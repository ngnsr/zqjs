//! Tree-walking interpreter: executes the AST directly. It is the oracle the VM is
//! tested against, so it is deliberately simple and deliberately *different* from the
//! VM where they could share a mistake (DESIGN_DECISIONS D16, D37).
//!
//! Environments (M6, D37): as in the spec, every scope that declares something gets an
//! environment record (`heap.Env`) when it is entered: the script, each block entry,
//! each `for` head (copied per iteration), each call (parameters + body), a named
//! function expression's own name. Records point to their parent; a closure keeps the
//! record it was created in. A binding is found by walking the chain to the record of
//! the binding's scope (Resolution.bindings[b].scope), then indexing it. `null` in a
//! record is the TDZ. The resolver's capture analysis is *not* used: the VM depends on
//! it, the tree-walker doesn't, so a capture-analysis bug shows up as a disagreement.
//!
//! Control flow: `exec` returns a Completion up the recursion; loops consume
//! break/continue, calls consume return. Zig errors are reserved for things that stop
//! the whole script (runtime.zig).
//!
//! Recursion: every exec/eval/call nests a Zig call, and a JS call nests a whole body,
//! so the interpreter counts its total depth across calls and stops at
//! Limits.max_interpreter_depth (LimitExceeded) before the Zig stack can overflow.
//!
//! Memory: records are heap objects; with no GC until M8 every scope entry's record
//! lives until the run ends (bounded by the heap limit). Long loops therefore use far
//! more heap here than on the VM; limits are engine-specific (LANGUAGE.md).

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

const Completion = enum { normal, @"break", @"continue", @"return" };

/// Runs a resolved script. On error.Thrown, `rt.exception` describes the exception.
pub fn run(rt: *Runtime, script: ast.Script, res: Resolution) Error!void {
    return runOnOwnStack(rt, script, res, null);
}

/// The tree-walker's own stack (DESIGN_DECISIONS D37). Measured worst case at
/// Limits.max_interpreter_depth = 6000: ~14.5 MB in Debug, ~4 MB in ReleaseSafe; the
/// test at the end of this file keeps it under half of this.
// shortcut: a big native stack instead of an explicit interpreter stack (D37 "Debt");
// replace it when the tree-walker's memory use or thread matters (e.g. embedding it).
pub const stack_bytes = 64 * 1024 * 1024;

/// Runs the interpreter on a thread with `stack_bytes` of stack, so its recursion
/// guard holds whatever stack the host's thread has (8 MiB, or a small worker thread).
/// The caller waits, so the Runtime is never used by two threads at once.
fn runOnOwnStack(rt: *Runtime, script: ast.Script, res: Resolution, use: ?*StackUse) Error!void {
    if (builtin.single_threaded) return runMeasured(rt, script, res, use);
    const Job = struct {
        fn work(r: *Runtime, sc: ast.Script, rs: Resolution, u: ?*StackUse, result: *Error!void) void {
            result.* = runMeasured(r, sc, rs, u);
        }
    };
    var result: Error!void = {};
    const thread = std.Thread.spawn(.{ .stack_size = stack_bytes }, Job.work, .{ rt, script, res, use, &result }) catch return error.OutOfMemory;
    thread.join();
    return result;
}

/// Test builds only: the deepest the interpreter recursed and the Zig stack it used.
const StackUse = struct { depth: u32 = 0, bytes: usize = 0 };

fn runMeasured(rt: *Runtime, script: ast.Script, res: Resolution, use: ?*StackUse) Error!void {
    var it: Interpreter = .{ .rt = rt, .res = res, .stack_top = @frameAddress(), .lowest_frame = @frameAddress() };
    defer if (use) |u| {
        u.* = .{ .depth = it.max_depth, .bytes = it.stack_top - it.lowest_frame };
    };
    defer {
        // No collection may scan this interpreter once it returns (D8).
        if (rt.engine_roots) |e| if (e.ctx == @as(*anyopaque, &it)) {
            rt.engine_roots = null;
        };
        it.roots.deinit(rt.gpa);
    }
    // The parser guarantees break/continue only occur in loops and return in functions.
    std.debug.assert(try it.block(script.statements) == .normal);
}

const Interpreter = struct {
    rt: *Runtime,
    res: Resolution,
    env: ?*Env = null,
    /// Nesting of exec/eval/call, across JS calls (Limits.max_interpreter_depth).
    depth: u32 = 0,
    /// Active JS calls (Limits.max_call_depth).
    calls: u32 = 0,
    /// The value of the `return` being propagated (valid while a `.return` completion is).
    ret: Value = .undefined,
    /// The running call's `this`: its receiver, or null for a call without one (D41).
    this: ?Value = null,
    /// The shadow stack (D10, GC_DESIGN §4): heap objects held in Zig locals across a
    /// sub-evaluation, which may contain a safepoint. Pushed with `hold`, released with
    /// `release` in a `defer`, so it is balanced on every exit path; `exec`/`eval` assert it.
    roots: std.ArrayList(*heap.Obj) = .empty,
    // Stack measurement, test builds only (see the test at the end).
    stack_top: usize = 0,
    lowest_frame: usize = 0,
    max_depth: u32 = 0,

    // Inlined so the frame address is the caller's (exec/eval/call), whose frames are
    // the ones that pile up.
    inline fn enter(it: *Interpreter) Error!void {
        if (it.depth >= it.rt.limits.max_interpreter_depth) return it.rt.limit(.interpreter_depth);
        it.depth += 1;
        if (builtin.is_test) {
            it.lowest_frame = @min(it.lowest_frame, @frameAddress());
            it.max_depth = @max(it.max_depth, it.depth);
        }
    }

    // ---- the collector (D8, D10)

    /// A safepoint: at the start of every statement and expression evaluation. Every heap
    /// value the interpreter still needs is reachable from `env`, `this`, `ret` or the
    /// shadow stack here, so a collection can run.
    fn safepoint(it: *Interpreter) void {
        const h = &it.rt.heap;
        if (!h.collect_requested and !h.collect_always) return;
        it.rt.engine_roots = .{ .ctx = it, .mark = markRoots };
        it.rt.collect();
    }

    fn markRoots(ctx: *anyopaque, h: *heap.Heap) void {
        const it: *Interpreter = @ptrCast(@alignCast(ctx));
        for (it.roots.items) |o| h.markObj(o);
        if (it.env) |e| h.markObj(&e.obj);
        if (it.this) |t| h.markValue(t);
        h.markValue(it.ret);
    }

    /// The shadow stack's depth, to `release` back to.
    fn mark(it: *const Interpreter) usize {
        return it.roots.items.len;
    }

    fn release(it: *Interpreter, m: usize) void {
        it.roots.shrinkRetainingCapacity(m);
    }

    /// Roots `v` until the matching `release` (non-heap values need nothing).
    fn hold(it: *Interpreter, v: Value) Error!void {
        const o: *heap.Obj = switch (v) {
            .undefined, .null, .boolean, .number, .native => return,
            .string => |x| @constCast(&x.obj),
            .closure => |x| @constCast(&x.obj),
            .object => |x| &x.obj,
        };
        try it.roots.append(it.rt.gpa, o);
    }

    fn holdKey(it: *Interpreter, k: object.Key) Error!void {
        switch (k) {
            .atom => |a| try it.roots.append(it.rt.gpa, &a.obj),
            .index => {},
        }
    }

    fn holdEnv(it: *Interpreter, e: ?*Env) Error!void {
        if (e) |x| try it.roots.append(it.rt.gpa, &x.obj);
    }

    // ---- environments

    /// The record holding binding `b`: walk outward to the record of its scope.
    fn envOf(it: *const Interpreter, b: u32) *Env {
        const scope = it.res.bindings[b].scope;
        var e = it.env;
        while (e) |rec| : (e = rec.parent) {
            rec.obj.checkLive(); // stress builds: a collected environment record
            if (rec.scope == scope) return rec;
        }
        unreachable; // the resolver only resolves names to bindings in enclosing scopes
    }

    /// Binding `b`'s value (null: in the TDZ).
    fn load(it: *const Interpreter, b: u32) ?Value {
        return it.envOf(b).values[it.res.bindings[b].index];
    }

    /// Writes binding `b` through the heap's store API (GC_DESIGN §7): no checks here.
    fn store(it: *Interpreter, b: u32, v: Value) void {
        it.rt.heap.storeEnv(it.envOf(b), it.res.bindings[b].index, v);
    }

    /// A new record for `scope` (if it declares anything) inside the current one.
    fn pushScope(it: *Interpreter, scope: ?u32) Error!void {
        const s = scope orelse return;
        it.env = try it.rt.heap.newEnv(it.env, s, it.res.scopes[s].len);
    }

    /// The scope a statement list declares into, if it declares anything.
    fn scopeOf(it: *const Interpreter, stmts: []const ast.Stmt) ?u32 {
        for (stmts) |s| switch (s.data) {
            .declaration => |decl| return it.res.bindings[decl.declarators[0].binding].scope,
            .function => |f| return it.res.bindings[f.name.?.binding].scope,
            else => {},
        };
        return null;
    }

    /// A block: a fresh record per *execution*, so a re-entered block (a loop body) gets
    /// fresh bindings in the TDZ, and closures from earlier executions keep theirs.
    fn block(it: *Interpreter, stmts: []const ast.Stmt) Error!Completion {
        const saved = it.env;
        defer it.env = saved;
        try it.pushScope(it.scopeOf(stmts));
        return it.body(stmts);
    }

    /// Statements in the current record: function declarations are created first
    /// (hoisted and initialised on entry), then everything runs in order.
    fn body(it: *Interpreter, stmts: []const ast.Stmt) Error!Completion {
        for (stmts) |s| if (s.data == .function) {
            const f = s.data.function;
            it.store(f.name.?.binding, .{ .closure = try it.rt.heap.newTreeClosure(f, it.env) });
        };
        for (stmts) |s| {
            const c = try it.exec(s);
            if (c != .normal) return c;
        }
        return .normal;
    }

    fn declare(it: *Interpreter, decl: ast.Declaration) Error!void {
        for (decl.declarators) |d| {
            const v: Value = if (d.init) |init| try it.eval(init) else .undefined;
            it.store(d.binding, v); // initialisation: no TDZ or const check
        }
    }

    /// CreatePerIterationEnvironment: a copy of the `for` head's record, so closures
    /// from one iteration keep that iteration's values.
    fn copyScope(it: *Interpreter) Error!void {
        const old = it.env.?;
        const new = try it.rt.heap.newEnv(old.parent, old.scope, old.values.len);
        @memcpy(new.values, old.values);
        it.env = new;
    }

    fn exec(it: *Interpreter, s: ast.Stmt) Error!Completion {
        try it.enter();
        defer it.depth -= 1;
        const balanced = it.mark();
        defer std.debug.assert(it.mark() == balanced); // shadow-stack symmetry, every exit
        it.safepoint();
        try it.rt.step();
        switch (s.data) {
            .empty, .function => {}, // functions were created on entry to the body
            .expression => |e| _ = try it.eval(e),
            .declaration => |decl| try it.declare(decl),
            .block => |stmts| return it.block(stmts),
            .@"return" => |v| {
                it.ret = if (v) |e| try it.eval(e) else .undefined;
                return .@"return";
            },
            .@"if" => |i| {
                if (ops.toBoolean(try it.eval(i.cond))) return it.exec(i.then.*);
                if (i.@"else") |e| return it.exec(e.*);
            },
            .@"while" => |w| while (true) {
                try it.rt.step();
                if (!ops.toBoolean(try it.eval(w.cond))) break;
                switch (try it.exec(w.body.*)) {
                    .normal, .@"continue" => {},
                    .@"break" => break,
                    .@"return" => return .@"return",
                }
            },
            .@"for" => |f| return it.execFor(f),
            .@"break" => return .@"break",
            .@"continue" => return .@"continue",
        }
        return .normal;
    }

    fn execFor(it: *Interpreter, f: @FieldType(ast.Stmt.Data, "for")) Error!Completion {
        const saved = it.env;
        defer it.env = saved;
        var per_iteration = false;
        if (f.init) |init| switch (init) {
            .declaration => |decl| {
                try it.pushScope(it.res.bindings[decl.declarators[0].binding].scope);
                try it.declare(decl);
                per_iteration = decl.kind == .let; // the spec copies only `let` bindings
            },
            .expression => |e| _ = try it.eval(e),
        };
        if (per_iteration) try it.copyScope();
        while (true) {
            try it.rt.step();
            if (f.cond) |c| if (!ops.toBoolean(try it.eval(c))) break;
            switch (try it.exec(f.body.*)) {
                .normal, .@"continue" => {}, // `continue` lands here: the update still runs
                .@"break" => break,
                .@"return" => return .@"return",
            }
            if (per_iteration) try it.copyScope();
            if (f.update) |u| _ = try it.eval(u);
        }
        return .normal;
    }

    fn eval(it: *Interpreter, e: *const ast.Expr) Error!Value {
        const rt = it.rt;
        try it.enter();
        defer it.depth -= 1;
        it.safepoint();
        // Every value held across a sub-evaluation below is on the shadow stack until the
        // end of this evaluation (`hold`); this release balances it on every exit path.
        const balanced = it.mark();
        defer it.release(balanced);
        try rt.step();
        switch (e.data) {
            .number => |n| return .{ .number = n },
            // shortcut: allocates a new string on every evaluation (D30); the VM's constant
            // pool creates each literal once.
            .string => |units| return .{ .string = try rt.heap.newString(&.{.{ .utf16 = units }}) },
            .boolean => |b| return .{ .boolean = b },
            .null => return .null,
            .identifier => |ref| return it.read(ref),
            .unary => |u| {
                const v = try it.eval(u.operand);
                return switch (u.op) {
                    .neg => .{ .number = -(try ops.toNumber(rt, v)) },
                    .plus => .{ .number = try ops.toNumber(rt, v) },
                    .not => .{ .boolean = !ops.toBoolean(v) },
                };
            },
            .binary => |b| return it.evalBinary(b),
            .assign => |a| return it.evalAssign(a),
            .update => |u| return it.evalUpdate(u),
            .member => |m| {
                const base = try it.eval(m.object);
                try it.hold(base);
                return object.get(rt, base, try it.toKey(try it.keyValue(m)));
            },
            .delete => |m| {
                const base = try it.eval(m.object);
                try it.hold(base);
                return .{ .boolean = try object.delete(rt, base, try it.toKey(try it.keyValue(m))) };
            },
            .this => return it.this orelse rt.fail(.sloppy_this),
            .array => |items| return it.evalArray(items),
            .object => |props| return it.evalObject(props),
            .function => |f| return it.evalFunction(f),
            .call => |c| return it.evalCall(c),
        }
    }

    // The big `eval` arms live in their own functions: in Debug, a function's frame holds
    // the locals of *every* arm of its switch, so with them inline each level of recursion
    // paid for the largest one (measured: ~2x the stack per level, D37).
    fn evalBinary(it: *Interpreter, b: @FieldType(ast.Expr.Data, "binary")) Error!Value {
        const rt = it.rt;
        const lhs = try it.eval(b.lhs);
        switch (b.op) {
            // Short-circuit, and return an operand, not a boolean: '' || 'd' is 'd'.
            // (`lhs` isn't needed once the right side runs.)
            .logical_and => return if (ops.toBoolean(lhs)) it.eval(b.rhs) else lhs,
            .logical_or => return if (ops.toBoolean(lhs)) lhs else it.eval(b.rhs),
            else => {
                try it.hold(lhs);
                return ops.binary(rt, b.op, lhs, try it.eval(b.rhs));
            },
        }
    }

    fn evalAssign(it: *Interpreter, a: @FieldType(ast.Expr.Data, "assign")) Error!Value {
        const rt = it.rt;
        switch (a.target) {
            .ref => |ref| {
                if (a.op) |op| {
                    // x op= e: read x first (TDZ), then evaluate e, then write (const check).
                    const old = try it.read(ref);
                    try it.hold(old);
                    const v = try ops.binary(rt, op, old, try it.eval(a.value));
                    try it.write(ref, v);
                    return v;
                }
                // x = e: evaluate e first; the TDZ and const checks happen on the write.
                const v = try it.eval(a.value);
                try it.write(ref, v);
                return v;
            },
            .member => |m| {
                // Base and key expression are evaluated exactly once, before the right-hand
                // side. The key is *converted* (ToPropertyKey) when the reference is first
                // used: for `=` after the right-hand side, for `op=` at the read before it.
                const base = try it.eval(m.object);
                try it.hold(base);
                const kv = try it.keyValue(m);
                if (kv == .value) try it.hold(kv.value);
                if (a.op) |op| {
                    const k = try it.toKey(kv);
                    try it.holdKey(k);
                    const old = try object.get(rt, base, k);
                    try it.hold(old);
                    const v = try ops.binary(rt, op, old, try it.eval(a.value));
                    try object.set(rt, base, k, v);
                    return v;
                }
                const v = try it.eval(a.value);
                try object.set(rt, base, try it.toKey(kv), v);
                return v;
            },
        }
    }

    fn evalUpdate(it: *Interpreter, u: @FieldType(ast.Expr.Data, "update")) Error!Value {
        const rt = it.rt;
        const old, const new = switch (u.target) {
            .ref => |ref| blk: {
                const old = try ops.toNumber(rt, try it.read(ref));
                const new = if (u.op == .inc) old + 1 else old - 1;
                try it.write(ref, .{ .number = new });
                break :blk .{ old, new };
            },
            .member => |m| blk: {
                const base = try it.eval(m.object);
                try it.hold(base);
                const k = try it.toKey(try it.keyValue(m));
                const old = try ops.toNumber(rt, try object.get(rt, base, k));
                const new = if (u.op == .inc) old + 1 else old - 1;
                try object.set(rt, base, k, .{ .number = new });
                break :blk .{ old, new };
            },
        };
        return .{ .number = if (u.prefix) new else old };
    }

    fn evalArray(it: *Interpreter, items: @FieldType(ast.Expr.Data, "array")) Error!Value {
        const rt = it.rt;
        const arr = try rt.heap.newArray((try builtins.realm(rt)).array_prototype);
        try it.hold(.{ .object = arr });
        for (items) |item| {
            const v = try it.eval(item);
            try rt.heap.appendElement(arr, v);
        }
        return .{ .object = arr };
    }

    fn evalObject(it: *Interpreter, props: @FieldType(ast.Expr.Data, "object")) Error!Value {
        const rt = it.rt;
        const o = try rt.heap.newObject((try builtins.realm(rt)).object_prototype);
        try it.hold(.{ .object = o });
        // Each key, then its value, in source order.
        for (props) |prop| {
            const m = it.mark();
            defer it.release(m);
            const k = try it.literalKey(prop.key);
            try it.holdKey(k);
            try object.define(rt, o, k, try it.eval(prop.value));
        }
        return .{ .object = o };
    }

    fn evalFunction(it: *Interpreter, f: @FieldType(ast.Expr.Data, "function")) Error!Value {
        const rt = it.rt;
        // A named expression's name lives in its own record around the function.
        if (f.name) |n| {
            const own = try rt.heap.newEnv(it.env, it.res.bindings[n.binding].scope, 1);
            const c = try rt.heap.newTreeClosure(f, own);
            rt.heap.storeEnv(own, 0, .{ .closure = c });
            return .{ .closure = c };
        }
        return .{ .closure = try rt.heap.newTreeClosure(f, it.env) };
    }

    fn evalCall(it: *Interpreter, c: @FieldType(ast.Expr.Data, "call")) Error!Value {
        const rt = it.rt;
        // A member callee is a method call: its base is the receiver (D41). The
        // callee is found before the arguments are evaluated.
        var receiver: ?Value = null;
        const callee = switch (c.callee.data) {
            .member => |m| blk: {
                const base = try it.eval(m.object);
                try it.hold(base);
                receiver = base;
                break :blk try object.get(rt, base, try it.toKey(try it.keyValue(m)));
            },
            else => try it.eval(c.callee),
        };
        try it.hold(callee);
        const args = try rt.gpa.alloc(Value, c.args.len);
        defer rt.gpa.free(args);
        // `args` is not traced: each value is on the shadow stack too.
        for (c.args, args) |arg, *slot| {
            slot.* = try it.eval(arg);
            try it.hold(slot.*);
        }
        return switch (callee) {
            .native => |n| if (n.host != null) rt.fail(.builtin) else n.call(rt, receiver orelse .undefined, args),
            // Sloppy JS would box a primitive receiver; ZQJS leaves `this` unset.
            .closure => |cl| it.call(cl, if (receiver) |r| (if (r == .object) r else null) else null, args),
            else => rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }}),
        };
    }

    /// A member's key as evaluated but not yet converted.
    const KeyValue = union(enum) { named: []const u8, value: Value };

    fn keyValue(it: *Interpreter, m: ast.Member) Error!KeyValue {
        return switch (m.key) {
            .name => |n| .{ .named = n },
            .computed => |e| .{ .value = try it.eval(e) },
            .string, .number => unreachable, // only in literals
        };
    }

    /// ToPropertyKey.
    fn toKey(it: *Interpreter, kv: KeyValue) Error!object.Key {
        return switch (kv) {
            .named => |n| object.named(it.rt, n),
            .value => |v| object.key(it.rt, v),
        };
    }

    fn literalKey(it: *Interpreter, k: ast.PropertyKey) Error!object.Key {
        return switch (k) {
            .name => |n| object.named(it.rt, n),
            .string => |units| object.keyUnits(it.rt, units),
            .number => |n| object.key(it.rt, .{ .number = n }),
            .computed => |e| object.key(it.rt, try it.eval(e)),
        };
    }

    fn call(it: *Interpreter, closure: *const heap.Closure, this: ?Value, args: []const Value) Error!Value {
        closure.obj.checkLive();
        const t = switch (closure.impl) {
            .tree => |t| t,
            .vm => unreachable, // each engine only ever sees its own closures
        };
        const f: *const ast.Function = @ptrCast(@alignCast(t.func));
        if (it.calls >= it.rt.limits.max_call_depth) return it.rt.limit(.call_depth);
        it.calls += 1;
        defer it.calls -= 1;
        try it.enter();
        defer it.depth -= 1;

        const saved = it.env;
        const saved_this = it.this;
        defer {
            it.env = saved;
            it.this = saved_this;
        }
        // The caller's environment and `this` are held only here while the body runs (the
        // callee's record descends from where the closure was made, not from the caller).
        const m = it.mark();
        defer it.release(m);
        try it.holdEnv(saved);
        if (saved_this) |v| try it.hold(v);
        it.env = t.env;
        it.this = this; // decided by the call, not by where the function was defined
        // Parameters and the body's declarations share one scope.
        const scope = if (f.params.len > 0) it.res.bindings[f.params[0].binding].scope else it.scopeOf(f.body);
        try it.pushScope(scope);
        for (f.params, 0..) |p, i| it.store(p.binding, if (i < args.len) args[i] else .undefined);
        return switch (try it.body(f.body)) {
            .@"return" => it.ret,
            else => .undefined,
        };
    }

    fn bindingOf(it: *const Interpreter, ref: ast.Ref) ?u32 {
        return switch (it.res.refs[ref.id]) {
            .local => |b| b,
            .capture => |c| c.binding,
            .global => null,
        };
    }

    fn read(it: *Interpreter, ref: ast.Ref) Error!Value {
        const b = it.bindingOf(ref) orelse return builtins.global(it.rt, ref.name);
        return it.load(b) orelse it.tdz(ref);
    }

    /// The resolver rejects writes to globals and to function-expression names.
    fn write(it: *Interpreter, ref: ast.Ref, v: Value) Error!void {
        const b = it.bindingOf(ref).?;
        if (it.load(b) == null) return it.tdz(ref);
        if (it.res.bindings[b].kind == .@"const")
            return it.rt.throw(.TypeError, &.{.{ .ascii = "Assignment to constant variable." }});
        it.store(b, v);
    }

    fn tdz(it: *Interpreter, ref: ast.Ref) Error {
        return it.rt.throw(.ReferenceError, &.{ .{ .ascii = "Cannot access '" }, .{ .ascii = ref.name }, .{ .ascii = "' before initialization" } });
    }
};

// ---- the recursion guard really bounds the Zig stack

test "max_interpreter_depth keeps the interpreter well inside its own stack" {
    const parse = @import("../frontend/parser.zig").parse;
    const resolve = @import("../frontend/resolver.zig").resolve;
    const Diagnostic = @import("../frontend/diag.zig").Diagnostic;
    const gpa = std.testing.allocator;
    // Worst cases: plain recursion (call → body → exec → eval → call …) and recursion
    // through a deeply nested expression (eval → eval → …), each until the limit stops it.
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("function f(n) { return ");
    for (0..200) |_| try w.writeByte('(');
    try w.writeAll("-f(n + 1)");
    for (0..200) |_| try w.writeByte(')');
    try w.writeAll("; } f(0);");
    for ([_][]const u8{ "function g(n) { return g(n + 1); } g(0);", w.buffered() }) |source| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var d: Diagnostic = .{};
        const limits: @import("../limits.zig").Limits = .{ .max_call_depth = 1 << 30 }; // the depth limit must stop it
        const script = try parse(arena.allocator(), source, limits, &d);
        const res = try resolve(arena.allocator(), script, &d);
        var discard: std.Io.Writer.Discarding = .init(&.{});
        var rt = Runtime.init(gpa, limits, &discard.writer);
        defer rt.deinit();
        var use: StackUse = .{};
        try std.testing.expectError(error.LimitExceeded, runOnOwnStack(&rt, script, res, &use));
        try std.testing.expectEqual(@import("../limits.zig").Limit.interpreter_depth, rt.limitHit().?);
        try std.testing.expectEqual(limits.max_interpreter_depth, use.depth);
        std.testing.expect(use.bytes < stack_bytes / 2) catch |e| {
            std.debug.print("tree-walker used {d} bytes of stack for depth {d} ({d} per level)\n", .{ use.bytes, use.depth, use.bytes / use.depth });
            return e;
        };
    }
}
