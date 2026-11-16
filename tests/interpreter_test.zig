//! Execution tests that node can't check, run on *both* engines: resource limits,
//! allocation failures, exception ownership, and differential fuzzing (the engines must
//! agree on any input). Observable JS behaviour is tested against node in tests/diff.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zqjs = @import("zqjs_internal");
const Limits = zqjs.Limits;
const Limit = zqjs.Limit;
const Diagnostic = zqjs.Diagnostic;
const Runtime = zqjs.Runtime;
const support = @import("support.zig");

/// Runs `source` on `engine` and returns the runtime error (or null on success), keeping
/// the runtime alive so the caller can inspect it. Output goes to `rt.out`.
fn runScript(arena: Allocator, rt: *Runtime, source: []const u8, engine: zqjs.Engine) !?anyerror {
    var d: Diagnostic = .{};
    const script = try zqjs.parse(arena, source, .{}, &d);
    const res = try zqjs.resolve(arena, script, &d);
    switch (engine) {
        .treewalk => zqjs.interpret(rt, script, res) catch |e| return @as(?anyerror, e), // as a value, not as an error
        .vm => {
            var proto = try zqjs.compile(rt.gpa, &rt.heap, script, res, .{}, &d);
            defer proto.deinit(rt.gpa);
            var failure: zqjs.verify.Failure = .{};
            _ = try zqjs.verify.verify(rt.gpa, &proto, .{}, &failure);
            var vm = zqjs.Vm.init(rt, &proto) catch |e| return @as(?anyerror, e);
            defer vm.deinit();
            vm.run() catch |e| return @as(?anyerror, e);
        },
    }
    return null;
}

fn expectLimit(source: []const u8, limits: Limits, which: Limit) !void {
    var dbg: support.ProgramAllocator = .init; // these programs run to a limit: many allocations
    defer support.endProgram(&dbg);
    for (support.engines) |engine| {
        var arena = std.heap.ArenaAllocator.init(dbg.allocator());
        defer arena.deinit();
        var discard: std.Io.Writer.Discarding = .init(&.{});
        var rt = Runtime.init(dbg.allocator(), limits, &discard.writer);
        defer rt.deinit();
        try testing.expectEqual(@as(?anyerror, error.LimitExceeded), try runScript(arena.allocator(), &rt, source, engine));
        try testing.expectEqual(which, rt.limitHit().?);
    }
}

test "watchdog: this binary fails, instead of hanging, if a test gets stuck" {
    support.watchdog(@src().file);
}

test "step budget covers loops, straight-line code and deep expressions" {
    try expectLimit("while (true) {}", .{ .max_steps = 1000 }, .steps);
    try expectLimit("for (;;) {}", .{ .max_steps = 1000 }, .steps);
    try expectLimit("1;", .{ .max_steps = 0 }, .steps);
    var buf: [4096]u8 = undefined;
    // 300 statements, no loop.
    var w: std.Io.Writer = .fixed(&buf);
    for (0..300) |_| try w.writeAll("1;");
    try expectLimit(w.buffered(), .{ .max_steps = 100 }, .steps);
    // One expression with 300 additions, no loop.
    w = .fixed(&buf);
    try w.writeAll("1");
    for (0..300) |_| try w.writeAll("+1");
    try w.writeAll(";");
    try expectLimit(w.buffered(), .{ .max_steps = 100 }, .steps);
}

test "call depth is limited on both engines; stack slots on the VM" {
    try expectLimit("function f(n) { return f(n + 1); } f(0);", .{ .max_call_depth = 50 }, .call_depth);
    try expectLimit("const f = function self() { return self(); }; f();", .{ .max_call_depth = 50 }, .call_depth);
    // Mutual recursion through hoisted declarations.
    try expectLimit("function a() { return b(); } function b() { return a(); } a();", .{ .max_call_depth = 50 }, .call_depth);
}

test "the VM's stack-slot limit counts every active frame's reservation" {
    // Each frame of f reserves its slots and operands; 20 frames need well over 64.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var rt = Runtime.init(testing.allocator, .{ .max_stack_slots = 64 }, &discard.writer);
    defer rt.deinit();
    try testing.expectEqual(@as(?anyerror, error.LimitExceeded), try runScript(arena.allocator(), &rt, "function f(n) { let a = n, b = n; if (n === 0) return 0; return f(n - 1); } f(20);", .vm));
    try testing.expectEqual(Limit.stack_slots, rt.limitHit().?);
    // The script's own frame counts too.
    var rt2 = Runtime.init(testing.allocator, .{ .max_stack_slots = 1 }, &discard.writer);
    defer rt2.deinit();
    try testing.expectEqual(@as(?anyerror, error.LimitExceeded), try runScript(arena.allocator(), &rt2, "let a = 1, b = 2;", .vm));
}

test "heap and string limits stop runaway strings" {
    try expectLimit("let s = 'ab'; while (true) { s += s; }", .{ .max_heap_bytes = 1 << 20 }, .heap_bytes);
    try expectLimit("let s = 'ab'; while (true) { s += s; }", .{ .max_string_length = 1000 }, .string_length);
    // Many small *live* strings: per-allocation overhead is charged, so they can't evade the
    // limit. (They are kept in an array: since M8 the VM collects unreferenced ones, see the
    // garbage test below.)
    try expectLimit("let keep = []; let n = 0; while (true) { keep.push('' + n++); }", .{ .max_heap_bytes = 1 << 16 }, .heap_bytes);
}

test "an exception outlives unwinding and is freed by Runtime.deinit" {
    for (support.engines) |engine| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var discard: std.Io.Writer.Discarding = .init(&.{});
        var rt = Runtime.init(testing.allocator, .{}, &discard.writer);
        defer rt.deinit(); // testing.allocator reports a leak if the message isn't freed
        try testing.expectEqual(@as(?anyerror, error.Thrown), try runScript(arena.allocator(), &rt, "{ let longName = 1; } longName;", engine));
        const ex = rt.exception.?;
        try testing.expectEqual(zqjs.ErrorName.ReferenceError, ex.name);
        const expected = std.unicode.utf8ToUtf16LeStringLiteral("longName is not defined");
        try testing.expectEqualSlices(u16, expected, ex.message.units);
    }
}

test "converting a native function to a string is Unsupported, not a mismatch" {
    for (support.engines) |engine| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var discard: std.Io.Writer.Discarding = .init(&.{});
        var rt = Runtime.init(testing.allocator, .{}, &discard.writer);
        defer rt.deinit();
        try testing.expectEqual(@as(?anyerror, error.Unsupported), try runScript(arena.allocator(), &rt, "print(print);", engine));
    }
}

test "comparing a function with a string is Unsupported; with a number it is false" {
    // node: `print > 'a'` is true (it compares the function's source text).
    for ([_][]const u8{ "print > 'a';", "'a' <= print;", "print < print;" }) |src| for (support.engines) |engine| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var discard: std.Io.Writer.Discarding = .init(&.{});
        var rt = Runtime.init(testing.allocator, .{}, &discard.writer);
        defer rt.deinit();
        try testing.expectEqual(@as(?anyerror, error.Unsupported), try runScript(arena.allocator(), &rt, src, engine));
        try testing.expectEqual(zqjs.Feature.function_to_string, rt.unsupported.?);
    };
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, "print(print < 1, print >= 0, null < print);", .{}, engine, .harness);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("false false false\n", r.out);
    }
}

fn runOnce(allocator: Allocator, source: []const u8, engine: zqjs.Engine) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = zqjs.runSource(allocator, "t", source, .{ .max_steps = 100_000 }, .{ .mode = .harness, .engine = engine }, &out.writer, &discard.writer) catch |e| switch (e) {
        // The output writer allocates too; under injected failure it reports WriteFailed.
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
}

test "error paths: every allocation failing once leaks nothing" {
    // Covers every partial state on the VM path too: failing while compiling, verifying,
    // allocating the VM's slots or its stack (Vm.init), and while running.
    const sources = [_][]const u8{
        "let s = 'a'; for (let i = 0; i < 3; i++) { s += i + '!'; } print(s, +'0x10', 1 / 3);",
        "let x = 1; { x; let x = 2; }", // ends in an exception whose message is allocated
        "const c = 1; c = print('rhs');",
        "", // empty script: max_stack 0, no slots
        // Functions: closures, cells, captures, per-iteration copies, calls and returns.
        "function counter() { let n = 0; return function() { n++; return n; }; } const c = counter(); c(); print(c());",
        "let fs = ''; for (let i = 0; i < 3; i++) { const f = function self(k) { if (k) return self(k - 1); return i; }; fs += f(2); } print(fs);",
        "function f(a, b) { return a + b; } print(f(1), f(1, 2, 3), f('x', print('arg')));",
        // Objects: literals, keys, prototype chains, methods, arrays, conversions.
        "let o = { a: 1, [ 'b' + 1 ]: [1, 2], m() { return this.a; } }; o.c = Object.create(o); o.b1.push(o.m()); delete o.a; print(o.b1, Object.keys(o), o.c.m(), [o.b1] + '', 'a' in o.c);",
    };
    for (support.engines) |engine| for (sources) |src|
        try testing.checkAllAllocationFailures(testing.allocator, runOnce, .{ src, engine });
}

const corpus = [_][]const u8{
    "let s = ''; for (let i = 0; i < 10; i++) { if (i === 5) continue; s += i; } print(s);",
    "let x = 1; x = x + (x = 10); print(x, x ** 0.5, -0, 1 / -0, '\\uD83D' + '\\uDE00');",
    "const c = 1; while (true) { c++; }",
    "print(+' 0x1f ', 'a' < 'b', null >= 0, 1e21, 5e-324);",
    "let a = '' || 'd', b = a && null; print(a, b, !a, -a, a === 'd', b !== null);",
    "x = print('rhs'); let x;",
    "const k = 1; k += print('rhs') + y;",
    "print(1)(2);",
    "for (;;) { if (print('once')) continue; else break; } print('after');",
    "function fib(n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); } print(fib(12));",
    "let a, b; { let x = 1; a = function() { return x; }; } { let x = 2; b = function() { x++; return x; }; } print(a(), b(), b());",
    "let fs = ''; for (let i = 0; i < 3; i++) { let g = function() { return i; }; i++; fs += g(); } print(fs);",
    "function o() { let v = 1; function m() { function i() { v = v * 2; return v; } return i; } return m(); } const d = o(); print(d(), d());",
    "const k = 1; function w() { k = 2; } w();",
    "function t() { return later; } t(); let later;",
    "const f = function g(x) { return x ? g(x - 1) + 1 : 0; };",
    "let o = { a: 1, b: [1, 2, { c: 3 }], m(x) { return this.a + x; } }; o.b.push(o.m(2)); o['a'] += o.b.length; print(o.b, o.a, 'm' in o, delete o.a, Object.keys(o));",
    "let p = { v: 1 }; let q = Object.create(p); q.w = 2; print(q.v + q.w, [q.v, q.w].join('-'), [] + {}, [3] * [4]);",
    "let s = 'h\\uD83D\\uDE00'; print(s.length, s.charCodeAt(1), s[2], Object.keys(s));",
    "let a = [1, 2, 3]; a.length = 1; a[a.length] = 9; print(a, a.pop(), a[0]++, ++a[0], a);",
};

test "the engines agree on every syntax case and corpus program" {
    var dbg: support.ProgramAllocator = .init;
    defer support.endProgram(&dbg);
    const gpa = dbg.allocator();
    var failures: usize = 0;
    for (corpus) |src| {
        if (!try support.enginesAgree(gpa, src, .{ .max_steps = 100_000 })) failures += 1;
    }
    var lines = std.mem.splitScalar(u8, @embedFile("syntax/cases.jsonl"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice([]const []const u8, gpa, line, .{});
        defer parsed.deinit();
        if (!try support.enginesAgree(gpa, parsed.value[1], .{ .max_steps = 100_000 })) failures += 1;
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

fn fuzzOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const source = buf[0..smith.slice(&buf)];
    const ok = try support.enginesAgree(testing.allocator, source, .{
        .max_nesting_depth = 64,
        .max_steps = 20_000,
        .max_heap_bytes = 1 << 20,
        .max_string_length = 1 << 12,
    });
    if (!ok) return error.EnginesDisagree;
}

test "fuzz: both engines agree on any input" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &corpus });
}

test "deep recursion stops cleanly even when the host thread has a tiny stack" {
    // The tree-walker recurses in Zig, but on its own stack (DESIGN_DECISIONS D37); the VM
    // doesn't recurse at all. So both must end in LimitExceeded, not a stack overflow.
    // (A small max_stack_slots keeps this fast under -Dstack-stress, which copies the
    // stacks on every call.)
    const Host = struct {
        fn work(result: *?support.Outcome, engine: zqjs.Engine, err: *?anyerror) void {
            result.* = support.run(testing.allocator, "function g(n) { return (((-g(n + 1)))); } g(0);", .{ .max_call_depth = 1 << 30, .max_stack_slots = 1 << 16 }, engine, .normal) catch |e| {
                err.* = e;
                return;
            };
        }
    };
    for (support.engines) |engine| {
        var result: ?support.Outcome = null;
        var err: ?anyerror = null;
        const t = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Host.work, .{ &result, engine, &err });
        t.join();
        if (err) |e| return e;
        var r = result.?;
        defer r.deinit(testing.allocator);
        const expected = switch (engine) {
            .treewalk => "t.js: LimitExceeded(interpreter_depth)\n",
            .vm => "t.js: LimitExceeded(stack_slots)\n",
        };
        try testing.expectEqualStrings(expected, r.err);
    }
}

/// Runs `source` on both engines and expects the given Unsupported diagnostic (the
/// feature id, and for `builtin` the member) after `output`.
fn expectUnsupported(source: []const u8, output: []const u8, diagnostic: []const u8) !void {
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, source, .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        testing.expectEqualStrings(output, r.out) catch |e| {
            std.debug.print("source: {s}\nengine: {s}\n", .{ source, @tagName(engine) });
            return e;
        };
        if (std.mem.indexOf(u8, r.err, diagnostic) == null) {
            std.debug.print("source: {s}\nengine: {s}\nexpected {s} in: {s}\n", .{ source, @tagName(engine), diagnostic, r.err });
            return error.TestUnexpectedResult;
        }
    }
}

test "this: decided by the call; an unbound call or a primitive receiver is Unsupported" {
    const obj = "const obj = { value: 42, getValue() { return this.value; } }; ";
    try expectUnsupported(obj ++ "print(obj.getValue()); const fn = obj.getValue; fn();", "42\n", "Unsupported(sloppy_this)");
    try expectUnsupported("function outer() { function inner() { return this; } return inner(); } print(1); outer();", "1\n", "Unsupported(sloppy_this)");
    // Not lexical: a nested function called plainly gets no receiver, even inside a method.
    try expectUnsupported("const o = { m() { const f = function () { return this; }; return f(); } }; o.m();", "", "Unsupported(sloppy_this)");
    try expectUnsupported("const s = { f() { return this; } }; let g = s.f; g.call;", "", "Unsupported(function_properties)");
    try expectUnsupported("let o = { f() { return this; } }; let p = 'str'; p.f = o.f;", "", "Unsupported(primitive_write)");
}

test "holes are Unsupported: arrays stay dense" {
    try expectUnsupported("let a = [10, 20, 30]; print(delete a[3]); delete a[1];", "true\n", "Unsupported(sparse_array)");
    try expectUnsupported("let a = [1]; a[1] = 2; print(a); a[5] = 6;", "1,2\n", "Unsupported(sparse_array)");
    try expectUnsupported("let a = [1, 2]; a.length = 1; print(a); a.length = 3;", "1\n", "Unsupported(sparse_array)");
}

test "built-ins: known to node but not implemented is Unsupported, naming the member" {
    try expectUnsupported("print(JSON === undefined);", "", "Unsupported(builtin): a built-in node has that ZQJS doesn't implement yet ('JSON')");
    try expectUnsupported("print([1].length); [1].map;", "1\n", "Unsupported(builtin)");
    try expectUnsupported("[1].map;", "", "('map')");
    try expectUnsupported("'abc'.toUpperCase;", "", "('toUpperCase')");
    try expectUnsupported("(1).toFixed;", "", "('toFixed')");
    try expectUnsupported("Object.assign;", "", "('assign')");
    try expectUnsupported("Object.name;", "", "('name')");
    try expectUnsupported("({}).hasOwnProperty;", "", "('hasOwnProperty')");
    try expectUnsupported("({}).constructor;", "", "('constructor')");
    try expectUnsupported("console;", "", "('console')");
    try expectUnsupported("Object({});", "", "Unsupported(builtin)");
    // Names node doesn't have are plain misses (undefined / ReferenceError), not Unsupported.
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, "print([].nope, ({}).nope, 'x'.nope, Object.nope); nope;", .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("undefined undefined undefined undefined\n", r.out);
        try testing.expect(std.mem.startsWith(u8, r.err, "Uncaught ReferenceError"));
    }
}

test "prototypes can't form a cycle: __proto__ is the only way, and it is Unsupported" {
    try expectUnsupported("let o = {}; o.__proto__ = o;", "", "('__proto__')");
    try expectUnsupported("let o = {}; o['__proto__'] = {};", "", "('__proto__')");
    try expectUnsupported("let o = {}; o.__proto__;", "", "('__proto__')");
    try expectUnsupported("let o = { __proto__: null };", "", "Unsupported(builtin)");
    // A computed `['__proto__']` key in a literal is an ordinary own property, as in JS.
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, "let o = { ['__proto__']: 1 }; print(Object.keys(o));", .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("__proto__\n", r.out);
    }
}

test "conversions call only the built-in methods" {
    try expectUnsupported("let o = { toString() { return 'mine'; } }; print('ok'); print(o);", "ok\n", "Unsupported(user_conversion)");
    try expectUnsupported("let o = { valueOf() { return 1; } }; o + 1;", "", "Unsupported(user_conversion)");
    try expectUnsupported("let a = [1]; a.join = function () { return 'j'; }; '' + a;", "", "Unsupported(user_conversion)");
    try expectUnsupported("let o = { toString: print }; '' + o;", "", "Unsupported(user_conversion)");
    try expectUnsupported("let f = function () {}; f.x = 1;", "", "Unsupported(function_properties)");
    try expectUnsupported("print.name;", "", "Unsupported(function_properties)");
}

test "object limits: heap, string length of a join, conversion depth" {
    try expectLimit("let a = []; while (true) { a.push({ x: a.length }); }", .{ .max_heap_bytes = 1 << 20 }, .heap_bytes);
    try expectLimit("let o = {}; let i = 0; while (true) { o['k' + i] = i; i++; }", .{ .max_heap_bytes = 1 << 20 }, .heap_bytes);
    try expectLimit("let a = ['abcdefgh']; while (true) { a.push(a.join()); }", .{ .max_string_length = 1000 }, .string_length);
    try expectLimit("let d = [1]; for (let i = 0; i < 2000; i++) { d = [d]; } '' + d;", .{}, .conversion_depth);
}
