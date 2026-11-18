//! Explicit-stack tree-walking interpreter (DESIGN_DECISIONS D59).
//!
//! It is the oracle the VM is tested against, so it is deliberately simple and
//! deliberately *different* from the VM where they could share a mistake
//! (DESIGN_DECISIONS D16, D37):
//! - Evaluates the AST directly without compiling to bytecode.
//! - Environments (M6, D37): spec-style environment records (`heap.Env`) allocated
//!   when entered (script, block, `for` head with per-iteration copies, call, named
//!   function expression). The resolver's capture analysis is *not* used.
//!
//! Execution model (D59):
//! - Two explicit heap-allocated stacks on `Machine`: `tasks` (continuations) and
//!   `values` (intermediate results). No JS construct nests a Zig call; native stack
//!   use is constant per JS nesting level, so it runs on the caller's thread.
//! - Abrupt completions (`break`, `continue`, `return`, `throw`) unwind over `tasks`
//!   and `values`. `finally` tasks hold their pending completion (rooted) and
//!   re-perform it after running the `finally` body unless the `finally` body itself
//!   completes abruptly (D55).
//! - Native→JS callbacks (`callFromBuiltin`) push a `.barrier` task and run a nested
//!   `runLoop` on the same machine; unwinding never crosses a barrier.

const std = @import("std");
const builtin = @import("builtin");
const ast = @import("../frontend/ast.zig");
const Resolution = @import("../frontend/resolver.zig").Resolution;
const Value = @import("../runtime/value.zig").Value;
const heap = @import("../runtime/heap.zig");
const Env = heap.Env;
const rt_mod = @import("../runtime/runtime.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const ops = @import("../runtime/ops.zig");
const object = @import("../runtime/object.zig");
const builtins = @import("../runtime/builtins.zig");
const coroutine = @import("../runtime/coroutine.zig");

/// Runs a resolved script. On error.Thrown, `rt.exception` or `rt.thrown_value`
/// describes the exception.
pub fn run(rt: *Runtime, script: ast.Script, res: Resolution) Error!void {
    return runMeasured(rt, script, res, null);
}

const StackUse = struct { depth: u32 = 0, bytes: usize = 0 };

fn runMeasured(rt: *Runtime, script: ast.Script, res: Resolution, use: ?*StackUse) Error!void {
    var m: Machine = .{
        .rt = rt,
        .res = res,
        .stack_top = if (builtin.is_test) @frameAddress() else 0,
        .lowest_frame = if (builtin.is_test) @frameAddress() else 0,
    };
    defer if (use) |u| {
        u.* = .{ .depth = m.max_depth, .bytes = m.stack_top - m.lowest_frame };
    };
    defer m.deinit();
    const prev_roots = rt.engine_roots;
    rt.engine_roots = m.roots();
    defer rt.engine_roots = prev_roots;
    const prev_caller = rt.closure_caller;
    rt.closure_caller = .{ .ctx = &m, .call = Machine.callFromBuiltin };
    defer rt.closure_caller = prev_caller;

    try m.pushBlock(script.statements);
    _ = try m.runLoop(0);
    try rt.drainMicrotasks();
}

const UnwindKind = enum { @"break", @"continue", @"return", throw };

const FinallyPending = union(enum) {
    normal,
    @"break",
    @"continue",
    @"return": Value,
    throw: Value,
};

const KeyValue = union(enum) { named: []const u8, value: Value };

const UpdateOp = @FieldType(@FieldType(ast.Expr.Data, "update"), "op");
const WhileTask = struct { cond: *const ast.Expr, body: *const ast.Stmt, values_base: u32 };
const DoWhileTask = struct { body: *const ast.Stmt, cond: *const ast.Expr, values_base: u32 };
const ForTask = struct { stmt: *const ast.Stmt, per_iter: bool, values_base: u32 };
const SwitchTestTask = struct { cases: []const ast.SwitchCase, idx: u32, default_idx: u32, values_base: u32 };
const ArrayPatTask = struct { pat: *const ast.Pattern, idx: u32, mode: BindMode };
const ObjectPatTask = struct { pat: *const ast.Pattern, idx: u32, mode: BindMode, excl_base: u32, excl_count: u32 };
const none_idx: u32 = std.math.maxInt(u32);

const Task = union(enum) {
    /// Balances `m.depth` for a non-leaf `exec` or `eval`.
    depth_pop,
    /// Restores `m.env` when leaving a block / switch / for / for-of / catch scope.
    scope_exit: ?*Env,
    /// Restores `m.env` and decrements `m.depth` when leaving a `.block` statement.
    scope_exit_depth: ?*Env,
    /// Pops and discards one value from `m.values` and decrements `m.depth`.
    pop_value_depth,
    /// Pops and discards one value from `m.values`.
    pop_value,

    // ---- Statements
    exec: *const ast.Stmt,
    stmt_list: struct { stmts: []const ast.Stmt, idx: usize },
    body_hoist: []const ast.Stmt,
    block: []const ast.Stmt,
    decl_next: struct { decls: []const ast.DeclItem, idx: usize },
    return_finish,
    if_branch: struct { then: *const ast.Stmt, @"else": ?*const ast.Stmt },
    while_iter: WhileTask,
    while_check: WhileTask,
    do_while_iter: DoWhileTask,
    do_while_cond: DoWhileTask,
    do_while_check: DoWhileTask,
    switch_scope: struct { cases: []const ast.SwitchCase, values_base: u32 },
    switch_test: SwitchTestTask,
    switch_test_cmp: SwitchTestTask,
    switch_exec: struct { cases: []const ast.SwitchCase, case_idx: u32, stmt_idx: u32, values_base: u32 },
    for_after_init: ForTask,
    for_iter: ForTask,
    for_cond_check: ForTask,
    for_update: ForTask,
    for_of_init: struct { stmt: *const ast.Stmt, has_scope: bool, values_base: u32 },
    for_of_iter: struct { stmt: *const ast.Stmt, iter: *heap.Object, has_scope: bool, values_base: u32 },
    throw_finish,
    try_catch: struct { catch_param: ?*const ast.Pattern, catch_body: []const ast.Stmt, saved_env: ?*Env, values_base: u32 },
    try_finally: struct { finally_body: []const ast.Stmt, saved_env: ?*Env, values_base: u32 },
    finally_resume: FinallyPending,

    // ---- Expressions
    eval: *const ast.Expr,
    template_next: struct { t: ast.Expr.Template, idx: usize },
    unary_finish: ast.UnaryOp,
    binary_rhs: struct { op: ast.BinaryOp, rhs: *const ast.Expr },
    binary_finish: ast.BinaryOp,
    cond_branch: struct { then_expr: *const ast.Expr, else_expr: *const ast.Expr },
    assign_ref_finish: ast.Ref,
    assign_ref_compound: struct { ref: ast.Ref, op: ast.BinaryOp },
    assign_member_base: struct { op: ast.AssignOp, key: ast.PropertyKey, value: *const ast.Expr },
    assign_member_after_key: struct { op: ast.AssignOp, value: *const ast.Expr, named: ?[]const u8 },
    assign_member_plain_finish: ?[]const u8,
    assign_member_plain_finish_key: object.Key,
    assign_member_compound_finish: struct { op: ast.BinaryOp, key: object.Key },
    assign_pattern_keep: *const ast.Pattern,
    update_member_base: struct { op: UpdateOp, prefix: bool, key: ast.PropertyKey },
    update_member_finish: struct { op: UpdateOp, prefix: bool, named: ?[]const u8 },
    member_base: struct { key: ast.PropertyKey, is_delete: bool },
    member_finish: struct { named: ?[]const u8, is_delete: bool },
    opt_after_base: struct { oc: ast.OptionalChain, is_delete: bool },
    opt_after_member_key: struct { oc: ast.OptionalChain, named: ?[]const u8, is_delete: bool },
    opt_step: struct { oc: ast.OptionalChain, idx: usize, is_delete: bool },
    opt_elem_finish: struct { oc: ast.OptionalChain, idx: usize, is_delete: bool },
    opt_call_finish: struct { oc: ast.OptionalChain, idx: usize, is_delete: bool, args_base: usize },
    array_next: struct { items: []const *const ast.Expr, idx: usize },
    array_elem_push,
    array_spread_push,
    object_next: struct { props: []const ast.PropertyDef, idx: usize },
    object_prop_key: struct { value: *const ast.Expr, props: []const ast.PropertyDef, idx: usize },
    object_prop_val: struct { key: object.Key, props: []const ast.PropertyDef, idx: usize },
    object_prop_computed_val: struct { value: *const ast.Expr, props: []const ast.PropertyDef, idx: usize },
    object_spread_finish: struct { props: []const ast.PropertyDef, idx: usize },
    call_member_base: struct { key: ast.PropertyKey, args: []const *const ast.Expr },
    call_member_key: struct { named: ?[]const u8, args: []const *const ast.Expr },
    call_after_callee: struct { args: []const *const ast.Expr, has_receiver: bool },
    new_call_after_callee: []const *const ast.Expr,
    eval_args_next: struct { args: []const *const ast.Expr, idx: usize, args_base: usize },
    eval_args_spread: struct { args: []const *const ast.Expr, idx: usize, args_base: usize },
    invoke_call: struct { has_receiver: bool, args_base: usize },
    invoke_new_call: usize,

    // ---- Calls & barriers
    call_bind_param: struct { func: *const ast.Function, idx: u32, args_base: u32, argc: u32 },
    call_enter_body: struct { func: *const ast.Function, args_base: u32 },
    call_return: struct { saved_env: ?*Env, saved_this: Value, has_this: bool, values_base: u32, construct_instance: ?*heap.Object = null },
    barrier: u32,
    await_suspend,

    // ---- Patterns
    bind_pattern: struct { pat: *const ast.Pattern, mode: BindMode },
    bind_target_member_base: ast.PropertyKey,
    bind_target_member_finish: ?[]const u8,
    bind_array_elem: ArrayPatTask,
    bind_array_elem_pre_member: struct { pat: *const ast.Pattern, idx: u32, mode: BindMode, key: ast.PropertyKey },
    bind_array_elem_pre_member_key: struct { pat: *const ast.Pattern, idx: u32, mode: BindMode, named: ?[]const u8 },
    bind_array_elem_after_default: struct { pat: *const ast.Pattern, idx: u32, mode: BindMode, has_mv: bool },
    bind_array_rest_pre_member: struct { rest: *const ast.Pattern, key: ast.PropertyKey },
    bind_array_rest_pre_member_key: ?[]const u8,
    bind_object_prop: ObjectPatTask,
    bind_object_prop_after_key: ObjectPatTask,
    bind_object_prop_pre_member: struct { pat: *const ast.Pattern, idx: u32, mode: BindMode, excl_base: u32, excl_count: u32, mem_key: ast.PropertyKey },
    bind_object_prop_pre_member_key: struct { pat: *const ast.Pattern, idx: u32, mode: BindMode, excl_base: u32, excl_count: u32, named: ?[]const u8 },
    bind_object_prop_after_default: struct { pat: *const ast.Pattern, idx: u32, mode: BindMode, excl_base: u32, excl_count: u32, has_mv: bool },
    bind_object_rest_pre_member: struct { excl_base: u32, excl_count: u32, key: ast.PropertyKey },
    bind_object_rest_pre_member_key: struct { excl_base: u32, excl_count: u32, named: ?[]const u8 },
};

const BindMode = enum { init, assign };

const Machine = struct {
    rt: *Runtime,
    res: Resolution,
    env: ?*Env = null,
    depth: u32 = 0,
    calls: u32 = 0,
    ret: Value = .undefined,
    this: ?Value = null,
    is_coroutine: bool = false,
    awaited: Value = .undefined,
    tasks: std.ArrayList(Task) = .empty,
    values: std.ArrayList(Value) = .empty,
    stack_top: usize = 0,
    lowest_frame: usize = 0,
    max_depth: u32 = 0,

    fn deinit(m: *Machine) void {
        if (m.rt.engine_roots) |e| if (e.ctx == @as(*anyopaque, m)) {
            m.rt.engine_roots = null;
        };
        m.tasks.deinit(m.rt.gpa);
        m.values.deinit(m.rt.gpa);
    }

    inline fn enter(m: *Machine) Error!void {
        if (m.depth >= m.rt.limits.max_interpreter_depth) return m.rt.limit(.interpreter_depth);
        m.depth += 1;
        if (builtin.is_test) {
            m.lowest_frame = @min(m.lowest_frame, @frameAddress());
            m.max_depth = @max(m.max_depth, m.depth);
        }
    }

    fn safepoint(m: *Machine) void {
        const h = &m.rt.heap;
        if (!h.collect_requested and !h.collect_always) return;
        if (!m.is_coroutine) m.rt.engine_roots = .{ .ctx = m, .mark = markRoots };
        m.rt.collect();
    }

    fn roots(m: *Machine) rt_mod.EngineRoots {
        return .{ .ctx = m, .mark = markRoots };
    }

    fn markRoots(ctx: *anyopaque, h: *heap.Heap) void {
        const m: *const Machine = @ptrCast(@alignCast(ctx));
        const mark_obj = struct {
            fn call(hh: *heap.Heap, o: *heap.Obj) void {
                hh.markObj(o);
            }
        }.call;
        visitRoots(m, h, mark_obj);
    }

    fn visitRoots(m: *const Machine, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *heap.Obj) void) void {
        for (m.values.items) |v| heap.visitValue(v, ctx, visit);
        if (m.env) |e| visit(ctx, &e.obj);
        if (m.this) |t| heap.visitValue(t, ctx, visit);
        heap.visitValue(m.ret, ctx, visit);
        heap.visitValue(m.awaited, ctx, visit);
        for (m.tasks.items) |t| switch (t) {
            .scope_exit, .scope_exit_depth => |e| if (e) |rec| visit(ctx, &rec.obj),
            .for_of_iter => |f| visit(ctx, &f.iter.obj),
            .try_catch => |tc| if (tc.saved_env) |e| visit(ctx, &e.obj),
            .try_finally => |tf| if (tf.saved_env) |e| visit(ctx, &e.obj),
            .finally_resume => |p| switch (p) {
                .@"return" => |v| heap.visitValue(v, ctx, visit),
                .throw => |v| heap.visitValue(v, ctx, visit),
                else => {},
            },
            .assign_member_plain_finish_key => |k| if (k == .atom) visit(ctx, @constCast(&k.atom.obj)),
            .assign_member_compound_finish => |c| if (c.key == .atom) visit(ctx, @constCast(&c.key.atom.obj)),
            .object_prop_val => |o| if (o.key == .atom) visit(ctx, @constCast(&o.key.atom.obj)),
            .call_return => |cr| {
                if (cr.saved_env) |e| visit(ctx, &e.obj);
                if (cr.has_this) heap.visitValue(cr.saved_this, ctx, visit);
                if (cr.construct_instance) |inst| visit(ctx, &inst.obj);
            },
            else => {},
        };
    }

    fn pushTask(m: *Machine, t: Task) Error!void {
        try m.tasks.append(m.rt.gpa, t);
    }

    fn pushVal(m: *Machine, v: Value) Error!void {
        try m.values.append(m.rt.gpa, v);
    }

    fn popVal(m: *Machine) Value {
        return m.values.pop().?;
    }

    // ---- environments

    fn envOf(m: *const Machine, b: u32) *Env {
        const scope = m.res.bindings[b].scope;
        var e = m.env;
        while (e) |rec| : (e = rec.parent) {
            rec.obj.checkLive();
            if (rec.scope == scope) return rec;
        }
        unreachable;
    }

    fn load(m: *const Machine, b: u32) ?Value {
        return m.envOf(b).values[m.res.bindings[b].index];
    }

    fn store(m: *Machine, b: u32, v: Value) void {
        m.rt.heap.storeEnv(m.envOf(b), m.res.bindings[b].index, v);
    }

    fn pushScope(m: *Machine, scope: ?u32) Error!bool {
        const s = scope orelse return false;
        m.env = try m.rt.heap.newEnv(m.env, s, m.res.scopes[s].len);
        return true;
    }

    fn patternScope(m: *const Machine, pat: *const ast.Pattern) ?u32 {
        switch (pat.data) {
            .binding => |d| return m.res.bindings[d.binding].scope,
            .target => return null,
            .array => |arr| {
                for (arr.elems) |maybe| if (maybe) |el| if (m.patternScope(el.pattern)) |s| return s;
                if (arr.rest) |r| return m.patternScope(r);
                return null;
            },
            .object => |obj| {
                for (obj.props) |pr| if (m.patternScope(pr.pattern)) |s| return s;
                if (obj.rest) |r| return m.patternScope(r);
                return null;
            },
        }
    }

    fn scopeOf(m: *const Machine, stmts: []const ast.Stmt) ?u32 {
        for (stmts) |s| switch (s.data) {
            .declaration => |decl| for (decl.declarators) |d| {
                if (m.patternScope(d.pattern)) |sc| return sc;
            },
            .function => |f| return m.res.bindings[f.name.?.binding].scope,
            else => {},
        };
        return null;
    }

    fn copyScope(m: *Machine) Error!void {
        const old = m.env.?;
        const new = try m.rt.heap.newEnv(old.parent, old.scope, old.values.len);
        @memcpy(new.values, old.values);
        m.env = new;
    }

    fn pushBlock(m: *Machine, stmts: []const ast.Stmt) Error!void {
        const saved = m.env;
        if (try m.pushScope(m.scopeOf(stmts))) {
            try m.pushTask(.{ .scope_exit = saved });
        }
        try m.pushBody(stmts);
    }

    fn pushBody(m: *Machine, stmts: []const ast.Stmt) Error!void {
        for (stmts) |s| if (s.data == .function) {
            const f = s.data.function;
            m.store(f.name.?.binding, .{ .closure = try m.rt.heap.newTreeClosure(f, m.env) });
        };
        if (stmts.len > 0) {
            try m.pushTask(.{ .stmt_list = .{ .stmts = stmts, .idx = 0 } });
        }
    }

    fn bindingOf(m: *const Machine, ref: ast.Ref) ?u32 {
        return switch (m.res.refs[ref.id]) {
            .local => |b| b,
            .capture => |c| c.binding,
            .global => null,
        };
    }

    fn read(m: *Machine, ref: ast.Ref) Error!Value {
        const b = m.bindingOf(ref) orelse return builtins.global(m.rt, ref.name);
        return m.load(b) orelse m.tdz(ref);
    }

    fn write(m: *Machine, ref: ast.Ref, v: Value) Error!void {
        const b = m.bindingOf(ref).?;
        if (m.load(b) == null) return m.tdz(ref);
        if (m.res.bindings[b].kind == .@"const")
            return m.rt.throw(.TypeError, &.{.{ .ascii = "Assignment to constant variable." }});
        m.store(b, v);
    }

    fn tdz(m: *Machine, ref: ast.Ref) Error {
        return m.rt.throw(.ReferenceError, &.{ .{ .ascii = "Cannot access '" }, .{ .ascii = ref.name }, .{ .ascii = "' before initialization" } });
    }

    // ---- Main run loop & unwinding

    fn runLoop(m: *Machine, stop_len: usize) Error!bool {
        while (m.tasks.items.len > stop_len) {
            const task = m.tasks.pop().?;
            switch (task) {
                .barrier => return false,
                .await_suspend => {
                    m.awaited = m.popVal();
                    m.depth -= 1;
                    return true;
                },
                else => {},
            }
            const maybe_unwind = m.stepTask(task) catch |err| switch (err) {
                error.Thrown => UnwindKind.throw,
                else => return err,
            };
            if (maybe_unwind) |kind| {
                try m.unwind(kind, stop_len);
            }
        }
        return false;
    }

    fn unwind(m: *Machine, kind: UnwindKind, stop_len: usize) Error!void {
        while (m.tasks.items.len > stop_len) {
            const top = &m.tasks.items[m.tasks.items.len - 1];
            switch (top.*) {
                .barrier => |values_base| {
                    std.debug.assert(kind == .throw);
                    _ = m.tasks.pop();
                    m.values.shrinkRetainingCapacity(values_base);
                    m.ret = .undefined;
                    return error.Thrown;
                },
                .depth_pop,
                .pop_value_depth,
                .return_finish,
                .unary_finish,
                .binary_rhs,
                .binary_finish,
                .assign_ref_finish,
                .assign_ref_compound,
                .assign_member_base,
                .assign_member_after_key,
                .assign_member_plain_finish,
                .assign_member_plain_finish_key,
                .assign_member_compound_finish,
                .member_base,
                .member_finish,
                => {
                    _ = m.tasks.pop();
                    m.depth -= 1;
                },
                .scope_exit => |saved_env| {
                    _ = m.tasks.pop();
                    m.env = saved_env;
                },
                .scope_exit_depth => |saved_env| {
                    _ = m.tasks.pop();
                    m.env = saved_env;
                    m.depth -= 1;
                },
                .call_return => |cr| {
                    _ = m.tasks.pop();
                    m.env = cr.saved_env;
                    m.this = if (cr.has_this) cr.saved_this else null;
                    m.calls -= 1;
                    m.depth -= 1;
                    m.values.shrinkRetainingCapacity(cr.values_base);
                    if (kind == .@"return") {
                        const rv = m.ret;
                        m.ret = .undefined;
                        const out_v: Value = if (cr.construct_instance) |inst|
                            (if (rv.isObjectLike()) rv else .{ .object = inst })
                        else
                            rv;
                        try m.pushVal(out_v);
                        return;
                    }
                },
                .try_catch => |tc| {
                    _ = m.tasks.pop();
                    if (kind == .throw) {
                        m.env = tc.saved_env;
                        m.values.shrinkRetainingCapacity(tc.values_base);
                        if (tc.catch_param) |cp| {
                            const val = try m.rt.catchValue();
                            const catch_scope: ?u32 = m.patternScope(cp) orelse m.scopeOf(tc.catch_body);
                            if (try m.pushScope(catch_scope)) {
                                try m.pushTask(.{ .scope_exit = tc.saved_env });
                            }
                            try m.pushTask(.{ .body_hoist = tc.catch_body });
                            try m.pushTask(.{ .bind_pattern = .{ .pat = cp, .mode = .init } });
                            try m.pushVal(val);
                        } else {
                            m.rt.clearThrown();
                            const catch_scope = m.scopeOf(tc.catch_body);
                            if (try m.pushScope(catch_scope)) {
                                try m.pushTask(.{ .scope_exit = tc.saved_env });
                            }
                            try m.pushBody(tc.catch_body);
                        }
                        return;
                    }
                },
                .try_finally => |tf| {
                    _ = m.tasks.pop();
                    m.env = tf.saved_env;
                    m.values.shrinkRetainingCapacity(tf.values_base);
                    const pending: FinallyPending = switch (kind) {
                        .@"break" => .@"break",
                        .@"continue" => .@"continue",
                        .@"return" => blk: {
                            const rv = m.ret;
                            m.ret = .undefined;
                            break :blk .{ .@"return" = rv };
                        },
                        .throw => .{ .throw = try m.rt.catchValue() },
                    };
                    try m.pushTask(.{ .finally_resume = pending });
                    try m.pushTask(.{ .block = tf.finally_body });
                    return;
                },
                .while_iter => |w| {
                    if (kind == .@"continue") {
                        m.values.shrinkRetainingCapacity(w.values_base);
                        return;
                    }
                    if (kind == .@"break") {
                        _ = m.tasks.pop();
                        m.values.shrinkRetainingCapacity(w.values_base);
                        return;
                    }
                    _ = m.tasks.pop();
                },
                .do_while_cond => |dw| {
                    if (kind == .@"continue") {
                        m.values.shrinkRetainingCapacity(dw.values_base);
                        return;
                    }
                    if (kind == .@"break") {
                        _ = m.tasks.pop();
                        m.values.shrinkRetainingCapacity(dw.values_base);
                        return;
                    }
                    _ = m.tasks.pop();
                },
                .for_update => |f| {
                    if (kind == .@"continue") {
                        m.values.shrinkRetainingCapacity(f.values_base);
                        return;
                    }
                    if (kind == .@"break") {
                        _ = m.tasks.pop();
                        m.values.shrinkRetainingCapacity(f.values_base);
                        return;
                    }
                    _ = m.tasks.pop();
                },
                .for_of_iter => |f| {
                    if (kind == .@"continue") {
                        m.values.shrinkRetainingCapacity(f.values_base);
                        return;
                    }
                    if (kind == .@"break") {
                        _ = m.tasks.pop();
                        m.values.shrinkRetainingCapacity(f.values_base);
                        return;
                    }
                    _ = m.tasks.pop();
                },
                .switch_exec => |sw| {
                    if (kind == .@"break") {
                        _ = m.tasks.pop();
                        m.values.shrinkRetainingCapacity(sw.values_base);
                        return;
                    }
                    _ = m.tasks.pop();
                },
                else => _ = m.tasks.pop(),
            }
        }
        // Unwound past `stop_len` (top-level or barrier): only `throw` can reach here.
        std.debug.assert(kind == .throw);
        return error.Thrown;
    }

    inline fn pushEval(m: *Machine, e: *const ast.Expr) Error!void {
        switch (e.data) {
            .number => |n| {
                try m.enter();
                m.safepoint();
                try m.rt.step();
                m.depth -= 1;
                try m.pushVal(.{ .number = n });
            },
            .boolean => |b| {
                try m.enter();
                m.safepoint();
                try m.rt.step();
                m.depth -= 1;
                try m.pushVal(.{ .boolean = b });
            },
            .null => {
                try m.enter();
                m.safepoint();
                try m.rt.step();
                m.depth -= 1;
                try m.pushVal(.null);
            },
            .identifier => |ref| {
                try m.enter();
                m.safepoint();
                try m.rt.step();
                m.depth -= 1;
                try m.pushVal(try m.read(ref));
            },
            .this => {
                try m.enter();
                m.safepoint();
                try m.rt.step();
                m.depth -= 1;
                try m.pushVal(m.this orelse return m.rt.fail(.sloppy_this));
            },
            .update => |u| switch (u.target) {
                .ref => |ref| {
                    try m.enter();
                    m.safepoint();
                    try m.rt.step();
                    const old = try ops.toNumber(m.rt, try m.read(ref));
                    const new = if (u.op == .inc) old + 1 else old - 1;
                    try m.write(ref, .{ .number = new });
                    m.depth -= 1;
                    try m.pushVal(.{ .number = if (u.prefix) new else old });
                },
                .member => try m.pushTask(.{ .eval = e }),
            },
            else => try m.pushTask(.{ .eval = e }),
        }
    }

    inline fn stepTask(m: *Machine, task: Task) Error!?UnwindKind {
        const rt = m.rt;
        switch (task) {
            .depth_pop => m.depth -= 1,
            .scope_exit => |saved| m.env = saved,
            .scope_exit_depth => |saved| {
                m.env = saved;
                m.depth -= 1;
            },
            .pop_value_depth => {
                _ = m.popVal();
                m.depth -= 1;
            },
            .pop_value => _ = m.popVal(),
            .barrier, .await_suspend => unreachable, // handled in runLoop
            .exec => |s| return m.execStmt(s),
            .stmt_list => |sl| {
                if (sl.idx + 1 < sl.stmts.len) {
                    try m.pushTask(.{ .stmt_list = .{ .stmts = sl.stmts, .idx = sl.idx + 1 } });
                }
                return m.execStmt(&sl.stmts[sl.idx]);
            },
            .body_hoist => |stmts| try m.pushBody(stmts),
            .block => |stmts| try m.pushBlock(stmts),
            .decl_next => |dn| {
                const d = dn.decls[dn.idx];
                if (dn.idx + 1 < dn.decls.len) {
                    try m.pushTask(.{ .decl_next = .{ .decls = dn.decls, .idx = dn.idx + 1 } });
                }
                try m.pushTask(.{ .bind_pattern = .{ .pat = d.pattern, .mode = .init } });
                if (d.init) |init| {
                    try m.pushTask(.{ .eval = init });
                } else {
                    try m.pushVal(.undefined);
                }
            },
            .return_finish => {
                m.ret = m.popVal();
                m.depth -= 1;
                return .@"return";
            },
            .if_branch => |ib| {
                const v = m.popVal();
                if (ops.toBoolean(v)) {
                    return m.execStmt(ib.then);
                } else if (ib.@"else") |e| {
                    return m.execStmt(e);
                }
            },
            .while_iter => |w| {
                try rt.step();
                try m.pushTask(.{ .while_check = w });
                try m.pushEval(w.cond);
            },
            .while_check => |w| {
                const v = m.popVal();
                if (ops.toBoolean(v)) {
                    try m.pushTask(.{ .while_iter = w });
                    return m.execStmt(w.body);
                }
            },
            .do_while_iter => |dw| {
                try rt.step();
                try m.pushTask(.{ .do_while_cond = dw });
                return m.execStmt(dw.body);
            },
            .do_while_cond => |dw| {
                try m.pushTask(.{ .do_while_check = dw });
                try m.pushTask(.{ .eval = dw.cond });
            },
            .do_while_check => |dw| {
                const v = m.popVal();
                if (ops.toBoolean(v)) {
                    try m.pushTask(.{ .do_while_iter = dw });
                }
            },
            .switch_scope => |sw| {
                // Keep `disc` on `values` across `switch_test` / `switch_test_cmp`.
                const saved = m.env;
                var scope: ?u32 = null;
                for (sw.cases) |c| {
                    if (m.scopeOf(c.body)) |sc| {
                        scope = sc;
                        break;
                    }
                }
                if (try m.pushScope(scope)) {
                    try m.pushTask(.{ .scope_exit = saved });
                }
                try m.pushTask(.{ .switch_test = .{
                    .cases = sw.cases,
                    .idx = 0,
                    .default_idx = none_idx,
                    .values_base = sw.values_base,
                } });
            },
            .switch_test => |st| {
                var idx = st.idx;
                var default_idx = st.default_idx;
                while (idx < st.cases.len) : (idx += 1) {
                    if (st.cases[idx].test_expr) |te| {
                        try m.pushTask(.{ .switch_test_cmp = .{
                            .cases = st.cases,
                            .idx = idx,
                            .default_idx = default_idx,
                            .values_base = st.values_base,
                        } });
                        try m.pushEval(te);
                        return null;
                    } else {
                        default_idx = idx;
                    }
                }
                _ = m.popVal(); // disc
                if (default_idx != none_idx) {
                    try m.pushSwitchExec(st.cases, default_idx, 0, st.values_base);
                }
            },
            .switch_test_cmp => |st| {
                const tv = m.popVal();
                const disc = m.values.items[m.values.items.len - 1];
                if (ops.strictEquals(disc, tv)) {
                    _ = m.popVal(); // disc
                    try m.pushSwitchExec(st.cases, st.idx, 0, st.values_base);
                } else {
                    try m.pushTask(.{ .switch_test = .{
                        .cases = st.cases,
                        .idx = st.idx + 1,
                        .default_idx = st.default_idx,
                        .values_base = st.values_base,
                    } });
                }
            },
            .switch_exec => |se| {
                if (se.case_idx < se.cases.len) {
                    const s = &se.cases[se.case_idx].body[se.stmt_idx];
                    try m.pushSwitchExec(se.cases, se.case_idx, se.stmt_idx + 1, se.values_base);
                    return m.execStmt(s);
                }
            },
            .for_after_init => |f| {
                if (f.per_iter) try m.copyScope();
                try m.pushTask(.{ .for_iter = f });
            },
            .for_iter => |f| {
                try rt.step();
                const fs = f.stmt.data.@"for";
                if (fs.cond) |c| {
                    try m.pushTask(.{ .for_cond_check = f });
                    try m.pushEval(c);
                } else {
                    try m.pushTask(.{ .for_update = f });
                    return m.execStmt(fs.body);
                }
            },
            .for_cond_check => |f| {
                const v = m.popVal();
                if (ops.toBoolean(v)) {
                    try m.pushTask(.{ .for_update = f });
                    return m.execStmt(f.stmt.data.@"for".body);
                }
            },
            .for_update => |f| {
                if (f.per_iter) try m.copyScope();
                try m.pushTask(.{ .for_iter = f });
                if (f.stmt.data.@"for".update) |u| {
                    try m.pushTask(.pop_value);
                    try m.pushEval(u);
                }
            },
            .for_of_init => |f| {
                const iterable = m.popVal();
                const iter = try builtins.getIterator(rt, iterable);
                try m.pushTask(.{ .for_of_iter = .{
                    .stmt = f.stmt,
                    .iter = iter,
                    .has_scope = f.has_scope,
                    .values_base = f.values_base,
                } });
            },
            .for_of_iter => |f| {
                try rt.step();
                const fo = f.stmt.data.for_of;
                const next_val = (try builtins.iteratorNextVal(rt, f.iter)) orelse return null;
                try m.pushTask(.{ .for_of_iter = f });
                switch (fo.target) {
                    .declaration => |decl| {
                        if (f.has_scope) try m.copyScope();
                        try m.pushTask(.{ .exec = fo.body });
                        try m.pushTask(.{ .bind_pattern = .{ .pat = decl.pattern, .mode = .init } });
                        try m.pushVal(next_val);
                    },
                    .target => |t| {
                        try m.pushTask(.{ .exec = fo.body });
                        try m.pushTask(.{ .bind_pattern = .{ .pat = t, .mode = .assign } });
                        try m.pushVal(next_val);
                    },
                }
            },
            .throw_finish => {
                const v = m.popVal();
                return rt.throwValue(v);
            },
            .try_catch => |tc| m.env = tc.saved_env,
            .try_finally => |tf| {
                m.env = tf.saved_env;
                try m.pushTask(.{ .block = tf.finally_body });
            },
            .finally_resume => |pending| switch (pending) {
                .normal => {},
                .@"break" => return .@"break",
                .@"continue" => return .@"continue",
                .@"return" => |v| {
                    m.ret = v;
                    return .@"return";
                },
                .throw => |v| return rt.throwValue(v),
            },

            // ---- Expressions
            .eval => |e| try m.evalExpr(e),
            .template_next => |tn| {
                const v = m.popVal();
                var acc = m.popVal();
                acc = try ops.binary(rt, .add, acc, v);
                if (tn.t.quasis[tn.idx + 1].len > 0) {
                    const q: Value = .{ .string = try rt.heap.newString(&.{.{ .utf16 = tn.t.quasis[tn.idx + 1] }}) };
                    acc = try ops.binary(rt, .add, acc, q);
                }
                try m.pushVal(acc);
                if (tn.idx + 1 < tn.t.exprs.len) {
                    try m.pushTask(.{ .template_next = .{ .t = tn.t, .idx = tn.idx + 1 } });
                    try m.pushTask(.{ .eval = tn.t.exprs[tn.idx + 1] });
                }
            },
            .unary_finish => |op| {
                const v = m.popVal();
                const res_v: Value = switch (op) {
                    .neg => .{ .number = -(try ops.toNumber(rt, v)) },
                    .plus => .{ .number = try ops.toNumber(rt, v) },
                    .not => .{ .boolean = !ops.toBoolean(v) },
                    .bit_not => .{ .number = ops.bitNot(try ops.toNumber(rt, v)) },
                    .typeof => try ops.typeOf(rt, v),
                };
                m.depth -= 1;
                try m.pushVal(res_v);
            },
            .binary_rhs => |br| {
                const lhs = m.values.items[m.values.items.len - 1];
                switch (br.op) {
                    .logical_and => if (ops.toBoolean(lhs)) {
                        _ = m.popVal();
                        try m.pushTask(.depth_pop);
                        try m.pushEval(br.rhs);
                    } else {
                        m.depth -= 1;
                    },
                    .logical_or => if (!ops.toBoolean(lhs)) {
                        _ = m.popVal();
                        try m.pushTask(.depth_pop);
                        try m.pushEval(br.rhs);
                    } else {
                        m.depth -= 1;
                    },
                    .nullish => if (lhs == .null or lhs == .undefined) {
                        _ = m.popVal();
                        try m.pushTask(.depth_pop);
                        try m.pushEval(br.rhs);
                    } else {
                        m.depth -= 1;
                    },
                    else => {
                        try m.pushTask(.{ .binary_finish = br.op });
                        try m.pushEval(br.rhs);
                    },
                }
            },
            .binary_finish => |op| {
                const rhs = m.popVal();
                const lhs = m.popVal();
                const res_v = try ops.binary(rt, op, lhs, rhs);
                m.depth -= 1;
                try m.pushVal(res_v);
            },
            .cond_branch => |cb| {
                const v = m.popVal();
                try m.pushEval(if (ops.toBoolean(v)) cb.then_expr else cb.else_expr);
            },
            .assign_ref_finish => |ref| {
                const v = m.values.items[m.values.items.len - 1];
                try m.write(ref, v);
                m.depth -= 1;
            },
            .assign_ref_compound => |ac| {
                const rhs = m.popVal();
                const old = m.popVal();
                const v = try ops.binary(rt, ac.op, old, rhs);
                try m.write(ac.ref, v);
                m.depth -= 1;
                try m.pushVal(v);
            },
            .assign_member_base => |am| {
                switch (am.key) {
                    .name => |n| try m.pushTask(.{ .assign_member_after_key = .{ .op = am.op, .value = am.value, .named = n } }),
                    .computed => |e| {
                        try m.pushTask(.{ .assign_member_after_key = .{ .op = am.op, .value = am.value, .named = null } });
                        try m.pushEval(e);
                    },
                    .string, .number => unreachable,
                }
            },
            .assign_member_after_key => |am| {
                const kv: KeyValue = if (am.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base = m.values.items[m.values.items.len - 1];
                switch (am.op) {
                    .plain => {
                        if (kv == .value) try m.pushVal(kv.value);
                        try m.pushTask(.{ .assign_member_plain_finish = am.named });
                        try m.pushEval(am.value);
                    },
                    .compound => |op| {
                        const k = try m.toKey(kv);
                        const old = try object.get(rt, base, k);
                        try m.pushVal(old);
                        try m.pushTask(.{ .assign_member_compound_finish = .{ .op = op, .key = k } });
                        try m.pushEval(am.value);
                    },
                    .logical_and, .logical_or, .nullish => {
                        const k = try m.toKey(kv);
                        const old = try object.get(rt, base, k);
                        if (!logicalAssignShouldWrite(am.op, old)) {
                            _ = m.popVal(); // base
                            m.depth -= 1;
                            try m.pushVal(old);
                        } else {
                            try m.pushTask(.{ .assign_member_plain_finish_key = k });
                            try m.pushEval(am.value);
                        }
                    },
                }
            },
            .assign_member_plain_finish => |named| {
                const v = m.popVal();
                const kv: KeyValue = if (named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base = m.popVal();
                try object.set(rt, base, try m.toKey(kv), v);
                m.depth -= 1;
                try m.pushVal(v);
            },
            .assign_member_plain_finish_key => |k| {
                const v = m.popVal();
                const base = m.popVal();
                try object.set(rt, base, k, v);
                m.depth -= 1;
                try m.pushVal(v);
            },
            .assign_member_compound_finish => |ac| {
                const rhs = m.popVal();
                const old = m.popVal();
                const base = m.popVal();
                const v = try ops.binary(rt, ac.op, old, rhs);
                try object.set(rt, base, ac.key, v);
                m.depth -= 1;
                try m.pushVal(v);
            },
            .assign_pattern_keep => |pat| {
                const v = m.values.items[m.values.items.len - 1];
                try m.pushTask(.{ .bind_pattern = .{ .pat = pat, .mode = .assign } });
                try m.pushVal(v);
            },
            .update_member_base => |um| {
                switch (um.key) {
                    .name => |n| try m.pushTask(.{ .update_member_finish = .{ .op = um.op, .prefix = um.prefix, .named = n } }),
                    .computed => |e| {
                        try m.pushTask(.{ .update_member_finish = .{ .op = um.op, .prefix = um.prefix, .named = null } });
                        try m.pushTask(.{ .eval = e });
                    },
                    .string, .number => unreachable,
                }
            },
            .update_member_finish => |um| {
                const kv: KeyValue = if (um.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base = m.popVal();
                const k = try m.toKey(kv);
                const old = try ops.toNumber(rt, try object.get(rt, base, k));
                const new = if (um.op == .inc) old + 1 else old - 1;
                try object.set(rt, base, k, .{ .number = new });
                try m.pushVal(.{ .number = if (um.prefix) new else old });
            },
            .member_base => |mb| {
                switch (mb.key) {
                    .name => |n| {
                        const base = m.popVal();
                        const k = try object.named(rt, n);
                        const res_v: Value = if (mb.is_delete) .{ .boolean = try object.delete(rt, base, k) } else try object.get(rt, base, k);
                        m.depth -= 1;
                        try m.pushVal(res_v);
                    },
                    .computed => |e| {
                        try m.pushTask(.{ .member_finish = .{ .named = null, .is_delete = mb.is_delete } });
                        try m.pushEval(e);
                    },
                    .string, .number => unreachable,
                }
            },
            .member_finish => |mf| {
                const kv: KeyValue = if (mf.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base = m.popVal();
                const k = try m.toKey(kv);
                const res_v: Value = if (mf.is_delete) .{ .boolean = try object.delete(rt, base, k) } else try object.get(rt, base, k);
                m.depth -= 1;
                try m.pushVal(res_v);
            },
            .opt_after_base => |oa| {
                const mem = oa.oc.base.data.member;
                switch (mem.key) {
                    .name => |n| try m.pushTask(.{ .opt_after_member_key = .{ .oc = oa.oc, .named = n, .is_delete = oa.is_delete } }),
                    .computed => |e| {
                        try m.pushTask(.{ .opt_after_member_key = .{ .oc = oa.oc, .named = null, .is_delete = oa.is_delete } });
                        try m.pushTask(.{ .eval = e });
                    },
                    .string, .number => unreachable,
                }
            },
            .opt_after_member_key => |oa| {
                const kv: KeyValue = if (oa.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base = m.values.items[m.values.items.len - 1]; // stays as receiver
                const val = try object.get(rt, base, try m.toKey(kv));
                try m.pushVal(val);
                try m.pushTask(.{ .opt_step = .{ .oc = oa.oc, .idx = 0, .is_delete = oa.is_delete } });
            },
            .opt_step => |os| {
                // Top of values: [..., receiver, val]
                if (os.idx >= os.oc.steps.len) {
                    const val = m.popVal();
                    _ = m.popVal(); // receiver
                    try m.pushVal(val);
                    return null;
                }
                const step = os.oc.steps[os.idx];
                const val = m.values.items[m.values.items.len - 1];
                if (step.optional and (val == .null or val == .undefined)) {
                    _ = m.popVal(); // val
                    _ = m.popVal(); // receiver
                    try m.pushVal(if (os.is_delete) .{ .boolean = true } else .undefined);
                    return null;
                }
                switch (step.kind) {
                    .prop => |n| {
                        const key = try object.named(rt, n);
                        if (os.is_delete and os.idx == os.oc.steps.len - 1) {
                            _ = m.popVal();
                            _ = m.popVal();
                            try m.pushVal(.{ .boolean = try object.delete(rt, val, key) });
                            return null;
                        }
                        const next_val = try object.get(rt, val, key);
                        const vals = m.values.items;
                        vals[vals.len - 2] = val; // receiver = val
                        vals[vals.len - 1] = next_val;
                        try m.pushTask(.{ .opt_step = .{ .oc = os.oc, .idx = os.idx + 1, .is_delete = os.is_delete } });
                    },
                    .elem => |e| {
                        try m.pushTask(.{ .opt_elem_finish = .{ .oc = os.oc, .idx = os.idx, .is_delete = os.is_delete } });
                        try m.pushTask(.{ .eval = e });
                    },
                    .call => |args| {
                        const args_base = m.values.items.len;
                        try m.pushTask(.{ .opt_call_finish = .{ .oc = os.oc, .idx = os.idx, .is_delete = os.is_delete, .args_base = args_base } });
                        if (args.len > 0) {
                            try m.pushTask(.{ .eval_args_next = .{ .args = args, .idx = 0, .args_base = args_base } });
                        }
                    },
                }
            },
            .opt_elem_finish => |oe| {
                const key_v = m.popVal();
                const val = m.values.items[m.values.items.len - 1];
                const key = try object.key(rt, key_v);
                if (oe.is_delete and oe.idx == oe.oc.steps.len - 1) {
                    _ = m.popVal();
                    _ = m.popVal();
                    try m.pushVal(.{ .boolean = try object.delete(rt, val, key) });
                    return null;
                }
                const next_val = try object.get(rt, val, key);
                const vals = m.values.items;
                vals[vals.len - 2] = val;
                vals[vals.len - 1] = next_val;
                try m.pushTask(.{ .opt_step = .{ .oc = oe.oc, .idx = oe.idx + 1, .is_delete = oe.is_delete } });
            },
            .opt_call_finish => |oc_call| {
                // values: [..., receiver, callee, arg0, ...]
                const vals = m.values.items;
                const callee = vals[oc_call.args_base - 1];
                const receiver = vals[oc_call.args_base - 2];
                vals[oc_call.args_base - 2] = .undefined;
                try m.pushTask(.{ .opt_step = .{ .oc = oc_call.oc, .idx = oc_call.idx + 1, .is_delete = oc_call.is_delete } });
                try m.invokeCallable(callee, if (receiver == .undefined) null else receiver, oc_call.args_base, oc_call.args_base - 1);
            },
            .array_next => |an| {
                if (an.idx < an.items.len) {
                    const item = an.items[an.idx];
                    try m.pushTask(.{ .array_next = .{ .items = an.items, .idx = an.idx + 1 } });
                    if (item.data == .spread) {
                        try m.pushTask(.array_spread_push);
                        try m.pushTask(.{ .eval = item.data.spread });
                    } else {
                        try m.pushTask(.array_elem_push);
                        try m.pushTask(.{ .eval = item });
                    }
                }
            },
            .array_elem_push => {
                const v = m.popVal();
                const arr = m.values.items[m.values.items.len - 1].object;
                try rt.heap.appendElement(arr, v);
            },
            .array_spread_push => {
                const iterable = m.popVal();
                const arr = m.values.items[m.values.items.len - 1].object;
                const iter = try builtins.getIterator(rt, iterable);
                try m.pushVal(.{ .object = iter }); // root iter across iteratorNextVal
                defer _ = m.popVal();
                while (try builtins.iteratorNextVal(rt, iter)) |elem| {
                    try rt.heap.appendElement(arr, elem);
                }
            },
            .object_next => |on| {
                if (on.idx < on.props.len) {
                    const prop = on.props[on.idx];
                    switch (prop) {
                        .prop => |pr| {
                            if (pr.key == .computed) {
                                try m.pushTask(.{ .object_prop_computed_val = .{ .value = pr.value, .props = on.props, .idx = on.idx } });
                                try m.pushTask(.{ .eval = pr.key.computed });
                            } else {
                                const k = try m.literalKey(pr.key);
                                try m.pushTask(.{ .object_prop_val = .{ .key = k, .props = on.props, .idx = on.idx } });
                                try m.pushTask(.{ .eval = pr.value });
                            }
                        },
                        .spread => |sp| {
                            try m.pushTask(.{ .object_spread_finish = .{ .props = on.props, .idx = on.idx } });
                            try m.pushTask(.{ .eval = sp.expr });
                        },
                        .cover_init => unreachable,
                    }
                }
            },
            .object_prop_computed_val => |op| {
                const kv = m.popVal();
                const k = try object.key(rt, kv);
                try m.pushTask(.{ .object_prop_val = .{ .key = k, .props = op.props, .idx = op.idx } });
                try m.pushTask(.{ .eval = op.value });
            },
            .object_prop_key => unreachable,
            .object_prop_val => |op| {
                const v = m.popVal();
                const o = m.values.items[m.values.items.len - 1].object;
                try object.define(rt, o, op.key, v);
                if (op.idx + 1 < op.props.len) {
                    try m.pushTask(.{ .object_next = .{ .props = op.props, .idx = op.idx + 1 } });
                }
            },
            .object_spread_finish => |os| {
                const src = m.popVal();
                const o = m.values.items[m.values.items.len - 1].object;
                try copyDataProperties(rt, o, src, &.{});
                if (os.idx + 1 < os.props.len) {
                    try m.pushTask(.{ .object_next = .{ .props = os.props, .idx = os.idx + 1 } });
                }
            },
            .call_member_base => |cm| {
                switch (cm.key) {
                    .name => |n| try m.pushTask(.{ .call_member_key = .{ .named = n, .args = cm.args } }),
                    .computed => |e| {
                        try m.pushTask(.{ .call_member_key = .{ .named = null, .args = cm.args } });
                        try m.pushTask(.{ .eval = e });
                    },
                    .string, .number => unreachable,
                }
            },
            .call_member_key => |cm| {
                const kv: KeyValue = if (cm.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base = m.values.items[m.values.items.len - 1];
                const callee = try object.get(rt, base, try m.toKey(kv));
                try m.pushVal(callee);
                // values: [..., receiver (base), callee]
                const args_base = m.values.items.len;
                try m.pushTask(.{ .invoke_call = .{ .has_receiver = true, .args_base = args_base } });
                if (cm.args.len > 0) {
                    try m.pushTask(.{ .eval_args_next = .{ .args = cm.args, .idx = 0, .args_base = args_base } });
                }
            },
            .call_after_callee => |ca| {
                // values: [..., callee]
                const args_base = m.values.items.len;
                try m.pushTask(.{ .invoke_call = .{ .has_receiver = ca.has_receiver, .args_base = args_base } });
                if (ca.args.len > 0) {
                    try m.pushTask(.{ .eval_args_next = .{ .args = ca.args, .idx = 0, .args_base = args_base } });
                }
            },
            .new_call_after_callee => |args| {
                const args_base = m.values.items.len;
                try m.pushTask(.{ .invoke_new_call = args_base });
                if (args.len > 0) {
                    try m.pushTask(.{ .eval_args_next = .{ .args = args, .idx = 0, .args_base = args_base } });
                }
            },
            .eval_args_next => |ea| {
                if (ea.idx < ea.args.len) {
                    const arg = ea.args[ea.idx];
                    if (ea.idx + 1 < ea.args.len) {
                        try m.pushTask(.{ .eval_args_next = .{ .args = ea.args, .idx = ea.idx + 1, .args_base = ea.args_base } });
                    }
                    if (arg.data == .spread) {
                        try m.pushTask(.{ .eval_args_spread = .{ .args = ea.args, .idx = ea.idx, .args_base = ea.args_base } });
                        try m.pushEval(arg.data.spread);
                    } else {
                        try m.pushEval(arg);
                    }
                }
            },
            .eval_args_spread => {
                const iterable = m.popVal();
                const iter = try builtins.getIterator(rt, iterable);
                try m.pushVal(.{ .object = iter });
                var count: usize = 0;
                errdefer m.values.shrinkRetainingCapacity(m.values.items.len - count - 1);
                // Pop iter after reading? No, keep iter rooted while appending elements, then shift or remove!
                while (try builtins.iteratorNextVal(rt, iter)) |elem| {
                    try m.pushVal(elem);
                    count += 1;
                }
                // Remove `iter` which sits at `len - 1 - count`:
                _ = m.values.orderedRemove(m.values.items.len - 1 - count);
            },
            .invoke_call => |ic| {
                const args_base = ic.args_base;
                const callee = m.values.items[args_base - 1];
                const receiver: ?Value = if (ic.has_receiver) m.values.items[args_base - 2] else null;
                const pop_to = if (ic.has_receiver) args_base - 2 else args_base - 1;
                try m.invokeCallable(callee, receiver, args_base, pop_to);
            },
            .invoke_new_call => |args_base| {
                const callee = m.values.items[args_base - 1];
                var target = callee;
                if (callee == .closure and callee.closure.impl == .bound) {
                    const b = callee.closure.impl.bound;
                    target = b.target;
                    if (b.bound_args.len > 0) {
                        try m.values.insertSlice(rt.gpa, args_base, b.bound_args);
                    }
                }
                if (!builtins.isConstructor(target)) {
                    return rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }});
                }
                if (target == .native) {
                    const res_v = try builtins.construct(rt, target, m.values.items[args_base..]);
                    m.values.shrinkRetainingCapacity(args_base - 1);
                    try m.pushVal(res_v);
                    return null;
                }
                const tc = target.closure;
                const t = tc.impl.tree;
                const f: *const ast.Function = @ptrCast(@alignCast(t.func));
                const proto_val = try object.get(rt, target, try object.named(rt, "prototype"));
                const r = try builtins.realm(rt);
                const instance = try rt.heap.newObject(if (proto_val == .object) proto_val.object else r.object_prototype);
                try m.pushClosureCallSync(tc, f, t.env, .{ .object = instance }, args_base, args_base - 1, instance);
            },

            // ---- Calls
            .call_bind_param => |bp| {
                const p = bp.func.params[bp.idx];
                const args = m.values.items[bp.args_base .. bp.args_base + bp.argc];
                if (bp.idx + 1 < bp.func.params.len) {
                    try m.pushTask(.{ .call_bind_param = .{ .func = bp.func, .idx = bp.idx + 1, .args_base = bp.args_base, .argc = bp.argc } });
                } else {
                    try m.pushTask(.{ .call_enter_body = .{ .func = bp.func, .args_base = bp.args_base } });
                }
                if (p.is_rest) {
                    const arr = try rt.heap.newArray((try builtins.realm(rt)).array_prototype);
                    if (bp.idx < args.len) try rt.heap.appendElements(arr, args[bp.idx..]);
                    try m.pushTask(.{ .bind_pattern = .{ .pat = p.pattern, .mode = .init } });
                    try m.pushVal(.{ .object = arr });
                } else {
                    const v: Value = if (bp.idx < args.len) args[bp.idx] else .undefined;
                    if (p.default) |def| {
                        if (v == .undefined) {
                            try m.pushTask(.{ .bind_pattern = .{ .pat = p.pattern, .mode = .init } });
                            try m.pushEval(def);
                            return null;
                        }
                    }
                    try m.pushTask(.{ .bind_pattern = .{ .pat = p.pattern, .mode = .init } });
                    try m.pushVal(v);
                }
            },
            .call_enter_body => |cb| {
                // Pop the call's args now that all parameters are bound.
                m.values.shrinkRetainingCapacity(cb.args_base);
                _ = try m.pushScope(m.scopeOf(cb.func.body));
                try m.pushBody(cb.func.body);
            },
            .call_return => |cr| {
                // Normal return (body fell off the end without `return`).
                m.env = cr.saved_env;
                m.this = if (cr.has_this) cr.saved_this else null;
                m.calls -= 1;
                m.depth -= 1;
                m.values.shrinkRetainingCapacity(cr.values_base);
                const out_v: Value = if (cr.construct_instance) |inst| .{ .object = inst } else .undefined;
                try m.pushVal(out_v);
            },

            // ---- Patterns
            .bind_pattern => |bp| {
                const val = m.popVal();
                try m.stepBindPattern(bp.pat, val, bp.mode);
            },
            .bind_target_member_base => |mem_key| {
                // values: [..., val, base]
                switch (mem_key) {
                    .name => |n| try m.pushTask(.{ .bind_target_member_finish = n }),
                    .computed => |e| {
                        try m.pushTask(.{ .bind_target_member_finish = null });
                        try m.pushTask(.{ .eval = e });
                    },
                    .string, .number => unreachable,
                }
            },
            .bind_target_member_finish => |named| {
                const kv: KeyValue = if (named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base = m.popVal();
                const val = m.popVal();
                const k = try m.toKey(kv);
                try object.set(rt, base, k, val);
            },
            .bind_array_elem => |ba| {
                // values: [..., iter]
                const iter = m.values.items[m.values.items.len - 1].object;
                const arr = ba.pat.data.array;
                if (ba.idx < arr.elems.len) {
                    const maybe_el = arr.elems[ba.idx];
                    if (maybe_el == null) {
                        _ = try builtins.iteratorNextVal(rt, iter);
                        try m.pushTask(.{ .bind_array_elem = .{ .pat = ba.pat, .idx = ba.idx + 1, .mode = ba.mode } });
                        return null;
                    }
                    const el = maybe_el.?;
                    if (ba.mode == .assign and el.pattern.data == .target and el.pattern.data.target == .member) {
                        const mem = el.pattern.data.target.member;
                        try m.pushTask(.{ .bind_array_elem_pre_member = .{
                            .pat = ba.pat,
                            .idx = ba.idx,
                            .mode = ba.mode,
                            .key = mem.key,
                        } });
                        try m.pushEval(mem.object);
                        return null;
                    }
                    const v = (try builtins.iteratorNextVal(rt, iter)) orelse .undefined;
                    if (el.default) |def| if (v == .undefined) {
                        try m.pushTask(.{ .bind_array_elem_after_default = .{
                            .pat = ba.pat,
                            .idx = ba.idx,
                            .mode = ba.mode,
                            .has_mv = false,
                        } });
                        try m.pushEval(def);
                        return null;
                    };
                    try m.pushTask(.{ .bind_array_elem = .{ .pat = ba.pat, .idx = ba.idx + 1, .mode = ba.mode } });
                    try m.pushTask(.{ .bind_pattern = .{ .pat = el.pattern, .mode = ba.mode } });
                    try m.pushVal(v);
                    return null;
                }
                if (arr.rest) |rest| {
                    if (ba.mode == .assign and rest.data == .target and rest.data.target == .member) {
                        const mem = rest.data.target.member;
                        try m.pushTask(.{ .bind_array_rest_pre_member = .{ .rest = rest, .key = mem.key } });
                        try m.pushEval(mem.object);
                        return null;
                    }
                    const rest_arr = try rt.heap.newArray((try builtins.realm(rt)).array_prototype);
                    try m.pushVal(.{ .object = rest_arr });
                    while (try builtins.iteratorNextVal(rt, iter)) |elem| {
                        try rt.heap.appendElement(rest_arr, elem);
                    }
                    const ra = m.popVal();
                    _ = m.popVal(); // iter
                    try m.pushTask(.{ .bind_pattern = .{ .pat = rest, .mode = ba.mode } });
                    try m.pushVal(ra);
                    return null;
                }
                _ = m.popVal(); // iter
            },
            .bind_array_elem_pre_member => |ba| {
                // values: [..., iter, base]
                switch (ba.key) {
                    .name => |n| try m.pushTask(.{ .bind_array_elem_pre_member_key = .{ .pat = ba.pat, .idx = ba.idx, .mode = ba.mode, .named = n } }),
                    .computed => |e| {
                        try m.pushTask(.{ .bind_array_elem_pre_member_key = .{ .pat = ba.pat, .idx = ba.idx, .mode = ba.mode, .named = null } });
                        try m.pushEval(e);
                    },
                    .string, .number => unreachable,
                }
            },
            .bind_array_elem_pre_member_key => |ba| {
                // values: [..., iter, base, (key_v?)]
                const iter_idx = if (ba.named == null) m.values.items.len - 3 else m.values.items.len - 2;
                const iter = m.values.items[iter_idx].object;
                const el = ba.pat.data.array.elems[ba.idx].?;
                const v = (try builtins.iteratorNextVal(rt, iter)) orelse .undefined;
                if (el.default) |def| if (v == .undefined) {
                    try m.pushTask(.{ .bind_array_elem_after_default = .{
                        .pat = ba.pat,
                        .idx = ba.idx,
                        .mode = ba.mode,
                        .has_mv = true,
                    } });
                    try m.pushEval(def);
                    return null;
                };
                const kv: KeyValue = if (ba.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base = m.popVal();
                try object.set(rt, base, try m.toKey(kv), v);
                try m.pushTask(.{ .bind_array_elem = .{ .pat = ba.pat, .idx = ba.idx + 1, .mode = ba.mode } });
            },
            .bind_array_elem_after_default => |ba| {
                const v = m.popVal();
                const el = ba.pat.data.array.elems[ba.idx].?;
                if (ba.has_mv) {
                    const mem_key = el.pattern.data.target.member.key;
                    const kv: KeyValue = switch (mem_key) {
                        .name => |n| .{ .named = n },
                        .computed => .{ .value = m.popVal() },
                        .string, .number => unreachable,
                    };
                    const base = m.popVal();
                    try object.set(rt, base, try m.toKey(kv), v);
                    try m.pushTask(.{ .bind_array_elem = .{ .pat = ba.pat, .idx = ba.idx + 1, .mode = ba.mode } });
                } else {
                    try m.pushTask(.{ .bind_array_elem = .{ .pat = ba.pat, .idx = ba.idx + 1, .mode = ba.mode } });
                    try m.pushTask(.{ .bind_pattern = .{ .pat = el.pattern, .mode = ba.mode } });
                    try m.pushVal(v);
                }
            },
            .bind_array_rest_pre_member => |br| {
                switch (br.key) {
                    .name => |n| try m.pushTask(.{ .bind_array_rest_pre_member_key = n }),
                    .computed => |e| {
                        try m.pushTask(.{ .bind_array_rest_pre_member_key = null });
                        try m.pushEval(e);
                    },
                    .string, .number => unreachable,
                }
            },
            .bind_array_rest_pre_member_key => |named| {
                // values: [..., iter, base, (key_v?)]
                const kv: KeyValue = if (named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base = m.popVal();
                const iter = m.popVal().object;
                try m.pushVal(base);
                if (kv == .value) try m.pushVal(kv.value);
                const rest_arr = try rt.heap.newArray((try builtins.realm(rt)).array_prototype);
                try m.pushVal(.{ .object = rest_arr });
                while (try builtins.iteratorNextVal(rt, iter)) |elem| {
                    try rt.heap.appendElement(rest_arr, elem);
                }
                const ra = m.popVal();
                const kv2: KeyValue = if (named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base2 = m.popVal();
                try object.set(rt, base2, try m.toKey(kv2), ra);
            },
            .bind_object_prop => |bo| {
                // values: [..., val, (excl_0, ..., excl_{excl_count-1})]
                const obj = bo.pat.data.object;
                if (bo.idx < obj.props.len) {
                    const pr = obj.props[bo.idx];
                    if (pr.key == .computed) {
                        try m.pushTask(.{ .bind_object_prop_after_key = bo });
                        try m.pushEval(pr.key.computed);
                        return null;
                    }
                    const k = try m.literalKey(pr.key);
                    try m.bindObjectPropWithKey(bo, k);
                    return null;
                }
                if (obj.rest) |rest| {
                    if (bo.mode == .assign and rest.data == .target and rest.data.target == .member) {
                        const mem = rest.data.target.member;
                        try m.pushTask(.{ .bind_object_rest_pre_member = .{
                            .excl_base = bo.excl_base,
                            .excl_count = bo.excl_count,
                            .key = mem.key,
                        } });
                        try m.pushEval(mem.object);
                        return null;
                    }
                    const rest_obj = try rt.heap.newObject((try builtins.realm(rt)).object_prototype);
                    try m.pushVal(.{ .object = rest_obj });
                    const val = m.values.items[bo.excl_base - 1];
                    try m.copyExcludedDataProperties(rest_obj, val, bo.excl_base, bo.excl_count);
                    const ro = m.popVal();
                    m.values.shrinkRetainingCapacity(bo.excl_base - 1); // pop excl + val
                    try m.pushTask(.{ .bind_pattern = .{ .pat = rest, .mode = bo.mode } });
                    try m.pushVal(ro);
                    return null;
                }
                m.values.shrinkRetainingCapacity(bo.excl_base - 1);
            },
            .bind_object_prop_after_key => |bo| {
                const kv = m.popVal();
                const k = try object.key(rt, kv);
                try m.bindObjectPropWithKey(bo, k);
            },
            .bind_object_prop_pre_member => |bo| {
                switch (bo.mem_key) {
                    .name => |n| try m.pushTask(.{ .bind_object_prop_pre_member_key = .{
                        .pat = bo.pat,
                        .idx = bo.idx,
                        .mode = bo.mode,
                        .excl_base = bo.excl_base,
                        .excl_count = bo.excl_count,
                        .named = n,
                    } }),
                    .computed => |e| {
                        try m.pushTask(.{ .bind_object_prop_pre_member_key = .{
                            .pat = bo.pat,
                            .idx = bo.idx,
                            .mode = bo.mode,
                            .excl_base = bo.excl_base,
                            .excl_count = bo.excl_count,
                            .named = null,
                        } });
                        try m.pushEval(e);
                    },
                    .string, .number => unreachable,
                }
            },
            .bind_object_prop_pre_member_key => |bo| {
                // values: [..., val, (excl...), prop_key_val, base, (mem_key_v?)]
                const val = m.values.items[bo.excl_base - 1];
                const pr = bo.pat.data.object.props[bo.idx];
                const key_idx = if (bo.named == null) m.values.items.len - 3 else m.values.items.len - 2;
                const k = valueToKey(m.values.items[key_idx]);
                const v = try object.get(rt, val, k);
                if (pr.default) |def| if (v == .undefined) {
                    try m.pushTask(.{ .bind_object_prop_after_default = .{
                        .pat = bo.pat,
                        .idx = bo.idx,
                        .mode = bo.mode,
                        .excl_base = bo.excl_base,
                        .excl_count = bo.excl_count,
                        .has_mv = true,
                    } });
                    try m.pushEval(def);
                    return null;
                };
                const kv: KeyValue = if (bo.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base = m.popVal();
                _ = m.popVal(); // prop_key_val
                try object.set(rt, base, try m.toKey(kv), v);
                try m.pushTask(.{ .bind_object_prop = .{
                    .pat = bo.pat,
                    .idx = bo.idx + 1,
                    .mode = bo.mode,
                    .excl_base = bo.excl_base,
                    .excl_count = bo.excl_count,
                } });
            },
            .bind_object_prop_after_default => |bo| {
                const v = m.popVal();
                const pr = bo.pat.data.object.props[bo.idx];
                if (bo.has_mv) {
                    const mem_key = pr.pattern.data.target.member.key;
                    const kv: KeyValue = switch (mem_key) {
                        .name => |n| .{ .named = n },
                        .computed => .{ .value = m.popVal() },
                        .string, .number => unreachable,
                    };
                    const base = m.popVal();
                    _ = m.popVal(); // prop_key_val
                    try object.set(rt, base, try m.toKey(kv), v);
                    try m.pushTask(.{ .bind_object_prop = .{
                        .pat = bo.pat,
                        .idx = bo.idx + 1,
                        .mode = bo.mode,
                        .excl_base = bo.excl_base,
                        .excl_count = bo.excl_count,
                    } });
                } else {
                    try m.pushTask(.{ .bind_object_prop = .{
                        .pat = bo.pat,
                        .idx = bo.idx + 1,
                        .mode = bo.mode,
                        .excl_base = bo.excl_base,
                        .excl_count = bo.excl_count,
                    } });
                    try m.pushTask(.{ .bind_pattern = .{ .pat = pr.pattern, .mode = bo.mode } });
                    try m.pushVal(v);
                }
            },
            .bind_object_rest_pre_member => |bo| {
                switch (bo.key) {
                    .name => |n| try m.pushTask(.{ .bind_object_rest_pre_member_key = .{ .excl_base = bo.excl_base, .excl_count = bo.excl_count, .named = n } }),
                    .computed => |e| {
                        try m.pushTask(.{ .bind_object_rest_pre_member_key = .{ .excl_base = bo.excl_base, .excl_count = bo.excl_count, .named = null } });
                        try m.pushEval(e);
                    },
                    .string, .number => unreachable,
                }
            },
            .bind_object_rest_pre_member_key => |bo| {
                const kv: KeyValue = if (bo.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base = m.popVal();
                const val = m.values.items[bo.excl_base - 1];
                const rest_obj = try rt.heap.newObject((try builtins.realm(rt)).object_prototype);
                try m.pushVal(.{ .object = rest_obj });
                try m.copyExcludedDataProperties(rest_obj, val, bo.excl_base, bo.excl_count);
                _ = m.popVal(); // rest_obj
                try object.set(rt, base, try m.toKey(kv), .{ .object = rest_obj });
                m.values.shrinkRetainingCapacity(bo.excl_base - 1);
            },
        }
        return null;
    }

    fn execStmt(m: *Machine, s: *const ast.Stmt) Error!?UnwindKind {
        try m.enter();
        m.safepoint();
        try m.rt.step();
        switch (s.data) {
            .empty, .function => m.depth -= 1,
            .expression => |e| {
                try m.pushTask(.pop_value_depth);
                try m.pushEval(e);
            },
            .declaration => |decl| {
                if (decl.declarators.len == 0) {
                    m.depth -= 1;
                } else {
                    try m.pushTask(.depth_pop);
                    try m.pushTask(.{ .decl_next = .{ .decls = decl.declarators, .idx = 0 } });
                }
            },
            .block => |stmts| {
                const saved = m.env;
                if (try m.pushScope(m.scopeOf(stmts))) {
                    try m.pushTask(.{ .scope_exit_depth = saved });
                } else {
                    try m.pushTask(.depth_pop);
                }
                for (stmts) |st| if (st.data == .function) {
                    const f = st.data.function;
                    m.store(f.name.?.binding, .{ .closure = try m.rt.heap.newTreeClosure(f, m.env) });
                };
                if (stmts.len > 0) {
                    if (stmts.len > 1) {
                        try m.pushTask(.{ .stmt_list = .{ .stmts = stmts, .idx = 1 } });
                    }
                    return m.execStmt(&stmts[0]);
                }
            },
            .@"return" => |v| {
                if (v) |e| {
                    try m.pushTask(.return_finish);
                    try m.pushEval(e);
                } else {
                    m.depth -= 1;
                    m.ret = .undefined;
                    return .@"return";
                }
            },
            .@"if" => |i| {
                try m.pushTask(.depth_pop);
                try m.pushTask(.{ .if_branch = .{ .then = i.then, .@"else" = i.@"else" } });
                try m.pushTask(.{ .eval = i.cond });
            },
            .@"while" => |w| {
                try m.pushTask(.depth_pop);
                try m.pushTask(.{ .while_iter = .{ .cond = w.cond, .body = w.body, .values_base = @intCast(m.values.items.len) } });
            },
            .do_while => |dw| {
                try m.pushTask(.depth_pop);
                try m.pushTask(.{ .do_while_iter = .{ .body = dw.body, .cond = dw.cond, .values_base = @intCast(m.values.items.len) } });
            },
            .@"switch" => |sw| {
                try m.pushTask(.depth_pop);
                try m.pushTask(.{ .switch_scope = .{ .cases = sw.cases, .values_base = @intCast(m.values.items.len) } });
                try m.pushEval(sw.discriminant);
            },
            .@"for" => |f| {
                const values_base: u32 = @intCast(m.values.items.len);
                try m.pushTask(.depth_pop);
                const saved = m.env;
                var per_iter = false;
                if (f.init) |init| switch (init) {
                    .declaration => |decl| {
                        var head_scope: ?u32 = null;
                        for (decl.declarators) |d| {
                            if (m.patternScope(d.pattern)) |sc| {
                                head_scope = sc;
                                break;
                            }
                        }
                        if (try m.pushScope(head_scope)) {
                            try m.pushTask(.{ .scope_exit = saved });
                        }
                        per_iter = decl.kind == .let and head_scope != null;
                        try m.pushTask(.{ .for_after_init = .{ .stmt = s, .per_iter = per_iter, .values_base = values_base } });
                        if (decl.declarators.len > 0) {
                            try m.pushTask(.{ .decl_next = .{ .decls = decl.declarators, .idx = 0 } });
                        }
                    },
                    .expression => |e| {
                        try m.pushTask(.{ .for_after_init = .{ .stmt = s, .per_iter = false, .values_base = values_base } });
                        try m.pushTask(.pop_value);
                        try m.pushEval(e);
                    },
                } else {
                    try m.pushTask(.{ .for_after_init = .{ .stmt = s, .per_iter = false, .values_base = values_base } });
                }
            },
            .for_of => |f| {
                const values_base: u32 = @intCast(m.values.items.len);
                try m.pushTask(.depth_pop);
                const saved = m.env;
                var has_scope = false;
                if (f.target == .declaration) {
                    const sc = m.patternScope(f.target.declaration.pattern);
                    has_scope = sc != null;
                    if (try m.pushScope(sc)) {
                        try m.pushTask(.{ .scope_exit = saved });
                    }
                }
                try m.pushTask(.{ .for_of_init = .{ .stmt = s, .has_scope = has_scope, .values_base = values_base } });
                try m.pushEval(f.iterable);
            },
            .@"break" => {
                m.depth -= 1;
                return .@"break";
            },
            .@"continue" => {
                m.depth -= 1;
                return .@"continue";
            },
            .throw => |e| {
                try m.pushTask(.depth_pop);
                try m.pushTask(.throw_finish);
                try m.pushEval(e);
            },
            .@"try" => |t| {
                const values_base: u32 = @intCast(m.values.items.len);
                const saved = m.env;
                try m.pushTask(.depth_pop);
                if (t.finally_body) |fb| {
                    try m.pushTask(.{ .try_finally = .{ .finally_body = fb, .saved_env = saved, .values_base = values_base } });
                }
                if (t.catch_body) |cb| {
                    try m.pushTask(.{ .try_catch = .{ .catch_param = t.catch_param, .catch_body = cb, .saved_env = saved, .values_base = values_base } });
                }
                try m.pushTask(.{ .block = t.body });
            },
        }
        return null;
    }

    fn evalExpr(m: *Machine, e: *const ast.Expr) Error!void {
        const rt = m.rt;
        try m.enter();
        m.safepoint();
        try rt.step();
        switch (e.data) {
            .number => |n| {
                m.depth -= 1;
                try m.pushVal(.{ .number = n });
            },
            .string => |units| {
                m.depth -= 1;
                try m.pushVal(.{ .string = try rt.heap.newString(&.{.{ .utf16 = units }}) });
            },
            .regexp => |rx| {
                m.depth -= 1;
                try m.pushVal(try builtins.newRegExpFromLiteral(rt, rx.pattern, rx.flags));
            },
            .boolean => |b| {
                m.depth -= 1;
                try m.pushVal(.{ .boolean = b });
            },
            .null => {
                m.depth -= 1;
                try m.pushVal(.null);
            },
            .identifier => |ref| {
                m.depth -= 1;
                try m.pushVal(try m.read(ref));
            },
            .this => {
                m.depth -= 1;
                try m.pushVal(m.this orelse return rt.fail(.sloppy_this));
            },
            .function => |f| {
                m.depth -= 1;
                try m.pushVal(try m.evalFunction(f));
            },
            .await => |inner| {
                try m.pushTask(.await_suspend);
                try m.pushEval(inner);
            },
            .template => |t| {
                const first: Value = .{ .string = try rt.heap.newString(&.{.{ .utf16 = t.quasis[0] }}) };
                try m.pushVal(first);
                if (t.exprs.len == 0) {
                    m.depth -= 1;
                } else {
                    try m.pushTask(.depth_pop);
                    try m.pushTask(.{ .template_next = .{ .t = t, .idx = 0 } });
                    try m.pushTask(.{ .eval = t.exprs[0] });
                }
            },
            .unary => |u| {
                if (u.op == .typeof and u.operand.data == .identifier) {
                    const ref = u.operand.data.identifier;
                    if (m.res.refs[ref.id] == .global) {
                        m.depth -= 1;
                        try m.pushVal(try ops.typeOf(rt, try builtins.tryGlobal(rt, ref.name)));
                        return;
                    }
                }
                try m.pushTask(.{ .unary_finish = u.op });
                try m.pushEval(u.operand);
            },
            .binary => |b| {
                try m.pushTask(.{ .binary_rhs = .{ .op = b.op, .rhs = b.rhs } });
                try m.pushEval(b.lhs);
            },
            .conditional => |c| {
                try m.pushTask(.depth_pop);
                try m.pushTask(.{ .cond_branch = .{ .then_expr = c.then_expr, .else_expr = c.else_expr } });
                try m.pushEval(c.cond);
            },
            .assign => |a| switch (a.target) {
                .ref => |ref| switch (a.op) {
                    .plain => {
                        try m.pushTask(.{ .assign_ref_finish = ref });
                        try m.pushEval(a.value);
                    },
                    .compound => |op| {
                        const old = try m.read(ref);
                        try m.pushVal(old);
                        try m.pushTask(.{ .assign_ref_compound = .{ .ref = ref, .op = op } });
                        try m.pushEval(a.value);
                    },
                    .logical_and, .logical_or, .nullish => {
                        const old = try m.read(ref);
                        if (!logicalAssignShouldWrite(a.op, old)) {
                            m.depth -= 1;
                            try m.pushVal(old);
                        } else {
                            try m.pushTask(.{ .assign_ref_finish = ref });
                            try m.pushEval(a.value);
                        }
                    },
                },
                .member => |mem| {
                    try m.pushTask(.{ .assign_member_base = .{ .op = a.op, .key = mem.key, .value = a.value } });
                    try m.pushEval(mem.object);
                },
            },
            .assign_pattern => |ap| {
                try m.pushTask(.depth_pop);
                try m.pushTask(.{ .assign_pattern_keep = ap.pattern });
                try m.pushTask(.{ .eval = ap.value });
            },
            .spread, .hole => unreachable,
            .update => |u| switch (u.target) {
                .ref => |ref| {
                    const old = try ops.toNumber(rt, try m.read(ref));
                    const new = if (u.op == .inc) old + 1 else old - 1;
                    try m.write(ref, .{ .number = new });
                    m.depth -= 1;
                    try m.pushVal(.{ .number = if (u.prefix) new else old });
                },
                .member => |mem| {
                    try m.pushTask(.depth_pop);
                    try m.pushTask(.{ .update_member_base = .{ .op = u.op, .prefix = u.prefix, .key = mem.key } });
                    try m.pushTask(.{ .eval = mem.object });
                },
            },
            .member => |mem| {
                try m.pushTask(.{ .member_base = .{ .key = mem.key, .is_delete = false } });
                try m.pushEval(mem.object);
            },
            .delete => |mem| {
                try m.pushTask(.{ .member_base = .{ .key = mem.key, .is_delete = true } });
                try m.pushEval(mem.object);
            },
            .optional_chain => |oc| try m.startOptionalChain(oc, false),
            .delete_optional => |oc| try m.startOptionalChain(oc, true),
            .array => |items| {
                const arr = try rt.heap.newArray((try builtins.realm(rt)).array_prototype);
                try m.pushVal(.{ .object = arr });
                if (items.len == 0) {
                    m.depth -= 1;
                } else {
                    try m.pushTask(.depth_pop);
                    try m.pushTask(.{ .array_next = .{ .items = items, .idx = 0 } });
                }
            },
            .object => |props| {
                const o = try rt.heap.newObject((try builtins.realm(rt)).object_prototype);
                try m.pushVal(.{ .object = o });
                if (props.len == 0) {
                    m.depth -= 1;
                } else {
                    try m.pushTask(.depth_pop);
                    try m.pushTask(.{ .object_next = .{ .props = props, .idx = 0 } });
                }
            },
            .call => |c| {
                try m.pushTask(.depth_pop);
                if (c.callee.data == .member) {
                    const mem = c.callee.data.member;
                    try m.pushTask(.{ .call_member_base = .{ .key = mem.key, .args = c.args } });
                    try m.pushEval(mem.object);
                } else {
                    try m.pushTask(.{ .call_after_callee = .{ .args = c.args, .has_receiver = false } });
                    try m.pushEval(c.callee);
                }
            },
            .new_call => |nc| {
                try m.pushTask(.depth_pop);
                try m.pushTask(.{ .new_call_after_callee = nc.args });
                try m.pushTask(.{ .eval = nc.callee });
            },
        }
    }

    fn startOptionalChain(m: *Machine, oc: ast.OptionalChain, is_delete: bool) Error!void {
        try m.pushTask(.depth_pop);
        if (oc.steps[0].kind == .call and oc.base.data == .member) {
            const mem = oc.base.data.member;
            try m.pushTask(.{ .opt_after_base = .{ .oc = oc, .is_delete = is_delete } });
            try m.pushTask(.{ .eval = mem.object });
        } else {
            try m.pushVal(.undefined); // null receiver
            try m.pushTask(.{ .opt_step = .{ .oc = oc, .idx = 0, .is_delete = is_delete } });
            try m.pushTask(.{ .eval = oc.base });
        }
    }

    fn pushSwitchExec(m: *Machine, cases: []const ast.SwitchCase, case_idx_in: u32, stmt_idx_in: u32, values_base: u32) Error!void {
        var ci = case_idx_in;
        var si = stmt_idx_in;
        while (ci < cases.len and si >= cases[ci].body.len) {
            ci += 1;
            si = 0;
        }
        try m.pushTask(.{ .switch_exec = .{ .cases = cases, .case_idx = ci, .stmt_idx = si, .values_base = values_base } });
    }

    fn evalFunction(m: *Machine, f: *const ast.Function) Error!Value {
        const rt = m.rt;
        const c = if (f.name) |n| blk: {
            const own = try rt.heap.newEnv(m.env, m.res.bindings[n.binding].scope, 1);
            const cl = try rt.heap.newTreeClosure(f, own);
            rt.heap.storeEnv(own, 0, .{ .closure = cl });
            break :blk cl;
        } else try rt.heap.newTreeClosure(f, m.env);
        if (f.is_arrow) {
            if (m.this) |t| try rt.heap.storeClosureLexicalThis(c, t);
        }
        return .{ .closure = c };
    }

    fn invokeCallable(m: *Machine, callee: Value, receiver: ?Value, args_base: usize, result_base: usize) Error!void {
        const rt = m.rt;
        if (callee == .closure and callee.closure.impl == .bound) {
            const b = callee.closure.impl.bound;
            if (b.bound_args.len > 0) {
                try m.values.insertSlice(rt.gpa, args_base, b.bound_args);
            }
            return m.invokeCallable(b.target, b.bound_this, args_base, result_base);
        }
        const args = m.values.items[args_base..];
        switch (callee) {
            .native => |n| {
                const res_v = if (n.host != null) return rt.fail(.builtin) else try n.call(rt, receiver orelse .undefined, args);
                m.values.shrinkRetainingCapacity(result_base);
                try m.pushVal(res_v);
            },
            .closure => |cl| {
                const this_val: ?Value = if (receiver) |r| (if (r.isObjectLike()) r else null) else null;
                try m.pushClosureCall(cl, this_val, args_base, result_base);
            },
            else => return rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }}),
        }
    }

    fn pushClosureCall(m: *Machine, closure: *const heap.Closure, this: ?Value, args_base: usize, result_base: usize) Error!void {
        closure.obj.checkLive();
        const t = switch (closure.impl) {
            .promise_cap => |pc| {
                const res_v = try builtins.callPromiseCapability(m.rt, pc.promise, pc.is_reject, m.values.items[args_base..]);
                m.values.shrinkRetainingCapacity(result_base);
                try m.pushVal(res_v);
                return;
            },
            .native_closure => |nc| {
                const f: *const fn (*Runtime, *heap.Object, []const Value) Error!Value = @ptrCast(@alignCast(nc.func));
                const res_v = try f(m.rt, nc.env, m.values.items[args_base..]);
                m.values.shrinkRetainingCapacity(result_base);
                try m.pushVal(res_v);
                return;
            },
            .tree => |t| t,
            .vm, .bound => return m.rt.bug("a non-tree-walker closure in the tree-walker"),
        };
        const f: *const ast.Function = @ptrCast(@alignCast(t.func));
        if (f.is_async) {
            const p = try startAsync(m.rt, m, closure, this, m.values.items[args_base..]);
            m.values.shrinkRetainingCapacity(result_base);
            try m.pushVal(p);
            return;
        }
        return m.pushClosureCallSync(closure, f, t.env, this, args_base, result_base, null);
    }

    fn pushClosureCallSync(m: *Machine, closure: *const heap.Closure, f: *const ast.Function, env: ?*Env, this: ?Value, args_base: usize, result_base: usize, construct_instance: ?*heap.Object) Error!void {
        if (m.calls >= m.rt.limits.max_call_depth) return m.rt.limit(.call_depth);
        try m.enter();
        m.calls += 1;

        const saved_env = m.env;
        const saved_this = m.this;
        try m.pushTask(.{ .call_return = .{
            .saved_env = saved_env,
            .saved_this = saved_this orelse .undefined,
            .has_this = saved_this != null,
            .values_base = @intCast(result_base),
            .construct_instance = construct_instance,
        } });

        m.env = env;
        m.this = if (f.is_arrow) (if (closure.meta) |meta| meta.lexical_this else null) else this;
        if (m.res.functions[f.id].param_scope) |ps| {
            if (m.res.scopes[ps].len > 0) _ = try m.pushScope(ps);
        }
        const argc: u32 = @intCast(m.values.items.len - args_base);
        if (f.params.len > 0) {
            try m.pushTask(.{ .call_bind_param = .{ .func = f, .idx = 0, .args_base = @intCast(args_base), .argc = argc } });
        } else {
            try m.pushTask(.{ .call_enter_body = .{ .func = f, .args_base = @intCast(args_base) } });
        }
    }

    fn callFromBuiltin(ctx: *anyopaque, closure: *const heap.Closure, this: ?Value, args: []const Value) Error!Value {
        const m: *Machine = @ptrCast(@alignCast(ctx));
        closure.obj.checkLive();
        const t = switch (closure.impl) {
            .promise_cap => |pc| return builtins.callPromiseCapability(m.rt, pc.promise, pc.is_reject, args),
            .native_closure => |nc| {
                const f: *const fn (*Runtime, *heap.Object, []const Value) Error!Value = @ptrCast(@alignCast(nc.func));
                return f(m.rt, nc.env, args);
            },
            .tree => |t| t,
            .vm, .bound => return m.rt.bug("a non-tree-walker closure in the tree-walker"),
        };
        const f: *const ast.Function = @ptrCast(@alignCast(t.func));
        if (f.is_async) return startAsync(m.rt, m, closure, this, args);

        const values_base = m.values.items.len;
        const stop_len = m.tasks.items.len;
        errdefer {
            m.tasks.shrinkRetainingCapacity(stop_len);
            m.values.shrinkRetainingCapacity(values_base);
        }
        try m.pushTask(.{ .barrier = @intCast(values_base) });
        const args_base = m.values.items.len;
        try m.values.appendSlice(m.rt.gpa, args);
        try m.pushClosureCallSync(closure, f, t.env, this, args_base, values_base, null);
        // Run until `.barrier` is reached (either via normal return from `call_return`
        // or via `unwind` hitting `.barrier`).
        _ = try m.runLoop(stop_len);
        return m.popVal();
    }

    const StartAsyncCtx = struct {
        rt: *Runtime,
        caller: *Machine,
        closure: *const heap.Closure,
        this: ?Value,
        args: []const Value,
    };

    const CoroAction = union(enum) {
        start,
        @"resume": struct { val: Value, rejected: bool },
    };

    fn startAsync(rt: *Runtime, caller: *Machine, closure: *const heap.Closure, this: ?Value, args: []const Value) Error!Value {
        const ctx: StartAsyncCtx = .{ .rt = rt, .caller = caller, .closure = closure, .this = this, .args = args };
        return coroutine.start(rt, &coro_vtable, ctx, createAndRunCoro);
    }

    fn createAndRunCoro(ctx: StartAsyncCtx, co: *heap.Coroutine) Error!coroutine.Outcome {
        const rt = ctx.rt;
        const m_ptr = try rt.gpa.create(Machine);
        m_ptr.* = .{
            .rt = rt,
            .res = ctx.caller.res,
            .is_coroutine = true,
            .calls = ctx.caller.calls,
            .depth = ctx.caller.depth,
            .stack_top = if (builtin.is_test) @frameAddress() else 0,
            .lowest_frame = if (builtin.is_test) @frameAddress() else 0,
        };
        errdefer {
            if (co.engine == null) {
                m_ptr.deinit();
                rt.gpa.destroy(m_ptr);
            }
        }
        const t = ctx.closure.impl.tree;
        const f: *const ast.Function = @ptrCast(@alignCast(t.func));
        try m_ptr.values.appendSlice(rt.gpa, ctx.args);
        try m_ptr.pushClosureCallSync(ctx.closure, f, t.env, ctx.this, 0, 0, null);
        co.engine = m_ptr;
        co.state = .running;
        return runCoroMachine(m_ptr, ctx.caller.calls, ctx.caller.depth, .start);
    }

    fn runCoroMachine(m: *Machine, caller_calls: u32, caller_depth: u32, action: CoroAction) Error!coroutine.Outcome {
        const rt = m.rt;
        const prev_caller = rt.closure_caller;
        rt.closure_caller = .{ .ctx = m, .call = Machine.callFromBuiltin };
        defer rt.closure_caller = prev_caller;

        try rt.addRoots(m.roots());
        defer rt.removeRoots(m);

        switch (action) {
            .start => {},
            .@"resume" => |res| {
                m.awaited = .undefined;
                if (res.rejected) {
                    _ = rt.throwValue(res.val) catch {};
                    m.unwind(.throw, 0) catch |ue| {
                        if (ue == error.Thrown) return .threw;
                        return ue;
                    };
                } else {
                    try m.pushVal(res.val);
                }
            },
        }

        const awaiting = m.runLoop(0) catch |e| {
            if (e == error.Thrown) return .threw;
            return e;
        };
        if (awaiting) {
            m.calls -= caller_calls;
            m.depth -= caller_depth;
            return .{ .awaiting = m.awaited };
        }
        return .{ .returned = m.popVal() };
    }

    fn coroResume(eng: *anyopaque, val: Value, rejected: bool) Error!coroutine.Outcome {
        const m: *Machine = @ptrCast(@alignCast(eng));
        return runCoroMachine(m, 0, 0, .{ .@"resume" = .{ .val = val, .rejected = rejected } });
    }

    fn coroTrace(eng: *anyopaque, visit_ctx: *anyopaque, visit: *const fn (*anyopaque, *heap.Obj) void) void {
        const m: *const Machine = @ptrCast(@alignCast(eng));
        const Ctx = struct { ctx: *anyopaque, visit: *const fn (*anyopaque, *heap.Obj) void };
        const thunk = struct {
            fn call(c: Ctx, o: *heap.Obj) void {
                c.visit(c.ctx, o);
            }
        }.call;
        visitRoots(m, Ctx{ .ctx = visit_ctx, .visit = visit }, thunk);
    }

    pub fn ownedBytes(m: *const Machine) usize {
        return @sizeOf(Machine) +
            m.tasks.capacity * @sizeOf(Task) +
            m.values.capacity * @sizeOf(Value);
    }

    fn coroOwnedBytes(eng: *anyopaque) usize {
        const m: *const Machine = @ptrCast(@alignCast(eng));
        return m.ownedBytes();
    }

    pub fn shrink(m: *Machine) void {
        const gpa = m.rt.gpa;
        m.tasks.shrinkAndFree(gpa, m.tasks.items.len);
        m.values.shrinkAndFree(gpa, m.values.items.len);
    }

    fn coroShrink(eng: *anyopaque) void {
        const m: *Machine = @ptrCast(@alignCast(eng));
        m.shrink();
    }

    fn coroDestroy(eng: *anyopaque) void {
        const m: *Machine = @ptrCast(@alignCast(eng));
        const gpa = m.rt.gpa;
        m.deinit();
        gpa.destroy(m);
    }

    const coro_vtable: heap.CoroutineVTable = .{
        .trace = coroTrace,
        .ownedBytes = coroOwnedBytes,
        .shrink = coroShrink,
        .destroy = coroDestroy,
        .@"resume" = &coroResume,
    };

    fn stepBindPattern(m: *Machine, pat: *const ast.Pattern, val: Value, mode: BindMode) Error!void {
        const rt = m.rt;
        switch (pat.data) {
            .binding => |d| m.store(d.binding, val),
            .target => |t| switch (t) {
                .ref => |ref| {
                    if (m.bindingOf(ref) != null) {
                        try m.write(ref, val);
                    } else if (builtins.isBuiltinGlobal(ref.name)) {
                        return rt.fail(.builtin);
                    } else {
                        return rt.throw(.ReferenceError, &.{ .{ .ascii = ref.name }, .{ .ascii = " is not defined" } });
                    }
                },
                .member => |mem| {
                    try m.pushVal(val);
                    try m.pushTask(.{ .bind_target_member_base = mem.key });
                    try m.pushEval(mem.object);
                },
            },
            .array => {
                const iter = try builtins.getIterator(rt, val);
                try m.pushVal(.{ .object = iter });
                try m.pushTask(.{ .bind_array_elem = .{ .pat = pat, .idx = 0, .mode = mode } });
            },
            .object => {
                if (val == .undefined or val == .null) {
                    return rt.throw(.TypeError, &.{ .{ .ascii = "Cannot destructure '" }, .{ .ascii = @tagName(val) }, .{ .ascii = "'" } });
                }
                try m.pushVal(val);
                const excl_base: u32 = @intCast(m.values.items.len);
                try m.pushTask(.{ .bind_object_prop = .{
                    .pat = pat,
                    .idx = 0,
                    .mode = mode,
                    .excl_base = excl_base,
                    .excl_count = 0,
                } });
            },
        }
    }

    fn keyToValue(k: object.Key) Value {
        return switch (k) {
            .atom => |a| .{ .string = a },
            .index => |i| .{ .number = @floatFromInt(i) },
        };
    }

    fn valueToKey(v: Value) object.Key {
        return switch (v) {
            .string => |s| .{ .atom = @constCast(s) },
            .number => |n| .{ .index = @intFromFloat(n) },
            else => unreachable,
        };
    }

    fn bindObjectPropWithKey(m: *Machine, bo: ObjectPatTask, k: object.Key) Error!void {
        const rt = m.rt;
        var excl_count = bo.excl_count;
        const key_val = keyToValue(k);
        if (bo.pat.data.object.rest != null) {
            try m.pushVal(key_val);
            excl_count += 1;
        }
        const pr = bo.pat.data.object.props[bo.idx];
        const val = m.values.items[bo.excl_base - 1];
        if (bo.mode == .assign and pr.pattern.data == .target and pr.pattern.data.target == .member) {
            const mem = pr.pattern.data.target.member;
            try m.pushVal(key_val);
            try m.pushTask(.{ .bind_object_prop_pre_member = .{
                .pat = bo.pat,
                .idx = bo.idx,
                .mode = bo.mode,
                .excl_base = bo.excl_base,
                .excl_count = excl_count,
                .mem_key = mem.key,
            } });
            try m.pushEval(mem.object);
            return;
        }
        const v = try object.get(rt, val, k);
        if (pr.default) |def| if (v == .undefined) {
            try m.pushTask(.{ .bind_object_prop_after_default = .{
                .pat = bo.pat,
                .idx = bo.idx,
                .mode = bo.mode,
                .excl_base = bo.excl_base,
                .excl_count = excl_count,
                .has_mv = false,
            } });
            try m.pushEval(def);
            return;
        };
        try m.pushTask(.{ .bind_object_prop = .{
            .pat = bo.pat,
            .idx = bo.idx + 1,
            .mode = bo.mode,
            .excl_base = bo.excl_base,
            .excl_count = excl_count,
        } });
        try m.pushTask(.{ .bind_pattern = .{ .pat = pr.pattern, .mode = bo.mode } });
        try m.pushVal(v);
    }

    fn copyExcludedDataProperties(m: *Machine, dst: *heap.Object, src: Value, excl_base: usize, excl_count: usize) Error!void {
        const rt = m.rt;
        const excluded = try rt.gpa.alloc(object.Key, excl_count);
        defer rt.gpa.free(excluded);
        for (m.values.items[excl_base .. excl_base + excl_count], 0..) |ev, i| {
            excluded[i] = switch (ev) {
                .string => |s| .{ .atom = @constCast(s) },
                .number => |n| .{ .index = @intFromFloat(n) },
                else => unreachable,
            };
        }
        try copyDataProperties(rt, dst, src, excluded);
    }

    fn toKey(m: *Machine, kv: KeyValue) Error!object.Key {
        return switch (kv) {
            .named => |n| object.named(m.rt, n),
            .value => |v| object.key(m.rt, v),
        };
    }

    fn literalKey(m: *Machine, k: ast.PropertyKey) Error!object.Key {
        return switch (k) {
            .name => |n| object.named(m.rt, n),
            .string => |units| object.keyUnits(m.rt, units),
            .number => |n| object.key(m.rt, .{ .number = n }),
            .computed => unreachable,
        };
    }
};

fn logicalAssignShouldWrite(op: ast.AssignOp, old: Value) bool {
    return switch (op) {
        .logical_and => ops.toBoolean(old),
        .logical_or => !ops.toBoolean(old),
        .nullish => old == .null or old == .undefined,
        .plain, .compound => unreachable,
    };
}

fn keyEq(a: object.Key, b: object.Key) bool {
    return switch (a) {
        .index => |ia| b == .index and b.index == ia,
        .atom => |aa| b == .atom and b.atom == aa,
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
        .object => |o| {
            const keys = try object.ownKeys(rt, o);
            defer rt.gpa.free(keys);
            for (keys) |k| {
                if (keyIn(k, excluded)) continue;
                const v = try object.get(rt, src, k);
                try object.define(rt, dst, k, v);
            }
        },
        .closure => |c| {
            const keys = try object.ownKeysClosure(rt, c);
            defer rt.gpa.free(keys);
            for (keys) |k| {
                if (keyIn(k, excluded)) continue;
                const v = try object.get(rt, src, k);
                try object.define(rt, dst, k, v);
            }
        },
        .undefined, .null, .boolean, .number, .native => {},
    }
}

test "native stack use at depth 10 and max_interpreter_depth differs by less than 16 KiB" {
    const parse = @import("../frontend/parser.zig").parse;
    const resolve = @import("../frontend/resolver.zig").resolve;
    const Diagnostic = @import("../frontend/diag.zig").Diagnostic;
    const Limits = @import("../limits.zig").Limits;
    const gpa = std.testing.allocator;

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("function f(n) { return ");
    for (0..200) |_| try w.writeByte('(');
    try w.writeAll("-f(n + 1)");
    for (0..200) |_| try w.writeByte(')');
    try w.writeAll("; } f(0);");

    for ([_][]const u8{ "function g(n) { return g(n + 1); } g(0);", w.buffered() }) |source| {
        var uses: [2]StackUse = undefined;
        for ([_]u32{ 10, (Limits{}).max_interpreter_depth }, 0..) |depth_lim, idx| {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            var d: Diagnostic = .{};
            const limits: Limits = .{ .max_call_depth = 1 << 30, .max_interpreter_depth = depth_lim };
            const script = try parse(arena.allocator(), source, limits, &d);
            const res = try resolve(arena.allocator(), script, &d);
            var discard: std.Io.Writer.Discarding = .init(&.{});
            var rt = Runtime.init(gpa, limits, &discard.writer);
            defer rt.deinit();
            uses[idx] = .{};
            try std.testing.expectError(error.LimitExceeded, runMeasured(&rt, script, res, &uses[idx]));
            try std.testing.expectEqual(@import("../limits.zig").Limit.interpreter_depth, rt.limitHit().?);
            try std.testing.expectEqual(depth_lim, uses[idx].depth);
        }
        const diff = if (uses[1].bytes > uses[0].bytes) uses[1].bytes - uses[0].bytes else uses[0].bytes - uses[1].bytes;
        std.testing.expect(diff < 16 * 1024) catch |e| {
            std.debug.print("native stack grew by {d} bytes from depth 10 ({d}) to max ({d})\n", .{ diff, uses[0].bytes, uses[1].bytes });
            return e;
        };
    }
}
