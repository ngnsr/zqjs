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

pub const Resolution = struct {
    refs: []const Ref,
    bindings: []const Binding,
    scopes: []const Scope,
    functions: []const Function,

    pub const Ref = union(enum) {
        /// A binding of the function containing the reference (binding id).
        local: u32,
        /// A binding of an outer function, reached through entry `index` of the current
        /// function's capture list.
        capture: struct { binding: u32, index: u32 },
        /// Not declared anywhere in the script; looked up by name at runtime.
        global,
    };

    pub const BindingKind = enum {
        let,
        @"const",
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
    };

    pub const Scope = struct { len: u32 = 0 };

    pub const Function = struct {
        slot_count: u32 = 0,
        param_count: u32 = 0,
        /// Slot of the first parameter (1 in a named function expression, whose own
        /// name comes first; else 0). Parameters occupy consecutive slots.
        param_slot: u32 = 0,
        param_scope: ?u32 = null,
        is_simple_params: bool = true,
        captures: []const Capture = &.{},
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
    var r: Resolver = .{
        .arena = arena,
        .diag = diag,
        .refs = try arena.alloc(Resolution.Ref, script.ref_count),
        .bindings = try arena.alloc(Resolution.Binding, script.binding_count),
        .functions = try arena.alloc(Resolution.Function, script.function_count),
    };
    @memset(r.refs, .global);
    @memset(r.functions, .{});
    try r.fns.append(arena, .{ .id = 0, .live_start = 0 });
    try r.block(script.statements, .script);
    r.finishFunction();
    return .{ .refs = r.refs, .bindings = r.bindings, .scopes = r.scopes.items, .functions = r.functions };
}

const Live = struct { name: []const u8, binding: u32 };

/// A function being resolved (innermost last in `Resolver.fns`).
const FnState = struct {
    id: u32,
    is_arrow: bool = false,
    /// Index in `live` where this function's bindings start (its slot 0).
    live_start: usize,
    max_slots: u32 = 0,
    captures: std.ArrayList(Resolution.Capture) = .empty,
};

const Resolver = struct {
    arena: Allocator,
    diag: *Diagnostic,
    refs: []Resolution.Ref,
    bindings: []Resolution.Binding,
    functions: []Resolution.Function,
    scopes: std.ArrayList(Resolution.Scope) = .empty,
    fns: std.ArrayList(FnState) = .empty,
    live: std.ArrayList(Live) = .empty,
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
        const f = r.fns.pop().?;
        r.functions[f.id].slot_count = f.max_slots;
        r.functions[f.id].captures = f.captures.items;
    }

    const Range = struct { start: usize, end: usize };

    /// The script body, a function body or a `{ … }` block: declare everything first,
    /// then resolve.
    fn block(r: *Resolver, stmts: []const ast.Stmt, comptime kind: enum { script, body, block }) Error!void {
        const saved = try r.enterScope();
        defer r.exitScope(saved);
        const param_range: ?Range = if (kind == .body)
            if (r.param_scope_start) |ps| .{ .start = ps, .end = r.param_scope_end } else null
        else
            null;
        for (stmts) |s| switch (s.data) {
            .declaration => |decl| for (decl.declarators) |d| try r.declarePattern(d.pattern, if (decl.kind == .let) .let else .@"const", kind == .script, true, param_range),
            .function => |f| try r.declare(f.name.?, .function, kind == .script, true, param_range),
            else => {},
        };
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
            const old = r.bindings[l.binding].kind;
            // Sloppy JS allows duplicate simple params (the later wins); non-simple params are SyntaxError.
            if (kind == .param and old == .param and !dup_is_syntax) return r.fail(.{ .unsupported = .duplicate_parameter }, d.span);
            if (kind == .function and (old == .function or old == .param)) return r.fail(.{ .unsupported = .duplicate_function }, d.span);
            return r.fail(.{ .syntax_error = "identifier has already been declared" }, d.span);
        }
        // At script level these would collide with non-configurable properties of the
        // global object: node rejects `let NaN` before running anything (SyntaxError);
        // for a function declaration it is less clear-cut, so Unsupported.
        if (script_scope and isRestrictedGlobal(d.name)) {
            if (kind == .function) return r.fail(.{ .unsupported = .duplicate_function }, d.span);
            return r.fail(.{ .syntax_error = "cannot redeclare a non-configurable global at script level" }, d.span);
        }
        const f = r.current();
        const slot: u32 = @intCast(r.live.items.len - f.live_start);
        const scope = &r.scopes.items[r.scope];
        r.bindings[d.binding] = .{ .kind = kind, .slot = slot, .scope = r.scope, .index = scope.len, .function = f.id };
        scope.len += 1;
        try r.live.append(r.arena, .{ .name = d.name, .binding = d.binding });
        f.max_slots = @max(f.max_slots, slot + 1);
    }

    fn stmt(r: *Resolver, s: ast.Stmt) Error!void {
        switch (s.data) {
            .empty, .@"break", .@"continue" => {},
            .expression => |e| try r.expr(e),
            // Already declared by the enclosing block; only the initialisers and pattern exprs remain.
            .declaration => |decl| for (decl.declarators) |d| {
                if (d.init) |init| try r.expr(init);
                try r.resolvePatternExprs(d.pattern);
            },
            .function => |f| try r.function(f),
            .@"return" => |v| if (v) |e| try r.expr(e),
            .throw => |e| try r.expr(e),
            .@"try" => |t| {
                try r.block(t.body, .block);
                if (t.catch_body) |cb| {
                    const saved = try r.enterScope();
                    defer r.exitScope(saved);
                    if (t.catch_param) |cp| try r.declarePattern(cp, .let, false, true, null);
                    for (cb) |cs| switch (cs.data) {
                        .declaration => |decl| for (decl.declarators) |d| try r.declarePattern(d.pattern, if (decl.kind == .let) .let else .@"const", false, true, null),
                        .function => |f| try r.declare(f.name.?, .function, false, true, null),
                        else => {},
                    };
                    if (t.catch_param) |cp| try r.resolvePatternExprs(cp);
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
                        .declaration => |d| for (d.declarators) |decl| try r.declarePattern(decl.pattern, if (d.kind == .let) .let else .@"const", false, true, null),
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
                        for (decl.declarators) |d| try r.declarePattern(d.pattern, if (decl.kind == .let) .let else .@"const", false, true, null);
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
            .for_of => |f| {
                const saved = try r.enterScope();
                defer r.exitScope(saved);
                switch (f.target) {
                    .declaration => |d| {
                        try r.declarePattern(d.pattern, if (d.kind == .let) .let else .@"const", false, true, null);
                        try r.expr(f.iterable);
                        try r.resolvePatternExprs(d.pattern);
                    },
                    .target => |t| {
                        try r.expr(f.iterable);
                        try r.resolvePatternExprs(t);
                    },
                }
                try r.stmt(f.body.*);
            },
        }
    }

    /// A function's own scopes: for a named expression, one holding just its name, then
    /// a parameter scope (for parameters and their defaults, isolated from body `let`/`const`),
    /// then the body scope.
    fn function(r: *Resolver, f: *const ast.Function) Error!void {
        try r.fns.append(r.arena, .{ .id = f.id, .is_arrow = f.is_arrow, .live_start = r.live.items.len });
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
        for (f.params) |p| try r.declarePattern(p.pattern, .param, false, !is_simple, null);
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
            .number, .string, .regexp, .boolean, .null => {},
            .template => |t| for (t.exprs) |ex| try r.expr(ex),
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
            .hole => unreachable,
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
            .this => if (r.current().is_arrow) return r.fail(.{ .unsupported = .arrow_this }, e.span),
            .await => |inner| try r.expr(inner),
            .call, .new_call => |c| {
                try r.expr(c.callee);
                for (c.args) |arg| try r.expr(arg);
            },
            .function => |f| try r.function(f),
        }
    }

    fn member(r: *Resolver, m: ast.Member) Error!void {
        try r.expr(m.object);
        if (m.key == .computed) try r.expr(m.key.computed);
    }

    fn optionalChain(r: *Resolver, oc: ast.OptionalChain) Error!void {
        try r.expr(oc.base);
        for (oc.steps) |s| switch (s.kind) {
            .prop => {},
            .elem => |e| try r.expr(e),
            .call => |args| for (args) |arg| try r.expr(arg),
        };
    }

    fn assignTarget(r: *Resolver, t: ast.Target) Error!void {
        switch (t) {
            .ref => |ref| try r.target(ref),
            .member => |m| try r.member(m),
        }
    }

    /// Assignment to a `const` is *not* rejected here: JS throws a TypeError only if
    /// the assignment actually executes (`if (false) c = 2;` is fine), so that check
    /// belongs to the runtime (M3). Assignment to an undeclared name is rejected:
    /// sloppy JS would silently create a global, which ZQJS doesn't do (decision B).
    fn target(r: *Resolver, ref: ast.Ref) Error!void {
        const res = try r.lookup(ref.name);
        const b = switch (res) {
            .global => return r.fail(.{ .unsupported = .global_assignment }, ref.span),
            .local => |b| b,
            .capture => |c| c.binding,
        };
        if (r.bindings[b].kind == .function_name) return r.fail(.{ .unsupported = .function_name_assignment }, ref.span);
        r.refs[ref.id] = res;
    }

    fn lookup(r: *Resolver, name: []const u8) Error!Resolution.Ref {
        var i = r.live.items.len;
        while (i > 0) {
            i -= 1;
            if (!std.mem.eql(u8, r.live.items[i].name, name)) continue;
            const b = r.live.items[i].binding;
            if (r.bindings[b].function == r.current().id) return .{ .local = b };
            r.bindings[b].captured = true;
            return .{ .capture = .{ .binding = b, .index = try r.captureIndex(r.fns.items.len - 1, b) } };
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
        const capture: Resolution.Capture = if (r.bindings[b].function == parent.id)
            .{ .binding = b, .from = .{ .parent_slot = r.bindings[b].slot } }
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
        .global => null,
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

test "globals: reading is fine, writing is Unsupported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const r = try resolveSource(arena.allocator(), "undefined; y;", &d);
    try testing.expectEqual(@as(?u32, null), refBinding(r, 0));
    try testing.expectEqual(@as(?u32, null), refBinding(r, 1));
    const unsupported: Diagnostic.Detail = .{ .unsupported = .global_assignment };
    try expectFailure("y = 1;", error.Unsupported, unsupported);
    try expectFailure("y += 1;", error.Unsupported, unsupported);
    try expectFailure("y++;", error.Unsupported, unsupported);
    try expectFailure("{ let y; } y = 1;", error.Unsupported, unsupported); // out of scope
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
