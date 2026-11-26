//! Name resolution: turns every variable *name* in the AST into a *number*
//! before anything runs.
//!
//! Output (all in side tables; the AST stays immutable, DESIGN_DECISIONS D20):
//!   refs[ref.id]                 → .local(binding), .capture{binding, index} or .global
//!   bindings[declarator.binding] → kind, slot, scope, index in scope, owning function,
//!                                  and whether an inner function captures it
//!   scopes[id]                   → how many bindings the scope declares (the tree-walker
//!                                  allocates one environment record per scope)
//!   functions[f.id]              → slot count, parameter count, capture list (0 = script)
//!
//! How it works
//! ------------
//! `live` is a stack of the bindings currently in scope, innermost last. A scope is
//! just "everything in `live` from index `scope_start` upward". Entering a scope
//! remembers the old `scope_start` *in a local variable of the Zig function doing
//! the walk*, so the native call stack doubles as the scope stack; leaving the scope
//! truncates `live` back. This gives three properties for free:
//!
//!   * Lookup = scan `live` from the end. The first match is the innermost
//!     binding, so shadowing works with no extra bookkeeping.
//!   * Redeclaration check = scan only `live[scope_start..]`, the *current* scope,
//!     so `let x; { let x; }` (shadowing) is fine and `let x; let x;` is not.
//!   * A binding's slot = its index in `live` minus where its function's bindings
//!     start. Bindings of a finished block are truncated away, so a later sibling
//!     block reuses the same slots; each function numbers its slots from 0.
//!
//! Hoisting: on entering a block we declare *all* of its `let`/`const` bindings (and,
//! in a script or function body, its function declarations) before resolving any
//! statement. So in `let x = 1; { x; let x = 2; }` the inner `x` reference finds the
//! inner binding, which at runtime is still in its temporal dead zone.
//!
//! Functions and captures (M6, DESIGN_DECISIONS D36)
//! ------------------------------------------------
//! A reference that finds a binding of an *outer* function is a capture. The binding
//! is marked `captured` (the VM then keeps it in a heap cell), and every function
//! between the binding's function and the referencing one gets a capture entry for
//! it: the innermost one reads it from its parent's capture list, and so on outward,
//! until the function directly inside the binding's own function reads it from that
//! function's slot. This is the information `make_closure` needs to build a closure.
//! A binding's `captured` flag can be set after some of its references were already
//! resolved, so consumers read it only once resolution has finished.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Diagnostic = @import("diag.zig").Diagnostic;

pub const Error = error{ SyntaxError, Unsupported, OutOfMemory };

pub const ReplKind = enum { let, @"const", @"var", function };

pub const ReplLookup = struct {
    ctx: *const anyopaque,
    get: *const fn (ctx: *const anyopaque, name: []const u8) ?ReplKind,
};

pub const ReplBinding = struct {
    name: []const u8,
    kind: ReplKind,
    is_decl: bool,
};

pub const Resolution = struct {
    refs: []const Ref,
    bindings: []const Binding,
    scopes: []const Scope,
    functions: []const Function,
    repl_bindings: []const ReplBinding = &.{},
    class_names: []const ?u32 = &.{},
    class_brands: []const ?u32 = &.{},
    private_refs: []const Ref = &.{},

    pub const Ref = union(enum) {
        /// A binding of the function containing the reference (binding id).
        local: u32,
        /// A binding of an outer function, reached through entry `index` of the current
        /// function's capture list.
        capture: struct { binding: u32, index: u32 },
        /// Not declared anywhere in the script; looked up by name at runtime.
        global,
        /// A top-level REPL binding (index into `Resolution.repl_bindings`).
        repl: u32,
    };

    pub const BindingKind = enum {
        let,
        @"const",
        @"var",
        param,
        /// A function declaration's name: initialised on scope entry, mutable.
        function,
        /// A named function expression's own name, visible only inside it; writes are
        /// Unsupported (sloppy JS silently ignores them).
        function_name,
    };

    pub const Binding = struct {
        kind: BindingKind,
        /// Frame slot in the owning function. A captured binding's slot holds its cell.
        slot: u32,
        scope: u32,
        /// Position among the bindings of `scope`.
        index: u32,
        function: u32,
        captured: bool = false,
        repl_index: ?u32 = null,
        /// Non-null when this declarator merges into an earlier canonical binding
        /// (duplicate `var`, `var` matching a parameter, or `function` matching `var`).
        alias_of: ?u32 = null,
        /// Non-null for non-module script-level `var` bindings, which live on `globalThis`.
        global_name: ?[]const u8 = null,
    };

    pub const Scope = struct { len: u32 = 0 };

    pub const Function = struct {
        slot_count: u32 = 0,
        param_count: u32 = 0,
        /// Slot of the first parameter (1 in a named function expression, whose own
        /// name comes first; else 0). Parameters occupy consecutive slots.
        param_slot: u32 = 0,
        param_scope: ?u32 = null,
        body_scope: ?u32 = null,
        is_simple_params: bool = true,
        captures: []const Capture = &.{},
        /// Canonical hoisted `var` binding ids belonging to this function/script.
        var_bindings: []const u32 = &.{},
        /// Implicit `arguments` object binding id, lazily allocated only when referenced.
        arguments_binding: ?u32 = null,
        /// Derived constructor's synthetic `this` binding, lazily allocated when an inner arrow captures `this`/`super`.
        this_binding: ?u32 = null,
        /// Capture index of the enclosing derived constructor's `this_binding` for an arrow function.
        lexical_this_capture: ?u32 = null,
    };

    pub const Capture = struct {
        binding: u32,
        from: union(enum) {
            /// The parent function's frame slot (which holds the binding's cell).
            parent_slot: u32,
            /// Entry of the parent function's own capture list.
            parent_capture: u32,
        },
    };

    /// Script slots (function 0).
    pub fn scriptSlots(r: Resolution) u32 {
        return r.functions[0].slot_count;
    }
};

/// `arena` also owns the returned tables; they live exactly as long as the AST.
pub fn resolve(arena: Allocator, script: ast.Script, diag: *Diagnostic) Error!Resolution {
    return resolveWithRepl(arena, script, null, diag);
}

pub fn resolveWithRepl(arena: Allocator, script: ast.Script, repl_lookup: ?ReplLookup, diag: *Diagnostic) Error!Resolution {
    var bindings_list: std.ArrayList(Resolution.Binding) = .empty;
    try bindings_list.resize(arena, script.binding_count);
    const class_names = try arena.alloc(?u32, script.class_count);
    @memset(class_names, null);
    const class_brands = try arena.alloc(?u32, script.class_count);
    @memset(class_brands, null);
    const private_refs = try arena.alloc(Resolution.Ref, script.private_ref_count);
    @memset(private_refs, .global);
    var r: Resolver = .{
        .arena = arena,
        .diag = diag,
        .refs = try arena.alloc(Resolution.Ref, script.ref_count),
        .bindings = bindings_list,
        .functions = try arena.alloc(Resolution.Function, script.function_count),
        .class_names = class_names,
        .class_brands = class_brands,
        .private_refs = private_refs,
        .repl_lookup = repl_lookup,
        .module_mode = script.source_kind == .module,
    };
    @memset(r.refs, .global);
    @memset(r.functions, .{});
    try r.fns.append(arena, .{ .id = 0, .live_start = 0 });
    try r.block(script.statements, .script);
    r.finishFunction();
    // Propagate final slot/captured/repl_index from canonical bindings to any merged `var` aliases.
    for (r.bindings.items) |*b| {
        if (b.alias_of) |canon_id| {
            var c = canon_id;
            while (r.bindings.items[c].alias_of) |next| c = next;
            b.* = r.bindings.items[c];
            b.alias_of = c;
        }
    }
    // Fix up `parent_slot` for any capture targeting a lazily-slotted `arguments` or `this` binding.
    for (r.functions) |*func| {
        const caps = @constCast(func.captures);
        for (caps) |*cap| {
            if (cap.from == .parent_slot) cap.from = .{ .parent_slot = r.bindings.items[cap.binding].slot };
        }
    }
    return .{
        .refs = r.refs,
        .bindings = r.bindings.items,
        .scopes = r.scopes.items,
        .functions = r.functions,
        .repl_bindings = r.repl_bindings.items,
        .class_names = r.class_names,
        .class_brands = r.class_brands,
        .private_refs = r.private_refs,
    };
}

const Live = struct { name: []const u8, binding: u32, is_simple_catch: bool = false };

/// A function being resolved (innermost last in `Resolver.fns`).
const FnState = struct {
    id: u32,
    is_arrow: bool = false,
    has_super_ctor: bool = false,
    /// Index in `live` where this function's bindings start (its slot 0).
    live_start: usize,
    var_scope: u32 = 0,
    max_slots: u32 = 0,
    captures: std.ArrayList(Resolution.Capture) = .empty,
    var_bindings: std.ArrayList(u32) = .empty,
    arguments_binding: ?u32 = null,
    this_binding: ?u32 = null,
};

const PrivateDecl = struct {
    has_get: bool = false,
    has_set: bool = false,
    is_static: bool = false,
    is_field_or_method: bool = false,
};

const PrivateScope = struct {
    brand_binding: u32,
    decls: std.StringHashMapUnmanaged(PrivateDecl),
};

const Resolver = struct {
    arena: Allocator,
    diag: *Diagnostic,
    refs: []Resolution.Ref,
    bindings: std.ArrayList(Resolution.Binding),
    functions: []Resolution.Function,
    class_names: []?u32,
    class_brands: []?u32,
    private_refs: []Resolution.Ref,
    scopes: std.ArrayList(Resolution.Scope) = .empty,
    fns: std.ArrayList(FnState) = .empty,
    live: std.ArrayList(Live) = .empty,
    private_scopes: std.ArrayList(PrivateScope) = .empty,
    repl_lookup: ?ReplLookup = null,
    repl_bindings: std.ArrayList(ReplBinding) = .empty,
    module_mode: bool = false,
    exported_names: std.StringHashMapUnmanaged(void) = .empty,
    scope_start: usize = 0,
    scope: u32 = 0,
    /// Index in `r.live` where the enclosing parameter scope starts (for checking
    /// parameter/body redeclarations in `block(..., .body)`).
    param_scope_start: ?usize = null,
    param_scope_end: usize = 0,

    const Saved = struct { scope_start: usize, live_len: usize, scope: u32 };

    fn enterScope(r: *Resolver) Error!Saved {
        const saved: Saved = .{ .scope_start = r.scope_start, .live_len = r.live.items.len, .scope = r.scope };
        r.scope_start = r.live.items.len;
        r.scope = @intCast(r.scopes.items.len);
        try r.scopes.append(r.arena, .{});
        return saved;
    }

    fn exitScope(r: *Resolver, saved: Saved) void {
        r.live.shrinkRetainingCapacity(saved.live_len);
        r.scope_start = saved.scope_start;
        r.scope = saved.scope;
    }

    fn current(r: *Resolver) *FnState {
        return &r.fns.items[r.fns.items.len - 1];
    }

    fn finishFunction(r: *Resolver) void {
        var f = r.fns.pop().?;
        if (f.arguments_binding) |ab| {
            r.bindings.items[ab].slot = f.max_slots;
            f.max_slots += 1;
            r.functions[f.id].arguments_binding = ab;
        }
        if (f.this_binding) |tb| {
            r.bindings.items[tb].slot = f.max_slots;
            f.max_slots += 1;
            r.functions[f.id].this_binding = tb;
        }
        r.functions[f.id].slot_count = f.max_slots;
        r.functions[f.id].captures = f.captures.items;
        r.functions[f.id].var_bindings = f.var_bindings.items;
    }

    const Range = struct { start: usize, end: usize };

    /// Pre-pass hoisting all `var` declarations within a script/function body (stopping at
    /// nested function/class-static-block boundaries).
    fn hoistVars(r: *Resolver, stmts: []const ast.Stmt, script_scope: bool, param_range: ?Range) Error!void {
        for (stmts) |s| try r.hoistVarStmt(s, script_scope, param_range);
    }

    fn hoistVarStmt(r: *Resolver, s: ast.Stmt, script_scope: bool, param_range: ?Range) Error!void {
        switch (s.data) {
            .declaration => |decl| if (decl.kind == .@"var") {
                for (decl.declarators) |d| try r.hoistVarPattern(d.pattern, script_scope, param_range);
            },
            .export_decl => |exp| switch (exp) {
                .declaration => |decl| if (decl.kind == .@"var") {
                    for (decl.declarators) |d| {
                        try r.hoistVarPattern(d.pattern, true, null);
                        try r.exportPatternNames(d.pattern);
                    }
                },
                else => {},
            },
            .block => |stmts| try r.hoistVars(stmts, script_scope, param_range),
            .labeled => |l| try r.hoistVarStmt(l.body.*, script_scope, param_range),
            .@"if" => |i| {
                try r.hoistVarStmt(i.then.*, script_scope, param_range);
                if (i.@"else") |e| try r.hoistVarStmt(e.*, script_scope, param_range);
            },
            .@"while" => |w| try r.hoistVarStmt(w.body.*, script_scope, param_range),
            .do_while => |dw| try r.hoistVarStmt(dw.body.*, script_scope, param_range),
            .@"for" => |f| {
                if (f.init) |init| switch (init) {
                    .declaration => |decl| if (decl.kind == .@"var") {
                        for (decl.declarators) |d| try r.hoistVarPattern(d.pattern, script_scope, param_range);
                    },
                    .expression => {},
                };
                try r.hoistVarStmt(f.body.*, script_scope, param_range);
            },
            .for_of => |f| {
                if (f.target == .declaration and f.target.declaration.kind == .@"var") {
                    try r.hoistVarPattern(f.target.declaration.pattern, script_scope, param_range);
                }
                try r.hoistVarStmt(f.body.*, script_scope, param_range);
            },
            .for_in => |f| {
                if (f.target == .declaration and f.target.declaration.kind == .@"var") {
                    try r.hoistVarPattern(f.target.declaration.pattern, script_scope, param_range);
                }
                try r.hoistVarStmt(f.body.*, script_scope, param_range);
            },
            .@"switch" => |sw| {
                for (sw.cases) |c| try r.hoistVars(c.body, script_scope, param_range);
            },
            .@"try" => |t| {
                try r.hoistVars(t.body, script_scope, param_range);
                if (t.catch_body) |cb| try r.hoistVars(cb, script_scope, param_range);
                if (t.finally_body) |fb| try r.hoistVars(fb, script_scope, param_range);
            },
            else => {},
        }
    }

    fn hoistVarPattern(r: *Resolver, pat: *const ast.Pattern, script_scope: bool, param_range: ?Range) Error!void {
        switch (pat.data) {
            .binding => |d| try r.hoistVar(d, script_scope, param_range),
            .array => |arr| {
                for (arr.elems) |maybe| if (maybe) |el| try r.hoistVarPattern(el.pattern, script_scope, param_range);
                if (arr.rest) |rest| try r.hoistVarPattern(rest, script_scope, param_range);
            },
            .object => |obj| {
                for (obj.props) |pr| try r.hoistVarPattern(pr.pattern, script_scope, param_range);
                if (obj.rest) |rest| try r.hoistVarPattern(rest, script_scope, param_range);
            },
            .target => unreachable,
        }
    }

    fn hoistVar(r: *Resolver, d: ast.Declarator, script_scope: bool, param_range: ?Range) Error!void {
        // `function f(x) { var x; }` merges into the parameter binding.
        if (param_range) |pr| {
            for (r.live.items[pr.start..pr.end]) |l| {
                if (!std.mem.eql(u8, l.name, d.name)) continue;
                r.bindings.items[d.binding] = r.bindings.items[l.binding];
                r.bindings.items[d.binding].alias_of = l.binding;
                return;
            }
        }
        // Duplicate `var` in the same hoisting scope merges into the canonical binding.
        for (r.live.items[r.scope_start..]) |l| {
            if (!std.mem.eql(u8, l.name, d.name)) continue;
            r.bindings.items[d.binding] = r.bindings.items[l.binding];
            r.bindings.items[d.binding].alias_of = l.binding;
            return;
        }
        // Sloppy script-level `var undefined/NaN/Infinity` is valid in JS (no-op on non-writable global).
        if (script_scope and !r.module_mode and isRestrictedGlobal(d.name)) {
            return r.fail(.{ .unsupported = .syntax }, d.span);
        }
        const f = r.current();
        const scope = &r.scopes.items[r.scope];
        if (script_scope) {
            if (r.module_mode) {
                const repl_idx: u32 = @intCast(r.repl_bindings.items.len);
                try r.repl_bindings.append(r.arena, .{ .name = d.name, .kind = .@"var", .is_decl = true });
                r.bindings.items[d.binding] = .{ .kind = .@"var", .slot = 0, .scope = r.scope, .index = scope.len, .function = f.id, .repl_index = repl_idx };
                scope.len += 1;
                try r.live.append(r.arena, .{ .name = d.name, .binding = d.binding });
                try f.var_bindings.append(r.arena, d.binding);
                return;
            }
            if (r.repl_lookup) |rl| {
                if (rl.get(rl.ctx, d.name)) |existing_kind| {
                    if (existing_kind == .let or existing_kind == .@"const") {
                        return r.fail(.{ .syntax_error = "identifier has already been declared" }, d.span);
                    }
                }
                const repl_idx: u32 = @intCast(r.repl_bindings.items.len);
                try r.repl_bindings.append(r.arena, .{ .name = d.name, .kind = .@"var", .is_decl = true });
                r.bindings.items[d.binding] = .{ .kind = .@"var", .slot = 0, .scope = r.scope, .index = scope.len, .function = f.id, .repl_index = repl_idx };
                scope.len += 1;
                try r.live.append(r.arena, .{ .name = d.name, .binding = d.binding });
                try f.var_bindings.append(r.arena, d.binding);
                return;
            }
            r.bindings.items[d.binding] = .{ .kind = .@"var", .slot = 0, .scope = r.scope, .index = scope.len, .function = f.id, .global_name = d.name };
            scope.len += 1;
            try r.live.append(r.arena, .{ .name = d.name, .binding = d.binding });
            try f.var_bindings.append(r.arena, d.binding);
            return;
        }
        const slot: u32 = @intCast(r.live.items.len - f.live_start);
        r.bindings.items[d.binding] = .{ .kind = .@"var", .slot = slot, .scope = r.scope, .index = scope.len, .function = f.id };
        scope.len += 1;
        try r.live.append(r.arena, .{ .name = d.name, .binding = d.binding });
        try f.var_bindings.append(r.arena, d.binding);
        f.max_slots = @max(f.max_slots, slot + 1);
    }

    /// Checks whether a `var` declaration collides with an intervening lexical binding
    /// (`let`/`const`/`class`/destructuring `catch`) between its position and the hoisting scope.
    fn checkVarConflicts(r: *Resolver, pat: *const ast.Pattern) Error!void {
        switch (pat.data) {
            .binding => |d| {
                const f = r.current();
                const param_scope = r.functions[f.id].param_scope;
                for (r.live.items[f.live_start..]) |l| {
                    const b = r.bindings.items[l.binding];
                    if (b.function != f.id) continue;
                    if (b.scope == f.var_scope) continue;
                    if (b.kind == .function_name) continue; // outer name scope of a named function expression
                    if (param_scope != null and b.scope == param_scope.?) continue;
                    if (!std.mem.eql(u8, l.name, d.name)) continue;
                    // Annex B B.3.5: `catch (e) { var e; }` is valid in sloppy JS with dual bindings.
                    if (l.is_simple_catch) return r.fail(.{ .unsupported = .syntax }, d.span);
                    return r.fail(.{ .syntax_error = "identifier has already been declared" }, d.span);
                }
            },
            .array => |arr| {
                for (arr.elems) |maybe| if (maybe) |el| try r.checkVarConflicts(el.pattern);
                if (arr.rest) |rest| try r.checkVarConflicts(rest);
            },
            .object => |obj| {
                for (obj.props) |pr| try r.checkVarConflicts(pr.pattern);
                if (obj.rest) |rest| try r.checkVarConflicts(rest);
            },
            .target => unreachable,
        }
    }

    /// The script body, a function body or a `{ … }` block: declare everything first,
    /// then resolve.
    fn block(r: *Resolver, stmts: []const ast.Stmt, comptime kind: enum { script, body, block }) Error!void {
        const saved = try r.enterScope();
        defer r.exitScope(saved);
        const param_range: ?Range = if (kind == .body)
            if (r.param_scope_start) |ps| .{ .start = ps, .end = r.param_scope_end } else null
        else
            null;
        if (kind == .script or kind == .body) {
            r.current().var_scope = r.scope;
            try r.hoistVars(stmts, kind == .script, param_range);
        }
        for (stmts) |s| switch (s.data) {
            .declaration => |decl| if (decl.kind != .@"var") {
                for (decl.declarators) |d| try r.declarePattern(d.pattern, if (decl.kind == .let) .let else .@"const", kind == .script, true, param_range);
            },
            .function => |f| try r.declare(f.name.?, .function, kind == .script, true, param_range),
            .class => |c| try r.declare(c.name.?, .let, kind == .script, true, param_range),
            .import_decl => |imp| {
                if (imp.default_binding) |db| try r.declare(db, .@"const", true, true, null);
                if (imp.namespace_binding) |nb| try r.declare(nb, .@"const", true, true, null);
                for (imp.named) |sp| try r.declare(sp.local, .@"const", true, true, null);
            },
            .export_decl => |exp| switch (exp) {
                .declaration => |decl| if (decl.kind != .@"var") {
                    const bk: Resolution.BindingKind = if (decl.kind == .let) .let else .@"const";
                    for (decl.declarators) |d| {
                        try r.declarePattern(d.pattern, bk, true, true, null);
                        try r.exportPatternNames(d.pattern);
                    }
                },
                .function => |f| {
                    try r.declare(f.name.?, .function, true, true, null);
                    try r.addExportName(f.name.?.name, f.name.?.span);
                },
                .class => |c| {
                    try r.declare(c.name.?, .let, true, true, null);
                    try r.addExportName(c.name.?.name, c.name.?.span);
                },
                .named => |specs| for (specs) |sp| try r.addExportName(sp.exported, sp.span),
                .default_expr => |de| {
                    try r.addExportName("default", s.span);
                    try r.declareSyntheticDefault(de.binding);
                },
                .default_function => |df| {
                    try r.addExportName("default", s.span);
                    if (df.func.name) |n| try r.declare(n, .function, true, true, null);
                    try r.declareSyntheticDefault(df.binding);
                },
                .default_class => |dc| {
                    try r.addExportName("default", s.span);
                    if (dc.cls.name) |n| try r.declare(n, .let, true, true, null);
                    try r.declareSyntheticDefault(dc.binding);
                },
                .reexport_named => |rn| for (rn.specifiers) |sp| try r.addExportName(sp.exported, sp.span),
                .reexport_all => |ra| if (ra.namespace) |ns| try r.addExportName(ns, s.span),
            },
            else => {},
        };
        if (kind == .script or kind == .body) {
            for (r.live.items[r.scope_start..]) |l| {
                if (r.bindings.items[l.binding].repl_index == null) {
                    r.functions[r.current().id].body_scope = r.scope;
                    break;
                }
            }
        }
        for (stmts) |s| try r.stmt(s);
    }

    fn declarePattern(
        r: *Resolver,
        pat: *const ast.Pattern,
        kind: Resolution.BindingKind,
        script_scope: bool,
        dup_is_syntax: bool,
        param_range: ?Range,
    ) Error!void {
        switch (pat.data) {
            .binding => |d| try r.declare(d, kind, script_scope, dup_is_syntax, param_range),
            .array => |arr| {
                for (arr.elems) |maybe| if (maybe) |el| try r.declarePattern(el.pattern, kind, script_scope, dup_is_syntax, param_range);
                if (arr.rest) |rest| try r.declarePattern(rest, kind, script_scope, dup_is_syntax, param_range);
            },
            .object => |obj| {
                for (obj.props) |pr| try r.declarePattern(pr.pattern, kind, script_scope, dup_is_syntax, param_range);
                if (obj.rest) |rest| try r.declarePattern(rest, kind, script_scope, dup_is_syntax, param_range);
            },
            .target => unreachable,
        }
    }

    fn declare(
        r: *Resolver,
        d: ast.Declarator,
        kind: Resolution.BindingKind,
        script_scope: bool,
        dup_is_syntax: bool,
        param_range: ?Range,
    ) Error!void {
        if (param_range) |pr| {
            for (r.live.items[pr.start..pr.end]) |l| {
                if (!std.mem.eql(u8, l.name, d.name)) continue;
                if (kind == .function) return r.fail(.{ .unsupported = .duplicate_function }, d.span);
                return r.fail(.{ .syntax_error = "identifier has already been declared" }, d.span);
            }
        }
        for (r.live.items[r.scope_start..]) |l| {
            if (!std.mem.eql(u8, l.name, d.name)) continue;
            const old = r.bindings.items[l.binding].kind;
            // Sloppy JS allows duplicate simple params (the later wins); non-simple params are SyntaxError.
            if (kind == .param and old == .param and !dup_is_syntax) return r.fail(.{ .unsupported = .duplicate_parameter }, d.span);
            if (kind == .function and old == .@"var" and !r.module_mode) {
                r.bindings.items[d.binding] = r.bindings.items[l.binding];
                r.bindings.items[d.binding].alias_of = l.binding;
                return;
            }
            if (kind == .function and (old == .function or old == .param)) return r.fail(.{ .unsupported = .duplicate_function }, d.span);
            return r.fail(.{ .syntax_error = "identifier has already been declared" }, d.span);
        }
        // At script level these would collide with non-configurable properties of the
        // global object: node rejects `let NaN` before running anything (SyntaxError);
        // for a function declaration it is less clear-cut, so Unsupported.
        if (script_scope and !r.module_mode and isRestrictedGlobal(d.name)) {
            if (kind == .function) return r.fail(.{ .unsupported = .duplicate_function }, d.span);
            return r.fail(.{ .syntax_error = "cannot redeclare a non-configurable global at script level" }, d.span);
        }
        const f = r.current();
        const scope = &r.scopes.items[r.scope];
        if (script_scope) {
            if (r.module_mode) {
                const repl_idx: u32 = @intCast(r.repl_bindings.items.len);
                const repl_kind: ReplKind = switch (kind) {
                    .let => .let,
                    .@"const" => .@"const",
                    .function => .function,
                    else => unreachable,
                };
                try r.repl_bindings.append(r.arena, .{ .name = d.name, .kind = repl_kind, .is_decl = true });
                r.bindings.items[d.binding] = .{ .kind = kind, .slot = 0, .scope = r.scope, .index = scope.len, .function = f.id, .repl_index = repl_idx };
                scope.len += 1;
                try r.live.append(r.arena, .{ .name = d.name, .binding = d.binding });
                return;
            }
            if (r.repl_lookup) |rl| {
                if (rl.get(rl.ctx, d.name)) |existing_kind| {
                    if (existing_kind == .@"const") {
                        return r.fail(.{ .syntax_error = "identifier has already been declared" }, d.span);
                    }
                }
                const repl_idx: u32 = @intCast(r.repl_bindings.items.len);
                const repl_kind: ReplKind = switch (kind) {
                    .let => .let,
                    .@"const" => .@"const",
                    .function => .function,
                    else => unreachable,
                };
                try r.repl_bindings.append(r.arena, .{ .name = d.name, .kind = repl_kind, .is_decl = true });
                r.bindings.items[d.binding] = .{ .kind = kind, .slot = 0, .scope = r.scope, .index = scope.len, .function = f.id, .repl_index = repl_idx };
                scope.len += 1;
                try r.live.append(r.arena, .{ .name = d.name, .binding = d.binding });
                return;
            }
        }
        const slot: u32 = @intCast(r.live.items.len - f.live_start);
        r.bindings.items[d.binding] = .{ .kind = kind, .slot = slot, .scope = r.scope, .index = scope.len, .function = f.id };
        scope.len += 1;
        try r.live.append(r.arena, .{ .name = d.name, .binding = d.binding });
        f.max_slots = @max(f.max_slots, slot + 1);
    }

    fn stmt(r: *Resolver, s: ast.Stmt) Error!void {
        switch (s.data) {
            .empty, .@"break", .@"continue" => {},
            .labeled => |l| try r.stmt(l.body.*),
            .expression => |e| try r.expr(e),
            // Already declared by the enclosing block (or hoisted for `var`); only conflict checks,
            // initialisers, and pattern exprs remain.
            .declaration => |decl| for (decl.declarators) |d| {
                if (decl.kind == .@"var") try r.checkVarConflicts(d.pattern);
                if (d.init) |init| try r.expr(init);
                try r.resolvePatternExprs(d.pattern);
            },
            .function => |f| try r.function(f),
            .class => |c| try r.resolveClass(c, false),
            .@"return" => |v| if (v) |e| try r.expr(e),
            .throw => |e| try r.expr(e),
            .@"try" => |t| {
                try r.block(t.body, .block);
                if (t.catch_body) |cb| {
                    const saved = try r.enterScope();
                    defer r.exitScope(saved);
                    if (t.catch_param) |cp| {
                        try r.declarePattern(cp, .let, false, true, null);
                        if (cp.data == .binding) r.live.items[r.live.items.len - 1].is_simple_catch = true;
                        try r.resolvePatternExprs(cp);
                    }
                    for (cb) |cs| switch (cs.data) {
                        .declaration => |decl| if (decl.kind != .@"var") {
                            for (decl.declarators) |d| try r.declarePattern(d.pattern, if (decl.kind == .let) .let else .@"const", false, true, null);
                        },
                        .function => |f| try r.declare(f.name.?, .function, false, true, null),
                        .class => |c| try r.declare(c.name.?, .let, false, true, null),
                        else => {},
                    };
                    for (cb) |cs| try r.stmt(cs);
                }
                if (t.finally_body) |fb| try r.block(fb, .block);
            },
            .block => |stmts| try r.block(stmts, .block),
            .@"if" => |i| {
                try r.expr(i.cond);
                try r.stmt(i.then.*);
                if (i.@"else") |e| try r.stmt(e.*);
            },
            .@"while" => |w| {
                try r.expr(w.cond);
                try r.stmt(w.body.*);
            },
            .do_while => |dw| {
                try r.stmt(dw.body.*);
                try r.expr(dw.cond);
            },
            .@"switch" => |sw| {
                try r.expr(sw.discriminant);
                const saved = try r.enterScope();
                defer r.exitScope(saved);
                // All case clauses share one lexical scope (TDZ across cases).
                for (sw.cases) |c| {
                    for (c.body) |st| switch (st.data) {
                        .declaration => |d| if (d.kind != .@"var") {
                            for (d.declarators) |decl| try r.declarePattern(decl.pattern, if (d.kind == .let) .let else .@"const", false, true, null);
                        },
                        .function => |f| try r.declare(f.name.?, .function, false, true, null),
                        .class => |cl| try r.declare(cl.name.?, .let, false, true, null),
                        else => {},
                    };
                }
                for (sw.cases) |c| {
                    if (c.test_expr) |te| try r.expr(te);
                    for (c.body) |st| try r.stmt(st);
                }
            },
            .@"for" => |f| {
                // The head declaration gets its own scope, enclosing the body (whose
                // block, if any, is one more scope), so `for (let i;;) { let i; }` is legal.
                const saved = try r.enterScope();
                defer r.exitScope(saved);
                if (f.init) |init| switch (init) {
                    .declaration => |decl| {
                        if (decl.kind == .@"var") {
                            for (decl.declarators) |d| try r.checkVarConflicts(d.pattern);
                        } else {
                            for (decl.declarators) |d| try r.declarePattern(d.pattern, if (decl.kind == .let) .let else .@"const", false, true, null);
                        }
                        for (decl.declarators) |d| {
                            if (d.init) |e| try r.expr(e);
                            try r.resolvePatternExprs(d.pattern);
                        }
                    },
                    .expression => |e| try r.expr(e),
                };
                if (f.cond) |e| try r.expr(e);
                if (f.update) |e| try r.expr(e);
                try r.stmt(f.body.*);
            },
            .for_of => |f| try r.resolveForEach(f.target, f.iterable, f.body),
            .for_in => |f| try r.resolveForEach(f.target, f.object, f.body),
            .import_decl => {},
            .export_decl => |exp| switch (exp) {
                .declaration => |decl| for (decl.declarators) |d| {
                    if (d.init) |init| try r.expr(init);
                    try r.resolvePatternExprs(d.pattern);
                },
                .function => |f| try r.function(f),
                .class => |c| try r.resolveClass(c, false),
                .named => |specs| for (specs) |sp| {
                    const ref_res = try r.lookup(sp.local.name);
                    if (ref_res == .global) return r.fail(.{ .syntax_error = "Exported name is not defined" }, sp.local.span);
                    r.refs[sp.local.id] = ref_res;
                },
                .default_expr => |de| try r.expr(de.expr),
                .default_function => |df| try r.function(df.func),
                .default_class => |dc| try r.resolveClass(dc.cls, false),
                .reexport_named, .reexport_all => {},
            },
        }
    }

    fn addExportName(r: *Resolver, name: []const u8, s: ast.Span) Error!void {
        if (r.exported_names.contains(name)) {
            return r.fail(.{ .syntax_error = "Duplicate export" }, s);
        }
        try r.exported_names.put(r.arena, name, {});
    }

    fn exportPatternNames(r: *Resolver, pat: *const ast.Pattern) Error!void {
        switch (pat.data) {
            .binding => |d| try r.addExportName(d.name, d.span),
            .array => |arr| {
                for (arr.elems) |maybe| if (maybe) |el| try r.exportPatternNames(el.pattern);
                if (arr.rest) |rest| try r.exportPatternNames(rest);
            },
            .object => |obj| {
                for (obj.props) |pr| try r.exportPatternNames(pr.pattern);
                if (obj.rest) |rest| try r.exportPatternNames(rest);
            },
            .target => unreachable,
        }
    }

    fn declareSyntheticDefault(r: *Resolver, binding_id: u32) Error!void {
        const repl_idx: u32 = @intCast(r.repl_bindings.items.len);
        try r.repl_bindings.append(r.arena, .{ .name = "*default*", .kind = .@"const", .is_decl = true });
        r.bindings.items[binding_id] = .{ .kind = .@"const", .slot = 0, .scope = r.scope, .index = 0, .function = 0, .repl_index = repl_idx };
    }

    fn resolveForEach(r: *Resolver, for_target: ast.ForOfTarget, rhs: *const ast.Expr, body: *const ast.Stmt) Error!void {
        const saved = try r.enterScope();
        defer r.exitScope(saved);
        switch (for_target) {
            .declaration => |d| {
                if (d.kind == .@"var") {
                    try r.checkVarConflicts(d.pattern);
                } else {
                    try r.declarePattern(d.pattern, if (d.kind == .let) .let else .@"const", false, true, null);
                }
                try r.expr(rhs);
                try r.resolvePatternExprs(d.pattern);
            },
            .target => |t| {
                try r.expr(rhs);
                try r.resolvePatternExprs(t);
            },
        }
        try r.stmt(body.*);
    }

    /// A function's own scopes: for a named expression, one holding just its name, then
    /// a parameter scope (for parameters and their defaults, isolated from body `let`/`const`),
    /// then the body scope.
    fn function(r: *Resolver, f: *const ast.Function) Error!void {
        try r.fns.append(r.arena, .{ .id = f.id, .is_arrow = f.is_arrow, .has_super_ctor = f.has_super_ctor, .live_start = r.live.items.len });
        const name_scope: ?Saved = if (f.kind == .expression and f.name != null) try r.enterScope() else null;
        if (name_scope != null) try r.declare(f.name.?, .function_name, false, true, null);
        const param_saved = try r.enterScope();
        r.functions[f.id].param_scope = r.scope;
        const is_simple = for (f.params) |p| {
            if (p.pattern.data != .binding or p.default != null or p.is_rest) break false;
        } else true;
        r.functions[f.id].is_simple_params = is_simple;
        r.functions[f.id].param_slot = @intCast(r.live.items.len - r.current().live_start);
        r.functions[f.id].param_count = if (is_simple) @intCast(f.params.len) else 0;
        for (f.params) |p| try r.declarePattern(p.pattern, .param, false, !is_simple or f.is_strict or f.is_method or f.is_class_constructor, null);
        for (f.params) |p| {
            try r.resolvePatternExprs(p.pattern);
            if (p.default) |def| try r.expr(def);
        }
        const prev_pstart = r.param_scope_start;
        const prev_pend = r.param_scope_end;
        r.param_scope_start = r.scope_start;
        r.param_scope_end = r.live.items.len;
        defer {
            r.param_scope_start = prev_pstart;
            r.param_scope_end = prev_pend;
        }
        try r.block(f.body, .body);
        r.exitScope(param_saved);
        if (name_scope) |sv| r.exitScope(sv);
        r.finishFunction();
    }

    fn resolvePatternExprs(r: *Resolver, pat: *const ast.Pattern) Error!void {
        switch (pat.data) {
            .binding => {},
            .target => |t| try r.assignTarget(t),
            .array => |arr| {
                for (arr.elems) |maybe| if (maybe) |el| {
                    try r.resolvePatternExprs(el.pattern);
                    if (el.default) |def| try r.expr(def);
                };
                if (arr.rest) |rest| try r.resolvePatternExprs(rest);
            },
            .object => |obj| {
                for (obj.props) |pr| {
                    if (pr.key == .computed) try r.expr(pr.key.computed);
                    try r.resolvePatternExprs(pr.pattern);
                    if (pr.default) |def| try r.expr(def);
                }
                if (obj.rest) |rest| try r.resolvePatternExprs(rest);
            },
        }
    }

    fn expr(r: *Resolver, e: *const ast.Expr) Error!void {
        switch (e.data) {
            .number, .bigint, .string, .regexp, .boolean, .null => {},
            .template => |t| for (t.exprs) |ex| try r.expr(ex),
            .tagged_template => |tt| {
                try r.expr(tt.callee);
                for (tt.exprs) |ex| try r.expr(ex);
            },
            .identifier => |ref| r.refs[ref.id] = try r.lookup(ref.name),
            .unary => |u| try r.expr(u.operand),
            .binary => |b| {
                try r.expr(b.lhs);
                try r.expr(b.rhs);
            },
            .conditional => |c| {
                try r.expr(c.cond);
                try r.expr(c.then_expr);
                try r.expr(c.else_expr);
            },
            .assign => |a| {
                try r.expr(a.value);
                try r.assignTarget(a.target);
            },
            .assign_pattern => |ap| {
                try r.expr(ap.value);
                try r.resolvePatternExprs(ap.pattern);
            },
            .spread => |inner| try r.expr(inner),
            .hole => {},
            .update => |u| try r.assignTarget(u.target),
            .member, .delete => |m| try r.member(m),
            .optional_chain, .delete_optional => |oc| try r.optionalChain(oc),
            .object => |props| for (props) |prop| switch (prop) {
                .prop => |pr| {
                    if (pr.key == .computed) try r.expr(pr.key.computed);
                    try r.expr(pr.value);
                },
                .spread => |sp| try r.expr(sp.expr),
                .cover_init => unreachable,
            },
            .array => |items| for (items) |item| try r.expr(item),
            .this => try r.resolveLexicalThis(),
            .await => |inner| try r.expr(inner),
            .yield => |y| if (y.value) |v| try r.expr(v),
            .call, .new_call => |c| {
                try r.expr(c.callee);
                for (c.args) |arg| try r.expr(arg);
            },
            .function => |f| try r.function(f),
            .class => |c| try r.resolveClass(c, true),
            .super_call => |args| for (args) |arg| try r.expr(arg),
            .super_call_forward => |ref| r.refs[ref.id] = try r.lookup(ref.name),
            .super_member => |k| {
                try r.resolveLexicalThis();
                if (k == .computed) try r.expr(k.computed);
            },
            .delete_super => {},
            .private_in => |pi| {
                try r.resolvePrivate(pi.name, pi.private_ref, pi.span);
                try r.expr(pi.rhs);
            },
            .import_meta => {},
            .dynamic_import => |spec| try r.expr(spec),
        }
    }

    fn resolveLexicalThis(r: *Resolver) Error!void {
        var owner_idx = r.fns.items.len - 1;
        while (owner_idx > 0 and r.fns.items[owner_idx].is_arrow) : (owner_idx -= 1) {}
        if (owner_idx == r.fns.items.len - 1) return;
        const owner = &r.fns.items[owner_idx];
        if (!owner.has_super_ctor) return;
        const tb: u32 = owner.this_binding orelse blk: {
            const ps = r.functions[owner.id].param_scope.?;
            const scope = &r.scopes.items[ps];
            const new_id: u32 = @intCast(r.bindings.items.len);
            try r.bindings.append(r.arena, .{
                .kind = .@"const",
                .slot = 0, // assigned in finishFunction after max_slots settles
                .scope = ps,
                .index = scope.len,
                .function = owner.id,
                .captured = true,
            });
            scope.len += 1;
            owner.this_binding = new_id;
            r.functions[owner.id].this_binding = new_id;
            break :blk new_id;
        };
        const cur_level = r.fns.items.len - 1;
        const cap_idx = try r.captureIndex(cur_level, tb);
        r.functions[r.current().id].lexical_this_capture = cap_idx;
        r.functions[r.current().id].this_binding = tb;
    }

    fn declareSynthetic(r: *Resolver, name: []const u8, kind: Resolution.BindingKind) Error!u32 {
        const f = r.current();
        const scope = &r.scopes.items[r.scope];
        const new_id: u32 = @intCast(r.bindings.items.len);
        const slot: u32 = @intCast(r.live.items.len - f.live_start);
        try r.bindings.append(r.arena, .{
            .kind = kind,
            .slot = slot,
            .scope = r.scope,
            .index = scope.len,
            .function = f.id,
        });
        scope.len += 1;
        try r.live.append(r.arena, .{ .name = name, .binding = new_id });
        f.max_slots = @max(f.max_slots, slot + 1);
        return new_id;
    }

    fn resolvePrivate(r: *Resolver, name: []const u8, private_ref_id: u32, s: ast.Span) Error!void {
        var i = r.private_scopes.items.len;
        while (i > 0) {
            i -= 1;
            const ps = r.private_scopes.items[i];
            if (!ps.decls.contains(name)) continue;
            const b = ps.brand_binding;
            if (r.bindings.items[b].function == r.current().id) {
                r.private_refs[private_ref_id] = .{ .local = b };
            } else {
                r.bindings.items[b].captured = true;
                r.private_refs[private_ref_id] = .{ .capture = .{ .binding = b, .index = try r.captureIndex(r.fns.items.len - 1, b) } };
            }
            return;
        }
        return r.fail(.{ .syntax_error = "Private field must be declared in an enclosing class" }, s);
    }

    fn addPrivateDecl(r: *Resolver, map: *std.StringHashMapUnmanaged(PrivateDecl), name: []const u8, decl: PrivateDecl, s: ast.Span) Error!void {
        const gop = try map.getOrPut(r.arena, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = decl;
            return;
        }
        const cur = gop.value_ptr.*;
        if (cur.is_field_or_method or decl.is_field_or_method or cur.is_static != decl.is_static) {
            return r.fail(.{ .syntax_error = "Identifier has already been declared" }, s);
        }
        if ((decl.has_get and cur.has_get) or (decl.has_set and cur.has_set)) {
            return r.fail(.{ .syntax_error = "Identifier has already been declared" }, s);
        }
        if (decl.has_get) gop.value_ptr.has_get = true;
        if (decl.has_set) gop.value_ptr.has_set = true;
    }

    fn resolveClass(r: *Resolver, c: *const ast.Class, is_expr: bool) Error!void {
        const has_private = for (c.methods) |m| {
            if (m.is_private) break true;
        } else for (c.instance_fields) |f| {
            if (f.is_private) break true;
        } else for (c.static_fields) |f| {
            if (f.is_private) break true;
        } else false;

        const saved: ?Saved = if (c.name != null or has_private) try r.enterScope() else null;
        defer if (saved) |s| r.exitScope(s);

        if (c.name) |nd| {
            if (is_expr) {
                try r.declare(nd, .@"const", false, false, null);
                r.class_names[c.id] = nd.binding;
            } else {
                r.class_names[c.id] = try r.declareSynthetic(nd.name, .@"const");
            }
        }
        if (c.super_class) |sc| try r.expr(sc);

        if (has_private) {
            var priv_map: std.StringHashMapUnmanaged(PrivateDecl) = .empty;
            for (c.methods) |m| {
                if (!m.is_private) continue;
                try r.addPrivateDecl(&priv_map, m.key.name, .{
                    .has_get = m.kind == .getter,
                    .has_set = m.kind == .setter,
                    .is_static = m.is_static,
                    .is_field_or_method = m.kind == .method,
                }, m.span);
            }
            for (c.instance_fields) |f| {
                if (!f.is_private) continue;
                try r.addPrivateDecl(&priv_map, f.key.name, .{ .is_static = false, .is_field_or_method = true }, f.span);
            }
            for (c.static_fields) |f| {
                if (!f.is_private) continue;
                try r.addPrivateDecl(&priv_map, f.key.name, .{ .is_static = true, .is_field_or_method = true }, f.span);
            }
            const brand_b = try r.declareSynthetic("", .@"const");
            r.class_brands[c.id] = brand_b;
            try r.private_scopes.append(r.arena, .{ .brand_binding = brand_b, .decls = priv_map });
        }
        defer if (has_private) {
            _ = r.private_scopes.pop();
        };

        try r.function(c.constructor);
        if (c.elements.len > 0) {
            for (c.elements) |el| switch (el) {
                .method => |idx| {
                    const m = c.methods[idx];
                    if (m.key == .computed) try r.expr(m.key.computed);
                    try r.function(m.func);
                },
                .instance_field => |idx| {
                    const f = c.instance_fields[idx];
                    if (f.key == .computed) try r.expr(f.key.computed);
                    if (f.init) |init_fn| try r.function(init_fn);
                },
                .static_field => |idx| {
                    const f = c.static_fields[idx];
                    if (f.key == .computed) try r.expr(f.key.computed);
                    if (f.init) |init_fn| try r.function(init_fn);
                },
            };
        } else {
            for (c.methods) |m| {
                if (m.key == .computed) try r.expr(m.key.computed);
                try r.function(m.func);
            }
            for (c.instance_fields) |f| {
                if (f.key == .computed) try r.expr(f.key.computed);
                if (f.init) |init_fn| try r.function(init_fn);
            }
            for (c.static_fields) |f| {
                if (f.key == .computed) try r.expr(f.key.computed);
                if (f.init) |init_fn| try r.function(init_fn);
            }
        }
        for (c.static_items) |item| switch (item) {
            .field => {},
            .block => |blk_fn| try r.function(blk_fn),
        };
    }

    fn member(r: *Resolver, m: ast.Member) Error!void {
        try r.expr(m.object);
        if (m.is_private) {
            try r.resolvePrivate(m.key.name, m.private_ref, m.object.span);
        } else if (m.key == .computed) try r.expr(m.key.computed);
    }

    fn optionalChain(r: *Resolver, oc: ast.OptionalChain) Error!void {
        try r.expr(oc.base);
        for (oc.steps) |s| switch (s.kind) {
            .prop => {},
            .private_prop => |pp| try r.resolvePrivate(pp.name, pp.private_ref, oc.base.span),
            .elem => |e| try r.expr(e),
            .call => |args| for (args) |arg| try r.expr(arg),
        };
    }

    fn assignTarget(r: *Resolver, t: ast.Target) Error!void {
        switch (t) {
            .ref => |ref| try r.target(ref),
            .member => |m| try r.member(m),
            .super_member => |k| {
                try r.resolveLexicalThis();
                if (k == .computed) try r.expr(k.computed);
            },
        }
    }

    /// Assignment to a `const` is *not* rejected here: JS throws a TypeError only if
    /// the assignment actually executes (`if (false) c = 2;` is fine), so that check
    /// belongs to the runtime (M3). Assignment to an undeclared name is rejected:
    /// sloppy JS would silently create a global, which ZQJS doesn't do (decision B).
    fn target(r: *Resolver, ref: ast.Ref) Error!void {
        const res = try r.lookup(ref.name);
        const b = switch (res) {
            .global => {
                r.refs[ref.id] = res;
                return;
            },
            .local => |b| b,
            .capture => |c| c.binding,
            .repl => {
                r.refs[ref.id] = res;
                return;
            },
        };
        if (r.bindings.items[b].kind == .function_name) return r.fail(.{ .unsupported = .function_name_assignment }, ref.span);
        r.refs[ref.id] = res;
    }

    fn lookup(r: *Resolver, name: []const u8) Error!Resolution.Ref {
        // Find the nearest enclosing non-arrow function for implicit `arguments` resolution.
        var arg_fn_idx: ?usize = null;
        if (std.mem.eql(u8, name, "arguments")) {
            var fi = r.fns.items.len;
            while (fi > 1) {
                fi -= 1;
                if (!r.fns.items[fi].is_arrow) {
                    arg_fn_idx = fi;
                    break;
                }
            }
        }
        const arg_floor: usize = if (arg_fn_idx) |fi| r.fns.items[fi].live_start else 0;

        var i = r.live.items.len;
        while (i > arg_floor) {
            i -= 1;
            if (!std.mem.eql(u8, r.live.items[i].name, name)) continue;
            const b = r.live.items[i].binding;
            if (r.bindings.items[b].global_name != null) return .global;
            if (r.bindings.items[b].repl_index) |repl_idx| return .{ .repl = repl_idx };
            if (r.bindings.items[b].function == r.current().id) return .{ .local = b };
            r.bindings.items[b].captured = true;
            return .{ .capture = .{ .binding = b, .index = try r.captureIndex(r.fns.items.len - 1, b) } };
        }
        // No local binding shadowed `arguments` inside the enclosing non-arrow function:
        // lazily materialize the implicit `arguments` binding on that function.
        if (arg_fn_idx) |fi| {
            const target_fn = &r.fns.items[fi];
            const arg_b: u32 = target_fn.arguments_binding orelse blk: {
                const ps = r.functions[target_fn.id].param_scope.?;
                const scope = &r.scopes.items[ps];
                const new_id: u32 = @intCast(r.bindings.items.len);
                try r.bindings.append(r.arena, .{
                    .kind = .let,
                    .slot = 0, // assigned in finishFunction after max_slots settles
                    .scope = ps,
                    .index = scope.len,
                    .function = target_fn.id,
                });
                scope.len += 1;
                target_fn.arguments_binding = new_id;
                break :blk new_id;
            };
            if (target_fn.id == r.current().id) return .{ .local = arg_b };
            r.bindings.items[arg_b].captured = true;
            return .{ .capture = .{ .binding = arg_b, .index = try r.captureIndex(r.fns.items.len - 1, arg_b) } };
        }
        if (r.repl_lookup) |rl| {
            if (rl.get(rl.ctx, name)) |rk| {
                for (r.repl_bindings.items, 0..) |rb, idx| {
                    if (!rb.is_decl and std.mem.eql(u8, rb.name, name)) return .{ .repl = @intCast(idx) };
                }
                const idx: u32 = @intCast(r.repl_bindings.items.len);
                try r.repl_bindings.append(r.arena, .{ .name = name, .kind = rk, .is_decl = false });
                return .{ .repl = idx };
            }
        }
        return .global;
    }

    /// Index of binding `b` in the capture list of function `fns[level]`, adding it
    /// (and, recursively, to the enclosing functions) if needed.
    fn captureIndex(r: *Resolver, level: usize, b: u32) Error!u32 {
        const f = &r.fns.items[level];
        for (f.captures.items, 0..) |c, i| if (c.binding == b) return @intCast(i);
        // `b` belongs to an enclosing function, so level > its function's level ≥ 0.
        const parent = r.fns.items[level - 1];
        const capture: Resolution.Capture = if (r.bindings.items[b].function == parent.id)
            .{ .binding = b, .from = .{ .parent_slot = r.bindings.items[b].slot } }
        else
            .{ .binding = b, .from = .{ .parent_capture = try r.captureIndex(level - 1, b) } };
        // `f` is still valid: the recursion appends to other functions' capture lists,
        // never to `fns` itself.
        try f.captures.append(r.arena, capture);
        return @intCast(f.captures.items.len - 1);
    }

    fn fail(r: *Resolver, detail: Diagnostic.Detail, s: ast.Span) Error {
        r.diag.* = .{ .detail = detail, .start = s.start, .end = s.end };
        return switch (detail) {
            .syntax_error => error.SyntaxError,
            .unsupported => error.Unsupported,
            .limit_exceeded => unreachable, // the resolver enforces no limits
        };
    }
};

fn isRestrictedGlobal(name: []const u8) bool {
    return std.mem.eql(u8, name, "undefined") or std.mem.eql(u8, name, "NaN") or std.mem.eql(u8, name, "Infinity");
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const parse = @import("parser.zig").parse;

const Resolved = struct { script: ast.Script, res: Resolution };

fn resolveSource(arena: Allocator, source: []const u8, diag: *Diagnostic) !Resolved {
    const script = try parse(arena, source, .{}, diag);
    return .{ .script = script, .res = try resolve(arena, script, diag) };
}

/// The binding the n-th reference (in source order) resolves to, or null for a global.
fn refBinding(r: Resolved, n: u32) ?u32 {
    return switch (r.res.refs[n]) {
        .local => |b| b,
        .capture => |c| c.binding,
        .global, .repl => null,
    };
}

fn expectFailure(source: []const u8, err: anyerror, detail: Diagnostic.Detail) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    try testing.expectError(err, resolveSource(arena.allocator(), source, &d));
    try testing.expectEqualDeep(detail, d.detail);
}

test "shadowing is allowed; each declaration gets its own binding and slot" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const r = try resolveSource(arena.allocator(), "let x = 1; { let x = 2; x; } x;", &d);
    try testing.expectEqual(@as(u32, 0), r.res.bindings[0].slot);
    try testing.expectEqual(@as(u32, 1), r.res.bindings[1].slot);
    try testing.expectEqual(@as(?u32, 1), refBinding(r, 0)); // inside the block: inner x
    try testing.expectEqual(@as(?u32, 0), refBinding(r, 1)); // after the block: outer x
    try testing.expectEqual(@as(u32, 2), r.res.scriptSlots());
}

test "redeclaration in the same scope is a SyntaxError" {
    const already: Diagnostic.Detail = .{ .syntax_error = "identifier has already been declared" };
    try expectFailure("let x; let x;", error.SyntaxError, already);
    try expectFailure("const x = 1; let x;", error.SyntaxError, already);
    try expectFailure("let x = 1, x = 2;", error.SyntaxError, already);
    try expectFailure("{ let a; const a = 1; }", error.SyntaxError, already);
    try expectFailure("for (let i = 0, i = 1;;) {}", error.SyntaxError, already);
}

test "same name in different scopes is not a redeclaration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    for ([_][]const u8{
        "{ let x; } let x;",
        "let x; { let x; { let x; } }",
        "{ let x; } { let x; }",
        "for (let i = 0;;) { let i; }",
        "for (let i = 0;;) {} let i;",
        "let i; for (let i = 0;;) {}",
    }) |src| _ = try resolveSource(arena.allocator(), src, &d);
}

test "declarations are hoisted to the top of their block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    // The inner `x` reference precedes the inner declaration but still resolves to it.
    const r = try resolveSource(arena.allocator(), "let x = 1; { x; let x = 2; }", &d);
    try testing.expectEqual(@as(?u32, 1), refBinding(r, 0));
    // `let y = y` refers to itself (a TDZ error at runtime), not to an outer y.
    const r2 = try resolveSource(arena.allocator(), "let y = 1; { let y = y; }", &d);
    try testing.expectEqual(@as(?u32, 1), refBinding(r2, 0));
}

test "sibling blocks reuse slots" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const r = try resolveSource(arena.allocator(), "let a; { let b; let c; } { let e; }", &d);
    try testing.expectEqual(@as(u32, 0), r.res.bindings[0].slot); // a
    try testing.expectEqual(@as(u32, 1), r.res.bindings[1].slot); // b
    try testing.expectEqual(@as(u32, 2), r.res.bindings[2].slot); // c
    try testing.expectEqual(@as(u32, 1), r.res.bindings[3].slot); // e reuses b's slot
    try testing.expectEqual(@as(u32, 3), r.res.scriptSlots());
}

test "nested scopes never reuse a slot that is still live" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    // Bindings in declaration order: a, b, c, e, f, g.
    const r = try resolveSource(arena.allocator(),
        \\let a;
        \\{ let b; { let c; a; b; c; } { let e; { let f; a; b; e; f; } } }
        \\{ let g; a; }
    , &d);
    const slot = struct {
        fn of(res: Resolution, binding: u32) u32 {
            return res.bindings[binding].slot;
        }
    }.of;
    const a = slot(r.res, 0);
    const b = slot(r.res, 1);
    const c = slot(r.res, 2);
    const e = slot(r.res, 3);
    const f = slot(r.res, 4);
    const g = slot(r.res, 5);
    // While c is live, a and b are live too: all three distinct.
    try testing.expect(a != b and a != c and b != c);
    // While f is live, a, b and e are live.
    try testing.expect(f != a and f != b and f != e and e != a and e != b);
    // c's block has ended before e's starts, so e may reuse c's slot (and does).
    try testing.expectEqual(c, e);
    // Only a is live next to g.
    try testing.expect(g != a);
    try testing.expectEqual(b, g);
    try testing.expectEqual(@as(u32, 4), r.res.scriptSlots()); // a, b, e, f at the deepest point
    // References inside the nested blocks still find the outer bindings.
    const expected = [_]u32{ 0, 1, 2, 0, 1, 3, 4, 0 }; // a b c | a b e f | a
    for (expected, 0..) |binding, n| try testing.expectEqual(@as(?u32, binding), refBinding(r, @intCast(n)));
}

test "a reference before its declaration resolves to the inner binding, not a global" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    // No outer x at all: without hoisting this would wrongly become a global read.
    const r = try resolveSource(arena.allocator(), "{ x; let x = 1; } x;", &d);
    try testing.expectEqual(@as(?u32, 0), refBinding(r, 0)); // inside: the block's x (TDZ at runtime)
    try testing.expectEqual(@as(?u32, null), refBinding(r, 1)); // after the block: a global
}

test "a body declaration may shadow the for-head binding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const r = try resolveSource(arena.allocator(), "for (let i = 0; i < 2; i++) { let i; }", &d);
    try testing.expectEqual(@as(usize, 2), r.res.bindings.len);
    try testing.expect(r.res.bindings[0].slot != r.res.bindings[1].slot); // both live in the body
    try testing.expectEqual(@as(?u32, 0), refBinding(r, 0)); // `i < 2` → head i
    try testing.expectEqual(@as(?u32, 0), refBinding(r, 1)); // `i++` → head i
}

test "for-head bindings live in their own scope around the body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const r = try resolveSource(arena.allocator(), "for (let i = 0; i < 3; i++) { let i = 5; i; } ", &d);
    // refs in source order: `i` (cond), `i` (update), `i` (body)
    try testing.expectEqual(@as(?u32, 0), refBinding(r, 0));
    try testing.expectEqual(@as(?u32, 0), refBinding(r, 1));
    try testing.expectEqual(@as(?u32, 1), refBinding(r, 2));
    try testing.expect(r.res.bindings[0].slot != r.res.bindings[1].slot);
    // The head binding is findable from the `for` node; M6 copies exactly these per iteration.
    const head = r.script.statements[0].data.@"for".init.?.declaration;
    try testing.expectEqual(@as(u32, 0), head.declarators[0].pattern.data.binding.binding);
}

test "undefined, NaN and Infinity: SyntaxError only at script level" {
    const msg: Diagnostic.Detail = .{ .syntax_error = "cannot redeclare a non-configurable global at script level" };
    try expectFailure("let undefined = 1;", error.SyntaxError, msg);
    try expectFailure("const NaN = 1;", error.SyntaxError, msg);
    try expectFailure("let Infinity;", error.SyntaxError, msg);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    _ = try resolveSource(arena.allocator(), "{ let undefined = 1; } for (let NaN = 0;;) {} let globalThis;", &d);
}

test "globals: reading and writing both resolve to .global" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const r = try resolveSource(arena.allocator(), "undefined; y; y = 1; y += 1; y++; { let y; } y = 2;", &d);
    try testing.expectEqual(@as(?u32, null), refBinding(r, 0));
    try testing.expectEqual(@as(?u32, null), refBinding(r, 1));
    try testing.expectEqual(@as(?u32, null), refBinding(r, 2));
}

test "assigning to a const resolves normally (the error is a runtime TypeError)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const r = try resolveSource(arena.allocator(), "const c = 1; if (false) c = 2; c++;", &d);
    try testing.expectEqual(Resolution.BindingKind.@"const", r.res.bindings[0].kind);
    try testing.expectEqual(@as(?u32, 0), refBinding(r, 0));
}

test "functions number their own slots; parameters come first, after a named expression's name" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const r = try resolveSource(arena.allocator(), "let a; function f(p, q) { let b; } let g = function self(x) { let y; };", &d);
    // Binding ids (parse order): a 0, f 1, p 2, q 3, b 4, g 5, self 6, x 7, y 8.
    const slot = struct {
        fn of(res: Resolution, binding: u32) u32 {
            return res.bindings[binding].slot;
        }
    }.of;
    try testing.expectEqual(@as(u32, 0), slot(r.res, 2)); // p: f's slot 0
    try testing.expectEqual(@as(u32, 1), slot(r.res, 3)); // q
    try testing.expectEqual(@as(u32, 2), slot(r.res, 4)); // b
    try testing.expectEqual(@as(u32, 0), slot(r.res, 6)); // self: the named expression's own name
    try testing.expectEqual(@as(u32, 1), slot(r.res, 7)); // x
    try testing.expectEqual(@as(u32, 1), r.res.functions[2].param_slot);
    try testing.expectEqual(@as(u32, 0), r.res.functions[1].param_slot);
    try testing.expectEqual(@as(u32, 3), r.res.functions[0].slot_count); // a, f, g
}

test "captures: marked bindings and capture chains through intermediate functions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    // Bindings: v(0) f(1) w(2) g(3) h(4). h reads v and w, two levels and one level out.
    const r = try resolveSource(arena.allocator(), "let v = 1; function f() { let w; function g() { function h() { return v + w; } } } v;", &d);
    try testing.expect(r.res.bindings[0].captured); // v: captured (by h)
    try testing.expect(r.res.bindings[2].captured); // w
    try testing.expect(!r.res.bindings[1].captured); // f: only declared
    const f = r.res.functions[1];
    const g = r.res.functions[2];
    const h = r.res.functions[3];
    // f gets v from the script's slot; g gets v from f's captures and w from f's slot;
    // h gets both from g's captures.
    try testing.expectEqual(@as(usize, 1), f.captures.len);
    try testing.expectEqual(Resolution.Capture{ .binding = 0, .from = .{ .parent_slot = 0 } }, f.captures[0]);
    try testing.expectEqual(@as(usize, 2), g.captures.len);
    try testing.expectEqual(Resolution.Capture{ .binding = 0, .from = .{ .parent_capture = 0 } }, g.captures[0]);
    try testing.expectEqual(Resolution.Capture{ .binding = 2, .from = .{ .parent_slot = 0 } }, g.captures[1]);
    try testing.expectEqual(@as(usize, 2), h.captures.len);
    try testing.expectEqual(Resolution.Capture{ .binding = 0, .from = .{ .parent_capture = 0 } }, h.captures[0]);
    try testing.expectEqual(Resolution.Capture{ .binding = 2, .from = .{ .parent_capture = 1 } }, h.captures[1]);
    // References: inside h through captures; at script level a plain local.
    try testing.expectEqual(Resolution.Ref{ .capture = .{ .binding = 0, .index = 0 } }, r.res.refs[0]);
    try testing.expectEqual(Resolution.Ref{ .capture = .{ .binding = 2, .index = 1 } }, r.res.refs[1]);
    try testing.expectEqual(Resolution.Ref{ .local = 0 }, r.res.refs[2]);
}

test "duplicate and conflicting declarations around functions" {
    try expectFailure("function f(a, a) {}", error.Unsupported, .{ .unsupported = .duplicate_parameter });
    try expectFailure("function f() {} function f() {}", error.Unsupported, .{ .unsupported = .duplicate_function });
    try expectFailure("function f(a) { function a() {} }", error.Unsupported, .{ .unsupported = .duplicate_function });
    try expectFailure("function f(a) { let a; }", error.SyntaxError, .{ .syntax_error = "identifier has already been declared" });
    try expectFailure("let f; function f() {}", error.SyntaxError, .{ .syntax_error = "identifier has already been declared" });
    try expectFailure("let g = function n() { n = 1; };", error.Unsupported, .{ .unsupported = .function_name_assignment });
}
