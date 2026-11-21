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
const bigint = @import("../runtime/bigint.zig");
const coroutine = @import("../runtime/coroutine.zig");
const module = @import("../runtime/module.zig");

/// Helper for `++` / `--` supporting both Number and BigInt.
fn stepNumeric(rt: *Runtime, old_in: Value, is_inc: bool) Error!struct { old: Value, new: Value } {
    const old = try ops.toNumeric(rt, old_in);
    const new: Value = if (old.isBigInt())
        Value.fromBigInt(try bigint.addI64(rt, old.asBigInt(), if (is_inc) 1 else -1))
    else
        Value.fromNumber(if (is_inc) old.asNumber() + 1 else old.asNumber() - 1);
    return .{ .old = old, .new = new };
}

/// Runs a resolved script. On error.Thrown, `rt.exception` or `rt.thrown_value`
/// describes the exception.
pub fn run(rt: *Runtime, script: ast.Script, res: Resolution) Error!void {
    return runMeasured(rt, script, res, null);
}

/// Runs a resolved ES Module body without draining microtasks (D72, D78).
pub fn runModuleBody(rt: *Runtime, script: ast.Script, res: *const Resolution, module_cells: []*heap.Cell, module_record: ?*anyopaque) Error!void {
    return runModuleImpl(rt, script, res, module_cells, module_record, false);
}

/// Runs a resolved ES Module with pre-linked cells (D72).
pub fn runModule(rt: *Runtime, script: ast.Script, res: *const Resolution, module_cells: []*heap.Cell, module_record: ?*anyopaque) Error!void {
    return runModuleImpl(rt, script, res, module_cells, module_record, true);
}

fn runModuleImpl(rt: *Runtime, script: ast.Script, res: *const Resolution, module_cells: []*heap.Cell, module_record: ?*anyopaque, drain: bool) Error!void {
    var m: Machine = .{
        .rt = rt,
        .res = res.*,
        .res_ptr = res,
        .repl_cells = module_cells,
        .module_record = module_record,
        .is_module = true,
        .this = .undefined,
        .stack_top = if (builtin.is_test) @frameAddress() else 0,
        .lowest_frame = if (builtin.is_test) @frameAddress() else 0,
    };
    defer m.deinit();
    const prev_roots = rt.engine_roots;
    const is_nested = prev_roots != null;
    if (is_nested) {
        try rt.addRoots(m.roots());
    } else {
        rt.engine_roots = m.roots();
    }
    defer if (is_nested) rt.removeRoots(&m) else {
        rt.engine_roots = prev_roots;
    };
    const prev_caller = rt.closure_caller;
    rt.closure_caller = .{ .ctx = &m, .call = Machine.callFromBuiltin, .construct = Machine.constructFromBuiltin };
    defer rt.closure_caller = prev_caller;

    try m.pushBlock(script.statements);
    _ = try m.runLoop(0);
    if (drain) try rt.drainMicrotasks();
}

/// Runs a resolved script in REPL mode with persistent bindings and completion value.
pub fn runRepl(rt: *Runtime, script: ast.Script, res: *const Resolution, repl_cells: []*heap.Cell) Error!void {
    var m: Machine = .{
        .rt = rt,
        .res = res.*,
        .res_ptr = res,
        .repl_cells = repl_cells,
        .repl_mode = true,
        .repl_top_stmts = script.statements,
        .stack_top = if (builtin.is_test) @frameAddress() else 0,
        .lowest_frame = if (builtin.is_test) @frameAddress() else 0,
    };
    defer m.deinit();
    const prev_roots = rt.engine_roots;
    const is_nested = prev_roots != null;
    if (is_nested) {
        try rt.addRoots(m.roots());
    } else {
        rt.engine_roots = m.roots();
    }
    defer if (is_nested) rt.removeRoots(&m) else {
        rt.engine_roots = prev_roots;
    };
    const prev_caller = rt.closure_caller;
    rt.closure_caller = .{ .ctx = &m, .call = Machine.callFromBuiltin, .construct = Machine.constructFromBuiltin };
    defer rt.closure_caller = prev_caller;

    try m.pushBlock(script.statements);
    _ = try m.runLoop(0);
    try rt.drainMicrotasks();
}

/// Starts a top-level-await REPL script as an async coroutine on the tree-walker.
pub fn runReplTopLevelAsync(rt: *Runtime, script: ast.Script, res: *const Resolution, repl_cells: []*heap.Cell) Error!Value {
    return runTopLevelAsyncImpl(rt, script, res, repl_cells, false, null);
}

/// Starts a top-level-await ES Module as an async coroutine on the tree-walker (D78).
pub fn runModuleTopLevelAsync(rt: *Runtime, script: ast.Script, res: *const Resolution, module_cells: []*heap.Cell, module_record: ?*anyopaque) Error!Value {
    return runTopLevelAsyncImpl(rt, script, res, module_cells, true, module_record);
}

fn runTopLevelAsyncImpl(rt: *Runtime, script: ast.Script, res: *const Resolution, cells: []*heap.Cell, is_module: bool, module_record: ?*anyopaque) Error!Value {
    const TopLevelAsyncCtx = struct {
        rt: *Runtime,
        script: ast.Script,
        res: *const Resolution,
        cells: []*heap.Cell,
        is_module: bool,
        module_record: ?*anyopaque,
    };
    const create_and_run = struct {
        fn call(ctx: TopLevelAsyncCtx, co: *heap.Coroutine) Error!coroutine.Outcome {
            const m_ptr = try ctx.rt.gpa.create(Machine);
            m_ptr.* = .{
                .rt = ctx.rt,
                .res = ctx.res.*,
                .res_ptr = ctx.res,
                .repl_cells = ctx.cells,
                .module_record = ctx.module_record,
                .repl_mode = !ctx.is_module,
                .is_module = ctx.is_module,
                .this = if (ctx.is_module) .undefined else null,
                .repl_top_stmts = if (ctx.is_module) null else ctx.script.statements,
                .is_coroutine = true,
                .stack_top = if (builtin.is_test) @frameAddress() else 0,
                .lowest_frame = if (builtin.is_test) @frameAddress() else 0,
            };
            errdefer {
                if (co.engine == null) {
                    m_ptr.deinit();
                    ctx.rt.gpa.destroy(m_ptr);
                }
            }
            try m_ptr.pushVal(.undefined);
            try m_ptr.pushBlock(ctx.script.statements);
            co.engine = m_ptr;
            co.state = .running;
            return Machine.runCoroMachine(m_ptr, 0, 0, .start);
        }
    }.call;
    return coroutine.start(rt, &Machine.coro_vtable, TopLevelAsyncCtx{
        .rt = rt,
        .script = script,
        .res = res,
        .cells = cells,
        .is_module = is_module,
        .module_record = module_record,
    }, create_and_run);
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
    const is_nested = prev_roots != null;
    if (is_nested) {
        try rt.addRoots(m.roots());
    } else {
        rt.engine_roots = m.roots();
    }
    defer if (is_nested) rt.removeRoots(&m) else {
        rt.engine_roots = prev_roots;
    };
    const prev_caller = rt.closure_caller;
    rt.closure_caller = .{ .ctx = &m, .call = Machine.callFromBuiltin, .construct = Machine.constructFromBuiltin };
    defer rt.closure_caller = prev_caller;

    try m.pushBlock(script.statements);
    _ = try m.runLoop(0);
    try rt.drainMicrotasks();
}

const UnwindKind = union(enum) {
    @"break": ?[]const u8,
    @"continue": ?[]const u8,
    @"return",
    throw,
};

const FinallyPending = union(enum) {
    normal,
    @"break": ?[]const u8,
    @"continue": ?[]const u8,
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
const ForAwaitTask = struct { stmt: *const ast.Stmt, iter: *heap.Object, has_scope: bool, values_base: u32 };

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
    /// Pops top of `m.values` into `rt.repl_result` (or coroutine return slot).
    save_repl_result,

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
    for_in_start: struct { stmt: *const ast.Stmt, has_scope: bool, values_base: u32 },
    for_in_iter: struct { stmt: *const ast.Stmt, iter: *heap.Object, has_scope: bool, values_base: u32 },
    labeled: struct { label: []const u8, values_base: u32 },
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
    assign_member_base: struct { op: ast.AssignOp, key: ast.PropertyKey, value: *const ast.Expr, is_private: bool = false },
    assign_member_after_key: struct { op: ast.AssignOp, value: *const ast.Expr, named: ?[]const u8, is_private: bool = false },
    assign_member_plain_finish: struct { named: ?[]const u8, is_private: bool = false },
    assign_member_plain_finish_key: object.Key,
    assign_member_compound_finish: struct { op: ast.BinaryOp, key: object.Key, priv_name: ?[]const u8 = null },
    assign_pattern_keep: *const ast.Pattern,
    update_member_base: struct { op: UpdateOp, prefix: bool, key: ast.PropertyKey, is_private: bool = false },
    update_member_finish: struct { op: UpdateOp, prefix: bool, named: ?[]const u8, is_private: bool = false },
    member_base: struct { key: ast.PropertyKey, is_delete: bool, is_private: bool = false },
    member_finish: struct { named: ?[]const u8, is_delete: bool, is_private: bool = false },
    private_in_finish: []const u8,
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
    call_member_base: struct { key: ast.PropertyKey, args: []const *const ast.Expr, tagged: ?*const ast.Expr.TaggedTemplate = null, is_private: bool = false },
    call_member_key: struct { named: ?[]const u8, args: []const *const ast.Expr, tagged: ?*const ast.Expr.TaggedTemplate = null, is_private: bool = false },
    call_after_callee: struct { args: []const *const ast.Expr, has_receiver: bool, tagged: ?*const ast.Expr.TaggedTemplate = null },
    new_call_after_callee: []const *const ast.Expr,
    eval_args_next: struct { args: []const *const ast.Expr, idx: usize, args_base: usize },
    eval_args_spread: struct { args: []const *const ast.Expr, idx: usize, args_base: usize },
    invoke_call: struct { has_receiver: bool, args_base: usize },
    invoke_new_call: usize,

    // ---- Calls & barriers
    call_bind_param: struct { func: *const ast.Function, idx: u32, args_base: u32, argc: u32 },
    call_enter_body: struct { func: *const ast.Function, args_base: u32 },
    call_return: struct {
        saved_env: ?*Env,
        saved_this: Value,
        has_this: bool,
        values_base: u32,
        construct_instance: ?*heap.Object = null,
        saved_closure: ?*const heap.Closure = null,
        saved_func: ?*const ast.Function = null,
        saved_construct_instance: ?*heap.Object = null,
        callee_func: ?*const ast.Function = null,
        is_super_call: bool = false,
        saved_res: Resolution = undefined,
        saved_res_ptr: ?*const Resolution = null,
        saved_repl_cells: []*heap.Cell = &.{},
        saved_module_record: ?*anyopaque = null,
    },
    dynamic_import,
    barrier: u32,
    await_suspend,
    /// A generator's suspension after its parameters are bound (D67).
    generator_start,
    /// Suspends the generator yielding the top value; `true`: `yield*`'s raw inner result.
    yield_suspend: bool,
    /// `yield* e` (D67): turns the evaluated `e` into an iterator, then loops
    /// `yield_star_step` → (raw yield, `yield_star_wait`) → resume → `yield_star_step`.
    yield_star_init,
    yield_star_step: struct { iter: *heap.Object, received: Value, mode: coroutine.ResumeMode },
    /// On top while a `yield*` is suspended: the resume feeds its value and mode to the next step.
    yield_star_wait: *heap.Object,
    /// Async `yield*` (D68): like the sync tasks, with an `await` between the inner call
    /// (`async_yield_star_step`) and its result (`async_yield_star_result`).
    async_yield_star_init,
    async_yield_star_step: struct { iter: *heap.Object, received: Value, mode: coroutine.ResumeMode },
    async_yield_star_result: struct { iter: *heap.Object, kind: @FieldType(builtins.AsyncYieldStar, "kind") },
    async_yield_star_wait: *heap.Object,
    /// `for await` (D68): `for_await_iter` calls `next` and awaits; `for_await_after` checks
    /// the result, then binds and runs the body above a new `for_await_iter`, which closes
    /// the iterator on an abrupt exit (awaiting `return()`, then `for_await_close`).
    for_await_iter: ForAwaitTask,
    for_await_after: ForAwaitTask,
    /// After AsyncIteratorClose's await; `true`: the completion is a throw (errors ignored).
    for_await_close: bool,

    // ---- Classes & super (M33, D63)
    class_decl_init: u32,
    export_default_init: struct { default_binding: u32, name_binding: ?u32 },
    class_setup: struct { cls: *const ast.Class, is_expr: bool },
    class_method_next: struct { cls: *const ast.Class, idx: usize },
    class_method_finish: struct { cls: *const ast.Class, idx: usize, named: ?[]const u8 },
    class_inst_field_next: struct { cls: *const ast.Class, idx: usize, key_idx: u32 },
    class_inst_field_finish: struct { cls: *const ast.Class, idx: usize, key_idx: u32, is_named: bool },
    class_static_key_next: struct { cls: *const ast.Class, idx: usize },
    class_static_key_finish: struct { cls: *const ast.Class, idx: usize },
    class_static_item_next: struct { cls: *const ast.Class, idx: usize, keys_base: usize },
    invoke_super_call: usize,
    super_get_elem,
    super_assign_plain: ?[]const u8,
    super_assign_after_key: struct { op: ast.AssignOp, value: *const ast.Expr, named: ?[]const u8 },
    super_assign_compound: struct { op: ast.BinaryOp, named: ?[]const u8 },
    super_assign_logical: struct { op: ast.AssignOp, named: ?[]const u8 },
    super_update_finish: struct { op: UpdateOp, prefix: bool, named: ?[]const u8 },
    super_call_member_key: struct { named: ?[]const u8, args: []const *const ast.Expr, tagged: ?*const ast.Expr.TaggedTemplate = null },
    bind_target_super_finish: ?[]const u8,

    // ---- Patterns
    bind_pattern: struct { pat: *const ast.Pattern, mode: BindMode },
    bind_target_member_base: struct { key: ast.PropertyKey, is_private: bool = false },
    bind_target_member_finish: struct { named: ?[]const u8, is_private: bool = false },
    bind_array_elem: ArrayPatTask,
    bind_array_elem_pre_member: struct { pat: *const ast.Pattern, idx: u32, mode: BindMode, key: ast.PropertyKey },
    bind_array_elem_pre_member_key: struct { pat: *const ast.Pattern, idx: u32, mode: BindMode, named: ?[]const u8 },
    bind_array_elem_after_default: struct { pat: *const ast.Pattern, idx: u32, mode: BindMode, has_mv: bool },
    bind_array_rest_pre_member: struct { rest: *const ast.Pattern, key: ast.PropertyKey },
    bind_array_rest_pre_member_key: ?[]const u8,
    array_iter_close: struct { iter: *heap.Object, values_base: u32 },
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
    res_ptr: ?*const Resolution = null,
    repl_cells: []*heap.Cell = &.{},
    module_record: ?*anyopaque = null,
    repl_mode: bool = false,
    is_module: bool = false,
    repl_top_stmts: ?[]const ast.Stmt = null,
    env: ?*Env = null,
    depth: u32 = 0,
    calls: u32 = 0,
    ret: Value = .undefined,
    this: ?Value = null,
    current_closure: ?*const heap.Closure = null,
    current_func: ?*const ast.Function = null,
    construct_instance: ?*heap.Object = null,
    is_coroutine: bool = false,
    /// Suspended at `generator_start`: the first resume pushes nothing.
    at_start: bool = false,
    /// The current suspension is a yield; otherwise an `await` (async generators, D68).
    yielding: bool = false,
    yield_raw: bool = false,
    awaited: Value = .undefined,
    tasks: std.ArrayList(Task) = .empty,
    values: std.ArrayList(Value) = .empty,
    stack_top: usize = 0,
    lowest_frame: usize = 0,
    max_depth: u32 = 0,

    fn deinit(m: *Machine) void {
        if (m.rt.engine_roots) |e| if (e.ctx == @as(*anyopaque, m)) {
            m.rt.engine_roots = null;
            m.rt.template_cache.clearRetainingCapacity();
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
        if (m.current_closure) |c| visit(ctx, @constCast(&c.obj));
        if (m.construct_instance) |ci| visit(ctx, &ci.obj);
        for (m.repl_cells) |cell| visit(ctx, &cell.obj);
        heap.visitValue(m.ret, ctx, visit);
        heap.visitValue(m.awaited, ctx, visit);
        for (m.tasks.items) |t| switch (t) {
            .scope_exit, .scope_exit_depth => |e| if (e) |rec| visit(ctx, &rec.obj),
            .for_of_iter => |f| visit(ctx, &f.iter.obj),
            .for_in_iter => |f| visit(ctx, &f.iter.obj),
            .yield_star_step => |ys| {
                visit(ctx, &ys.iter.obj);
                heap.visitValue(ys.received, ctx, visit);
            },
            .yield_star_wait => |it| visit(ctx, &it.obj),
            .async_yield_star_step => |ys| {
                visit(ctx, &ys.iter.obj);
                heap.visitValue(ys.received, ctx, visit);
            },
            .async_yield_star_result => |r| visit(ctx, &r.iter.obj),
            .async_yield_star_wait => |it| visit(ctx, &it.obj),
            .for_await_iter, .for_await_after => |f| visit(ctx, &f.iter.obj),
            .array_iter_close => |ac| visit(ctx, &ac.iter.obj),
            .try_catch => |tc| if (tc.saved_env) |e| visit(ctx, &e.obj),
            .try_finally => |tf| if (tf.saved_env) |e| visit(ctx, &e.obj),
            .finally_resume => |p| switch (p) {
                .@"return" => |v| heap.visitValue(v, ctx, visit),
                .throw => |v| heap.visitValue(v, ctx, visit),
                else => {},
            },
            .assign_member_plain_finish_key => |k| visitKey(k, ctx, visit),
            .assign_member_compound_finish => |c| if (c.priv_name == null) visitKey(c.key, ctx, visit),
            .object_prop_val => |o| visitKey(o.key, ctx, visit),
            .call_return => |cr| {
                if (cr.saved_env) |e| visit(ctx, &e.obj);
                if (cr.has_this) heap.visitValue(cr.saved_this, ctx, visit);
                if (cr.construct_instance) |inst| visit(ctx, &inst.obj);
                if (cr.saved_closure) |sc| visit(ctx, @constCast(&sc.obj));
                if (cr.saved_construct_instance) |sci| visit(ctx, &sci.obj);
            },
            else => {},
        };
    }

    fn visitKey(k: object.Key, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *heap.Obj) void) void {
        switch (k) {
            .atom => |a| visit(ctx, @constCast(&a.obj)),
            .symbol => |s| visit(ctx, @constCast(&s.obj)),
            .index => {},
        }
    }

    fn pushTask(m: *Machine, t: Task) Error!void {
        try m.tasks.append(m.rt.gpa, t);
    }

    /// Awaits `v` from a task (D68): an `await` whose operand is already evaluated.
    fn pushAwait(m: *Machine, v: Value) Error!void {
        try m.enter();
        try m.pushTask(.await_suspend);
        try m.pushVal(v);
    }

    fn inAsyncGenerator(m: *const Machine) bool {
        const f = m.current_func orelse return false;
        return f.is_async and f.is_generator;
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
        if (m.res.bindings[b].repl_index) |ri| return m.repl_cells[ri].value;
        return m.envOf(b).values[m.res.bindings[b].index];
    }

    fn store(m: *Machine, b: u32, v: Value) void {
        if (m.res.bindings[b].repl_index) |ri| {
            m.rt.heap.storeCell(m.repl_cells[ri], v);
            return;
        }
        m.rt.heap.storeEnv(m.envOf(b), m.res.bindings[b].index, v);
    }

    fn pushScope(m: *Machine, scope: ?u32) Error!bool {
        const s = scope orelse return false;
        m.env = try m.rt.heap.newEnv(m.env, s, m.res.scopes[s].len);
        return true;
    }

    fn patternScope(m: *const Machine, pat: *const ast.Pattern) ?u32 {
        switch (pat.data) {
            .binding => |d| return if (m.res.bindings[d.binding].repl_index != null) null else m.res.bindings[d.binding].scope,
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
            .function => |f| if (m.res.bindings[f.name.?.binding].repl_index == null) return m.res.bindings[f.name.?.binding].scope,
            .class => |c| if (m.res.bindings[c.name.?.binding].repl_index == null) return m.res.bindings[c.name.?.binding].scope,
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

    fn makeTreeClosure(m: *Machine, f: *const ast.Function, env: ?*Env) Error!*heap.Closure {
        const cl = try m.rt.heap.newTreeClosure(f, env);
        cl.impl.tree.res = if (m.res_ptr) |rp| @ptrCast(rp) else null;
        cl.impl.tree.repl_cells = m.repl_cells;
        cl.impl.tree.module_record = m.module_record;
        if (m.current_closure) |pc| {
            if (pc.meta) |pm| {
                if (pm.brand) |br| {
                    var root_buf = [_]Value{Value.fromClosure(cl)};
                    var val_roots: rt_mod.ValueRoots = .{ .values = &root_buf };
                    try val_roots.register(m.rt);
                    defer val_roots.unregister(m.rt);
                    try m.rt.heap.storeClosureBrand(cl, br);
                }
            }
        }
        return cl;
    }

    fn pushBody(m: *Machine, stmts: []const ast.Stmt) Error!void {
        if (!(m.is_module and m.current_func == null)) {
            for (stmts) |s| if (s.data == .function) {
                const f = s.data.function;
                m.store(f.name.?.binding, Value.fromClosure(try m.makeTreeClosure(f, m.env)));
            };
        }
        if (stmts.len > 0) {
            try m.pushTask(.{ .stmt_list = .{ .stmts = stmts, .idx = 0 } });
        }
    }

    fn bindingOf(m: *const Machine, ref: ast.Ref) ?u32 {
        return switch (m.res.refs[ref.id]) {
            .local => |b| b,
            .capture => |c| c.binding,
            .global, .repl => null,
        };
    }

    fn read(m: *Machine, ref: ast.Ref) Error!Value {
        if (m.res.refs[ref.id] == .repl) {
            const ri = m.res.refs[ref.id].repl;
            return m.repl_cells[ri].value orelse m.tdz(ref);
        }
        const b = m.bindingOf(ref) orelse return builtins.global(m.rt, ref.name);
        return m.load(b) orelse m.tdz(ref);
    }

    fn write(m: *Machine, ref: ast.Ref, v: Value) Error!void {
        if (m.res.refs[ref.id] == .repl) {
            const ri = m.res.refs[ref.id].repl;
            if (m.repl_cells[ri].value == null) return m.tdz(ref);
            if (m.res.repl_bindings[ri].kind == .@"const")
                return m.rt.throw(.TypeError, &.{.{ .ascii = "Assignment to constant variable." }});
            m.rt.heap.storeCell(m.repl_cells[ri], v);
            return;
        }
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
                .generator_start => {
                    m.awaited = .undefined;
                    m.yield_raw = false;
                    m.at_start = true;
                    m.yielding = true;
                    return true;
                },
                .yield_suspend => |raw| {
                    m.awaited = m.popVal();
                    m.yield_raw = raw;
                    m.yielding = true;
                    if (!raw) m.depth -= 1; // a raw yield's depth belongs to its `yield*`
                    return true;
                },
                else => {},
            }
            const maybe_unwind = m.stepTask(task) catch |err| switch (err) {
                error.Thrown => UnwindKind.throw,
                else => return err,
            };
            if (maybe_unwind) |kind| {
                m.unwind(kind, stop_len) catch |uerr| switch (uerr) {
                    error.Thrown => {
                        m.ret = .undefined;
                        try m.unwind(.throw, stop_len);
                    },
                    else => return uerr,
                };
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
                .yield_suspend, // only the non-raw form is ever below an evaluation
                .yield_star_init,
                .yield_star_step,
                .yield_star_wait,
                .await_suspend, // holds the `await` expression's depth while its operand runs
                .async_yield_star_init,
                .async_yield_star_step,
                .async_yield_star_result,
                .async_yield_star_wait,
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
                    const cur_this = m.this;
                    m.env = cr.saved_env;
                    m.this = if (cr.has_this) cr.saved_this else null;
                    m.current_closure = cr.saved_closure;
                    m.current_func = cr.saved_func;
                    m.construct_instance = cr.saved_construct_instance;
                    m.res = cr.saved_res;
                    m.res_ptr = cr.saved_res_ptr;
                    m.repl_cells = cr.saved_repl_cells;
                    m.module_record = cr.saved_module_record;
                    m.calls -= 1;
                    m.depth -= 1;
                    m.values.shrinkRetainingCapacity(cr.values_base);
                    if (kind == .@"return") {
                        const rv = m.ret;
                        m.ret = .undefined;
                        const out_v: Value = if (cr.construct_instance == null)
                            rv
                        else if (cr.callee_func != null and cr.callee_func.?.has_super_ctor) blk: {
                            if (rv.isObjectLike()) break :blk rv;
                            if (rv.isUndefined()) {
                                break :blk cur_this orelse return m.rt.throw(.ReferenceError, &.{.{ .ascii = "Must call super constructor in derived class before accessing 'this' or returning from derived constructor" }});
                            }
                            return m.rt.throw(.TypeError, &.{.{ .ascii = "Derived constructors may only return object or undefined" }});
                        } else if (rv.isObjectLike())
                            rv
                        else
                            Value.fromObject(cr.construct_instance.?);
                        if (cr.is_super_call) {
                            m.this = out_v;
                            if (m.current_closure) |dc| try builtins.runInstanceInits(m.rt, @constCast(dc), out_v);
                        }
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
                        .@"break" => |lbl| .{ .@"break" = lbl },
                        .@"continue" => |lbl| .{ .@"continue" = lbl },
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
                .labeled => |lb| {
                    if (kind == .@"break") {
                        if (kind.@"break") |lbl| {
                            if (std.mem.eql(u8, lb.label, lbl)) {
                                _ = m.tasks.pop();
                                m.values.shrinkRetainingCapacity(lb.values_base);
                                return;
                            }
                        }
                    }
                    _ = m.tasks.pop();
                },
                .while_iter => |w| {
                    if (kind == .@"continue" and loopMatchesLabel(m.tasks.items, m.tasks.items.len - 1, kind.@"continue")) {
                        m.values.shrinkRetainingCapacity(w.values_base);
                        return;
                    }
                    if (kind == .@"break" and kind.@"break" == null) {
                        _ = m.tasks.pop();
                        m.values.shrinkRetainingCapacity(w.values_base);
                        return;
                    }
                    _ = m.tasks.pop();
                },
                .do_while_cond => |dw| {
                    if (kind == .@"continue" and loopMatchesLabel(m.tasks.items, m.tasks.items.len - 1, kind.@"continue")) {
                        m.values.shrinkRetainingCapacity(dw.values_base);
                        return;
                    }
                    if (kind == .@"break" and kind.@"break" == null) {
                        _ = m.tasks.pop();
                        m.values.shrinkRetainingCapacity(dw.values_base);
                        return;
                    }
                    _ = m.tasks.pop();
                },
                .for_update => |f| {
                    if (kind == .@"continue" and loopMatchesLabel(m.tasks.items, m.tasks.items.len - 1, kind.@"continue")) {
                        m.values.shrinkRetainingCapacity(f.values_base);
                        return;
                    }
                    if (kind == .@"break" and kind.@"break" == null) {
                        _ = m.tasks.pop();
                        m.values.shrinkRetainingCapacity(f.values_base);
                        return;
                    }
                    _ = m.tasks.pop();
                },
                .for_in_iter => |f| {
                    if (kind == .@"continue" and loopMatchesLabel(m.tasks.items, m.tasks.items.len - 1, kind.@"continue")) {
                        m.values.shrinkRetainingCapacity(f.values_base);
                        return;
                    }
                    if (kind == .@"break" and kind.@"break" == null) {
                        _ = m.tasks.pop();
                        m.values.shrinkRetainingCapacity(f.values_base);
                        return;
                    }
                    _ = m.tasks.pop();
                    m.values.shrinkRetainingCapacity(f.values_base);
                },
                .for_of_iter => |f| {
                    if (kind == .@"continue" and loopMatchesLabel(m.tasks.items, m.tasks.items.len - 1, kind.@"continue")) {
                        m.values.shrinkRetainingCapacity(f.values_base);
                        return;
                    }
                    if (kind == .@"break" and kind.@"break" == null) {
                        _ = m.tasks.pop();
                        m.values.shrinkRetainingCapacity(f.values_base);
                        try builtins.iteratorClose(m.rt, f.iter, false);
                        return;
                    }
                    _ = m.tasks.pop();
                    m.values.shrinkRetainingCapacity(f.values_base);
                    try builtins.iteratorClose(m.rt, f.iter, kind == .throw);
                },
                .array_iter_close => |ac| {
                    _ = m.tasks.pop();
                    m.values.shrinkRetainingCapacity(ac.values_base);
                    try builtins.iteratorClose(m.rt, ac.iter, kind == .throw);
                },
                .for_await_iter => |f| {
                    if (kind == .@"continue" and loopMatchesLabel(m.tasks.items, m.tasks.items.len - 1, kind.@"continue")) {
                        m.values.shrinkRetainingCapacity(f.values_base);
                        return;
                    }
                    _ = m.tasks.pop();
                    m.values.shrinkRetainingCapacity(f.values_base);
                    // AsyncIteratorClose (D68): park the completion like `finally` does, await
                    // `return()`'s result, then resume the completion.
                    const pending: FinallyPending = switch (kind) {
                        .@"break" => |lbl| if (lbl == null) .normal else .{ .@"break" = lbl },
                        .@"continue" => |lbl| .{ .@"continue" = lbl },
                        .@"return" => blk: {
                            const rv = m.ret;
                            m.ret = .undefined;
                            break :blk .{ .@"return" = rv };
                        },
                        .throw => .{ .throw = try m.rt.catchValue() },
                    };
                    try m.pushTask(.{ .finally_resume = pending });
                    const res = try builtins.asyncIterCloseStart(m.rt, f.iter, kind == .throw);
                    if (res) |r| {
                        try m.pushTask(.{ .for_await_close = kind == .throw });
                        try m.pushAwait(r);
                    }
                    return;
                },
                .for_await_after => |f| {
                    _ = m.tasks.pop(); // an awaited `next()` failed: no close
                    m.values.shrinkRetainingCapacity(f.values_base);
                },
                .for_await_close => |is_throw| {
                    _ = m.tasks.pop();
                    if (is_throw) { // a rejected `return()` loses to the original throw
                        m.rt.clearThrown();
                        return;
                    }
                },
                .switch_exec => |sw| {
                    if (kind == .@"break" and kind.@"break" == null) {
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

    fn loopMatchesLabel(tasks: []const Task, loop_idx: usize, maybe_lbl: ?[]const u8) bool {
        const lbl = maybe_lbl orelse return true;
        var i = loop_idx;
        while (i > 0) {
            i -= 1;
            switch (tasks[i]) {
                .labeled => |lb| if (std.mem.eql(u8, lb.label, lbl)) return true,
                .depth_pop, .scope_exit => {},
                else => return false,
            }
        }
        return false;
    }

    inline fn pushEval(m: *Machine, e: *const ast.Expr) Error!void {
        switch (e.data) {
            .number => |n| {
                try m.enter();
                m.safepoint();
                try m.rt.step();
                m.depth -= 1;
                try m.pushVal(Value.fromNumber(n));
            },
            .bigint => |raw| {
                try m.enter();
                m.safepoint();
                try m.rt.step();
                m.depth -= 1;
                try m.pushVal(Value.fromBigInt(try bigint.parse(m.rt, raw, true)));
            },
            .boolean => |b| {
                try m.enter();
                m.safepoint();
                try m.rt.step();
                m.depth -= 1;
                try m.pushVal(Value.fromBool(b));
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
                try m.pushVal(try m.requireThis());
            },
            .update => |u| switch (u.target) {
                .ref => |ref| {
                    try m.enter();
                    m.safepoint();
                    try m.rt.step();
                    const s = try stepNumeric(m.rt, try m.read(ref), u.op == .inc);
                    try m.write(ref, s.new);
                    m.depth -= 1;
                    try m.pushVal(if (u.prefix) s.new else s.old);
                },
                .member, .super_member => try m.pushTask(.{ .eval = e }),
            },
            else => try m.pushTask(.{ .eval = e }),
        }
    }

    fn stepTask(m: *Machine, task: Task) Error!?UnwindKind {
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
            .dynamic_import => {
                const spec_val = m.popVal();
                const mod_ptr: ?*module.ModuleRecord = if (m.module_record) |mp| @ptrCast(@alignCast(mp)) else null;
                const promise_obj = try module.dynamicImport(rt, mod_ptr, spec_val, .treewalk);
                m.depth -= 1;
                try m.pushVal(Value.fromObject(promise_obj));
            },
            .barrier, .await_suspend, .generator_start, .yield_suspend => unreachable, // handled in runLoop
            .yield_star_wait, .async_yield_star_wait => unreachable, // consumed by the resume
            .async_yield_star_init => {
                const iter = try builtins.getAsyncIterator(rt, m.popVal());
                try m.pushTask(.{ .async_yield_star_step = .{ .iter = iter, .received = .undefined, .mode = .next } });
            },
            .async_yield_star_step => |ys| {
                m.depth -= 1; // re-counted below by the result task
                const r = try builtins.asyncYieldStarCall(rt, ys.iter, ys.received, ys.mode);
                m.depth += 1;
                try m.pushTask(.{ .async_yield_star_result = .{ .iter = ys.iter, .kind = r.kind } });
                try m.pushAwait(r.value);
            },
            .async_yield_star_result => |ar| {
                m.depth -= 1; // re-counted below while the `yield*` stays suspended
                var root_buf = [_]Value{ Value.fromObject(ar.iter), m.popVal() }; // getters may collect
                var vroots: rt_mod.ValueRoots = .{ .values = &root_buf };
                try vroots.register(rt);
                defer vroots.unregister(rt);
                const r = try builtins.asyncYieldStarResult(rt, ar.kind, root_buf[1]);
                switch (r.kind) {
                    .yield => {
                        m.depth += 1;
                        try m.pushTask(.{ .async_yield_star_wait = ar.iter });
                        try m.pushTask(.{ .yield_suspend = true }); // its depth stays with the wait
                        try m.pushVal(r.value);
                    },
                    .done => try m.pushVal(r.value),
                    .@"return" => {
                        m.ret = r.value;
                        return .@"return";
                    },
                }
            },
            .for_await_iter => |f| {
                try rt.step();
                try m.pushTask(.{ .for_await_after = f }); // roots the record during `next()`
                try m.pushAwait(try builtins.asyncIterNext(rt, f.iter));
            },
            .for_await_after => |f| {
                const fo = f.stmt.data.for_of;
                var root_buf = [_]Value{ Value.fromObject(f.iter), m.popVal() }; // getters may collect
                var vroots: rt_mod.ValueRoots = .{ .values = &root_buf };
                try vroots.register(rt);
                defer vroots.unregister(rt);
                const next_val = (try builtins.asyncIterValue(rt, root_buf[1])) orelse return null;
                try m.pushTask(.{ .for_await_iter = f });
                switch (fo.target) {
                    .declaration => |decl| {
                        if (f.has_scope) try m.copyScope();
                        try m.pushTask(.{ .exec = fo.body });
                        try m.pushTask(.{ .bind_pattern = .{ .pat = decl.pattern, .mode = .init } });
                    },
                    .target => |t| {
                        try m.pushTask(.{ .exec = fo.body });
                        try m.pushTask(.{ .bind_pattern = .{ .pat = t, .mode = .assign } });
                    },
                }
                try m.pushVal(next_val);
            },
            .for_await_close => |is_throw| {
                const v = m.popVal();
                if (!is_throw) try builtins.asyncIterCloseCheck(rt, v);
            },
            .yield_star_init => {
                const iter = try builtins.getIterator(rt, m.popVal());
                try m.pushTask(.{ .yield_star_step = .{ .iter = iter, .received = .undefined, .mode = .next } });
            },
            .yield_star_step => |ys| {
                m.depth -= 1; // re-counted below while the `yield*` stays suspended
                const r = try builtins.yieldStarStep(rt, ys.iter, ys.received, ys.mode);
                switch (r.kind) {
                    .yield => {
                        m.depth += 1;
                        try m.pushTask(.{ .yield_star_wait = ys.iter });
                        try m.pushTask(.{ .yield_suspend = true });
                        try m.pushVal(r.value);
                    },
                    .done => try m.pushVal(r.value),
                    .@"return" => {
                        m.ret = r.value;
                        return .@"return";
                    },
                }
            },
            .save_repl_result => {
                const v = m.popVal();
                if (m.is_coroutine) {
                    // Replace the initial `.undefined` slot at values[0] with `v`.
                    m.values.shrinkRetainingCapacity(0);
                    try m.pushVal(v);
                } else {
                    m.rt.repl_result = v;
                }
            },
            .exec => |s| return m.execStmt(s),
            .stmt_list => |sl| {
                if (sl.idx + 1 < sl.stmts.len) {
                    try m.pushTask(.{ .stmt_list = .{ .stmts = sl.stmts, .idx = sl.idx + 1 } });
                } else if (m.repl_mode and m.repl_top_stmts != null and sl.stmts.ptr == m.repl_top_stmts.?.ptr and sl.stmts[sl.idx].data == .expression) {
                    try m.pushTask(.save_repl_result);
                    try m.pushTask(.{ .eval = sl.stmts[sl.idx].data.expression });
                    return null;
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
            .switch_scope,
            .switch_test,
            .switch_test_cmp,
            .switch_exec,
            .for_after_init,
            .for_iter,
            .for_cond_check,
            .for_update,
            .for_of_init,
            .for_of_iter,
            .for_in_start,
            .for_in_iter,
            => return m.stepLoopSwitchTask(task),
            .throw_finish => {
                const v = m.popVal();
                return rt.throwValue(v);
            },
            .try_catch => |tc| m.env = tc.saved_env,
            .try_finally => |tf| {
                m.env = tf.saved_env;
                try m.pushTask(.{ .block = tf.finally_body });
            },
            .labeled => {},
            .finally_resume => |pending| switch (pending) {
                .normal => {},
                .@"break" => |lbl| return .{ .@"break" = lbl },
                .@"continue" => |lbl| return .{ .@"continue" = lbl },
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
                var roots_buf = [_]Value{ acc, v };
                var val_roots = rt_mod.ValueRoots{ .values = &roots_buf };
                try val_roots.register(rt);
                defer val_roots.unregister(rt);

                const v_str = try ops.toStringValue(rt, v);
                roots_buf[1] = v_str;
                acc = try ops.binary(rt, .add, acc, v_str);
                roots_buf[0] = acc;
                if (tn.t.quasis[tn.idx + 1].len > 0) {
                    const q: Value = Value.fromString(try rt.heap.newString(&.{.{ .utf16 = tn.t.quasis[tn.idx + 1] }}));
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
                    .neg => blk: {
                        const nv = try ops.toNumeric(rt, v);
                        break :blk if (nv.isBigInt()) Value.fromBigInt(try bigint.neg(rt, nv.asBigInt())) else Value.fromNumber(-nv.asNumber());
                    },
                    .plus => Value.fromNumber(try ops.toNumber(rt, v)),
                    .not => Value.fromBool(!ops.toBoolean(v)),
                    .bit_not => blk: {
                        const nv = try ops.toNumeric(rt, v);
                        break :blk if (nv.isBigInt()) Value.fromBigInt(try bigint.bitNot(rt, nv.asBigInt())) else Value.fromNumber(ops.bitNot(nv.asNumber()));
                    },
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
                    .nullish => if (lhs.isNull() or lhs.isUndefined()) {
                        _ = m.popVal();
                        try m.pushTask(.depth_pop);
                        try m.pushEval(br.rhs);
                    } else {
                        m.depth -= 1;
                    },
                    .comma => {
                        _ = m.popVal();
                        try m.pushTask(.depth_pop);
                        try m.pushEval(br.rhs);
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
            .assign_pattern_keep => |pat| {
                const v = m.values.items[m.values.items.len - 1];
                try m.pushTask(.{ .bind_pattern = .{ .pat = pat, .mode = .assign } });
                try m.pushVal(v);
            },
            .assign_member_base,
            .assign_member_after_key,
            .assign_member_plain_finish,
            .assign_member_plain_finish_key,
            .assign_member_compound_finish,
            .update_member_base,
            .update_member_finish,
            .member_base,
            .member_finish,
            .private_in_finish,
            .opt_after_base,
            .opt_after_member_key,
            .opt_step,
            .opt_elem_finish,
            .opt_call_finish,
            .super_get_elem,
            .super_assign_plain,
            .super_assign_after_key,
            .super_assign_compound,
            .super_assign_logical,
            .super_update_finish,
            .super_call_member_key,
            => try m.stepMemberTask(task),

            .array_next,
            .array_elem_push,
            .array_spread_push,
            .object_next,
            .object_prop_computed_val,
            .object_prop_key,
            .object_prop_val,
            .object_spread_finish,
            => try m.stepLiteralTask(task),

            .call_member_base,
            .call_member_key,
            .call_after_callee,
            .new_call_after_callee,
            .eval_args_next,
            .eval_args_spread,
            .invoke_call,
            .invoke_new_call,
            .invoke_super_call,
            .call_bind_param,
            .call_enter_body,
            .call_return,
            => try m.stepCallTask(task),

            .class_decl_init,
            .export_default_init,
            .class_setup,
            .class_method_next,
            .class_method_finish,
            .class_inst_field_next,
            .class_inst_field_finish,
            .class_static_key_next,
            .class_static_key_finish,
            .class_static_item_next,
            => try m.stepClassTask(task),

            .bind_pattern,
            .bind_target_member_base,
            .bind_target_member_finish,
            .bind_target_super_finish,
            .bind_array_elem,
            .bind_array_elem_pre_member,
            .bind_array_elem_pre_member_key,
            .bind_array_elem_after_default,
            .bind_array_rest_pre_member,
            .bind_array_rest_pre_member_key,
            .array_iter_close,
            .bind_object_prop,
            .bind_object_prop_after_key,
            .bind_object_prop_pre_member,
            .bind_object_prop_pre_member_key,
            .bind_object_prop_after_default,
            .bind_object_rest_pre_member,
            .bind_object_rest_pre_member_key,
            => try m.stepBindTask(task),
        }
        return null;
    }

    noinline fn stepLoopSwitchTask(m: *Machine, task: Task) Error!?UnwindKind {
        const rt = m.rt;
        switch (task) {
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
                if (f.stmt.data.for_of.is_await) {
                    const rec = try builtins.getAsyncIterator(rt, iterable);
                    try m.pushTask(.{ .for_await_iter = .{ .stmt = f.stmt, .iter = rec, .has_scope = f.has_scope, .values_base = f.values_base } });
                    return null;
                }
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
            .for_in_start => |f| {
                const obj = m.popVal();
                const iter = try builtins.forInInit(rt, obj);
                try m.pushTask(.{ .for_in_iter = .{
                    .stmt = f.stmt,
                    .iter = iter,
                    .has_scope = f.has_scope,
                    .values_base = f.values_base,
                } });
            },
            .for_in_iter => |f| {
                try rt.step();
                const fi = f.stmt.data.for_in;
                const next_val = (try builtins.forInNext(rt, f.iter)) orelse return null;
                try m.pushTask(.{ .for_in_iter = f });
                switch (fi.target) {
                    .declaration => |decl| {
                        if (f.has_scope) try m.copyScope();
                        try m.pushTask(.{ .exec = fi.body });
                        try m.pushTask(.{ .bind_pattern = .{ .pat = decl.pattern, .mode = .init } });
                        try m.pushVal(next_val);
                    },
                    .target => |t| {
                        try m.pushTask(.{ .exec = fi.body });
                        try m.pushTask(.{ .bind_pattern = .{ .pat = t, .mode = .assign } });
                        try m.pushVal(next_val);
                    },
                }
            },
            else => unreachable,
        }
        return null;
    }

    noinline fn stepMemberTask(m: *Machine, task: Task) Error!void {
        const rt = m.rt;
        switch (task) {
            .assign_member_base => |am| {
                switch (am.key) {
                    .name => |n| try m.pushTask(.{ .assign_member_after_key = .{ .op = am.op, .value = am.value, .named = n, .is_private = am.is_private } }),
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
                        try m.pushTask(.{ .assign_member_plain_finish = .{ .named = am.named, .is_private = am.is_private } });
                        try m.pushEval(am.value);
                    },
                    .compound => |op| {
                        if (am.is_private) {
                            const brand = m.current_closure.?.meta.?.brand.?.asClosure();
                            const old = try object.getPrivate(rt, base, brand, try rt.heap.internAscii(am.named.?));
                            try m.pushVal(old);
                            try m.pushTask(.{ .assign_member_compound_finish = .{ .op = op, .key = .{ .index = 0 }, .priv_name = am.named.? } });
                            try m.pushEval(am.value);
                        } else {
                            const k = try m.toKey(kv);
                            const old = try object.get(rt, base, k);
                            try m.pushVal(old);
                            try m.pushTask(.{ .assign_member_compound_finish = .{ .op = op, .key = k } });
                            try m.pushEval(am.value);
                        }
                    },
                    .logical_and, .logical_or, .nullish => {
                        if (am.is_private) {
                            const brand = m.current_closure.?.meta.?.brand.?.asClosure();
                            const old = try object.getPrivate(rt, base, brand, try rt.heap.internAscii(am.named.?));
                            if (!logicalAssignShouldWrite(am.op, old)) {
                                _ = m.popVal();
                                m.depth -= 1;
                                try m.pushVal(old);
                            } else {
                                try m.pushTask(.{ .assign_member_plain_finish = .{ .named = am.named, .is_private = true } });
                                try m.pushEval(am.value);
                            }
                        } else {
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
                        }
                    },
                }
            },
            .assign_member_plain_finish => |am| {
                const v = m.popVal();
                if (am.is_private) {
                    const base = m.popVal();
                    const brand = m.current_closure.?.meta.?.brand.?.asClosure();
                    try object.setPrivate(rt, base, brand, try rt.heap.internAscii(am.named.?), v);
                } else {
                    const kv: KeyValue = if (am.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                    const base = m.popVal();
                    try object.set(rt, base, try m.toKey(kv), v);
                }
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
                if (ac.priv_name) |pn| {
                    const brand = m.current_closure.?.meta.?.brand.?.asClosure();
                    try object.setPrivate(rt, base, brand, try rt.heap.internAscii(pn), v);
                } else {
                    try object.set(rt, base, ac.key, v);
                }
                m.depth -= 1;
                try m.pushVal(v);
            },
            .update_member_base => |um| {
                switch (um.key) {
                    .name => |n| try m.pushTask(.{ .update_member_finish = .{ .op = um.op, .prefix = um.prefix, .named = n, .is_private = um.is_private } }),
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
                if (um.is_private) {
                    const brand = m.current_closure.?.meta.?.brand.?.asClosure();
                    const name_str = try rt.heap.internAscii(um.named.?);
                    const s = try stepNumeric(rt, try object.getPrivate(rt, base, brand, name_str), um.op == .inc);
                    try object.setPrivate(rt, base, brand, name_str, s.new);
                    try m.pushVal(if (um.prefix) s.new else s.old);
                } else {
                    const k = try m.toKey(kv);
                    const s = try stepNumeric(rt, try object.get(rt, base, k), um.op == .inc);
                    try object.set(rt, base, k, s.new);
                    try m.pushVal(if (um.prefix) s.new else s.old);
                }
            },
            .member_base => |mb| {
                switch (mb.key) {
                    .name => |n| {
                        const base = m.popVal();
                        const res_v: Value = if (mb.is_private) blk: {
                            const brand = m.current_closure.?.meta.?.brand.?.asClosure();
                            break :blk try object.getPrivate(rt, base, brand, try rt.heap.internAscii(n));
                        } else blk: {
                            const k = try object.named(rt, n);
                            break :blk if (mb.is_delete) Value.fromBool(try object.delete(rt, base, k)) else try object.get(rt, base, k);
                        };
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
                const res_v: Value = if (mf.is_delete) Value.fromBool(try object.delete(rt, base, k)) else try object.get(rt, base, k);
                m.depth -= 1;
                try m.pushVal(res_v);
            },
            .private_in_finish => |name| {
                const rhs = m.popVal();
                const brand = m.current_closure.?.meta.?.brand.?.asClosure();
                const b = try object.hasPrivate(rt, rhs, brand, try rt.heap.internAscii(name));
                m.depth -= 1;
                try m.pushVal(Value.fromBool(b));
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
                    return;
                }
                const step = os.oc.steps[os.idx];
                const val = m.values.items[m.values.items.len - 1];
                if (step.optional and val.isNullish()) {
                    _ = m.popVal(); // val
                    _ = m.popVal(); // receiver
                    try m.pushVal(if (os.is_delete) Value.fromBool(true) else .undefined);
                    return;
                }
                switch (step.kind) {
                    .prop => |n| {
                        const key = try object.named(rt, n);
                        if (os.is_delete and os.idx == os.oc.steps.len - 1) {
                            _ = m.popVal();
                            _ = m.popVal();
                            try m.pushVal(Value.fromBool(try object.delete(rt, val, key)));
                            return;
                        }
                        const next_val = try object.get(rt, val, key);
                        const vals = m.values.items;
                        vals[vals.len - 2] = val; // receiver = val
                        vals[vals.len - 1] = next_val;
                        try m.pushTask(.{ .opt_step = .{ .oc = os.oc, .idx = os.idx + 1, .is_delete = os.is_delete } });
                    },
                    .private_prop => |n| {
                        const brand = m.current_closure.?.meta.?.brand.?.asClosure();
                        const next_val = try object.getPrivate(rt, val, brand, try rt.heap.internAscii(n));
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
                    try m.pushVal(Value.fromBool(try object.delete(rt, val, key)));
                    return;
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
                try m.invokeCallable(callee, if (receiver.isUndefined()) null else receiver, oc_call.args_base, oc_call.args_base - 1);
            },
            .super_get_elem => {
                const this_val = try m.requireThis();
                const home = m.current_closure.?.meta.?.home_object orelse return rt.bug("super_get_elem without home_object");
                const k = try m.toKey(.{ .value = m.popVal() });
                try m.pushVal(try object.getSuper(rt, home, this_val, k));
            },
            .super_assign_plain => |named| {
                const this_val = try m.requireThis();
                const home = m.current_closure.?.meta.?.home_object orelse return rt.bug("super_assign without home_object");
                const val = m.popVal();
                const kv: KeyValue = if (named) |n| .{ .named = n } else .{ .value = m.popVal() };
                try object.setSuper(rt, home, this_val, try m.toKey(kv), val);
                try m.pushVal(val);
            },
            .super_assign_after_key => |sa| {
                const this_val = try m.requireThis();
                const home = m.current_closure.?.meta.?.home_object orelse return rt.bug("super_assign without home_object");
                const kv: KeyValue = if (sa.named) |n| .{ .named = n } else .{ .value = m.values.items[m.values.items.len - 1] };
                const k = try m.toKey(kv);
                const old = try object.getSuper(rt, home, this_val, k);
                switch (sa.op) {
                    .plain => unreachable,
                    .compound => |op| {
                        try m.pushVal(old);
                        try m.pushTask(.{ .super_assign_compound = .{ .op = op, .named = sa.named } });
                        try m.pushEval(sa.value);
                    },
                    .logical_and, .logical_or, .nullish => {
                        if (!logicalAssignShouldWrite(sa.op, old)) {
                            if (sa.named == null) _ = m.popVal(); // key
                            try m.pushVal(old);
                        } else {
                            try m.pushTask(.{ .super_assign_logical = .{ .op = sa.op, .named = sa.named } });
                            try m.pushEval(sa.value);
                        }
                    },
                }
            },
            .super_assign_compound => |sc| {
                const this_val = try m.requireThis();
                const home = m.current_closure.?.meta.?.home_object orelse return rt.bug("super_assign without home_object");
                const rhs = m.popVal();
                const old = m.popVal();
                const kv: KeyValue = if (sc.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const new_val = try ops.binary(rt, sc.op, old, rhs);
                try object.setSuper(rt, home, this_val, try m.toKey(kv), new_val);
                try m.pushVal(new_val);
            },
            .super_assign_logical => |sl| {
                const this_val = try m.requireThis();
                const home = m.current_closure.?.meta.?.home_object orelse return rt.bug("super_assign without home_object");
                const rhs = m.popVal();
                const kv: KeyValue = if (sl.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                try object.setSuper(rt, home, this_val, try m.toKey(kv), rhs);
                try m.pushVal(rhs);
            },
            .super_update_finish => |su| {
                const this_val = try m.requireThis();
                const home = m.current_closure.?.meta.?.home_object orelse return rt.bug("super_update without home_object");
                const kv: KeyValue = if (su.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const k = try m.toKey(kv);
                const s = try stepNumeric(rt, try object.getSuper(rt, home, this_val, k), su.op == .inc);
                try object.setSuper(rt, home, this_val, k, s.new);
                try m.pushVal(if (su.prefix) s.new else s.old);
            },
            .super_call_member_key => |sm| {
                const this_val = try m.requireThis();
                const home = m.current_closure.?.meta.?.home_object orelse return rt.bug("super_call_member_key without home_object");
                const kv: KeyValue = if (sm.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const callee = try object.getSuper(rt, home, this_val, try m.toKey(kv));
                try m.pushVal(callee);
                const args_base = m.values.items.len;
                if (sm.tagged) |tt| {
                    const tpl = try builtins.getTemplateObjectFromUnits(rt, @intFromPtr(tt), tt.cooked, tt.raw);
                    try m.pushVal(tpl);
                }
                try m.pushTask(.{ .invoke_call = .{ .has_receiver = true, .args_base = args_base } });
                if (sm.args.len > 0) {
                    try m.pushTask(.{ .eval_args_next = .{ .args = sm.args, .idx = 0, .args_base = args_base } });
                }
            },
            else => unreachable,
        }
    }

    noinline fn stepLiteralTask(m: *Machine, task: Task) Error!void {
        const rt = m.rt;
        switch (task) {
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
                const arr = m.values.items[m.values.items.len - 1].asObject();
                try rt.heap.appendElement(arr, v);
            },
            .array_spread_push => {
                const iterable = m.popVal();
                const arr = m.values.items[m.values.items.len - 1].asObject();
                const iter = try builtins.getIterator(rt, iterable);
                try m.pushVal(Value.fromObject(iter)); // root iter across iteratorNextVal
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
                const o = m.values.items[m.values.items.len - 1].asObject();
                const pr = op.props[op.idx].prop;
                switch (pr.kind) {
                    .init => try object.define(rt, o, op.key, v),
                    .getter, .setter => {
                        if (!v.isClosure()) return rt.bug("object accessor expects closure");
                        try rt.heap.storeClosureHomeObject(@constCast(v.asClosure()), Value.fromObject(o));
                        try object.defineAccessor(rt, Value.fromObject(o), op.key, v, pr.kind == .setter, true);
                    },
                }
                if (op.idx + 1 < op.props.len) {
                    try m.pushTask(.{ .object_next = .{ .props = op.props, .idx = op.idx + 1 } });
                }
            },
            .object_spread_finish => |os| {
                const src = m.popVal();
                const o = m.values.items[m.values.items.len - 1].asObject();
                try copyDataProperties(rt, o, src, &.{});
                if (os.idx + 1 < os.props.len) {
                    try m.pushTask(.{ .object_next = .{ .props = os.props, .idx = os.idx + 1 } });
                }
            },
            else => unreachable,
        }
    }

    noinline fn stepCallTask(m: *Machine, task: Task) Error!void {
        const rt = m.rt;
        switch (task) {
            .call_member_base => |cm| {
                switch (cm.key) {
                    .name => |n| try m.pushTask(.{ .call_member_key = .{ .named = n, .args = cm.args, .tagged = cm.tagged, .is_private = cm.is_private } }),
                    .computed => |e| {
                        try m.pushTask(.{ .call_member_key = .{ .named = null, .args = cm.args, .tagged = cm.tagged } });
                        try m.pushTask(.{ .eval = e });
                    },
                    .string, .number => unreachable,
                }
            },
            .call_member_key => |cm| {
                const kv: KeyValue = if (cm.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base = m.values.items[m.values.items.len - 1];
                const callee = if (cm.is_private) blk: {
                    const brand = m.current_closure.?.meta.?.brand.?.asClosure();
                    break :blk try object.getPrivate(rt, base, brand, try rt.heap.internAscii(cm.named.?));
                } else try object.get(rt, base, try m.toKey(kv));
                try m.pushVal(callee);
                // values: [..., receiver (base), callee]
                const args_base = m.values.items.len;
                if (cm.tagged) |tt| {
                    const tpl = try builtins.getTemplateObjectFromUnits(rt, @intFromPtr(tt), tt.cooked, tt.raw);
                    try m.pushVal(tpl);
                }
                try m.pushTask(.{ .invoke_call = .{ .has_receiver = true, .args_base = args_base } });
                if (cm.args.len > 0) {
                    try m.pushTask(.{ .eval_args_next = .{ .args = cm.args, .idx = 0, .args_base = args_base } });
                }
            },
            .call_after_callee => |ca| {
                // values: [..., callee]
                const args_base = m.values.items.len;
                if (ca.tagged) |tt| {
                    const tpl = try builtins.getTemplateObjectFromUnits(rt, @intFromPtr(tt), tt.cooked, tt.raw);
                    try m.pushVal(tpl);
                }
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
                try m.pushVal(Value.fromObject(iter));
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
                var new_target = callee;
                if (callee.isClosure() and callee.asClosure().impl == .bound) {
                    const b = callee.asClosure().impl.bound;
                    target = b.target;
                    new_target = b.target;
                    if (b.bound_args.len > 0) {
                        try m.values.insertSlice(rt.gpa, args_base, b.bound_args);
                    }
                }
                if (!builtins.isConstructor(target)) {
                    return rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }});
                }
                if (target.isObject()) {
                    const res_v = try builtins.callProxyConstruct(rt, target.asObject(), m.values.items[args_base..], new_target);
                    m.values.shrinkRetainingCapacity(args_base - 1);
                    try m.pushVal(res_v);
                    return;
                }
                if (target.isNative()) {
                    const res_v = try builtins.construct(rt, target, m.values.items[args_base..]);
                    m.values.shrinkRetainingCapacity(args_base - 1);
                    try m.pushVal(res_v);
                    return;
                }
                const tc = target.asClosure();
                const t = tc.impl.tree;
                const f: *const ast.Function = @ptrCast(@alignCast(t.func));
                const proto_val = try object.get(rt, target, try object.named(rt, "prototype"));
                const r = try builtins.realm(rt);
                const instance = try rt.heap.newObject(if (proto_val.isObject()) proto_val.asObject() else r.object_prototype);
                const init_this: ?Value = if (f.has_super_ctor) null else Value.fromObject(instance);
                try m.pushClosureCallSync(tc, f, t.env, init_this, args_base, args_base - 1, instance, false);
            },
            .invoke_super_call => |args_base| {
                if (m.this != null) {
                    return rt.throw(.ReferenceError, &.{.{ .ascii = "Super constructor may only be called once" }});
                }
                const cur_closure = m.current_closure orelse return rt.bug("super() without closure");
                var target = try object.getPrototypeOfValue(rt, Value.fromClosure(cur_closure));
                if (target.isClosure() and target.asClosure().impl == .bound) {
                    const b = target.asClosure().impl.bound;
                    target = b.target;
                    if (b.bound_args.len > 0) {
                        try m.values.insertSlice(rt.gpa, args_base, b.bound_args);
                    }
                }
                if (!builtins.isConstructor(target)) {
                    return rt.throw(.TypeError, &.{.{ .ascii = "Super constructor is not a constructor" }});
                }
                const inst = m.construct_instance orelse return rt.bug("super() without construct_instance");
                if (target.isObject()) {
                    const res_v = try builtins.callProxyConstruct(rt, target.asObject(), m.values.items[args_base..], Value.fromClosure(cur_closure));
                    m.values.shrinkRetainingCapacity(args_base);
                    m.this = res_v;
                    try builtins.runInstanceInits(rt, @constCast(cur_closure), res_v);
                    try m.pushVal(res_v);
                    return;
                }
                if (target.isNative()) {
                    const res_v = try builtins.construct(rt, target, m.values.items[args_base..]);
                    if (res_v.isObject()) rt.heap.storeObjectProto(res_v.asObject(), inst.proto);
                    m.values.shrinkRetainingCapacity(args_base);
                    m.this = res_v;
                    try builtins.runInstanceInits(rt, @constCast(cur_closure), res_v);
                    try m.pushVal(res_v);
                    return;
                }
                const tc = target.asClosure();
                const t = tc.impl.tree;
                const f: *const ast.Function = @ptrCast(@alignCast(t.func));
                const init_this: ?Value = if (f.has_super_ctor) null else Value.fromObject(inst);
                try m.pushClosureCallSync(tc, f, t.env, init_this, args_base, args_base, inst, true);
            },
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
                    try m.pushVal(Value.fromObject(arr));
                } else {
                    const v: Value = if (bp.idx < args.len) args[bp.idx] else .undefined;
                    if (p.default) |def| {
                        if (v.isUndefined()) {
                            try m.pushTask(.{ .bind_pattern = .{ .pat = p.pattern, .mode = .init } });
                            try m.pushEval(def);
                            return;
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
                // Parameters bind on the call; the generator object is returned here (D67).
                if (cb.func.is_generator) try m.pushTask(.generator_start);
            },
            .call_return => |cr| {
                // Normal return (body fell off the end without `return`).
                const cur_this = m.this;
                m.env = cr.saved_env;
                m.this = if (cr.has_this) cr.saved_this else null;
                m.current_closure = cr.saved_closure;
                m.current_func = cr.saved_func;
                m.construct_instance = cr.saved_construct_instance;
                m.res = cr.saved_res;
                m.res_ptr = cr.saved_res_ptr;
                m.repl_cells = cr.saved_repl_cells;
                m.module_record = cr.saved_module_record;
                m.calls -= 1;
                m.depth -= 1;
                m.values.shrinkRetainingCapacity(cr.values_base);
                const out_v: Value = if (cr.construct_instance) |inst| blk: {
                    if (cr.callee_func != null and cr.callee_func.?.has_super_ctor) {
                        break :blk cur_this orelse return rt.throw(.ReferenceError, &.{.{ .ascii = "Must call super constructor in derived class before accessing 'this' or returning from derived constructor" }});
                    }
                    break :blk Value.fromObject(inst);
                } else .undefined;
                if (cr.is_super_call) {
                    m.this = out_v;
                    if (m.current_closure) |dc| try builtins.runInstanceInits(rt, @constCast(dc), out_v);
                }
                try m.pushVal(out_v);
            },
            else => unreachable,
        }
    }

    noinline fn stepClassTask(m: *Machine, task: Task) Error!void {
        const rt = m.rt;
        switch (task) {
            .class_decl_init => |b| {
                const v = m.popVal();
                m.store(b, v);
            },
            .export_default_init => |ed| {
                const v = m.popVal();
                m.store(ed.default_binding, v);
                if (ed.name_binding) |nb| m.store(nb, v);
            },
            .class_setup => |cs| {
                const super_val = m.popVal();
                const saved_env = m.env;
                const has_inner = cs.is_expr and cs.cls.name != null;
                if (has_inner) {
                    const nd = cs.cls.name.?;
                    const own = try rt.heap.newEnv(m.env, m.res.bindings[nd.binding].scope, 1);
                    m.env = own;
                }
                const ctor_val = try m.evalFunction(cs.cls.constructor);
                if (has_inner) {
                    m.store(cs.cls.name.?.binding, ctor_val);
                }
                try m.pushVal(ctor_val);
                const proto_obj = try builtins.setupClass(rt, ctor_val, cs.cls.super_class != null, super_val);
                if (cs.cls.methods.len > 0 or cs.cls.instance_fields.len > 0 or cs.cls.static_fields.len > 0 or cs.cls.static_items.len > 0) {
                    if (has_inner) try m.pushTask(.{ .scope_exit = saved_env });
                    try m.pushVal(Value.fromObject(proto_obj));
                    try m.pushTask(.{ .class_method_next = .{ .cls = cs.cls, .idx = 0 } });
                } else if (has_inner) {
                    m.env = saved_env;
                }
            },
            .class_method_next => |cm| {
                var idx = cm.idx;
                while (idx < cm.cls.methods.len and cm.cls.methods[idx].is_private) : (idx += 1) {}
                if (idx >= cm.cls.methods.len) {
                    const proto_val = m.popVal();
                    const ctor_val = m.values.items[m.values.items.len - 1];
                    const ctor_c = @constCast(ctor_val.asClosure());
                    // Register private instance methods/accessors in instance_inits, and install static private methods on ctor.
                    for (cm.cls.methods) |meth| {
                        if (!meth.is_private) continue;
                        const fn_val = try m.evalFunction(meth.func);
                        try rt.heap.storeClosureBrand(@constCast(fn_val.asClosure()), ctor_val);
                        const name_str = try rt.heap.internAscii(meth.key.name);
                        if (meth.is_static) {
                            try rt.heap.storeClosureHomeObject(@constCast(fn_val.asClosure()), ctor_val);
                            switch (meth.kind) {
                                .method => try object.definePrivateMethod(rt, ctor_val, ctor_c, name_str, fn_val),
                                .getter, .setter => try object.definePrivateAccessor(rt, ctor_val, ctor_c, name_str, fn_val, meth.kind == .setter),
                            }
                        } else {
                            try rt.heap.storeClosureHomeObject(@constCast(fn_val.asClosure()), proto_val);
                            try rt.heap.appendClosureInstanceInit(ctor_c, .{
                                .kind = switch (meth.kind) {
                                    .method => .private_method,
                                    .getter => .private_getter,
                                    .setter => .private_setter,
                                },
                                .name = name_str,
                                .func = fn_val,
                            });
                        }
                    }
                    try m.pushVal(proto_val);
                    try m.pushTask(.{ .class_inst_field_next = .{ .cls = cm.cls, .idx = 0, .key_idx = 0 } });
                    return;
                }
                const meth = cm.cls.methods[idx];
                switch (meth.key) {
                    .name => |n| try m.pushTask(.{ .class_method_finish = .{ .cls = cm.cls, .idx = idx, .named = n } }),
                    .string => |units| {
                        const s = try rt.heap.newString(&.{.{ .utf16 = units }});
                        try m.pushVal(Value.fromString(s));
                        try m.pushTask(.{ .class_method_finish = .{ .cls = cm.cls, .idx = idx, .named = null } });
                    },
                    .number => |num| {
                        try m.pushVal(Value.fromNumber(num));
                        try m.pushTask(.{ .class_method_finish = .{ .cls = cm.cls, .idx = idx, .named = null } });
                    },
                    .computed => |k| {
                        try m.pushTask(.{ .class_method_finish = .{ .cls = cm.cls, .idx = idx, .named = null } });
                        try m.pushEval(k);
                    },
                }
            },
            .class_method_finish => |cm| {
                const meth = cm.cls.methods[cm.idx];
                const kv: KeyValue = if (cm.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const k = try m.toKey(kv);
                const proto_val = m.values.items[m.values.items.len - 1];
                const ctor_val = m.values.items[m.values.items.len - 2];
                const target = if (meth.is_static) ctor_val else proto_val;
                const fn_val = try m.evalFunction(meth.func);
                try rt.heap.storeClosureBrand(@constCast(fn_val.asClosure()), ctor_val);
                switch (meth.kind) {
                    .method => try builtins.defineClassMethod(rt, target, k, fn_val),
                    .getter, .setter => try builtins.defineClassAccessor(rt, target, k, fn_val, meth.kind == .setter),
                }
                try m.pushTask(.{ .class_method_next = .{ .cls = cm.cls, .idx = cm.idx + 1 } });
            },
            .class_inst_field_next => |cf| {
                if (cf.idx >= cf.cls.instance_fields.len) {
                    _ = m.popVal(); // pop proto_obj, leaving ctor on top
                    const keys_base = m.values.items.len;
                    try m.pushTask(.{ .class_static_item_next = .{ .cls = cf.cls, .idx = 0, .keys_base = keys_base } });
                    try m.pushTask(.{ .class_static_key_next = .{ .cls = cf.cls, .idx = 0 } });
                    return;
                }
                const f = cf.cls.instance_fields[cf.idx];
                if (f.is_private) {
                    try m.pushTask(.{ .class_inst_field_finish = .{ .cls = cf.cls, .idx = cf.idx, .key_idx = cf.key_idx, .is_named = true } });
                    return;
                }
                switch (f.key) {
                    .name => |n| {
                        const s = try rt.heap.internAscii(n);
                        try m.pushVal(Value.fromString(s));
                        try m.pushTask(.{ .class_inst_field_finish = .{ .cls = cf.cls, .idx = cf.idx, .key_idx = cf.key_idx, .is_named = false } });
                    },
                    .string => |units| {
                        const s = try rt.heap.newString(&.{.{ .utf16 = units }});
                        try m.pushVal(Value.fromString(s));
                        try m.pushTask(.{ .class_inst_field_finish = .{ .cls = cf.cls, .idx = cf.idx, .key_idx = cf.key_idx, .is_named = false } });
                    },
                    .number => |num| {
                        try m.pushVal(Value.fromNumber(num));
                        try m.pushTask(.{ .class_inst_field_finish = .{ .cls = cf.cls, .idx = cf.idx, .key_idx = cf.key_idx, .is_named = false } });
                    },
                    .computed => |k| {
                        try m.pushTask(.{ .class_inst_field_finish = .{ .cls = cf.cls, .idx = cf.idx, .key_idx = cf.key_idx, .is_named = false } });
                        try m.pushEval(k);
                    },
                }
            },
            .class_inst_field_finish => |cf| {
                const f = cf.cls.instance_fields[cf.idx];
                const key_val: Value = if (cf.is_named) .undefined else m.popVal();
                const proto_val = m.values.items[m.values.items.len - 1];
                const ctor_val = m.values.items[m.values.items.len - 2];
                const ctor_c = @constCast(ctor_val.asClosure());
                const init_val: Value = if (f.init) |init_fn| blk: {
                    const iv = try m.evalFunction(init_fn);
                    try rt.heap.storeClosureHomeObject(@constCast(iv.asClosure()), proto_val);
                    try rt.heap.storeClosureBrand(@constCast(iv.asClosure()), ctor_val);
                    break :blk iv;
                } else .undefined;
                var next_key_idx = cf.key_idx;
                if (f.is_private) {
                    try rt.heap.appendClosureInstanceInit(ctor_c, .{
                        .kind = .private_field,
                        .name = try rt.heap.internAscii(f.key.name),
                        .func = init_val,
                    });
                } else {
                    try rt.heap.appendClosureFieldKey(ctor_c, key_val);
                    try rt.heap.appendClosureInstanceInit(ctor_c, .{
                        .kind = .public_field,
                        .key_idx = cf.key_idx,
                        .func = init_val,
                    });
                    next_key_idx += 1;
                }
                try m.pushTask(.{ .class_inst_field_next = .{ .cls = cf.cls, .idx = cf.idx + 1, .key_idx = next_key_idx } });
            },
            .class_static_key_next => |cs| {
                if (cs.idx >= cs.cls.static_fields.len) return;
                const f = cs.cls.static_fields[cs.idx];
                if (f.is_private) {
                    try m.pushVal(.undefined);
                    try m.pushTask(.{ .class_static_key_next = .{ .cls = cs.cls, .idx = cs.idx + 1 } });
                    return;
                }
                switch (f.key) {
                    .name => |n| {
                        try m.pushVal(Value.fromString(try rt.heap.internAscii(n)));
                        try m.pushTask(.{ .class_static_key_next = .{ .cls = cs.cls, .idx = cs.idx + 1 } });
                    },
                    .string => |units| {
                        try m.pushVal(Value.fromString(try rt.heap.newString(&.{.{ .utf16 = units }})));
                        try m.pushTask(.{ .class_static_key_next = .{ .cls = cs.cls, .idx = cs.idx + 1 } });
                    },
                    .number => |num| {
                        try m.pushVal(Value.fromNumber(num));
                        try m.pushTask(.{ .class_static_key_next = .{ .cls = cs.cls, .idx = cs.idx + 1 } });
                    },
                    .computed => |k| {
                        try m.pushTask(.{ .class_static_key_finish = .{ .cls = cs.cls, .idx = cs.idx } });
                        try m.pushEval(k);
                    },
                }
            },
            .class_static_key_finish => |cs| {
                try m.pushTask(.{ .class_static_key_next = .{ .cls = cs.cls, .idx = cs.idx + 1 } });
            },
            .class_static_item_next => |cs| {
                if (cs.idx >= cs.cls.static_items.len) {
                    m.values.shrinkRetainingCapacity(cs.keys_base); // leave ctor on top
                    return;
                }
                const ctor_val = m.values.items[cs.keys_base - 1];
                switch (cs.cls.static_items[cs.idx]) {
                    .field => |fidx| {
                        const f = cs.cls.static_fields[fidx];
                        const val: Value = if (f.init) |init_fn| blk: {
                            const iv = try m.evalFunction(init_fn);
                            try rt.heap.storeClosureHomeObject(@constCast(iv.asClosure()), ctor_val);
                            try rt.heap.storeClosureBrand(@constCast(iv.asClosure()), ctor_val);
                            break :blk try rt.callCallable(iv, ctor_val, &.{});
                        } else .undefined;
                        if (f.is_private) {
                            try object.definePrivateField(rt, ctor_val, ctor_val.asClosure(), try rt.heap.internAscii(f.key.name), val);
                        } else {
                            const key_val = m.values.items[cs.keys_base + fidx];
                            try object.definePublicField(rt, ctor_val, try object.key(rt, key_val), val);
                        }
                    },
                    .block => |blk_fn| {
                        const bv = try m.evalFunction(blk_fn);
                        try rt.heap.storeClosureHomeObject(@constCast(bv.asClosure()), ctor_val);
                        try rt.heap.storeClosureBrand(@constCast(bv.asClosure()), ctor_val);
                        _ = try rt.callCallable(bv, ctor_val, &.{});
                    },
                }
                try m.pushTask(.{ .class_static_item_next = .{ .cls = cs.cls, .idx = cs.idx + 1, .keys_base = cs.keys_base } });
            },
            else => unreachable,
        }
    }

    noinline fn stepBindTask(m: *Machine, task: Task) Error!void {
        const rt = m.rt;
        switch (task) {
            .bind_target_super_finish => |named| {
                const this_val = try m.requireThis();
                const kv: KeyValue = if (named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const val = m.popVal();
                try object.set(rt, this_val, try m.toKey(kv), val);
            },
            .bind_pattern => |bp| {
                const val = m.popVal();
                try m.stepBindPattern(bp.pat, val, bp.mode);
            },
            .bind_target_member_base => |mb| {
                // values: [..., val, base]
                switch (mb.key) {
                    .name => |n| try m.pushTask(.{ .bind_target_member_finish = .{ .named = n, .is_private = mb.is_private } }),
                    .computed => |e| {
                        try m.pushTask(.{ .bind_target_member_finish = .{ .named = null } });
                        try m.pushTask(.{ .eval = e });
                    },
                    .string, .number => unreachable,
                }
            },
            .bind_target_member_finish => |bf| {
                const kv: KeyValue = if (bf.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base = m.popVal();
                const val = m.popVal();
                if (bf.is_private) {
                    const brand = m.current_closure.?.meta.?.brand.?.asClosure();
                    try object.setPrivate(rt, base, brand, try rt.heap.internAscii(bf.named.?), val);
                } else {
                    const k = try m.toKey(kv);
                    try object.set(rt, base, k, val);
                }
            },
            .bind_array_elem => |ba| {
                // values: [..., iter]
                const iter = m.values.items[m.values.items.len - 1].asObject();
                const arr = ba.pat.data.array;
                if (ba.idx < arr.elems.len) {
                    const maybe_el = arr.elems[ba.idx];
                    if (maybe_el == null) {
                        _ = try builtins.iteratorNextVal(rt, iter);
                        try m.pushTask(.{ .bind_array_elem = .{ .pat = ba.pat, .idx = ba.idx + 1, .mode = ba.mode } });
                        return;
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
                        return;
                    }
                    const v: Value = (try builtins.iteratorNextVal(rt, iter)) orelse .undefined;
                    if (el.default) |def| if (v.isUndefined()) {
                        try m.pushTask(.{ .bind_array_elem_after_default = .{
                            .pat = ba.pat,
                            .idx = ba.idx,
                            .mode = ba.mode,
                            .has_mv = false,
                        } });
                        try m.pushEval(def);
                        return;
                    };
                    try m.pushTask(.{ .bind_array_elem = .{ .pat = ba.pat, .idx = ba.idx + 1, .mode = ba.mode } });
                    try m.pushTask(.{ .bind_pattern = .{ .pat = el.pattern, .mode = ba.mode } });
                    try m.pushVal(v);
                    return;
                }
                if (arr.rest) |rest| {
                    if (ba.mode == .assign and rest.data == .target and rest.data.target == .member) {
                        const mem = rest.data.target.member;
                        try m.pushTask(.{ .bind_array_rest_pre_member = .{ .rest = rest, .key = mem.key } });
                        try m.pushEval(mem.object);
                        return;
                    }
                    const rest_arr = try rt.heap.newArray((try builtins.realm(rt)).array_prototype);
                    try m.pushVal(Value.fromObject(rest_arr));
                    while (try builtins.iteratorNextVal(rt, iter)) |elem| {
                        try rt.heap.appendElement(rest_arr, elem);
                    }
                    const ra = m.popVal();
                    _ = m.popVal(); // iter
                    try m.pushTask(.{ .bind_pattern = .{ .pat = rest, .mode = ba.mode } });
                    try m.pushVal(ra);
                    return;
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
                const iter = m.values.items[iter_idx].asObject();
                const el = ba.pat.data.array.elems[ba.idx].?;
                const v: Value = (try builtins.iteratorNextVal(rt, iter)) orelse .undefined;
                if (el.default) |def| if (v.isUndefined()) {
                    try m.pushTask(.{ .bind_array_elem_after_default = .{
                        .pat = ba.pat,
                        .idx = ba.idx,
                        .mode = ba.mode,
                        .has_mv = true,
                    } });
                    try m.pushEval(def);
                    return;
                };
                const kv: KeyValue = if (ba.named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base = m.popVal();
                if (el.pattern.data.target.member.is_private) {
                    const brand = m.current_closure.?.meta.?.brand.?.asClosure();
                    try object.setPrivate(rt, base, brand, try rt.heap.internAscii(ba.named.?), v);
                } else {
                    try object.set(rt, base, try m.toKey(kv), v);
                }
                try m.pushTask(.{ .bind_array_elem = .{ .pat = ba.pat, .idx = ba.idx + 1, .mode = ba.mode } });
            },
            .bind_array_elem_after_default => |ba| {
                const v = m.popVal();
                const el = ba.pat.data.array.elems[ba.idx].?;
                if (ba.has_mv) {
                    const mem = el.pattern.data.target.member;
                    const kv: KeyValue = switch (mem.key) {
                        .name => |n| .{ .named = n },
                        .computed => .{ .value = m.popVal() },
                        .string, .number => unreachable,
                    };
                    const base = m.popVal();
                    if (mem.is_private) {
                        const brand = m.current_closure.?.meta.?.brand.?.asClosure();
                        try object.setPrivate(rt, base, brand, try rt.heap.internAscii(mem.key.name), v);
                    } else {
                        try object.set(rt, base, try m.toKey(kv), v);
                    }
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
                const iter_idx = if (named == null) m.values.items.len - 3 else m.values.items.len - 2;
                const iter = m.values.items[iter_idx].asObject();
                const rest_arr = try rt.heap.newArray((try builtins.realm(rt)).array_prototype);
                try m.pushVal(Value.fromObject(rest_arr));
                while (try builtins.iteratorNextVal(rt, iter)) |elem| {
                    try rt.heap.appendElement(rest_arr, elem);
                }
                const ra = m.popVal();
                const kv2: KeyValue = if (named) |n| .{ .named = n } else .{ .value = m.popVal() };
                const base2 = m.popVal();
                _ = m.popVal(); // iter
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
                        return;
                    }
                    const k = try m.literalKey(pr.key);
                    try m.bindObjectPropWithKey(bo, k);
                    return;
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
                        return;
                    }
                    const rest_obj = try rt.heap.newObject((try builtins.realm(rt)).object_prototype);
                    try m.pushVal(Value.fromObject(rest_obj));
                    const val = m.values.items[bo.excl_base - 1];
                    try m.copyExcludedDataProperties(rest_obj, val, bo.excl_base, bo.excl_count);
                    const ro = m.popVal();
                    m.values.shrinkRetainingCapacity(bo.excl_base - 1); // pop excl + val
                    try m.pushTask(.{ .bind_pattern = .{ .pat = rest, .mode = bo.mode } });
                    try m.pushVal(ro);
                    return;
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
                if (pr.default) |def| if (v.isUndefined()) {
                    try m.pushTask(.{ .bind_object_prop_after_default = .{
                        .pat = bo.pat,
                        .idx = bo.idx,
                        .mode = bo.mode,
                        .excl_base = bo.excl_base,
                        .excl_count = bo.excl_count,
                        .has_mv = true,
                    } });
                    try m.pushEval(def);
                    return;
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
                try m.pushVal(Value.fromObject(rest_obj));
                try m.copyExcludedDataProperties(rest_obj, val, bo.excl_base, bo.excl_count);
                _ = m.popVal(); // rest_obj
                try object.set(rt, base, try m.toKey(kv), Value.fromObject(rest_obj));
                m.values.shrinkRetainingCapacity(bo.excl_base - 1);
            },
            .array_iter_close => |ac| try builtins.iteratorClose(rt, ac.iter, false),
            else => unreachable,
        }
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
            .class => |cls| {
                try m.pushTask(.depth_pop);
                try m.pushTask(.{ .class_decl_init = cls.name.?.binding });
                try m.pushTask(.{ .class_setup = .{ .cls = cls, .is_expr = false } });
                if (cls.super_class) |sc| {
                    try m.pushEval(sc);
                } else {
                    try m.pushVal(.undefined);
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
                    m.store(f.name.?.binding, Value.fromClosure(try m.makeTreeClosure(f, m.env)));
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
                    if (m.inAsyncGenerator()) { // `return e` awaits `e` (D68)
                        try m.enter();
                        try m.pushTask(.await_suspend);
                    }
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
            .for_in => |f| {
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
                try m.pushTask(.{ .for_in_start = .{ .stmt = s, .has_scope = has_scope, .values_base = values_base } });
                try m.pushEval(f.object);
            },
            .import_decl => m.depth -= 1,
            .export_decl => |exp| switch (exp) {
                .declaration => |decl| {
                    m.depth -= 1;
                    if (decl.declarators.len > 0) try m.pushTask(.{ .decl_next = .{ .decls = decl.declarators, .idx = 0 } });
                },
                .class => |cls| {
                    try m.pushTask(.depth_pop);
                    try m.pushTask(.{ .class_decl_init = cls.name.?.binding });
                    try m.pushTask(.{ .class_setup = .{ .cls = cls, .is_expr = false } });
                    if (cls.super_class) |sc| {
                        try m.pushEval(sc);
                    } else {
                        try m.pushVal(.undefined);
                    }
                },
                .default_expr => |de| {
                    try m.pushTask(.depth_pop);
                    try m.pushTask(.{ .export_default_init = .{ .default_binding = de.binding, .name_binding = null } });
                    try m.pushEval(de.expr);
                },
                .default_class => |dc| {
                    try m.pushTask(.depth_pop);
                    try m.pushTask(.{ .export_default_init = .{
                        .default_binding = dc.binding,
                        .name_binding = if (dc.cls.name) |n| n.binding else null,
                    } });
                    try m.pushTask(.{ .class_setup = .{ .cls = dc.cls, .is_expr = false } });
                    if (dc.cls.super_class) |sc| {
                        try m.pushEval(sc);
                    } else {
                        try m.pushVal(.undefined);
                    }
                },
                .function, .default_function, .named, .reexport_named, .reexport_all => m.depth -= 1,
            },
            .labeled => |l| {
                const values_base: u32 = @intCast(m.values.items.len);
                try m.pushTask(.depth_pop);
                try m.pushTask(.{ .labeled = .{ .label = l.label, .values_base = values_base } });
                try m.pushTask(.{ .exec = l.body });
            },
            .@"break" => |lbl| {
                m.depth -= 1;
                return .{ .@"break" = lbl };
            },
            .@"continue" => |lbl| {
                m.depth -= 1;
                return .{ .@"continue" = lbl };
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
                try m.pushVal(Value.fromNumber(n));
            },
            .bigint => |raw| {
                m.depth -= 1;
                try m.pushVal(Value.fromBigInt(try bigint.parse(rt, raw, true)));
            },
            .string => |units| {
                m.depth -= 1;
                try m.pushVal(Value.fromString(try rt.heap.newString(&.{.{ .utf16 = units }})));
            },
            .regexp => |rx| {
                m.depth -= 1;
                try m.pushVal(try builtins.newRegExpFromLiteral(rt, rx.pattern, rx.flags));
            },
            .boolean => |b| {
                m.depth -= 1;
                try m.pushVal(Value.fromBool(b));
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
                try m.pushVal(try m.requireThis());
            },
            .function => |f| {
                m.depth -= 1;
                try m.pushVal(try m.evalFunction(f));
            },
            .class => |cls| {
                try m.pushTask(.depth_pop);
                try m.pushTask(.{ .class_setup = .{ .cls = cls, .is_expr = true } });
                if (cls.super_class) |sc| {
                    try m.pushEval(sc);
                } else {
                    try m.pushVal(.undefined);
                }
            },
            .super_call => |args| {
                try m.pushTask(.depth_pop);
                const args_base = m.values.items.len;
                try m.pushTask(.{ .invoke_super_call = args_base });
                if (args.len > 0) {
                    try m.pushTask(.{ .eval_args_next = .{ .args = args, .idx = 0, .args_base = args_base } });
                }
            },
            .super_member => |k| {
                const this_val = try m.requireThis();
                const home = m.current_closure.?.meta.?.home_object orelse return rt.bug("super_member without home_object");
                switch (k) {
                    .name => |n| {
                        m.depth -= 1;
                        try m.pushVal(try object.getSuper(rt, home, this_val, try m.toKey(.{ .named = n })));
                    },
                    .computed => |ke| {
                        try m.pushTask(.depth_pop);
                        try m.pushTask(.super_get_elem);
                        try m.pushEval(ke);
                    },
                    .string, .number => unreachable,
                }
            },
            .delete_super => return rt.throw(.ReferenceError, &.{.{ .ascii = "Unsupported reference to 'super'" }}),
            .await => |inner| {
                try m.pushTask(.await_suspend);
                try m.pushEval(inner);
            },
            .yield => |y| {
                if (y.star) {
                    try m.pushTask(if (m.inAsyncGenerator()) .async_yield_star_init else .yield_star_init);
                    try m.pushEval(y.value.?);
                } else {
                    try m.pushTask(.{ .yield_suspend = false });
                    if (m.inAsyncGenerator()) { // AsyncGeneratorYield awaits its operand (D68)
                        try m.enter();
                        try m.pushTask(.await_suspend);
                    }
                    if (y.value) |v| try m.pushEval(v) else try m.pushVal(.undefined);
                }
            },
            .template => |t| {
                const first: Value = Value.fromString(try rt.heap.newString(&.{.{ .utf16 = t.quasis[0] }}));
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
                    try m.pushTask(.{ .assign_member_base = .{ .op = a.op, .key = mem.key, .value = a.value, .is_private = mem.is_private } });
                    try m.pushEval(mem.object);
                },
                .super_member => |k| {
                    _ = try m.requireThis();
                    if (a.op == .plain) {
                        switch (k) {
                            .name => |n| {
                                try m.pushTask(.{ .super_assign_plain = n });
                                try m.pushEval(a.value);
                            },
                            .computed => |ke| {
                                try m.pushTask(.{ .super_assign_plain = null });
                                try m.pushTask(.{ .eval = a.value });
                                try m.pushEval(ke);
                            },
                            .string, .number => unreachable,
                        }
                    } else {
                        switch (k) {
                            .name => |n| try m.pushTask(.{ .super_assign_after_key = .{ .op = a.op, .value = a.value, .named = n } }),
                            .computed => |ke| {
                                try m.pushTask(.{ .super_assign_after_key = .{ .op = a.op, .value = a.value, .named = null } });
                                try m.pushEval(ke);
                            },
                            .string, .number => unreachable,
                        }
                    }
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
                    const s = try stepNumeric(rt, try m.read(ref), u.op == .inc);
                    try m.write(ref, s.new);
                    m.depth -= 1;
                    try m.pushVal(if (u.prefix) s.new else s.old);
                },
                .member => |mem| {
                    try m.pushTask(.depth_pop);
                    try m.pushTask(.{ .update_member_base = .{ .op = u.op, .prefix = u.prefix, .key = mem.key, .is_private = mem.is_private } });
                    try m.pushTask(.{ .eval = mem.object });
                },
                .super_member => |k| {
                    _ = try m.requireThis();
                    try m.pushTask(.depth_pop);
                    switch (k) {
                        .name => |n| try m.pushTask(.{ .super_update_finish = .{ .op = u.op, .prefix = u.prefix, .named = n } }),
                        .computed => |ke| {
                            try m.pushTask(.{ .super_update_finish = .{ .op = u.op, .prefix = u.prefix, .named = null } });
                            try m.pushEval(ke);
                        },
                        .string, .number => unreachable,
                    }
                },
            },
            .member => |mem| {
                try m.pushTask(.{ .member_base = .{ .key = mem.key, .is_delete = false, .is_private = mem.is_private } });
                try m.pushEval(mem.object);
            },
            .private_in => |pi| {
                try m.pushTask(.{ .private_in_finish = pi.name });
                try m.pushEval(pi.rhs);
            },
            .import_meta => {
                const mod_ptr = m.module_record orelse return rt.bug("import.meta outside a module");
                const meta_obj = try module.getImportMeta(rt, @ptrCast(@alignCast(mod_ptr)));
                m.depth -= 1;
                try m.pushVal(Value.fromObject(meta_obj));
            },
            .dynamic_import => |spec| {
                try m.pushTask(.dynamic_import);
                try m.pushEval(spec);
            },
            .delete => |mem| {
                try m.pushTask(.{ .member_base = .{ .key = mem.key, .is_delete = true } });
                try m.pushEval(mem.object);
            },
            .optional_chain => |oc| try m.startOptionalChain(oc, false),
            .delete_optional => |oc| try m.startOptionalChain(oc, true),
            .array => |items| {
                const arr = try rt.heap.newArray((try builtins.realm(rt)).array_prototype);
                try m.pushVal(Value.fromObject(arr));
                if (items.len == 0) {
                    m.depth -= 1;
                } else {
                    try m.pushTask(.depth_pop);
                    try m.pushTask(.{ .array_next = .{ .items = items, .idx = 0 } });
                }
            },
            .object => |props| {
                const o = try rt.heap.newObject((try builtins.realm(rt)).object_prototype);
                try m.pushVal(Value.fromObject(o));
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
                    try m.pushTask(.{ .call_member_base = .{ .key = mem.key, .args = c.args, .is_private = mem.is_private } });
                    try m.pushEval(mem.object);
                } else if (c.callee.data == .super_member) {
                    const this_val = try m.requireThis();
                    try m.pushVal(this_val);
                    switch (c.callee.data.super_member) {
                        .name => |n| try m.pushTask(.{ .super_call_member_key = .{ .named = n, .args = c.args } }),
                        .computed => |ke| {
                            try m.pushTask(.{ .super_call_member_key = .{ .named = null, .args = c.args } });
                            try m.pushEval(ke);
                        },
                        .string, .number => unreachable,
                    }
                } else {
                    try m.pushTask(.{ .call_after_callee = .{ .args = c.args, .has_receiver = false } });
                    try m.pushEval(c.callee);
                }
            },
            .tagged_template => |*tt| {
                try m.pushTask(.depth_pop);
                if (tt.callee.data == .member) {
                    const mem = tt.callee.data.member;
                    try m.pushTask(.{ .call_member_base = .{ .key = mem.key, .args = tt.exprs, .tagged = tt, .is_private = mem.is_private } });
                    try m.pushEval(mem.object);
                } else if (tt.callee.data == .super_member) {
                    const this_val = try m.requireThis();
                    try m.pushVal(this_val);
                    switch (tt.callee.data.super_member) {
                        .name => |n| try m.pushTask(.{ .super_call_member_key = .{ .named = n, .args = tt.exprs, .tagged = tt } }),
                        .computed => |ke| {
                            try m.pushTask(.{ .super_call_member_key = .{ .named = null, .args = tt.exprs, .tagged = tt } });
                            try m.pushEval(ke);
                        },
                        .string, .number => unreachable,
                    }
                } else {
                    try m.pushTask(.{ .call_after_callee = .{ .args = tt.exprs, .has_receiver = false, .tagged = tt } });
                    try m.pushEval(tt.callee);
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
            const cl = try m.makeTreeClosure(f, own);
            rt.heap.storeEnv(own, 0, Value.fromClosure(cl));
            break :blk cl;
        } else try m.makeTreeClosure(f, m.env);
        if (f.is_arrow) {
            if (m.this) |t| try rt.heap.storeClosureLexicalThis(c, t);
            if (m.current_closure) |pc| {
                if (pc.meta) |pm| {
                    if (pm.home_object) |ho| try rt.heap.storeClosureHomeObject(c, ho);
                }
            }
        }
        if (m.current_closure) |pc| {
            if (pc.meta) |pm| {
                if (pm.brand) |br| try rt.heap.storeClosureBrand(c, br);
            }
        }
        return Value.fromClosure(c);
    }

    fn requireThis(m: *Machine) Error!Value {
        if (m.this) |t| return t;
        if (m.current_func) |cf| if (cf.has_super_ctor) {
            return m.rt.throw(.ReferenceError, &.{.{ .ascii = "Must call super constructor in derived class before accessing 'this' or returning from derived constructor" }});
        };
        return m.rt.fail(.sloppy_this);
    }

    fn invokeCallable(m: *Machine, callee: Value, receiver: ?Value, args_base: usize, result_base: usize) Error!void {
        const rt = m.rt;
        if (callee.isClosure() and callee.asClosure().impl == .bound) {
            const b = callee.asClosure().impl.bound;
            if (b.bound_args.len > 0) {
                try m.values.insertSlice(rt.gpa, args_base, b.bound_args);
            }
            return m.invokeCallable(b.target, b.bound_this, args_base, result_base);
        }
        const args = m.values.items[args_base..];
        switch (callee.unpack()) {
            .native => |n| {
                const res_v = if (n.host != null) return rt.fail(.builtin) else try n.call(rt, receiver orelse .undefined, args);
                m.values.shrinkRetainingCapacity(result_base);
                try m.pushVal(res_v);
            },
            .closure => |cl| {
                const this_val: ?Value = if (receiver) |r| (if (r.isObjectLike()) r else null) else null;
                try m.pushClosureCall(cl, this_val, args_base, result_base);
            },
            .object => |o| {
                if (o.kind != .proxy or !o.kind.proxy.is_callable) return rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }});
                const res_v = try builtins.callProxy(rt, o, receiver orelse .undefined, args);
                m.values.shrinkRetainingCapacity(result_base);
                try m.pushVal(res_v);
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
        if (f.is_class_constructor) {
            return m.rt.throw(.TypeError, &.{.{ .ascii = "Class constructor cannot be invoked without 'new'" }});
        }
        if (f.is_async or f.is_generator) {
            const p = try startAsync(m.rt, m, closure, this, m.values.items[args_base..]);
            m.values.shrinkRetainingCapacity(result_base);
            try m.pushVal(p);
            return;
        }
        return m.pushClosureCallSync(closure, f, t.env, this, args_base, result_base, null, false);
    }

    fn pushClosureCallSync(m: *Machine, closure: *const heap.Closure, f: *const ast.Function, env: ?*Env, this: ?Value, args_base: usize, result_base: usize, construct_instance: ?*heap.Object, is_super_call: bool) Error!void {
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
            .saved_closure = m.current_closure,
            .saved_func = m.current_func,
            .saved_construct_instance = m.construct_instance,
            .callee_func = f,
            .is_super_call = is_super_call,
            .saved_res = m.res,
            .saved_res_ptr = m.res_ptr,
            .saved_repl_cells = m.repl_cells,
            .saved_module_record = m.module_record,
        } });

        if (closure.impl.tree.res) |rp| {
            const res_ptr: *const Resolution = @ptrCast(@alignCast(rp));
            m.res = res_ptr.*;
            m.res_ptr = res_ptr;
            m.repl_cells = closure.impl.tree.repl_cells;
        }
        m.module_record = closure.impl.tree.module_record;
        m.env = env;
        m.this = if (f.has_super_ctor) null else if (f.is_arrow) (if (closure.meta) |meta| meta.lexical_this else null) else this;
        m.current_closure = closure;
        m.current_func = f;
        m.construct_instance = construct_instance;
        if (m.res.functions[f.id].param_scope) |ps| {
            if (m.res.scopes[ps].len > 0) _ = try m.pushScope(ps);
        }
        const argc: u32 = @intCast(m.values.items.len - args_base);
        if (f.params.len > 0) {
            try m.pushTask(.{ .call_bind_param = .{ .func = f, .idx = 0, .args_base = @intCast(args_base), .argc = argc } });
        } else {
            try m.pushTask(.{ .call_enter_body = .{ .func = f, .args_base = @intCast(args_base) } });
        }
        if (construct_instance != null and !f.has_super_ctor) {
            try builtins.runInstanceInits(m.rt, @constCast(closure), Value.fromObject(construct_instance.?));
        }
    }

    fn constructFromBuiltin(ctx: *anyopaque, closure: *const heap.Closure, args: []const Value, new_target: Value) Error!Value {
        const m: *Machine = @ptrCast(@alignCast(ctx));
        closure.obj.checkLive();
        const t = switch (closure.impl) {
            .tree => |t| t,
            else => return m.rt.bug("a non-tree-walker closure in constructFromBuiltin"),
        };
        const f: *const ast.Function = @ptrCast(@alignCast(t.func));
        if (f.is_generator or !builtins.hasAutoPrototype(closure)) {
            return m.rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }});
        }

        var ret_root = [_]Value{ m.ret, Value.fromClosure(closure), new_target, .undefined };
        var ret_roots: rt_mod.ValueRoots = .{ .values = &ret_root };
        try ret_roots.register(m.rt);
        m.ret = .undefined;
        defer {
            m.ret = ret_root[0];
            ret_roots.unregister(m.rt);
        }

        const proto_val = try object.get(m.rt, new_target, try object.named(m.rt, "prototype"));
        const r = try builtins.realm(m.rt);
        const instance = try m.rt.heap.newObject(if (proto_val.isObject()) proto_val.asObject() else r.object_prototype);
        ret_root[3] = Value.fromObject(instance);
        const init_this: ?Value = if (f.has_super_ctor) null else Value.fromObject(instance);

        const values_base = m.values.items.len;
        const stop_len = m.tasks.items.len;
        errdefer {
            m.tasks.shrinkRetainingCapacity(stop_len);
            m.values.shrinkRetainingCapacity(values_base);
        }
        try m.pushTask(.{ .barrier = @intCast(values_base) });
        const args_base = m.values.items.len;
        try m.values.appendSlice(m.rt.gpa, args);
        try m.pushClosureCallSync(closure, f, t.env, init_this, args_base, values_base, instance, false);
        _ = try m.runLoop(stop_len);
        return m.popVal();
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
        if (f.is_class_constructor) return m.rt.throw(.TypeError, &.{.{ .ascii = "Class constructor cannot be invoked without 'new'" }});
        if (f.is_async or f.is_generator) return startAsync(m.rt, m, closure, this, args);

        var ret_root = [_]Value{m.ret};
        var ret_roots: rt_mod.ValueRoots = .{ .values = &ret_root };
        try ret_roots.register(m.rt);
        m.ret = .undefined;
        defer {
            m.ret = ret_root[0];
            ret_roots.unregister(m.rt);
        }

        const values_base = m.values.items.len;
        const stop_len = m.tasks.items.len;
        errdefer {
            m.tasks.shrinkRetainingCapacity(stop_len);
            m.values.shrinkRetainingCapacity(values_base);
        }
        try m.pushTask(.{ .barrier = @intCast(values_base) });
        const args_base = m.values.items.len;
        try m.values.appendSlice(m.rt.gpa, args);
        try m.pushClosureCallSync(closure, f, t.env, this, args_base, values_base, null, false);
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
        @"resume": struct { val: Value, mode: coroutine.ResumeMode },
    };

    /// Async functions and generators (D67) both run on a coroutine Machine.
    fn startAsync(rt: *Runtime, caller: *Machine, closure: *const heap.Closure, this: ?Value, args: []const Value) Error!Value {
        const ctx: StartAsyncCtx = .{ .rt = rt, .caller = caller, .closure = closure, .this = this, .args = args };
        const f: *const ast.Function = @ptrCast(@alignCast(closure.impl.tree.func));
        if (f.is_generator)
            return coroutine.startGenerator(rt, &coro_vtable, Value.fromClosure(closure), f.is_async, ctx, createAndRunCoro);
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
        if (t.res) |rp| {
            const res_ptr: *const Resolution = @ptrCast(@alignCast(rp));
            m_ptr.res = res_ptr.*;
            m_ptr.res_ptr = res_ptr;
            m_ptr.repl_cells = t.repl_cells;
        }
        m_ptr.module_record = t.module_record;
        const f: *const ast.Function = @ptrCast(@alignCast(t.func));
        try m_ptr.values.appendSlice(rt.gpa, ctx.args);
        try m_ptr.pushClosureCallSync(ctx.closure, f, t.env, ctx.this, 0, 0, null, false);
        co.engine = m_ptr;
        co.state = .running;
        return runCoroMachine(m_ptr, ctx.caller.calls, ctx.caller.depth, .start);
    }

    fn runCoroMachine(m: *Machine, caller_calls: u32, caller_depth: u32, action: CoroAction) Error!coroutine.Outcome {
        const rt = m.rt;
        const prev_caller = rt.closure_caller;
        rt.closure_caller = .{ .ctx = m, .call = Machine.callFromBuiltin, .construct = Machine.constructFromBuiltin };
        defer rt.closure_caller = prev_caller;

        try rt.addRoots(m.roots());
        defer rt.removeRoots(m);

        switch (action) {
            .start => {},
            .@"resume" => |res| {
                m.awaited = .undefined;
                const top: ?Task = if (m.tasks.items.len > 0) m.tasks.items[m.tasks.items.len - 1] else null;
                if (m.at_start) {
                    m.at_start = false; // the first `next()`: its value is dropped (D67)
                } else if (top != null and top.? == .yield_star_wait) {
                    _ = m.tasks.pop();
                    try m.pushTask(.{ .yield_star_step = .{ .iter = top.?.yield_star_wait, .received = res.val, .mode = res.mode } });
                } else if (top != null and top.? == .async_yield_star_wait) {
                    _ = m.tasks.pop();
                    try m.pushTask(.{ .async_yield_star_step = .{ .iter = top.?.async_yield_star_wait, .received = res.val, .mode = res.mode } });
                } else switch (res.mode) {
                    .next => try m.pushVal(res.val),
                    .throw => {
                        _ = rt.throwValue(res.val) catch {};
                        m.unwind(.throw, 0) catch |ue| {
                            if (ue == error.Thrown) return .threw;
                            return ue;
                        };
                    },
                    .@"return" => {
                        // The same completion a `return` statement produces (D67).
                        m.ret = res.val;
                        m.unwind(.@"return", 0) catch |ue| {
                            if (ue != error.Thrown) return ue;
                            m.ret = .undefined;
                            m.unwind(.throw, 0) catch |ue2| {
                                if (ue2 == error.Thrown) return .threw;
                                return ue2;
                            };
                        };
                    },
                }
            },
        }

        const suspended = m.runLoop(0) catch |e| {
            if (e == error.Thrown) return .threw;
            return e;
        };
        if (suspended) {
            m.calls -= caller_calls;
            m.depth -= caller_depth;
            if (m.yielding) {
                m.yielding = false;
                return .{ .yielded = .{ .value = m.awaited, .raw = m.yield_raw } };
            }
            return .{ .awaiting = m.awaited };
        }
        return .{ .returned = m.popVal() };
    }

    fn coroResume(eng: *anyopaque, val: Value, mode: coroutine.ResumeMode) Error!coroutine.Outcome {
        const m: *Machine = @ptrCast(@alignCast(eng));
        return runCoroMachine(m, 0, 0, .{ .@"resume" = .{ .val = val, .mode = mode } });
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
                    try m.pushTask(.{ .bind_target_member_base = .{ .key = mem.key, .is_private = mem.is_private } });
                    try m.pushEval(mem.object);
                },
                .super_member => |k| {
                    _ = try m.requireThis();
                    try m.pushVal(val);
                    switch (k) {
                        .name => |n| try m.pushTask(.{ .bind_target_super_finish = n }),
                        .computed => |ke| {
                            try m.pushTask(.{ .bind_target_super_finish = null });
                            try m.pushEval(ke);
                        },
                        .string, .number => unreachable,
                    }
                },
            },
            .array => {
                const values_base: u32 = @intCast(m.values.items.len);
                const iter = try builtins.getIterator(rt, val);
                try m.pushTask(.{ .array_iter_close = .{ .iter = iter, .values_base = values_base } });
                try m.pushVal(Value.fromObject(iter));
                try m.pushTask(.{ .bind_array_elem = .{ .pat = pat, .idx = 0, .mode = mode } });
            },
            .object => {
                if (val.isUndefined() or val.isNull()) {
                    return rt.throw(.TypeError, &.{ .{ .ascii = "Cannot destructure '" }, .{ .ascii = @tagName(val.tag()) }, .{ .ascii = "'" } });
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
            .atom => |a| Value.fromString(a),
            .index => |i| Value.fromNumber(@floatFromInt(i)),
            .symbol => |s| Value.fromSymbol(s),
        };
    }

    fn valueToKey(v: Value) object.Key {
        return switch (v.unpack()) {
            .string => |s| .{ .atom = @constCast(s) },
            .number => |n| .{ .index = @intFromFloat(n) },
            .symbol => |s| .{ .symbol = @constCast(s) },
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
        if (pr.default) |def| if (v.isUndefined()) {
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
            excluded[i] = switch (ev.unpack()) {
                .string => |s| .{ .atom = @constCast(s) },
                .number => |n| .{ .index = @intFromFloat(n) },
                .symbol => |s| .{ .symbol = @constCast(s) },
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
            .number => |n| object.key(m.rt, Value.fromNumber(n)),
            .computed => unreachable,
        };
    }
};

fn logicalAssignShouldWrite(op: ast.AssignOp, old: Value) bool {
    return switch (op) {
        .logical_and => ops.toBoolean(old),
        .logical_or => !ops.toBoolean(old),
        .nullish => old.isNull() or old.isUndefined(),
        .plain, .compound => unreachable,
    };
}

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
    switch (src.unpack()) {
        .string => |s| {
            for (0..s.units.len) |i| {
                const k: object.Key = .{ .index = @intCast(i) };
                if (keyIn(k, excluded)) continue;
                const ch = try rt.heap.newString(&.{.{ .utf16 = s.units[i..][0..1] }});
                try object.define(rt, dst, k, Value.fromString(ch));
            }
        },
        .object, .closure => {
            const keys = if (src.isObject())
                try object.ownAllKeys(rt, src.asObject())
            else
                try object.ownAllKeysClosure(rt, src.asClosure());
            defer rt.gpa.free(keys);
            const root_vals = try rt.gpa.alloc(Value, 2 + keys.len);
            defer rt.gpa.free(root_vals);
            root_vals[0] = Value.fromObject(dst);
            root_vals[1] = src;
            for (keys, root_vals[2..]) |k, *rv| rv.* = switch (k) {
                .atom => |a| Value.fromString(a),
                .symbol => |s| Value.fromSymbol(s),
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
