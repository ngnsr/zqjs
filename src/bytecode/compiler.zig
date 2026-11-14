//! AST + Resolution → Proto (bytecode.zig). One pass over the tree.
//!
//! The code must do exactly what the tree-walker (interp/treewalk.zig, the oracle)
//! does, in the same order. Each case below names the order it reproduces.
//!
//! Stack depth is tracked while emitting (`depth`, `max_stack`). Structured control
//! flow means every jump lands where the depth equals the jump's, so one running
//! counter is exact; the verifier recomputes it independently over the control-flow
//! graph and must agree.
//!
//! No unreachable code is emitted. `stmt` returns whether control can reach the end
//! of the statement, and code that cannot be reached (after `break`, after an `if`
//! whose branches both break, after `for (;;)` with no `break`) is skipped. Besides
//! keeping the disassembly honest, this is what makes "verifier max == compiler max"
//! a checkable invariant: the verifier only sees reachable code.
//!
//! Recursion is bounded by the AST depth limit, as in the tree-walker.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../frontend/ast.zig");
const Resolution = @import("../frontend/resolver.zig").Resolution;
const Diagnostic = @import("../frontend/diag.zig").Diagnostic;
const Limits = @import("../limits.zig").Limits;
const Limit = @import("../limits.zig").Limit;
const Heap = @import("../runtime/heap.zig").Heap;
const Value = @import("../runtime/value.zig").Value;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const Proto = bc.Proto;

pub const Error = error{ LimitExceeded, OutOfMemory };

/// Compiles a resolved script. String constants are allocated on `heap` (see Proto for
/// ownership); everything else with `gpa`. On LimitExceeded, `diag` says which limit
/// and where. On any error nothing is leaked and the heap is as before.
pub fn compile(gpa: Allocator, heap: *Heap, script: ast.Script, res: Resolution, limits: Limits, diag: *Diagnostic) Error!Proto {
    const heap_mark = heap.mark();
    errdefer heap.rollback(heap_mark);

    var c: Compiler = .{ .gpa = gpa, .heap = heap, .res = res, .limits = limits, .diag = diag };
    defer c.deinitTables();
    errdefer {
        c.code.deinit(gpa);
        c.consts.deinit(gpa);
        for (c.names.items) |n| gpa.free(n);
        c.names.deinit(gpa);
    }

    if (try c.block(script.statements, .{ .start = 0, .end = 0 })) try c.emit(.halt, &.{});
    std.debug.assert(c.depth == 0);

    const code = try c.code.toOwnedSlice(gpa);
    errdefer gpa.free(code);
    const consts = try c.consts.toOwnedSlice(gpa);
    errdefer gpa.free(consts);
    const names = try c.names.toOwnedSlice(gpa);
    return .{ .code = code, .consts = consts, .names = names, .slot_count = res.max_slots, .max_stack = c.max_stack };
}

const Loop = struct {
    /// Offsets of the operands of `break` jumps, patched to the loop's end.
    breaks: std.ArrayList(u32) = .empty,
    /// Same for `continue`, patched to the loop's continue point.
    continues: std.ArrayList(u32) = .empty,
};

const Compiler = struct {
    gpa: Allocator,
    heap: *Heap,
    res: Resolution,
    limits: Limits,
    diag: *Diagnostic,

    code: std.ArrayList(u8) = .empty,
    consts: std.ArrayList(Value) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    // Deduplication. Numbers by bit pattern, so 0 and -0 stay distinct and every NaN
    // literal (there is only one bit pattern the lexer produces) shares one entry.
    number_index: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    // Strings by content; keys are the literals' UTF-16 units as bytes, which live in
    // the AST arena for the whole compilation.
    string_index: std.StringHashMapUnmanaged(u32) = .empty,
    name_index: std.StringHashMapUnmanaged(u32) = .empty,

    depth: u32 = 0,
    max_stack: u32 = 0,
    loop: ?*Loop = null,
    /// Span of the statement being compiled, for limit diagnostics.
    span: ast.Span = .{ .start = 0, .end = 0 },

    fn deinitTables(c: *Compiler) void {
        c.number_index.deinit(c.gpa);
        c.string_index.deinit(c.gpa);
        c.name_index.deinit(c.gpa);
    }

    fn limit(c: *Compiler, which: Limit) Error {
        c.diag.* = .{ .detail = .{ .limit_exceeded = which }, .start = c.span.start, .end = c.span.end };
        return error.LimitExceeded;
    }

    // ---- emission

    /// Appends an instruction and applies its stack effect.
    fn emit(c: *Compiler, op: Op, operands: []const u32) Error!void {
        const info = op.info();
        std.debug.assert(operands.len == info.operands.len);
        if (c.code.items.len + op.size() > c.limits.max_code_bytes) return c.limit(.code_bytes);
        try c.code.ensureUnusedCapacity(c.gpa, op.size());
        c.code.appendAssumeCapacity(@backingInt(op));
        for (operands) |x| c.code.appendSliceAssumeCapacity(&std.mem.toBytes(std.mem.nativeToLittle(u32, x)));

        const pops = info.pops + if (op == .call) operands[0] else 0;
        c.depth -= pops; // underflow here is a compiler bug (safety-checked)
        c.depth += info.pushes;
        c.max_stack = @max(c.max_stack, c.depth);
    }

    fn here(c: *const Compiler) u32 {
        return @intCast(c.code.items.len); // < max_code_bytes < 4 GiB
    }

    /// Emits a forward jump and returns the offset of its target operand, to `patch`.
    fn jumpForward(c: *Compiler, op: Op) Error!u32 {
        try c.emit(op, &.{0});
        return c.here() - 4;
    }

    fn patch(c: *Compiler, operand: u32, target: u32) void {
        std.mem.writeInt(u32, c.code.items[operand..][0..4], target, .little);
    }

    // ---- pools

    fn constant(c: *Compiler, v: Value) Error!u32 {
        if (c.consts.items.len >= c.limits.max_constants) return c.limit(.constants);
        try c.consts.append(c.gpa, v);
        return @intCast(c.consts.items.len - 1);
    }

    fn number(c: *Compiler, n: f64) Error!u32 {
        const gop = try c.number_index.getOrPut(c.gpa, @bitCast(n));
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = c.number_index.remove(@bitCast(n));
        gop.value_ptr.* = try c.constant(.{ .number = n });
        return gop.value_ptr.*;
    }

    fn string(c: *Compiler, units: []const u16) Error!u32 {
        const key = std.mem.sliceAsBytes(units);
        const gop = try c.string_index.getOrPut(c.gpa, key);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = c.string_index.remove(key);
        if (c.consts.items.len >= c.limits.max_constants) return c.limit(.constants);
        const s = c.heap.newString(&.{.{ .utf16 = units }}) catch |e| switch (e) {
            error.LimitExceeded => return c.limit(c.heap.limit_hit.?),
            error.OutOfMemory => return error.OutOfMemory,
        };
        // On a later failure the string is freed by the heap rollback in `compile`.
        gop.value_ptr.* = try c.constant(.{ .string = s });
        return gop.value_ptr.*;
    }

    fn name(c: *Compiler, text: []const u8) Error!u32 {
        const gop = try c.name_index.getOrPut(c.gpa, text);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = c.name_index.remove(text);
        if (c.names.items.len >= c.limits.max_constants) return c.limit(.constants);
        try c.names.ensureUnusedCapacity(c.gpa, 1);
        const copy = try c.gpa.dupe(u8, text);
        c.names.appendAssumeCapacity(copy);
        gop.key_ptr.* = copy; // the key must not point into the source after we return
        gop.value_ptr.* = @intCast(c.names.items.len - 1);
        return gop.value_ptr.*;
    }

    fn slotOf(c: *const Compiler, binding: u32) u32 {
        return c.res.bindings[binding].slot;
    }

    // ---- statements

    /// Compiles statements in order, stopping after one that cannot complete normally.
    /// Like treewalk `block`: all declarations of the block enter the TDZ first.
    fn block(c: *Compiler, stmts: []const ast.Stmt, span: ast.Span) Error!bool {
        c.span = span;
        for (stmts) |s| if (s.data == .declaration) try c.clearScope(s.data.declaration);
        for (stmts) |s| if (!try c.stmt(s)) return false;
        return true;
    }

    fn clearScope(c: *Compiler, decl: ast.Declaration) Error!void {
        for (decl.declarators) |d| try c.emit(.clear_local, &.{c.slotOf(d.binding)});
    }

    fn declare(c: *Compiler, decl: ast.Declaration) Error!void {
        for (decl.declarators) |d| {
            if (d.init) |init| try c.expr(init) else try c.emit(.push_undefined, &.{});
            try c.emit(.init_local, &.{c.slotOf(d.binding)});
        }
    }

    /// Returns whether control can reach the end of the statement.
    fn stmt(c: *Compiler, s: ast.Stmt) Error!bool {
        c.span = s.span;
        switch (s.data) {
            .empty => {},
            .expression => |e| {
                try c.expr(e);
                try c.emit(.pop, &.{});
            },
            .declaration => |decl| try c.declare(decl),
            .block => |stmts| return c.block(stmts, s.span),
            .@"if" => |i| {
                try c.expr(i.cond);
                const to_else = try c.jumpForward(.jump_if_false);
                const then_completes = try c.stmt(i.then.*);
                const e = i.@"else" orelse {
                    c.patch(to_else, c.here());
                    return true;
                };
                const to_end = if (then_completes) try c.jumpForward(.jump) else null;
                c.patch(to_else, c.here());
                const else_completes = try c.stmt(e.*);
                if (to_end) |j| c.patch(j, c.here());
                return then_completes or else_completes;
            },
            .@"while" => |w| {
                // top: cond; jump_if_false end; body; jump top; end:
                var loop: Loop = .{};
                defer c.deinitLoop(&loop);
                const top = c.here();
                try c.expr(w.cond);
                const to_end = try c.jumpForward(.jump_if_false);
                if (try c.loopBody(&loop, w.body.*)) try c.emit(.jump, &.{top});
                c.patch(to_end, c.here());
                for (loop.continues.items) |j| c.patch(j, top);
                for (loop.breaks.items) |j| c.patch(j, c.here());
                return true; // the condition can be false
            },
            .@"for" => |f| {
                // init; top: [cond; jump_if_false end]; body; cont: [update; pop]; jump top; end:
                if (f.init) |init| switch (init) {
                    .declaration => |decl| {
                        try c.clearScope(decl);
                        try c.declare(decl);
                    },
                    .expression => |e| {
                        try c.expr(e);
                        try c.emit(.pop, &.{});
                    },
                };
                var loop: Loop = .{};
                defer c.deinitLoop(&loop);
                const top = c.here();
                const to_end = if (f.cond) |cond| blk: {
                    try c.expr(cond);
                    break :blk try c.jumpForward(.jump_if_false);
                } else null;
                const body_completes = try c.loopBody(&loop, f.body.*);
                // `continue` lands on the update, which still runs (as in treewalk).
                if (body_completes or loop.continues.items.len > 0) {
                    for (loop.continues.items) |j| c.patch(j, c.here());
                    if (f.update) |u| {
                        try c.expr(u);
                        try c.emit(.pop, &.{});
                    }
                    try c.emit(.jump, &.{top});
                }
                if (to_end) |j| c.patch(j, c.here());
                for (loop.breaks.items) |j| c.patch(j, c.here());
                return to_end != null or loop.breaks.items.len > 0;
            },
            // The parser guarantees break/continue only occur inside loops.
            .@"break" => {
                const j = try c.jumpForward(.jump);
                try c.loop.?.breaks.append(c.gpa, j);
                return false;
            },
            .@"continue" => {
                const j = try c.jumpForward(.jump);
                try c.loop.?.continues.append(c.gpa, j);
                return false;
            },
        }
        return true;
    }

    fn loopBody(c: *Compiler, loop: *Loop, body: ast.Stmt) Error!bool {
        const outer = c.loop;
        c.loop = loop;
        defer c.loop = outer;
        return c.stmt(body);
    }

    fn deinitLoop(c: *Compiler, loop: *Loop) void {
        loop.breaks.deinit(c.gpa);
        loop.continues.deinit(c.gpa);
    }

    // ---- expressions: each pushes exactly one value

    fn expr(c: *Compiler, e: *const ast.Expr) Error!void {
        switch (e.data) {
            .number => |n| try c.emit(.push_const, &.{try c.number(n)}),
            .string => |units| try c.emit(.push_const, &.{try c.string(units)}),
            .boolean => |b| try c.emit(if (b) .push_true else .push_false, &.{}),
            .null => try c.emit(.push_null, &.{}),
            .identifier => |ref| try c.read(ref),
            .unary => |u| {
                try c.expr(u.operand);
                try c.emit(switch (u.op) {
                    .neg => .neg,
                    .plus => .to_number,
                    .not => .not,
                }, &.{});
            },
            .binary => |b| switch (b.op) {
                // lhs; dup; jump_if_(false|true) end; pop; rhs; end:
                // The kept copy is the result when short-circuiting ('' || 'd' is 'd').
                .logical_and, .logical_or => {
                    try c.expr(b.lhs);
                    try c.emit(.dup, &.{});
                    const to_end = try c.jumpForward(if (b.op == .logical_and) .jump_if_false else .jump_if_true);
                    try c.emit(.pop, &.{});
                    try c.expr(b.rhs);
                    c.patch(to_end, c.here());
                },
                else => {
                    try c.expr(b.lhs);
                    try c.expr(b.rhs);
                    try c.emit(binaryOp(b.op), &.{});
                },
            },
            .assign => |a| {
                if (a.op) |op| {
                    // x op= e: read x (TDZ), evaluate e, apply op, then write (const check).
                    try c.read(a.target);
                    try c.expr(a.value);
                    try c.emit(binaryOp(op), &.{});
                } else {
                    // x = e: evaluate e first; the TDZ and const checks happen on the write.
                    try c.expr(a.value);
                }
                try c.write(a.target);
            },
            .update => |u| {
                // Read, ToNumber, then write; the result is the new value (prefix) or the
                // old one (postfix: keep a copy of it under the new value).
                try c.read(u.target);
                try c.emit(.to_number, &.{});
                if (!u.prefix) try c.emit(.dup, &.{});
                try c.emit(if (u.op == .inc) .inc else .dec, &.{});
                try c.write(u.target);
                if (!u.prefix) try c.emit(.pop, &.{});
            },
            .call => |call| {
                // Callee, then arguments left to right, then the callable check.
                try c.expr(call.callee);
                for (call.args) |arg| try c.expr(arg);
                try c.emit(.call, &.{@intCast(call.args.len)}); // args.len < source size
            },
        }
    }

    fn read(c: *Compiler, ref: ast.Ref) Error!void {
        switch (c.res.refs[ref.id]) {
            .local => |b| try c.emit(.get_local, &.{ c.slotOf(b), try c.name(ref.name) }),
            .global => try c.emit(.get_global, &.{try c.name(ref.name)}),
        }
    }

    /// Writes the top of the stack to `ref`, keeping it. The resolver rejects writes to
    /// globals, so `ref` is local.
    fn write(c: *Compiler, ref: ast.Ref) Error!void {
        const b = c.res.refs[ref.id].local;
        const op: Op = if (c.res.bindings[b].kind == .@"const") .assign_const else .set_local;
        try c.emit(op, &.{ c.slotOf(b), try c.name(ref.name) });
    }
};

fn binaryOp(op: ast.BinaryOp) Op {
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
        .logical_and, .logical_or => unreachable, // control flow, handled by the caller
    };
}
