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
const builtins = @import("../runtime/builtins.zig");
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
};

pub const Vm = struct {
    pub const State = enum { running, halted };

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
        vm.frames.appendAssumeCapacity(.{ .proto = script, .closure = null, .return_pc = 0, .locals_base = 0, .stack_base = 0, .result_index = 0, .this = null, .stack_end = script.max_stack });
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
        c.obj.checkLive();
        const v = switch (c.impl) {
            .vm => |v| v,
            .tree => return rt.bug("a tree-walker closure in a nested call"),
        };
        const callee: *const Proto = @ptrCast(@alignCast(v.proto));
        const argc: u32 = @intCast(args.len);
        if (@as(u64, argc) + callee.slot_count + callee.max_stack > rt.limits.max_stack_slots) return rt.limit(.stack_slots);
        var vm: Vm = .{ .rt = rt, .nested = true };
        errdefer vm.deinit();
        try vm.reserve(callee);
        try vm.frames.ensureTotalCapacity(rt.gpa, 1);
        vm.initLocals(callee, args);
        vm.frames.appendAssumeCapacity(.{
            .proto = callee,
            .closure = c,
            .return_pc = 0,
            .locals_base = 0,
            .stack_base = 0,
            .result_index = 0,
            .this = this,
            .stack_end = callee.max_stack,
        });
        vm.locals_len = callee.slot_count;
        vm.reserved = callee.slot_count + callee.max_stack;
        return vm;
    }

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

    inline fn runLoop(vm: *Vm, comptime bounded: bool, steps: u64) Error!State {
        if (vm.fault) |e| return e;
        if (vm.halted) return .halted;
        const rt = vm.rt;
        const h = &rt.heap;
        if (!vm.nested) rt.engine_roots = .{ .ctx = vm, .mark = markRoots };
        var n: u64 = 0;
        while (!bounded or n < steps) {
            if (h.collect_requested or h.collect_always) {
                rt.collect();
            }
            const state = @call(.always_inline, execute, .{vm}) catch |e| {
                vm.fault = e;
                return e;
            };
            if (state == .halted) return .halted;
            if (bounded) n += 1;
        }
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
        const vm: *Vm = @ptrCast(@alignCast(ctx));
        for (vm.stack[0..vm.sp]) |v| h.markValue(v);
        for (vm.locals[0..vm.locals_len]) |s| switch (s) {
            .value => |v| if (v) |x| h.markValue(x),
            .cell => |c| h.markObj(&c.obj),
        };
        for (vm.frames.items) |f| {
            if (f.closure) |c| h.markObj(@constCast(&c.obj));
            if (f.this) |t| h.markValue(t);
        }
        markProto(h, vm.frames.items[0].proto);
    }

    fn markProto(h: *heap.Heap, p: *const Proto) void {
        for (p.consts) |k| h.markValue(k);
        for (p.functions) |*f| markProto(h, f); // nesting depth is bounded by the AST's
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
        return vm.execute() catch |e| {
            vm.fault = e;
            return e;
        };
    }

    /// One instruction. Every path either fails before changing VM state, or commits
    /// its changes and then sets `pc` (see the contract above).
    fn execute(vm: *Vm) Error!State {
        const p = vm.proto();
        const code = p.code;
        const pc = vm.pc;
        if (pc >= code.len) return vm.bug("pc outside the code");
        const op = Op.decode(code[pc]) orelse return vm.bug("invalid opcode");
        if (op.size() > code.len - pc) return vm.bug("instruction runs past the end of the code");
        try vm.rt.step();
        const rt = vm.rt;
        var next: u32 = pc + op.size();

        switch (op) {
            .push_undefined => try vm.push(.undefined),
            .push_null => try vm.push(.null),
            .push_true => try vm.push(.{ .boolean = true }),
            .push_false => try vm.push(.{ .boolean = false }),
            .push_const => {
                const k = vm.operand(0);
                if (k >= p.consts.len) return vm.bug("constant index out of range");
                try vm.push(p.consts[k]);
            },

            .get_local => {
                const v = (try vm.value(vm.operand(0))).* orelse return vm.tdz(vm.operand(1));
                try vm.push(v);
            },
            .set_local => {
                const s = try vm.value(vm.operand(0));
                if (s.* == null) return vm.tdz(vm.operand(1));
                s.* = try vm.peek(0); // the assignment's value stays on the stack
            },
            .init_local => {
                (try vm.slot(vm.operand(0))).* = .{ .value = try vm.peek(0) };
                try vm.drop(1);
            },
            .clear_local => (try vm.slot(vm.operand(0))).* = .{ .value = null },
            .assign_const => {
                if ((try vm.value(vm.operand(0))).* == null) return vm.tdz(vm.operand(1));
                return vm.constAssignment();
            },
            .get_global => {
                try vm.ensurePush();
                try vm.push(try builtins.global(rt, try vm.name(vm.operand(0))));
            },

            .new_cell => {
                (try vm.slot(vm.operand(0))).* = .{ .cell = try rt.heap.newCell(null) };
            },
            .box_local => {
                const s = try vm.slot(vm.operand(0));
                const v: Value = switch (s.*) {
                    .value => |v| v orelse return vm.bug("boxing a slot in the TDZ"),
                    .cell => return vm.bug("boxing a cell"),
                };
                s.* = .{ .cell = try rt.heap.newCell(v) };
            },
            .fresh_cell => {
                const s = try vm.slot(vm.operand(0));
                const old = try vm.cellIn(s);
                s.* = .{ .cell = try rt.heap.newCell(old.value) };
            },
            .get_cell => {
                const v = (try vm.cellAt(vm.operand(0))).value orelse return vm.tdz(vm.operand(1));
                try vm.push(v);
            },
            .set_cell => {
                const c = try vm.cellAt(vm.operand(0));
                if (c.value == null) return vm.tdz(vm.operand(1));
                rt.heap.storeCell(c, try vm.peek(0));
            },
            .init_cell => {
                rt.heap.storeCell(try vm.cellAt(vm.operand(0)), try vm.peek(0));
                try vm.drop(1);
            },
            .assign_const_cell => {
                if ((try vm.cellAt(vm.operand(0))).value == null) return vm.tdz(vm.operand(1));
                return vm.constAssignment();
            },
            .get_capture => {
                const v = (try vm.capture(vm.operand(0))).value orelse return vm.tdz(vm.operand(1));
                try vm.push(v);
            },
            .set_capture => {
                const c = try vm.capture(vm.operand(0));
                if (c.value == null) return vm.tdz(vm.operand(1));
                rt.heap.storeCell(c, try vm.peek(0));
            },
            .assign_const_capture => {
                if ((try vm.capture(vm.operand(0))).value == null) return vm.tdz(vm.operand(1));
                return vm.constAssignment();
            },

            .make_closure => {
                const f = vm.operand(0);
                if (f >= p.functions.len) return vm.bug("function index out of range");
                const child = &p.functions[f];
                try vm.ensurePush();
                const c = try rt.heap.newVmClosure(child, child.captures.len);
                // Fills the captures. These accessors fail only on a bug (a real failure
                // would leave an incomplete closure on the heap, collected, never reachable).
                for (child.captures, c.impl.vm.captures) |desc, *dst| dst.* = switch (desc.from) {
                    .parent_slot => try vm.cellAt(desc.index),
                    .parent_capture => try vm.capture(desc.index),
                };
                try vm.push(.{ .closure = c });
            },
            .push_callee => {
                const c = vm.frame().closure orelse return vm.bug("push_callee in the script");
                try vm.push(.{ .closure = c });
            },

            .pop => try vm.drop(1),
            .dup => try vm.push(try vm.peek(0)),
            .dup2 => {
                const a = try vm.peek(1);
                const b = try vm.peek(0);
                try vm.ensurePush2();
                try vm.push(a);
                try vm.push(b);
            },
            .rot3, .rot4 => {
                const n: u32 = if (op == .rot3) 3 else 4;
                const t = try vm.peek(0);
                _ = try vm.peek(n - 1); // underflow check
                const at = vm.sp - n;
                std.mem.copyBackwards(Value, vm.stack[at + 1 .. vm.sp], vm.stack[at .. vm.sp - 1]);
                vm.stack[at] = t;
            },

            // ---- objects: compute first (any of these can fail), then commit
            .new_object => {
                try vm.ensurePush();
                const o = try rt.heap.newObject((try builtins.realm(rt)).object_prototype);
                try vm.push(.{ .object = o });
            },
            .new_array => {
                const n = vm.operand(0);
                if (n > vm.sp - vm.frame().stack_base) return vm.bug("stack underflow");
                const arr = try rt.heap.newArray((try builtins.realm(rt)).array_prototype);
                try rt.heap.appendElements(arr, vm.stack[vm.sp - n .. vm.sp]);
                vm.sp -= n;
                try vm.push(.{ .object = arr });
            },
            .define_prop => {
                const o = try vm.peek(1);
                if (o != .object) return vm.bug("define on a non-object");
                try object.define(rt, o.object, try object.named(rt, try vm.name(vm.operand(0))), try vm.peek(0));
                try vm.drop(1);
            },
            .define_elem => {
                const o = try vm.peek(2);
                if (o != .object) return vm.bug("define on a non-object");
                try object.define(rt, o.object, try object.key(rt, try vm.peek(1)), try vm.peek(0));
                try vm.drop(2);
            },
            .get_prop => {
                const r = try object.get(rt, try vm.peek(0), try object.named(rt, try vm.name(vm.operand(0))));
                (try vm.top()).* = r;
            },
            .get_elem => {
                const k = try object.key(rt, try vm.peek(0));
                const r = try object.get(rt, try vm.peek(1), k);
                try vm.drop(1);
                (try vm.top()).* = r;
            },
            .set_prop => {
                const v = try vm.peek(0);
                try object.set(rt, try vm.peek(1), try object.named(rt, try vm.name(vm.operand(0))), v);
                try vm.drop(1);
                (try vm.top()).* = v;
            },
            .set_elem => {
                const v = try vm.peek(0);
                const k = try object.key(rt, try vm.peek(1)); // after the value: JS's order for `=`
                try object.set(rt, try vm.peek(2), k, v);
                try vm.drop(2);
                (try vm.top()).* = v;
            },
            .delete_prop => {
                const r = try object.delete(rt, try vm.peek(0), try object.named(rt, try vm.name(vm.operand(0))));
                (try vm.top()).* = .{ .boolean = r };
            },
            .delete_elem => {
                const k = try object.key(rt, try vm.peek(0));
                const r = try object.delete(rt, try vm.peek(1), k);
                try vm.drop(1);
                (try vm.top()).* = .{ .boolean = r };
            },
            .push_this => {
                try vm.ensurePush();
                try vm.push(vm.frame().this orelse return rt.fail(.sloppy_this));
            },

            .add, .sub, .mul, .div, .mod, .pow, .lt, .le, .gt, .ge, .strict_eq, .strict_ne, .in => {
                // M10.2b/M10.2c: fast path when both operands are already `.number` (`f64`),
                // matching IEEE-754 / JS semantics for NaN, infinities, and -0. All mixed or
                // out-of-domain cases fall back to `ops.binary`.
                const lhs = try vm.peek(1);
                const rhs = try vm.peek(0);
                const r: Value = if (lhs == .number and rhs == .number) switch (op) {
                    .add => .{ .number = lhs.number + rhs.number },
                    .sub => .{ .number = lhs.number - rhs.number },
                    .mul => .{ .number = lhs.number * rhs.number },
                    .div => .{ .number = lhs.number / rhs.number },
                    .mod => .{ .number = fastRemainder(lhs.number, rhs.number) },
                    .lt => .{ .boolean = lhs.number < rhs.number },
                    .le => .{ .boolean = lhs.number <= rhs.number },
                    .gt => .{ .boolean = lhs.number > rhs.number },
                    .ge => .{ .boolean = lhs.number >= rhs.number },
                    .strict_eq => .{ .boolean = lhs.number == rhs.number },
                    .strict_ne => .{ .boolean = lhs.number != rhs.number },
                    .pow, .in => try ops.binary(rt, binaryOp(op), lhs, rhs),
                    else => unreachable,
                } else try ops.binary(rt, binaryOp(op), lhs, rhs);
                vm.sp -= 1;
                vm.stack[vm.sp - 1] = r;
            },
            // Compute into a local, then store. `top().* = .{ .number = f(peek(0)) }` would
            // be wrong: Zig builds the union in place, so the slot's tag changes *before*
            // f reads the old value through peek (result-location aliasing).
            .neg, .to_number, .not => {
                const v = try vm.peek(0);
                const r: Value = switch (op) {
                    .neg => .{ .number = if (v == .number) -v.number else -(try ops.toNumber(rt, v)) },
                    .to_number => if (v == .number) v else .{ .number = try ops.toNumber(rt, v) },
                    .not => .{ .boolean = !ops.toBoolean(v) },
                    else => unreachable,
                };
                (try vm.top()).* = r;
            },
            .inc, .dec => {
                const t = try vm.top();
                if (t.* != .number) return vm.bug("inc/dec on a non-number"); // always after to_number
                t.number += if (op == .inc) 1 else -1;
            },

            .jump => next = try vm.target(),
            .jump_if_false, .jump_if_true => {
                const truthy = ops.toBoolean(try vm.peek(0));
                try vm.drop(1);
                if (truthy == (op == .jump_if_true)) next = try vm.target();
            },
            .call, .call_method => {
                // Stack: [callee, args…] or [receiver, callee, args…], arguments in source
                // order. The result replaces the whole group, from `base`.
                const argc = vm.operand(0);
                const group = argc + @as(u32, if (op == .call_method) 2 else 1);
                if (group > vm.sp - vm.frame().stack_base) return vm.bug("stack underflow");
                const base = vm.sp - group;
                const args = vm.sp - argc;
                const receiver: ?Value = if (op == .call_method) vm.stack[base] else null;
                switch (vm.stack[args - 1]) {
                    // A built-in native *borrows* the argument slice: valid only during the call; it
                    // cannot call back into JS, so the stack cannot move under it. A host native
                    // (D53) receives temporary handles owned by its native-call record. If either
                    // fails, nothing has been popped: the stack is still a valid pre-call state (D35).
                    .native => |n| {
                        const this_obj: ?Value = if (receiver) |r| (if (r == .object) r else null) else null;
                        const result = (if (n.host) |h|
                            h.call(rt, h.ctx, this_obj, vm.stack[args..vm.sp])
                        else
                            n.call(rt, receiver orelse .undefined, vm.stack[args..vm.sp])) catch |e| {
                            if (e != error.Internal and rt.exec_ctx.active and rt.exec_ctx.budget_fault != null)
                                return rt.limit(.steps);
                            return e;
                        };
                        if (rt.exec_ctx.active and rt.exec_ctx.budget_fault != null)
                            return rt.limit(.steps);
                        vm.stack[base] = result;
                        vm.sp = base + 1;
                    },
                    .closure => |c| {
                        // Sloppy JS would box a primitive receiver; ZQJS leaves `this` unset.
                        const this: ?Value = if (receiver) |r| (if (r == .object) r else null) else null;
                        try vm.enter(c, base, args, argc, next, this);
                        return .running; // pc is the callee's 0
                    },
                    else => return rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }}),
                }
            },
            .@"return" => {
                if (vm.frames.items.len < 2) {
                    // A nested call's body returned (D51): the value is the call's
                    // result, and the call ends here — no caller frame to unwind to.
                    if (vm.nested and vm.frames.items.len == 1) {
                        const v = try vm.peek(0);
                        vm.nested_result = v;
                        vm.halted = true;
                        return .halted;
                    }
                    return vm.bug("return in the script");
                }
                const v = try vm.peek(0);
                const f = vm.frames.pop().?;
                if (vm.chain) |cx| cx.call_depth -= 1; // the frame died (D51 #2)
                vm.locals_len = f.locals_base;
                vm.reserved -= f.proto.slot_count + f.proto.max_stack;
                vm.sp = f.result_index;
                vm.stack[vm.sp] = v; // replaces the callee (and receiver); arguments and callee operands are gone
                vm.sp += 1;
                vm.pc = f.return_pc;
                return .running;
            },
            .halt => {
                if (vm.frames.items.len != 1) return vm.bug("halt in a function");
                if (vm.sp != 0) return vm.bug("stack not empty at halt");
                vm.halted = true;
                return .halted; // pc stays on `halt`
            },
        }
        if (next >= code.len) return vm.bug("pc outside the code");
        vm.pc = next;
        return .running;
    }

    // ---- calls

    /// Enters closure `c`: its `argc` arguments start at `stack[args]`, and the result will
    /// replace everything from `stack[base]`. Transactional: everything that can fail
    /// happens before anything is committed.
    fn enter(vm: *Vm, c: *const Closure, base: u32, args: u32, argc: u32, return_pc: u32, this: ?Value) Error!void {
        c.obj.checkLive();
        const v = switch (c.impl) {
            .vm => |v| v,
            .tree => return vm.bug("a tree-walker closure in the VM"),
        };
        const callee: *const Proto = @ptrCast(@alignCast(v.proto));
        const limits = vm.rt.limits;
        // 1. limits — a chained VM checks the chain's shared depth (D51 #2: every VM's
        // frames plus every native record, one `max_call_depth` across the chain); a
        // chain-less VM (the CLI) checks its own frames.
        if (vm.chain) |cx| {
            if (cx.call_depth >= limits.max_call_depth) return vm.rt.limit(.call_depth);
        } else if (vm.frames.items.len >= limits.max_call_depth) return vm.rt.limit(.call_depth);
        if (vm.reserved + callee.slot_count + callee.max_stack > limits.max_stack_slots) return vm.rt.limit(.stack_slots);
        // 2. capacity (may move the stacks: fine, everything is an index)
        try vm.frames.ensureUnusedCapacity(vm.rt.gpa, 1);
        try vm.reserve(callee);
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
            .this = this,
            .stack_end = vm.stackEnd(callee),
        });
        vm.locals_len += callee.slot_count;
        vm.reserved += callee.slot_count + callee.max_stack;
        vm.pc = 0;
        if (vm.chain) |cx| cx.call_depth += 1; // the frame is live now (D51 #2)
    }

    /// Makes room for a frame of `p` above the current locals and operands. Grows
    /// geometrically; on failure the old stacks are untouched. With -Dstack-stress, moves
    /// both stacks to fresh allocations every time, so stale indices or slices would
    /// show up at once.
    fn reserve(vm: *Vm, p: *const Proto) Error!void {
        const gpa = vm.rt.gpa;
        const need_locals = @as(usize, vm.locals_len) + p.slot_count;
        const need_stack: usize = vm.stackEnd(p);
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
        const below: u32 = if (vm.frames.items.len > 0) vm.frame().stack_end else 0;
        return @max(below, vm.sp + p.max_stack);
    }

    /// Initialises the `p.slot_count` locals above locals_len: the parameters (slots
    /// param_slot…) from `args` (missing ones are undefined, extra ones ignored),
    /// everything else in the TDZ.
    fn initLocals(vm: *Vm, p: *const Proto, args: []const Value) void {
        for (vm.locals[vm.locals_len..][0..p.slot_count], 0..) |*s, n| {
            const i = @as(i64, @intCast(n)) - p.param_slot; // parameter number
            s.* = .{ .value = if (i >= 0 and i < p.param_count) (if (i < args.len) args[@intCast(i)] else .undefined) else null };
        }
    }

    // ---- checked accessors (see "Defensive checks"). Every one either returns its
    // result or, on a failed check, poisons the runtime and returns `error.Internal`
    // before anything it guards was touched (D35, D49).

    fn operand(vm: *const Vm, i: usize) u32 {
        return bc.readU32(vm.proto().code, vm.pc + 1 + 4 * i); // instruction bounds checked in execute
    }

    fn target(vm: *const Vm) Error!u32 {
        const t = vm.operand(0);
        if (t >= vm.proto().code.len) return vm.bug("jump target outside the code");
        return t;
    }

    fn slot(vm: *Vm, i: u32) Error!*Slot {
        if (i >= vm.proto().slot_count) return vm.bug("slot index out of range");
        return &vm.locals[vm.frame().locals_base + i];
    }

    /// A plain (uncaptured) slot's value.
    fn value(vm: *Vm, i: u32) Error!*?Value {
        return switch ((try vm.slot(i)).*) {
            .value => |*v| v,
            .cell => return vm.bug("value access to a cell slot"),
        };
    }

    fn cellIn(vm: *const Vm, s: *const Slot) Error!*Cell {
        return switch (s.*) {
            .cell => |c| blk: {
                c.obj.checkLive(); // stress builds: a collected cell
                break :blk c;
            },
            .value => return vm.bug("cell access to a value slot"),
        };
    }

    fn cellAt(vm: *Vm, i: u32) Error!*Cell {
        return vm.cellIn(try vm.slot(i));
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

    /// Stack room for one more operand in the current frame.
    fn ensurePush(vm: *const Vm) Error!void {
        if (vm.sp >= vm.frame().stack_base + vm.proto().max_stack or vm.sp >= vm.stack.len) return vm.bug("stack overflow");
    }

    fn ensurePush2(vm: *const Vm) Error!void {
        if (vm.sp + 1 >= vm.frame().stack_base + vm.proto().max_stack or vm.sp + 1 >= vm.stack.len) return vm.bug("stack overflow");
    }

    fn push(vm: *Vm, v: Value) Error!void {
        try vm.ensurePush();
        vm.stack[vm.sp] = v;
        vm.sp += 1;
    }

    /// The value `depth` places below the top (0 = top), within the current frame.
    fn peek(vm: *const Vm, depth: u32) Error!Value {
        if (depth >= vm.sp - vm.frame().stack_base) return vm.bug("stack underflow");
        return vm.stack[vm.sp - 1 - depth];
    }

    fn top(vm: *Vm) Error!*Value {
        if (vm.sp == vm.frame().stack_base) return vm.bug("stack underflow");
        return &vm.stack[vm.sp - 1];
    }

    fn drop(vm: *Vm, n: u32) Error!void {
        if (n > vm.sp - vm.frame().stack_base) return vm.bug("stack underflow");
        vm.sp -= n;
    }

    fn tdz(vm: *Vm, name_index: u32) Error {
        return vm.rt.throw(.ReferenceError, &.{ .{ .ascii = "Cannot access '" }, .{ .ascii = try vm.name(name_index) }, .{ .ascii = "' before initialization" } });
    }

    fn constAssignment(vm: *Vm) Error {
        return vm.rt.throw(.TypeError, &.{.{ .ascii = "Assignment to constant variable." }});
    }

    /// A defensive check failed (D49): poison the runtime and return `error.Internal`.
    /// The compare that called this has run; nothing else has changed.
    fn bug(vm: *const Vm, comptime what: []const u8) Error {
        return vm.rt.bug(what);
    }
};

fn binaryOp(op: Op) BinaryOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .pow => .pow,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .strict_eq => .strict_eq,
        .strict_ne => .strict_ne,
        .in => .in,
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
