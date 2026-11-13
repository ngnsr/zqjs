//! Tree-walking interpreter: executes the AST directly, using the resolver's slots.
//! Deliberately simple: plain recursion over the tree, no caching, no compilation.
//!
//! Frame: one `?Value` per slot (Resolution.max_slots). `null` means "not yet
//! initialised" (the temporal dead zone); Zig's optional type guarantees this marker
//! can never escape into a JavaScript value.
//!
//! Control flow: `exec` returns a Completion (`.normal`, `.break`, `.continue`) up the
//! recursion; loops consume break/continue. Zig errors are reserved for things that
//! stop the whole script (runtime.zig).
//!
//! Recursion depth is bounded: the parser limits AST depth (Limits.max_nesting_depth)
//! and M3 has no user functions.

const std = @import("std");
const ast = @import("../frontend/ast.zig");
const Resolution = @import("../frontend/resolver.zig").Resolution;
const Value = @import("../runtime/value.zig").Value;
const rt_mod = @import("../runtime/runtime.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const ops = @import("../runtime/ops.zig");
const globals = @import("../runtime/globals.zig");

const Completion = enum { normal, @"break", @"continue" };

/// Runs a resolved script. On error.Thrown, `rt.exception` describes the exception.
pub fn run(rt: *Runtime, script: ast.Script, res: Resolution) Error!void {
    const slots = try rt.gpa.alloc(?Value, res.max_slots);
    defer rt.gpa.free(slots);
    @memset(slots, null);
    var it: Interpreter = .{ .rt = rt, .res = res, .slots = slots };
    // The parser guarantees break/continue only occur inside loops.
    std.debug.assert(try it.block(script.statements) == .normal);
}

const Interpreter = struct {
    rt: *Runtime,
    res: Resolution,
    slots: []?Value,

    fn slotOf(it: *const Interpreter, binding: u32) *?Value {
        return &it.slots[it.res.bindings[binding].slot];
    }

    /// Entering a scope puts its bindings in the TDZ. This matters when a block is
    /// re-entered (loop bodies): the previous iteration's values must not leak.
    fn enterScope(it: *Interpreter, decl: ast.Declaration) void {
        for (decl.declarators) |d| it.slotOf(d.binding).* = null;
    }

    fn block(it: *Interpreter, stmts: []const ast.Stmt) Error!Completion {
        for (stmts) |s| if (s.data == .declaration) it.enterScope(s.data.declaration);
        for (stmts) |s| {
            const c = try it.exec(s);
            if (c != .normal) return c;
        }
        return .normal;
    }

    fn declare(it: *Interpreter, decl: ast.Declaration) Error!void {
        for (decl.declarators) |d| {
            const v: Value = if (d.init) |init| try it.eval(init) else .undefined;
            it.slotOf(d.binding).* = v; // initialisation: no TDZ or const check
        }
    }

    fn exec(it: *Interpreter, s: ast.Stmt) Error!Completion {
        try it.rt.step();
        switch (s.data) {
            .empty => {},
            .expression => |e| _ = try it.eval(e),
            .declaration => |decl| try it.declare(decl),
            .block => |stmts| return it.block(stmts),
            .@"if" => |i| {
                if (ops.toBoolean(try it.eval(i.cond))) return it.exec(i.then.*);
                if (i.@"else") |e| return it.exec(e.*);
            },
            .@"while" => |w| while (true) {
                try it.rt.step();
                if (!ops.toBoolean(try it.eval(w.cond))) break;
                if (try it.exec(w.body.*) == .@"break") break;
            },
            .@"for" => |f| {
                if (f.init) |init| switch (init) {
                    .declaration => |decl| {
                        it.enterScope(decl);
                        try it.declare(decl);
                    },
                    .expression => |e| _ = try it.eval(e),
                };
                while (true) {
                    try it.rt.step();
                    if (f.cond) |c| if (!ops.toBoolean(try it.eval(c))) break;
                    if (try it.exec(f.body.*) == .@"break") break;
                    // `continue` lands here: the update still runs.
                    if (f.update) |u| _ = try it.eval(u);
                }
            },
            .@"break" => return .@"break",
            .@"continue" => return .@"continue",
        }
        return .normal;
    }

    fn eval(it: *Interpreter, e: *const ast.Expr) Error!Value {
        const rt = it.rt;
        try rt.step();
        switch (e.data) {
            .number => |n| return .{ .number = n },
            // shortcut: allocates a new string on every evaluation; the M4 constant pool
            // creates each literal once.
            .string => |units| return .{ .string = try rt.heap.newString(&.{.{ .utf16 = units }}) },
            .boolean => |b| return .{ .boolean = b },
            .null => return .null,
            .identifier => |ref| return it.read(ref),
            .unary => |u| {
                const v = try it.eval(u.operand);
                return switch (u.op) {
                    .neg => .{ .number = -(try ops.toNumber(rt.gpa, v)) },
                    .plus => .{ .number = try ops.toNumber(rt.gpa, v) },
                    .not => .{ .boolean = !ops.toBoolean(v) },
                };
            },
            .binary => |b| {
                const lhs = try it.eval(b.lhs);
                switch (b.op) {
                    // Short-circuit, and return an operand, not a boolean: '' || 'd' is 'd'.
                    .logical_and => return if (ops.toBoolean(lhs)) it.eval(b.rhs) else lhs,
                    .logical_or => return if (ops.toBoolean(lhs)) lhs else it.eval(b.rhs),
                    else => return ops.binary(rt, b.op, lhs, try it.eval(b.rhs)),
                }
            },
            .assign => |a| {
                if (a.op) |op| {
                    // x op= e: read x first (TDZ), then evaluate e, then write (const check).
                    const old = try it.read(a.target);
                    const v = try ops.binary(rt, op, old, try it.eval(a.value));
                    try it.write(a.target, v);
                    return v;
                }
                // x = e: evaluate e first; the TDZ and const checks happen on the write.
                const v = try it.eval(a.value);
                try it.write(a.target, v);
                return v;
            },
            .update => |u| {
                const old = try ops.toNumber(rt.gpa, try it.read(u.target));
                const new = if (u.op == .inc) old + 1 else old - 1;
                try it.write(u.target, .{ .number = new });
                return .{ .number = if (u.prefix) new else old };
            },
            .call => |c| {
                const callee = try it.eval(c.callee);
                const args = try rt.gpa.alloc(Value, c.args.len);
                defer rt.gpa.free(args);
                for (c.args, args) |arg, *slot| slot.* = try it.eval(arg);
                if (callee != .native) return rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }});
                return callee.native.call(rt, args);
            },
        }
    }

    fn read(it: *Interpreter, ref: ast.Ref) Error!Value {
        switch (it.res.refs[ref.id]) {
            .local => |b| return it.slotOf(b).* orelse it.tdz(ref),
            .global => return globals.lookup(ref.name) orelse
                it.rt.throw(.ReferenceError, &.{ .{ .ascii = ref.name }, .{ .ascii = " is not defined" } }),
        }
    }

    /// The resolver rejects writes to globals, so every target here is local.
    fn write(it: *Interpreter, ref: ast.Ref, v: Value) Error!void {
        const b = it.res.refs[ref.id].local;
        const slot = it.slotOf(b);
        if (slot.* == null) return it.tdz(ref);
        if (it.res.bindings[b].kind == .@"const")
            return it.rt.throw(.TypeError, &.{.{ .ascii = "Assignment to constant variable." }});
        slot.* = v;
    }

    fn tdz(it: *Interpreter, ref: ast.Ref) Error {
        return it.rt.throw(.ReferenceError, &.{ .{ .ascii = "Cannot access '" }, .{ .ascii = ref.name }, .{ .ascii = "' before initialization" } });
    }
};
