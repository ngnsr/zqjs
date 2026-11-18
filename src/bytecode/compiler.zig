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
            // A named expression's own name: the running closure (visible to parameter defaults).
            if (func.kind == .expression) if (func.name) |n| {
                if (c.binding(n.binding).captured) try c.emit(.new_cell, &.{c.slotOf(n.binding)});
                try c.emit(.push_callee, &.{});
                try c.initBinding(n.binding);
            };
            const fn_info = c.s.res.functions[func.id];
            if (fn_info.is_simple_params) {
                // Parameters arrive as plain values; box the captured ones.
                for (func.params) |p| {
                    const b = p.pattern.data.binding.binding;
                    if (c.binding(b).captured) try c.emit(.box_local, &.{c.slotOf(b)});
                }
            } else {
                for (func.params) |p| try c.enterPatternBindings(p.pattern);
                for (func.params, 0..) |p, i| {
                    if (p.is_rest) {
                        try c.emit(.rest_array, &.{@intCast(i)});
                    } else {
                        try c.emit(.get_arg, &.{@intCast(i)});
                        if (p.default) |def| {
                            const skip = try c.jumpIfNotUndefined();
                            try c.emit(.pop, &.{});
                            try c.expr(def);
                            c.patch(skip, c.here());
                        }
                    }
                    try c.bindPattern(p.pattern, .init);
                }
            }
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
    handlers: std.ArrayList(Proto.ExceptionHandler) = .empty,
    // Deduplication. Numbers by bit pattern, so 0 and -0 stay distinct and every NaN
    // literal (there is only one bit pattern the lexer produces) shares one entry.
    number_index: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    // Strings by content; keys are the literals' UTF-16 units as bytes, which live in
    // the AST arena for the whole compilation.
    string_index: std.StringHashMapUnmanaged(u32) = .empty,
    name_index: std.StringHashMapUnmanaged(u32) = .empty,

    depth: u32 = 0,
    max_stack: u32 = 0,
    temp_depth: u32 = 0,
    max_temp: u32 = 0,
    /// Active loop for `continue` (and `break` when not inside a `switch`).
    loop: ?*Loop = null,
    /// Active break target list (innermost loop or `switch`).
    breaks: ?*std.ArrayList(u32) = null,
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
        c.handlers.deinit(gpa);
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
        errdefer {
            for (functions) |*fn_p| fn_p.deinit(gpa);
            gpa.free(functions);
        }
        const handlers = try gpa.dupe(Proto.ExceptionHandler, c.handlers.items);
        // Ownership of names and nested Protos has moved: don't free them twice.
        c.names.clearRetainingCapacity();
        c.functions.clearRetainingCapacity();
        return .{
            .kind = kind,
            .is_arrow = if (f) |func| func.is_arrow else false,
            .name = name_copy,
            .code = code,
            .consts = consts,
            .names = names,
            .name_atoms = name_atoms,
            .slot_count = info.slot_count + c.max_temp,
            .max_stack = c.max_stack,
            .param_count = info.param_count,
            .param_slot = info.param_slot,
            .captures = captures,
            .functions = functions,
            .handlers = handlers,
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
        gop.key_ptr.* = std.mem.sliceAsBytes(str.units);
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
    fn allocTemp(c: *Compiler) u32 {
        const info = c.s.res.functions[c.function];
        const slot = info.slot_count + c.temp_depth;
        c.temp_depth += 1;
        c.max_temp = @max(c.max_temp, c.temp_depth);
        return slot;
    }

    fn freeTemp(c: *Compiler) void {
        c.temp_depth -= 1;
    }

    /// Emits a jump to skip the default if the top of the stack is NOT `undefined`.
    /// Leaves the value on the stack in both branches.
    fn jumpIfNotUndefined(c: *Compiler) Error!u32 {
        try c.emit(.dup, &.{});
        try c.emit(.push_undefined, &.{});
        try c.emit(.strict_eq, &.{});
        return c.jumpForward(.jump_if_false);
    }

    fn statements(c: *Compiler, stmts: []const ast.Stmt, span: ast.Span) Error!bool {
        c.span = span;
        for (stmts) |s| switch (s.data) {
            .declaration => |decl| for (decl.declarators) |d| try c.enterPatternBindings(d.pattern),
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

    fn enterPatternBindings(c: *Compiler, pat: *const ast.Pattern) Error!void {
        switch (pat.data) {
            .binding => |d| try c.enterBinding(d.binding),
            .target => {},
            .array => |arr| {
                for (arr.elems) |maybe| if (maybe) |el| try c.enterPatternBindings(el.pattern);
                if (arr.rest) |r| try c.enterPatternBindings(r);
            },
            .object => |obj| {
                for (obj.props) |pr| try c.enterPatternBindings(pr.pattern);
                if (obj.rest) |r| try c.enterPatternBindings(r);
            },
        }
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
            try c.bindPattern(d.pattern, .init);
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
            .throw => |e| {
                try c.expr(e);
                try c.emit(.throw, &.{});
                return false;
            },
            .@"try" => |t| {
                const try_depth = c.depth;
                const try_start = c.here();
                const try_completes = try c.statements(t.body, s.span);
                const try_end = c.here();
                const to_end = if (try_completes) try c.jumpForward(.jump) else null;
                const catch_pc = c.here();
                c.depth = try_depth;
                if (t.catch_param) |cp| {
                    c.depth += 1;
                    c.max_stack = @max(c.max_stack, c.depth);
                    try c.enterPatternBindings(cp);
                    try c.bindPattern(cp, .init);
                }
                const catch_completes = try c.statements(t.catch_body, s.span);
                if (to_end) |j| c.patch(j, c.here());
                if (try_end > try_start) {
                    try c.handlers.append(c.s.gpa, .{
                        .try_start = try_start,
                        .try_end = try_end,
                        .catch_pc = catch_pc,
                        .stack_depth = try_depth,
                        .has_binding = t.catch_param != null,
                    });
                }
                return try_completes or catch_completes;
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
            .do_while => |dw| {
                // top: body; cont: cond; jump_if_true top; end:
                var loop: Loop = .{};
                defer c.deinitLoop(&loop);
                const top = c.here();
                const body_completes = try c.loopBody(&loop, dw.body.*);
                if (body_completes or loop.continues.items.len > 0) {
                    for (loop.continues.items) |j| c.patch(j, c.here());
                    try c.expr(dw.cond);
                    try c.emit(.jump_if_true, &.{top});
                }
                for (loop.breaks.items) |j| c.patch(j, c.here());
                return body_completes or loop.continues.items.len > 0 or loop.breaks.items.len > 0;
            },
            .@"switch" => |sw| return c.compileSwitch(sw),
            .@"for" => |f| {
                // init; [copy]; top: [cond; jump_if_false end]; body;
                // cont: [copy]; [update; pop]; jump top; end:
                // `copy` gives captured `let` head bindings fresh cells per iteration
                // (CreatePerIterationEnvironment), as the tree-walker copies its record.
                var copies: []const ast.DeclItem = &.{};
                if (f.init) |init| switch (init) {
                    .declaration => |decl| {
                        for (decl.declarators) |d| try c.enterPatternBindings(d.pattern);
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
            .for_of => |f| {
                // Store iterator in a hidden local slot so the operand stack stays empty
                // across `body` (preserving `return`/`try`/`break`/`continue` stack invariants).
                const iter_slot = c.allocTemp();
                defer c.freeTemp();

                var single_copy: [1]ast.DeclItem = undefined;
                var copies: []const ast.DeclItem = &.{};
                if (f.target == .declaration) {
                    const pat = f.target.declaration.pattern;
                    try c.enterPatternBindings(pat);
                    single_copy[0] = .{ .pattern = pat, .init = null, .span = pat.span };
                    copies = &single_copy;
                }
                try c.expr(f.iterable);
                try c.emit(.get_iter, &.{});
                try c.emit(.init_local, &.{iter_slot});
                var loop: Loop = .{};
                defer c.deinitLoop(&loop);
                const top = c.here();
                try c.emit(.get_local, &.{ iter_slot, try c.name("<iter>") });
                try c.emit(.iter_next, &.{});
                const to_end = try c.jumpForward(.jump_if_true);
                switch (f.target) {
                    .declaration => |decl| {
                        try c.perIteration(copies);
                        try c.bindPattern(decl.pattern, .init);
                    },
                    .target => |t| {
                        try c.bindPattern(t, .assign);
                    },
                }
                const body_completes = try c.loopBody(&loop, f.body.*);
                if (body_completes) try c.emit(.jump, &.{top});
                for (loop.continues.items) |j| c.patch(j, top);
                c.patch(to_end, c.here());
                // At `to_end` (reached only from `jump_if_true` after `iter_next`), the
                // stack holds `[undefined]` (`depth + 1` relative to body).
                c.depth += 1;
                try c.emit(.pop, &.{});
                for (loop.breaks.items) |j| c.patch(j, c.here());
                try c.emit(.clear_local, &.{iter_slot});
                return true;
            },
            // The parser guarantees break/continue only occur inside loops (or switch for break).
            .@"break" => {
                const j = try c.jumpForward(.jump);
                try c.breaks.?.append(c.s.gpa, j);
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

    fn compileSwitch(c: *Compiler, sw: @FieldType(ast.Stmt.Data, "switch")) Error!bool {
        try c.expr(sw.discriminant);
        for (sw.cases) |cs| {
            for (cs.body) |s| switch (s.data) {
                .declaration => |d| for (d.declarators) |decl| try c.enterPatternBindings(decl.pattern),
                else => {},
            };
        }

        const case_jumps = try c.s.gpa.alloc(u32, sw.cases.len);
        defer c.s.gpa.free(case_jumps);

        var default_idx: ?usize = null;
        for (sw.cases, 0..) |cs, i| {
            if (cs.test_expr) |te| {
                try c.emit(.dup, &.{});
                try c.expr(te);
                try c.emit(.strict_eq, &.{});
                const to_next = try c.jumpForward(.jump_if_false);
                try c.emit(.pop, &.{});
                case_jumps[i] = try c.jumpForward(.jump);
                c.patch(to_next, c.here());
                c.depth += 1; // `to_next` bypassed `pop`, so `disc` is still on the stack
            } else {
                default_idx = i;
            }
        }
        try c.emit(.pop, &.{});
        const no_match_jump = try c.jumpForward(.jump);

        var switch_breaks: std.ArrayList(u32) = .empty;
        defer switch_breaks.deinit(c.s.gpa);
        const outer_breaks = c.breaks;
        c.breaks = &switch_breaks;
        defer c.breaks = outer_breaks;

        var last_completes = true;
        for (sw.cases, 0..) |cs, i| {
            if (cs.test_expr != null) {
                c.patch(case_jumps[i], c.here());
            } else {
                c.patch(no_match_jump, c.here());
            }
            var clause_completes = true;
            for (cs.body) |s| {
                if (clause_completes) clause_completes = try c.stmt(s);
            }
            last_completes = clause_completes;
        }
        if (default_idx == null) c.patch(no_match_jump, c.here());
        for (switch_breaks.items) |j| c.patch(j, c.here());
        return (default_idx == null) or (switch_breaks.items.len > 0) or last_completes;
    }

    fn perIteration(c: *Compiler, head: []const ast.DeclItem) Error!void {
        for (head) |d| try c.perIterationPattern(d.pattern);
    }

    fn perIterationPattern(c: *Compiler, pat: *const ast.Pattern) Error!void {
        switch (pat.data) {
            .binding => |d| if (c.binding(d.binding).captured) try c.emit(.fresh_cell, &.{c.slotOf(d.binding)}),
            .target => {},
            .array => |arr| {
                for (arr.elems) |maybe| if (maybe) |el| try c.perIterationPattern(el.pattern);
                if (arr.rest) |r| try c.perIterationPattern(r);
            },
            .object => |obj| {
                for (obj.props) |pr| try c.perIterationPattern(pr.pattern);
                if (obj.rest) |r| try c.perIterationPattern(r);
            },
        }
    }

    fn loopBody(c: *Compiler, loop: *Loop, body: ast.Stmt) Error!bool {
        const outer_loop = c.loop;
        const outer_breaks = c.breaks;
        c.loop = loop;
        c.breaks = &loop.breaks;
        defer {
            c.loop = outer_loop;
            c.breaks = outer_breaks;
        }
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
            .template => |t| {
                try c.emit(.push_const, &.{try c.string(t.quasis[0])});
                for (t.exprs, 0..) |ex, i| {
                    try c.expr(ex);
                    try c.emit(.add, &.{});
                    if (t.quasis[i + 1].len > 0) {
                        try c.emit(.push_const, &.{try c.string(t.quasis[i + 1])});
                        try c.emit(.add, &.{});
                    }
                }
            },
            .boolean => |b| try c.emit(if (b) .push_true else .push_false, &.{}),
            .null => try c.emit(.push_null, &.{}),
            .identifier => |ref| try c.read(ref),
            .function => |f| try c.closure(f),
            .unary => |u| {
                if (u.op == .typeof and u.operand.data == .identifier) {
                    const ref = u.operand.data.identifier;
                    if (c.s.res.refs[ref.id] == .global) {
                        try c.emit(.get_global_or_undefined, &.{try c.name(ref.name)});
                        try c.emit(.typeof, &.{});
                        return;
                    }
                }
                try c.expr(u.operand);
                try c.emit(switch (u.op) {
                    .neg => .neg,
                    .plus => .to_number,
                    .not => .not,
                    .bit_not => .bit_not,
                    .typeof => .typeof,
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
                .nullish => {
                    try c.expr(b.lhs);
                    const to_end = try c.jumpIfLogicalAssignShortCircuit(.nullish);
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
            .conditional => |cond| {
                // cond; jump_if_false else_lbl; then_expr; jump end; else_lbl: else_expr; end:
                try c.expr(cond.cond);
                const to_else = try c.jumpForward(.jump_if_false);
                try c.expr(cond.then_expr);
                const to_end = try c.jumpForward(.jump);
                c.depth -= 1; // else_expr starts at the pre-branch stack depth
                c.patch(to_else, c.here());
                try c.expr(cond.else_expr);
                c.patch(to_end, c.here());
            },
            .assign_pattern => |ap| {
                try c.expr(ap.value);
                try c.emit(.dup, &.{});
                try c.bindPattern(ap.pattern, .assign);
            },
            .spread, .hole => unreachable,
            .assign => |a| switch (a.target) {
                .ref => |ref| switch (a.op) {
                    .plain => {
                        // x = e: evaluate e first; the TDZ and const checks happen on the write.
                        try c.expr(a.value);
                        try c.write(ref);
                    },
                    .compound => |op| {
                        // x op= e: read x (TDZ), evaluate e, apply op, then write (const check).
                        try c.read(ref);
                        try c.expr(a.value);
                        try c.emit(binaryOp(op), &.{});
                        try c.write(ref);
                    },
                    .logical_and, .logical_or, .nullish => {
                        try c.read(ref);
                        const to_short = try c.jumpIfLogicalAssignShortCircuit(a.op);
                        try c.emit(.pop, &.{});
                        try c.expr(a.value);
                        try c.write(ref);
                        c.patch(to_short, c.here());
                    },
                },
                // Base and key exactly once, before the right-hand side (dup/dup2 keep them
                // for the write). `op=` reads before evaluating the right-hand side.
                .member => |m| {
                    try c.expr(m.object);
                    const named = switch (m.key) {
                        .name => |n| n,
                        .computed => |k| blk: {
                            try c.expr(k);
                            break :blk null;
                        },
                        .string, .number => unreachable, // only in literals
                    };
                    switch (a.op) {
                        .plain => {
                            try c.expr(a.value);
                            if (named) |n| try c.emit(.set_prop, &.{try c.name(n)}) else try c.emit(.set_elem, &.{});
                        },
                        .compound => |op| {
                            if (named) |n| {
                                try c.emit(.dup, &.{});
                                try c.emit(.get_prop, &.{try c.name(n)});
                            } else {
                                try c.emit(.dup2, &.{});
                                try c.emit(.get_elem, &.{});
                            }
                            try c.expr(a.value);
                            try c.emit(binaryOp(op), &.{});
                            if (named) |n| try c.emit(.set_prop, &.{try c.name(n)}) else try c.emit(.set_elem, &.{});
                        },
                        .logical_and, .logical_or, .nullish => {
                            const computed = named == null;
                            if (named) |n| {
                                try c.emit(.dup, &.{});
                                try c.emit(.get_prop, &.{try c.name(n)});
                            } else {
                                try c.emit(.dup2, &.{});
                                try c.emit(.get_elem, &.{});
                            }
                            const to_short = try c.jumpIfLogicalAssignShortCircuit(a.op);
                            try c.emit(.pop, &.{});
                            try c.expr(a.value);
                            if (named) |n| try c.emit(.set_prop, &.{try c.name(n)}) else try c.emit(.set_elem, &.{});
                            const to_end = try c.jumpForward(.jump);
                            // Short-circuit path arrives with [o, old] or [o, k, old]; move `old`
                            // below the kept target parts and pop them.
                            c.depth += if (computed) 2 else 1;
                            c.patch(to_short, c.here());
                            try c.emit(.dup, &.{});
                            try c.emit(if (computed) .rot4 else .rot3, &.{});
                            try c.emit(.pop, &.{});
                            try c.emit(.pop, &.{});
                            if (computed) try c.emit(.pop, &.{});
                            c.patch(to_end, c.here());
                        },
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
            .optional_chain => |oc| try c.optionalChain(oc, false),
            .delete => |m| try c.member(m, .delete),
            .delete_optional => |oc| try c.optionalChain(oc, true),
            .this => try c.emit(.push_this, &.{}),
            .array => |items| {
                const has_spread = for (items) |item| {
                    if (item.data == .spread) break true;
                } else false;
                if (!has_spread) {
                    for (items) |item| try c.expr(item);
                    try c.emit(.new_array, &.{@intCast(items.len)});
                } else {
                    try c.compileArgsArray(items);
                }
            },
            .object => |props| {
                // Each key (if computed), then its value, in source order.
                try c.emit(.new_object, &.{});
                for (props) |prop| switch (prop) {
                    .prop => |pr| switch (pr.key) {
                        .name => |n| {
                            try c.expr(pr.value);
                            try c.emit(.define_prop, &.{try c.name(n)});
                        },
                        .string => |units| {
                            try c.emit(.push_const, &.{try c.string(units)});
                            try c.expr(pr.value);
                            try c.emit(.define_elem, &.{});
                        },
                        .number => |n| {
                            try c.emit(.push_const, &.{try c.number(n)});
                            try c.expr(pr.value);
                            try c.emit(.define_elem, &.{});
                        },
                        .computed => |k| {
                            try c.expr(k);
                            try c.expr(pr.value);
                            try c.emit(.define_elem, &.{});
                        },
                    },
                    .spread => |sp| {
                        try c.expr(sp.expr);
                        try c.emit(.object_spread, &.{});
                    },
                    .cover_init => unreachable,
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
                const has_spread = for (call.args) |arg| {
                    if (arg.data == .spread) break true;
                } else false;
                if (has_spread) {
                    try c.compileArgsArray(call.args);
                    try c.emit(if (method) .call_method_spread else .call_spread, &.{});
                } else {
                    for (call.args) |arg| try c.expr(arg);
                    try c.emit(if (method) .call_method else .call, &.{@intCast(call.args.len)}); // args.len < source size
                }
            },
            .new_call => |nc| {
                try c.expr(nc.callee);
                const has_spread = for (nc.args) |arg| {
                    if (arg.data == .spread) break true;
                } else false;
                if (has_spread) {
                    try c.compileArgsArray(nc.args);
                    try c.emit(.new_call_spread, &.{});
                } else {
                    for (nc.args) |arg| try c.expr(arg);
                    try c.emit(.new_call, &.{@intCast(nc.args.len)});
                }
            },
        }
    }

    fn jumpIfNullish(c: *Compiler, targets: *std.ArrayList(u32)) Error!void {
        try c.emit(.dup, &.{});
        try c.emit(.push_null, &.{});
        try c.emit(.strict_eq, &.{});
        try targets.append(c.s.gpa, try c.jumpForward(.jump_if_true));
        try c.emit(.dup, &.{});
        try c.emit(.push_undefined, &.{});
        try c.emit(.strict_eq, &.{});
        try targets.append(c.s.gpa, try c.jumpForward(.jump_if_true));
    }

    fn optionalChain(c: *Compiler, oc: ast.OptionalChain, is_delete: bool) Error!void {
        var short_1: std.ArrayList(u32) = .empty;
        defer short_1.deinit(c.s.gpa);
        var short_2: std.ArrayList(u32) = .empty;
        defer short_2.deinit(c.s.gpa);

        var has_receiver = false;
        if (oc.steps[0].kind == .call and oc.base.data == .member) {
            const m = oc.base.data.member;
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
            has_receiver = true;
        } else {
            try c.expr(oc.base);
        }

        for (oc.steps, 0..) |step, i| {
            if (step.optional) {
                try c.jumpIfNullish(if (has_receiver) &short_2 else &short_1);
            }
            switch (step.kind) {
                .prop => |n| {
                    if (is_delete and i == oc.steps.len - 1) {
                        try c.emit(.delete_prop, &.{try c.name(n)});
                    } else {
                        if (i + 1 < oc.steps.len and oc.steps[i + 1].kind == .call) {
                            try c.emit(.dup, &.{});
                            has_receiver = true;
                        }
                        try c.emit(.get_prop, &.{try c.name(n)});
                    }
                },
                .elem => |k| {
                    if (is_delete and i == oc.steps.len - 1) {
                        try c.expr(k);
                        try c.emit(.delete_elem, &.{});
                    } else {
                        if (i + 1 < oc.steps.len and oc.steps[i + 1].kind == .call) {
                            try c.emit(.dup, &.{});
                            has_receiver = true;
                        }
                        try c.expr(k);
                        try c.emit(.get_elem, &.{});
                    }
                },
                .call => |args| {
                    const has_spread = for (args) |arg| {
                        if (arg.data == .spread) break true;
                    } else false;
                    if (has_spread) {
                        try c.compileArgsArray(args);
                        try c.emit(if (has_receiver) .call_method_spread else .call_spread, &.{});
                    } else {
                        for (args) |arg| try c.expr(arg);
                        try c.emit(if (has_receiver) .call_method else .call, &.{@intCast(args.len)});
                    }
                    has_receiver = false;
                },
            }
        }
        std.debug.assert(!has_receiver);

        const to_end = try c.jumpForward(.jump);
        if (short_2.items.len > 0) {
            c.depth += 1;
            for (short_2.items) |j| c.patch(j, c.here());
            try c.emit(.pop, &.{});
        }
        for (short_1.items) |j| c.patch(j, c.here());
        try c.emit(.pop, &.{});
        try c.emit(if (is_delete) .push_true else .push_undefined, &.{});
        c.patch(to_end, c.here());
    }

    fn compileArgsArray(c: *Compiler, items: []const *const ast.Expr) Error!void {
        try c.emit(.new_array, &.{0});
        for (items) |item| {
            if (item.data == .spread) {
                try c.expr(item.data.spread);
                try c.emit(.array_spread, &.{});
            } else {
                try c.expr(item);
                try c.emit(.array_push, &.{});
            }
        }
    }

    const MemberSlots = struct {
        base_slot: u32,
        key_slot: ?u32,
        prop_name: ?[]const u8,
    };

    fn preEvalMemberTarget(c: *Compiler, pat: *const ast.Pattern) Error!?MemberSlots {
        if (pat.data != .target or pat.data.target != .member) return null;
        const m = pat.data.target.member;
        try c.expr(m.object);
        const base_slot = c.allocTemp();
        try c.emit(.init_local, &.{base_slot});
        switch (m.key) {
            .name => |n| return .{ .base_slot = base_slot, .key_slot = null, .prop_name = n },
            .computed => |k| {
                try c.expr(k);
                const key_slot = c.allocTemp();
                try c.emit(.init_local, &.{key_slot});
                return .{ .base_slot = base_slot, .key_slot = key_slot, .prop_name = null };
            },
            .string, .number => unreachable,
        }
    }

    fn storeMemberSlots(c: *Compiler, ms: MemberSlots) Error!void {
        const val_slot = c.allocTemp();
        try c.emit(.init_local, &.{val_slot});
        try c.emit(.get_local, &.{ ms.base_slot, try c.name("<base>") });
        if (ms.key_slot) |ks| try c.emit(.get_local, &.{ ks, try c.name("<key>") });
        try c.emit(.get_local, &.{ val_slot, try c.name("<val>") });
        if (ms.prop_name) |n| {
            try c.emit(.set_prop, &.{try c.name(n)});
        } else {
            try c.emit(.set_elem, &.{});
        }
        try c.emit(.pop, &.{});
        try c.emit(.clear_local, &.{val_slot});
        c.freeTemp();
        if (ms.key_slot) |ks| {
            try c.emit(.clear_local, &.{ks});
            c.freeTemp();
        }
        try c.emit(.clear_local, &.{ms.base_slot});
        c.freeTemp();
    }

    /// Consumes the top of the stack and binds/assigns it according to `pat`.
    fn bindPattern(c: *Compiler, pat: *const ast.Pattern, mode: enum { init, assign }) Error!void {
        switch (pat.data) {
            .binding => |d| try c.initBinding(d.binding),
            .target => |t| switch (t) {
                .ref => |ref| {
                    try c.write(ref);
                    try c.emit(.pop, &.{});
                },
                .member => |m| {
                    const val_slot = c.allocTemp();
                    defer c.freeTemp();
                    try c.emit(.init_local, &.{val_slot});
                    try c.expr(m.object);
                    switch (m.key) {
                        .name => |n| {
                            try c.emit(.get_local, &.{ val_slot, try c.name("<val>") });
                            try c.emit(.set_prop, &.{try c.name(n)});
                        },
                        .computed => |k| {
                            try c.expr(k);
                            try c.emit(.get_local, &.{ val_slot, try c.name("<val>") });
                            try c.emit(.set_elem, &.{});
                        },
                        .string, .number => unreachable,
                    }
                    try c.emit(.pop, &.{});
                    try c.emit(.clear_local, &.{val_slot});
                },
            },
            .array => |arr| {
                try c.emit(.get_iter, &.{});
                const iter_slot = c.allocTemp();
                defer c.freeTemp();
                try c.emit(.init_local, &.{iter_slot});
                for (arr.elems) |maybe_el| {
                    const el = maybe_el orelse {
                        try c.emit(.get_local, &.{ iter_slot, try c.name("<iter>") });
                        try c.emit(.iter_next, &.{});
                        try c.emit(.pop, &.{});
                        try c.emit(.pop, &.{});
                        continue;
                    };
                    const ms = if (mode == .assign) try c.preEvalMemberTarget(el.pattern) else null;
                    try c.emit(.get_local, &.{ iter_slot, try c.name("<iter>") });
                    try c.emit(.iter_next, &.{});
                    try c.emit(.pop, &.{});
                    if (el.default) |def| {
                        const skip = try c.jumpIfNotUndefined();
                        try c.emit(.pop, &.{});
                        try c.expr(def);
                        c.patch(skip, c.here());
                    }
                    if (ms) |slots| try c.storeMemberSlots(slots) else try c.bindPattern(el.pattern, mode);
                }
                if (arr.rest) |rest| {
                    const ms = if (mode == .assign) try c.preEvalMemberTarget(rest) else null;
                    try c.emit(.get_local, &.{ iter_slot, try c.name("<iter>") });
                    try c.emit(.iter_rest, &.{});
                    if (ms) |slots| try c.storeMemberSlots(slots) else try c.bindPattern(rest, mode);
                }
                try c.emit(.clear_local, &.{iter_slot});
            },
            .object => |obj| {
                try c.emit(.require_obj, &.{});
                const src_slot = c.allocTemp();
                defer c.freeTemp();
                try c.emit(.init_local, &.{src_slot});

                var computed_slots: std.ArrayList(u32) = .empty;
                defer computed_slots.deinit(c.s.gpa);

                for (obj.props) |pr| {
                    var k_slot: ?u32 = null;
                    if (pr.key == .computed) {
                        try c.expr(pr.key.computed);
                        k_slot = c.allocTemp();
                        try c.emit(.init_local, &.{k_slot.?});
                        try computed_slots.append(c.s.gpa, k_slot.?);
                    }
                    const ms = if (mode == .assign) try c.preEvalMemberTarget(pr.pattern) else null;
                    try c.emit(.get_local, &.{ src_slot, try c.name("<obj>") });
                    switch (pr.key) {
                        .name => |n| try c.emit(.get_prop, &.{try c.name(n)}),
                        .string => |u| {
                            try c.emit(.push_const, &.{try c.string(u)});
                            try c.emit(.get_elem, &.{});
                        },
                        .number => |n| {
                            try c.emit(.push_const, &.{try c.number(n)});
                            try c.emit(.get_elem, &.{});
                        },
                        .computed => {
                            try c.emit(.get_local, &.{ k_slot.?, try c.name("<key>") });
                            try c.emit(.get_elem, &.{});
                        },
                    }
                    if (pr.default) |def| {
                        const skip = try c.jumpIfNotUndefined();
                        try c.emit(.pop, &.{});
                        try c.expr(def);
                        c.patch(skip, c.here());
                    }
                    if (ms) |slots| try c.storeMemberSlots(slots) else try c.bindPattern(pr.pattern, mode);
                }
                if (obj.rest) |rest| {
                    const ms = if (mode == .assign) try c.preEvalMemberTarget(rest) else null;
                    try c.emit(.get_local, &.{ src_slot, try c.name("<obj>") });
                    var ci: usize = 0;
                    for (obj.props) |pr| switch (pr.key) {
                        .name => |n| {
                            const units = try c.s.gpa.alloc(u16, n.len);
                            defer c.s.gpa.free(units);
                            for (n, units) |ch, *u| u.* = ch;
                            try c.emit(.push_const, &.{try c.string(units)});
                        },
                        .string => |u| try c.emit(.push_const, &.{try c.string(u)}),
                        .number => |n| try c.emit(.push_const, &.{try c.number(n)}),
                        .computed => {
                            try c.emit(.get_local, &.{ computed_slots.items[ci], try c.name("<key>") });
                            ci += 1;
                        },
                    };
                    try c.emit(.object_rest, &.{@intCast(obj.props.len)});
                    if (ms) |slots| try c.storeMemberSlots(slots) else try c.bindPattern(rest, mode);
                }
                var i = computed_slots.items.len;
                while (i > 0) {
                    i -= 1;
                    try c.emit(.clear_local, &.{computed_slots.items[i]});
                    c.freeTemp();
                }
                try c.emit(.clear_local, &.{src_slot});
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

    /// Expects `[..., old]` on the stack. Emits a test that jumps to the returned
    /// target if the logical assignment should short-circuit (keeping `old`), or
    /// falls through (still with `[..., old]`) when the right-hand side should run.
    fn jumpIfLogicalAssignShortCircuit(c: *Compiler, op: ast.AssignOp) Error!u32 {
        switch (op) {
            .logical_and => {
                try c.emit(.dup, &.{});
                return c.jumpForward(.jump_if_false);
            },
            .logical_or => {
                try c.emit(.dup, &.{});
                return c.jumpForward(.jump_if_true);
            },
            .nullish => {
                try c.emit(.dup, &.{});
                try c.emit(.push_null, &.{});
                try c.emit(.strict_eq, &.{});
                const to_assign = try c.jumpForward(.jump_if_true);
                try c.emit(.dup, &.{});
                try c.emit(.push_undefined, &.{});
                try c.emit(.strict_eq, &.{});
                const to_short = try c.jumpForward(.jump_if_false);
                c.patch(to_assign, c.here());
                return to_short;
            },
            .plain, .compound => unreachable,
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
        .logical_and, .logical_or, .nullish => unreachable, // control flow, handled by the caller
    };
}
