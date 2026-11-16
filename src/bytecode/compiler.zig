//! AST + Resolution → Proto tree (bytecode.zig). One pass per function.
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
//! of the statement, and code that cannot be reached (after `break`, `continue` or
//! `return`, after an `if` whose branches all leave, after `for (;;)` with no `break`)
//! is skipped. Besides keeping the disassembly honest, this is what makes "verifier
//! max == compiler max" a checkable invariant: the verifier only sees reachable code.
//!
//! Captured bindings (M6, DESIGN_DECISIONS D36): a binding the resolver marked
//! `captured` lives in a cell in its slot. Its scope entry emits `new_cell` (fresh cells
//! on every execution of the scope), and every access uses the *_cell instructions; a
//! binding of an enclosing function is reached through the closure (*_capture).
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
    var shared: Shared = .{ .gpa = gpa, .heap = heap, .res = res, .limits = limits, .diag = diag };
    return shared.proto(.script, null, script.statements);
}

/// State shared by the compilers of all functions of one script.
const Shared = struct {
    gpa: Allocator,
    heap: *Heap,
    res: Resolution,
    limits: Limits,
    diag: *Diagnostic,
    /// Code bytes of all Protos so far (Limits.max_code_bytes bounds the whole script).
    code_bytes: usize = 0,

    /// Compiles one script or function into a Proto (and, recursively, its functions).
    fn proto(s: *Shared, kind: @FieldType(Proto, "kind"), f: ?*const ast.Function, body: []const ast.Stmt) Error!Proto {
        var c: Compiler = .{ .s = s, .function = if (f) |func| func.id else 0 };
        defer c.deinit();

        if (f) |func| {
            // Parameters arrive as plain values; box the captured ones.
            for (func.params) |p| if (c.binding(p.binding).captured) try c.emit(.box_local, &.{c.slotOf(p.binding)});
            // A named expression's own name: the running closure.
            if (func.kind == .expression) if (func.name) |n| {
                if (c.binding(n.binding).captured) try c.emit(.new_cell, &.{c.slotOf(n.binding)});
                try c.emit(.push_callee, &.{});
                try c.initBinding(n.binding);
            };
        }
        const completes = try c.statements(body, .{ .start = 0, .end = 0 });
        if (completes) switch (kind) {
            .script => try c.emit(.halt, &.{}),
            .function => {
                try c.emit(.push_undefined, &.{});
                try c.emit(.@"return", &.{});
            },
        };
        return c.finish(kind, f);
    }
};

const Loop = struct {
    /// Offsets of the operands of `break` jumps, patched to the loop's end.
    breaks: std.ArrayList(u32) = .empty,
    /// Same for `continue`, patched to the loop's continue point.
    continues: std.ArrayList(u32) = .empty,
};

/// The compiler of one function (or the script).
const Compiler = struct {
    s: *Shared,
    /// Resolution.functions index of the function being compiled.
    function: u32,

    code: std.ArrayList(u8) = .empty,
    consts: std.ArrayList(Value) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    functions: std.ArrayList(Proto) = .empty,
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

    /// Frees everything not handed over by `finish` (all of it, after an error).
    fn deinit(c: *Compiler) void {
        const gpa = c.s.gpa;
        c.number_index.deinit(gpa);
        c.string_index.deinit(gpa);
        c.name_index.deinit(gpa);
        c.code.deinit(gpa);
        c.consts.deinit(gpa);
        for (c.names.items) |n| gpa.free(n);
        c.names.deinit(gpa);
        for (c.functions.items) |*f| f.deinit(gpa);
        c.functions.deinit(gpa);
    }

    /// Moves everything into a Proto. On failure nothing has moved, so `deinit` still
    /// frees it all.
    fn finish(c: *Compiler, kind: @FieldType(Proto, "kind"), f: ?*const ast.Function) Error!Proto {
        const gpa = c.s.gpa;
        const info = c.s.res.functions[c.function];
        const captures = try gpa.alloc(Proto.Capture, info.captures.len);
        errdefer gpa.free(captures);
        for (info.captures, captures) |from, *to| to.* = switch (from.from) {
            .parent_slot => |i| .{ .from = .parent_slot, .index = i },
            .parent_capture => |i| .{ .from = .parent_capture, .index = i },
        };
        const fn_name: []const u8 = if (f) |func| (if (func.name) |n| n.name else "") else "";
        const name_copy = try gpa.dupe(u8, fn_name);
        errdefer gpa.free(name_copy);
        // Exact-size slices, allocated before anything is moved out of the lists.
        const code = try gpa.dupe(u8, c.code.items);
        errdefer gpa.free(code);
        const consts = try gpa.dupe(Value, c.consts.items);
        errdefer gpa.free(consts);
        const names = try gpa.dupe([]const u8, c.names.items);
        errdefer gpa.free(names);
        const name_atoms = try gpa.alloc(*@import("../runtime/heap.zig").String, c.names.items.len);
        errdefer gpa.free(name_atoms);
        for (c.names.items, 0..) |n, i| {
            name_atoms[i] = c.s.heap.internAscii(n) catch |e| switch (e) {
                error.LimitExceeded => return c.limit(c.s.heap.limit_hit.?),
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        const functions = try gpa.dupe(Proto, c.functions.items);
        // Ownership of names and nested Protos has moved: don't free them twice.
        c.names.clearRetainingCapacity();
        c.functions.clearRetainingCapacity();
        return .{
            .kind = kind,
            .name = name_copy,
            .code = code,
            .consts = consts,
            .names = names,
            .name_atoms = name_atoms,
            .slot_count = info.slot_count,
            .max_stack = c.max_stack,
            .param_count = info.param_count,
            .param_slot = info.param_slot,
            .captures = captures,
            .functions = functions,
        };
    }

    fn binding(c: *const Compiler, b: u32) Resolution.Binding {
        return c.s.res.bindings[b];
    }

    fn slotOf(c: *const Compiler, b: u32) u32 {
        return c.s.res.bindings[b].slot;
    }

    fn limit(c: *Compiler, which: Limit) Error {
        c.s.diag.* = .{ .detail = .{ .limit_exceeded = which }, .start = c.span.start, .end = c.span.end };
        return error.LimitExceeded;
    }

    // ---- emission

    /// Appends an instruction and applies its stack effect.
    fn emit(c: *Compiler, op: Op, operands: []const u32) Error!void {
        const info = op.info();
        std.debug.assert(operands.len == info.operands.len);
        if (c.s.code_bytes + op.size() > c.s.limits.max_code_bytes) return c.limit(.code_bytes);
        try c.code.ensureUnusedCapacity(c.s.gpa, op.size());
        c.code.appendAssumeCapacity(@backingInt(op));
        for (operands) |x| c.code.appendSliceAssumeCapacity(&std.mem.toBytes(std.mem.nativeToLittle(u32, x)));
        c.s.code_bytes += op.size();

        const argc: u32 = if (info.operands.len > 0 and info.operands[0] == .argc) operands[0] else 0;
        c.depth -= @intCast(op.popsWith(argc)); // underflow here is a compiler bug (safety-checked)
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
        if (c.consts.items.len >= c.s.limits.max_constants) return c.limit(.constants);
        try c.consts.append(c.s.gpa, v);
        return @intCast(c.consts.items.len - 1);
    }

    fn number(c: *Compiler, n: f64) Error!u32 {
        const gop = try c.number_index.getOrPut(c.s.gpa, @bitCast(n));
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = c.number_index.remove(@bitCast(n));
        gop.value_ptr.* = try c.constant(.{ .number = n });
        return gop.value_ptr.*;
    }

    fn string(c: *Compiler, units: []const u16) Error!u32 {
        const key = std.mem.sliceAsBytes(units);
        const gop = try c.string_index.getOrPut(c.s.gpa, key);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = c.string_index.remove(key);
        if (c.consts.items.len >= c.s.limits.max_constants) return c.limit(.constants);
        const str = c.s.heap.newString(&.{.{ .utf16 = units }}) catch |e| switch (e) {
            error.LimitExceeded => return c.limit(c.s.heap.limit_hit.?),
            error.OutOfMemory => return error.OutOfMemory,
        };
        // On a later failure the string is freed by the heap rollback in `compile`.
        gop.value_ptr.* = try c.constant(.{ .string = str });
        return gop.value_ptr.*;
    }

    fn name(c: *Compiler, text: []const u8) Error!u32 {
        const gop = try c.name_index.getOrPut(c.s.gpa, text);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = c.name_index.remove(text);
        if (c.names.items.len >= c.s.limits.max_constants) return c.limit(.constants);
        try c.names.ensureUnusedCapacity(c.s.gpa, 1);
        const copy = try c.s.gpa.dupe(u8, text);
        c.names.appendAssumeCapacity(copy);
        gop.key_ptr.* = copy; // the key must not point into the source after we return
        gop.value_ptr.* = @intCast(c.names.items.len - 1);
        return gop.value_ptr.*;
    }

    // ---- statements

    /// Statements of a script, function body or block, in order, stopping after one
    /// that cannot complete normally. Scope entry first, like the tree-walker: all
    /// let/const of the scope enter the TDZ (fresh cells for captured ones), then the
    /// function declarations are created (hoisted and initialised).
    fn statements(c: *Compiler, stmts: []const ast.Stmt, span: ast.Span) Error!bool {
        c.span = span;
        for (stmts) |s| switch (s.data) {
            .declaration => |decl| for (decl.declarators) |d| try c.enterBinding(d.binding),
            .function => |f| if (c.binding(f.name.?.binding).captured) try c.emit(.new_cell, &.{c.slotOf(f.name.?.binding)}),
            else => {},
        };
        for (stmts) |s| if (s.data == .function) {
            const f = s.data.function;
            try c.closure(f);
            try c.initBinding(f.name.?.binding);
        };
        for (stmts) |s| if (!try c.stmt(s)) return false;
        return true;
    }

    /// The binding's scope is being entered: TDZ (a fresh cell if captured).
    fn enterBinding(c: *Compiler, b: u32) Error!void {
        try c.emit(if (c.binding(b).captured) .new_cell else .clear_local, &.{c.slotOf(b)});
    }

    /// Pops the top of the stack into binding `b` of this function (no TDZ/const check).
    fn initBinding(c: *Compiler, b: u32) Error!void {
        try c.emit(if (c.binding(b).captured) .init_cell else .init_local, &.{c.slotOf(b)});
    }

    fn declare(c: *Compiler, decl: ast.Declaration) Error!void {
        for (decl.declarators) |d| {
            if (d.init) |init| try c.expr(init) else try c.emit(.push_undefined, &.{});
            try c.initBinding(d.binding);
        }
    }

    /// `make_closure` for a nested function, compiling it first.
    fn closure(c: *Compiler, f: *const ast.Function) Error!void {
        const outer_span = c.span;
        var child = try c.s.proto(.function, f, f.body);
        {
            errdefer child.deinit(c.s.gpa);
            try c.functions.append(c.s.gpa, child);
        }
        c.span = outer_span;
        try c.emit(.make_closure, &.{@intCast(c.functions.items.len - 1)});
    }

    /// Returns whether control can reach the end of the statement.
    fn stmt(c: *Compiler, s: ast.Stmt) Error!bool {
        c.span = s.span;
        switch (s.data) {
            .empty, .function => {}, // functions were created on entry to the body
            .expression => |e| {
                try c.expr(e);
                try c.emit(.pop, &.{});
            },
            .declaration => |decl| try c.declare(decl),
            .block => |stmts| return c.statements(stmts, s.span),
            .@"return" => |v| {
                if (v) |e| try c.expr(e) else try c.emit(.push_undefined, &.{});
                try c.emit(.@"return", &.{});
                return false;
            },
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
                // init; [copy]; top: [cond; jump_if_false end]; body;
                // cont: [copy]; [update; pop]; jump top; end:
                // `copy` gives captured `let` head bindings fresh cells per iteration
                // (CreatePerIterationEnvironment), as the tree-walker copies its record.
                var copies: []const ast.Declarator = &.{};
                if (f.init) |init| switch (init) {
                    .declaration => |decl| {
                        for (decl.declarators) |d| try c.enterBinding(d.binding);
                        try c.declare(decl);
                        if (decl.kind == .let) copies = decl.declarators;
                    },
                    .expression => |e| {
                        try c.expr(e);
                        try c.emit(.pop, &.{});
                    },
                };
                try c.perIteration(copies);
                var loop: Loop = .{};
                defer c.deinitLoop(&loop);
                const top = c.here();
                const to_end = if (f.cond) |cond| blk: {
                    try c.expr(cond);
                    break :blk try c.jumpForward(.jump_if_false);
                } else null;
                const body_completes = try c.loopBody(&loop, f.body.*);
                // `continue` lands on the copy and the update, which still run (as in treewalk).
                if (body_completes or loop.continues.items.len > 0) {
                    for (loop.continues.items) |j| c.patch(j, c.here());
                    try c.perIteration(copies);
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
                try c.loop.?.breaks.append(c.s.gpa, j);
                return false;
            },
            .@"continue" => {
                const j = try c.jumpForward(.jump);
                try c.loop.?.continues.append(c.s.gpa, j);
                return false;
            },
        }
        return true;
    }

    fn perIteration(c: *Compiler, head: []const ast.Declarator) Error!void {
        for (head) |d| if (c.binding(d.binding).captured) try c.emit(.fresh_cell, &.{c.slotOf(d.binding)});
    }

    fn loopBody(c: *Compiler, loop: *Loop, body: ast.Stmt) Error!bool {
        const outer = c.loop;
        c.loop = loop;
        defer c.loop = outer;
        return c.stmt(body);
    }

    fn deinitLoop(c: *Compiler, loop: *Loop) void {
        loop.breaks.deinit(c.s.gpa);
        loop.continues.deinit(c.s.gpa);
    }

    // ---- expressions: each pushes exactly one value

    fn expr(c: *Compiler, e: *const ast.Expr) Error!void {
        switch (e.data) {
            .number => |n| try c.emit(.push_const, &.{try c.number(n)}),
            .string => |units| try c.emit(.push_const, &.{try c.string(units)}),
            .boolean => |b| try c.emit(if (b) .push_true else .push_false, &.{}),
            .null => try c.emit(.push_null, &.{}),
            .identifier => |ref| try c.read(ref),
            .function => |f| try c.closure(f),
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
            .assign => |a| switch (a.target) {
                .ref => |ref| {
                    if (a.op) |op| {
                        // x op= e: read x (TDZ), evaluate e, apply op, then write (const check).
                        try c.read(ref);
                        try c.expr(a.value);
                        try c.emit(binaryOp(op), &.{});
                    } else {
                        // x = e: evaluate e first; the TDZ and const checks happen on the write.
                        try c.expr(a.value);
                    }
                    try c.write(ref);
                },
                // Base and key exactly once, before the right-hand side (dup/dup2 keep them
                // for the write). `op=` reads before evaluating the right-hand side.
                .member => |m| {
                    try c.expr(m.object);
                    switch (m.key) {
                        .name => |n| {
                            if (a.op) |op| {
                                try c.emit(.dup, &.{});
                                try c.emit(.get_prop, &.{try c.name(n)});
                                try c.expr(a.value);
                                try c.emit(binaryOp(op), &.{});
                            } else try c.expr(a.value);
                            try c.emit(.set_prop, &.{try c.name(n)});
                        },
                        .computed => |k| {
                            try c.expr(k);
                            if (a.op) |op| {
                                try c.emit(.dup2, &.{});
                                try c.emit(.get_elem, &.{});
                                try c.expr(a.value);
                                try c.emit(binaryOp(op), &.{});
                            } else try c.expr(a.value);
                            try c.emit(.set_elem, &.{});
                        },
                        .string, .number => unreachable, // only in literals
                    }
                },
            },
            .update => |u| switch (u.target) {
                .ref => |ref| {
                    // Read, ToNumber, then write; the result is the new value (prefix) or the
                    // old one (postfix: keep a copy of it under the new value).
                    try c.read(ref);
                    try c.emit(.to_number, &.{});
                    if (!u.prefix) try c.emit(.dup, &.{});
                    try c.emit(if (u.op == .inc) .inc else .dec, &.{});
                    try c.write(ref);
                    if (!u.prefix) try c.emit(.pop, &.{});
                },
                // o.p++: o; dup; get_prop; to_number; [dup; rot3]; inc; set_prop; [pop]
                // o[k]++: o; k; dup2; get_elem; to_number; [dup; rot4]; inc; set_elem; [pop]
                // (rot moves a copy of the old value below base and key, for postfix).
                .member => |m| {
                    try c.expr(m.object);
                    const named = switch (m.key) {
                        .name => |n| n,
                        .computed => |k| blk: {
                            try c.expr(k);
                            break :blk null;
                        },
                        .string, .number => unreachable,
                    };
                    if (named) |n| {
                        try c.emit(.dup, &.{});
                        try c.emit(.get_prop, &.{try c.name(n)});
                    } else {
                        try c.emit(.dup2, &.{});
                        try c.emit(.get_elem, &.{});
                    }
                    try c.emit(.to_number, &.{});
                    if (!u.prefix) {
                        try c.emit(.dup, &.{});
                        try c.emit(if (named == null) .rot4 else .rot3, &.{});
                    }
                    try c.emit(if (u.op == .inc) .inc else .dec, &.{});
                    if (named) |n| try c.emit(.set_prop, &.{try c.name(n)}) else try c.emit(.set_elem, &.{});
                    if (!u.prefix) try c.emit(.pop, &.{});
                },
            },
            .member => |m| try c.member(m, .get),
            .delete => |m| try c.member(m, .delete),
            .this => try c.emit(.push_this, &.{}),
            .array => |items| {
                for (items) |item| try c.expr(item);
                try c.emit(.new_array, &.{@intCast(items.len)});
            },
            .object => |props| {
                // Each key (if computed), then its value, in source order.
                try c.emit(.new_object, &.{});
                for (props) |prop| switch (prop.key) {
                    .name => |n| {
                        try c.expr(prop.value);
                        try c.emit(.define_prop, &.{try c.name(n)});
                    },
                    .string => |units| {
                        try c.emit(.push_const, &.{try c.string(units)});
                        try c.expr(prop.value);
                        try c.emit(.define_elem, &.{});
                    },
                    .number => |n| {
                        try c.emit(.push_const, &.{try c.number(n)});
                        try c.expr(prop.value);
                        try c.emit(.define_elem, &.{});
                    },
                    .computed => |k| {
                        try c.expr(k);
                        try c.expr(prop.value);
                        try c.emit(.define_elem, &.{});
                    },
                };
            },
            .call => |call| {
                // Callee, then arguments left to right, then the callable check. A member
                // callee is a method call: [receiver, callee, args] (D41).
                const method = call.callee.data == .member;
                if (method) {
                    const m = call.callee.data.member;
                    try c.expr(m.object);
                    try c.emit(.dup, &.{});
                    switch (m.key) {
                        .name => |n| try c.emit(.get_prop, &.{try c.name(n)}),
                        .computed => |k| {
                            try c.expr(k);
                            try c.emit(.get_elem, &.{});
                        },
                        .string, .number => unreachable,
                    }
                } else try c.expr(call.callee);
                for (call.args) |arg| try c.expr(arg);
                try c.emit(if (method) .call_method else .call, &.{@intCast(call.args.len)}); // args.len < source size
            },
        }
    }

    /// `o.name` / `o[k]`, read or deleted.
    fn member(c: *Compiler, m: ast.Member, comptime what: enum { get, delete }) Error!void {
        try c.expr(m.object);
        switch (m.key) {
            .name => |n| try c.emit(if (what == .get) .get_prop else .delete_prop, &.{try c.name(n)}),
            .computed => |k| {
                try c.expr(k);
                try c.emit(if (what == .get) .get_elem else .delete_elem, &.{});
            },
            .string, .number => unreachable, // only in literals
        }
    }

    fn read(c: *Compiler, ref: ast.Ref) Error!void {
        switch (c.s.res.refs[ref.id]) {
            .local => |b| try c.emit(if (c.binding(b).captured) .get_cell else .get_local, &.{ c.slotOf(b), try c.name(ref.name) }),
            .capture => |cap| try c.emit(.get_capture, &.{ cap.index, try c.name(ref.name) }),
            .global => try c.emit(.get_global, &.{try c.name(ref.name)}),
        }
    }

    /// Writes the top of the stack to `ref`, keeping it. The resolver rejects writes to
    /// globals and to function-expression names.
    fn write(c: *Compiler, ref: ast.Ref) Error!void {
        switch (c.s.res.refs[ref.id]) {
            .local => |b| {
                const is_const = c.binding(b).kind == .@"const";
                const op: Op = if (c.binding(b).captured)
                    (if (is_const) .assign_const_cell else .set_cell)
                else
                    (if (is_const) .assign_const else .set_local);
                try c.emit(op, &.{ c.slotOf(b), try c.name(ref.name) });
            },
            .capture => |cap| {
                const op: Op = if (c.binding(cap.binding).kind == .@"const") .assign_const_capture else .set_capture;
                try c.emit(op, &.{ cap.index, try c.name(ref.name) });
            },
            .global => unreachable,
        }
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
        .in => .in,
        .logical_and, .logical_or => unreachable, // control flow, handled by the caller
    };
}
