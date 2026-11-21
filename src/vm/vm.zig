//! The stack VM: executes a verified Proto tree (bytecode/bytecode.zig).
//!
//! State (DESIGN_DECISIONS D12, D36), all addressed by index, never by pointer, so the
//! stacks can move when they grow:
//!   frames   one per active call (the script is frames[0]): its Proto and closure,
//!            the caller's pc to return to, where its locals and operands start
//!   locals   every frame's slots, contiguous; a slot holds a value (`null` = TDZ) or,
//!            for a captured binding, a Cell (`Slot`)
//!   stack    every frame's operands, contiguous; a callee's operands start above the
//!            caller's arguments
//!
//! Semantics live in runtime/ops.zig, shared with the tree-walker (D16). This file only
//! moves values between the stacks, the cells and those functions.
//!
//! `step()` contract (DESIGN_DECISIONS D35)
//!   * Executes exactly one instruction (a call or return included), charging one budget
//!     step *before* it.
//!   * `.running`: the instruction completed; `pc` is the next instruction (the callee's
//!     first after a call, the caller's next after a return).
//!   * `.halted`: `halt` executed. Further calls return `.halted` and do nothing.
//!   * An error is *precise*: `pc`, the frames, both stacks and every slot and cell are
//!     exactly as before the failing instruction. Details are on the Runtime. The VM is
//!     then faulted: further calls return the same error and execute nothing. (Side
//!     effects outside the VM, such as output a native already wrote, are not undone.)
//!
//! Calls (D36) are transactional: limits are checked and every stack's capacity is
//! reserved (growing may move a stack, which is fine: everything is an index) before
//! anything is committed, so a failed call leaves the caller exactly as it was: its
//! operands, including callee and arguments, untouched, and `pc` on the `call`.
//!
//! Defensive checks. The verifier rejects malformed bytecode; these checks catch bugs in
//! the VM, the compiler or the verifier themselves: pc and instruction bounds, opcode
//! validity, a frame's stack underflow/overflow, slot, constant, name, function and
//! capture indices, and the kind of a slot (value or cell). They are cheap compares,
//! kept in every build mode, and a failure is a bug: it returns `error.Internal` and
//! poisons the runtime (D49), rather than producing a JavaScript-visible result or
//! crashing an embedder's process.

const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("build_options");
const Value = @import("../runtime/value.zig").Value;
const heap = @import("../runtime/heap.zig");
const Cell = heap.Cell;
const Closure = heap.Closure;
const rt_mod = @import("../runtime/runtime.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const ops = @import("../runtime/ops.zig");
const object = @import("../runtime/object.zig");
const bigint = @import("../runtime/bigint.zig");
const builtins = @import("../runtime/builtins.zig");
const coroutine = @import("../runtime/coroutine.zig");
const BinaryOp = @import("../frontend/ast.zig").BinaryOp;
const bc = @import("../bytecode/bytecode.zig");
const Op = bc.Op;
const Proto = bc.Proto;

/// A local slot: a plain binding's value (`null` = TDZ), or a captured binding's cell.
pub const Slot = union(enum) {
    value: ?Value,
    cell: *Cell,
};

pub const Frame = struct {
    proto: *const Proto,
    /// The running closure (null for the script).
    closure: ?*const Closure,
    /// Where the caller continues (unused for the script).
    return_pc: u32,
    /// First of this frame's `slot_count` locals.
    locals_base: u32,
    /// First of this frame's operands.
    stack_base: u32,
    /// Where the result goes in the caller's operands (the callee's slot, or the receiver's
    /// for a method call): `return` cuts the stack back to it.
    result_index: u32,
    /// `this`: the method call's receiver, or null for a call without one (D41).
    this: ?Value,
    /// The end of the operand region reserved by this frame *or any frame below it*: a
    /// callee's region can end below its caller's, and the stack must keep both.
    stack_end: u32,
    /// Where this call's arguments start on `vm.stack`, and how many were passed.
    args_start: u32,
    argc: u32,
    /// True when entered via `new` (returns `this` unless body returns an object-like value).
    is_construct: bool = false,
    /// True when entered via `super(...)` from a derived class constructor.
    is_super_call: bool = false,
    /// Pre-allocated instance for `new` / `super(...)` (traced by GC).
    construct_instance: ?*heap.Object = null,
};

pub const Vm = struct {
    pub const State = enum { running, halted, awaiting };

    rt: *Runtime,
    frames: std.ArrayList(Frame) = .empty,
    locals: []Slot = &.{},
    locals_len: u32 = 0,
    stack: []Value = &.{},
    sp: u32 = 0,
    /// Σ (slot_count + max_stack) over active frames (Limits.max_stack_slots).
    reserved: u64 = 0,
    /// The current frame's pc.
    pc: u32 = 0,
    halted: bool = false,
    fault: ?Error = null,
    /// A nested-call VM (M9.1, D51): the closure runs as frame 0 and `return` ends the
    /// call into `nested_result` — no caller frame exists. The `.return` "in the script"
    /// bug applies only to ordinary script frames.
    nested: bool = false,
    /// The nested call's result, set when its frame 0 returns. Null until then; a halt
    /// without one is an engine bug (a function's proto always ends in `return`).
    nested_result: ?Value = null,
    /// The value passed to `await` when this VM is suspended in `.awaiting` (D56), or the
    /// value a generator yielded (D67).
    awaited: Value = .undefined,
    /// Set by `yield`/`generator_start` (in `executeCold`) to stop the run loop; the
    /// suspension is then reported as `.yielded`, not `.awaiting` (D67).
    yielding: bool = false,
    /// The pending yield is `yield*`'s raw inner result.
    yield_raw: bool = false,
    /// The execution context this VM charges (M9.1, D51): set while a chain runs it —
    /// the embedding API's resume, or a nested call — so frames check the chain's shared
    /// `call_depth` instead of a per-VM limit. Null for a chain-less VM (the CLI's),
    /// which keeps its own per-VM check. Torn down in `deinit` (subtracting the frames
    /// still live), so a VM faulting mid-recursion unwinds its charge exactly.
    chain: ?*rt_mod.ExecContext = null,

    /// `script` must have passed `verify` and must outlive the VM (and every use of its
    /// closures). Allocates with `rt.gpa`; on failure nothing is left allocated.
    pub fn init(rt: *Runtime, script: *const Proto) Error!Vm {
        if (@as(u64, script.slot_count) + script.max_stack > rt.limits.max_stack_slots) return rt.limit(.stack_slots);
        var vm: Vm = .{ .rt = rt };
        errdefer vm.deinit();
        try vm.reserve(script);
        try vm.frames.ensureTotalCapacity(rt.gpa, 1);
        vm.initLocals(script, &.{});
        vm.frames.appendAssumeCapacity(.{ .proto = script, .closure = null, .return_pc = 0, .locals_base = 0, .stack_base = 0, .result_index = 0, .this = if (script.is_module) .undefined else null, .stack_end = script.max_stack, .args_start = 0, .argc = 0 });
        vm.locals_len = script.slot_count;
        vm.reserved = script.slot_count + script.max_stack;
        return vm;
    }

    pub fn deinit(vm: *Vm) void {
        if (vm.chain) |cx| if (cx.active) {
            cx.call_depth -= @intCast(vm.frames.items.len); // the frames still live unwind their depth charge (D51)
        };
        if (vm.rt.engine_roots) |e| if (e.ctx == @as(*anyopaque, vm)) {
            vm.rt.engine_roots = null; // no collection may scan a VM that is gone
        };
        if (!vm.nested) vm.rt.template_cache.clearRetainingCapacity();
        const gpa = vm.rt.gpa;
        vm.frames.deinit(gpa);
        gpa.free(vm.locals);
        gpa.free(vm.stack);
        vm.* = undefined;
    }

    /// A VM for one nested call (M9.1, D51): the closure runs as frame 0 with `this` and
    /// `args` bound (missing parameters undefined, extra ones ignored, as a call binds
    /// them); its `return` ends the call into `nested_result`, so no caller frame exists.
    /// It shares the runtime's heap and realm. The caller sets `chain` (the shared
    /// budget and depth), registers `roots()` with the execution context before the
    /// first step, and tears the VM down with `deinit` — which unwinds exactly the
    /// frames a fault left live. Transactional: on failure nothing is left allocated.
    pub fn initCall(rt: *Runtime, c: *const Closure, this: ?Value, args: []const Value) Error!Vm {
        return initCallEx(rt, c, this, args, false, null);
    }

    fn initCallEx(rt: *Runtime, c: *const Closure, this: ?Value, args: []const Value, is_construct: bool, construct_instance: ?*heap.Object) Error!Vm {
        c.obj.checkLive();
        const v = switch (c.impl) {
            .vm => |v| v,
            .tree, .promise_cap, .native_closure, .bound => return rt.bug("a non-VM closure in a nested call"),
        };
        const callee: *const Proto = @ptrCast(@alignCast(v.proto));
        const effective_this: ?Value = if (callee.is_arrow) (if (c.meta) |m| m.lexical_this else null) else this;
        const argc: u32 = @intCast(args.len);
        if (@as(u64, argc) + callee.slot_count + callee.max_stack > rt.limits.max_stack_slots) return rt.limit(.stack_slots);
        var vm: Vm = .{ .rt = rt, .nested = true };
        errdefer vm.deinit();
        try vm.reserveWithExtra(callee, argc);
        try vm.frames.ensureTotalCapacity(rt.gpa, 1);
        if (argc > 0) @memcpy(vm.stack[0..argc], args);
        vm.sp = argc;
        vm.initLocals(callee, args);
        vm.frames.appendAssumeCapacity(.{
            .proto = callee,
            .closure = c,
            .return_pc = 0,
            .locals_base = 0,
            .stack_base = argc,
            .result_index = 0,
            .this = effective_this,
            .stack_end = argc + callee.max_stack,
            .args_start = 0,
            .argc = argc,
            .is_construct = is_construct,
            .construct_instance = construct_instance,
        });
        vm.locals_len = callee.slot_count;
        vm.reserved = callee.slot_count + callee.max_stack;
        return vm;
    }

    /// Invokes a VM closure from inside a built-in native via Model B nested VM execution (M16.1).
    fn callFromBuiltin(ctx: *anyopaque, c: *const Closure, this: ?Value, args: []const Value) Error!Value {
        const vm: *Vm = @ptrCast(@alignCast(ctx));
        return callNested(vm.rt, vm, c, this, args, false, null);
    }

    fn constructFromBuiltin(ctx: *anyopaque, c: *const Closure, args: []const Value, new_target: Value) Error!Value {
        const vm: *Vm = @ptrCast(@alignCast(ctx));
        return constructNested(vm.rt, vm, c, args, new_target);
    }

    /// Invokes a VM closure from a top-level microtask checkpoint outside any outer VM (M18).
    pub fn callStandalone(ctx: *anyopaque, c: *const Closure, this: ?Value, args: []const Value) Error!Value {
        const rt: *Runtime = @ptrCast(@alignCast(ctx));
        return callNested(rt, null, c, this, args, false, null);
    }

    pub fn constructStandalone(ctx: *anyopaque, c: *const Closure, args: []const Value, new_target: Value) Error!Value {
        const rt: *Runtime = @ptrCast(@alignCast(ctx));
        return constructNested(rt, null, c, args, new_target);
    }

    fn constructNested(rt: *Runtime, caller_vm: ?*Vm, c: *const Closure, args: []const Value, new_target: Value) Error!Value {
        c.obj.checkLive();
        const v = switch (c.impl) {
            .vm => |v| v,
            .tree, .promise_cap, .native_closure, .bound => return rt.bug("a non-VM closure in a nested construct"),
        };
        const callee: *const Proto = @ptrCast(@alignCast(v.proto));
        if (callee.is_generator or !builtins.hasAutoPrototype(c)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }});
        }
        var root_buf = [_]Value{ .{ .closure = c }, new_target, .undefined };
        var val_roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try val_roots.register(rt);
        defer val_roots.unregister(rt);

        const proto_val = try object.get(rt, new_target, try object.named(rt, "prototype"));
        const r = try builtins.realm(rt);
        const instance = try rt.heap.newObject(if (proto_val == .object) proto_val.object else r.object_prototype);
        root_buf[2] = .{ .object = instance };
        const init_this: ?Value = if (callee.has_super_ctor) null else .{ .object = instance };
        return callNested(rt, caller_vm, c, init_this, args, true, instance);
    }

    fn callNested(rt: *Runtime, caller_vm: ?*Vm, c: *const Closure, this: ?Value, args: []const Value, is_construct: bool, construct_instance: ?*heap.Object) Error!Value {
        c.obj.checkLive();
        const v = switch (c.impl) {
            .vm => |v| v,
            .tree, .promise_cap, .native_closure, .bound => return rt.bug("a non-VM closure in a nested call"),
        };
        const callee: *const Proto = @ptrCast(@alignCast(v.proto));
        if (!is_construct and callee.is_class_constructor) return rt.throw(.TypeError, &.{.{ .ascii = "Class constructor cannot be invoked without 'new'" }});
        if (callee.is_async) return startAsync(rt, caller_vm, c, this, args);

        const own_chain = !rt.exec_ctx.active;
        const saved_max_steps = rt.max_steps;
        if (own_chain) {
            if (caller_vm) |cv| {
                std.debug.assert(cv.chain == null);
                rt.beginChain(rt.steps, saved_max_steps);
                rt.exec_ctx.call_depth = @intCast(cv.frames.items.len);
                cv.chain = &rt.exec_ctx;
            } else {
                rt.beginChain(rt.steps, saved_max_steps);
            }
        }
        const depth_before = rt.exec_ctx.call_depth;
        defer {
            std.debug.assert(rt.exec_ctx.call_depth == depth_before);
            if (own_chain) {
                if (caller_vm) |cv| cv.chain = null;
                _ = rt.endChain();
                rt.max_steps = saved_max_steps;
            }
        }
        if (rt.exec_ctx.budget_fault != null) return rt.limit(.steps);
        if (rt.exec_ctx.call_depth >= rt.limits.max_call_depth) return rt.limit(.call_depth);

        var nested = try Vm.initCallEx(rt, c, this, args, is_construct, construct_instance);
        defer nested.deinit();
        nested.chain = &rt.exec_ctx;
        rt.exec_ctx.call_depth += 1;
        try rt.exec_ctx.vms.append(rt.gpa, nested.roots());
        defer rt.exec_ctx.removeVm(&nested);

        if (is_construct and !callee.has_super_ctor and construct_instance != null) {
            try builtins.runInstanceInits(rt, @constCast(c), .{ .object = construct_instance.? });
        }

        try nested.run();
        if (rt.exec_ctx.budget_fault != null) return rt.limit(.steps);
        return nested.nested_result orelse rt.bug("a nested call ended without a result");
    }

    const StartAsyncCtx = struct {
        rt: *Runtime,
        caller_vm: ?*Vm,
        c: *const Closure,
        this: ?Value,
        args: []const Value,
    };

    const CoroAction = union(enum) {
        start,
        @"resume": struct { val: Value, mode: coroutine.ResumeMode },
    };

    noinline fn startAsyncFromVm(vm: *Vm, c: *const Closure, this: ?Value, args: []const Value) Error!Value {
        @branchHint(.cold);
        return startAsync(vm.rt, vm, c, this, args);
    }

    /// Starts a top-level REPL script compiled as an async body (D71).
    pub fn startTopLevelAsync(rt: *Runtime, p: *const Proto) Error!Value {
        const c = try rt.heap.newVmClosure(p, 0);
        var held = [_]Value{.{ .closure = c }};
        var val_roots: rt_mod.ValueRoots = .{ .values = &held };
        try val_roots.register(rt);
        defer val_roots.unregister(rt);
        return startAsync(rt, null, c, null, &.{});
    }

    /// Every `is_async` call lands here: async functions and generators (D67).
    noinline fn startAsync(rt: *Runtime, caller_vm: ?*Vm, c: *const Closure, this: ?Value, args: []const Value) Error!Value {
        @branchHint(.cold);
        const ctx: StartAsyncCtx = .{ .rt = rt, .caller_vm = caller_vm, .c = c, .this = this, .args = args };
        const p: *const Proto = @ptrCast(@alignCast(c.impl.vm.proto));
        if (p.is_generator)
            return coroutine.startGenerator(rt, &coro_vtable, .{ .closure = c }, p.is_async_generator, ctx, createAndRunCoro);
        return coroutine.start(rt, &coro_vtable, ctx, createAndRunCoro);
    }

    fn createAndRunCoro(ctx: StartAsyncCtx, co: *heap.Coroutine) Error!coroutine.Outcome {
        const rt = ctx.rt;
        const vm_ptr = try rt.gpa.create(Vm);
        vm_ptr.* = Vm.initCall(rt, ctx.c, ctx.this, ctx.args) catch |e| {
            rt.gpa.destroy(vm_ptr);
            return e;
        };
        co.engine = vm_ptr;
        co.state = .running;
        return runCoroVm(vm_ptr, ctx.caller_vm, .start);
    }

    fn runCoroVm(vm: *Vm, caller_vm: ?*Vm, action: CoroAction) Error!coroutine.Outcome {
        const rt = vm.rt;
        const own_chain = !rt.exec_ctx.active;
        const saved_max_steps = rt.max_steps;
        if (own_chain) {
            if (caller_vm) |cv| {
                std.debug.assert(cv.chain == null);
                rt.beginChain(rt.steps, saved_max_steps);
                rt.exec_ctx.call_depth = @intCast(cv.frames.items.len);
                cv.chain = &rt.exec_ctx;
            } else {
                rt.beginChain(rt.steps, saved_max_steps);
            }
        }
        const depth_before = rt.exec_ctx.call_depth;
        defer {
            std.debug.assert(rt.exec_ctx.call_depth == depth_before);
            if (own_chain) {
                if (caller_vm) |cv| cv.chain = null;
                _ = rt.endChain();
                rt.max_steps = saved_max_steps;
            }
        }
        if (rt.exec_ctx.budget_fault != null) return rt.limit(.steps);
        if (rt.exec_ctx.call_depth >= rt.limits.max_call_depth) return rt.limit(.call_depth);

        vm.chain = &rt.exec_ctx;
        rt.exec_ctx.call_depth += @intCast(vm.frames.items.len);
        defer {
            if (vm.chain) |cx| {
                if (cx.active) cx.call_depth -= @intCast(vm.frames.items.len);
                vm.chain = null;
            }
        }
        try rt.exec_ctx.vms.append(rt.gpa, vm.roots());
        defer rt.exec_ctx.removeVm(vm);

        switch (action) {
            .start => {},
            .@"resume" => |res| {
                vm.awaited = .undefined;
                const at = vm.frame().proto.code[vm.pc];
                if (at == @backingInt(Op.generator_start)) {
                    vm.pc += Op.generator_start.size(); // the first `next()`: its value is dropped
                } else if (at == @backingInt(Op.yield)) {
                    // [value, mode]: the code after `yield` dispatches on the mode (D67).
                    if (vm.sp + 2 > vm.stack.len) return vm.bug("stack overflow on generator resume");
                    vm.stack[vm.sp] = res.val;
                    vm.stack[vm.sp + 1] = .{ .number = @floatFromInt(@backingInt(res.mode)) };
                    vm.sp += 2;
                    vm.pc += Op.yield.size();
                } else if (res.mode == .throw) {
                    _ = rt.throwValue(res.val) catch {};
                    vm.unwind(vm.pc) catch |ue| {
                        if (ue == error.Thrown) return .threw;
                        return ue;
                    };
                } else {
                    if (vm.sp >= vm.stack.len) return vm.bug("stack overflow on await resume");
                    vm.stack[vm.sp] = res.val;
                    vm.sp += 1;
                    vm.pc += Op.await.size();
                }
            },
        }

        const state = vm.runLoop(false, 0) catch |e| {
            if (e != error.Internal and rt.exec_ctx.budget_fault != null) return rt.limit(.steps);
            if (e == error.Thrown) return .threw;
            return e;
        };
        if (rt.exec_ctx.budget_fault != null) return rt.limit(.steps);
        return switch (state) {
            .halted => .{ .returned = vm.nested_result orelse return rt.bug("a nested call ended without a result") },
            .awaiting => if (vm.yielding) blk: {
                vm.yielding = false;
                break :blk .{ .yielded = .{ .value = vm.awaited, .raw = vm.yield_raw } };
            } else .{ .awaiting = vm.awaited },
            .running => unreachable,
        };
    }

    fn coroResume(eng: *anyopaque, val: Value, mode: coroutine.ResumeMode) Error!coroutine.Outcome {
        const vm: *Vm = @ptrCast(@alignCast(eng));
        return runCoroVm(vm, null, .{ .@"resume" = .{ .val = val, .mode = mode } });
    }

    fn coroTrace(eng: *anyopaque, visit_ctx: *anyopaque, visit: *const fn (*anyopaque, *heap.Obj) void) void {
        const vm: *const Vm = @ptrCast(@alignCast(eng));
        const Ctx = struct { ctx: *anyopaque, visit: *const fn (*anyopaque, *heap.Obj) void };
        const thunk = struct {
            fn call(c: Ctx, o: *heap.Obj) void {
                c.visit(c.ctx, o);
            }
        }.call;
        visitRoots(vm, Ctx{ .ctx = visit_ctx, .visit = visit }, thunk);
    }

    pub fn ownedBytes(vm: *const Vm) usize {
        return @sizeOf(Vm) +
            vm.frames.capacity * @sizeOf(Frame) +
            vm.locals.len * @sizeOf(Slot) +
            vm.stack.len * @sizeOf(Value);
    }

    fn coroOwnedBytes(eng: *anyopaque) usize {
        const vm: *const Vm = @ptrCast(@alignCast(eng));
        return vm.ownedBytes();
    }

    pub fn shrink(vm: *Vm) void {
        if (vm.frames.items.len != 1) return;
        const gpa = vm.rt.gpa;
        const f = vm.frames.items[0];
        if (vm.frames.capacity > 1) vm.frames.shrinkAndFree(gpa, 1);
        const need_locals = f.proto.slot_count;
        if (vm.locals.len > need_locals) {
            if (gpa.realloc(vm.locals, need_locals)) |new_locals| {
                vm.locals = new_locals;
            } else |_| {}
        }
        const need_stack = @max(vm.sp, f.argc + f.proto.max_stack);
        if (vm.stack.len > need_stack) {
            if (gpa.realloc(vm.stack, need_stack)) |new_stack| {
                vm.stack = new_stack;
            } else |_| {}
        }
    }

    fn coroShrink(eng: *anyopaque) void {
        const vm: *Vm = @ptrCast(@alignCast(eng));
        vm.shrink();
    }

    fn coroDestroy(eng: *anyopaque) void {
        const vm: *Vm = @ptrCast(@alignCast(eng));
        const gpa = vm.rt.gpa;
        vm.deinit();
        gpa.destroy(vm);
    }

    const coro_vtable: heap.CoroutineVTable = .{
        .trace = coroTrace,
        .ownedBytes = coroOwnedBytes,
        .shrink = coroShrink,
        .destroy = coroDestroy,
        .@"resume" = &coroResume,
    };

    /// Runs to `halt` or the first error (M10.2a: dedicated continuous loop preserving
    /// `Vm.step()` unchanged for sliced execution and debugging, with exact `rt.step()`
    /// accounting and per-instruction GC safepoints).
    pub fn run(vm: *Vm) Error!void {
        _ = try vm.runLoop(false, 0);
    }

    /// Runs up to `steps` instructions (or `std.math.maxInt(u64)` unbounded) using the
    /// same continuous loop and exact `execute` / GC safepoint semantics as `run()`.
    pub fn runSteps(vm: *Vm, steps: u64) Error!State {
        if (steps == std.math.maxInt(u64)) return vm.runLoop(false, 0);
        return vm.runLoop(true, steps);
    }

    /// Loop-local cache of the active frame's `proto`, `code`, `pc`, and frame-constant
    /// stack/local bounds (`locals_base` is stored as an index into `vm.locals`, never
    /// as a slice/pointer, so stack/local growth in `enter()` cannot dangle).
    /// Invariants: `vm.pc` is still written on every committed instruction so helpers,
    /// errors, host calls, GC, and suspended slices always observe an exact PC; any
    /// opcode that pushes or pops a frame (currently `.call`/`.call_method` on a
    /// closure and `.@"return"`) must refresh the cache via `FrameCache.fromVm`.
    const FrameCache = struct {
        p: *const Proto,
        code: []const u8,
        pc: u32,
        sp: u32,
        stack_base: u32,
        stack_limit: u32,
        locals_base: u32,

        fn fromVm(vm: *const Vm, pc: u32) FrameCache {
            const f = vm.frame();
            const p = f.proto;
            const limit = @min(@as(usize, f.stack_base) + p.max_stack, vm.stack.len);
            return .{
                .p = p,
                .code = p.code,
                .pc = pc,
                .sp = vm.sp,
                .stack_base = f.stack_base,
                .stack_limit = @intCast(limit),
                .locals_base = f.locals_base,
            };
        }

        inline fn syncSp(self: FrameCache, vm: *Vm) void {
            vm.sp = self.sp;
        }

        inline fn operand(self: FrameCache, i: usize) u32 {
            return bc.readU32(self.code, self.pc + 1 + 4 * i); // instruction bounds checked in execute
        }

        inline fn target(self: FrameCache, vm: *const Vm) Error!u32 {
            const t = self.operand(0);
            if (t >= self.code.len) return vm.bug("jump target outside the code");
            return t;
        }

        inline fn slot(self: FrameCache, vm: *Vm, i: u32) Error!*Slot {
            if (i >= self.p.slot_count) return vm.bug("slot index out of range");
            return &vm.locals[self.locals_base + i];
        }

        inline fn value(self: FrameCache, vm: *Vm, i: u32) Error!*?Value {
            return switch ((try self.slot(vm, i)).*) {
                .value => |*v| v,
                .cell => return vm.bug("value access to a cell slot"),
            };
        }

        inline fn cellAt(self: FrameCache, vm: *Vm, i: u32) Error!*Cell {
            return vm.cellIn(try self.slot(vm, i));
        }

        inline fn ensurePush(self: FrameCache, vm: *const Vm) Error!void {
            if (self.sp >= self.stack_limit) return vm.bug("stack overflow");
        }

        inline fn ensurePush2(self: FrameCache, vm: *const Vm) Error!void {
            if (self.sp + 1 >= self.stack_limit) return vm.bug("stack overflow");
        }

        inline fn push(self: *FrameCache, vm: *Vm, v: Value) Error!void {
            try self.ensurePush(vm);
            const sp = self.sp;
            vm.stack[sp] = v;
            self.sp = sp + 1;
        }

        inline fn peek(self: FrameCache, vm: *const Vm, depth: u32) Error!Value {
            if (depth >= self.sp - self.stack_base) return vm.bug("stack underflow");
            return vm.stack[self.sp - 1 - depth];
        }

        inline fn top(self: FrameCache, vm: *Vm) Error!*Value {
            if (self.sp == self.stack_base) return vm.bug("stack underflow");
            return &vm.stack[self.sp - 1];
        }

        inline fn drop(self: *FrameCache, vm: *const Vm, n: u32) Error!void {
            if (n > self.sp - self.stack_base) return vm.bug("stack underflow");
            self.sp -= n;
        }
    };

    inline fn runLoop(vm: *Vm, comptime bounded: bool, steps: u64) Error!State {
        if (vm.fault) |e| return e;
        if (vm.halted) return .halted;
        const rt = vm.rt;
        const h = &rt.heap;
        if (!vm.nested) rt.engine_roots = .{ .ctx = vm, .mark = markRoots };
        const prev_caller = rt.closure_caller;
        rt.closure_caller = .{ .ctx = vm, .call = callFromBuiltin, .construct = constructFromBuiltin };
        defer rt.closure_caller = prev_caller;
        var cache = FrameCache.fromVm(vm, vm.pc);
        var n: u64 = 0;
        while (!bounded or n < steps) {
            if (h.collect_requested or h.collect_always) {
                cache.syncSp(vm);
                rt.collect();
            }
            const state = @call(.always_inline, execute, .{ vm, &cache }) catch |e| {
                cache.syncSp(vm);
                if (e == error.Thrown) {
                    if (vm.unwind(cache.pc)) |_| {
                        cache = FrameCache.fromVm(vm, vm.pc);
                        if (bounded) n += 1;
                        continue;
                    } else |ue| {
                        vm.fault = ue;
                        return ue;
                    }
                }
                vm.fault = e;
                return e;
            };
            if (state != .running) {
                cache.syncSp(vm);
                if (state == .halted) {
                    if (!vm.nested) {
                        rt.drainMicrotasks() catch |e| {
                            vm.fault = e;
                            return e;
                        };
                    }
                    return .halted;
                }
                return .awaiting;
            }
            if (bounded) n += 1;
        }
        cache.syncSp(vm);
        return if (vm.halted) .halted else .running;
    }

    /// The VM's roots (GC_DESIGN §4): the operand stack, the locals (values and cells), each
    /// frame's closure and `this`, and the script's Proto tree (its string constants; the
    /// Protos aren't heap objects, so the tree being run is what keeps them).
    /// This VM as a root set, for a host that keeps it across calls (the embedding API's
    /// suspended executions). `vm` must not move while registered.
    pub fn roots(vm: *Vm) rt_mod.EngineRoots {
        return .{ .ctx = vm, .mark = markRoots };
    }

    /// A compiled script's constants as a root set (the embedding API keeps programs that
    /// aren't running alive). `p` must not move while registered.
    pub fn protoRoots(p: *const Proto) rt_mod.EngineRoots {
        return .{ .ctx = @constCast(p), .mark = struct {
            fn mark(ctx: *anyopaque, h: *heap.Heap) void {
                markProto(h, @ptrCast(@alignCast(ctx)));
            }
        }.mark };
    }

    fn markRoots(ctx: *anyopaque, h: *heap.Heap) void {
        const vm: *const Vm = @ptrCast(@alignCast(ctx));
        const mark_obj = struct {
            fn call(hh: *heap.Heap, o: *heap.Obj) void {
                hh.markObj(o);
            }
        }.call;
        visitRoots(vm, h, mark_obj);
        markProto(h, vm.frames.items[0].proto);
    }

    /// The VM's own live state, shared by `markRoots` and a suspended coroutine's trace.
    /// The Proto's constants are not included: they belong to the program (or the script
    /// VM), and a coroutine trace must not read a Proto whose program may already be gone.
    fn visitRoots(vm: *const Vm, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *heap.Obj) void) void {
        for (vm.stack[0..vm.sp]) |v| heap.visitValue(v, ctx, visit);
        for (vm.locals[0..vm.locals_len]) |s| switch (s) {
            .value => |v| if (v) |x| heap.visitValue(x, ctx, visit),
            .cell => |c| visit(ctx, &c.obj),
        };
        for (vm.frames.items) |f| {
            if (f.closure) |c| visit(ctx, @constCast(&c.obj));
            if (f.this) |t| heap.visitValue(t, ctx, visit);
            if (f.construct_instance) |ci| visit(ctx, &ci.obj);
        }
        heap.visitValue(vm.awaited, ctx, visit);
    }

    fn visitProto(p: *const Proto, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *heap.Obj) void) void {
        for (p.consts) |k| heap.visitValue(k, ctx, visit);
        for (p.name_atoms) |a| visit(ctx, &a.obj);
        for (p.functions) |*f| visitProto(f, ctx, visit); // nesting depth is bounded by the AST's
    }

    fn markProto(h: *heap.Heap, p: *const Proto) void {
        const mark_obj = struct {
            fn call(hh: *heap.Heap, o: *heap.Obj) void {
                hh.markObj(o);
            }
        }.call;
        visitProto(p, h, mark_obj);
    }

    /// The Proto this VM runs (the one `init` was given), for tests.
    pub fn scriptProto(vm: *const Vm) *const Proto {
        return vm.frames.items[0].proto;
    }

    /// The operand stack of all frames, bottom first (for traces and tests).
    pub fn operands(vm: *const Vm) []const Value {
        return vm.stack[0..vm.sp];
    }

    pub fn frame(vm: *const Vm) *const Frame {
        return &vm.frames.items[vm.frames.items.len - 1];
    }

    pub fn proto(vm: *const Vm) *const Proto {
        return vm.frame().proto;
    }

    pub fn step(vm: *Vm) Error!State {
        if (vm.fault) |e| return e;
        if (vm.halted) return .halted;
        // The safepoint (D8): every live value is in the stacks and frames now, so a
        // collection can run. Before the budget charge, so collecting never costs a step.
        // Registered here rather than in init, which returns the VM by value (a pointer
        // taken there would point at a copy).
        const h = &vm.rt.heap;
        if (h.collect_requested or h.collect_always) {
            if (!vm.nested) vm.rt.engine_roots = .{ .ctx = vm, .mark = markRoots };
            vm.rt.collect();
        }
        var cache = FrameCache.fromVm(vm, vm.pc);
        const state = vm.execute(&cache) catch |e| {
            cache.syncSp(vm);
            if (e == error.Thrown) {
                if (vm.unwind(cache.pc)) |_| {
                    return .running;
                } else |ue| {
                    vm.fault = ue;
                    return ue;
                }
            }
            vm.fault = e;
            return e;
        };
        cache.syncSp(vm);
        return state;
    }

    /// One instruction. Every path either fails before changing VM state, or commits
    /// its changes and then sets `pc` (see the contract above).
    fn execute(vm: *Vm, cache: *FrameCache) Error!State {
        const p = cache.p;
        const code = cache.code;
        const pc = cache.pc;
        if (pc >= code.len) return vm.bug("pc outside the code");
        const byte = code[pc];
        if (byte >= Op.count) return vm.bug("invalid opcode");
        const op: Op = @fromBackingInt(@intCast(byte));
        if (op.size() > code.len - pc) return vm.bug("instruction runs past the end of the code");
        try vm.rt.step();
        const rt = vm.rt;
        var next: u32 = pc + op.size();

        switch (op) {
            .push_undefined => try cache.push(vm, .undefined),
            .push_null => try cache.push(vm, .null),
            .push_true => try cache.push(vm, .{ .boolean = true }),
            .push_false => try cache.push(vm, .{ .boolean = false }),
            .push_const => {
                const k = cache.operand(0);
                if (k >= p.consts.len) return vm.bug("constant index out of range");
                try cache.push(vm, p.consts[k]);
            },

            .get_local => {
                const v = (try cache.value(vm, cache.operand(0))).* orelse return vm.tdz(cache.operand(1));
                try cache.push(vm, v);
            },
            .set_local => {
                const s = try cache.value(vm, cache.operand(0));
                if (s.* == null) return vm.tdz(cache.operand(1));
                s.* = try cache.peek(vm, 0); // the assignment's value stays on the stack
            },
            .init_local => {
                (try cache.slot(vm, cache.operand(0))).* = .{ .value = try cache.peek(vm, 0) };
                try cache.drop(vm, 1);
            },
            .clear_local => (try cache.slot(vm, cache.operand(0))).* = .{ .value = null },
            .assign_const => {
                if ((try cache.value(vm, cache.operand(0))).* == null) return vm.tdz(cache.operand(1));
                return vm.constAssignment();
            },
            .get_global => {
                try cache.ensurePush(vm);
                try cache.push(vm, try builtins.global(rt, try vm.name(cache.operand(0))));
            },
            .get_global_or_undefined => {
                try cache.ensurePush(vm);
                try cache.push(vm, try builtins.tryGlobal(rt, try vm.name(cache.operand(0))));
            },

            .new_cell => {
                (try cache.slot(vm, cache.operand(0))).* = .{ .cell = try rt.heap.newCell(null) };
            },
            .box_local => {
                const s = try cache.slot(vm, cache.operand(0));
                const v: Value = switch (s.*) {
                    .value => |v| v orelse return vm.bug("boxing a slot in the TDZ"),
                    .cell => return vm.bug("boxing a cell"),
                };
                s.* = .{ .cell = try rt.heap.newCell(v) };
            },
            .fresh_cell => {
                const s = try cache.slot(vm, cache.operand(0));
                const old = try vm.cellIn(s);
                s.* = .{ .cell = try rt.heap.newCell(old.value) };
            },
            .get_cell => {
                const v = (try cache.cellAt(vm, cache.operand(0))).value orelse return vm.tdz(cache.operand(1));
                try cache.push(vm, v);
            },
            .set_cell => {
                const c = try cache.cellAt(vm, cache.operand(0));
                if (c.value == null) return vm.tdz(cache.operand(1));
                rt.heap.storeCell(c, try cache.peek(vm, 0));
            },
            .init_cell => {
                rt.heap.storeCell(try cache.cellAt(vm, cache.operand(0)), try cache.peek(vm, 0));
                try cache.drop(vm, 1);
            },
            .assign_const_cell => {
                if ((try cache.cellAt(vm, cache.operand(0))).value == null) return vm.tdz(cache.operand(1));
                return vm.constAssignment();
            },
            .get_capture => {
                const v = (try vm.capture(cache.operand(0))).value orelse return vm.tdz(cache.operand(1));
                try cache.push(vm, v);
            },
            .set_capture => {
                const c = try vm.capture(cache.operand(0));
                if (c.value == null) return vm.tdz(cache.operand(1));
                rt.heap.storeCell(c, try cache.peek(vm, 0));
            },
            .assign_const_capture => {
                if ((try vm.capture(cache.operand(0))).value == null) return vm.tdz(cache.operand(1));
                return vm.constAssignment();
            },
            .get_repl => {
                const idx = cache.operand(0);
                if (idx >= p.repl_cells.len) return vm.bug("repl cell index out of range");
                const v = p.repl_cells[idx].value orelse return vm.tdz(cache.operand(1));
                try cache.push(vm, v);
            },
            .set_repl => {
                const idx = cache.operand(0);
                if (idx >= p.repl_cells.len) return vm.bug("repl cell index out of range");
                const c = p.repl_cells[idx];
                if (c.value == null) return vm.tdz(cache.operand(1));
                rt.heap.storeCell(c, try cache.peek(vm, 0));
            },
            .init_repl => {
                const idx = cache.operand(0);
                if (idx >= p.repl_cells.len) return vm.bug("repl cell index out of range");
                rt.heap.storeCell(p.repl_cells[idx], try cache.peek(vm, 0));
                try cache.drop(vm, 1);
            },
            .assign_const_repl => {
                const idx = cache.operand(0);
                if (idx >= p.repl_cells.len) return vm.bug("repl cell index out of range");
                if (p.repl_cells[idx].value == null) return vm.tdz(cache.operand(1));
                return vm.constAssignment();
            },
            .save_repl_result => {
                rt.repl_result = try cache.peek(vm, 0);
                try cache.drop(vm, 1);
            },

            .make_closure => {
                const f = cache.operand(0);
                if (f >= p.functions.len) return vm.bug("function index out of range");
                const child = &p.functions[f];
                try cache.ensurePush(vm);
                const c = try rt.heap.newVmClosure(child, child.captures.len);
                // Fills the captures. These accessors fail only on a bug (a real failure
                // would leave an incomplete closure on the heap, collected, never reachable).
                for (child.captures, c.impl.vm.captures) |desc, *dst| dst.* = switch (desc.from) {
                    .parent_slot => try cache.cellAt(vm, desc.index),
                    .parent_capture => try vm.capture(desc.index),
                };
                if (child.is_arrow) {
                    if (vm.frame().this) |t| try rt.heap.storeClosureLexicalThis(c, t);
                    if (vm.frame().closure) |parent_c| {
                        if (parent_c.meta) |pm| {
                            if (pm.home_object) |ho| try rt.heap.storeClosureHomeObject(c, ho);
                        }
                    }
                }
                if (vm.frame().closure) |parent_c| {
                    if (parent_c.meta) |pm| {
                        if (pm.brand) |br| try rt.heap.storeClosureBrand(c, br);
                    }
                }
                try cache.push(vm, .{ .closure = c });
            },
            .push_callee => {
                const c = vm.frame().closure orelse return vm.bug("push_callee in the script");
                try cache.push(vm, .{ .closure = c });
            },

            .pop => try cache.drop(vm, 1),
            .dup => try cache.push(vm, try cache.peek(vm, 0)),
            .dup2 => {
                const a = try cache.peek(vm, 1);
                const b = try cache.peek(vm, 0);
                try cache.ensurePush2(vm);
                try cache.push(vm, a);
                try cache.push(vm, b);
            },
            .rot3, .rot4 => {
                const n: u32 = if (op == .rot3) 3 else 4;
                const t = try cache.peek(vm, 0);
                _ = try cache.peek(vm, n - 1); // underflow check
                const at = cache.sp - n;
                std.mem.copyBackwards(Value, vm.stack[at + 1 .. cache.sp], vm.stack[at .. cache.sp - 1]);
                vm.stack[at] = t;
            },

            // ---- objects: compute first (any of these can fail), then commit
            .new_object => {
                try cache.ensurePush(vm);
                const o = try rt.heap.newObject((try builtins.realm(rt)).object_prototype);
                try cache.push(vm, .{ .object = o });
            },
            .new_array => {
                const n = cache.operand(0);
                if (n > cache.sp - cache.stack_base) return vm.bug("stack underflow");
                const arr = try rt.heap.newArray((try builtins.realm(rt)).array_prototype);
                try rt.heap.appendElements(arr, vm.stack[cache.sp - n .. cache.sp]);
                cache.sp -= n;
                try cache.push(vm, .{ .object = arr });
            },
            .new_regexp,
            .get_template_obj,
            .setup_class,
            .define_method,
            .define_elem_method,
            .define_accessor,
            .define_elem_accessor,
            .define_private_method,
            .define_private_accessor,
            .define_public_field,
            .define_private_field,
            .get_private,
            .set_private,
            .in_private,
            .store_field_key,
            .add_instance_init,
            .run_static_init,
            .set_brand,
            .super_call,
            .super_call_spread,
            .super_get_prop,
            .super_get_elem,
            .super_set_prop,
            .super_set_elem,
            .throw_delete_super,
            .delete_prop,
            .delete_elem,
            .rest_array,
            .array_spread,
            .object_spread,
            .iter_rest,
            .require_obj,
            .object_rest,
            .new_call_spread,
            .call_spread,
            .call_method_spread,
            .iter_close,
            .iter_close_throw,
            .generator_start,
            .yield,
            .yield_star_step,
            .get_async_iter,
            .async_iter_next,
            .async_iter_result,
            .async_iter_close,
            .async_iter_close_throw,
            .async_iter_close_check,
            .async_yield_star_call,
            .async_yield_star_result,
            => {
                cache.syncSp(vm);
                if (try vm.executeCold(op, pc, next)) {
                    if (vm.yielding) {
                        cache.sp = vm.sp;
                        return .awaiting; // a generator suspends like `await` (D67)
                    }
                    cache.* = FrameCache.fromVm(vm, 0);
                    return .running;
                }
                cache.sp = vm.sp;
            },
            .define_prop => {
                const o = try cache.peek(vm, 1);
                if (o != .object) return vm.bug("define on a non-object");
                try object.define(rt, o.object, try vm.nameKey(cache.operand(0)), try cache.peek(vm, 0));
                try cache.drop(vm, 1);
            },
            .define_elem => {
                cache.syncSp(vm);
                const o = try cache.peek(vm, 2);
                if (o != .object) return vm.bug("define on a non-object");
                try object.define(rt, o.object, try object.key(rt, try cache.peek(vm, 1)), try cache.peek(vm, 0));
                try cache.drop(vm, 2);
            },
            .get_prop => {
                cache.syncSp(vm);
                const r = try object.get(rt, try cache.peek(vm, 0), try vm.nameKey(cache.operand(0)));
                (try cache.top(vm)).* = r;
            },
            .get_elem => {
                const idx = try cache.peek(vm, 0);
                const base = try cache.peek(vm, 1);
                const r: Value = fastArrayGet(base, idx) orelse fastTypedArrayGet(base, idx) orelse blk: {
                    cache.syncSp(vm);
                    const k = try object.key(rt, idx);
                    break :blk try object.get(rt, base, k);
                };
                try cache.drop(vm, 1);
                (try cache.top(vm)).* = r;
            },
            .set_prop => {
                const v = try cache.peek(vm, 0);
                cache.syncSp(vm);
                try object.set(rt, try cache.peek(vm, 1), try vm.nameKey(cache.operand(0)), v);
                try cache.drop(vm, 1);
                (try cache.top(vm)).* = v;
            },
            .set_elem => {
                const v = try cache.peek(vm, 0);
                const idx = try cache.peek(vm, 1);
                const base = try cache.peek(vm, 2);
                if (!fastTypedArraySet(base, idx, v)) {
                    cache.syncSp(vm);
                    const k = try object.key(rt, idx); // after the value: JS's order for `=`
                    try object.set(rt, base, k, v);
                }
                try cache.drop(vm, 2);
                (try cache.top(vm)).* = v;
            },
            .push_this => {
                try cache.ensurePush(vm);
                try cache.push(vm, try vm.requireThis());
            },
            .get_arg => {
                const idx = cache.operand(0);
                const f = vm.frame();
                const val: Value = if (idx < f.argc) vm.stack[f.args_start + idx] else .undefined;
                try cache.push(vm, val);
            },
            .array_push => {
                const arr_v = try cache.peek(vm, 1);
                const val = try cache.peek(vm, 0);
                if (arr_v != .object or arr_v.object.kind != .array) return vm.bug("array_push on non-array");
                try rt.heap.appendElement(arr_v.object, val);
                try cache.drop(vm, 1);
            },

            .add, .sub, .mul, .div, .mod, .pow, .shl, .shr, .ushr, .bit_and, .bit_xor, .bit_or, .lt, .le, .gt, .ge, .strict_eq, .strict_ne, .in, .instanceof => {
                // M10.2b/M10.2c: fast path when both operands are already `.number` (`f64`),
                // matching IEEE-754 / JS semantics for NaN, infinities, and -0. All mixed or
                // out-of-domain cases fall back to `ops.binary`.
                const lhs = try cache.peek(vm, 1);
                const rhs = try cache.peek(vm, 0);
                const r: Value = if (lhs == .number and rhs == .number) switch (op) {
                    .add => .{ .number = lhs.number + rhs.number },
                    .sub => .{ .number = lhs.number - rhs.number },
                    .mul => .{ .number = lhs.number * rhs.number },
                    .div => .{ .number = lhs.number / rhs.number },
                    .mod => .{ .number = fastRemainder(lhs.number, rhs.number) },
                    .shl => .{ .number = ops.bitShl(lhs.number, rhs.number) },
                    .shr => .{ .number = ops.bitShr(lhs.number, rhs.number) },
                    .ushr => .{ .number = ops.bitUshr(lhs.number, rhs.number) },
                    .bit_and => .{ .number = ops.bitAnd(lhs.number, rhs.number) },
                    .bit_xor => .{ .number = ops.bitXor(lhs.number, rhs.number) },
                    .bit_or => .{ .number = ops.bitOr(lhs.number, rhs.number) },
                    .lt => .{ .boolean = lhs.number < rhs.number },
                    .le => .{ .boolean = lhs.number <= rhs.number },
                    .gt => .{ .boolean = lhs.number > rhs.number },
                    .ge => .{ .boolean = lhs.number >= rhs.number },
                    .strict_eq => .{ .boolean = lhs.number == rhs.number },
                    .strict_ne => .{ .boolean = lhs.number != rhs.number },
                    .pow, .in, .instanceof => blk: {
                        cache.syncSp(vm);
                        break :blk try ops.binary(rt, binaryOp(op), lhs, rhs);
                    },
                    else => unreachable,
                } else blk: {
                    cache.syncSp(vm);
                    break :blk try ops.binary(rt, binaryOp(op), lhs, rhs);
                };
                cache.sp -= 1;
                vm.stack[cache.sp - 1] = r;
            },
            // Compute into a local, then store. `top().* = .{ .number = f(peek(0)) }` would
            // be wrong: Zig builds the union in place, so the slot's tag changes *before*
            // f reads the old value through peek (result-location aliasing).
            .neg, .to_number, .to_numeric, .to_string, .not, .bit_not, .typeof => {
                const v = try cache.peek(vm, 0);
                if (v.isObjectLike() and (op == .neg or op == .to_number or op == .to_numeric or op == .to_string or op == .bit_not)) {
                    cache.syncSp(vm);
                }
                const r: Value = switch (op) {
                    .neg => blk: {
                        if (v == .number) break :blk .{ .number = -v.number };
                        const nv = try ops.toNumeric(rt, v);
                        break :blk if (nv == .bigint) .{ .bigint = try bigint.neg(rt, nv.bigint) } else .{ .number = -nv.number };
                    },
                    .to_number => if (v == .number) v else .{ .number = try ops.toNumber(rt, v) },
                    .to_numeric => if (v == .number or v == .bigint) v else try ops.toNumeric(rt, v),
                    .to_string => if (v == .string) v else try ops.toStringValue(rt, v),
                    .not => .{ .boolean = !ops.toBoolean(v) },
                    .bit_not => blk: {
                        if (v == .number) break :blk .{ .number = ops.bitNot(v.number) };
                        const nv = try ops.toNumeric(rt, v);
                        break :blk if (nv == .bigint) .{ .bigint = try bigint.bitNot(rt, nv.bigint) } else .{ .number = ops.bitNot(nv.number) };
                    },
                    .typeof => try ops.typeOf(rt, v),
                    else => unreachable,
                };
                (try cache.top(vm)).* = r;
            },
            .inc, .dec => {
                const t = try cache.top(vm);
                if (t.* == .number) {
                    t.number += if (op == .inc) 1 else -1;
                } else if (t.* == .bigint) {
                    t.* = .{ .bigint = try bigint.addI64(rt, t.bigint, if (op == .inc) 1 else -1) };
                } else {
                    return vm.bug("inc/dec on a non-numeric");
                }
            },

            .jump => next = try cache.target(vm),
            .jump_if_false, .jump_if_true => {
                const truthy = ops.toBoolean(try cache.peek(vm, 0));
                try cache.drop(vm, 1);
                if (truthy == (op == .jump_if_true)) next = try cache.target(vm);
            },
            .get_iter => {
                const iterable = try cache.peek(vm, 0);
                cache.syncSp(vm);
                const iter = try builtins.getIterator(rt, iterable);
                vm.stack[cache.sp - 1] = .{ .object = iter };
            },
            .iter_next => {
                const iter_val = try cache.peek(vm, 0);
                if (iter_val != .object or iter_val.object.kind != .iterator) return vm.bug("iter_next on non-iterator");
                cache.syncSp(vm);
                const next_v = try builtins.iteratorNextVal(rt, iter_val.object);
                vm.stack[cache.sp - 1] = next_v orelse .undefined;
                try cache.push(vm, .{ .boolean = next_v == null });
            },
            .for_in_init => {
                const obj = try cache.peek(vm, 0);
                cache.syncSp(vm);
                const iter = try builtins.forInInit(rt, obj);
                vm.stack[cache.sp - 1] = .{ .object = iter };
            },
            .for_in_next => {
                const iter_val = try cache.peek(vm, 0);
                if (iter_val != .object or iter_val.object.kind != .iterator) return vm.bug("for_in_next on non-iterator");
                cache.syncSp(vm);
                const next_v = try builtins.forInNext(rt, iter_val.object);
                vm.stack[cache.sp - 1] = next_v orelse .undefined;
                try cache.push(vm, .{ .boolean = next_v == null });
            },
            .new_call => {
                const argc = cache.operand(0);
                const group = argc + 1;
                if (group > cache.sp - cache.stack_base) return vm.bug("stack underflow");
                const base = cache.sp - group;
                const args = cache.sp - argc;
                cache.syncSp(vm);
                const callee = vm.stack[base];
                if (try vm.callConstruct(base, callee, args, vm.stack[args..cache.sp], false, next)) {
                    cache.* = FrameCache.fromVm(vm, 0);
                    return .running;
                }
                cache.sp = base + 1;
            },
            .call, .call_method => {
                // Stack: [callee, args…] or [receiver, callee, args…], arguments in source
                // order. The result replaces the whole group, from `base`.
                const argc = cache.operand(0);
                const group = argc + @as(u32, if (op == .call_method) 2 else 1);
                if (group > cache.sp - cache.stack_base) return vm.bug("stack underflow");
                const base = cache.sp - group;
                const args = cache.sp - argc;
                const receiver: ?Value = if (op == .call_method) vm.stack[base] else null;
                switch (vm.stack[args - 1]) {
                    // A built-in native *borrows* the argument slice: valid only during the call; it
                    // cannot call back into JS, so the stack cannot move under it. A host native
                    // (D53) receives temporary handles owned by its native-call record. If either
                    // fails, nothing has been popped: the stack is still a valid pre-call state (D35).
                    .native => |n| {
                        cache.syncSp(vm);
                        const this_obj: ?Value = if (receiver) |r| (if (r.isObjectLike()) r else null) else null;
                        const result = (if (n.host) |h|
                            h.call(rt, h.ctx, this_obj, vm.stack[args..cache.sp])
                        else
                            n.call(rt, receiver orelse .undefined, vm.stack[args..cache.sp])) catch |e| {
                            if (e != error.Internal and rt.exec_ctx.active and rt.exec_ctx.budget_fault != null)
                                return rt.limit(.steps);
                            return e;
                        };
                        if (rt.exec_ctx.active and rt.exec_ctx.budget_fault != null)
                            return rt.limit(.steps);
                        vm.stack[base] = result;
                        cache.sp = base + 1;
                    },
                    .closure => |c| switch (c.impl) {
                        .promise_cap => |cap| {
                            cache.syncSp(vm);
                            vm.stack[base] = try @import("../runtime/builtins.zig").callPromiseCapability(rt, cap.promise, cap.is_reject, vm.stack[args..cache.sp]);
                            cache.sp = base + 1;
                        },
                        .native_closure => |nc| {
                            cache.syncSp(vm);
                            const f: *const fn (*Runtime, *heap.Object, []const Value) Error!Value = @ptrCast(@alignCast(nc.func));
                            vm.stack[base] = try f(rt, nc.env, vm.stack[args..cache.sp]);
                            cache.sp = base + 1;
                        },
                        .bound => |b| {
                            cache.syncSp(vm);
                            if (try vm.callBound(b, base, vm.stack[args..cache.sp], next)) {
                                cache.* = FrameCache.fromVm(vm, 0);
                                return .running;
                            }
                            cache.sp = base + 1;
                        },
                        .vm => |v_impl| {
                            // Sloppy JS would box a primitive receiver; ZQJS leaves `this` unset.
                            const this: ?Value = if (receiver) |r| (if (r.isObjectLike()) r else null) else null;
                            cache.syncSp(vm);
                            const callee_proto: *const Proto = @ptrCast(@alignCast(v_impl.proto));
                            if (callee_proto.is_async) {
                                vm.stack[base] = try vm.startAsyncFromVm(c, this, vm.stack[args..cache.sp]);
                                cache.sp = base + 1;
                            } else {
                                try vm.enter(c, base, args, argc, next, this, false, false, null);
                                cache.* = FrameCache.fromVm(vm, 0);
                                return .running; // pc is the callee's 0
                            }
                        },
                        .tree => return vm.bug("a non-VM closure in the VM"),
                    },
                    .object => |o| {
                        if (o.kind != .proxy or !o.kind.proxy.is_callable) return rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }});
                        cache.syncSp(vm);
                        vm.stack[base] = try builtins.callProxy(rt, o, receiver orelse .undefined, vm.stack[args..cache.sp]);
                        cache.sp = base + 1;
                    },
                    else => return rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }}),
                }
            },
            .@"return" => {
                if (vm.frames.items.len < 2) {
                    // A nested call's body returned (D51): the value is the call's
                    // result, and the call ends here — no caller frame to unwind to.
                    if (vm.nested and vm.frames.items.len == 1) {
                        const ret_v = try cache.peek(vm, 0);
                        const f = vm.frame();
                        cache.syncSp(vm);
                        vm.nested_result = if (f.is_construct and !ret_v.isObjectLike()) f.this.? else ret_v;
                        vm.halted = true;
                        return .halted;
                    }
                    return vm.bug("return in the script");
                }
                const ret_v = try cache.peek(vm, 0);
                const cur_f = vm.frame();
                const v: Value = if (!cur_f.is_construct)
                    ret_v
                else if (cur_f.proto.has_super_ctor) blk: {
                    if (ret_v.isObjectLike()) break :blk ret_v;
                    if (ret_v == .undefined) {
                        break :blk cur_f.this orelse return rt.throw(.ReferenceError, &.{.{ .ascii = "Must call super constructor in derived class before accessing 'this' or returning from derived constructor" }});
                    }
                    return rt.throw(.TypeError, &.{.{ .ascii = "Derived constructors may only return object or undefined" }});
                } else if (!ret_v.isObjectLike())
                    .{ .object = cur_f.construct_instance.? }
                else
                    ret_v;
                const f = vm.frames.pop().?;
                if (f.is_super_call) {
                    vm.frames.items[vm.frames.items.len - 1].this = v;
                }
                if (vm.chain) |cx| cx.call_depth -= 1; // the frame died (D51 #2)
                vm.locals_len = f.locals_base;
                vm.reserved -= f.proto.slot_count + f.proto.max_stack;
                vm.sp = f.result_index;
                vm.stack[vm.sp] = v; // replaces the callee (and receiver); arguments and callee operands are gone
                vm.sp += 1;
                vm.pc = f.return_pc;
                if (f.is_super_call) {
                    if (vm.frames.items[vm.frames.items.len - 1].closure) |dc| {
                        try builtins.runInstanceInits(rt, @constCast(dc), v);
                    }
                }
                cache.* = FrameCache.fromVm(vm, f.return_pc);
                return .running;
            },
            .halt => {
                if (vm.frames.items.len != 1) return vm.bug("halt in a function");
                if (cache.sp != 0) return vm.bug("stack not empty at halt");
                vm.halted = true;
                return .halted; // pc stays on `halt`
            },
            .await => {
                const v = try cache.peek(vm, 0);
                cache.sp -= 1;
                cache.syncSp(vm);
                vm.pc = pc;
                vm.awaited = v;
                return .awaiting;
            },
            .throw => {
                const v = try cache.peek(vm, 0);
                return rt.throwValue(v);
            },
        }
        if (next >= code.len) return vm.bug("pc outside the code");
        vm.pc = next;
        cache.pc = next;
        return .running;
    }

    // ---- cold opcodes & calls (outlined to keep `Vm.run` small and `FrameCache` in registers)

    /// Executes cold/rare opcodes out-of-line. Returns `true` if a new VM frame was entered.
    noinline fn executeCold(vm: *Vm, op: Op, pc: u32, next: u32) Error!bool {
        @branchHint(.cold);
        const rt = vm.rt;
        var cache = FrameCache.fromVm(vm, pc);
        const p = cache.p;
        switch (op) {
            .new_regexp => {
                const k_pat = cache.operand(0);
                const k_flags = cache.operand(1);
                if (k_pat >= p.consts.len or k_flags >= p.consts.len) return vm.bug("constant index out of range");
                const pat_val = p.consts[k_pat];
                const flags_val = p.consts[k_flags];
                if (pat_val != .string or flags_val != .string) return vm.bug("new_regexp operand is not a string");
                try cache.ensurePush(vm);
                const re = try builtins.newRegExpFromStrings(rt, pat_val.string, flags_val.string);
                try cache.push(vm, re);
            },
            .get_template_obj => {
                const idx = cache.operand(0);
                if (idx >= p.templates.len) return vm.bug("template index out of range");
                const site = &p.templates[idx];
                try cache.ensurePush(vm);
                const obj = try builtins.getTemplateObjectFromConsts(rt, @intFromPtr(site), site.cooked, site.raw, p.consts);
                try cache.push(vm, obj);
            },
            .setup_class => {
                const has_super = cache.operand(0) != 0;
                const super_val = try cache.peek(vm, 0);
                const ctor_val = try cache.peek(vm, 1);
                const proto_obj = try builtins.setupClass(rt, ctor_val, has_super, super_val);
                try cache.drop(vm, 1);
                try cache.push(vm, .{ .object = proto_obj });
            },
            .define_method => {
                const method_val = try cache.peek(vm, 0);
                const target = try cache.peek(vm, 1);
                try builtins.defineClassMethod(rt, target, try vm.nameKey(cache.operand(0)), method_val);
                try cache.drop(vm, 1);
            },
            .define_elem_method => {
                cache.syncSp(vm);
                const method_val = try cache.peek(vm, 0);
                const key_val = try cache.peek(vm, 1);
                const target = try cache.peek(vm, 2);
                try builtins.defineClassMethod(rt, target, try object.key(rt, key_val), method_val);
                try cache.drop(vm, 2);
            },
            .define_accessor => {
                const fn_val = try cache.peek(vm, 0);
                const target = try cache.peek(vm, 1);
                const flags = cache.operand(1);
                const is_setter = (flags & 1) != 0;
                const enumerable = (flags & 2) != 0;
                if (fn_val != .closure) return vm.bug("define_accessor expects closure");
                try rt.heap.storeClosureHomeObject(@constCast(fn_val.closure), target);
                try object.defineAccessor(rt, target, try vm.nameKey(cache.operand(0)), fn_val, is_setter, enumerable);
                try cache.drop(vm, 1);
            },
            .define_elem_accessor => {
                cache.syncSp(vm);
                const fn_val = try cache.peek(vm, 0);
                const key_val = try cache.peek(vm, 1);
                const target = try cache.peek(vm, 2);
                const flags = cache.operand(0);
                const is_setter = (flags & 1) != 0;
                const enumerable = (flags & 2) != 0;
                if (fn_val != .closure) return vm.bug("define_elem_accessor expects closure");
                try rt.heap.storeClosureHomeObject(@constCast(fn_val.closure), target);
                try object.defineAccessor(rt, target, try object.key(rt, key_val), fn_val, is_setter, enumerable);
                try cache.drop(vm, 2);
            },
            .define_private_method => {
                const fn_val = try cache.peek(vm, 0);
                const target = try cache.peek(vm, 1);
                if (fn_val != .closure or target != .closure) return vm.bug("define_private_method expects closures");
                try rt.heap.storeClosureHomeObject(@constCast(fn_val.closure), target);
                try rt.heap.storeClosureBrand(@constCast(fn_val.closure), target);
                const name_str = (try vm.nameKey(cache.operand(0))).atom;
                try object.definePrivateMethod(rt, target, target.closure, name_str, fn_val);
                try cache.drop(vm, 1);
            },
            .define_private_accessor => {
                const fn_val = try cache.peek(vm, 0);
                const target = try cache.peek(vm, 1);
                if (fn_val != .closure or target != .closure) return vm.bug("define_private_accessor expects closures");
                try rt.heap.storeClosureHomeObject(@constCast(fn_val.closure), target);
                try rt.heap.storeClosureBrand(@constCast(fn_val.closure), target);
                const name_str = (try vm.nameKey(cache.operand(0))).atom;
                const is_setter = (cache.operand(1) & 1) != 0;
                try object.definePrivateAccessor(rt, target, target.closure, name_str, fn_val, is_setter);
                try cache.drop(vm, 1);
            },
            .define_public_field => {
                cache.syncSp(vm);
                const val = try cache.peek(vm, 0);
                const key_val = try cache.peek(vm, 1);
                const target = try cache.peek(vm, 2);
                try object.definePublicField(rt, target, try object.key(rt, key_val), val);
                try cache.drop(vm, 2);
            },
            .define_private_field => {
                const val = try cache.peek(vm, 0);
                const target = try cache.peek(vm, 1);
                const brand_val = if (target == .closure) target else (vm.frame().closure.?.meta.?.brand orelse return vm.bug("define_private_field without brand"));
                const name_str = (try vm.nameKey(cache.operand(0))).atom;
                try object.definePrivateField(rt, target, brand_val.closure, name_str, val);
                try cache.drop(vm, 1);
            },
            .get_private => {
                const brand_val = vm.frame().closure.?.meta.?.brand orelse return vm.bug("get_private without brand");
                const name_str = (try vm.nameKey(cache.operand(0))).atom;
                const r = try object.getPrivate(rt, try cache.peek(vm, 0), brand_val.closure, name_str);
                (try cache.top(vm)).* = r;
            },
            .set_private => {
                const v = try cache.peek(vm, 0);
                const brand_val = vm.frame().closure.?.meta.?.brand orelse return vm.bug("set_private without brand");
                const name_str = (try vm.nameKey(cache.operand(0))).atom;
                try object.setPrivate(rt, try cache.peek(vm, 1), brand_val.closure, name_str, v);
                try cache.drop(vm, 1);
                (try cache.top(vm)).* = v;
            },
            .in_private => {
                const brand_val = vm.frame().closure.?.meta.?.brand orelse return vm.bug("in_private without brand");
                const name_str = (try vm.nameKey(cache.operand(0))).atom;
                const b = try object.hasPrivate(rt, try cache.peek(vm, 0), brand_val.closure, name_str);
                (try cache.top(vm)).* = .{ .boolean = b };
            },
            .store_field_key => {
                const key_val = try cache.peek(vm, 0);
                const ctor_val = try cache.peek(vm, 1);
                if (ctor_val != .closure) return vm.bug("store_field_key expects closure");
                try rt.heap.appendClosureFieldKey(@constCast(ctor_val.closure), key_val);
                try cache.drop(vm, 1);
            },
            .add_instance_init => {
                const fn_val = try cache.peek(vm, 0);
                const ctor_val = try cache.peek(vm, 1);
                if (ctor_val != .closure) return vm.bug("add_instance_init expects closure");
                const packed_op = cache.operand(1);
                const kind: @FieldType(heap.InstanceInit, "kind") = @fromBackingInt(@intCast(@as(u8, @intCast(packed_op >> 16))));
                const key_idx: u32 = packed_op & 0xffff;
                const name_str: ?*heap.String = if (kind == .public_field) null else (try vm.nameKey(cache.operand(0))).atom;
                if (fn_val == .closure) {
                    const proto_val = (ctor_val.closure.meta orelse return vm.bug("add_instance_init without meta")).prototype orelse return vm.bug("add_instance_init without prototype");
                    try rt.heap.storeClosureHomeObject(@constCast(fn_val.closure), proto_val);
                    try rt.heap.storeClosureBrand(@constCast(fn_val.closure), ctor_val);
                }
                try rt.heap.appendClosureInstanceInit(@constCast(ctor_val.closure), .{
                    .kind = kind,
                    .name = name_str,
                    .key_idx = key_idx,
                    .func = fn_val,
                });
                try cache.drop(vm, 1);
            },
            .run_static_init => {
                const fn_val = try cache.peek(vm, 0);
                const ctor_val = try cache.peek(vm, 1);
                if (fn_val != .closure or ctor_val != .closure) return vm.bug("run_static_init expects closures");
                try rt.heap.storeClosureHomeObject(@constCast(fn_val.closure), ctor_val);
                try rt.heap.storeClosureBrand(@constCast(fn_val.closure), ctor_val);
                const r = try rt.callCallable(fn_val, ctor_val, &.{});
                try cache.drop(vm, 1);
                (try cache.top(vm)).* = r;
            },
            .set_brand => {
                const fn_val = try cache.peek(vm, 0);
                const ctor_val = try cache.peek(vm, 1);
                if (fn_val != .closure or ctor_val != .closure) return vm.bug("set_brand expects closures");
                try rt.heap.storeClosureBrand(@constCast(fn_val.closure), ctor_val);
                try cache.drop(vm, 1);
                (try cache.top(vm)).* = fn_val;
            },
            .super_call => {
                const argc = cache.operand(0);
                const args_start = cache.sp - argc;
                const base = args_start;
                cache.syncSp(vm);
                if (try vm.callSuper(base, vm.stack[args_start..cache.sp], false, next)) return true;
                cache.sp = base + 1;
            },
            .super_call_spread => {
                const arr_val = try cache.peek(vm, 0);
                const base = cache.sp - 1;
                if (arr_val != .object or arr_val.object.kind != .array) return vm.bug("super_call_spread expects array");
                cache.syncSp(vm);
                if (try vm.callSuper(base, arr_val.object.kind.array.items, true, next)) return true;
                cache.sp = base + 1;
            },
            .super_get_prop => {
                cache.syncSp(vm);
                const this_val = try vm.requireThis();
                const home = vm.frame().closure.?.meta.?.home_object orelse return vm.bug("super_get_prop without home_object");
                try cache.ensurePush(vm);
                try cache.push(vm, try object.getSuper(rt, home, this_val, try vm.nameKey(cache.operand(0))));
            },
            .super_get_elem => {
                cache.syncSp(vm);
                const this_val = try vm.requireThis();
                const home = vm.frame().closure.?.meta.?.home_object orelse return vm.bug("super_get_elem without home_object");
                const k = try object.key(rt, try cache.peek(vm, 0));
                (try cache.top(vm)).* = try object.getSuper(rt, home, this_val, k);
            },
            .super_set_prop => {
                cache.syncSp(vm);
                const this_val = try vm.requireThis();
                const home = vm.frame().closure.?.meta.?.home_object orelse return vm.bug("super_set_prop without home_object");
                const val = try cache.peek(vm, 0);
                try object.setSuper(rt, home, this_val, try vm.nameKey(cache.operand(0)), val);
            },
            .super_set_elem => {
                cache.syncSp(vm);
                const this_val = try vm.requireThis();
                const home = vm.frame().closure.?.meta.?.home_object orelse return vm.bug("super_set_elem without home_object");
                const val = try cache.peek(vm, 0);
                const key_val = try cache.peek(vm, 1);
                const k = try object.key(rt, key_val);
                try object.setSuper(rt, home, this_val, k, val);
                try cache.drop(vm, 1);
                (try cache.top(vm)).* = val;
            },
            .throw_delete_super => return rt.throw(.ReferenceError, &.{.{ .ascii = "Unsupported reference to 'super'" }}),
            .delete_prop => {
                cache.syncSp(vm);
                const r = try object.delete(rt, try cache.peek(vm, 0), try vm.nameKey(cache.operand(0)));
                (try cache.top(vm)).* = .{ .boolean = r };
            },
            .delete_elem => {
                cache.syncSp(vm);
                const k = try object.key(rt, try cache.peek(vm, 0));
                const r = try object.delete(rt, try cache.peek(vm, 1), k);
                try cache.drop(vm, 1);
                (try cache.top(vm)).* = .{ .boolean = r };
            },
            .rest_array => {
                const start_idx = cache.operand(0);
                const f = vm.frame();
                const arr = try rt.heap.newArray((try builtins.realm(rt)).array_prototype);
                if (start_idx < f.argc) {
                    const args_start = f.args_start + start_idx;
                    const rest_len = f.argc - start_idx;
                    try rt.heap.appendElements(arr, vm.stack[args_start..][0..rest_len]);
                }
                try cache.push(vm, .{ .object = arr });
            },
            .array_spread => {
                const arr_v = try cache.peek(vm, 1);
                const iterable = try cache.peek(vm, 0);
                if (arr_v != .object or arr_v.object.kind != .array) return vm.bug("array_spread on non-array");
                const iter = try builtins.getIterator(rt, iterable);
                var root_buf = [_]Value{ arr_v, .{ .object = iter } };
                var val_roots: rt_mod.ValueRoots = .{ .values = &root_buf };
                try val_roots.register(rt);
                defer val_roots.unregister(rt);
                while (try builtins.iteratorNextVal(rt, iter)) |elem| {
                    try rt.heap.appendElement(arr_v.object, elem);
                }
                try cache.drop(vm, 1);
            },
            .object_spread => {
                cache.syncSp(vm);
                const obj_v = try cache.peek(vm, 1);
                const src = try cache.peek(vm, 0);
                if (obj_v != .object) return vm.bug("object_spread on non-object");
                try copyDataProperties(rt, obj_v.object, src, &.{});
                try cache.drop(vm, 1);
            },
            .iter_rest => {
                const iter_val = try cache.peek(vm, 0);
                if (iter_val != .object or iter_val.object.kind != .iterator) return vm.bug("iter_rest on non-iterator");
                const arr = try rt.heap.newArray((try builtins.realm(rt)).array_prototype);
                var root_buf = [_]Value{ iter_val, .{ .object = arr } };
                var val_roots: rt_mod.ValueRoots = .{ .values = &root_buf };
                try val_roots.register(rt);
                defer val_roots.unregister(rt);
                while (try builtins.iteratorNextVal(rt, iter_val.object)) |elem| {
                    try rt.heap.appendElement(arr, elem);
                }
                vm.stack[cache.sp - 1] = .{ .object = arr };
            },
            .require_obj => {
                const v = try cache.peek(vm, 0);
                if (v == .undefined or v == .null) {
                    return rt.throw(.TypeError, &.{ .{ .ascii = "Cannot destructure '" }, .{ .ascii = @tagName(v) }, .{ .ascii = "'" } });
                }
            },
            .object_rest => {
                cache.syncSp(vm);
                const n = cache.operand(0);
                const group = n + 1;
                if (group > cache.sp - cache.stack_base) return vm.bug("stack underflow");
                const base = cache.sp - group;
                const src = vm.stack[base];
                const excluded = try rt.gpa.alloc(object.Key, n);
                defer rt.gpa.free(excluded);
                for (vm.stack[base + 1 .. cache.sp], excluded, 0..) |kv, *dst, idx| {
                    const k = try object.key(rt, kv);
                    dst.* = k;
                    // Keep converted atom/symbol keys rooted on the VM stack across subsequent conversions.
                    vm.stack[base + 1 + idx] = switch (k) {
                        .atom => |a| .{ .string = a },
                        .symbol => |s| .{ .symbol = s },
                        .index => .undefined,
                    };
                }
                const rest_obj = try rt.heap.newObject((try builtins.realm(rt)).object_prototype);
                try copyDataProperties(rt, rest_obj, src, excluded);
                vm.stack[base] = .{ .object = rest_obj };
                cache.sp = base + 1;
            },
            .new_call_spread => {
                cache.syncSp(vm);
                const callee = try cache.peek(vm, 1);
                const args_v = try cache.peek(vm, 0);
                if (args_v != .object or args_v.object.kind != .array) return vm.bug("new_call_spread args not array");
                const base = cache.sp - 2;
                if (try vm.callConstruct(base, callee, 0, args_v.object.kind.array.items, true, next)) return true;
                cache.sp = base + 1;
            },
            .call_spread, .call_method_spread => {
                cache.syncSp(vm);
                const is_method = op == .call_method_spread;
                const group: u32 = if (is_method) 3 else 2;
                if (group > cache.sp - cache.stack_base) return vm.bug("stack underflow");
                const base = cache.sp - group;
                const receiver: ?Value = if (is_method) vm.stack[base] else null;
                const callee = vm.stack[cache.sp - 2];
                const args_v = vm.stack[cache.sp - 1];
                if (args_v != .object or args_v.object.kind != .array) return vm.bug("call_spread args not array");
                const args_slice = args_v.object.kind.array.items;
                switch (callee) {
                    .native => |n| {
                        const this_obj: ?Value = if (receiver) |r| (if (r.isObjectLike()) r else null) else null;
                        const result = (if (n.host) |h|
                            h.call(rt, h.ctx, this_obj, args_slice)
                        else
                            n.call(rt, receiver orelse .undefined, args_slice)) catch |e| {
                            if (e != error.Internal and rt.exec_ctx.active and rt.exec_ctx.budget_fault != null)
                                return rt.limit(.steps);
                            return e;
                        };
                        if (rt.exec_ctx.active and rt.exec_ctx.budget_fault != null)
                            return rt.limit(.steps);
                        vm.stack[base] = result;
                        cache.sp = base + 1;
                    },
                    .closure => |c| switch (c.impl) {
                        .promise_cap => |cap| {
                            vm.stack[base] = try builtins.callPromiseCapability(rt, cap.promise, cap.is_reject, args_slice);
                            cache.sp = base + 1;
                        },
                        .native_closure => |nc| {
                            const f: *const fn (*Runtime, *heap.Object, []const Value) Error!Value = @ptrCast(@alignCast(nc.func));
                            vm.stack[base] = try f(rt, nc.env, args_slice);
                            cache.sp = base + 1;
                        },
                        .bound => |b| {
                            if (try vm.callBound(b, base, args_slice, next)) return true;
                            cache.sp = base + 1;
                        },
                        .vm => |v_impl| {
                            const this: ?Value = if (receiver) |r| (if (r.isObjectLike()) r else null) else null;
                            const callee_proto: *const Proto = @ptrCast(@alignCast(v_impl.proto));
                            if (callee_proto.is_async) {
                                vm.stack[base] = try vm.startAsyncFromVm(c, this, args_slice);
                                cache.sp = base + 1;
                            } else {
                                try vm.enterSlice(c, base, args_slice, next, this, false, false, null);
                                return true;
                            }
                        },
                        .tree => return vm.bug("a non-VM closure in the VM"),
                    },
                    .object => |o| {
                        if (o.kind != .proxy or !o.kind.proxy.is_callable) return rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }});
                        vm.stack[base] = try builtins.callProxy(rt, o, receiver orelse .undefined, args_slice);
                        cache.sp = base + 1;
                    },
                    else => return rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }}),
                }
            },
            .generator_start, .yield => {
                // Suspends with `pc` on the instruction; the resume steps past it (D67).
                var v: Value = .undefined;
                if (op == .yield) {
                    v = try cache.peek(vm, 0);
                    try cache.drop(vm, 1);
                }
                cache.syncSp(vm);
                vm.pc = pc;
                vm.awaited = v;
                vm.yield_raw = op == .yield and cache.operand(0) != 0;
                vm.yielding = true;
                return true;
            },
            .yield_star_step => {
                const iter_val = try cache.peek(vm, 2);
                const mode_val = try cache.peek(vm, 0);
                if (iter_val != .object or iter_val.object.kind != .iterator or mode_val != .number) return vm.bug("yield_star_step operands");
                const mode: coroutine.ResumeMode = switch (@as(u32, @intFromFloat(mode_val.number))) {
                    0 => .next,
                    1 => .throw,
                    else => .@"return",
                };
                const r = try builtins.yieldStarStep(rt, iter_val.object, try cache.peek(vm, 1), mode);
                try cache.drop(vm, 3);
                try cache.push(vm, r.value);
                try cache.push(vm, .{ .number = @floatFromInt(@backingInt(r.kind)) });
            },
            .get_async_iter => {
                const rec = try builtins.getAsyncIterator(rt, try cache.peek(vm, 0));
                vm.stack[cache.sp - 1] = .{ .object = rec };
            },
            .async_iter_next => {
                const rec = try cache.peek(vm, 0);
                if (rec != .object or rec.object.kind != .iterator) return vm.bug("async_iter_next on a non-iterator");
                vm.stack[cache.sp - 1] = try builtins.asyncIterNext(rt, rec.object);
            },
            .async_iter_result => {
                const v = try builtins.asyncIterValue(rt, try cache.peek(vm, 0));
                vm.stack[cache.sp - 1] = v orelse .undefined;
                try cache.push(vm, .{ .boolean = v == null });
            },
            .async_iter_close, .async_iter_close_throw => {
                const rec = try cache.peek(vm, 0);
                var res: ?Value = null;
                if (rec != .undefined) {
                    if (rec != .object or rec.object.kind != .iterator) return vm.bug("async_iter_close on a non-iterator");
                    res = try builtins.asyncIterCloseStart(rt, rec.object, op == .async_iter_close_throw);
                }
                vm.stack[cache.sp - 1] = res orelse .undefined;
                try cache.push(vm, .{ .boolean = res != null });
            },
            .async_iter_close_check => {
                try builtins.asyncIterCloseCheck(rt, try cache.peek(vm, 0));
                try cache.drop(vm, 1);
            },
            .async_yield_star_call => {
                const rec = try cache.peek(vm, 2);
                const mode_val = try cache.peek(vm, 0);
                if (rec != .object or rec.object.kind != .iterator or mode_val != .number) return vm.bug("async_yield_star_call operands");
                const mode: coroutine.ResumeMode = switch (@as(u32, @intFromFloat(mode_val.number))) {
                    0 => .next,
                    1 => .throw,
                    else => .@"return",
                };
                const r = try builtins.asyncYieldStarCall(rt, rec.object, try cache.peek(vm, 1), mode);
                try cache.drop(vm, 3);
                try cache.push(vm, .{ .number = @floatFromInt(@backingInt(r.kind)) });
                try cache.push(vm, r.value);
            },
            .async_yield_star_result => {
                const kind_val = try cache.peek(vm, 1);
                if (kind_val != .number or !(kind_val.number >= 0 and kind_val.number <= 3)) return vm.bug("async_yield_star_result operands");
                const kind: @FieldType(builtins.AsyncYieldStar, "kind") = @fromBackingInt(@intCast(@as(u8, @intFromFloat(kind_val.number))));
                const r = try builtins.asyncYieldStarResult(rt, kind, try cache.peek(vm, 0));
                vm.stack[cache.sp - 2] = r.value;
                vm.stack[cache.sp - 1] = .{ .number = @floatFromInt(@backingInt(r.kind)) };
            },
            .iter_close, .iter_close_throw => {
                const iter_val = try cache.peek(vm, 0);
                if (iter_val != .undefined) {
                    if (iter_val != .object or iter_val.object.kind != .iterator) return vm.bug("iter_close on non-iterator");
                    try builtins.iteratorClose(rt, iter_val.object, op == .iter_close_throw);
                }
                try cache.drop(vm, 1);
            },
            else => unreachable,
        }
        cache.syncSp(vm);
        return false;
    }

    // Keep FrameCache out of non-inlined helpers so LLVM keeps `cache` in registers (e2b1fd2).
    noinline fn callBound(vm: *Vm, b: *const heap.BoundClosure, base: u32, call_args: []const Value, next: u32) Error!bool {
        const rt = vm.rt;
        const combined = try rt.gpa.alloc(Value, b.bound_args.len + call_args.len);
        defer rt.gpa.free(combined);
        @memcpy(combined[0..b.bound_args.len], b.bound_args);
        @memcpy(combined[b.bound_args.len..], call_args);

        switch (b.target) {
            .native => |n| {
                const this_obj: ?Value = if (b.bound_this.isObjectLike()) b.bound_this else null;
                const result = (if (n.host) |h|
                    h.call(rt, h.ctx, this_obj, combined)
                else
                    n.call(rt, b.bound_this, combined)) catch |e| {
                    if (e != error.Internal and rt.exec_ctx.active and rt.exec_ctx.budget_fault != null)
                        return rt.limit(.steps);
                    return e;
                };
                if (rt.exec_ctx.active and rt.exec_ctx.budget_fault != null)
                    return rt.limit(.steps);
                vm.stack[base] = result;
                return false;
            },
            .closure => |tc| switch (tc.impl) {
                .promise_cap => |cap| {
                    vm.stack[base] = try builtins.callPromiseCapability(rt, cap.promise, cap.is_reject, combined);
                    return false;
                },
                .native_closure => |nc| {
                    const f: *const fn (*Runtime, *heap.Object, []const Value) Error!Value = @ptrCast(@alignCast(nc.func));
                    vm.stack[base] = try f(rt, nc.env, combined);
                    return false;
                },
                .vm => |v_impl| {
                    const this: ?Value = if (b.bound_this.isObjectLike()) b.bound_this else null;
                    const callee_proto: *const Proto = @ptrCast(@alignCast(v_impl.proto));
                    if (callee_proto.is_async) {
                        vm.stack[base] = try vm.startAsyncFromVm(tc, this, combined);
                        return false;
                    }
                    try vm.enterSlice(tc, base, combined, next, this, false, false, null);
                    return true;
                },
                .tree, .bound => return vm.bug("invalid bound target in the VM"),
            },
            .object => |o| {
                if (o.kind != .proxy or !o.kind.proxy.is_callable) return rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }});
                vm.stack[base] = try builtins.callProxy(rt, o, b.bound_this, combined);
                return false;
            },
            else => return rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }}),
        }
    }

    noinline fn callConstruct(vm: *Vm, base: u32, callee: Value, args_start: u32, args_slice: []const Value, is_spread: bool, next: u32) Error!bool {
        const rt = vm.rt;
        var target = callee;
        var new_target = callee;
        var combined: []Value = &.{};
        defer if (combined.len > 0) rt.gpa.free(combined);

        if (callee == .closure and callee.closure.impl == .bound) {
            const b = callee.closure.impl.bound;
            target = b.target;
            new_target = b.target;
            if (b.bound_args.len > 0) {
                combined = try rt.gpa.alloc(Value, b.bound_args.len + args_slice.len);
                @memcpy(combined[0..b.bound_args.len], b.bound_args);
                @memcpy(combined[b.bound_args.len..], args_slice);
            }
        }
        const effective_args = if (combined.len > 0) combined else args_slice;
        if (!builtins.isConstructor(target)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }});
        }
        if (target == .object) {
            vm.stack[base] = try builtins.callProxyConstruct(rt, target.object, effective_args, new_target);
            return false;
        }
        if (target == .native) {
            const result = try builtins.construct(rt, target, effective_args);
            vm.stack[base] = result;
            return false;
        }
        const tc = target.closure;
        const tc_proto: *const Proto = switch (tc.impl) {
            .vm => |v| @ptrCast(@alignCast(v.proto)),
            else => return vm.bug("a non-VM closure in the VM"),
        };
        const proto_val = try object.get(rt, target, try object.named(rt, "prototype"));
        const r = try builtins.realm(rt);
        const instance = try rt.heap.newObject(if (proto_val == .object) proto_val.object else r.object_prototype);
        const init_this: ?Value = if (tc_proto.has_super_ctor) null else .{ .object = instance };
        if (!is_spread and combined.len == 0) {
            try vm.enter(tc, base, args_start, @intCast(args_slice.len), next, init_this, true, false, instance);
        } else {
            try vm.enterSlice(tc, base, effective_args, next, init_this, true, false, instance);
        }
        return true;
    }

    fn requireThis(vm: *Vm) Error!Value {
        const f = vm.frame();
        if (f.this) |t| return t;
        if (f.proto.has_super_ctor) {
            return vm.rt.throw(.ReferenceError, &.{.{ .ascii = "Must call super constructor in derived class before accessing 'this' or returning from derived constructor" }});
        }
        return vm.rt.fail(.sloppy_this);
    }

    noinline fn callSuper(vm: *Vm, base: u32, args_slice: []const Value, is_spread: bool, next: u32) Error!bool {
        const rt = vm.rt;
        const f = vm.frame();
        if (f.this != null) {
            return rt.throw(.ReferenceError, &.{.{ .ascii = "Super constructor may only be called once" }});
        }
        const cur_closure = f.closure orelse return vm.bug("super() without closure");
        var target = try object.getPrototypeOfValue(rt, .{ .closure = cur_closure });
        var combined: []Value = &.{};
        defer if (combined.len > 0) rt.gpa.free(combined);

        if (target == .closure and target.closure.impl == .bound) {
            const b = target.closure.impl.bound;
            target = b.target;
            if (b.bound_args.len > 0) {
                combined = try rt.gpa.alloc(Value, b.bound_args.len + args_slice.len);
                @memcpy(combined[0..b.bound_args.len], b.bound_args);
                @memcpy(combined[b.bound_args.len..], args_slice);
            }
        }
        const effective_args = if (combined.len > 0) combined else args_slice;
        if (!builtins.isConstructor(target)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Super constructor is not a constructor" }});
        }
        const inst = f.construct_instance orelse return vm.bug("super() without construct_instance");
        if (target == .object) {
            const res = try builtins.callProxyConstruct(rt, target.object, effective_args, .{ .closure = cur_closure });
            vm.frames.items[vm.frames.items.len - 1].this = res;
            vm.stack[base] = res;
            vm.sp = base + 1;
            try builtins.runInstanceInits(rt, @constCast(cur_closure), res);
            return false;
        }
        if (target == .native) {
            const res = try builtins.construct(rt, target, effective_args);
            if (res == .object) rt.heap.storeObjectProto(res.object, inst.proto);
            vm.frames.items[vm.frames.items.len - 1].this = res;
            vm.stack[base] = res;
            vm.sp = base + 1;
            try builtins.runInstanceInits(rt, @constCast(cur_closure), res);
            return false;
        }
        const tc = target.closure;
        const tc_proto: *const Proto = switch (tc.impl) {
            .vm => |v| @ptrCast(@alignCast(v.proto)),
            else => return vm.bug("a non-VM closure in the VM"),
        };
        const child_this: ?Value = if (tc_proto.has_super_ctor) null else .{ .object = inst };
        if (!is_spread and combined.len == 0) {
            try vm.enter(tc, base, base, @intCast(args_slice.len), next, child_this, true, true, inst);
        } else {
            try vm.enterSlice(tc, base, effective_args, next, child_this, true, true, inst);
        }
        return true;
    }

    /// Enters closure `c`: its `argc` arguments start at `stack[args]`, and the result will
    /// replace everything from `stack[base]`. Transactional: everything that can fail
    /// happens before anything is committed.
    fn enter(vm: *Vm, c: *const Closure, base: u32, args: u32, argc: u32, return_pc: u32, this: ?Value, is_construct: bool, is_super_call: bool, construct_instance: ?*heap.Object) Error!void {
        c.obj.checkLive();
        const v = switch (c.impl) {
            .vm => |v| v,
            .tree, .promise_cap, .native_closure, .bound => return vm.bug("a non-VM closure in the VM"),
        };
        const callee: *const Proto = @ptrCast(@alignCast(v.proto));
        if (!is_construct and callee.is_class_constructor) {
            return vm.rt.throw(.TypeError, &.{.{ .ascii = "Class constructor cannot be invoked without 'new'" }});
        }
        const effective_this: ?Value = if (callee.is_arrow) (if (c.meta) |m| m.lexical_this else null) else this;
        const limits = vm.rt.limits;
        // 1. limits — a chained VM checks the chain's shared depth (D51 #2: every VM's
        // frames plus every native record, one `max_call_depth` across the chain); a
        // chain-less VM (the CLI) checks its own frames.
        if (vm.chain) |cx| {
            if (cx.call_depth >= limits.max_call_depth) return vm.rt.limit(.call_depth);
        } else if (vm.frames.items.len >= limits.max_call_depth) return vm.rt.limit(.call_depth);
        if (vm.reserved + callee.slot_count + callee.max_stack > limits.max_stack_slots) return vm.rt.limit(.stack_slots);
        // 2. capacity (may move the stacks: fine, everything is an index)
        if (vm.frames.items.len == vm.frames.capacity) try vm.growFrames();
        const need_locals = @as(usize, vm.locals_len) + callee.slot_count;
        const need_stack: usize = vm.stackEnd(callee);
        if (build_options.stack_stress or need_locals > vm.locals.len or need_stack > vm.stack.len) {
            try vm.reserve(callee);
        }
        // 3. the callee's locals, above locals_len (not live yet, so nothing visible changes)
        vm.initLocals(callee, vm.stack[args..][0..argc]);
        // 4. commit
        vm.frames.appendAssumeCapacity(.{
            .proto = callee,
            .closure = c,
            .return_pc = return_pc,
            .locals_base = vm.locals_len,
            .stack_base = vm.sp,
            .result_index = base,
            .this = effective_this,
            .stack_end = vm.stackEnd(callee),
            .args_start = args,
            .argc = argc,
            .is_construct = is_construct,
            .is_super_call = is_super_call,
            .construct_instance = construct_instance,
        });
        vm.locals_len += callee.slot_count;
        vm.reserved += callee.slot_count + callee.max_stack;
        vm.pc = 0;
        if (vm.chain) |cx| cx.call_depth += 1; // the frame is live now (D51 #2)
        if (is_construct and !callee.has_super_ctor) {
            try builtins.runInstanceInits(vm.rt, @constCast(c), .{ .object = construct_instance.? });
        }
    }

    fn enterSlice(vm: *Vm, c: *const Closure, base: u32, args_slice: []const Value, return_pc: u32, this: ?Value, is_construct: bool, is_super_call: bool, construct_instance: ?*heap.Object) Error!void {
        c.obj.checkLive();
        const v = switch (c.impl) {
            .vm => |v| v,
            .tree, .promise_cap, .native_closure, .bound => return vm.bug("a non-VM closure in the VM"),
        };
        const callee: *const Proto = @ptrCast(@alignCast(v.proto));
        if (!is_construct and callee.is_class_constructor) {
            return vm.rt.throw(.TypeError, &.{.{ .ascii = "Class constructor cannot be invoked without 'new'" }});
        }
        const effective_this: ?Value = if (callee.is_arrow) (if (c.meta) |m| m.lexical_this else null) else this;
        const limits = vm.rt.limits;
        if (vm.chain) |cx| {
            if (cx.call_depth >= limits.max_call_depth) return vm.rt.limit(.call_depth);
        } else if (vm.frames.items.len >= limits.max_call_depth) return vm.rt.limit(.call_depth);
        const argc: u32 = @intCast(args_slice.len);
        if (vm.reserved + callee.slot_count + callee.max_stack > limits.max_stack_slots) return vm.rt.limit(.stack_slots);
        if (vm.frames.items.len == vm.frames.capacity) try vm.growFrames();
        const need_locals = @as(usize, vm.locals_len) + callee.slot_count;
        const need_stack: usize = vm.stackEndWithExtra(callee, argc);
        if (build_options.stack_stress or need_locals > vm.locals.len or need_stack > vm.stack.len) {
            try vm.reserveWithExtra(callee, argc);
        }
        const args_start = vm.sp;
        if (argc > 0) @memcpy(vm.stack[args_start..][0..argc], args_slice);
        vm.sp = args_start + argc;
        vm.initLocals(callee, vm.stack[args_start..][0..argc]);
        vm.frames.appendAssumeCapacity(.{
            .proto = callee,
            .closure = c,
            .return_pc = return_pc,
            .locals_base = vm.locals_len,
            .stack_base = vm.sp,
            .result_index = base,
            .this = effective_this,
            .stack_end = vm.stackEnd(callee),
            .args_start = args_start,
            .argc = argc,
            .is_construct = is_construct,
            .is_super_call = is_super_call,
            .construct_instance = construct_instance,
        });
        vm.locals_len += callee.slot_count;
        vm.reserved += callee.slot_count + callee.max_stack;
        vm.pc = 0;
        if (vm.chain) |cx| cx.call_depth += 1;
        if (is_construct and !callee.has_super_ctor) {
            try builtins.runInstanceInits(vm.rt, @constCast(c), .{ .object = construct_instance.? });
        }
    }

    noinline fn growFrames(vm: *Vm) Error!void {
        @branchHint(.cold);
        try vm.frames.ensureUnusedCapacity(vm.rt.gpa, 1);
    }

    /// Makes room for a frame of `p` above the current locals and operands. Grows
    /// geometrically; on failure the old stacks are untouched. With -Dstack-stress, moves
    /// both stacks to fresh allocations every time, so stale indices or slices would
    /// show up at once.
    noinline fn reserve(vm: *Vm, p: *const Proto) Error!void {
        return vm.reserveWithExtra(p, 0);
    }

    noinline fn reserveWithExtra(vm: *Vm, p: *const Proto, extra_stack: u32) Error!void {
        @branchHint(.cold);
        const gpa = vm.rt.gpa;
        const need_locals = @as(usize, vm.locals_len) + p.slot_count;
        const need_stack: usize = vm.stackEndWithExtra(p, extra_stack);
        if (build_options.stack_stress) {
            const locals = try gpa.alloc(Slot, need_locals);
            errdefer gpa.free(locals);
            const stack = try gpa.alloc(Value, need_stack);
            @memcpy(locals[0..vm.locals_len], vm.locals[0..vm.locals_len]);
            @memcpy(stack[0..vm.sp], vm.stack[0..vm.sp]);
            gpa.free(vm.locals);
            gpa.free(vm.stack);
            vm.locals = locals;
            vm.stack = stack;
            return;
        }
        if (need_locals > vm.locals.len) vm.locals = try gpa.realloc(vm.locals, @max(need_locals, vm.locals.len * 2));
        if (need_stack > vm.stack.len) vm.stack = try gpa.realloc(vm.stack, @max(need_stack, vm.stack.len * 2));
    }

    /// Operand stack size needed with a frame of `p` on top: its region, and the regions
    /// of every frame below it (found by the stress mode, whose exact-size copies would
    /// otherwise drop the caller's unused reservation).
    fn stackEnd(vm: *const Vm, p: *const Proto) u32 {
        return vm.stackEndWithExtra(p, 0);
    }

    fn stackEndWithExtra(vm: *const Vm, p: *const Proto, extra: u32) u32 {
        const below: u32 = if (vm.frames.items.len > 0) vm.frame().stack_end else 0;
        return @max(below, vm.sp + extra + p.max_stack);
    }

    /// Initialises the `p.slot_count` locals above locals_len: the parameters (slots
    /// param_slot…) from `args` (missing ones are undefined, extra ones ignored),
    /// everything else in the TDZ.
    fn initLocals(vm: *Vm, p: *const Proto, args: []const Value) void {
        std.debug.assert(@as(u64, p.param_slot) + p.param_count <= p.slot_count);
        const dst = vm.locals[vm.locals_len..][0..p.slot_count];
        const ps = p.param_slot;
        const pe = ps + p.param_count;
        const copy_n = @min(p.param_count, args.len);
        @memset(dst[0..ps], .{ .value = null });
        for (dst[ps..][0..copy_n], args[0..copy_n]) |*s, arg| s.* = .{ .value = arg };
        @memset(dst[ps + copy_n .. pe], .{ .value = .undefined });
        @memset(dst[pe..], .{ .value = null });
    }

    // ---- checked accessors (see "Defensive checks"). Every one either returns its
    // result or, on a failed check, poisons the runtime and returns `error.Internal`
    // before anything it guards was touched (D35, D49).

    fn cellIn(vm: *const Vm, s: *const Slot) Error!*Cell {
        return switch (s.*) {
            .cell => |c| blk: {
                c.obj.checkLive(); // stress builds: a collected cell
                break :blk c;
            },
            .value => return vm.bug("cell access to a value slot"),
        };
    }

    fn capture(vm: *const Vm, i: u32) Error!*Cell {
        const c = vm.frame().closure orelse return vm.bug("capture access in the script");
        const caps = c.impl.vm.captures;
        if (i >= caps.len) return vm.bug("capture index out of range");
        caps[i].obj.checkLive();
        return caps[i];
    }

    fn name(vm: *const Vm, i: u32) Error![]const u8 {
        if (i >= vm.proto().names.len) return vm.bug("name index out of range");
        return vm.proto().names[i];
    }

    fn nameKey(vm: *const Vm, i: u32) Error!object.Key {
        const p = vm.proto();
        if (i < p.name_atoms.len) return object.namedAtom(p.name_atoms[i]);
        return object.named(vm.rt, try vm.name(i));
    }

    fn tdz(vm: *Vm, name_index: u32) Error {
        return vm.rt.throw(.ReferenceError, &.{ .{ .ascii = "Cannot access '" }, .{ .ascii = try vm.name(name_index) }, .{ .ascii = "' before initialization" } });
    }

    fn constAssignment(vm: *Vm) Error {
        return vm.rt.throw(.TypeError, &.{.{ .ascii = "Assignment to constant variable." }});
    }

    /// Two-phase JS exception unwind: scans active frames for a matching `try` handler
    /// before mutating any frame/stack state, so uncaught exceptions preserve exact
    /// faulting PC, stack, and frames.
    noinline fn unwind(vm: *Vm, fault_pc: u32) Error!void {
        @branchHint(.cold);
        var match_frame: ?usize = null;
        var match_handler: Proto.ExceptionHandler = undefined;
        var fi: usize = vm.frames.items.len;
        while (fi > 0) {
            fi -= 1;
            const check_pc: u32 = if (fi == vm.frames.items.len - 1) fault_pc else vm.frames.items[fi + 1].return_pc - 1;
            for (vm.frames.items[fi].proto.handlers) |h| {
                if (h.try_start <= check_pc and check_pc < h.try_end) {
                    match_frame = fi;
                    match_handler = h;
                    break;
                }
            }
            if (match_frame != null) break;
        }
        const target_frame = match_frame orelse return error.Thrown;
        const caught: ?Value = if (match_handler.has_binding) try vm.rt.catchValue() else blk: {
            vm.rt.clearThrown();
            break :blk null;
        };
        while (vm.frames.items.len - 1 > target_frame) {
            const popped = vm.frames.pop().?;
            if (vm.chain) |cx| cx.call_depth -= 1;
            vm.locals_len = popped.locals_base;
            vm.reserved -= popped.proto.slot_count + popped.proto.max_stack;
        }
        vm.sp = vm.frame().stack_base + match_handler.stack_depth;
        if (caught) |v| {
            vm.stack[vm.sp] = v;
            vm.sp += 1;
        }
        vm.pc = match_handler.catch_pc;
    }

    /// A defensive check failed (D49): poison the runtime and return `error.Internal`.
    /// The compare that called this has run; nothing else has changed.
    noinline fn bug(vm: *const Vm, comptime what: []const u8) Error {
        @branchHint(.cold);
        return vm.rt.bug(what);
    }
};

fn keyEq(a: object.Key, b: object.Key) bool {
    return switch (a) {
        .index => |ia| b == .index and b.index == ia,
        .atom => |aa| b == .atom and b.atom == aa,
        .symbol => |sa| b == .symbol and b.symbol == sa,
    };
}

fn keyIn(k: object.Key, list: []const object.Key) bool {
    for (list) |ex| if (keyEq(k, ex)) return true;
    return false;
}

fn copyDataProperties(rt: *Runtime, dst: *heap.Object, src: Value, excluded: []const object.Key) Error!void {
    switch (src) {
        .string => |s| {
            for (0..s.units.len) |i| {
                const k: object.Key = .{ .index = @intCast(i) };
                if (keyIn(k, excluded)) continue;
                const ch = try rt.heap.newString(&.{.{ .utf16 = s.units[i..][0..1] }});
                try object.define(rt, dst, k, .{ .string = ch });
            }
        },
        .object, .closure => {
            const keys = if (src == .object)
                try object.ownAllKeys(rt, src.object)
            else
                try object.ownAllKeysClosure(rt, src.closure);
            defer rt.gpa.free(keys);
            const root_vals = try rt.gpa.alloc(Value, 2 + keys.len);
            defer rt.gpa.free(root_vals);
            root_vals[0] = .{ .object = dst };
            root_vals[1] = src;
            for (keys, root_vals[2..]) |k, *rv| rv.* = switch (k) {
                .atom => |a| .{ .string = a },
                .symbol => |s| .{ .symbol = s },
                .index => .undefined,
            };
            var roots: rt_mod.ValueRoots = .{ .values = root_vals };
            try roots.register(rt);
            defer roots.unregister(rt);

            for (keys) |k| {
                if (keyIn(k, excluded)) continue;
                const v = try object.get(rt, src, k);
                try object.define(rt, dst, k, v);
            }
        },
        .undefined, .null, .boolean, .number, .bigint, .symbol, .native => {},
    }
}

fn fastArrayGet(base: Value, idx: Value) ?Value {
    if (base != .object or idx != .number) return null;
    const o = base.object;
    if (o.kind != .array) return null;
    const n = idx.number;
    const elems = o.kind.array.items;
    if (!(n >= 0 and n < @as(f64, @floatFromInt(elems.len)) and @floor(n) == n)) return null;
    o.obj.checkLive();
    const r = elems[@intFromFloat(n)];
    heap.checkValue(r);
    return r;
}

fn fastTypedArrayGet(base: Value, idx: Value) ?Value {
    if (base != .object or idx != .number) return null;
    const o = base.object;
    if (o.kind != .typed_array) return null;
    const ta = o.kind.typed_array;
    if (ta.kind.isBigInt() or ta.buffer.kind.array_buffer.detached) return null;
    const n = idx.number;
    if (!(n >= 0 and n < @as(f64, @floatFromInt(ta.length)) and @floor(n) == n)) return null;
    o.obj.checkLive();
    return object.readTypedArrayNumber(ta, @intFromFloat(n));
}

fn fastTypedArraySet(base: Value, idx: Value, val: Value) bool {
    if (base != .object or idx != .number or val != .number) return false;
    const o = base.object;
    if (o.kind != .typed_array) return false;
    const ta = o.kind.typed_array;
    if (ta.kind.isBigInt() or ta.buffer.kind.array_buffer.detached) return false;
    const n = idx.number;
    if (!(n >= 0 and n < @as(f64, @floatFromInt(ta.length)) and @floor(n) == n)) return false;
    o.obj.checkLive();
    object.writeTypedArrayNumber(ta, @intFromFloat(n), val.number);
    return true;
}

fn binaryOp(op: Op) BinaryOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .pow => .pow,
        .shl => .shl,
        .shr => .shr,
        .ushr => .ushr,
        .bit_and => .bit_and,
        .bit_xor => .bit_xor,
        .bit_or => .bit_or,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .strict_eq => .strict_eq,
        .strict_ne => .strict_ne,
        .in => .in,
        .instanceof => .instanceof,
        else => unreachable,
    };
}

/// M10.2c: fast exact-integer `%` when both operands are finite, integral, and within
/// `[-Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER]` with non-zero divisor. Preserves
/// JS dividend-sign remainder and `-0` (`-4 % 2`, `-0 % 5`), falling back to `ops.remainder`
/// for everything else.
inline fn fastRemainder(a: f64, b: f64) f64 {
    const max_safe: f64 = 9007199254740991.0; // 2^53 - 1
    if (-max_safe <= a and a <= max_safe and -max_safe <= b and b <= max_safe and b != 0) {
        const ai: i64 = @intFromFloat(a);
        const bi: i64 = @intFromFloat(b);
        if (@as(f64, @floatFromInt(ai)) == a and @as(f64, @floatFromInt(bi)) == b) {
            const r = @rem(ai, bi);
            if (r == 0) return if (std.math.signbit(a)) -0.0 else 0.0;
            return @floatFromInt(r);
        }
    }
    return ops.remainder(a, b);
}
