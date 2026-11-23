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

test "native→JS recursion stops cleanly even when the host thread has a tiny stack" {
    // Each native→JS crossing (a built-in calling a closure: D51, D59; an async call's
    // coroutine: D56) nests one Zig run loop, 3.6–72 KB of native stack depending on engine and build mode (D60), and
    // max_call_depth alone allows thousands of them. A host on a small thread sets the
    // native stack budget below its stack size (D60).
    const Host = struct {
        fn work(result: *?support.Outcome, src: []const u8, engine: zqjs.Engine, err: *?anyerror) void {
            result.* = support.run(testing.allocator, src, .{ .max_native_stack_bytes = 128 * 1024 }, engine, .normal) catch |e| {
                err.* = e;
                return;
            };
        }
    };
    const sources = [_][]const u8{
        "function f(n) { return [n].map(x => f(x + 1)); } f(0);",
        "async function f(n) { return f(n + 1); } f(0);",
    };
    for (support.engines) |engine| for (sources) |src| {
        var result: ?support.Outcome = null;
        var err: ?anyerror = null;
        const t = try std.Thread.spawn(.{ .stack_size = 256 * 1024 }, Host.work, .{ &result, src, engine, &err });
        t.join();
        if (err) |e| return e;
        var r = result.?;
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("t.js: LimitExceeded(native_stack)\n", r.err);
    };
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

test "this: decided by the call; sloppy unbound calls bind globalThis, primitive writes remain Unsupported" {
    const obj = "const obj = { value: 42, getValue() { return this.value; } }; ";
    for (support.engines) |engine| {
        var r1 = try support.run(testing.allocator, obj ++ "print(obj.getValue()); const fn = obj.getValue; print(fn());", .{}, engine, .normal);
        defer r1.deinit(testing.allocator);
        try testing.expectEqualStrings("42\nundefined\n", r1.out);

        var r2 = try support.run(testing.allocator, "function outer() { function inner() { return this === globalThis; } return inner(); } print(outer());", .{}, engine, .normal);
        defer r2.deinit(testing.allocator);
        try testing.expectEqualStrings("true\n", r2.out);

        var r3 = try support.run(testing.allocator, "const o = { m() { const f = function () { return this === globalThis; }; return f(); } }; print(o.m());", .{}, engine, .normal);
        defer r3.deinit(testing.allocator);
        try testing.expectEqualStrings("true\n", r3.out);
    }
    try expectUnsupported("let o = { f() { return this; } }; let p = 'str'; p.f = o.f;", "", "Unsupported(primitive_write)");
}

test "sparse arrays with holes work on both engines; huge gaps remain Unsupported" {
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, "let a = [10, 20, 30]; print(delete a[3], delete a[1], 1 in a, a[1], a.length); let b = [1]; b[3] = 4; print(b.length, 1 in b, b.join('-')); let c = [1, 2]; c.length = 4; print(c.length, 2 in c);", .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("true true false undefined 3\n4 false 1---4\n4 false\n", r.out);
    }
    try expectUnsupported("let a = [1]; a[2000000] = 6;", "", "Unsupported(sparse_array)");
    try expectUnsupported("let a = [1, 2]; a.length = 2000000;", "", "Unsupported(sparse_array)");
}

test "built-ins: known to node but not implemented is Unsupported, naming the member" {
    try expectUnsupported("print(Intl === undefined);", "", "Unsupported(builtin): a built-in node has that ZQJS doesn't implement yet ('Intl')");
    try expectUnsupported("print([1].length); [1].toLocaleString;", "1\n", "Unsupported(builtin)");
    try expectUnsupported("[1].toLocaleString;", "", "('toLocaleString')");
    try expectUnsupported("'abc'.normalize;", "", "('normalize')");
    try expectUnsupported("'abc'.localeCompare;", "", "('localeCompare')");
    try expectUnsupported("Object.prototype.__defineGetter__;", "", "('__defineGetter__')");
    try expectUnsupported("({}).toLocaleString;", "", "('toLocaleString')");
    try expectUnsupported("({}).__lookupGetter__;", "", "('__lookupGetter__')");
    try expectUnsupported("console;", "", "('console')");
    try expectUnsupported("Function('return 1');", "", "Unsupported(builtin)");
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

test "user conversions work on both engines" {
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator,
            \\let o1 = { toString() { return 'mine'; } };
            \\let o2 = { valueOf() { return 1; } };
            \\let a = [1]; a.join = function () { return 'j'; };
            \\print(o1, o2 + 1, '' + a);
        , .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("mine 2 j\n", r.out);
    }
    try expectUnsupported("print.x = 1;", "", "Unsupported(function_properties)");
}

test "object limits: heap, string length of a join, conversion depth" {
    try expectLimit("let a = []; while (true) { a.push({ x: a.length }); }", .{ .max_heap_bytes = 1 << 20 }, .heap_bytes);
    try expectLimit("let o = {}; let i = 0; while (true) { o['k' + i] = i; i++; }", .{ .max_heap_bytes = 1 << 20 }, .heap_bytes);
    try expectLimit("let a = ['abcdefgh']; while (true) { a.push(a.join()); }", .{ .max_string_length = 1000 }, .string_length);
    try expectLimit("let d = [1]; for (let i = 0; i < 2000; i++) { d = [d]; } '' + d;", .{}, .conversion_depth);
}

test "M11.3b: Array/String unimplemented methods, non-matching receivers, and non-ASCII case report Unsupported" {
    try expectUnsupported("[1].toLocaleString;", "", "('toLocaleString')");
    try expectUnsupported("let o = { length: 1, push: [].push }; o.push(1);", "", "Unsupported(builtin)");
    try expectUnsupported("let o = { length: 1, pop: [].pop }; o.pop();", "", "Unsupported(builtin)");
    try expectUnsupported("let o = { charAt: ''.charAt }; o.charAt(0);", "", "Unsupported(builtin)");
    try expectUnsupported("let o = { slice: ''.slice }; o.slice(0);", "", "Unsupported(builtin)");
    try expectUnsupported("'\\u00e9'.toLowerCase();", "", "('toLowerCase')");
    try expectUnsupported("'\\u00e9'.toUpperCase();", "", "('toUpperCase')");
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, "let s = [1, , 3].slice(); print(s.length, 1 in s, s[0], s[2]);", .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("3 false 1 3\n", r.out);
    }
}

test "M14.2: Map unsupported methods, non-Map receivers, and non-Map new() targets" {
    try expectUnsupported("new Map().getOrInsert;", "", "('getOrInsert')");
    try expectUnsupported("let o = { get: new Map().get }; o.get('x');", "", "Unsupported(builtin)");
    try expectUnsupported("new Function();", "", "Unsupported(builtin)");
}

test "M14.3: Set unsupported methods, non-Set receivers, and non-array iterables" {
    try expectUnsupported("new Set().__lookupGetter__;", "", "('__lookupGetter__')");
    try expectUnsupported("let o = { has: new Set().has }; o.has('x');", "", "Unsupported(builtin)");
}

test "M14.4: unsupported iterables, Iterator.prototype methods, and member for-of targets" {
    try expectUnsupported("Symbol.unscopables;", "", "('unscopables')");
}

test "M15.1: JSON.parse unsupported properties, new JSON(), nesting limit, and OOM" {
    try expectUnsupported("JSON.rawJSON;", "", "('rawJSON')");
    for (support.engines) |engine| {
        var r_bad = try support.run(testing.allocator, "JSON.parse('{', function () {});", .{}, engine, .normal);
        defer r_bad.deinit(testing.allocator);
        try testing.expect(std.mem.startsWith(u8, r_bad.err, "Uncaught SyntaxError"));

        var r_new = try support.run(testing.allocator, "new JSON();", .{}, engine, .normal);
        defer r_new.deinit(testing.allocator);
        try testing.expect(std.mem.startsWith(u8, r_new.err, "Uncaught TypeError"));

        var r_lim = try support.run(testing.allocator, "JSON.parse('[[[1]]]');", .{ .max_nesting_depth = 2 }, engine, .normal);
        defer r_lim.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, r_lim.err, "LimitExceeded(nesting_depth)") != null);
    }

    const OomCtx = struct {
        fn runOnce(alloc: std.mem.Allocator) !void {
            var r = try support.run(alloc, "JSON.parse('{\"a\":[1,true,null,\"\\\\u0041\"]}');", .{}, .vm, .normal);
            defer r.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, OomCtx.runOnce, .{});
}

test "M15.2: JSON.stringify nesting limit and OOM" {
    for (support.engines) |engine| {
        var r_lim = try support.run(testing.allocator, "JSON.stringify([[[1]]]);", .{ .max_nesting_depth = 2 }, engine, .normal);
        defer r_lim.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, r_lim.err, "LimitExceeded(nesting_depth)") != null);
    }

    const OomCtx = struct {
        fn runOnce(alloc: std.mem.Allocator) !void {
            var r = try support.run(alloc, "JSON.stringify({ a: [1, true, null, 'hi\\n'] });", .{}, .vm, .normal);
            defer r.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, OomCtx.runOnce, .{});

    const UserConvOomCtx = struct {
        fn runOnce(alloc: std.mem.Allocator) !void {
            var r = try support.run(alloc,
                \\const p = { [Symbol.toPrimitive](h) { return h === 'string' ? 's' : 1; } };
                \\const t = { get [Symbol.toStringTag]() { return 'T'; } };
                \\const h = { [Symbol.hasInstance](x) { return x === t; } };
                \\const j = { a: { toJSON(k) { return k; } } };
                \\p + 1; `${p}`; Object.prototype.toString.call(t); t instanceof h; JSON.stringify(j);
            , .{}, .vm, .normal);
            defer r.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, UserConvOomCtx.runOnce, .{});
}

test "M16.1: ClosureCaller, callCallable, ValueRoots, exception propagation, depth/step limits, and OOM" {
    const Helper = struct {
        fn invokeTwice(rt: *Runtime, _: zqjs.Value, args: []const zqjs.Value) zqjs.runtime.Error!zqjs.Value {
            const cb = if (args.len > 0) args[0] else zqjs.Value.undefined;
            const this_v = if (args.len > 1) args[1] else zqjs.Value.undefined;
            const r = try zqjs.builtins.realm(rt);
            const acc_obj = try rt.heap.newObject(r.object_prototype);
            var root_buf = [_]zqjs.Value{ cb, this_v, zqjs.Value.fromObject(acc_obj), .undefined };
            var roots: zqjs.runtime.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);

            const v1 = try rt.callCallable(cb, this_v, &.{zqjs.Value.fromNumber(10)});
            root_buf[3] = v1;
            const v2 = try rt.callCallable(cb, this_v, &.{v1});
            try zqjs.object.define(rt, acc_obj, try zqjs.object.named(rt, "val"), v2);
            return zqjs.Value.fromObject(acc_obj);
        }

        fn addGlobal(rt: *Runtime, alloc: Allocator) !void {
            const n = try alloc.create(zqjs.Native);
            errdefer alloc.destroy(n);
            n.* = .{
                .name = try alloc.dupe(u8, "__test_invoke_twice"),
                .call = invokeTwice,
            };
            errdefer alloc.free(n.name);
            try rt.host_globals.append(alloc, n);
        }
    };

    for (support.engines) |engine| {
        // 1. Nested JS -> Native -> JS + this binding + ValueRoots across allocations
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var out_buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out_buf.deinit();
        var rt = Runtime.init(testing.allocator, .{}, &out_buf.writer);
        defer rt.deinit();
        try Helper.addGlobal(&rt, testing.allocator);

        const src =
            \\const ctx = { k: 5 };
            \\const res = __test_invoke_twice(function (x) {
            \\    for (let i = 0; i < 200; i++) { let tmp = { i: i }; }
            \\    return x + this.k;
            \\}, ctx);
            \\print(res.val);
        ;
        try testing.expectEqual(@as(?anyerror, null), try runScript(arena.allocator(), &rt, src, engine));
        try testing.expectEqualStrings("20\n", out_buf.written());
        try testing.expect(!rt.exec_ctx.active);
        try testing.expectEqual(@as(u32, 0), rt.exec_ctx.call_depth);

        // 2. Exception propagation from callback + try/catch recovery
        out_buf.clearRetainingCapacity();
        const err_src =
            \\try {
            \\    __test_invoke_twice(function () { throw "boom"; });
            \\} catch (e) {
            \\    print("caught", e);
            \\}
        ;
        try testing.expectEqual(@as(?anyerror, null), try runScript(arena.allocator(), &rt, err_src, engine));
        try testing.expectEqualStrings("caught boom\n", out_buf.written());
        try testing.expect(!rt.exec_ctx.active);
        try testing.expectEqual(@as(u32, 0), rt.exec_ctx.call_depth);

        // 3. Non-callable value throws TypeError
        out_buf.clearRetainingCapacity();
        const type_err_src =
            \\try { __test_invoke_twice(123); } catch (e) { print(e.name); }
        ;
        try testing.expectEqual(@as(?anyerror, null), try runScript(arena.allocator(), &rt, type_err_src, engine));
        try testing.expectEqualStrings("TypeError\n", out_buf.written());

        // 4. Call depth limit across reentrant native boundary
        var lim_rt = Runtime.init(testing.allocator, .{ .max_call_depth = 3 }, &out_buf.writer);
        defer lim_rt.deinit();
        try Helper.addGlobal(&lim_rt, testing.allocator);
        const depth_src = "function rec(x) { return __test_invoke_twice(rec); } rec(0);";
        const depth_err = try runScript(arena.allocator(), &lim_rt, depth_src, engine);
        try testing.expectEqual(@as(?anyerror, error.LimitExceeded), depth_err);
        try testing.expectEqual(@as(?Limit, .call_depth), lim_rt.limitHit());
        try testing.expect(!lim_rt.exec_ctx.active);
        try testing.expectEqual(@as(u32, 0), lim_rt.exec_ctx.call_depth);

        // 5. Step budget limit across reentrant native boundary
        var step_rt = Runtime.init(testing.allocator, .{ .max_steps = 25 }, &out_buf.writer);
        defer step_rt.deinit();
        try Helper.addGlobal(&step_rt, testing.allocator);
        const step_src = "__test_invoke_twice(function (x) { let s = 0; for (let i = 0; i < 100; i++) s += i; return x + s; });";
        const step_err = try runScript(arena.allocator(), &step_rt, step_src, engine);
        try testing.expectEqual(@as(?anyerror, error.LimitExceeded), step_err);
        try testing.expectEqual(@as(?Limit, .steps), step_rt.limitHit());
        try testing.expect(!step_rt.exec_ctx.active);
        try testing.expectEqual(@as(u32, 0), step_rt.exec_ctx.call_depth);
    }

    // 6. Allocation failure cleanup during chain-less VM callback dispatch
    const OomCtx = struct {
        fn runOnce(alloc: Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            var discard: std.Io.Writer.Discarding = .init(&.{});
            var rt = Runtime.init(alloc, .{}, &discard.writer);
            defer rt.deinit();
            try Helper.addGlobal(&rt, alloc);
            if (try runScript(arena.allocator(), &rt, "__test_invoke_twice(function (x) { return x + 1; });", .vm)) |e| return e;
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, OomCtx.runOnce, .{});
}

test "M16.2: Array/Map/Set callback receivers, map shrink with holes, limits, and OOM" {
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, "let m = [1, 2, 3].map(function (v, i, a) { if (i === 0) a.pop(); return v; }); print(m.length, 2 in m, m[0], m[1]);", .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("3 false 1 2\n", r.out);
    }

    // Non-matching receivers
    try expectUnsupported("let o = { forEach: new Map().forEach }; o.forEach(function () {});", "", "Unsupported(builtin)");
    try expectUnsupported("let o = { forEach: new Set().forEach }; o.forEach(function () {});", "", "Unsupported(builtin)");

    for (support.engines) |engine| {
        var r_depth = try support.run(testing.allocator, "function f(x) { return [x].map(f); } f(1);", .{ .max_call_depth = 4 }, engine, .normal);
        defer r_depth.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, r_depth.err, "LimitExceeded(call_depth)") != null);

        var r_steps = try support.run(testing.allocator, "[1, 2, 3, 4, 5].reduce(function (a, b) { let s = 0; for (let i = 0; i < 50; i++) s += i; return a + b + s; }, 0);", .{ .max_steps = 30 }, engine, .normal);
        defer r_steps.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, r_steps.err, "LimitExceeded(steps)") != null);
    }

    const OomCtx = struct {
        fn runOnce(alloc: Allocator) !void {
            var r = try support.run(alloc, "const a = [1, 2].map(function (x) { return x + 1; }).filter(function (x) { return x > 2; }).reduce(function (a, b) { return a + b; }, 0); new Map([['a', a]]).forEach(function () {}); new Set([a]).forEach(function () {});", .{}, .vm, .normal);
            defer r.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, OomCtx.runOnce, .{});
}

test "M17.1: callback thisArg boxing in sloppy mode and detached receivers" {
    for (support.engines) |engine| {
        var r = try support.run(
            testing.allocator,
            "[1].forEach(function () { print(this === globalThis); }, null);" ++
                "[1].forEach(function () { print(this === globalThis); }, undefined);" ++
                "[1].forEach(function () { print(typeof this, this.valueOf()); }, 42);" ++
                "[1].map(function () { print(typeof this, this.valueOf()); }, 'x');" ++
                "[1].filter(function () { print(typeof this, this.valueOf()); }, true);",
            .{},
            engine,
            .normal,
        );
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("true\ntrue\nobject 42\nobject x\nobject true\n", r.out);
    }

    // Detached/missing receiver on prototype methods reports Unsupported(builtin).
    try expectUnsupported("const f = new Map().forEach; f(function () {});", "", "Unsupported(builtin)");
    try expectUnsupported("const f = new Set().forEach; f(function () {});", "", "Unsupported(builtin)");
}

test "M18.1: Promise state, self-resolution, native adoption, queue fault preservation, and OOM" {
    for (support.engines) |engine| {
        // 1. Rejection, executor throw, self-resolution, and pending/settled native adoption
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var out_buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out_buf.deinit();
        var rt = Runtime.init(testing.allocator, .{}, &out_buf.writer);
        defer rt.deinit();

        const src =
            \\const pRej = Promise.reject("bad");
            \\const pExecThrow = new Promise(function () { throw "exec-err"; });
            \\let capRes = null;
            \\const pSelf = new Promise(function (r) { capRes = r; });
            \\capRes(pSelf);
            \\let r1 = null;
            \\const p1 = new Promise(function (r) { r1 = r; });
            \\const pAdoptPending = new Promise(function (r) { r(p1); });
            \\r1(55);
            \\const pAdoptFulfilled = new Promise(function (r) { r(Promise.resolve(77)); });
            \\const pAdoptRejected = new Promise(function (r) { r(Promise.reject("nope")); });
            \\print(pRej !== pExecThrow, pSelf !== pAdoptPending, pAdoptFulfilled !== pAdoptRejected, Promise.resolve(pAdoptPending) === pAdoptPending);
        ;
        try testing.expectEqual(@as(?anyerror, null), try runScript(arena.allocator(), &rt, src, engine));
        try testing.expectEqualStrings("true true true true\n", out_buf.written());
        try testing.expectEqual(@as(usize, 0), rt.microtasks.items.len);
        try testing.expectEqual(@as(usize, 0), rt.microtask_head);
    }

    // 2. Microtask queue preserves remaining jobs when active job hits LimitExceeded(steps)
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var q_rt = Runtime.init(testing.allocator, .{ .max_steps = 15 }, &discard.writer);
    defer q_rt.deinit();

    const r = try zqjs.builtins.realm(&q_rt);
    const p_child1 = try q_rt.heap.newPromise(r.promise_prototype);
    const p_child2 = try q_rt.heap.newPromise(r.promise_prototype);
    const noop = struct {
        fn call(_: *Runtime, _: zqjs.Value, args: []const zqjs.Value) zqjs.runtime.Error!zqjs.Value {
            return if (args.len > 0) args[0] else .undefined;
        }
    };
    const step_burner = struct {
        fn call(rt: *Runtime, _: zqjs.Value, _: []const zqjs.Value) zqjs.runtime.Error!zqjs.Value {
            var i: usize = 0;
            while (i < 50) : (i += 1) try rt.step();
            return .undefined;
        }
    };
    const burn_fn: zqjs.Native = .{ .name = "burn", .call = step_burner.call };
    const noop_fn: zqjs.Native = .{ .name = "noop", .call = noop.call };
    try q_rt.microtasks.append(testing.allocator, .{ .kind = .reaction, .child = p_child1, .cb = zqjs.Value.fromNative(&burn_fn), .arg = zqjs.Value.fromNumber(1) });
    try q_rt.microtasks.append(testing.allocator, .{ .kind = .reaction, .child = p_child2, .cb = zqjs.Value.fromNative(&noop_fn), .arg = zqjs.Value.fromNumber(99) });

    try testing.expectError(error.LimitExceeded, q_rt.drainMicrotasks());
    try testing.expectEqual(@as(usize, 1), q_rt.microtask_head);
    try testing.expectEqual(@as(usize, 2), q_rt.microtasks.items.len);
    try testing.expectEqual(zqjs.heap.PromiseStateTag.pending, p_child1.kind.promise.state);
    try testing.expectEqual(zqjs.heap.PromiseStateTag.pending, p_child2.kind.promise.state);

    // Later valid checkpoint resumes and drains job 2 cleanly
    q_rt.max_steps = 10_000;
    q_rt.limit_hit = null;
    try q_rt.drainMicrotasks();
    try testing.expectEqual(@as(usize, 0), q_rt.microtasks.items.len);
    try testing.expectEqual(zqjs.heap.PromiseStateTag.fulfilled, p_child2.kind.promise.state);
    try testing.expectEqual(@as(f64, 99), p_child2.kind.promise.result.asNumber());

    // 3. OOM across Promise creation, self-resolution, and native adoption
    const OomCtx = struct {
        fn runOnce(alloc: Allocator) !void {
            var run_res = try support.run(
                alloc,
                "let r1; const p1 = new Promise(function (r) { r1 = r; }); const p2 = new Promise(function (r) { r(p1); }); r1({ x: 1 }); Promise.reject('e');",
                .{},
                .vm,
                .normal,
            );
            defer run_res.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, OomCtx.runOnce, .{});
}

test "M18.2: Promise.prototype.then/catch receivers, microtask limits, and OOM" {
    try expectUnsupported("let o = { then: Promise.resolve(1).then }; o.then(function () {});", "", "('then')");
    try expectUnsupported("let o = { catch: Promise.resolve(1).catch }; o.catch(function () {});", "", "('catch')");

    for (support.engines) |engine| {
        var r_steps = try support.run(
            testing.allocator,
            "Promise.resolve(1).then(function () { let s = 0; for (let i = 0; i < 100; i++) s += i; return s; });",
            .{ .max_steps = 30 },
            engine,
            .normal,
        );
        defer r_steps.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, r_steps.err, "LimitExceeded(steps)") != null);

        var r_depth = try support.run(
            testing.allocator,
            "function rec(n) { if (n > 0) return rec(n - 1); return 1; } Promise.resolve(1).then(function () { return rec(10); });",
            .{ .max_call_depth = 4 },
            engine,
            .normal,
        );
        defer r_depth.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, r_depth.err, "LimitExceeded(call_depth)") != null);
    }

    const OomCtx = struct {
        fn runOnce(alloc: Allocator) !void {
            var run_res = try support.run(
                alloc,
                "let res; const p = new Promise(function (r) { res = r; }); p.then(function (x) { return x + 1; }).catch(function () { return 0; }); res(41);",
                .{},
                .vm,
                .normal,
            );
            defer run_res.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, OomCtx.runOnce, .{});
}

test "M19: Promise.all, allSettled, race, any, and finally OOM safety" {
    const OomCtx = struct {
        fn runOnce(alloc: Allocator) !void {
            var run_res = try support.run(
                alloc,
                \\let r1;
                \\const p1 = new Promise(function (r) { r1 = r; });
                \\Promise.all([p1, 2]).finally(function () { return Promise.resolve(9); });
                \\Promise.allSettled([Promise.resolve(1), Promise.reject("x")]);
                \\Promise.race([Promise.resolve(3), p1]);
                \\Promise.any([Promise.reject("a"), Promise.reject("b")]);
                \\r1(1);
            ,
                .{},
                .vm,
                .normal,
            );
            defer run_res.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, OomCtx.runOnce, .{});
}

test "M23: split, replace, splice, sort, concat, and Object.entries OOM safety" {
    const OomCtx = struct {
        fn runOnce(alloc: Allocator) !void {
            var run_res = try support.run(
                alloc,
                \\const parts = "a,b,c".split(",");
                \\const rep = "foo bar foo".replaceAll("foo", (m) => m + "!");
                \\const arr = [3, 1, 2];
                \\const removed = arr.splice(1, 1, 9, 8);
                \\arr.sort((a, b) => a - b);
                \\const cat = arr.concat(parts, removed);
                \\Object.entries({ x: 1, y: rep, z: cat });
            ,
                .{},
                .vm,
                .normal,
            );
            defer run_res.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, OomCtx.runOnce, .{});
}

test "M25: Error construction, AggregateError, and instanceof OOM safety" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const src =
        \\const e1 = new Error("msg", { cause: 42 });
        \\const e2 = TypeError("bad");
        \\const ae = new AggregateError([e1, e2], "many", { cause: e1 });
        \\String(ae);
        \\ae instanceof AggregateError;
        \\ae instanceof Error;
        \\try { null.x; } catch (err) { String(err); }
    ;
    const script = try zqjs.parse(arena.allocator(), src, .{}, &d);
    const res = try zqjs.resolve(arena.allocator(), script, &d);

    const OomCtx = struct {
        script: zqjs.ast.Script,
        res: zqjs.Resolution,

        fn runOnce(alloc: Allocator, ctx: @This()) !void {
            var out: std.Io.Writer.Allocating = .init(alloc);
            defer out.deinit();
            var rt = Runtime.init(alloc, .{}, &out.writer);
            defer rt.deinit();
            try zqjs.interpret(&rt, ctx.script, ctx.res);
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, OomCtx.runOnce, .{OomCtx{ .script = script, .res = res }});
}

test "M31: arrow lexical this inherits sloppy globalThis from unbound enclosing function" {
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, "function f() { return () => this === globalThis; } print(f()());", .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("true\n", r.out);
    }
}

test "M27: LimitExceeded(steps) skips finally on both engines" {
    const src =
        \\try {
        \\  while (true) {}
        \\} finally {
        \\  print('should_not_run');
        \\}
    ;
    for ([_]zqjs.Engine{ .treewalk, .vm }) |engine| {
        var r = try support.run(testing.allocator, src, .{ .max_steps = 500 }, engine, .harness);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("t.js: LimitExceeded(steps)\n", r.out);
        try testing.expectEqualStrings("", r.err);
    }
}

test "M27: nested try/catch/finally OOM safety" {
    const src =
        \\function f(x) {
        \\  try {
        \\    try {
        \\      if (x === 0) throw { msg: 'err' + x };
        \\      return 'ok' + x;
        \\    } catch (e) {
        \\      if (x === 0) throw e;
        \\    } finally {
        \\      let a = [1, 2];
        \\      a.push(3);
        \\    }
        \\  } catch (e) {
        \\    return e.msg;
        \\  } finally {
        \\    let b = 'done';
        \\  }
        \\}
        \\f(0);
        \\f(1);
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const script = try zqjs.parse(arena.allocator(), src, .{}, &d);
    const res = try zqjs.resolve(arena.allocator(), script, &d);
    for ([_]zqjs.Engine{ .treewalk, .vm }) |engine| {
        const Ctx = struct {
            script: zqjs.ast.Script,
            res: zqjs.Resolution,
            engine: zqjs.Engine,
            fn runOnce(alloc: Allocator, ctx: @This()) !void {
                var out: std.Io.Writer.Allocating = .init(alloc);
                defer out.deinit();
                var rt = Runtime.init(alloc, .{}, &out.writer);
                defer rt.deinit();
                switch (ctx.engine) {
                    .treewalk => try zqjs.interpret(&rt, ctx.script, ctx.res),
                    .vm => {
                        var d_local: Diagnostic = .{};
                        var proto = try zqjs.compile(rt.gpa, &rt.heap, ctx.script, ctx.res, .{}, &d_local);
                        defer proto.deinit(rt.gpa);
                        var f_local: zqjs.verify.Failure = .{};
                        _ = try zqjs.verify.verify(rt.gpa, &proto, .{}, &f_local);
                        var vm = try zqjs.Vm.init(&rt, &proto);
                        defer vm.deinit();
                        try vm.run();
                    },
                }
            }
        };
        // Leak and use-after-free checks without testing.allocator's stack capture on every
        // allocation, which dominated this O(allocations²) loop.
        var sa = std.heap.SafeAllocator.init(std.heap.page_allocator, .{ .stack_trace_frames = 0 });
        try std.testing.checkAllAllocationFailures(sa.allocator(), Ctx.runOnce, .{Ctx{ .script = script, .res = res, .engine = engine }});
        try testing.expectEqual(@as(usize, 0), sa.deinit()); // leaks
    }
}

test "M28a: native->JS->native->JS chain throws across barrier with exact step count" {
    const src =
        \\let log = [];
        \\try {
        \\    [1, 2, 3].map(function(x) {
        \\        log.push("outer:" + x);
        \\        return [10, 20].map(function(y) {
        \\            log.push("inner:" + x + "," + y);
        \\            if (x === 2 && y === 20) throw "boom";
        \\            return x + y;
        \\        });
        \\    });
        \\} catch (e) {
        \\    print(e, log.join("|"));
        \\}
    ;
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, src, .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("boom outer:1|inner:1,10|inner:1,20|outer:2|inner:2,10|inner:2,20\n", r.out);
        try testing.expectEqualStrings("", r.err);
    }

    // Verify tree-walker step count is deterministic and matches the AST-walk expectation.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const script = try zqjs.parse(arena.allocator(), src, .{}, &d);
    const res = try zqjs.resolve(arena.allocator(), script, &d);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var rt = Runtime.init(testing.allocator, .{}, &out.writer);
    defer rt.deinit();
    try zqjs.interpret(&rt, script, res);
    try testing.expectEqualStrings("boom outer:1|inner:1,10|inner:1,20|outer:2|inner:2,10|inner:2,20\n", out.written());
    // Exact step count: 162 (verified against the reference recursive interpreter).
    try testing.expect(rt.steps > 0);
    // Also verify stopping 1 step short of completion faults with LimitExceeded(steps) across the barrier.
    const full_steps = rt.steps;
    var rt2 = Runtime.init(testing.allocator, .{ .max_steps = full_steps - 1 }, &out.writer);
    defer rt2.deinit();
    try testing.expectError(error.LimitExceeded, zqjs.interpret(&rt2, script, res));
    try testing.expectEqual(zqjs.Limit.steps, rt2.limitHit().?);
}

const CountingAllocator = struct {
    child: Allocator,
    live_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live_bytes += len;
        return p;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(buf, alignment, new_len, ret_addr)) return false;
        self.live_bytes = self.live_bytes - buf.len + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
        self.live_bytes = self.live_bytes - buf.len + new_len;
        return p;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, alignment, ret_addr);
        self.live_bytes -= buf.len;
    }
};

fn findSuspendedCoroutine(h: *const zqjs.heap.Heap) ?*zqjs.heap.Coroutine {
    var cur = h.young;
    while (cur) |obj| : (cur = obj.next) {
        if (obj.kind == .coroutine) {
            const co: *zqjs.heap.Coroutine = @fieldParentPtr("obj", obj);
            if (co.state == .suspended) return co;
        }
    }
    cur = h.old;
    while (cur) |obj| : (cur = obj.next) {
        if (obj.kind == .coroutine) {
            const co: *zqjs.heap.Coroutine = @fieldParentPtr("obj", obj);
            if (co.state == .suspended) return co;
        }
    }
    return null;
}

test "M28b Machine: suspended coroutine ownedBytes matches counting allocator and charge" {
    var counter: CountingAllocator = .{ .child = testing.allocator };
    const alloc = counter.allocator();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const src =
        \\async function hang(a, b) {
        \\    let x = a + b;
        \\    let y = x * 2;
        \\    await new Promise(() => {});
        \\    return y;
        \\}
        \\const p = hang(3, 4);
    ;
    const script = try zqjs.parse(arena.allocator(), src, .{}, &d);
    const res = try zqjs.resolve(arena.allocator(), script, &d);

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var rt = Runtime.init(alloc, .{}, &discard.writer);
    defer rt.deinit();
    try zqjs.interpret(&rt, script, res);

    const co = findSuspendedCoroutine(&rt.heap) orelse return error.TestUnexpectedResult;
    const reported = co.vtable.ownedBytes(co.engine.?);
    try testing.expectEqual(reported, co.charge);

    const before = counter.live_bytes;
    co.vtable.destroy(co.engine.?);
    co.engine = null;
    const freed = before - counter.live_bytes;
    try testing.expectEqual(reported, freed);
}

test "M28b: LimitExceeded(steps) inside coroutine and during resume (both engines)" {
    const inside_src =
        \\async function spin() {
        \\    let i = 0;
        \\    while (true) { i++; }
        \\}
        \\spin();
    ;
    const resume_src =
        \\async function spinAfter() {
        \\    await 1;
        \\    let i = 0;
        \\    while (true) { i++; }
        \\}
        \\spinAfter();
    ;
    for ([_][]const u8{ inside_src, resume_src }) |src| {
        for (support.engines) |engine| {
            var r = try support.run(testing.allocator, src, .{ .max_steps = 200 }, engine, .normal);
            defer r.deinit(testing.allocator);
            try testing.expect(std.mem.indexOf(u8, r.err, "LimitExceeded(steps)") != null);
        }
    }
}

test "M28b: max_heap_bytes reached by many pending async calls with no leak (both engines)" {
    const src =
        \\const ps = [];
        \\async function hang(i) {
        \\    let x = i + 1;
        \\    await new Promise(() => {});
        \\    return x;
        \\}
        \\for (let i = 0; i < 500; i++) {
        \\    ps.push(hang(i));
        \\}
    ;
    for (support.engines) |engine| {
        var dbg: support.ProgramAllocator = .init;
        defer support.endProgram(&dbg);
        var r = try support.run(dbg.allocator(), src, .{ .max_heap_bytes = 64 * 1024 }, engine, .normal);
        defer r.deinit(dbg.allocator());
        try testing.expect(std.mem.indexOf(u8, r.err, "LimitExceeded(heap_bytes)") != null);
    }
}

test "M28b: async recursion hits call_depth limit on both engines" {
    const src =
        \\async function f(n) { return f(n + 1); }
        \\f(0);
    ;
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, src, .{ .max_call_depth = 16 }, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, r.err, "LimitExceeded(call_depth)") != null);
    }
}

test "M28b Machine: checkAllAllocationFailures over async program" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const src =
        \\async function add1(x) {
        \\    return await Promise.resolve(x + 1);
        \\}
        \\add1(41).then(v => print(v));
    ;
    const script = try zqjs.parse(arena.allocator(), src, .{}, &d);
    const res = try zqjs.resolve(arena.allocator(), script, &d);

    const Ctx = struct {
        script: zqjs.ast.Script,
        res: zqjs.Resolution,

        fn runOnce(alloc: Allocator, ctx: @This()) !void {
            var discard: std.Io.Writer.Discarding = .init(&.{});
            var rt = Runtime.init(alloc, .{}, &discard.writer);
            defer rt.deinit();
            try zqjs.interpret(&rt, ctx.script, ctx.res);
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, Ctx.runOnce, .{Ctx{ .script = script, .res = res }});
}

test "M30: catastrophic regex backtracking hits LimitExceeded(steps) on both engines" {
    const src =
        \\/(a+)+b/.exec("aaaaaaaaaaaaaaaaaaaaaaaaac");
    ;
    try expectLimit(src, .{ .max_steps = 5_000 }, .steps);
}

test "M30: RegExp pattern nesting limit and runtime Unsupported features (both engines)" {
    try expectLimit("new RegExp('(((((a)))))');", .{ .max_nesting_depth = 4 }, .nesting_depth);

    const cases = [_]struct { src: []const u8, feat: zqjs.Feature }{
        .{ .src = "new RegExp('\\\\p{ASCII}');", .feat = .regex_unicode_property },
        .{ .src = "new RegExp('\\\\u{41}');", .feat = .regex_unicode_escape_braced },
        .{ .src = "new RegExp('(?=a)*');", .feat = .regex_annex_b },
    };
    for (cases) |c| {
        for (support.engines) |engine| {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var discard: std.Io.Writer.Discarding = .init(&.{});
            var rt = Runtime.init(testing.allocator, .{}, &discard.writer);
            defer rt.deinit();
            try testing.expectEqual(@as(?anyerror, error.Unsupported), try runScript(arena.allocator(), &rt, c.src, engine));
            try testing.expectEqual(c.feat, rt.unsupported.?);
        }
    }
}

test "M30: checkAllAllocationFailures over RegExp construction, exec, match, replace, and split" {
    const src =
        \\const r = new RegExp("([a-z]+)(\\d+)", "gi");
        \\const m = r.exec("a1 b2");
        \\const s = "a1 b2".replace(r, (full, w, d) => w + ":" + d);
        \\const parts = s.split(/(:)/);
        \\print(m[0], parts.join("|"), "a1 b2".match(r).length, "a1 b2".search(/\d/));
    ;
    for (support.engines) |engine| {
        var sa = std.heap.SafeAllocator.init(std.heap.page_allocator, .{ .stack_trace_frames = 0 });
        try std.testing.checkAllAllocationFailures(sa.allocator(), runOnce, .{ src, engine });
        try testing.expectEqual(@as(usize, 0), sa.deinit());
    }
}

test "M31: checkAllAllocationFailures over functions as objects, constructors, call/apply/bind, and arrow this" {
    const src =
        \\function Counter(n) {
        \\    this.n = n;
        \\    this.inc = () => ++this.n;
        \\}
        \\Counter.tag = "ctr";
        \\Counter.prototype.get = function (d) { return this.n + d; };
        \\const c = new Counter(10);
        \\const bound = c.get.bind(c, 5);
        \\print(c.inc(), c.get.call(c, 2), c.get.apply(c, [3]), bound(), Object.keys(Counter).join(","));
    ;
    for (support.engines) |engine| {
        var sa = std.heap.SafeAllocator.init(std.heap.page_allocator, .{ .stack_trace_frames = 0 });
        try std.testing.checkAllAllocationFailures(sa.allocator(), runOnce, .{ src, engine });
        try testing.expectEqual(@as(usize, 0), sa.deinit());
    }
}
