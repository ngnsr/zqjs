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
const heap_mod = @import("../runtime/heap.zig");
const bigint_mod = @import("../runtime/bigint.zig");
const Value = @import("../runtime/value.zig").Value;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const Proto = bc.Proto;

pub const Error = error{ LimitExceeded, OutOfMemory };

pub const CompileOptions = struct {
    repl: bool = false,
    top_level_await: bool = false,
    is_module: bool = false,
};

/// Compiles a resolved script. String constants are allocated on `heap` (see Proto for
/// ownership); everything else with `gpa`. On LimitExceeded, `diag` says which limit
/// and where. On any error nothing is leaked and the heap is as before.
pub fn compile(gpa: Allocator, heap: *Heap, script: ast.Script, res: Resolution, limits: Limits, diag: *Diagnostic) Error!Proto {
    return compileWithOptions(gpa, heap, script, res, limits, .{}, diag);
}

pub fn compileWithOptions(gpa: Allocator, heap: *Heap, script: ast.Script, res: Resolution, limits: Limits, options: CompileOptions, diag: *Diagnostic) Error!Proto {
    const heap_mark = heap.mark();
    errdefer heap.rollback(heap_mark);
    var shared: Shared = .{ .gpa = gpa, .heap = heap, .res = res, .limits = limits, .options = options, .diag = diag, .script_strict = script.is_strict or options.is_module };
    return shared.proto(.script, null, script.statements);
}

/// State shared by the compilers of all functions of one script.
const Shared = struct {
    gpa: Allocator,
    heap: *Heap,
    res: Resolution,
    limits: Limits,
    options: CompileOptions = .{},
    diag: *Diagnostic,
    script_strict: bool = false,
    /// Code bytes of all Protos so far (Limits.max_code_bytes bounds the whole script).
    code_bytes: usize = 0,

    /// Compiles one script or function into a Proto (and, recursively, its functions).
    fn proto(s: *Shared, kind: @FieldType(Proto, "kind"), f: ?*const ast.Function, body: []const ast.Stmt) Error!Proto {
        var c: Compiler = .{
            .s = s,
            .function = if (f) |func| func.id else 0,
            .is_async_generator = if (f) |func| func.is_async and func.is_generator else false,
        };
        defer c.deinit();

        if (f) |func| {
            // A named expression's own name: the running closure (visible to parameter defaults).
            if (func.kind == .expression) if (func.name) |n| {
                if (c.binding(n.binding).captured) try c.emit(.new_cell, &.{c.slotOf(n.binding)});
                try c.emit(.push_callee, &.{});
                try c.initBinding(n.binding);
            };
            const fn_info = c.s.res.functions[func.id];
            if (fn_info.arguments_binding) |ab| {
                if (c.binding(ab).captured) try c.emit(.new_cell, &.{c.slotOf(ab)});
                try c.emit(.make_arguments, &.{});
                try c.initBinding(ab);
            }
            if (fn_info.is_simple_params) {
                // Parameters arrive as plain values; box the captured ones.
                for (func.params) |p| {
                    const b = p.pattern.data.binding.binding;
                    if (c.binding(b).captured) {
                        try c.emit(.box_local, &.{c.slotOf(b)});
                    } else {
                        c.markSlotInit(c.slotOf(b));
                    }
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
            // Parameters bind on the call; the generator object is returned here (D67).
            if (func.is_generator) try c.emit(.generator_start, &.{});
        }
        // Hoisted `var` bindings start as `undefined` (fresh cell if captured) before any statement runs.
        for (c.s.res.functions[c.function].var_bindings) |vb| {
            const b = c.binding(vb);
            if (b.repl_index != null) continue;
            const sl = c.slotOf(vb);
            if (b.captured) {
                try c.emit(.new_cell, &.{sl});
                try c.emit(.push_undefined, &.{});
                try c.emit(.init_cell, &.{sl});
            } else {
                try c.emit(.push_undefined, &.{});
                try c.emit(.init_local, &.{sl});
                c.markSlotInit(sl);
            }
        }
        const completes = try c.statementsImpl(body, .{ .start = 0, .end = 0 }, kind == .script and s.options.repl);
        if (completes) switch (kind) {
            .script => if (s.options.top_level_await) {
                try c.emit(.push_undefined, &.{});
                try c.emit(.@"return", &.{});
            } else {
                try c.emit(.halt, &.{});
            },
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
    /// Set for `for...of` loops so `return`/outer jumps close the iterator.
    iter_slot: ?u32 = null,
    /// `for await`: closing awaits `return()`'s result (AsyncIteratorClose, D68).
    is_await: bool = false,
};

const JumpTarget = union(enum) {
    loop_break: *Loop,
    loop_continue: *Loop,
    switch_break: *std.ArrayList(u32),

    fn eql(a: JumpTarget, b: JumpTarget) bool {
        return switch (a) {
            .loop_break => |pa| b == .loop_break and pa == b.loop_break,
            .loop_continue => |pa| b == .loop_continue and pa == b.loop_continue,
            .switch_break => |pa| b == .switch_break and pa == b.switch_break,
        };
    }

    fn append(self: JumpTarget, gpa: std.mem.Allocator, j: u32) !void {
        switch (self) {
            .loop_break => |l| try l.breaks.append(gpa, j),
            .loop_continue => |l| try l.continues.append(gpa, j),
            .switch_break => |s| try s.append(gpa, j),
        }
    }
};

const FinallyContext = struct {
    kind_slot: u32,
    val_slot: u32,
    to_finally: std.ArrayList(u32) = .empty,
    jumps: std.ArrayList(JumpTarget) = .empty,
    has_return: bool = false,

    fn deinit(fc: *FinallyContext, gpa: std.mem.Allocator) void {
        fc.to_finally.deinit(gpa);
        fc.jumps.deinit(gpa);
    }

    fn addJump(fc: *FinallyContext, gpa: std.mem.Allocator, jt: JumpTarget) !u32 {
        for (fc.jumps.items, 0..) |existing, i| {
            if (existing.eql(jt)) return @intCast(3 + i);
        }
        try fc.jumps.append(gpa, jt);
        return @intCast(3 + fc.jumps.items.len - 1);
    }
};

const LabelTarget = struct {
    name: []const u8,
    breaks: std.ArrayList(u32) = .empty,
    loop: ?*Loop = null,
};

const ControlContext = union(enum) {
    loop: *Loop,
    @"switch": *std.ArrayList(u32),
    label: *LabelTarget,
    finally_region: *FinallyContext,
    finally_body: *FinallyContext,
};

const BigIntIndexCtx = struct {
    pub fn hash(_: @This(), b: *const heap_mod.BigInt) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(&.{@intFromBool(b.negative)});
        hasher.update(std.mem.sliceAsBytes(b.limbs));
        return hasher.final();
    }
    pub fn eql(_: @This(), a: *const heap_mod.BigInt, b: *const heap_mod.BigInt) bool {
        return a.negative == b.negative and std.mem.eql(u64, a.limbs, b.limbs);
    }
};

/// The compiler of one function (or the script).
const Compiler = struct {
    s: *Shared,
    /// Resolution.functions index of the function being compiled.
    function: u32,
    /// `yield` and `return e` await their operand; `yield*` is async (D68).
    is_async_generator: bool = false,
    /// Bitset of local slots 0..63 guaranteed initialized on all paths reaching the current PC (M54).
    init_slots: u64 = 0,

    code: std.ArrayList(u8) = .empty,
    consts: std.ArrayList(Value) = .empty,
    names: std.ArrayList([]const u8) = .empty,
    functions: std.ArrayList(Proto) = .empty,
    handlers: std.ArrayList(Proto.ExceptionHandler) = .empty,
    templates: std.ArrayList(Proto.TemplateSite) = .empty,
    // Deduplication. Numbers by bit pattern, so 0 and -0 stay distinct and every NaN
    // literal (there is only one bit pattern the lexer produces) shares one entry.
    number_index: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    // Strings by content; keys are the literals' UTF-16 units as bytes, which live in
    // the AST arena for the whole compilation.
    string_index: std.StringHashMapUnmanaged(u32) = .empty,
    bigint_index: std.HashMapUnmanaged(*const heap_mod.BigInt, u32, BigIntIndexCtx, std.hash_map.default_max_load_percentage) = .empty,
    name_index: std.StringHashMapUnmanaged(u32) = .empty,

    depth: u32 = 0,
    max_stack: u32 = 0,
    temp_depth: u32 = 0,
    max_temp: u32 = 0,
    /// Active control contexts (loops, switches, finally regions/bodies), innermost last.
    controls: std.ArrayList(ControlContext) = .empty,
    /// Span of the statement being compiled, for limit diagnostics.
    span: ast.Span = .{ .start = 0, .end = 0 },

    /// Frees everything not handed over by `finish` (all of it, after an error).
    fn deinit(c: *Compiler) void {
        const gpa = c.s.gpa;
        c.number_index.deinit(gpa);
        c.string_index.deinit(gpa);
        c.bigint_index.deinit(gpa);
        c.name_index.deinit(gpa);
        c.code.deinit(gpa);
        c.consts.deinit(gpa);
        for (c.names.items) |n| gpa.free(n);
        c.names.deinit(gpa);
        for (c.functions.items) |*f| f.deinit(gpa);
        c.functions.deinit(gpa);
        c.handlers.deinit(gpa);
        for (c.templates.items) |t| {
            gpa.free(t.cooked);
            gpa.free(t.raw);
        }
        c.templates.deinit(gpa);
        c.controls.deinit(gpa);
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
        const inferred_src: []const u8 = if (f) |func| func.inferred_name else "";
        const inferred_copy: []const u8 = if (inferred_src.len > 0) try gpa.dupe(u8, inferred_src) else "";
        errdefer if (inferred_copy.len > 0) gpa.free(inferred_copy);
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
            name_atoms[i] = c.s.heap.internUtf8(n) catch |e| switch (e) {
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
        const templates = try c.templates.toOwnedSlice(gpa);
        // Ownership of names and nested Protos has moved: don't free them twice.
        c.names.clearRetainingCapacity();
        c.functions.clearRetainingCapacity();
        return .{
            .kind = kind,
            .is_arrow = if (f) |func| func.is_arrow else false,
            .is_async = if (f) |func| func.is_async or func.is_generator else c.s.options.top_level_await,
            .is_generator = if (f) |func| func.is_generator else false,
            .is_async_generator = if (f) |func| func.is_async and func.is_generator else false,
            .is_method = if (f) |func| func.is_method else false,
            .is_class_constructor = if (f) |func| func.is_class_constructor else false,
            .is_strict = if (f) |func| func.is_strict else c.s.script_strict,
            .has_super_ctor = if (f) |func| func.has_super_ctor else false,
            .has_home_object = if (f) |func| func.has_home_object else false,
            .length = if (f) |func| func.length else 0,
            .name = name_copy,
            .inferred_name = inferred_copy,
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
            .templates = templates,
            .repl_count = @intCast(c.s.res.repl_bindings.len),
            .is_module = if (f == null) c.s.options.is_module else false,
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
        gop.value_ptr.* = try c.constant(Value.fromNumber(n));
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
        gop.value_ptr.* = try c.constant(Value.fromString(str));
        return gop.value_ptr.*;
    }

    fn bigintConst(c: *Compiler, raw: []const u8) Error!u32 {
        if (c.consts.items.len >= c.s.limits.max_constants) return c.limit(.constants);
        const b = bigint_mod.parseLiteralToHeap(c.s.heap, c.s.gpa, c.s.limits.max_bigint_bits, raw) catch |e| switch (e) {
            error.LimitExceeded => return c.limit(c.s.heap.limit_hit orelse .heap_bytes),
            error.OutOfMemory => return error.OutOfMemory,
        };
        const gop = try c.bigint_index.getOrPut(c.s.gpa, b);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = c.bigint_index.remove(b);
        gop.value_ptr.* = try c.constant(Value.fromBigInt(b));
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
        return c.statementsImpl(stmts, span, false);
    }

    fn statementsImpl(c: *Compiler, stmts: []const ast.Stmt, span: ast.Span, repl_top: bool) Error!bool {
        c.span = span;
        const is_module_top = c.function == 0 and c.s.options.is_module;
        const saved_init = c.init_slots;
        defer c.init_slots = saved_init;

        // Inside nested loops/blocks, skip dead `clear_local` for leading simple
        // non-captured `let`/`const` declarations whose pure initializers cannot
        // observe TDZ (M54).
        var skip_clear_prefix: usize = 0;
        if (c.controls.items.len > 0) {
            var has_hoisted = false;
            for (stmts) |s| switch (s.data) {
                .function, .class => {
                    has_hoisted = true;
                    break;
                },
                else => {},
            };
            if (!has_hoisted) {
                var pending_slots: u64 = 0;
                for (stmts) |s| switch (s.data) {
                    .declaration => |decl| if (decl.kind != .@"var") for (decl.declarators) |d| {
                        if (d.pattern.data == .binding) {
                            const b = d.pattern.data.binding.binding;
                            if (c.binding(b).repl_index == null and !c.binding(b).captured) {
                                const sl = c.slotOf(b);
                                if (sl < 64) pending_slots |= (@as(u64, 1) << @intCast(sl));
                            }
                        }
                    },
                    else => {},
                };
                for (stmts) |s| {
                    if (s.data != .declaration) break;
                    const decl = s.data.declaration;
                    if (decl.kind == .@"var") break;
                    var all_safe = true;
                    for (decl.declarators) |d| {
                        if (d.pattern.data != .binding or d.init == null) {
                            all_safe = false;
                            break;
                        }
                        const b = d.pattern.data.binding.binding;
                        if (c.binding(b).repl_index != null or c.binding(b).captured or c.slotOf(b) >= 64) {
                            all_safe = false;
                            break;
                        }
                        if (!c.isPureNoPendingTdz(d.init.?, pending_slots)) {
                            all_safe = false;
                            break;
                        }
                    }
                    if (!all_safe) break;
                    for (decl.declarators) |d| {
                        const sl = c.slotOf(d.pattern.data.binding.binding);
                        pending_slots &= ~(@as(u64, 1) << @intCast(sl));
                    }
                    skip_clear_prefix += 1;
                }
            }
        }

        for (stmts, 0..) |s, si| switch (s.data) {
            .declaration => |decl| if (decl.kind != .@"var" and si >= skip_clear_prefix) {
                for (decl.declarators) |d| try c.enterPatternBindings(d.pattern);
            },
            .function => |f| {
                const b = c.binding(f.name.?.binding);
                if (b.repl_index == null and b.alias_of == null and b.captured) try c.emit(.new_cell, &.{c.slotOf(f.name.?.binding)});
            },
            .class => |cls| try c.enterBinding(cls.name.?.binding),
            else => {},
        };
        for (stmts) |s| switch (s.data) {
            .function => |f| {
                if (is_module_top) {
                    _ = try c.compileTopFunction(f);
                } else {
                    try c.closure(f);
                    try c.initBinding(f.name.?.binding);
                }
            },
            .export_decl => |exp| switch (exp) {
                .function => |f| {
                    _ = try c.compileTopFunction(f);
                },
                .default_function => |df| {
                    _ = try c.compileTopFunction(df.func);
                },
                else => {},
            },
            else => {},
        };
        for (stmts, 0..) |s, idx| {
            if (repl_top and idx + 1 == stmts.len and s.data == .expression) {
                c.span = s.span;
                try c.expr(s.data.expression);
                if (c.s.options.top_level_await) {
                    try c.emit(.@"return", &.{});
                    return false;
                }
                try c.emit(.save_repl_result, &.{});
                continue;
            }
            if (!try c.stmt(s)) return false;
        }
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

    inline fn markSlotInit(c: *Compiler, slot: u32) void {
        if (slot < 64) c.init_slots |= (@as(u64, 1) << @intCast(slot));
    }

    inline fn clearSlotInit(c: *Compiler, slot: u32) void {
        if (slot < 64) c.init_slots &= ~(@as(u64, 1) << @intCast(slot));
    }

    inline fn isSlotInit(c: *const Compiler, slot: u32) bool {
        return slot < 64 and (c.init_slots & (@as(u64, 1) << @intCast(slot))) != 0;
    }

    /// True if `e` is a side-effect-free expression that cannot read any binding in `pending_slots`.
    fn isPureNoPendingTdz(c: *const Compiler, e: *const ast.Expr, pending_slots: u64) bool {
        return switch (e.data) {
            .number, .string, .boolean, .null, .bigint => true,
            .identifier => |ref| switch (c.s.res.refs[ref.id]) {
                .local => |b| blk: {
                    if (c.binding(b).captured) break :blk false;
                    const sl = c.slotOf(b);
                    break :blk sl < 64 and (pending_slots & (@as(u64, 1) << @intCast(sl))) == 0;
                },
                else => false,
            },
            .unary => |u| u.op != .typeof and c.isPureNoPendingTdz(u.operand, pending_slots),
            .binary => |b| c.isPureNoPendingTdz(b.lhs, pending_slots) and c.isPureNoPendingTdz(b.rhs, pending_slots),
            else => false,
        };
    }

    /// The binding's scope is being entered: TDZ (a fresh cell if captured).
    fn enterBinding(c: *Compiler, b: u32) Error!void {
        if (c.binding(b).repl_index != null) return;
        const sl = c.slotOf(b);
        c.clearSlotInit(sl);
        try c.emit(if (c.binding(b).captured) .new_cell else .clear_local, &.{sl});
    }

    /// Pops the top of the stack into binding `b` of this function (no TDZ/const check).
    fn initBinding(c: *Compiler, b: u32) Error!void {
        if (c.binding(b).repl_index) |repl_idx| {
            try c.emit(.init_repl, &.{repl_idx});
            return;
        }
        const sl = c.slotOf(b);
        if (c.binding(b).captured) {
            try c.emit(.init_cell, &.{sl});
        } else {
            try c.emit(.init_local, &.{sl});
            c.markSlotInit(sl);
        }
    }

    fn declare(c: *Compiler, decl: ast.Declaration) Error!void {
        for (decl.declarators) |d| {
            // Hoisted `var x;` without an initializer is a no-op (must not clobber an existing value).
            if (decl.kind == .@"var" and d.init == null) continue;
            if (d.init) |init| try c.expr(init) else try c.emit(.push_undefined, &.{});
            try c.bindPattern(d.pattern, .init);
        }
    }

    /// Compiles a nested function and appends its Proto without emitting `make_closure`
    /// (used for module top-level functions hoisted at Link time, D72).
    fn compileTopFunction(c: *Compiler, f: *const ast.Function) Error!u32 {
        const outer_span = c.span;
        var child = try c.s.proto(.function, f, f.body);
        {
            errdefer child.deinit(c.s.gpa);
            try c.functions.append(c.s.gpa, child);
        }
        c.span = outer_span;
        return @intCast(c.functions.items.len - 1);
    }

    /// `make_closure` for a nested function, compiling it first.
    fn closure(c: *Compiler, f: *const ast.Function) Error!void {
        const idx = try c.compileTopFunction(f);
        try c.emit(.make_closure, &.{idx});
    }

    /// Returns whether control can reach the end of the statement.
    fn stmt(c: *Compiler, s: ast.Stmt) Error!bool {
        c.span = s.span;
        switch (s.data) {
            .empty, .function => {}, // functions were created on entry to the body
            .expression => |e| try c.exprDiscard(e),
            .declaration => |decl| try c.declare(decl),
            .class => |cls| {
                try c.compileClass(cls, false);
                try c.initBinding(cls.name.?.binding);
            },
            .block => |stmts| return c.statements(stmts, s.span),
            .@"return" => |v| {
                if (v) |e| {
                    try c.expr(e);
                    if (c.is_async_generator) try c.emit(.await, &.{}); // D68
                } else try c.emit(.push_undefined, &.{});
                try c.emitReturn();
                return false;
            },
            .throw => |e| {
                try c.expr(e);
                try c.emit(.throw, &.{});
                return false;
            },
            .@"try" => |t| return c.compileTry(t, s.span),
            .@"if" => |i| {
                const to_else = try c.jumpIfFalseExpr(i.cond);
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
                c.attachLabelsToLoop(&loop);
                c.attachLabelsToLoop(&loop);
                const top = c.here();
                const to_end = try c.jumpIfFalseExpr(w.cond);
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
                c.attachLabelsToLoop(&loop);
                c.attachLabelsToLoop(&loop);
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
                const saved_init = c.init_slots;
                defer c.init_slots = saved_init;
                // init; [copy]; top: [cond; jump_if_false end]; body;
                // cont: [copy]; [update; pop]; jump top; end:
                // `copy` gives captured `let` head bindings fresh cells per iteration
                // (CreatePerIterationEnvironment), as the tree-walker copies its record.
                var copies: []const ast.DeclItem = &.{};
                if (f.init) |init| switch (init) {
                    .declaration => |decl| {
                        if (decl.kind != .@"var") {
                            for (decl.declarators) |d| try c.enterPatternBindings(d.pattern);
                        }
                        try c.declare(decl);
                        if (decl.kind == .let) copies = decl.declarators;
                    },
                    .expression => |e| try c.exprDiscard(e),
                };
                try c.perIteration(copies);
                var loop: Loop = .{};
                defer c.deinitLoop(&loop);
                c.attachLabelsToLoop(&loop);
                c.attachLabelsToLoop(&loop);
                const top = c.here();
                const to_end = if (f.cond) |cond| try c.jumpIfFalseExpr(cond) else null;
                const body_completes = try c.loopBody(&loop, f.body.*);
                // `continue` lands on the copy and the update, which still run (as in treewalk).
                if (body_completes or loop.continues.items.len > 0) {
                    for (loop.continues.items) |j| c.patch(j, c.here());
                    try c.perIteration(copies);
                    if (f.update) |u| try c.exprDiscard(u);
                    try c.emit(.jump, &.{top});
                }
                if (to_end) |j| c.patch(j, c.here());
                for (loop.breaks.items) |j| c.patch(j, c.here());
                return to_end != null or loop.breaks.items.len > 0;
            },
            .for_of => |f| {
                // Store iterator in a hidden local slot so the operand stack stays empty
                // across `body` (preserving `return`/`try`/`break`/`continue` stack invariants).
                const loop_depth = c.depth;
                const iter_slot = c.allocTemp();
                defer c.freeTemp();

                var single_copy: [1]ast.DeclItem = undefined;
                var copies: []const ast.DeclItem = &.{};
                if (f.target == .declaration and f.target.declaration.kind != .@"var") {
                    const pat = f.target.declaration.pattern;
                    try c.enterPatternBindings(pat);
                    single_copy[0] = .{ .pattern = pat, .init = null, .span = pat.span };
                    copies = &single_copy;
                }
                try c.expr(f.iterable);
                try c.emit(if (f.is_await) .get_async_iter else .get_iter, &.{});
                try c.emit(.init_local, &.{iter_slot});
                var loop: Loop = .{ .iter_slot = iter_slot, .is_await = f.is_await };
                defer c.deinitLoop(&loop);
                c.attachLabelsToLoop(&loop);
                const top = c.here();
                try c.emit(.get_local, &.{ iter_slot, try c.name("<iter>") });
                if (f.is_await) { // `for await` (D68): await each `next()` result
                    try c.emit(.async_iter_next, &.{});
                    try c.emit(.await, &.{});
                    try c.emit(.async_iter_result, &.{});
                } else try c.emit(.iter_next, &.{});
                const to_end = try c.jumpForward(.jump_if_true);
                const body_bind_start = c.here();
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
                const body_end = c.here();
                if (body_completes) try c.emit(.jump, &.{top});
                for (loop.continues.items) |j| c.patch(j, top);
                if (body_end > body_bind_start) {
                    const catch_pc = c.here();
                    c.depth = loop_depth + 1;
                    c.max_stack = @max(c.max_stack, c.depth);
                    try c.emit(.get_local, &.{ iter_slot, try c.name("<iter>") });
                    if (f.is_await) try c.emitAsyncClose(true) else try c.emit(.iter_close_throw, &.{});
                    try c.emit(.clear_local, &.{iter_slot});
                    try c.emit(.throw, &.{});
                    try c.handlers.append(c.s.gpa, .{
                        .try_start = body_bind_start,
                        .try_end = body_end,
                        .catch_pc = catch_pc,
                        .stack_depth = loop_depth,
                        .has_binding = true,
                    });
                }
                if (loop.breaks.items.len > 0) {
                    c.depth = loop_depth;
                    for (loop.breaks.items) |j| c.patch(j, c.here());
                    try c.emit(.get_local, &.{ iter_slot, try c.name("<iter>") });
                    if (f.is_await) try c.emitAsyncClose(false) else try c.emit(.iter_close, &.{});
                    const after_break = try c.jumpForward(.jump);
                    c.patch(to_end, c.here());
                    // At `to_end` (reached only from `jump_if_true` after `iter_next`), the
                    // stack holds `[undefined]` (`depth + 1` relative to body).
                    c.depth = loop_depth + 1;
                    try c.emit(.pop, &.{});
                    c.patch(after_break, c.here());
                } else {
                    c.patch(to_end, c.here());
                    c.depth = loop_depth + 1;
                    try c.emit(.pop, &.{});
                }
                try c.emit(.clear_local, &.{iter_slot});
                return true;
            },
            .for_in => |f| {
                const loop_depth = c.depth;
                const iter_slot = c.allocTemp();
                defer c.freeTemp();

                var single_copy: [1]ast.DeclItem = undefined;
                var copies: []const ast.DeclItem = &.{};
                if (f.target == .declaration and f.target.declaration.kind != .@"var") {
                    const pat = f.target.declaration.pattern;
                    try c.enterPatternBindings(pat);
                    single_copy[0] = .{ .pattern = pat, .init = null, .span = pat.span };
                    copies = &single_copy;
                }
                try c.expr(f.object);
                try c.emit(.for_in_init, &.{});
                try c.emit(.init_local, &.{iter_slot});
                var loop: Loop = .{};
                defer c.deinitLoop(&loop);
                c.attachLabelsToLoop(&loop);
                const top = c.here();
                try c.emit(.get_local, &.{ iter_slot, try c.name("<iter>") });
                try c.emit(.for_in_next, &.{});
                const to_end = try c.jumpForward(.jump_if_true);
                switch (f.target) {
                    .declaration => |decl| {
                        try c.perIteration(copies);
                        try c.bindPattern(decl.pattern, .init);
                    },
                    .target => |t| try c.bindPattern(t, .assign),
                }
                const body_completes = try c.loopBody(&loop, f.body.*);
                if (body_completes) try c.emit(.jump, &.{top});
                for (loop.continues.items) |j| c.patch(j, top);
                c.patch(to_end, c.here());
                c.depth = loop_depth + 1;
                try c.emit(.pop, &.{});
                for (loop.breaks.items) |j| c.patch(j, c.here());
                try c.emit(.clear_local, &.{iter_slot});
                return true;
            },
            .import_decl => return true,
            .export_decl => |exp| switch (exp) {
                .declaration => |decl| {
                    try c.declare(decl);
                    return true;
                },
                .class => |cls| {
                    try c.compileClass(cls, false);
                    try c.initBinding(cls.name.?.binding);
                    return true;
                },
                .default_expr => |de| {
                    try c.expr(de.expr);
                    try c.initBinding(de.binding);
                    return true;
                },
                .default_class => |dc| {
                    try c.compileClass(dc.cls, false);
                    if (dc.cls.name) |n| {
                        try c.emit(.dup, &.{});
                        try c.initBinding(n.binding);
                    }
                    try c.initBinding(dc.binding);
                    return true;
                },
                .function, .default_function, .named, .reexport_named, .reexport_all => return true,
            },
            .labeled => |l| {
                var target: LabelTarget = .{ .name = l.label };
                defer target.breaks.deinit(c.s.gpa);
                try c.controls.append(c.s.gpa, .{ .label = &target });
                const body_completes = blk: {
                    defer _ = c.controls.pop();
                    break :blk try c.stmt(l.body.*);
                };
                for (target.breaks.items) |j| c.patch(j, c.here());
                return body_completes or target.breaks.items.len > 0;
            },
            // The parser guarantees break/continue only occur inside valid loops/switches/labels.
            .@"break" => |maybe_lbl| {
                var i = c.controls.items.len;
                const jt: JumpTarget = if (maybe_lbl) |lbl| while (i > 0) {
                    i -= 1;
                    switch (c.controls.items[i]) {
                        .label => |lt| if (std.mem.eql(u8, lt.name, lbl)) break .{ .switch_break = &lt.breaks },
                        else => {},
                    }
                } else unreachable else while (i > 0) {
                    i -= 1;
                    switch (c.controls.items[i]) {
                        .loop => |l| break .{ .loop_break = l },
                        .@"switch" => |sb| break .{ .switch_break = sb },
                        .label, .finally_region, .finally_body => {},
                    }
                } else unreachable;
                try c.emitJump(jt);
                return false;
            },
            .@"continue" => |maybe_lbl| {
                var i = c.controls.items.len;
                const jt: JumpTarget = if (maybe_lbl) |lbl| while (i > 0) {
                    i -= 1;
                    switch (c.controls.items[i]) {
                        .label => |lt| if (std.mem.eql(u8, lt.name, lbl)) break .{ .loop_continue = lt.loop.? },
                        else => {},
                    }
                } else unreachable else while (i > 0) {
                    i -= 1;
                    switch (c.controls.items[i]) {
                        .loop => |l| break .{ .loop_continue = l },
                        .@"switch", .label, .finally_region, .finally_body => {},
                    }
                } else unreachable;
                try c.emitJump(jt);
                return false;
            },
        }
        return true;
    }

    fn emitIterClose(c: *Compiler, slot: u32, is_await: bool) Error!void {
        // Clear `slot` before closing so throwing in `return()` does not double-close.
        try c.emit(.get_local, &.{ slot, try c.name("<iter>") });
        try c.emit(.push_undefined, &.{});
        try c.emit(.init_local, &.{slot});
        if (is_await) try c.emitAsyncClose(false) else try c.emit(.iter_close, &.{});
        try c.emit(.clear_local, &.{slot});
    }

    /// AsyncIteratorClose of the record on top of the stack (D68): [record] → []. On a throw
    /// completion (`is_throw`) a rejected `return()` promise is ignored, through a handler
    /// around the `await`, so the original exception wins.
    fn emitAsyncClose(c: *Compiler, is_throw: bool) Error!void {
        const base = c.depth - 1;
        try c.emit(if (is_throw) .async_iter_close_throw else .async_iter_close, &.{});
        const to_skip = try c.jumpForward(.jump_if_false); // [result]
        const await_pc = c.here();
        try c.emit(.await, &.{});
        if (is_throw) {
            // The awaited value or the caught rejection: both are dropped.
            const after = c.here();
            try c.handlers.append(c.s.gpa, .{
                .try_start = await_pc,
                .try_end = after,
                .catch_pc = after,
                .stack_depth = base,
                .has_binding = true,
            });
            c.patch(to_skip, c.here());
            try c.emit(.pop, &.{});
        } else {
            try c.emit(.async_iter_close_check, &.{});
            const to_end = try c.jumpForward(.jump);
            c.patch(to_skip, c.here());
            c.depth = base + 1;
            try c.emit(.pop, &.{});
            c.patch(to_end, c.here());
        }
        c.depth = base;
    }

    fn emitReturn(c: *Compiler) Error!void {
        var i = c.controls.items.len;
        while (i > 0) {
            i -= 1;
            switch (c.controls.items[i]) {
                .finally_body => |fb| {
                    try c.emit(.clear_local, &.{fb.kind_slot});
                    try c.emit(.clear_local, &.{fb.val_slot});
                },
                .finally_region => |fr| {
                    fr.has_return = true;
                    try c.emit(.init_local, &.{fr.val_slot});
                    try c.emit(.push_const, &.{try c.number(2)});
                    try c.emit(.init_local, &.{fr.kind_slot});
                    try fr.to_finally.append(c.s.gpa, try c.jumpForward(.jump));
                    return;
                },
                .loop => |l| if (l.iter_slot) |slot| try c.emitIterClose(slot, l.is_await),
                .@"switch", .label => {},
            }
        }
        try c.emit(.@"return", &.{});
    }

    /// A `return` of the value on top of the stack from inside an expression (a generator
    /// resumed with `return()`, D67): drops the operands below it first, since statements
    /// run on an empty stack and `return` (or a `finally` jump) expects only the value.
    fn returnFromExpr(c: *Compiler) Error!void {
        if (c.depth > 1) {
            const tmp = c.allocTemp();
            defer c.freeTemp();
            try c.emit(.init_local, &.{tmp});
            while (c.depth > 0) try c.emit(.pop, &.{});
            try c.emit(.get_local, &.{ tmp, try c.name("<yield>") });
            try c.emit(.clear_local, &.{tmp});
        }
        try c.emitReturn();
    }

    /// `yield* e` (D67): a loop around `yield_star_step`, the inner iterator in a hidden
    /// slot; inner results are yielded raw, and the resume's [value, mode] feeds the next round.
    /// In an async generator (D68) each round awaits the inner result between
    /// `async_yield_star_call` and `async_yield_star_result`, and yields its value.
    fn yieldStar(c: *Compiler, operand: *const ast.Expr) Error!void {
        const iter_slot = c.allocTemp();
        defer c.freeTemp();
        try c.expr(operand);
        try c.emit(if (c.is_async_generator) .get_async_iter else .get_iter, &.{});
        try c.emit(.init_local, &.{iter_slot});
        try c.emit(.push_undefined, &.{});
        try c.emit(.push_const, &.{try c.number(0)});
        const top = c.here();
        const round = c.depth; // [received, mode]
        try c.emit(.get_local, &.{ iter_slot, try c.name("<iter>") });
        try c.emit(.rot3, &.{});
        if (c.is_async_generator) {
            try c.emit(.async_yield_star_call, &.{});
            try c.emit(.await, &.{});
            try c.emit(.async_yield_star_result, &.{});
        } else try c.emit(.yield_star_step, &.{});
        try c.emit(.dup, &.{});
        const to_yield = try c.jumpForward(.jump_if_false);
        try c.emit(.push_const, &.{try c.number(1)});
        try c.emit(.strict_eq, &.{});
        const to_return = try c.jumpForward(.jump_if_false);
        const to_done = try c.jumpForward(.jump);
        c.patch(to_return, c.here());
        try c.emit(.clear_local, &.{iter_slot});
        try c.returnFromExpr();
        c.patch(to_yield, c.here());
        c.depth = round; // [value, kind]
        try c.emit(.pop, &.{});
        try c.emit(.yield, &.{@intFromBool(!c.is_async_generator)});
        try c.emit(.jump, &.{top});
        c.patch(to_done, c.here());
        c.depth = round - 1; // [value]
        try c.emit(.clear_local, &.{iter_slot});
    }

    fn attachLabelsToLoop(c: *Compiler, loop: *Loop) void {
        var i = c.controls.items.len;
        while (i > 0) {
            i -= 1;
            switch (c.controls.items[i]) {
                .label => |lt| lt.loop = loop,
                else => break,
            }
        }
    }

    fn emitJump(c: *Compiler, jt: JumpTarget) Error!void {
        var i = c.controls.items.len;
        while (i > 0) {
            i -= 1;
            switch (c.controls.items[i]) {
                .loop => |l| switch (jt) {
                    .loop_break => |tl| if (l == tl) {
                        try jt.append(c.s.gpa, try c.jumpForward(.jump));
                        return;
                    } else if (l.iter_slot) |slot| try c.emitIterClose(slot, l.is_await),
                    .loop_continue => |tl| if (l == tl) {
                        try jt.append(c.s.gpa, try c.jumpForward(.jump));
                        return;
                    } else if (l.iter_slot) |slot| try c.emitIterClose(slot, l.is_await),
                    .switch_break => if (l.iter_slot) |slot| try c.emitIterClose(slot, l.is_await),
                },
                .@"switch" => |sb| switch (jt) {
                    .switch_break => |ts| if (sb == ts) {
                        try jt.append(c.s.gpa, try c.jumpForward(.jump));
                        return;
                    },
                    .loop_break, .loop_continue => {},
                },
                .label => |lt| switch (jt) {
                    .switch_break => |ts| if (&lt.breaks == ts) {
                        try jt.append(c.s.gpa, try c.jumpForward(.jump));
                        return;
                    },
                    .loop_break, .loop_continue => {},
                },
                .finally_body => |fb| {
                    try c.emit(.clear_local, &.{fb.kind_slot});
                    try c.emit(.clear_local, &.{fb.val_slot});
                },
                .finally_region => |fr| {
                    const kind_id = try fr.addJump(c.s.gpa, jt);
                    try c.emit(.push_const, &.{try c.number(@floatFromInt(kind_id))});
                    try c.emit(.init_local, &.{fr.kind_slot});
                    try fr.to_finally.append(c.s.gpa, try c.jumpForward(.jump));
                    return;
                },
            }
        }
        unreachable;
    }

    fn compileTryCatch(c: *Compiler, t: @FieldType(ast.Stmt.Data, "try"), span: ast.Span) Error!bool {
        const cb = t.catch_body orelse return c.statements(t.body, span);
        const try_depth = c.depth;
        const try_start = c.here();
        const try_completes = try c.statements(t.body, span);
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
        const catch_completes = try c.statements(cb, span);
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
    }

    fn compileTry(c: *Compiler, t: @FieldType(ast.Stmt.Data, "try"), span: ast.Span) Error!bool {
        const fb = t.finally_body orelse return c.compileTryCatch(t, span);
        const kind_slot = c.allocTemp();
        const val_slot = c.allocTemp();
        defer {
            c.freeTemp();
            c.freeTemp();
        }
        var fc: FinallyContext = .{ .kind_slot = kind_slot, .val_slot = val_slot };
        defer fc.deinit(c.s.gpa);

        const try_depth = c.depth;
        try c.controls.append(c.s.gpa, .{ .finally_region = &fc });
        const region_start = c.here();
        const region_completes = blk: {
            errdefer _ = c.controls.pop();
            const ok = try c.compileTryCatch(t, span);
            _ = c.controls.pop();
            break :blk ok;
        };
        const region_end = c.here();

        const to_finally_normal = if (region_completes) blk: {
            try c.emit(.push_const, &.{try c.number(0)});
            try c.emit(.init_local, &.{kind_slot});
            break :blk if (region_end > region_start) try c.jumpForward(.jump) else null;
        } else null;

        if (region_end > region_start) {
            const region_catch_pc = c.here();
            std.debug.assert(region_catch_pc < region_start or region_catch_pc >= region_end);
            c.depth = try_depth + 1;
            c.max_stack = @max(c.max_stack, c.depth);
            try c.emit(.init_local, &.{val_slot});
            try c.emit(.push_const, &.{try c.number(1)});
            try c.emit(.init_local, &.{kind_slot});
            try c.handlers.append(c.s.gpa, .{
                .try_start = region_start,
                .try_end = region_end,
                .catch_pc = region_catch_pc,
                .stack_depth = try_depth,
                .has_binding = true,
            });
        }

        const finally_pc = c.here();
        c.depth = try_depth;
        if (to_finally_normal) |j| c.patch(j, finally_pc);
        for (fc.to_finally.items) |j| c.patch(j, finally_pc);

        try c.controls.append(c.s.gpa, .{ .finally_body = &fc });
        const fin_start = c.here();
        const fin_completes = blk: {
            errdefer _ = c.controls.pop();
            const ok = try c.statements(fb, span);
            _ = c.controls.pop();
            break :blk ok;
        };
        const fin_end = c.here();

        if (fin_end > fin_start) {
            const to_dispatch = if (fin_completes) try c.jumpForward(.jump) else null;
            const fin_catch_pc = c.here();
            std.debug.assert(fin_catch_pc < fin_start or fin_catch_pc >= fin_end);
            c.depth = try_depth + 1;
            c.max_stack = @max(c.max_stack, c.depth);
            try c.emit(.clear_local, &.{kind_slot});
            try c.emit(.clear_local, &.{val_slot});
            try c.emit(.throw, &.{});
            try c.handlers.append(c.s.gpa, .{
                .try_start = fin_start,
                .try_end = fin_end,
                .catch_pc = fin_catch_pc,
                .stack_depth = try_depth,
                .has_binding = true,
            });
            if (to_dispatch) |j| c.patch(j, c.here());
        }

        if (!fin_completes) return false;
        c.depth = try_depth;

        const has_throw = region_end > region_start;
        const total_abrupt: usize = @as(usize, @intFromBool(has_throw)) + @as(usize, @intFromBool(fc.has_return)) + fc.jumps.items.len;
        var emitted: usize = 0;

        if (has_throw) {
            emitted += 1;
            const is_last_unconditional = !region_completes and emitted == total_abrupt;
            const next = if (!is_last_unconditional) blk: {
                try c.emit(.get_local, &.{ kind_slot, try c.name("<pending>") });
                try c.emit(.push_const, &.{try c.number(1)});
                try c.emit(.strict_eq, &.{});
                break :blk try c.jumpForward(.jump_if_false);
            } else null;
            try c.emit(.get_local, &.{ val_slot, try c.name("<pending>") });
            try c.emit(.clear_local, &.{kind_slot});
            try c.emit(.clear_local, &.{val_slot});
            try c.emit(.throw, &.{});
            if (next) |j| c.patch(j, c.here());
            c.depth = try_depth;
        }
        if (fc.has_return) {
            emitted += 1;
            const is_last_unconditional = !region_completes and emitted == total_abrupt;
            const next = if (!is_last_unconditional) blk: {
                try c.emit(.get_local, &.{ kind_slot, try c.name("<pending>") });
                try c.emit(.push_const, &.{try c.number(2)});
                try c.emit(.strict_eq, &.{});
                break :blk try c.jumpForward(.jump_if_false);
            } else null;
            try c.emit(.get_local, &.{ val_slot, try c.name("<pending>") });
            try c.emit(.clear_local, &.{kind_slot});
            try c.emit(.clear_local, &.{val_slot});
            try c.emitReturn();
            if (next) |j| c.patch(j, c.here());
            c.depth = try_depth;
        }
        for (fc.jumps.items, 0..) |jt, idx| {
            emitted += 1;
            const is_last_unconditional = !region_completes and emitted == total_abrupt;
            const next = if (!is_last_unconditional) blk: {
                try c.emit(.get_local, &.{ kind_slot, try c.name("<pending>") });
                try c.emit(.push_const, &.{try c.number(@floatFromInt(3 + idx))});
                try c.emit(.strict_eq, &.{});
                break :blk try c.jumpForward(.jump_if_false);
            } else null;
            try c.emit(.clear_local, &.{kind_slot});
            try c.emit(.clear_local, &.{val_slot});
            try c.emitJump(jt);
            if (next) |j| c.patch(j, c.here());
            c.depth = try_depth;
        }
        if (!region_completes) return false;
        try c.emit(.clear_local, &.{kind_slot});
        try c.emit(.clear_local, &.{val_slot});
        return true;
    }

    fn compileSwitch(c: *Compiler, sw: @FieldType(ast.Stmt.Data, "switch")) Error!bool {
        try c.expr(sw.discriminant);
        for (sw.cases) |cs| {
            for (cs.body) |s| switch (s.data) {
                .declaration => |d| if (d.kind != .@"var") for (d.declarators) |decl| try c.enterPatternBindings(decl.pattern),
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
        try c.controls.append(c.s.gpa, .{ .@"switch" = &switch_breaks });
        defer _ = c.controls.pop();

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
        try c.controls.append(c.s.gpa, .{ .loop = loop });
        defer _ = c.controls.pop();
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
            .bigint => |raw| try c.emit(.push_const, &.{try c.bigintConst(raw)}),
            .string => |units| try c.emit(.push_const, &.{try c.string(units)}),
            .template => |t| {
                try c.emit(.push_const, &.{try c.string(t.quasis[0])});
                for (t.exprs, 0..) |ex, i| {
                    try c.expr(ex);
                    try c.emit(.to_string, &.{});
                    try c.emit(.add, &.{});
                    if (t.quasis[i + 1].len > 0) {
                        try c.emit(.push_const, &.{try c.string(t.quasis[i + 1])});
                        try c.emit(.add, &.{});
                    }
                }
            },
            .boolean => |b| try c.emit(if (b) .push_true else .push_false, &.{}),
            .null => try c.emit(.push_null, &.{}),
            .regexp => |rx| {
                var flags_u16: [8]u16 = undefined;
                for (rx.flags, 0..) |b, i| flags_u16[i] = b;
                const k_pat = try c.string(rx.pattern);
                const k_flags = try c.string(flags_u16[0..rx.flags.len]);
                try c.emit(.new_regexp, &.{ k_pat, k_flags });
            },
            .identifier => |ref| try c.read(ref),
            .function => |f| try c.closure(f),
            .class => |cls| try c.compileClass(cls, true),
            .super_call => |args| {
                const has_spread = for (args) |a| {
                    if (a.data == .spread) break true;
                } else false;
                if (has_spread) {
                    try c.compileArgsArray(args);
                    try c.emit(.super_call_spread, &.{});
                } else {
                    for (args) |a| try c.expr(a);
                    try c.emit(.super_call, &.{@intCast(args.len)});
                }
            },
            .super_member => |k| switch (k) {
                .name => |n| try c.emit(.super_get_prop, &.{try c.name(n)}),
                .computed => |ke| {
                    try c.emit(.push_this, &.{});
                    try c.emit(.pop, &.{});
                    try c.expr(ke);
                    try c.emit(.super_get_elem, &.{});
                },
                .string, .number => unreachable,
            },
            .delete_super => try c.emit(.throw_delete_super, &.{}),
            .private_in => |pi| {
                try c.expr(pi.rhs);
                try c.emit(.in_private, &.{try c.name(pi.name)});
            },
            .import_meta => try c.emit(.get_import_meta, &.{}),
            .dynamic_import => |spec| {
                try c.expr(spec);
                try c.emit(.dynamic_import, &.{});
            },
            .await => |inner| {
                try c.expr(inner);
                try c.emit(.await, &.{});
            },
            .yield => |y| {
                if (y.star) return c.yieldStar(y.value.?);
                if (y.value) |v| try c.expr(v) else try c.emit(.push_undefined, &.{});
                if (c.is_async_generator) try c.emit(.await, &.{}); // AsyncGeneratorYield awaits (D68)
                try c.emit(.yield, &.{0});
                // [value, mode]: next → value; throw → throw value; return → `return value`.
                const resumed = c.depth;
                try c.emit(.dup, &.{});
                const to_next = try c.jumpForward(.jump_if_false);
                try c.emit(.push_const, &.{try c.number(1)});
                try c.emit(.strict_eq, &.{});
                const to_return = try c.jumpForward(.jump_if_false);
                try c.emit(.throw, &.{});
                c.patch(to_return, c.here());
                c.depth = resumed - 1;
                try c.returnFromExpr();
                c.patch(to_next, c.here());
                c.depth = resumed;
                try c.emit(.pop, &.{});
            },
            .unary => |u| {
                if (u.op == .void) {
                    try c.exprDiscard(u.operand);
                    try c.emit(.push_undefined, &.{});
                    return;
                }
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
                    .void => unreachable,
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
                .comma => {
                    try c.expr(b.lhs);
                    try c.emit(.pop, &.{});
                    try c.expr(b.rhs);
                },
                else => {
                    try c.expr(b.lhs);
                    if (b.rhs.data == .number) {
                        const fused: ?Op = switch (b.op) {
                            .add => .add_const,
                            .sub => .sub_const,
                            .mul => .mul_const,
                            .mod => .mod_const,
                            else => null,
                        };
                        if (fused) |fop| {
                            try c.emit(fop, &.{try c.number(b.rhs.data.number)});
                            return;
                        }
                    } else if (b.rhs.data == .identifier) {
                        const ref = b.rhs.data.identifier;
                        if (c.s.res.refs[ref.id] == .local) {
                            const lb = c.s.res.refs[ref.id].local;
                            if (!c.binding(lb).captured) {
                                const fused: ?Op = switch (b.op) {
                                    .add => .add_local,
                                    .sub => .sub_local,
                                    .mul => .mul_local,
                                    .mod => .mod_local,
                                    else => null,
                                };
                                if (fused) |fop| {
                                    try c.emit(fop, &.{ c.slotOf(lb), try c.name(ref.name) });
                                    return;
                                }
                            }
                        }
                    }
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
                    const get_op: Op = if (m.is_private) .get_private else .get_prop;
                    const set_op: Op = if (m.is_private) .set_private else .set_prop;
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
                            if (named) |n| try c.emit(set_op, &.{try c.name(n)}) else try c.emit(.set_elem, &.{});
                        },
                        .compound => |op| {
                            if (named) |n| {
                                try c.emit(.dup, &.{});
                                try c.emit(get_op, &.{try c.name(n)});
                            } else {
                                try c.emit(.dup2, &.{});
                                try c.emit(.get_elem, &.{});
                            }
                            try c.expr(a.value);
                            try c.emit(binaryOp(op), &.{});
                            if (named) |n| try c.emit(set_op, &.{try c.name(n)}) else try c.emit(.set_elem, &.{});
                        },
                        .logical_and, .logical_or, .nullish => {
                            const computed = named == null;
                            if (named) |n| {
                                try c.emit(.dup, &.{});
                                try c.emit(get_op, &.{try c.name(n)});
                            } else {
                                try c.emit(.dup2, &.{});
                                try c.emit(.get_elem, &.{});
                            }
                            const to_short = try c.jumpIfLogicalAssignShortCircuit(a.op);
                            try c.emit(.pop, &.{});
                            try c.expr(a.value);
                            if (named) |n| try c.emit(set_op, &.{try c.name(n)}) else try c.emit(.set_elem, &.{});
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
                .super_member => |k| {
                    const named = switch (k) {
                        .name => |n| n,
                        .computed => |ke| blk: {
                            try c.emit(.push_this, &.{});
                            try c.emit(.pop, &.{});
                            try c.expr(ke);
                            break :blk null;
                        },
                        .string, .number => unreachable,
                    };
                    switch (a.op) {
                        .plain => {
                            try c.expr(a.value);
                            if (named) |n| try c.emit(.super_set_prop, &.{try c.name(n)}) else try c.emit(.super_set_elem, &.{});
                        },
                        .compound => |op| {
                            if (named) |n| {
                                try c.emit(.super_get_prop, &.{try c.name(n)});
                                try c.expr(a.value);
                                try c.emit(binaryOp(op), &.{});
                                try c.emit(.super_set_prop, &.{try c.name(n)});
                            } else {
                                try c.emit(.dup, &.{});
                                try c.emit(.super_get_elem, &.{});
                                try c.expr(a.value);
                                try c.emit(binaryOp(op), &.{});
                                try c.emit(.super_set_elem, &.{});
                            }
                        },
                        .logical_and, .logical_or, .nullish => {
                            if (named) |n| {
                                try c.emit(.super_get_prop, &.{try c.name(n)});
                                const to_short = try c.jumpIfLogicalAssignShortCircuit(a.op);
                                try c.emit(.pop, &.{});
                                try c.expr(a.value);
                                try c.emit(.super_set_prop, &.{try c.name(n)});
                                c.patch(to_short, c.here());
                            } else {
                                const k_slot = c.allocTemp();
                                defer c.freeTemp();
                                try c.emit(.init_local, &.{k_slot});
                                try c.emit(.get_local, &.{ k_slot, try c.name("<key>") });
                                try c.emit(.super_get_elem, &.{});
                                const to_short = try c.jumpIfLogicalAssignShortCircuit(a.op);
                                try c.emit(.pop, &.{});
                                try c.emit(.get_local, &.{ k_slot, try c.name("<key>") });
                                try c.expr(a.value);
                                try c.emit(.super_set_elem, &.{});
                                c.patch(to_short, c.here());
                                try c.emit(.clear_local, &.{k_slot});
                            }
                        },
                    }
                },
            },
            .update => |u| switch (u.target) {
                .ref => |ref| {
                    // Read, ToNumber, then write; the result is the new value (prefix) or the
                    // old one (postfix: keep a copy of it under the new value).
                    try c.read(ref);
                    try c.emit(.to_numeric, &.{});
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
                    const get_op: Op = if (m.is_private) .get_private else .get_prop;
                    const set_op: Op = if (m.is_private) .set_private else .set_prop;
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
                        try c.emit(get_op, &.{try c.name(n)});
                    } else {
                        try c.emit(.dup2, &.{});
                        try c.emit(.get_elem, &.{});
                    }
                    try c.emit(.to_numeric, &.{});
                    if (!u.prefix) {
                        try c.emit(.dup, &.{});
                        try c.emit(if (named == null) .rot4 else .rot3, &.{});
                    }
                    try c.emit(if (u.op == .inc) .inc else .dec, &.{});
                    if (named) |n| try c.emit(set_op, &.{try c.name(n)}) else try c.emit(.set_elem, &.{});
                    if (!u.prefix) try c.emit(.pop, &.{});
                },
                .super_member => |k| {
                    const named = switch (k) {
                        .name => |n| n,
                        .computed => |ke| blk: {
                            try c.emit(.push_this, &.{});
                            try c.emit(.pop, &.{});
                            try c.expr(ke);
                            break :blk null;
                        },
                        .string, .number => unreachable,
                    };
                    if (named) |n| {
                        try c.emit(.super_get_prop, &.{try c.name(n)});
                        try c.emit(.to_numeric, &.{});
                        if (!u.prefix) try c.emit(.dup, &.{});
                        try c.emit(if (u.op == .inc) .inc else .dec, &.{});
                        try c.emit(.super_set_prop, &.{try c.name(n)});
                        if (!u.prefix) try c.emit(.pop, &.{});
                    } else {
                        const k_slot = c.allocTemp();
                        defer c.freeTemp();
                        const val_slot = c.allocTemp();
                        defer c.freeTemp();
                        try c.emit(.init_local, &.{k_slot});
                        try c.emit(.get_local, &.{ k_slot, try c.name("<key>") });
                        try c.emit(.super_get_elem, &.{});
                        try c.emit(.to_numeric, &.{});
                        if (!u.prefix) {
                            try c.emit(.dup, &.{});
                            try c.emit(.init_local, &.{val_slot});
                        }
                        try c.emit(if (u.op == .inc) .inc else .dec, &.{});
                        const new_slot = c.allocTemp();
                        defer c.freeTemp();
                        try c.emit(.init_local, &.{new_slot});
                        try c.emit(.get_local, &.{ k_slot, try c.name("<key>") });
                        try c.emit(.get_local, &.{ new_slot, try c.name("<val>") });
                        try c.emit(.super_set_elem, &.{});
                        if (!u.prefix) {
                            try c.emit(.pop, &.{});
                            try c.emit(.get_local, &.{ val_slot, try c.name("<old>") });
                            try c.emit(.clear_local, &.{val_slot});
                        }
                        try c.emit(.clear_local, &.{new_slot});
                        try c.emit(.clear_local, &.{k_slot});
                    }
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
                    .prop => |pr| {
                        const acc_flags: ?u32 = switch (pr.kind) {
                            .init => null,
                            .getter => 2,
                            .setter => 3,
                        };
                        switch (pr.key) {
                            .name => |n| {
                                try c.expr(pr.value);
                                if (acc_flags) |f| {
                                    try c.emit(.define_accessor, &.{ try c.name(n), f });
                                } else {
                                    try c.emit(.define_prop, &.{try c.name(n)});
                                }
                            },
                            .string => |units| {
                                try c.emit(.push_const, &.{try c.string(units)});
                                try c.expr(pr.value);
                                if (acc_flags) |f| {
                                    try c.emit(.define_elem_accessor, &.{f});
                                } else {
                                    try c.emit(.define_elem, &.{});
                                }
                            },
                            .number => |n| {
                                try c.emit(.push_const, &.{try c.number(n)});
                                try c.expr(pr.value);
                                if (acc_flags) |f| {
                                    try c.emit(.define_elem_accessor, &.{f});
                                } else {
                                    try c.emit(.define_elem, &.{});
                                }
                            },
                            .computed => |k| {
                                try c.expr(k);
                                try c.expr(pr.value);
                                if (acc_flags) |f| {
                                    try c.emit(.define_elem_accessor, &.{f});
                                } else {
                                    try c.emit(.define_elem, &.{});
                                }
                            },
                        }
                    },
                    .spread => |sp| {
                        try c.expr(sp.expr);
                        try c.emit(.object_spread, &.{});
                    },
                    .cover_init => unreachable,
                };
            },
            .call => |call| {
                const method = try c.compileCallee(call.callee);
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
            .tagged_template => |tt| {
                const method = try c.compileCallee(tt.callee);
                const cooked_idx = try c.s.gpa.alloc(u32, tt.cooked.len);
                errdefer c.s.gpa.free(cooked_idx);
                const raw_idx = try c.s.gpa.alloc(u32, tt.raw.len);
                errdefer c.s.gpa.free(raw_idx);
                for (tt.cooked, 0..) |maybe_u, i| {
                    cooked_idx[i] = if (maybe_u) |u| try c.string(u) else std.math.maxInt(u32);
                }
                for (tt.raw, 0..) |u, i| {
                    raw_idx[i] = try c.string(u);
                }
                const site_idx: u32 = @intCast(c.templates.items.len);
                try c.templates.append(c.s.gpa, .{ .cooked = cooked_idx, .raw = raw_idx });
                try c.emit(.get_template_obj, &.{site_idx});
                for (tt.exprs) |ex| try c.expr(ex);
                try c.emit(if (method) .call_method else .call, &.{@intCast(tt.exprs.len + 1)});
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
                .name => |n| try c.emit(if (m.is_private) .get_private else .get_prop, &.{try c.name(n)}),
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
                .prop, .private_prop => |n| {
                    const is_priv = step.kind == .private_prop;
                    if (is_delete and i == oc.steps.len - 1) {
                        try c.emit(.delete_prop, &.{try c.name(n)});
                    } else {
                        if (i + 1 < oc.steps.len and oc.steps[i + 1].kind == .call) {
                            try c.emit(.dup, &.{});
                            has_receiver = true;
                        }
                        try c.emit(if (is_priv) .get_private else .get_prop, &.{try c.name(n)});
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
        is_private: bool = false,
    };

    fn preEvalMemberTarget(c: *Compiler, pat: *const ast.Pattern) Error!?MemberSlots {
        if (pat.data != .target or pat.data.target != .member) return null;
        const m = pat.data.target.member;
        try c.expr(m.object);
        const base_slot = c.allocTemp();
        try c.emit(.init_local, &.{base_slot});
        switch (m.key) {
            .name => |n| return .{ .base_slot = base_slot, .key_slot = null, .prop_name = n, .is_private = m.is_private },
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
            try c.emit(if (ms.is_private) .set_private else .set_prop, &.{try c.name(n)});
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
                            try c.emit(if (m.is_private) .set_private else .set_prop, &.{try c.name(n)});
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
                .super_member => |k| {
                    const val_slot = c.allocTemp();
                    defer c.freeTemp();
                    try c.emit(.init_local, &.{val_slot});
                    switch (k) {
                        .name => |n| {
                            try c.emit(.get_local, &.{ val_slot, try c.name("<val>") });
                            try c.emit(.super_set_prop, &.{try c.name(n)});
                        },
                        .computed => |ke| {
                            try c.emit(.push_this, &.{});
                            try c.emit(.pop, &.{});
                            try c.expr(ke);
                            try c.emit(.get_local, &.{ val_slot, try c.name("<val>") });
                            try c.emit(.super_set_elem, &.{});
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
                const base_depth = c.depth;
                const elems_start = c.here();
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
                const elems_end = c.here();
                if (arr.rest == null) {
                    try c.emit(.get_local, &.{ iter_slot, try c.name("<iter>") });
                    try c.emit(.iter_close, &.{});
                }
                try c.emit(.clear_local, &.{iter_slot});
                if (elems_end > elems_start) {
                    const to_after = try c.jumpForward(.jump);
                    const catch_pc = c.here();
                    c.depth = base_depth + 1;
                    c.max_stack = @max(c.max_stack, c.depth);
                    try c.emit(.get_local, &.{ iter_slot, try c.name("<iter>") });
                    try c.emit(.iter_close_throw, &.{});
                    try c.emit(.clear_local, &.{iter_slot});
                    try c.emit(.throw, &.{});
                    try c.handlers.append(c.s.gpa, .{
                        .try_start = elems_start,
                        .try_end = elems_end,
                        .catch_pc = catch_pc,
                        .stack_depth = base_depth,
                        .has_binding = true,
                    });
                    c.patch(to_after, c.here());
                    c.depth = base_depth;
                }
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
        if (what == .get and !m.is_private and m.key == .computed and m.object.data == .identifier and m.key.computed.data == .identifier) {
            const oref = m.object.data.identifier;
            const kref = m.key.computed.data.identifier;
            if (c.s.res.refs[oref.id] == .local and c.s.res.refs[kref.id] == .local) {
                const ob = c.s.res.refs[oref.id].local;
                const kb = c.s.res.refs[kref.id].local;
                if (!c.binding(ob).captured and !c.binding(kb).captured) {
                    const os = c.slotOf(ob);
                    const ks = c.slotOf(kb);
                    if (c.isSlotInit(os) and c.isSlotInit(ks)) {
                        try c.emit(.get_elem_local, &.{ os, ks });
                        return;
                    }
                }
            }
        }
        try c.expr(m.object);
        switch (m.key) {
            .name => |n| {
                const op: Op = if (what == .get) (if (m.is_private) .get_private else .get_prop) else .delete_prop;
                try c.emit(op, &.{try c.name(n)});
            },
            .computed => |k| {
                try c.expr(k);
                try c.emit(if (what == .get) .get_elem else .delete_elem, &.{});
            },
            .string, .number => unreachable, // only in literals
        }
    }

    /// Compiles `e` in a value-discarded context (expression statements, `for` init/update),
    /// emitting superinstructions for common local updates and assignments (M52).
    fn exprDiscard(c: *Compiler, e: *const ast.Expr) Error!void {
        switch (e.data) {
            .update => |u| if (u.target == .ref) {
                const ref = u.target.ref;
                if (c.s.res.refs[ref.id] == .local) {
                    const b = c.s.res.refs[ref.id].local;
                    if (!c.binding(b).captured and c.binding(b).kind != .@"const") {
                        try c.emit(if (u.op == .inc) .inc_local else .dec_local, &.{ c.slotOf(b), try c.name(ref.name) });
                        return;
                    }
                }
            },
            .assign => |a| if (a.op == .plain) switch (a.target) {
                .ref => |ref| if (c.s.res.refs[ref.id] == .local) {
                    const b = c.s.res.refs[ref.id].local;
                    if (!c.binding(b).captured and c.binding(b).kind != .@"const") {
                        try c.expr(a.value);
                        try c.emit(.set_local_pop, &.{ c.slotOf(b), try c.name(ref.name) });
                        return;
                    }
                },
                .member => |m| if (!m.is_private) {
                    try c.expr(m.object);
                    switch (m.key) {
                        .name => |n| {
                            try c.expr(a.value);
                            try c.emit(.set_prop_pop, &.{try c.name(n)});
                            return;
                        },
                        .computed => |k| {
                            try c.expr(k);
                            try c.expr(a.value);
                            try c.emit(.set_elem_pop, &.{});
                            return;
                        },
                        .string, .number => unreachable,
                    }
                },
                else => {},
            },
            else => {},
        }
        try c.expr(e);
        try c.emit(.pop, &.{});
    }

    /// Evaluates condition `e` and emits a forward conditional jump taken when falsy,
    /// fusing relational/strict-equality ops into `*_jump_if_false` (M52/M53) and
    /// `local op num_const` into `*_local_const_jif` (M57).
    fn jumpIfFalseExpr(c: *Compiler, e: *const ast.Expr) Error!u32 {
        if (e.data == .binary) {
            const b = e.data.binary;
            if (b.lhs.data == .identifier and b.rhs.data == .number) {
                const lref = b.lhs.data.identifier;
                if (c.s.res.refs[lref.id] == .local) {
                    const lb = c.s.res.refs[lref.id].local;
                    if (!c.binding(lb).captured) {
                        const ls = c.slotOf(lb);
                        if (c.isSlotInit(ls)) {
                            const lc_op: ?Op = switch (b.op) {
                                .lt => .lt_local_const_jif,
                                .le => .le_local_const_jif,
                                .strict_eq => .strict_eq_local_const_jif,
                                .strict_ne => .strict_ne_local_const_jif,
                                else => null,
                            };
                            if (lc_op) |fop| {
                                const k = try c.constant(Value.fromNumber(b.rhs.data.number));
                                const target_pos = c.here() + 1;
                                try c.emit(fop, &.{ 0, ls, k });
                                return target_pos;
                            }
                        }
                    }
                }
            }
            const fused: ?Op = switch (b.op) {
                .lt => .lt_jump_if_false,
                .le => .le_jump_if_false,
                .gt => .gt_jump_if_false,
                .ge => .ge_jump_if_false,
                .strict_eq => .strict_eq_jump_if_false,
                .strict_ne => .strict_ne_jump_if_false,
                else => null,
            };
            if (fused) |fop| {
                try c.expr(b.lhs);
                try c.expr(b.rhs);
                return c.jumpForward(fop);
            }
        }
        try c.expr(e);
        return c.jumpForward(.jump_if_false);
    }

    fn read(c: *Compiler, ref: ast.Ref) Error!void {
        switch (c.s.res.refs[ref.id]) {
            .local => |b| try c.emit(if (c.binding(b).captured) .get_cell else .get_local, &.{ c.slotOf(b), try c.name(ref.name) }),
            .capture => |cap| try c.emit(.get_capture, &.{ cap.index, try c.name(ref.name) }),
            .global => try c.emit(.get_global, &.{try c.name(ref.name)}),
            .repl => |idx| try c.emit(.get_repl, &.{ idx, try c.name(ref.name) }),
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
            .repl => |idx| {
                const op: Op = if (c.s.res.repl_bindings[idx].kind == .@"const") .assign_const_repl else .set_repl;
                try c.emit(op, &.{ idx, try c.name(ref.name) });
            },
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

    fn compileCallee(c: *Compiler, callee: *const ast.Expr) Error!bool {
        // A member callee is a method call: [receiver, callee] (D41).
        if (callee.data == .super_member) {
            try c.emit(.push_this, &.{});
            switch (callee.data.super_member) {
                .name => |n| try c.emit(.super_get_prop, &.{try c.name(n)}),
                .computed => |k| {
                    try c.expr(k);
                    try c.emit(.super_get_elem, &.{});
                },
                .string, .number => unreachable,
            }
            return true;
        }
        const method = callee.data == .member;
        if (method) {
            const m = callee.data.member;
            try c.expr(m.object);
            try c.emit(.dup, &.{});
            switch (m.key) {
                .name => |n| try c.emit(if (m.is_private) .get_private else .get_prop, &.{try c.name(n)}),
                .computed => |k| {
                    try c.expr(k);
                    try c.emit(.get_elem, &.{});
                },
                .string, .number => unreachable,
            }
        } else try c.expr(callee);
        return method;
    }

    fn emitPropertyKeyExpr(c: *Compiler, pk: ast.PropertyKey) Error!void {
        switch (pk) {
            .name => |n| {
                const units = try c.s.gpa.alloc(u16, n.len);
                defer c.s.gpa.free(units);
                for (n, 0..) |ch, i| units[i] = ch;
                try c.emit(.push_const, &.{try c.string(units)});
            },
            .string => |units| try c.emit(.push_const, &.{try c.string(units)}),
            .number => |num| try c.emit(.push_const, &.{try c.number(num)}),
            .computed => |k| try c.expr(k),
        }
    }

    fn compileClass(c: *Compiler, cls: *const ast.Class, is_expr: bool) Error!void {
        const ctor_slot = c.allocTemp();
        defer c.freeTemp();
        const proto_slot = c.allocTemp();
        defer c.freeTemp();

        if (is_expr) {
            if (cls.name) |nd| try c.enterBinding(nd.binding);
        }
        try c.closure(cls.constructor);
        if (cls.super_class) |sc| {
            try c.expr(sc);
        } else {
            try c.emit(.push_undefined, &.{});
        }
        try c.emit(.setup_class, &.{if (cls.super_class != null) 1 else 0});
        // Stack: [ctor, ctor_proto]
        try c.emit(.init_local, &.{proto_slot});
        if (is_expr) {
            if (cls.name) |nd| {
                try c.emit(.dup, &.{});
                try c.initBinding(nd.binding);
            }
        }
        try c.emit(.init_local, &.{ctor_slot});

        for (cls.methods) |m| {
            if (m.is_private) continue; // installed via instance_inits / static block
            const target_slot = if (m.is_static) ctor_slot else proto_slot;
            try c.emit(.get_local, &.{ target_slot, try c.name("<class>") });
            const acc_flags: ?u32 = switch (m.kind) {
                .method => null,
                .getter => 0,
                .setter => 1,
            };
            switch (m.key) {
                .name => |n| {
                    try c.emit(.get_local, &.{ ctor_slot, try c.name("<class>") });
                    try c.closure(m.func);
                    try c.emit(.set_brand, &.{});
                    if (acc_flags) |f| {
                        try c.emit(.define_accessor, &.{ try c.name(n), f });
                    } else {
                        try c.emit(.define_method, &.{try c.name(n)});
                    }
                },
                .string => |units| {
                    try c.emit(.push_const, &.{try c.string(units)});
                    try c.emit(.get_local, &.{ ctor_slot, try c.name("<class>") });
                    try c.closure(m.func);
                    try c.emit(.set_brand, &.{});
                    if (acc_flags) |f| {
                        try c.emit(.define_elem_accessor, &.{f});
                    } else {
                        try c.emit(.define_elem_method, &.{});
                    }
                },
                .number => |num| {
                    try c.emit(.push_const, &.{try c.number(num)});
                    try c.emit(.get_local, &.{ ctor_slot, try c.name("<class>") });
                    try c.closure(m.func);
                    try c.emit(.set_brand, &.{});
                    if (acc_flags) |f| {
                        try c.emit(.define_elem_accessor, &.{f});
                    } else {
                        try c.emit(.define_elem_method, &.{});
                    }
                },
                .computed => |k| {
                    try c.expr(k);
                    try c.emit(.get_local, &.{ ctor_slot, try c.name("<class>") });
                    try c.closure(m.func);
                    try c.emit(.set_brand, &.{});
                    if (acc_flags) |f| {
                        try c.emit(.define_elem_accessor, &.{f});
                    } else {
                        try c.emit(.define_elem_method, &.{});
                    }
                },
            }
            try c.emit(.pop, &.{});
        }

        // Private instance methods/accessors + instance fields (installed per `new C()`).
        for (cls.methods) |m| {
            if (m.is_static or !m.is_private) continue;
            const kind_code: u32 = switch (m.kind) {
                .method => 2, // private_method
                .getter => 3, // private_getter
                .setter => 4, // private_setter
            };
            try c.emit(.get_local, &.{ ctor_slot, try c.name("<class>") });
            try c.closure(m.func);
            try c.emit(.add_instance_init, &.{ try c.name(m.key.name), kind_code << 16 });
            try c.emit(.pop, &.{});
        }
        var field_key_count: u32 = 0;
        for (cls.instance_fields) |f| {
            var key_idx: u32 = 0;
            if (!f.is_private) {
                key_idx = field_key_count;
                field_key_count += 1;
                try c.emit(.get_local, &.{ ctor_slot, try c.name("<class>") });
                try c.emitPropertyKeyExpr(f.key);
                try c.emit(.store_field_key, &.{});
                try c.emit(.pop, &.{});
            }
            const kind_code: u32 = if (f.is_private) 1 else 0;
            const name_str: []const u8 = if (f.is_private) f.key.name else "";
            try c.emit(.get_local, &.{ ctor_slot, try c.name("<class>") });
            if (f.init) |init_fn| try c.closure(init_fn) else try c.emit(.push_undefined, &.{});
            try c.emit(.add_instance_init, &.{ try c.name(name_str), (kind_code << 16) | key_idx });
            try c.emit(.pop, &.{});
        }

        // Static private methods/accessors, static fields, and `static {}` blocks.
        for (cls.methods) |m| {
            if (!m.is_static or !m.is_private) continue;
            try c.emit(.get_local, &.{ ctor_slot, try c.name("<class>") });
            try c.closure(m.func);
            switch (m.kind) {
                .method => try c.emit(.define_private_method, &.{try c.name(m.key.name)}),
                .getter => try c.emit(.define_private_accessor, &.{ try c.name(m.key.name), 0 }),
                .setter => try c.emit(.define_private_accessor, &.{ try c.name(m.key.name), 1 }),
            }
            try c.emit(.pop, &.{});
        }
        var static_key_slots = try c.s.gpa.alloc(?u32, cls.static_fields.len);
        defer c.s.gpa.free(static_key_slots);
        for (cls.static_fields, 0..) |f, i| {
            if (!f.is_private) {
                const slot = c.allocTemp();
                static_key_slots[i] = slot;
                try c.emitPropertyKeyExpr(f.key);
                try c.emit(.init_local, &.{slot});
            } else {
                static_key_slots[i] = null;
            }
        }
        for (cls.static_items) |item| switch (item) {
            .field => |idx| {
                const f = cls.static_fields[idx];
                try c.emit(.get_local, &.{ ctor_slot, try c.name("<class>") });
                if (!f.is_private) {
                    try c.emit(.get_local, &.{ static_key_slots[idx].?, try c.name("<key>") });
                }
                if (f.init) |init_fn| {
                    try c.emit(.get_local, &.{ ctor_slot, try c.name("<class>") });
                    try c.closure(init_fn);
                    try c.emit(.run_static_init, &.{});
                } else {
                    try c.emit(.push_undefined, &.{});
                }
                if (f.is_private) {
                    try c.emit(.define_private_field, &.{try c.name(f.key.name)});
                } else {
                    try c.emit(.define_public_field, &.{});
                }
                try c.emit(.pop, &.{});
            },
            .block => |blk_fn| {
                try c.emit(.get_local, &.{ ctor_slot, try c.name("<class>") });
                try c.closure(blk_fn);
                try c.emit(.run_static_init, &.{});
                try c.emit(.pop, &.{});
            },
        };
        var si = cls.static_fields.len;
        while (si > 0) {
            si -= 1;
            if (static_key_slots[si]) |slot| {
                try c.emit(.clear_local, &.{slot});
                c.freeTemp();
            }
        }

        try c.emit(.get_local, &.{ ctor_slot, try c.name("<class>") });
        try c.emit(.clear_local, &.{ctor_slot});
        try c.emit(.clear_local, &.{proto_slot});
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
        .loose_eq => .loose_eq,
        .loose_ne => .loose_ne,
        .in => .in,
        .instanceof => .instanceof,
        .logical_and, .logical_or, .nullish, .comma => unreachable, // control flow, handled by the caller
    };
}
