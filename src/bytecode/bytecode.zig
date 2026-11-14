//! The bytecode format: instruction set, encoding and the compiled script (`Proto`).
//! Shared by the compiler, the verifier, the disassembler and (M5) the VM, so the
//! format is defined exactly once: `Op.info()` is the single table of operands and
//! stack effects.
//!
//! Encoding
//! --------
//! A byte stream. Each instruction is a 1-byte opcode followed by its operands, each a
//! little-endian u32. u32 does not make limits unnecessary: code size and pool sizes
//! are bounded by `Limits.max_code_bytes` / `max_constants`, enforced by the compiler
//! and checked again by the verifier (DESIGN_DECISIONS D32).
//!
//! Operand kinds
//!   slot    index into the frame's local slots (< Proto.slot_count)
//!   const   index into Proto.consts
//!   name    index into Proto.names (variable names, for globals and error messages)
//!   target  absolute byte offset of the jump destination (an instruction start)
//!   argc    number of call arguments
//!
//! Stack discipline: every statement leaves the operand stack as it found it (empty),
//! every expression pushes exactly one value. `max_stack` is the deepest the stack
//! gets; the M5 VM reserves it once on entry and pushes without bounds checks
//! (DESIGN_DECISIONS D12), which is only sound because the verifier checks it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../runtime/value.zig").Value;

pub const Operand = enum { slot, @"const", name, target, argc };

pub const Op = enum(u8) {
    // ---- constants: push one value
    push_undefined,
    push_null,
    push_true,
    push_false,
    /// Push consts[k] (a number or a string).
    push_const,

    // ---- locals. `name` is only used in error messages.
    /// Push slot s; ReferenceError if it is in the TDZ.
    get_local,
    /// Store the top of the stack into slot s and *keep* it (the value of an assignment
    /// expression); ReferenceError if s is in the TDZ.
    set_local,
    /// Pop into slot s: initialises a declaration, so no TDZ or const check.
    init_local,
    /// Put slot s back into the TDZ: emitted on entering a block, so a re-entered loop
    /// body doesn't see the previous iteration's values.
    clear_local,
    /// A write to a `const` binding (known at compile time). Throws: ReferenceError if
    /// s is in the TDZ, TypeError otherwise. The compiler places it exactly where the
    /// write would happen, so the value and its side effects come first, as in the
    /// tree-walker. Never falls through at run time, but the verifier models it as
    /// stack-neutral fallthrough, which is the conservative choice.
    assign_const,

    /// Push the global `name`; ReferenceError if there is none.
    get_global,

    // ---- stack
    pop,
    dup,

    // ---- operators (runtime/ops.zig): pop operands, push the result
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    lt,
    le,
    gt,
    ge,
    strict_eq,
    strict_ne,
    neg,
    /// ToNumber: unary `+`, and the first step of `++`/`--`.
    to_number,
    not,
    /// Number + 1 / number - 1. The operand is always the result of `to_number`.
    inc,
    dec,

    // ---- control
    jump,
    /// Pop; jump if falsy / truthy (ToBoolean).
    jump_if_false,
    jump_if_true,
    /// Stack: [callee, arg0 … arg(argc-1)] → [result].
    /// M3/M5 calling convention, native functions only: the callee is evaluated first,
    /// then the arguments, and only then is it checked (TypeError if not callable,
    /// matching the tree-walker). The native receives the argument values as a slice of
    /// the operand stack, valid only during the call; it cannot call back into JS, so
    /// the stack cannot move under it. User functions (M6) will define frames, `this`
    /// and return, and may change this instruction; nothing here anticipates them.
    call,
    /// End of the script. The stack must be empty.
    halt,

    pub const Info = struct {
        operands: []const Operand,
        /// Values popped; for `call`, add argc.
        pops: u32,
        pushes: u32,
    };

    pub fn info(op: Op) Info {
        return switch (op) {
            .push_undefined, .push_null, .push_true, .push_false => .{ .operands = &.{}, .pops = 0, .pushes = 1 },
            .push_const => .{ .operands = &.{.@"const"}, .pops = 0, .pushes = 1 },
            .get_local => .{ .operands = &.{ .slot, .name }, .pops = 0, .pushes = 1 },
            .set_local, .assign_const => .{ .operands = &.{ .slot, .name }, .pops = 1, .pushes = 1 },
            .init_local => .{ .operands = &.{.slot}, .pops = 1, .pushes = 0 },
            .clear_local => .{ .operands = &.{.slot}, .pops = 0, .pushes = 0 },
            .get_global => .{ .operands = &.{.name}, .pops = 0, .pushes = 1 },
            .pop => .{ .operands = &.{}, .pops = 1, .pushes = 0 },
            .dup => .{ .operands = &.{}, .pops = 1, .pushes = 2 },
            .add, .sub, .mul, .div, .mod, .pow, .lt, .le, .gt, .ge, .strict_eq, .strict_ne => .{ .operands = &.{}, .pops = 2, .pushes = 1 },
            .neg, .to_number, .not, .inc, .dec => .{ .operands = &.{}, .pops = 1, .pushes = 1 },
            .jump => .{ .operands = &.{.target}, .pops = 0, .pushes = 0 },
            .jump_if_false, .jump_if_true => .{ .operands = &.{.target}, .pops = 1, .pushes = 0 },
            .call => .{ .operands = &.{.argc}, .pops = 1, .pushes = 1 },
            .halt => .{ .operands = &.{}, .pops = 0, .pushes = 0 },
        };
    }

    /// Encoded length in bytes.
    pub fn size(op: Op) u32 {
        return 1 + 4 * @as(u32, @intCast(op.info().operands.len));
    }
};

/// Reads the u32 operand starting at `pos`. The caller guarantees it is in bounds
/// (the verifier checks this for every instruction).
pub fn readU32(code: []const u8, pos: usize) u32 {
    return std.mem.readInt(u32, code[pos..][0..4], .little);
}

/// A compiled script.
///
/// Ownership: `code`, `consts` (the slice), `names` and every name are owned by the
/// Proto and freed by `deinit` with the allocator given to the compiler. String
/// constants are heap objects owned by the runtime heap the compiler was given: the
/// Proto must not outlive that heap. Without a GC (until M8) heap objects live until
/// `Heap.deinit`; with one, the Proto is what keeps them alive (it marks its constants,
/// DESIGN_DECISIONS D9). If compilation fails, the compiler frees the strings it made
/// (`Heap.rollback`), so a failed compile leaves the heap as it found it.
pub const Proto = struct {
    code: []const u8,
    /// Numbers and strings only.
    consts: []const Value,
    /// Variable names (source text, ASCII), copied out of the source.
    names: []const []const u8,
    slot_count: u32,
    max_stack: u32,

    pub fn deinit(p: *Proto, gpa: Allocator) void {
        gpa.free(p.code);
        gpa.free(p.consts);
        for (p.names) |n| gpa.free(n);
        gpa.free(p.names);
        p.* = undefined;
    }
};

test "every opcode has a consistent size" {
    inline for (@typeInfo(Op).@"enum".field_values) |value| {
        const op: Op = @fromBackingInt(value);
        try std.testing.expect(op.size() == 1 or op.size() == 5 or op.size() == 9);
    }
}
