//! The stack VM: executes a verified Proto (bytecode/bytecode.zig).
//!
//! State: `pc` and `sp` are indices (never pointers, DESIGN_DECISIONS D12); `slots` are
//! the script's locals (`null` = TDZ, as in the tree-walker); `stack` is the operand
//! stack, sized `max_stack` once (M5 has no calls into JS, so it never grows).
//!
//! Semantics live in runtime/ops.zig, shared with the tree-walker (D16). This file only
//! moves values between the stack, the slots and those functions.
//!
//! `step()` contract (DESIGN_DECISIONS D35)
//!   * Executes exactly one instruction, charging one budget step *before* it.
//!   * `.running`: the instruction completed; `pc` is the next instruction.
//!   * `.halted`: `halt` executed. Further calls return `.halted` and do nothing.
//!   * An error (Thrown, LimitExceeded, Unsupported, OutOfMemory, WriteFailed) is
//!     *precise*: `pc` still points at the failing instruction and the operand stack and
//!     slots are exactly as before it. Details are on the Runtime (`exception`,
//!     `limitHit()`, `unsupported`). The VM is then faulted: further calls return the
//!     same error and execute nothing. (Side effects outside the VM, such as output a
//!     native already wrote, are not undone.)
//!
//! Defensive checks. The verifier rejects malformed bytecode; these checks catch bugs in
//! the VM or the verifier themselves: pc and instruction bounds, opcode validity, stack
//! underflow/overflow, slot, constant and name indices. They are cheap compares, kept in
//! every build mode, and a failure is a bug, so it panics (`bug`) rather than producing
//! a JavaScript-visible result. Remove them only if benchmarks justify it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../runtime/value.zig").Value;
const rt_mod = @import("../runtime/runtime.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const ops = @import("../runtime/ops.zig");
const globals = @import("../runtime/globals.zig");
const BinaryOp = @import("../frontend/ast.zig").BinaryOp;
const bc = @import("../bytecode/bytecode.zig");
const Op = bc.Op;
const Proto = bc.Proto;

pub const Vm = struct {
    pub const State = enum { running, halted };

    rt: *Runtime,
    proto: *const Proto,
    pc: u32 = 0,
    sp: u32 = 0,
    slots: []?Value,
    stack: []Value,
    halted: bool = false,
    fault: ?Error = null,

    /// `proto` must have passed `verify` and must outlive the VM. Allocates with `rt.gpa`;
    /// on failure nothing is left allocated.
    pub fn init(rt: *Runtime, proto: *const Proto) Allocator.Error!Vm {
        const slots = try rt.gpa.alloc(?Value, proto.slot_count);
        errdefer rt.gpa.free(slots);
        @memset(slots, null);
        const stack = try rt.gpa.alloc(Value, proto.max_stack);
        return .{ .rt = rt, .proto = proto, .slots = slots, .stack = stack };
    }

    pub fn deinit(vm: *Vm) void {
        vm.rt.gpa.free(vm.stack);
        vm.rt.gpa.free(vm.slots);
        vm.* = undefined;
    }

    /// Runs to `halt` or the first error.
    pub fn run(vm: *Vm) Error!void {
        while (try vm.step() == .running) {}
    }

    /// The operand stack, bottom first (for traces and tests).
    pub fn operands(vm: *const Vm) []const Value {
        return vm.stack[0..vm.sp];
    }

    pub fn step(vm: *Vm) Error!State {
        if (vm.fault) |e| return e;
        if (vm.halted) return .halted;
        return vm.execute() catch |e| {
            vm.fault = e;
            return e;
        };
    }

    /// One instruction. Every path either fails before changing VM state, or commits
    /// its stack/slot changes and then sets `pc` (see the contract above).
    fn execute(vm: *Vm) Error!State {
        const code = vm.proto.code;
        const pc = vm.pc;
        if (pc >= code.len) vm.bug("pc outside the code");
        const op = std.enums.fromInt(Op, code[pc]) orelse vm.bug("invalid opcode");
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
                if (k >= vm.proto.consts.len) vm.bug("constant index out of range");
                vm.push(vm.proto.consts[k]);
            },

            .get_local => {
                const v = vm.slot(vm.operand(0)).* orelse return vm.tdz(vm.operand(1));
                vm.push(v);
            },
            .set_local => {
                const s = vm.slot(vm.operand(0));
                if (s.* == null) return vm.tdz(vm.operand(1));
                s.* = vm.peek(0); // the assignment's value stays on the stack
            },
            .init_local => {
                vm.slot(vm.operand(0)).* = vm.peek(0);
                vm.drop(1);
            },
            .clear_local => vm.slot(vm.operand(0)).* = null,
            .assign_const => {
                if (vm.slot(vm.operand(0)).* == null) return vm.tdz(vm.operand(1));
                return rt.throw(.TypeError, &.{.{ .ascii = "Assignment to constant variable." }});
            },
            .get_global => {
                const n = vm.name(vm.operand(0));
                const v = globals.lookup(n) orelse return rt.throw(.ReferenceError, &.{ .{ .ascii = n }, .{ .ascii = " is not defined" } });
                vm.push(v);
            },

            .pop => vm.drop(1),
            .dup => vm.push(vm.peek(0)),

            .add, .sub, .mul, .div, .mod, .pow, .lt, .le, .gt, .ge, .strict_eq, .strict_ne => {
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
                    .neg => .{ .number = -(try ops.toNumber(rt.gpa, v)) },
                    .to_number => .{ .number = try ops.toNumber(rt.gpa, v) },
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
            .call => {
                // Stack: [callee, arg0 … arg(argc-1)], arguments in source order. The native
                // *borrows* the argument slice: it is valid only during the call and must not
                // be kept (M6's NativeCtx replaces it). If the native throws, nothing has been
                // popped, so the stack is still a valid pre-call state. On success, callee and
                // arguments are replaced by the result.
                const argc = vm.operand(0);
                if (argc >= vm.sp) vm.bug("stack underflow");
                const base = vm.sp - argc - 1;
                const callee = vm.stack[base];
                if (callee != .native) return rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }});
                const result = try callee.native.call(rt, vm.stack[base + 1 .. vm.sp]);
                vm.stack[base] = result;
                vm.sp = base + 1;
            },
            .halt => {
                if (vm.sp != 0) vm.bug("stack not empty at halt");
                vm.halted = true;
                return .halted; // pc stays on `halt`
            },
        }
        if (next >= code.len) vm.bug("pc outside the code");
        vm.pc = next;
        return .running;
    }

    // ---- checked accessors (see "Defensive checks")

    fn operand(vm: *const Vm, i: usize) u32 {
        return bc.readU32(vm.proto.code, vm.pc + 1 + 4 * i); // instruction bounds checked in execute
    }

    fn target(vm: *const Vm) u32 {
        const t = vm.operand(0);
        if (t >= vm.proto.code.len) vm.bug("jump target outside the code");
        return t;
    }

    fn slot(vm: *Vm, i: u32) *?Value {
        if (i >= vm.slots.len) vm.bug("slot index out of range");
        return &vm.slots[i];
    }

    fn name(vm: *const Vm, i: u32) []const u8 {
        if (i >= vm.proto.names.len) vm.bug("name index out of range");
        return vm.proto.names[i];
    }

    fn push(vm: *Vm, v: Value) void {
        if (vm.sp >= vm.stack.len) vm.bug("stack overflow");
        vm.stack[vm.sp] = v;
        vm.sp += 1;
    }

    /// The value `depth` places below the top (0 = top).
    fn peek(vm: *const Vm, depth: u32) Value {
        if (depth >= vm.sp) vm.bug("stack underflow");
        return vm.stack[vm.sp - 1 - depth];
    }

    fn top(vm: *Vm) *Value {
        if (vm.sp == 0) vm.bug("stack underflow");
        return &vm.stack[vm.sp - 1];
    }

    fn drop(vm: *Vm, n: u32) void {
        if (n > vm.sp) vm.bug("stack underflow");
        vm.sp -= n;
    }

    fn tdz(vm: *Vm, name_index: u32) Error {
        return vm.rt.throw(.ReferenceError, &.{ .{ .ascii = "Cannot access '" }, .{ .ascii = vm.name(name_index) }, .{ .ascii = "' before initialization" } });
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
        else => unreachable,
    };
}
