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
//! kept in every build mode, and a failure is a bug, so it panics (`bug`) rather than
//! producing a JavaScript-visible result.

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

    /// `script` must have passed `verify` and must outlive the VM (and every use of its
    /// closures). Allocates with `rt.gpa`; on failure nothing is left allocated.
    pub fn init(rt: *Runtime, script: *const Proto) Error!Vm {
        if (@as(u64, script.slot_count) + script.max_stack > rt.limits.max_stack_slots) return rt.limit(.stack_slots);
        var vm: Vm = .{ .rt = rt };
        errdefer vm.deinit();
        try vm.reserve(script);
        try vm.frames.ensureTotalCapacity(rt.gpa, 1);
        vm.initLocals(script, 0, 0);
        vm.frames.appendAssumeCapacity(.{ .proto = script, .closure = null, .return_pc = 0, .locals_base = 0, .stack_base = 0, .result_index = 0, .this = null, .stack_end = script.max_stack });
        vm.locals_len = script.slot_count;
        vm.reserved = script.slot_count + script.max_stack;
        return vm;
    }

    pub fn deinit(vm: *Vm) void {
        if (vm.rt.engine_roots) |e| if (e.ctx == @as(*anyopaque, vm)) {
            vm.rt.engine_roots = null; // no collection may scan a VM that is gone
        };
        const gpa = vm.rt.gpa;
        vm.frames.deinit(gpa);
        gpa.free(vm.locals);
        gpa.free(vm.stack);
        vm.* = undefined;
    }

    /// Runs to `halt` or the first error.
    pub fn run(vm: *Vm) Error!void {
        while (try vm.step() == .running) {}
    }

    /// The VM's roots (GC_DESIGN §4): the operand stack, the locals (values and cells), each
    /// frame's closure and `this`, and the script's Proto tree (its string constants; the
    /// Protos aren't heap objects, so the tree being run is what keeps them).
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
            vm.rt.engine_roots = .{ .ctx = vm, .mark = markRoots };
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
        if (pc >= code.len) vm.bug("pc outside the code");
        const op = Op.decode(code[pc]) orelse vm.bug("invalid opcode");
        if (op.size() > code.len - pc) vm.bug("instruction runs past the end of the code");
        try vm.rt.step();
        const rt = vm.rt;
        var next: u32 = pc + op.size();

        switch (op) {
            .push_undefined => vm.push(.undefined),
            .push_null => vm.push(.null),
            .push_true => vm.push(.{ .boolean = true }),
            .push_false => vm.push(.{ .boolean = false }),
            .push_const => {
                const k = vm.operand(0);
                if (k >= p.consts.len) vm.bug("constant index out of range");
                vm.push(p.consts[k]);
            },

            .get_local => {
                const v = vm.value(vm.operand(0)).* orelse return vm.tdz(vm.operand(1));
                vm.push(v);
            },
            .set_local => {
                const s = vm.value(vm.operand(0));
                if (s.* == null) return vm.tdz(vm.operand(1));
                s.* = vm.peek(0); // the assignment's value stays on the stack
            },
            .init_local => {
                vm.slot(vm.operand(0)).* = .{ .value = vm.peek(0) };
                vm.drop(1);
            },
            .clear_local => vm.slot(vm.operand(0)).* = .{ .value = null },
            .assign_const => {
                if (vm.value(vm.operand(0)).* == null) return vm.tdz(vm.operand(1));
                return vm.constAssignment();
            },
            .get_global => {
                vm.ensurePush();
                vm.push(try builtins.global(rt, vm.name(vm.operand(0))));
            },

            .new_cell => {
                const s = vm.slot(vm.operand(0));
                s.* = .{ .cell = try rt.heap.newCell(null) };
            },
            .box_local => {
                const s = vm.slot(vm.operand(0));
                const v = switch (s.*) {
                    .value => |v| v orelse vm.bug("boxing a slot in the TDZ"),
                    .cell => vm.bug("boxing a cell"),
                };
                s.* = .{ .cell = try rt.heap.newCell(v) };
            },
            .fresh_cell => {
                const s = vm.slot(vm.operand(0));
                const old = vm.cellIn(s);
                s.* = .{ .cell = try rt.heap.newCell(old.value) };
            },
            .get_cell => {
                const v = vm.cellAt(vm.operand(0)).value orelse return vm.tdz(vm.operand(1));
                vm.push(v);
            },
            .set_cell => {
                const c = vm.cellAt(vm.operand(0));
                if (c.value == null) return vm.tdz(vm.operand(1));
                rt.heap.storeCell(c, vm.peek(0));
            },
            .init_cell => {
                rt.heap.storeCell(vm.cellAt(vm.operand(0)), vm.peek(0));
                vm.drop(1);
            },
            .assign_const_cell => {
                if (vm.cellAt(vm.operand(0)).value == null) return vm.tdz(vm.operand(1));
                return vm.constAssignment();
            },
            .get_capture => {
                const v = vm.capture(vm.operand(0)).value orelse return vm.tdz(vm.operand(1));
                vm.push(v);
            },
            .set_capture => {
                const c = vm.capture(vm.operand(0));
                if (c.value == null) return vm.tdz(vm.operand(1));
                rt.heap.storeCell(c, vm.peek(0));
            },
            .assign_const_capture => {
                if (vm.capture(vm.operand(0)).value == null) return vm.tdz(vm.operand(1));
                return vm.constAssignment();
            },

            .make_closure => {
                const f = vm.operand(0);
                if (f >= p.functions.len) vm.bug("function index out of range");
                const child = &p.functions[f];
                vm.ensurePush();
                const c = try rt.heap.newVmClosure(child, child.captures.len);
                // Nothing below can fail: the closure is complete before it is pushed.
                for (child.captures, c.impl.vm.captures) |desc, *dst| dst.* = switch (desc.from) {
                    .parent_slot => vm.cellAt(desc.index),
                    .parent_capture => vm.capture(desc.index),
                };
                vm.push(.{ .closure = c });
            },
            .push_callee => vm.push(.{ .closure = vm.frame().closure orelse vm.bug("push_callee in the script") }),

            .pop => vm.drop(1),
            .dup => vm.push(vm.peek(0)),
            .dup2 => {
                const a = vm.peek(1);
                const b = vm.peek(0);
                vm.ensurePush2();
                vm.push(a);
                vm.push(b);
            },
            .rot3, .rot4 => {
                const n: u32 = if (op == .rot3) 3 else 4;
                const t = vm.peek(0);
                _ = vm.peek(n - 1); // underflow check
                const at = vm.sp - n;
                std.mem.copyBackwards(Value, vm.stack[at + 1 .. vm.sp], vm.stack[at .. vm.sp - 1]);
                vm.stack[at] = t;
            },

            // ---- objects: compute first (any of these can fail), then commit
            .new_object => {
                vm.ensurePush();
                const o = try rt.heap.newObject((try builtins.realm(rt)).object_prototype);
                vm.push(.{ .object = o });
            },
            .new_array => {
                const n = vm.operand(0);
                if (n > vm.sp - vm.frame().stack_base) vm.bug("stack underflow");
                const arr = try rt.heap.newArray((try builtins.realm(rt)).array_prototype);
                try rt.heap.appendElements(arr, vm.stack[vm.sp - n .. vm.sp]);
                vm.sp -= n;
                vm.push(.{ .object = arr });
            },
            .define_prop => {
                const o = vm.peek(1);
                if (o != .object) vm.bug("define on a non-object");
                try object.define(rt, o.object, try object.named(rt, vm.name(vm.operand(0))), vm.peek(0));
                vm.drop(1);
            },
            .define_elem => {
                const o = vm.peek(2);
                if (o != .object) vm.bug("define on a non-object");
                try object.define(rt, o.object, try object.key(rt, vm.peek(1)), vm.peek(0));
                vm.drop(2);
            },
            .get_prop => {
                const r = try object.get(rt, vm.peek(0), try object.named(rt, vm.name(vm.operand(0))));
                vm.top().* = r;
            },
            .get_elem => {
                const k = try object.key(rt, vm.peek(0));
                const r = try object.get(rt, vm.peek(1), k);
                vm.drop(1);
                vm.top().* = r;
            },
            .set_prop => {
                const v = vm.peek(0);
                try object.set(rt, vm.peek(1), try object.named(rt, vm.name(vm.operand(0))), v);
                vm.drop(1);
                vm.top().* = v;
            },
            .set_elem => {
                const v = vm.peek(0);
                const k = try object.key(rt, vm.peek(1)); // after the value: JS's order for `=`
                try object.set(rt, vm.peek(2), k, v);
                vm.drop(2);
                vm.top().* = v;
            },
            .delete_prop => {
                const r = try object.delete(rt, vm.peek(0), try object.named(rt, vm.name(vm.operand(0))));
                vm.top().* = .{ .boolean = r };
            },
            .delete_elem => {
                const k = try object.key(rt, vm.peek(0));
                const r = try object.delete(rt, vm.peek(1), k);
                vm.drop(1);
                vm.top().* = .{ .boolean = r };
            },
            .push_this => {
                vm.ensurePush();
                vm.push(vm.frame().this orelse return rt.fail(.sloppy_this));
            },

            .add, .sub, .mul, .div, .mod, .pow, .lt, .le, .gt, .ge, .strict_eq, .strict_ne, .in => {
                const r = try ops.binary(rt, binaryOp(op), vm.peek(1), vm.peek(0)); // into a local (see .neg)
                vm.drop(1);
                vm.top().* = r;
            },
            // Compute into a local, then store. `top().* = .{ .number = f(peek(0)) }` would
            // be wrong: Zig builds the union in place, so the slot's tag changes *before*
            // f reads the old value through peek (result-location aliasing).
            .neg, .to_number, .not => {
                const v = vm.peek(0);
                const r: Value = switch (op) {
                    .neg => .{ .number = -(try ops.toNumber(rt, v)) },
                    .to_number => .{ .number = try ops.toNumber(rt, v) },
                    .not => .{ .boolean = !ops.toBoolean(v) },
                    else => unreachable,
                };
                vm.top().* = r;
            },
            .inc, .dec => {
                const t = vm.top();
                if (t.* != .number) vm.bug("inc/dec on a non-number"); // always after to_number
                t.number += if (op == .inc) 1 else -1;
            },

            .jump => next = vm.target(),
            .jump_if_false, .jump_if_true => {
                const truthy = ops.toBoolean(vm.peek(0));
                vm.drop(1);
                if (truthy == (op == .jump_if_true)) next = vm.target();
            },
            .call, .call_method => {
                // Stack: [callee, args…] or [receiver, callee, args…], arguments in source
                // order. The result replaces the whole group, from `base`.
                const argc = vm.operand(0);
                const group = argc + @as(u32, if (op == .call_method) 2 else 1);
                if (group > vm.sp - vm.frame().stack_base) vm.bug("stack underflow");
                const base = vm.sp - group;
                const args = vm.sp - argc;
                const receiver: ?Value = if (op == .call_method) vm.stack[base] else null;
                switch (vm.stack[args - 1]) {
                    // The native *borrows* the argument slice: valid only during the call; it
                    // cannot call back into JS, so the stack cannot move under it. If it fails,
                    // nothing has been popped: the stack is still a valid pre-call state.
                    .native => |n| {
                        const result = try n.call(rt, receiver orelse .undefined, vm.stack[args..vm.sp]);
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
                if (vm.frames.items.len < 2) vm.bug("return in the script");
                const v = vm.peek(0);
                const f = vm.frames.pop().?;
                vm.locals_len = f.locals_base;
                vm.reserved -= f.proto.slot_count + f.proto.max_stack;
                vm.sp = f.result_index;
                vm.stack[vm.sp] = v; // replaces the callee (and receiver); arguments and callee operands are gone
                vm.sp += 1;
                vm.pc = f.return_pc;
                return .running;
            },
            .halt => {
                if (vm.frames.items.len != 1) vm.bug("halt in a function");
                if (vm.sp != 0) vm.bug("stack not empty at halt");
                vm.halted = true;
                return .halted; // pc stays on `halt`
            },
        }
        if (next >= code.len) vm.bug("pc outside the code");
        vm.pc = next;
        return .running;
    }

    // ---- calls

    /// Enters closure `c`: its `argc` arguments start at `stack[args]`, and the result will
    /// replace everything from `stack[base]`. Transactional: everything that can fail
    /// happens before anything is committed.
    fn enter(vm: *Vm, c: *const Closure, base: u32, args: u32, argc: u32, return_pc: u32, this: ?Value) Error!void {
        const v = switch (c.impl) {
            .vm => |v| v,
            .tree => vm.bug("a tree-walker closure in the VM"),
        };
        const callee: *const Proto = @ptrCast(@alignCast(v.proto));
        const limits = vm.rt.limits;
        // 1. limits
        if (vm.frames.items.len >= limits.max_call_depth) return vm.rt.limit(.call_depth);
        if (vm.reserved + callee.slot_count + callee.max_stack > limits.max_stack_slots) return vm.rt.limit(.stack_slots);
        // 2. capacity (may move the stacks: fine, everything is an index)
        try vm.frames.ensureUnusedCapacity(vm.rt.gpa, 1);
        try vm.reserve(callee);
        // 3. the callee's locals, above locals_len (not live yet, so nothing visible changes)
        vm.initLocals(callee, args, argc);
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
    /// param_slot…) from the `argc` values at stack[args…] (missing ones are undefined,
    /// extra ones ignored), everything else in the TDZ.
    fn initLocals(vm: *Vm, p: *const Proto, args: u32, argc: u32) void {
        for (vm.locals[vm.locals_len..][0..p.slot_count], 0..) |*s, n| {
            const i = @as(i64, @intCast(n)) - p.param_slot; // parameter number
            s.* = .{ .value = if (i >= 0 and i < p.param_count) (if (i < argc) vm.stack[args + @as(u32, @intCast(i))] else .undefined) else null };
        }
    }

    // ---- checked accessors (see "Defensive checks")

    fn operand(vm: *const Vm, i: usize) u32 {
        return bc.readU32(vm.proto().code, vm.pc + 1 + 4 * i); // instruction bounds checked in execute
    }

    fn target(vm: *const Vm) u32 {
        const t = vm.operand(0);
        if (t >= vm.proto().code.len) vm.bug("jump target outside the code");
        return t;
    }

    fn slot(vm: *Vm, i: u32) *Slot {
        if (i >= vm.proto().slot_count) vm.bug("slot index out of range");
        return &vm.locals[vm.frame().locals_base + i];
    }

    /// A plain (uncaptured) slot's value.
    fn value(vm: *Vm, i: u32) *?Value {
        return switch (vm.slot(i).*) {
            .value => |*v| v,
            .cell => vm.bug("value access to a cell slot"),
        };
    }

    fn cellIn(vm: *const Vm, s: *Slot) *Cell {
        return switch (s.*) {
            .cell => |c| c,
            .value => vm.bug("cell access to a value slot"),
        };
    }

    fn cellAt(vm: *Vm, i: u32) *Cell {
        return vm.cellIn(vm.slot(i));
    }

    fn capture(vm: *const Vm, i: u32) *Cell {
        const c = vm.frame().closure orelse vm.bug("capture access in the script");
        const caps = c.impl.vm.captures;
        if (i >= caps.len) vm.bug("capture index out of range");
        return caps[i];
    }

    fn name(vm: *const Vm, i: u32) []const u8 {
        if (i >= vm.proto().names.len) vm.bug("name index out of range");
        return vm.proto().names[i];
    }

    /// Stack room for one more operand in the current frame.
    fn ensurePush(vm: *const Vm) void {
        if (vm.sp >= vm.frame().stack_base + vm.proto().max_stack or vm.sp >= vm.stack.len) vm.bug("stack overflow");
    }

    fn ensurePush2(vm: *const Vm) void {
        if (vm.sp + 1 >= vm.frame().stack_base + vm.proto().max_stack or vm.sp + 1 >= vm.stack.len) vm.bug("stack overflow");
    }

    fn push(vm: *Vm, v: Value) void {
        vm.ensurePush();
        vm.stack[vm.sp] = v;
        vm.sp += 1;
    }

    /// The value `depth` places below the top (0 = top), within the current frame.
    fn peek(vm: *const Vm, depth: u32) Value {
        if (depth >= vm.sp - vm.frame().stack_base) vm.bug("stack underflow");
        return vm.stack[vm.sp - 1 - depth];
    }

    fn top(vm: *Vm) *Value {
        if (vm.sp == vm.frame().stack_base) vm.bug("stack underflow");
        return &vm.stack[vm.sp - 1];
    }

    fn drop(vm: *Vm, n: u32) void {
        if (n > vm.sp - vm.frame().stack_base) vm.bug("stack underflow");
        vm.sp -= n;
    }

    fn tdz(vm: *Vm, name_index: u32) Error {
        return vm.rt.throw(.ReferenceError, &.{ .{ .ascii = "Cannot access '" }, .{ .ascii = vm.name(name_index) }, .{ .ascii = "' before initialization" } });
    }

    fn constAssignment(vm: *Vm) Error {
        return vm.rt.throw(.TypeError, &.{.{ .ascii = "Assignment to constant variable." }});
    }

    fn bug(vm: *const Vm, comptime what: []const u8) noreturn {
        std.debug.panic("zqjs VM bug at pc {d}: " ++ what, .{vm.pc});
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
