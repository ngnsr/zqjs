//! Name resolution: turns every variable *name* in the AST into a *number*
//! before anything runs.
//!
//! Output (all in side tables; the AST stays immutable, DESIGN_DECISIONS D20):
//!   refs[ref.id]               → .local(binding id) or .global
//!   bindings[declarator.binding] → { kind, slot }
//!   max_slots                  → how many local slots a frame needs
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
//!   * A binding's slot = its index in `live` when it was declared. Bindings of a
//!     finished block are truncated away, so a later sibling block reuses the same
//!     slots, and the largest `live.len` ever seen is the frame size.
//!
//! Hoisting: on entering a block we declare *all* of its `let`/`const` bindings
//! before resolving any statement. So in `let x = 1; { x; let x = 2; }` the inner
//! `x` reference finds the inner binding, which at runtime is still in its
//! temporal dead zone (ReferenceError), exactly as in JS.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("ast.zig");
const Diagnostic = @import("diag.zig").Diagnostic;

pub const Error = error{ SyntaxError, Unsupported, OutOfMemory };

pub const Resolution = struct {
    refs: []const Ref,
    bindings: []const Binding,
    max_slots: u32,

    pub const Ref = union(enum) {
        /// Binding id (index into `bindings`).
        local: u32,
        /// Not declared anywhere in the script; looked up by name at runtime.
        global,
    };

    pub const Binding = struct {
        kind: ast.DeclKind,
        slot: u32,
    };
};

/// `arena` also owns the returned tables; they live exactly as long as the AST.
pub fn resolve(arena: Allocator, script: ast.Script, diag: *Diagnostic) Error!Resolution {
    var r: Resolver = .{
        .arena = arena,
        .diag = diag,
        .refs = try arena.alloc(Resolution.Ref, script.ref_count),
        .bindings = try arena.alloc(Resolution.Binding, script.binding_count),
    };
    try r.block(script.statements, .script);
    return .{ .refs = r.refs, .bindings = r.bindings, .max_slots = r.max_slots };
}

const Live = struct { name: []const u8, binding: u32 };

const Resolver = struct {
    arena: Allocator,
    diag: *Diagnostic,
    refs: []Resolution.Ref,
    bindings: []Resolution.Binding,
    live: std.ArrayList(Live) = .empty,
    scope_start: usize = 0,
    max_slots: u32 = 0,

    const Saved = struct { scope_start: usize, live_len: usize };

    fn enterScope(r: *Resolver) Saved {
        const saved: Saved = .{ .scope_start = r.scope_start, .live_len = r.live.items.len };
        r.scope_start = r.live.items.len;
        return saved;
    }

    fn exitScope(r: *Resolver, saved: Saved) void {
        r.live.shrinkRetainingCapacity(saved.live_len);
        r.scope_start = saved.scope_start;
    }

    /// The script body or a `{ … }` block: declare everything first, then resolve.
    fn block(r: *Resolver, stmts: []const ast.Stmt, comptime kind: enum { script, block }) Error!void {
        const saved = r.enterScope();
        defer r.exitScope(saved);
        for (stmts) |s| if (s.data == .declaration) try r.declare(s.data.declaration, kind == .script);
        for (stmts) |s| try r.stmt(s);
    }

    fn declare(r: *Resolver, decl: ast.Declaration, script_scope: bool) Error!void {
        for (decl.declarators) |d| {
            for (r.live.items[r.scope_start..]) |l| {
                if (std.mem.eql(u8, l.name, d.name)) return r.fail(.{ .syntax_error = "identifier has already been declared" }, d.span);
            }
            // At script level these would collide with non-configurable properties of
            // the global object; node throws a SyntaxError before running anything.
            // Inside a block (or a `for` head) they are ordinary local names.
            if (script_scope and isRestrictedGlobal(d.name))
                return r.fail(.{ .syntax_error = "cannot redeclare a non-configurable global at script level" }, d.span);
            const slot: u32 = @intCast(r.live.items.len);
            r.bindings[d.binding] = .{ .kind = decl.kind, .slot = slot };
            try r.live.append(r.arena, .{ .name = d.name, .binding = d.binding });
            r.max_slots = @max(r.max_slots, slot + 1);
        }
    }

    fn stmt(r: *Resolver, s: ast.Stmt) Error!void {
        switch (s.data) {
            .empty, .@"break", .@"continue" => {},
            .expression => |e| try r.expr(e),
            // Already declared by the enclosing block; only the initialisers remain.
            .declaration => |decl| for (decl.declarators) |d| if (d.init) |init| try r.expr(init),
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
            .@"for" => |f| {
                // The head declaration gets its own scope, enclosing the body (whose
                // block, if any, is one more scope), so `for (let i;;) { let i; }` is legal.
                const saved = r.enterScope();
                defer r.exitScope(saved);
                if (f.init) |init| switch (init) {
                    .declaration => |decl| {
                        try r.declare(decl, false);
                        for (decl.declarators) |d| if (d.init) |e| try r.expr(e);
                    },
                    .expression => |e| try r.expr(e),
                };
                if (f.cond) |e| try r.expr(e);
                if (f.update) |e| try r.expr(e);
                try r.stmt(f.body.*);
            },
        }
    }

    fn expr(r: *Resolver, e: *const ast.Expr) Error!void {
        switch (e.data) {
            .number, .string, .boolean, .null => {},
            .identifier => |ref| r.refs[ref.id] = r.lookup(ref.name),
            .unary => |u| try r.expr(u.operand),
            .binary => |b| {
                try r.expr(b.lhs);
                try r.expr(b.rhs);
            },
            .assign => |a| {
                try r.expr(a.value);
                try r.target(a.target);
            },
            .update => |u| try r.target(u.target),
        }
    }

    /// Assignment to a `const` is *not* rejected here: JS throws a TypeError only if
    /// the assignment actually executes (`if (false) c = 2;` is fine), so that check
    /// belongs to the runtime (M3). Assignment to an undeclared name is rejected:
    /// sloppy JS would silently create a global, which ZQJS doesn't do (decision B).
    fn target(r: *Resolver, ref: ast.Ref) Error!void {
        const res = r.lookup(ref.name);
        if (res == .global) return r.fail(.{ .unsupported = .global_assignment }, ref.span);
        r.refs[ref.id] = res;
    }

    fn lookup(r: *Resolver, name: []const u8) Resolution.Ref {
        var i = r.live.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, r.live.items[i].name, name)) return .{ .local = r.live.items[i].binding };
        }
        return .global;
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
    try testing.expectEqual(@as(u32, 2), r.res.max_slots);
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
    try testing.expectEqual(@as(u32, 3), r.res.max_slots);
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
    try testing.expectEqual(@as(u32, 4), r.res.max_slots); // a, b, e, f at the deepest point
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
    try testing.expectEqual(@as(u32, 0), head.declarators[0].binding);
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
    try testing.expectEqual(ast.DeclKind.@"const", r.res.bindings[0].kind);
    try testing.expectEqual(@as(?u32, 0), refBinding(r, 0));
}
