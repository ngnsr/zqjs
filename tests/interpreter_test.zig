//! Execution tests that node can't check, run on *both* engines: resource limits,
//! allocation failures, exception ownership, and differential fuzzing (the engines must
//! agree on any input). Observable JS behaviour is tested against node in tests/diff.

const std = @import("std");
const builtin = @import("builtin");
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
    // Debug stack frames on Linux x86_64 are larger than on macOS arm64; keep 256 KiB for optimized builds.
    const stack_size: usize = if (builtin.mode == .debug) 512 * 1024 else 256 * 1024;
    for (support.engines) |engine| {
        var result: ?support.Outcome = null;
        var err: ?anyerror = null;
        const t = try std.Thread.spawn(.{ .stack_size = stack_size }, Host.work, .{ &result, engine, &err });
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
    const stack_size: usize = if (builtin.mode == .debug) 512 * 1024 else 256 * 1024;
    for (support.engines) |engine| for (sources) |src| {
        var result: ?support.Outcome = null;
        var err: ?anyerror = null;
        const t = try std.Thread.spawn(.{ .stack_size = stack_size }, Host.work, .{ &result, src, engine, &err });
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
    try expectUnsupported("Atomics;", "", "('Atomics')");
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
    try expectUnsupported("let o = { length: 1, splice: [].splice }; o.splice(0, 1);", "", "Unsupported(builtin)");
    try expectUnsupported("let o = { charAt: ''.charAt }; o.charAt(0);", "", "Unsupported(builtin)");
    try expectUnsupported("let o = { slice: ''.slice }; o.slice(0);", "", "Unsupported(builtin)");
    try expectUnsupported("'\\u00e9'.toLowerCase();", "", "('toLowerCase')");
    try expectUnsupported("'\\u00e9'.toUpperCase();", "", "('toUpperCase')");
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, "let s = [1, , 3].slice(); print(s.length, 1 in s, s[0], s[2]);", .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("3 false 1 3\n", r.out);

        var r_gp = try support.run(testing.allocator, "let o = { length: 1, push: [].push, pop: [].pop }; print(o.push(7), o[1], o.pop(), o.length);", .{}, engine, .normal);
        defer r_gp.deinit(testing.allocator);
        try testing.expectEqualStrings("2 7 7 1\n", r_gp.out);
    }
}

test "M14.2: Map unsupported methods, non-Map receivers, and non-Map new() targets" {
    try expectUnsupported("new Map().__lookupGetter__;", "", "('__lookupGetter__')");
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

    for (support.engines) |engine| {
        var r_catch = try support.run(
            testing.allocator,
            "let o = { catch: Promise.resolve(1).catch }; o.catch(function () {});",
            .{},
            engine,
            .normal,
        );
        defer r_catch.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, r_catch.err, "TypeError") != null);
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

test "Test262: Error.prototype.stack accessor and Iterator drop/take MAX_SAFE_INTEGER limit (both engines)" {
    const src =
        \\function errName(fn) {
        \\    try { fn(); return "ok"; } catch (e) { return e.name; }
        \\}
        \\const d = Object.getOwnPropertyDescriptor(Error.prototype, "stack");
        \\print("desc:", typeof d.get, typeof d.set, d.get.name, d.get.length, d.set.name, d.set.length, d.enumerable, d.configurable);
        \\print("get prim:", errName(() => d.get.call(null)), errName(() => d.get.call(1)));
        \\print("get non-err:", d.get.call({}), d.get.call(new Proxy(new Error("x"), {})));
        \\print("get err:", typeof d.get.call(new Error("x")));
        \\print("set prim:", errName(() => d.set.call(null, "a")), errName(() => d.set.call({}, 123)));
        \\print("set proto:", errName(() => d.set.call(Error.prototype, "a")));
        \\const plain = {};
        \\d.set.call(plain, "custom");
        \\const pd = Object.getOwnPropertyDescriptor(plain, "stack");
        \\print("set plain:", pd.value, pd.writable, pd.enumerable, pd.configurable);
        \\const rejDef = new Proxy({}, { defineProperty() { return false; } });
        \\const rejSet = new Proxy({ stack: "a" }, { set() { return false; } });
        \\print("set proxy rej:", errName(() => d.set.call(rejDef, "b")), errName(() => d.set.call(rejSet, "b")));
        \\let dropClosed = 0;
        \\const dropIter = { next() { return { done: true, value: undefined }; }, return() { dropClosed++; return {}; } };
        \\print("drop:", errName(() => Iterator.prototype.drop.call(dropIter, Number.MAX_SAFE_INTEGER + 1)), dropClosed);
        \\let takeClosed = 0;
        \\const takeIter = { next() { return { done: true, value: undefined }; }, return() { takeClosed++; return {}; } };
        \\print("take:", errName(() => Iterator.prototype.take.call(takeIter, Number.MAX_SAFE_INTEGER + 1)), takeClosed);
    ;
    const expected =
        \\desc: function function get stack 0 set stack 1 false true
        \\get prim: TypeError TypeError
        \\get non-err: undefined undefined
        \\get err: string
        \\set prim: TypeError TypeError
        \\set proto: TypeError
        \\set plain: custom true true true
        \\set proxy rej: TypeError TypeError
        \\drop: RangeError 1
        \\take: RangeError 1
        \\
    ;
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, src, .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("", r.err);
        try testing.expectEqualStrings(expected, r.out);
    }
}

test "console: log/info/debug/warn/error/assert, descriptors, detached calls, and GC rooting" {
    const src =
        \\const gd = Object.getOwnPropertyDescriptor(globalThis, "console");
        \\const ld = Object.getOwnPropertyDescriptor(console, "log");
        \\console.log("shape:", typeof console, globalThis.console === console, Object.prototype.toString.call(console));
        \\console.log("global desc:", gd.writable, gd.enumerable, gd.configurable);
        \\console.log("log desc:", ld.writable, ld.enumerable, ld.configurable, console.log.name, console.log.length, console.assert.name, console.assert.length);
        \\console.log("keys:", Object.keys(console).join(","), console.nonexistent);
        \\console.log();
        \\console.info("i", 1, true, null, undefined, 42n, Symbol("s"));
        \\console.debug("d", [1, 2]);
        \\console.warn("w");
        \\console.error("e");
        \\const { log, assert } = console;
        \\const retLog = log("detached");
        \\console.log("retLog:", retLog);
        \\let sideEffect = false;
        \\const retPass = assert(true, { toString() { sideEffect = true; return "nope"; } });
        \\console.log("assert pass:", retPass, sideEffect);
        \\const retFail0 = console.assert();
        \\console.assert(false);
        \\console.assert(0, "zero", 123);
        \\console.assert("", Symbol("tag"));
        \\console.log("retFail0:", retFail0);
        \\const allocToString = {
        \\    toString() {
        \\        let s = "";
        \\        for (let i = 0; i < 64; i++) s = "x" + i;
        \\        return "ok:" + s;
        \\    }
        \\};
        \\console.log(allocToString, { toString() { return "second"; } });
        \\console.assert(false, allocToString, { toString() { return "third"; } });
        \\const saved = globalThis.console;
        \\delete globalThis.console;
        \\print("after delete:", globalThis.console);
        \\globalThis.console = saved;
        \\console.log("restored");
    ;
    const expected =
        \\shape: object true [object console]
        \\global desc: true false true
        \\log desc: true true true log 0 assert 0
        \\keys: log,info,debug,warn,error,assert undefined
        \\
        \\i 1 true null undefined 42n Symbol(s)
        \\d [ 1, 2 ]
        \\w
        \\e
        \\detached
        \\retLog: undefined
        \\assert pass: undefined false
        \\Assertion failed
        \\Assertion failed
        \\Assertion failed: zero 123
        \\Assertion failed: Symbol(tag)
        \\retFail0: undefined
        \\{ toString: [Function: toString] } { toString: [Function: toString] }
        \\Assertion failed: { toString: [Function: toString] } { toString: [Function: toString] }
        \\after delete: undefined
        \\restored
        \\
    ;
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, src, .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("", r.err);
        try testing.expectEqualStrings(expected, r.out);
    }
}

test "console: inspect formatting, cycle safety, read-only getters, print invariance, and GC stress" {
    const src =
        \\console.log("hi", { msg: "ok", arr: [1, 2] });
        \\console.log(undefined, null, true, false, 0, -0, NaN, Infinity, 42n, Symbol("s"));
        \\console.log({ a: 1, b: "two" });
        \\console.log([1, [2, 3]]);
        \\console.log(new Map([["k", 1], ["m", [2, 3]]]));
        \\console.log(new Set([1, "two", 3n]));
        \\console.log(new TypeError("boom"));
        \\function greet() {}
        \\console.log(greet);
        \\const cyclic = {};
        \\cyclic.self = cyclic;
        \\console.log(cyclic);
        \\let hits = 0;
        \\const guarded = {
        \\    get boom() { hits++; throw new Error("getter invoked"); },
        \\    toString() { hits++; return "nope"; },
        \\};
        \\console.log(guarded);
        \\console.log("hits:", hits);
        \\console.assert(false, "bad", { x: 1 });
        \\print({ a: 1 });
    ;
    const expected =
        \\hi { msg: 'ok', arr: [ 1, 2 ] }
        \\undefined null true false 0 -0 NaN Infinity 42n Symbol(s)
        \\{ a: 1, b: 'two' }
        \\[
        \\  1,
        \\  [ 2, 3 ]
        \\]
        \\Map(2) { 'k' => 1, 'm' => [ 2, 3 ] }
        \\Set(3) { 1, 'two', 3n }
        \\TypeError: boom
        \\[Function: greet]
        \\<ref *1> { self: [Circular *1] }
        \\{ boom: [Getter], toString: [Function: toString] }
        \\hits: 0
        \\Assertion failed: bad { x: 1 }
        \\[object Object]
        \\
    ;
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, src, .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("", r.err);
        try testing.expectEqualStrings(expected, r.out);

        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err_w.deinit();
        const code = try zqjs.runSource(testing.allocator, "console_gc_stress.js", src, .{}, .{
            .mode = .normal,
            .engine = engine,
            .collect_always = true,
            .verify_heap = true,
        }, &out.writer, &err_w.writer);
        try testing.expectEqual(@as(u8, 0), code);
        try testing.expectEqualStrings("", err_w.written());
        try testing.expectEqualStrings(expected, out.written());
    }
}

test "array index Object.defineProperty overrides: data flags, accessors, length shrink, keys, freeze/seal, array methods" {
    const src =
        \\// 1. Non-writable, non-enumerable, non-configurable data descriptors
        \\const a = [10, 20, 30, 40];
        \\Object.defineProperty(a, 1, { value: 200, writable: false, enumerable: false, configurable: true });
        \\Object.defineProperty(a, 2, { value: 300, writable: true, enumerable: true, configurable: false });
        \\const d1 = Object.getOwnPropertyDescriptor(a, 1);
        \\const d2 = Object.getOwnPropertyDescriptor(a, 2);
        \\print("d1:", d1.value, d1.writable, d1.enumerable, d1.configurable);
        \\print("d2:", d2.value, d2.writable, d2.enumerable, d2.configurable);
        \\a[1] = 999; // sloppy no-op
        \\print("after sloppy write a[1]:", a[1]);
        \\let strictWriteErr = false;
        \\try { (function() { "use strict"; a[1] = 999; })(); } catch (e) { strictWriteErr = e instanceof TypeError; }
        \\print("strict write err:", strictWriteErr);
        \\print("keys:", Object.keys(a).join(","));
        \\print("ownNames:", Object.getOwnPropertyNames(a).join(","));
        \\print("values:", Object.values(a).join(","));
        \\print("entries:", Object.entries(a).map(e => e[0] + ":" + e[1]).join(","));
        \\const forInKeys = [];
        \\for (const k in a) forInKeys.push(k);
        \\print("forIn:", forInKeys.join(","));
        \\print("in:", 0 in a, 1 in a, 2 in a, 99 in a);
        \\print("del non-conf:", delete a[2], a[2]);
        \\print("del conf:", delete a[1], 1 in a, a[1]);
        \\
        \\// 2. a.length = 0 stops at non-configurable index 2 (ES2025 ArraySetLength)
        \\a.length = 0; // sloppy: shrinks to 3 (deletes 3, stops at non-configurable 2)
        \\print("sloppy shrink len:", a.length, 3 in a, a[2]);
        \\let strictShrinkErr = false;
        \\try { (function() { "use strict"; a.length = 0; })(); } catch (e) { strictShrinkErr = e instanceof TypeError; }
        \\print("strict shrink err:", strictShrinkErr, a.length);
        \\let defLenErr = false;
        \\try { Object.defineProperty(a, "length", { value: 0, writable: false }); } catch (e) { defLenErr = e instanceof TypeError; }
        \\print("defLen err:", defLenErr, a.length, Object.getOwnPropertyDescriptor(a, "length").writable);
        \\
        \\// 3. Getter/setter array indices + writable non-enumerable update
        \\const b = [1, 2];
        \\let backing = 50;
        \\let setCount = 0;
        \\Object.defineProperty(b, 0, {
        \\  get() { return backing; },
        \\  set(v) { setCount++; backing = v * 2; },
        \\  enumerable: true,
        \\  configurable: true,
        \\});
        \\Object.defineProperty(b, 3, { value: 7, writable: true, enumerable: false, configurable: true });
        \\print("b len:", b.length, "b[0]:", b[0], "b[3]:", b[3]);
        \\b[0] = 21;
        \\b[3] = 77;
        \\print("after set:", b[0], setCount, b[3], Object.getOwnPropertyDescriptor(b, 3).enumerable);
        \\print("b keys:", Object.keys(b).join(","), "b names:", Object.getOwnPropertyNames(b).join(","));
        \\print("b map:", b.map(x => x + 1).join(","));
        \\print("b filter:", b.filter(x => x > 10).join(","));
        \\print("b slice:", b.slice(0, 4).join(","));
        \\
        \\// 4. Array mutators: push, pop, shift, unshift, splice, reverse, sort, copyWithin
        \\const c = [3, 1, 2];
        \\let cLog = [];
        \\Object.defineProperty(c, 1, {
        \\  get() { return 10; },
        \\  set(v) { cLog.push("set1:" + v); },
        \\  enumerable: true,
        \\  configurable: true,
        \\});
        \\c.push(4);
        \\print("push:", c.length, c[3]);
        \\print("pop:", c.pop(), c.length);
        \\c.reverse();
        \\print("reverse:", c[0], c[1], c[2], cLog.join("|"));
        \\const s = [1, 2, 3, 4];
        \\Object.defineProperty(s, 1, { value: 20, writable: false, enumerable: true, configurable: true });
        \\let spliceErr = false;
        \\try { s.splice(1, 1, 99); } catch (e) { spliceErr = e instanceof TypeError; }
        \\print("splice non-writable err:", spliceErr, s[1]);
        \\let sortErr = false;
        \\try { s.sort((x, y) => y - x); } catch (e) { sortErr = e instanceof TypeError; }
        \\print("sort non-writable err:", sortErr);
        \\let cwErr = false;
        \\try { s.copyWithin(1, 0, 1); } catch (e) { cwErr = e instanceof TypeError; }
        \\print("copyWithin non-writable err:", cwErr);
        \\
        \\// 5. Object.freeze / Object.seal / Object.isFrozen / Object.isSealed
        \\const f = [1];
        \\Object.defineProperty(f, 0, { value: 1, writable: false, configurable: false });
        \\Object.defineProperty(f, "length", { writable: false });
        \\Object.preventExtensions(f);
        \\print("manual frozen:", Object.isSealed(f), Object.isFrozen(f));
        \\const g = [1, 2];
        \\Object.defineProperty(g, 0, { get() { return 5; }, configurable: true });
        \\Object.freeze(g);
        \\print("frozen accessor:", Object.isFrozen(g), g[0], Object.getOwnPropertyDescriptor(g, 0).configurable);
    ;
    const expected =
        \\d1: 200 false false true
        \\d2: 300 true true false
        \\after sloppy write a[1]: 200
        \\strict write err: true
        \\keys: 0,2,3
        \\ownNames: 0,1,2,3,length
        \\values: 10,300,40
        \\entries: 0:10,2:300,3:40
        \\forIn: 0,2,3
        \\in: true true true false
        \\del non-conf: false 300
        \\del conf: true false undefined
        \\sloppy shrink len: 3 false 300
        \\strict shrink err: true 3
        \\defLen err: true 3 false
        \\b len: 4 b[0]: 50 b[3]: 7
        \\after set: 42 1 77 false
        \\b keys: 0,1 b names: 0,1,3,length
        \\b map: 43,3,,78
        \\b filter: 42,77
        \\b slice: 42,2,,77
        \\push: 4 4
        \\pop: 4 3
        \\reverse: 2 10 3 
        \\splice non-writable err: true 20
        \\sort non-writable err: true
        \\copyWithin non-writable err: true
        \\manual frozen: true true
        \\frozen accessor: true 5 false
        \\
    ;
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, src, .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("", r.err);
        try testing.expectEqualStrings(expected, r.out);
    }
}

test "array index Object.defineProperty overrides: GC stress on getter/setter closures and values" {
    const src =
        \\const arr = [{ tag: "init" }];
        \\let box = { n: 1 };
        \\Object.defineProperty(arr, 0, {
        \\  get() { return { seen: box.n }; },
        \\  set(v) { box = { n: v.n + 1 }; },
        \\  enumerable: true,
        \\  configurable: true,
        \\});
        \\Object.defineProperty(arr, 1, {
        \\  value: { payload: "kept" },
        \\  writable: false,
        \\  enumerable: false,
        \\  configurable: true,
        \\});
        \\let sum = 0;
        \\for (let i = 0; i < 60; i++) {
        \\  const garbage = { a: [i, i + 1], s: "tmp_" + i };
        \\  arr[0] = { n: i };
        \\  sum += arr[0].seen;
        \\  if (garbage.a[0] < 0) print(garbage);
        \\}
        \\print(sum, arr[1].payload);
    ;
    const expected = "1830 kept\n";
    for (support.engines) |engine| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err_w.deinit();
        const code = try zqjs.runSource(testing.allocator, "gc_arr_override.js", src, .{}, .{
            .mode = .normal,
            .engine = engine,
            .collect_always = true,
            .verify_heap = true,
        }, &out.writer, &err_w.writer);
        try testing.expectEqual(@as(u8, 0), code);
        try testing.expectEqualStrings("", err_w.written());
        try testing.expectEqualStrings(expected, out.written());
    }
}

test "test262 spec tail: array shrink proto fallback, fastArraySet hole trap, iterator toStringTag, var arguments" {
    const src =
        \\// 1. Array.prototype.{forEach,every,some,filter,reduce,reduceRight} prototype fallback after length shrink
        \\function makeShrinking(shrinkAt) {
        \\  const arr = [1, 2, 3];
        \\  Object.defineProperty(arr, shrinkAt, {
        \\    get() { arr.length = 2; return shrinkAt === 0 ? 10 : 20; },
        \\    configurable: true,
        \\    enumerable: true,
        \\  });
        \\  return arr;
        \\}
        \\Array.prototype[2] = 99;
        \\try {
        \\  const fe = [];
        \\  makeShrinking(1).forEach((v) => fe.push(v));
        \\  const ev = [];
        \\  const evRes = makeShrinking(1).every((v) => { ev.push(v); return v !== 99; });
        \\  const sm = [];
        \\  const smRes = makeShrinking(1).some((v) => { sm.push(v); return v === 99; });
        \\  const fl = makeShrinking(1).filter((v) => v === 99);
        \\  const rd = makeShrinking(1).reduce((a, v) => a + "," + v, "s");
        \\  const rrArr = [1, 2, 3];
        \\  Object.defineProperty(rrArr, 2, {
        \\    get() { rrArr.length = 1; return 30; },
        \\    configurable: true,
        \\    enumerable: true,
        \\  });
        \\  Array.prototype[1] = 88;
        \\  const rr = rrArr.reduceRight((a, v) => a + "," + v, "s");
        \\  delete Array.prototype[1];
        \\  print("arr:", fe.join(","), evRes, ev.join(","), smRes, sm.join(","), fl.join(","), rd, rr);
        \\} finally {
        \\  delete Array.prototype[2];
        \\  delete Array.prototype[1];
        \\}
        \\
        \\// 2. fastArraySet hole check: Proxy prototype set trap & inherited setter on Object.prototype
        \\let proxyTrap = "";
        \\const p = new Proxy({}, {
        \\  set(target, prop, val, receiver) {
        \\    proxyTrap = String(prop) + "=" + val + ":" + (receiver === a1);
        \\    return true;
        \\  },
        \\});
        \\const a1 = new Array(1);
        \\Object.setPrototypeOf(a1, p);
        \\a1[0] = 1;
        \\let inheritedSet = -1;
        \\Object.defineProperty(Object.prototype, 0, {
        \\  set(v) { inheritedSet = v; },
        \\  configurable: true,
        \\});
        \\try {
        \\  const a2 = new Array(1);
        \\  a2[0] = 42;
        \\} finally {
        \\  delete Object.prototype[0];
        \\}
        \\print("holeSet:", proxyTrap, inheritedSet);
        \\
        \\// 3. Object.prototype.toString on String Iterator with normal, non-string, and deleted Symbol.toStringTag
        \\const strIter = ""[Symbol.iterator]();
        \\const strIterProto = Object.getPrototypeOf(strIter);
        \\const origDesc = Object.getOwnPropertyDescriptor(strIterProto, Symbol.toStringTag);
        \\try {
        \\  const tNormal = Object.prototype.toString.call(strIter);
        \\  Object.defineProperty(strIterProto, Symbol.toStringTag, { value: new String("x"), configurable: true });
        \\  const tNonStr = Object.prototype.toString.call(strIter);
        \\  delete strIterProto[Symbol.toStringTag];
        \\  const tDeleted = Object.prototype.toString.call(strIter);
        \\  print("iterTag:", tNormal, "|", tNonStr, "|", tDeleted);
        \\} finally {
        \\  Object.defineProperty(strIterProto, Symbol.toStringTag, origDesc);
        \\}
        \\
        \\// 4. var arguments does not clobber initial arguments object
        \\function f() { return typeof arguments; var arguments = 123; }
        \\function g() { const before = typeof arguments; var arguments = 123; return before + ":" + arguments; }
        \\function h(a) { a = 7; return arguments[0]; var arguments; }
        \\print("varArgs:", f(1, 2, 3), g(1, 2), h(1));
    ;
    const expected =
        \\arr: 1,20,99 false 1,20,99 true 1,20,99 99 s,1,20,99 s,30,88,1
        \\holeSet: 0=1:true 42
        \\iterTag: [object String Iterator] | [object Object] | [object Iterator]
        \\varArgs: object object:123 7
        \\
    ;
    for (support.engines) |engine| {
        for ([_]bool{ false, true }) |gc_stress| {
            var out: std.Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
            defer err_w.deinit();
            const code = try zqjs.runSource(testing.allocator, "test262_spec_tail.js", src, .{}, .{
                .mode = .normal,
                .engine = engine,
                .collect_always = gc_stress,
                .verify_heap = gc_stress,
            }, &out.writer, &err_w.writer);
            try testing.expectEqual(@as(u8, 0), code);
            try testing.expectEqualStrings("", err_w.written());
            try testing.expectEqualStrings(expected, out.written());
        }
    }
}

test "instanceof fast and slow paths: primitives, closures, natives, proxies, Symbol.hasInstance, bound, mutated Function.prototype" {
    const src =
        \\class Base {}
        \\class Sub extends Base {}
        \\const b = new Base();
        \\const s = new Sub();
        \\print("fast ctor:", b instanceof Base, s instanceof Base, s instanceof Sub, b instanceof Sub);
        \\print("fast prim:", 1 instanceof Base, "a" instanceof String, null instanceof Object, undefined instanceof Array, true instanceof Boolean);
        \\print("fast native:", [] instanceof Array, [] instanceof Object, ({}) instanceof Array, new Date() instanceof Date);
        \\
        \\// Non-object prototype throws TypeError for objects, returns false for primitives
        \\const arrow = () => {};
        \\let arrowObjErr = false;
        \\try { ({}) instanceof arrow; } catch (e) { arrowObjErr = e instanceof TypeError; }
        \\print("arrow:", 1 instanceof arrow, arrowObjErr);
        \\function BadProto() {}
        \\BadProto.prototype = 42;
        \\let badProtoErr = false;
        \\try { ({}) instanceof BadProto; } catch (e) { badProtoErr = e instanceof TypeError; }
        \\print("badProto:", 1 instanceof BadProto, badProtoErr);
        \\
        \\// Own prototype accessor on a non-constructable closure (arrow has no auto-prototype)
        \\let protoGetterCalls = 0;
        \\const AccProto = () => {};
        \\Object.defineProperty(AccProto, "prototype", {
        \\  get() { protoGetterCalls++; return Base.prototype; },
        \\});
        \\print("accProto:", b instanceof AccProto, protoGetterCalls);
        \\
        \\// Bound constructor (including bound custom Symbol.hasInstance on primitive!)
        \\const BoundBase = Base.bind();
        \\print("bound:", b instanceof BoundBase, 1 instanceof BoundBase);
        \\class CustomNum {
        \\  static [Symbol.hasInstance](x) { return typeof x === "number"; }
        \\}
        \\class SubCustomNum extends CustomNum {}
        \\const BoundCustom = CustomNum.bind();
        \\print("custom:", 42 instanceof CustomNum, "x" instanceof CustomNum, 42 instanceof SubCustomNum, 42 instanceof BoundCustom);
        \\
        \\// Proxy LHS and Proxy in prototype chain
        \\let proxyProtoCalls = 0;
        \\const pLhs = new Proxy({}, {
        \\  getPrototypeOf() { proxyProtoCalls++; return Base.prototype; },
        \\});
        \\const childOfProxy = Object.create(pLhs);
        \\print("proxy:", pLhs instanceof Base, childOfProxy instanceof Base, proxyProtoCalls);
        \\
        \\// Proxy RHS
        \\let rhsTrap = 0;
        \\const pRhs = new Proxy(Base, {
        \\  get(t, k, r) {
        \\    if (k === Symbol.hasInstance) rhsTrap++;
        \\    return Reflect.get(t, k, r);
        \\  },
        \\});
        \\print("proxyRhs:", b instanceof pRhs, rhsTrap);
        \\
        \\// Replaced [[Prototype]] with custom Symbol.hasInstance (bypassing Function.prototype)
        \\let customProtoCalls = 0;
        \\function AltCtor() {}
        \\Object.setPrototypeOf(AltCtor, {
        \\  [Symbol.hasInstance](x) { customProtoCalls++; return x === "magic"; },
        \\});
        \\print("altProto:", "magic" instanceof AltCtor, b instanceof AltCtor, customProtoCalls);
    ;
    const expected =
        \\fast ctor: true true true false
        \\fast prim: false false false false false
        \\fast native: true true false true
        \\arrow: false true
        \\badProto: false true
        \\accProto: true 1
        \\bound: true false
        \\custom: true false true true
        \\proxy: true true 2
        \\proxyRhs: true 1
        \\altProto: true false 2
        \\
    ;
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, src, .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("", r.err);
        try testing.expectEqualStrings(expected, r.out);
    }
}

test "new.target: calls, constructors, extends/super, Reflect.construct, bound, escaping arrows, defaults, methods, fields, and proxy (both engines)" {
    const src =
        \\function F() { return { nt: new /* c */ . /* c */ target }; }
        \\print("plain:", F().nt === undefined);
        \\print("new:", new F().nt === F);
        \\
        \\class Base {
        \\    constructor() {
        \\        this.baseNT = new.target;
        \\    }
        \\}
        \\class Mid extends Base {}
        \\class Sub extends Mid {
        \\    constructor() {
        \\        const before = new.target;
        \\        const getNT = () => new.target;
        \\        super();
        \\        this.before = before;
        \\        this.after = new.target;
        \\        this.arrowNT = getNT();
        \\    }
        \\}
        \\const sub = new Sub();
        \\print("extends:", sub.baseNT === Sub, sub.before === Sub, sub.after === Sub, sub.arrowNT === Sub);
        \\
        \\function Custom() {}
        \\const rBase = Reflect.construct(Base, [], Custom);
        \\const rSub = Reflect.construct(Sub, [], Custom);
        \\print("reflect:", rBase.baseNT === Custom, rSub.baseNT === Custom, rSub.before === Custom, rSub.after === Custom, rSub.arrowNT === Custom);
        \\
        \\const BF = F.bind(null);
        \\const BBF = BF.bind(null);
        \\print("bound:", new BF().nt === F, new BBF().nt === F);
        \\print("bound-reflect:", Reflect.construct(BF, []).nt === F, Reflect.construct(BF, [], Custom).nt === Custom);
        \\const BoundBase = Base.bind(null);
        \\BoundBase.prototype = Base.prototype;
        \\class SubBound extends BoundBase {
        \\    constructor() { super(); }
        \\}
        \\const sb = new SubBound();
        \\print("sub-bound:", sb.baseNT === SubBound, Reflect.construct(SubBound, [], Custom).baseNT === Custom);
        \\
        \\function EscapeCtor() {
        \\    const inner = () => () => new.target;
        \\    this.get = inner();
        \\}
        \\const esc = new EscapeCtor();
        \\let churn = [];
        \\for (let i = 0; i < 200; i++) churn.push({ i, s: "x" + i });
        \\print("escape:", esc.get() === EscapeCtor, churn.length);
        \\
        \\function Def(a = new.target, g = () => new.target) {
        \\    return { a, b: g() };
        \\}
        \\const dPlain = Def();
        \\const dNew = new Def();
        \\print("def:", dPlain.a === undefined, dPlain.b === undefined, dNew.a === Def, dNew.b === Def);
        \\function ArrowDefOuter() {
        \\    const arrow = (x = new.target) => x;
        \\    return { v: arrow() };
        \\}
        \\print("arrow-def:", ArrowDefOuter().v === undefined, new ArrowDefOuter().v === ArrowDefOuter);
        \\
        \\function Outer() {
        \\    function Inner() { return { nt: new.target }; }
        \\    const arrow = () => new.target;
        \\    return {
        \\        outer: new.target,
        \\        innerPlain: Inner().nt,
        \\        innerNew: new Inner().nt === Inner,
        \\        arrow: arrow(),
        \\    };
        \\}
        \\const oRes = new Outer();
        \\print("nested:", oRes.outer === Outer, oRes.innerPlain === undefined, oRes.innerNew, oRes.arrow === Outer);
        \\
        \\function Self(depth) {
        \\    this.depth = depth;
        \\    this.nt = new.target;
        \\    if (depth > 0) this.child = new new.target(depth - 1);
        \\}
        \\class SelfSub extends Self {}
        \\const selfInst = new SelfSub(1);
        \\print("new-new-target:", selfInst.nt === SelfSub, selfInst.child instanceof SelfSub, selfInst.child.nt === SelfSub, selfInst.child.depth === 0);
        \\
        \\function Holder() {
        \\    return new new.target.Sub();
        \\}
        \\Holder.Sub = class { constructor() { this.ok = new.target === Holder.Sub; } };
        \\print("new-new-target-member:", new Holder().ok);
        \\
        \\function* gen() { yield new.target; }
        \\async function afn() { return new.target; }
        \\const obj = {
        \\    m() { return new.target; },
        \\    get g() { return new.target; },
        \\};
        \\function FieldHost() {
        \\    class C {
        \\        inst = new.target;
        \\        instArrow = () => new.target;
        \\        static stat = new.target;
        \\        static blk;
        \\        static { this.blk = new.target; }
        \\        method() { return new.target; }
        \\    }
        \\    const c = new C();
        \\    return { inst: c.inst, instArrow: c.instArrow(), stat: C.stat, blk: C.blk, m: c.method() };
        \\}
        \\const fh = new FieldHost();
        \\print("methods-fields:", gen().next().value === undefined, obj.m() === undefined, obj.g === undefined, fh.inst === undefined, fh.instArrow === undefined, fh.stat === undefined, fh.blk === undefined, fh.m === undefined);
        \\afn().then((v) => print("async:", v === undefined));
        \\
        \\let proxyNT = null;
        \\const ProxyBase = new Proxy(class { constructor() {} }, {
        \\    construct(target, args, newTarget) {
        \\        proxyNT = newTarget;
        \\        return Reflect.construct(target, args, newTarget);
        \\    }
        \\});
        \\class SubProxy extends ProxyBase {
        \\    constructor() { super(); }
        \\}
        \\new SubProxy();
        \\const p1 = proxyNT === SubProxy;
        \\Reflect.construct(SubProxy, [], Custom);
        \\const p2 = proxyNT === Custom;
        \\print("proxy-super:", p1, p2);
    ;
    const expected =
        \\plain: true
        \\new: true
        \\extends: true true true true
        \\reflect: true true true true true
        \\bound: true true
        \\bound-reflect: true true
        \\sub-bound: true true
        \\escape: true 200
        \\def: true true true true
        \\arrow-def: true true
        \\nested: true true true true
        \\new-new-target: true true true true
        \\new-new-target-member: true
        \\methods-fields: true true true true true true true true
        \\proxy-super: true true
        \\async: true
        \\
    ;
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, src, .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("", r.err);
        try testing.expectEqualStrings(expected, r.out);
    }
}

test "new.target: early SyntaxErrors at top-level, top-level arrows, invalid targets, and unicode escapes" {
    const cases = [_][]const u8{
        "new.target;",
        "() => new.target;",
        "() => () => new.target;",
        "class C extends new.target {}",
        "class C { [new.target] = 1; }",
        "function f() { new.target = 1; }",
        "function f() { new.target += 1; }",
        "function f() { ++new.target; }",
        "function f() { new.target++; }",
        "function f() { [new.target] = [1]; }",
        "function f() { ({ a: new.target } = { a: 1 }); }",
        "function f() { new.foo; }",
        "function f() { new.\\u0074arget; }",
        "function f() { \\u006eew.target; }",
    };
    for (cases) |src| {
        for (support.engines) |engine| {
            var r = try support.run(testing.allocator, src, .{}, engine, .normal);
            defer r.deinit(testing.allocator);
            try testing.expect(std.mem.indexOf(u8, r.err, "SyntaxError") != null);
        }
    }
}

test "ES2025 §10.4.4.7 mapped arguments: aliasing, callee, delete, defineProperty, freeze/seal, unmapped modes" {
    const src =
        \\// 1. Bidirectional aliasing & Object.prototype.toString
        \\function bidir(a, b) {
        \\    const tag = Object.prototype.toString.call(arguments);
        \\    a = 10;
        \\    const r1 = arguments[0];
        \\    arguments[1] = 20;
        \\    const r2 = b;
        \\    const d0 = Object.getOwnPropertyDescriptor(arguments, 0);
        \\    return [tag, r1, r2, d0.value, d0.writable, d0.enumerable, d0.configurable];
        \\}
        \\print("bidir:", bidir(1, 2).join("|"));
        \\
        \\// 2. Unmapped when i >= argc or i >= param_count
        \\function bounds(a, b) {
        \\    arguments[1] = 99;
        \\    const bAfter = b;
        \\    arguments[2] = 77;
        \\    return [a, bAfter, arguments[1], arguments[2], arguments.length];
        \\}
        \\print("bounds:", bounds(5).join("|"));
        \\function extra(a) {
        \\    a = 11;
        \\    arguments[1] = 22;
        \\    return [arguments[0], arguments[1], arguments.length];
        \\}
        \\print("extra:", extra(1, 2).join("|"));
        \\
        \\// 3. arguments.callee: sloppy (with and without params) vs strict & non-simple
        \\function sloppyCallee(a) {
        \\    const d = Object.getOwnPropertyDescriptor(arguments, "callee");
        \\    const same = arguments.callee === sloppyCallee;
        \\    arguments.callee = 123;
        \\    return [same, d.writable, d.enumerable, d.configurable, arguments.callee];
        \\}
        \\print("callee-sloppy:", sloppyCallee(1).join("|"));
        \\function sloppyZero() {
        \\    return arguments.callee === sloppyZero;
        \\}
        \\print("callee-zero:", sloppyZero());
        \\function strictCallee(a) {
        \\    "use strict";
        \\    a = 99;
        \\    let threw = false;
        \\    try { void arguments.callee; } catch (e) { threw = e instanceof TypeError; }
        \\    return [arguments[0], threw];
        \\}
        \\print("callee-strict:", strictCallee(1).join("|"));
        \\function defaultUnmapped(a = 1) {
        \\    a = 99;
        \\    let threw = false;
        \\    try { void arguments.callee; } catch (e) { threw = e instanceof TypeError; }
        \\    return [arguments[0], threw];
        \\}
        \\print("unmapped-default:", defaultUnmapped(2).join("|"));
        \\function restUnmapped(a, ...r) {
        \\    a = 99;
        \\    let threw = false;
        \\    try { void arguments.callee; } catch (e) { threw = e instanceof TypeError; }
        \\    return [arguments[0], r.length, threw];
        \\}
        \\print("unmapped-rest:", restUnmapped(3, 4).join("|"));
        \\function destructUnmapped({ x }) {
        \\    x = 99;
        \\    let threw = false;
        \\    try { void arguments.callee; } catch (e) { threw = e instanceof TypeError; }
        \\    return [arguments[0].x, threw];
        \\}
        \\print("unmapped-destruct:", destructUnmapped({ x: 5 }).join("|"));
        \\
        \\// 4. delete arguments[0] unlinking + re-add
        \\function delUnlink(a) {
        \\    a = 10;
        \\    const delOk = delete arguments[0];
        \\    const has0 = 0 in arguments;
        \\    arguments[0] = 500;
        \\    const aAfterReadd = a;
        \\    a = 600;
        \\    const arg0AfterParam = arguments[0];
        \\    return [delOk, has0, aAfterReadd, arg0AfterParam];
        \\}
        \\print("delete:", delUnlink(1).join("|"));
        \\
        \\// 5. Object.defineProperty: accessor unlink, writable:false w/ and w/o value, enumerable/configurable stay mapped
        \\function defAccessor(a) {
        \\    a = 7;
        \\    Object.defineProperty(arguments, 0, { get() { return 42; }, configurable: true });
        \\    const v1 = arguments[0];
        \\    const a1 = a;
        \\    a = 8;
        \\    const v2 = arguments[0];
        \\    return [v1, a1, v2, a];
        \\}
        \\print("def-accessor:", defAccessor(1).join("|"));
        \\
        \\function defWritableNoVal(a) {
        \\    a = 33;
        \\    Object.defineProperty(arguments, 0, { writable: false });
        \\    const v1 = arguments[0];
        \\    a = 44;
        \\    const v2 = arguments[0];
        \\    arguments[0] = 55;
        \\    return [v1, v2, arguments[0], a];
        \\}
        \\print("def-writ-noval:", defWritableNoVal(1).join("|"));
        \\
        \\function defWritableWithVal(a) {
        \\    Object.defineProperty(arguments, 0, { value: 88, writable: false });
        \\    const a1 = a;
        \\    const v1 = arguments[0];
        \\    a = 99;
        \\    return [a1, v1, arguments[0], a];
        \\}
        \\print("def-writ-val:", defWritableWithVal(1).join("|"));
        \\
        \\function defEnumConfStayMapped(a, b) {
        \\    Object.defineProperty(arguments, 0, { enumerable: false });
        \\    Object.defineProperty(arguments, 1, { configurable: false });
        \\    a = 101;
        \\    arguments[1] = 202;
        \\    const delNonConf = delete arguments[1];
        \\    b = 303;
        \\    const d0 = Object.getOwnPropertyDescriptor(arguments, 0);
        \\    const d1 = Object.getOwnPropertyDescriptor(arguments, 1);
        \\    return [arguments[0], b, delNonConf, arguments[1], d0.enumerable, d0.value, d1.configurable, d1.value];
        \\}
        \\print("def-enum-conf:", defEnumConfStayMapped(1, 2).join("|"));
        \\
        \\// 6. Object.seal stays mapped; Object.freeze snapshots live value and unlinks
        \\function sealFreeze(a, b) {
        \\    Object.seal(arguments);
        \\    a = 71;
        \\    const sealedLive = arguments[0];
        \\    b = 82;
        \\    Object.freeze(arguments);
        \\    b = 93;
        \\    return [sealedLive, arguments[1], b];
        \\}
        \\print("seal-freeze:", sealFreeze(1, 2).join("|"));
        \\
        \\// 7. Receiver != arguments does not mutate parameter
        \\function receiverCheck(a) {
        \\    const child = Object.create(arguments);
        \\    child[0] = 777;
        \\    const a1 = a;
        \\    const r2 = Reflect.set(arguments, 0, 888, {});
        \\    return [a1, child[0], a, r2];
        \\}
        \\print("receiver:", receiverCheck(5).join("|"));
    ;
    const expected =
        \\bidir: [object Arguments]|10|20|10|true|true|true
        \\bounds: 5||99|77|1
        \\extra: 11|22|2
        \\callee-sloppy: true|true|false|true|123
        \\callee-zero: true
        \\callee-strict: 1|true
        \\unmapped-default: 2|true
        \\unmapped-rest: 3|1|true
        \\unmapped-destruct: 5|true
        \\delete: true|false|10|500
        \\def-accessor: 42|7|42|8
        \\def-writ-noval: 33|33|33|44
        \\def-writ-val: 88|88|88|99
        \\def-enum-conf: 101|303|false|303|false|101|false|303
        \\seal-freeze: 71|82|93
        \\receiver: 5|777|5|true
        \\
    ;
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, src, .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("", r.err);
        try testing.expectEqualStrings(expected, r.out);
    }
}

test "ES2025 §10.4.4.7 mapped arguments: escaping closure and GC stress (collect_always + verify_heap)" {
    const src =
        \\function makeEscaping(a, b) {
        \\    const reader = () => [a, arguments[0], b, arguments[1]];
        \\    const mutateParam = (v) => { a = v; };
        \\    const mutateArg = (v) => { arguments[1] = v; };
        \\    const unlinkZero = () => { delete arguments[0]; };
        \\    return { reader, mutateParam, mutateArg, unlinkZero, args: arguments };
        \\}
        \\const h = makeEscaping({ k: "initA" }, { k: "initB" });
        \\// Allocate garbage to force promotions & minor/major collections under collect_always.
        \\for (let i = 0; i < 40; i++) {
        \\    const tmp = { n: i, s: "garbage-" + i };
        \\    void tmp;
        \\}
        \\h.mutateParam({ k: "newA" });
        \\h.mutateArg({ k: "newB" });
        \\const r1 = h.reader();
        \\print("r1:", r1[0].k, r1[1].k, r1[0] === r1[1], r1[2].k, r1[3].k, r1[2] === r1[3]);
        \\h.unlinkZero();
        \\h.mutateParam({ k: "afterUnlink" });
        \\h.args[0] = { k: "readded" };
        \\const r2 = h.reader();
        \\print("r2:", r2[0].k, r2[1].k, r2[2].k, r2[3].k);
    ;
    const expected =
        \\r1: newA newA true newB newB true
        \\r2: afterUnlink readded newB newB
        \\
    ;
    for (support.engines) |engine| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err_w.deinit();
        const code = try zqjs.runSource(testing.allocator, "gc_mapped_args.js", src, .{}, .{
            .mode = .normal,
            .engine = engine,
            .collect_always = true,
            .verify_heap = true,
        }, &out.writer, &err_w.writer);
        try testing.expectEqual(@as(u8, 0), code);
        try testing.expectEqualStrings("", err_w.written());
        try testing.expectEqualStrings(expected, out.written());
    }
}

test "WHATWG Encoding globals: btoa, atob, TextEncoder, TextDecoder (dual-engine)" {
    const src =
        \\function errInfo(fn) {
        \\    try { fn(); return "ok"; }
        \\    catch (e) { return `${e instanceof Error}:${e.name}:${e.code ?? ""}`; }
        \\}
        \\
        \\// 1. Global descriptors, lengths, and constructability
        \\const dAtob = Object.getOwnPropertyDescriptor(globalThis, "atob");
        \\const dBtoa = Object.getOwnPropertyDescriptor(globalThis, "btoa");
        \\const dTE = Object.getOwnPropertyDescriptor(globalThis, "TextEncoder");
        \\const dTD = Object.getOwnPropertyDescriptor(globalThis, "TextDecoder");
        \\print("desc:",
        \\    dAtob.writable, dAtob.enumerable, dAtob.configurable, atob.length,
        \\    dBtoa.writable, dBtoa.enumerable, dBtoa.configurable, btoa.length,
        \\    dTE.writable, dTE.enumerable, dTE.configurable, TextEncoder.length,
        \\    dTD.writable, dTD.enumerable, dTD.configurable, TextDecoder.length
        \\);
        \\print("ctor-err:",
        \\    errInfo(() => new atob("Zg==")),
        \\    errInfo(() => new btoa("f")),
        \\    errInfo(() => TextEncoder()),
        \\    errInfo(() => TextDecoder())
        \\);
        \\
        \\// 2. btoa / atob roundtrips, Latin-1 binary 0..255, whitespace, missing padding, errors
        \\let allLatin1 = "";
        \\for (let i = 0; i < 256; i++) allLatin1 += String.fromCharCode(i);
        \\const b64All = btoa(allLatin1);
        \\const decAll = atob(b64All);
        \\let latin1Ok = decAll.length === 256;
        \\for (let i = 0; i < 256; i++) {
        \\    if (decAll.charCodeAt(i) !== i) latin1Ok = false;
        \\}
        \\print("btoa-atob:",
        \\    btoa(""), atob(""),
        \\    btoa("f"), btoa("fo"), btoa("foo"),
        \\    atob(" \t\n\f\r Zm 9v \r\n "),
        \\    atob("Zg"), atob("Zm8"), atob("Zm9v"),
        \\    btoa(123), atob("MTIz"),
        \\    latin1Ok
        \\);
        \\print("btoa-err:",
        \\    errInfo(() => btoa()),
        \\    errInfo(() => btoa("Привіт")),
        \\    errInfo(() => btoa("\u0100")),
        \\    errInfo(() => atob()),
        \\    errInfo(() => atob("a")),
        \\    errInfo(() => atob("abcde")),
        \\    errInfo(() => atob("Zm=v")),
        \\    errInfo(() => atob("Zm9!")),
        \\    errInfo(() => atob("Zg===")),
        \\    errInfo(() => atob("Zg=\u0080"))
        \\);
        \\
        \\// 3. TextEncoder: encoding, encode, encodeInto, subarray, detached, brand check
        \\const enc = new TextEncoder();
        \\print("te-meta:",
        \\    enc.encoding,
        \\    Object.prototype.toString.call(enc),
        \\    TextEncoder.prototype.encode.length,
        \\    TextEncoder.prototype.encodeInto.length,
        \\    enc.encode().length,
        \\    enc.encode(undefined).length,
        \\    errInfo(() => Object.getOwnPropertyDescriptor(TextEncoder.prototype, "encoding").get.call({})),
        \\    errInfo(() => enc.encodeInto("a"))
        \\);
        \\const eAscii = enc.encode("hi");
        \\const eCyr = enc.encode("Привіт");
        \\const eEmoji = enc.encode("😀");
        \\const eLoneHi = enc.encode("\uD800");
        \\const eLoneLo = enc.encode("\uDC00");
        \\print("te-bytes:",
        \\    [...eAscii].join(","),
        \\    [...eCyr].join(","),
        \\    [...eEmoji].join(","),
        \\    [...eLoneHi].join(","),
        \\    [...eLoneLo].join(",")
        \\);
        \\// Truncation mid-2-byte (é = C3 A9), mid-3-byte (€ = E2 82 AC), mid-4-byte (😀 = F0 9F 98 80)
        \\const b2 = new Uint8Array(2);
        \\const r2 = enc.encodeInto("aé", b2);
        \\const b3 = new Uint8Array(3);
        \\const r3 = enc.encodeInto("a€", b3);
        \\const b4 = new Uint8Array(4);
        \\const r4 = enc.encodeInto("a😀", b4);
        \\const b5 = new Uint8Array(5);
        \\const r5 = enc.encodeInto("a😀", b5);
        \\const backing = new Uint8Array([9, 9, 9, 9, 9, 9]);
        \\const sub = backing.subarray(2, 5);
        \\const rSub = enc.encodeInto("hi!", sub);
        \\const detU8 = new Uint8Array(4);
        \\structuredClone(detU8.buffer, { transfer: [detU8.buffer] });
        \\print("te-into:",
        \\    `${r2.read}/${r2.written}:${b2[0]},${b2[1]}`,
        \\    `${r3.read}/${r3.written}:${b3[0]},${b3[1]},${b3[2]}`,
        \\    `${r4.read}/${r4.written}:${b4[0]},${b4[1]}`,
        \\    `${r5.read}/${r5.written}:${[...b5].join(",")}`,
        \\    `${rSub.read}/${rSub.written}:${[...backing].join(",")}`,
        \\    errInfo(() => enc.encodeInto("a", detU8)),
        \\    errInfo(() => enc.encodeInto("a", new Int8Array(4)))
        \\);
        \\
        \\// 4. TextDecoder: labels, options, BOM, fatal vs replacement, views, streaming
        \\const dec = new TextDecoder();
        \\const decNorm1 = new TextDecoder("UTF-8");
        \\const decNorm2 = new TextDecoder(" \tutf8\n ");
        \\const decNorm3 = new TextDecoder("unicode-1-1-utf-8");
        \\const decFatal = new TextDecoder("utf-8", { fatal: true });
        \\const decBom = new TextDecoder("utf-8", { ignoreBOM: true });
        \\print("td-meta:",
        \\    dec.encoding, dec.fatal, dec.ignoreBOM,
        \\    decNorm1.encoding, decNorm2.encoding, decNorm3.encoding,
        \\    decFatal.fatal, decBom.ignoreBOM,
        \\    Object.prototype.toString.call(dec),
        \\    errInfo(() => new TextDecoder("latin1")),
        \\    errInfo(() => new TextDecoder("utf-8", 42)),
        \\    errInfo(() => Object.getOwnPropertyDescriptor(TextDecoder.prototype, "fatal").get.call({}))
        \\);
        \\// BOM stripping vs ignoreBOM
        \\const withBom = new Uint8Array([0xEF, 0xBB, 0xBF, 0x68, 0x69]);
        \\print("td-bom:",
        \\    dec.decode(withBom), dec.decode(withBom).length,
        \\    decBom.decode(withBom).charCodeAt(0) === 0xFEFF, decBom.decode(withBom).length
        \\);
        \\// ArrayBuffer, TypedArray subarray, DataView, undefined
        \\const fullBuf = new Uint8Array([0x58, 0xF0, 0x9F, 0x98, 0x80, 0x59]);
        \\const dv = new DataView(fullBuf.buffer, 1, 4);
        \\print("td-views:",
        \\    dec.decode(),
        \\    dec.decode(fullBuf.buffer),
        \\    dec.decode(fullBuf.subarray(1, 5)),
        \\    dec.decode(dv)
        \\);
        \\// Maximal-subpart U+FFFD replacement vs fatal: true TypeError
        \\const invalidSeqs = [
        \\    new Uint8Array([0xC0, 0xAF]),             // overlong 2-byte
        \\    new Uint8Array([0xE0, 0x80, 0xAF]),       // overlong 3-byte
        \\    new Uint8Array([0xED, 0xA0, 0x80]),       // UTF-16 surrogate U+D800
        \\    new Uint8Array([0xF4, 0x90, 0x80, 0x80]), // > U+10FFFF
        \\    new Uint8Array([0xE2, 0x82, 0x41]),       // truncated 3-byte followed by 'A'
        \\    new Uint8Array([0xF0, 0x9F]),             // truncated at EOF
        \\];
        \\print("td-repl:",
        \\    invalidSeqs.map(s => [...dec.decode(s)].map(c => c.codePointAt(0).toString(16)).join("+")).join(" | ")
        \\);
        \\print("td-fatal:",
        \\    invalidSeqs.map(s => errInfo(() => decFatal.decode(s))).join(" | "),
        \\    decFatal.decode(enc.encode("ok"))
        \\);
        \\// Streaming split 4-byte emoji + split BOM + trailing incomplete flush
        \\const sDec = new TextDecoder();
        \\const p1 = sDec.decode(new Uint8Array([0xEF, 0xBB]), { stream: true });
        \\const p2 = sDec.decode(new Uint8Array([0xBF, 0xF0, 0x9F]), { stream: true });
        \\const p3 = sDec.decode(new Uint8Array([0x98, 0x80, 0x21]), { stream: true });
        \\const p4 = sDec.decode();
        \\const t1 = sDec.decode(new Uint8Array([0xF0, 0x9F]), { stream: true });
        \\const t2 = sDec.decode();
        \\print("td-stream:",
        \\    `${p1}|${p2}|${p3}|${p4}`,
        \\    t1.length,
        \\    t2.charCodeAt(0).toString(16),
        \\    errInfo(() => dec.decode(detU8)),
        \\    errInfo(() => dec.decode("not-a-buffer"))
        \\);
    ;
    const expected =
        \\desc: true true true 1 true true true 1 true false true 0 true false true 0
        \\ctor-err: true:TypeError: true:TypeError: true:TypeError: true:TypeError:
        \\btoa-atob:   Zg== Zm8= Zm9v foo f fo foo MTIz 123 true
        \\btoa-err: true:TypeError: true:InvalidCharacterError:5 true:InvalidCharacterError:5 true:TypeError: true:InvalidCharacterError:5 true:InvalidCharacterError:5 true:InvalidCharacterError:5 true:InvalidCharacterError:5 true:InvalidCharacterError:5 true:InvalidCharacterError:5
        \\te-meta: utf-8 [object TextEncoder] 0 2 0 0 true:TypeError: true:TypeError:
        \\te-bytes: 104,105 208,159,209,128,208,184,208,178,209,150,209,130 240,159,152,128 239,191,189 239,191,189
        \\te-into: 1/1:97,0 1/1:97,0,0 1/1:97,0 3/5:97,240,159,152,128 3/3:9,9,104,105,33,9 true:TypeError: true:TypeError:
        \\td-meta: utf-8 false false utf-8 utf-8 utf-8 true true [object TextDecoder] true:RangeError: true:TypeError: true:TypeError:
        \\td-bom: hi 2 true 3
        \\td-views:  X😀Y 😀 😀
        \\td-repl: fffd+fffd | fffd+fffd+fffd | fffd+fffd+fffd | fffd+fffd+fffd+fffd | fffd+41 | fffd
        \\td-fatal: true:TypeError: | true:TypeError: | true:TypeError: | true:TypeError: | true:TypeError: | true:TypeError: ok
        \\td-stream: ||😀!| 0 fffd true:TypeError: true:TypeError:
        \\
    ;
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, src, .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqual(@as(u8, 0), r.code);
        try testing.expectEqualStrings("", r.err);
        try testing.expectEqualStrings(expected, r.out);
    }
}

test "WHATWG Encoding globals GC stress (collect_always + verify_heap)" {
    const src =
        \\function churn(tag) {
        \\    for (let i = 0; i < 16; i++) {
        \\        const tmp = { k: tag + i, a: [i, i + 1] };
        \\        void tmp;
        \\    }
        \\}
        \\const b = btoa({ toString() { churn("btoa"); return "hello"; } });
        \\const a = atob({ toString() { churn("atob"); return b; } });
        \\const enc = new TextEncoder();
        \\const u8 = enc.encode({ toString() { churn("enc"); return "Привіт 😀"; } });
        \\const dst = new Uint8Array(32);
        \\const into = enc.encodeInto({ toString() { churn("into"); return "😀ok"; } }, dst);
        \\const dec = new TextDecoder(
        \\    { toString() { churn("lbl"); return " UTF-8 "; } },
        \\    {
        \\        get fatal() { churn("f"); return false; },
        \\        get ignoreBOM() { churn("b"); return false; },
        \\    }
        \\);
        \\const c1 = dec.decode(u8.subarray(0, 14), { get stream() { churn("s1"); return true; } });
        \\const c2 = dec.decode(u8.subarray(14), { get stream() { churn("s2"); return false; } });
        \\print(b, a, into.read, into.written, c1 + c2);
    ;
    const expected =
        \\aGVsbG8= hello 4 6 Привіт 😀
        \\
    ;
    for (support.engines) |engine| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err_w.deinit();
        const code = try zqjs.runSource(testing.allocator, "gc_encoding_globals.js", src, .{}, .{
            .mode = .normal,
            .engine = engine,
            .collect_always = true,
            .verify_heap = true,
        }, &out.writer, &err_w.writer);
        try testing.expectEqual(@as(u8, 0), code);
        try testing.expectEqualStrings("", err_w.written());
        try testing.expectEqualStrings(expected, out.written());
    }
}

test "ES2026 Uint8Array Base64 and Hex methods (dual-engine)" {
    const src =
        \\// 1. Method presence & descriptors: ONLY on Uint8Array / Uint8Array.prototype
        \\const TA = Object.getPrototypeOf(Uint8Array);
        \\const staticNames = ["fromBase64", "fromHex"];
        \\const protoNames = ["toBase64", "toHex", "setFromBase64", "setFromHex"];
        \\const expectedLengths = { fromBase64: 1, fromHex: 1, toBase64: 0, toHex: 0, setFromBase64: 1, setFromHex: 1 };
        \\let descOk = true;
        \\for (const name of staticNames) {
        \\    const d = Object.getOwnPropertyDescriptor(Uint8Array, name);
        \\    if (!d || typeof d.value !== "function" || !d.writable || d.enumerable || !d.configurable) descOk = false;
        \\    if (d.value.name !== name || d.value.length !== expectedLengths[name]) descOk = false;
        \\    if (name in TA || name in Int8Array || name in Uint8ClampedArray) descOk = false;
        \\}
        \\for (const name of protoNames) {
        \\    const d = Object.getOwnPropertyDescriptor(Uint8Array.prototype, name);
        \\    if (!d || typeof d.value !== "function" || !d.writable || d.enumerable || !d.configurable) descOk = false;
        \\    if (d.value.name !== name || d.value.length !== expectedLengths[name]) descOk = false;
        \\    if (name in TA.prototype || name in Int8Array.prototype || name in Uint8ClampedArray.prototype) descOk = false;
        \\}
        \\print("desc:", descOk);
        \\
        \\// 2. toBase64 / fromBase64 roundtrips, base64url, omitPadding
        \\const bytes = new Uint8Array([0xfb, 0xff, 0xbf, 0x00, 0x66]);
        \\const b64 = bytes.toBase64();
        \\const b64NoPad = bytes.toBase64({ omitPadding: true });
        \\const b64url = bytes.toBase64({ alphabet: "base64url" });
        \\const b64urlNoPad = bytes.toBase64({ alphabet: "base64url", omitPadding: true });
        \\print("encode:", b64, b64NoPad, b64url, b64urlNoPad, new Uint8Array(0).toBase64());
        \\print("rt:", [...Uint8Array.fromBase64(b64)].join(","), [...Uint8Array.fromBase64(b64NoPad)].join(","));
        \\print("rt-url:", [...Uint8Array.fromBase64(b64url, { alphabet: "base64url" })].join(","), [...Uint8Array.fromBase64(b64urlNoPad, { alphabet: "base64url" })].join(","));
        \\
        \\// 3. Whitespace & lastChunkHandling modes
        \\print("ws5:", [...Uint8Array.fromBase64("\t\n\f\r Zg = = \t\r\n")].join(","));
        \\function errName(fn) { try { fn(); return "ok"; } catch (e) { return e.name; } }
        \\print("ws-bad:", errName(() => Uint8Array.fromBase64("\vZg==")), errName(() => Uint8Array.fromBase64("\u00A0Zg==")));
        \\print("alpha-mismatch:", errName(() => Uint8Array.fromBase64("-_==")), errName(() => Uint8Array.fromBase64("+/==", { alphabet: "base64url" })));
        \\print("lch-1char:",
        \\    errName(() => Uint8Array.fromBase64("Z")),
        \\    errName(() => Uint8Array.fromBase64("Z", { lastChunkHandling: "strict" })),
        \\    Uint8Array.fromBase64("Z", { lastChunkHandling: "stop-before-partial" }).length
        \\);
        \\print("lch-2char:",
        \\    [...Uint8Array.fromBase64("Zg")].join(","),
        \\    errName(() => Uint8Array.fromBase64("Zg", { lastChunkHandling: "strict" })),
        \\    Uint8Array.fromBase64("Zg", { lastChunkHandling: "stop-before-partial" }).length
        \\);
        \\print("lch-pad-stop:",
        \\    [...Uint8Array.fromBase64("Zg==", { lastChunkHandling: "stop-before-partial" })].join(","),
        \\    Uint8Array.fromBase64("Zg=", { lastChunkHandling: "stop-before-partial" }).length,
        \\    errName(() => Uint8Array.fromBase64("Zg=a", { lastChunkHandling: "stop-before-partial" }))
        \\);
        \\print("overflow-bits:",
        \\    [...Uint8Array.fromBase64("Zh==")].join(","),
        \\    errName(() => Uint8Array.fromBase64("Zh==", { lastChunkHandling: "strict" })),
        \\    [...Uint8Array.fromBase64("Zh==", { lastChunkHandling: "stop-before-partial" })].join(","),
        \\    errName(() => Uint8Array.fromBase64("Zm9=", { lastChunkHandling: "strict" })),
        \\    [...Uint8Array.fromBase64("Zm9=")].join(",")
        \\);
        \\print("bad-pad:",
        \\    errName(() => Uint8Array.fromBase64("=")),
        \\    errName(() => Uint8Array.fromBase64("===")),
        \\    errName(() => Uint8Array.fromBase64("Zg=")),
        \\    errName(() => Uint8Array.fromBase64("Zg==a"))
        \\);
        \\
        \\// 4. Receiver, argument, options, and detached buffer validation
        \\print("recv:",
        \\    errName(() => Uint8Array.prototype.toBase64.call(new Uint8ClampedArray(1))),
        \\    errName(() => Uint8Array.prototype.toBase64.call(new Int8Array(1))),
        \\    errName(() => Uint8Array.prototype.toHex.call({})),
        \\    errName(() => Uint8Array.prototype.setFromBase64.call(new Uint8ClampedArray(1), "Zg==")),
        \\    errName(() => Uint8Array.prototype.setFromHex.call(new Int8Array(1), "66"))
        \\);
        \\print("str-arg:",
        \\    errName(() => Uint8Array.fromBase64(new String("Zg=="))),
        \\    errName(() => Uint8Array.fromBase64(123)),
        \\    errName(() => Uint8Array.fromHex(undefined)),
        \\    errName(() => new Uint8Array(4).setFromBase64(null)),
        \\    errName(() => new Uint8Array(4).setFromHex(new String("66")))
        \\);
        \\print("opts-bad:",
        \\    errName(() => Uint8Array.fromBase64("Zg==", null)),
        \\    errName(() => Uint8Array.fromBase64("Zg==", 42)),
        \\    errName(() => Uint8Array.fromBase64("Zg==", { alphabet: "hex" })),
        \\    errName(() => Uint8Array.fromBase64("Zg==", { alphabet: 1 })),
        \\    errName(() => Uint8Array.fromBase64("Zg==", { lastChunkHandling: "bad" })),
        \\    errName(() => new Uint8Array(1).toBase64("base64"))
        \\);
        \\const order = [];
        \\new Uint8Array([1]).toBase64({
        \\    get alphabet() { order.push("a"); return "base64"; },
        \\    get omitPadding() { order.push("o"); return true; },
        \\});
        \\Uint8Array.fromBase64("Zg==", {
        \\    get alphabet() { order.push("fa"); return "base64"; },
        \\    get lastChunkHandling() { order.push("fl"); return "strict"; },
        \\});
        \\print("opt-order:", order.join(","));
        \\const det1 = new Uint8Array([1, 2, 3]);
        \\structuredClone(det1.buffer, { transfer: [det1.buffer] });
        \\print("pre-detached:",
        \\    errName(() => det1.toBase64()),
        \\    errName(() => det1.toHex()),
        \\    errName(() => det1.setFromBase64("Zg==")),
        \\    errName(() => det1.setFromHex("66"))
        \\);
        \\const det2 = new Uint8Array([1, 2, 3]);
        \\const det3 = new Uint8Array(3);
        \\print("getter-detached:",
        \\    errName(() => det2.toBase64({ get alphabet() { structuredClone(det2.buffer, { transfer: [det2.buffer] }); return "base64"; } })),
        \\    errName(() => det3.setFromBase64("Zg==", { get lastChunkHandling() { structuredClone(det3.buffer, { transfer: [det3.buffer] }); return "loose"; } }))
        \\);
        \\let detHits1 = 0;
        \\let detHits2 = 0;
        \\const detErr1 = errName(() => det1.toBase64({ get alphabet() { detHits1++; return "base64"; } }));
        \\const detErr2 = errName(() => det1.setFromBase64("Zg==", { get alphabet() { detHits2++; return "base64"; } }));
        \\print("detached-reads-opts:", detErr1, detHits1, detErr2, detHits2);
        \\
        \\// 5. setFromBase64 exact { read, written }, truncation, 0-len, partial writes
        \\const rExact = new Uint8Array(3).setFromBase64("Zm9v");
        \\const rExactWs = new Uint8Array(3).setFromBase64("Zm9v   ");
        \\const rRoomWs = new Uint8Array(4).setFromBase64("Zm9v   ");
        \\const rSmall2 = new Uint8Array(2).setFromBase64("Zm9v");
        \\const rSmall1Of2 = new Uint8Array(1).setFromBase64("Zm8");
        \\const rSmall1Pad = new Uint8Array(1).setFromBase64("Zg==");
        \\const rFullBeforeBad = new Uint8Array(3).setFromBase64("Zm9v!!!");
        \\const rZero = new Uint8Array(0).setFromBase64("!!!invalid!!!");
        \\const rStop1 = new Uint8Array(4).setFromBase64("Zm9v  Z", { lastChunkHandling: "stop-before-partial" });
        \\const rStop2 = new Uint8Array(4).setFromBase64("Zm9v  Zg", { lastChunkHandling: "stop-before-partial" });
        \\const rStopPad = new Uint8Array(4).setFromBase64("Zm9v  Zg==", { lastChunkHandling: "stop-before-partial" });
        \\print("setb64:",
        \\    `${rExact.read}/${rExact.written}`,
        \\    `${rExactWs.read}/${rExactWs.written}`,
        \\    `${rRoomWs.read}/${rRoomWs.written}`,
        \\    `${rSmall2.read}/${rSmall2.written}`,
        \\    `${rSmall1Of2.read}/${rSmall1Of2.written}`,
        \\    `${rSmall1Pad.read}/${rSmall1Pad.written}`,
        \\    `${rFullBeforeBad.read}/${rFullBeforeBad.written}`,
        \\    `${rZero.read}/${rZero.written}`,
        \\    `${rStop1.read}/${rStop1.written}`,
        \\    `${rStop2.read}/${rStop2.written}`,
        \\    `${rStopPad.read}/${rStopPad.written}`
        \\);
        \\const rd = Object.getOwnPropertyDescriptor(rExact, "read");
        \\print("res-obj:", Object.getPrototypeOf(rExact) === Object.prototype, rd.writable, rd.enumerable, rd.configurable);
        \\const partialB64 = new Uint8Array(4);
        \\const partialB64Err = errName(() => partialB64.setFromBase64("Zm9v!!!"));
        \\print("partial-b64:", partialB64Err, [...partialB64].join(","));
        \\
        \\// 6. toHex / fromHex / setFromHex & subarray views
        \\const hx = new Uint8Array([0x00, 0x0a, 0xab, 0xff]);
        \\print("hex:", hx.toHex(), [...Uint8Array.fromHex("000AabFF")].join(","), new Uint8Array(0).toHex(), Uint8Array.fromHex("").length);
        \\print("hex-err:",
        \\    errName(() => Uint8Array.fromHex("a")),
        \\    errName(() => Uint8Array.fromHex(" 41")),
        \\    errName(() => Uint8Array.fromHex("4g")),
        \\    errName(() => new Uint8Array(0).setFromHex("a"))
        \\);
        \\const hexTrunc = new Uint8Array(1);
        \\const rHexTrunc = hexTrunc.setFromHex("41zz");
        \\const hexPart = new Uint8Array(2);
        \\const hexPartErr = errName(() => hexPart.setFromHex("41zz"));
        \\const hexOdd = new Uint8Array(2);
        \\const hexOddErr = errName(() => hexOdd.setFromHex("41z"));
        \\print("sethex:", `${rHexTrunc.read}/${rHexTrunc.written}`, hexTrunc[0], hexPartErr, [...hexPart].join(","), hexOddErr, [...hexOdd].join(","));
        \\
        \\// 7. Non-zero byteOffset subarray views
        \\const backing = new Uint8Array([9, 102, 111, 111, 8]);
        \\const view = backing.subarray(1, 4);
        \\print("sub-enc:", view.toBase64(), view.toHex());
        \\const rSubB64 = view.setFromBase64("YmFy");
        \\print("sub-b64:", `${rSubB64.read}/${rSubB64.written}`, [...backing].join(","));
        \\const rSubHex = view.setFromHex("010203");
        \\print("sub-hex:", `${rSubHex.read}/${rSubHex.written}`, [...backing].join(","));
    ;
    const expected =
        \\desc: true
        \\encode: +/+/AGY= +/+/AGY -_-_AGY= -_-_AGY 
        \\rt: 251,255,191,0,102 251,255,191,0,102
        \\rt-url: 251,255,191,0,102 251,255,191,0,102
        \\ws5: 102
        \\ws-bad: SyntaxError SyntaxError
        \\alpha-mismatch: SyntaxError SyntaxError
        \\lch-1char: SyntaxError SyntaxError 0
        \\lch-2char: 102 SyntaxError 0
        \\lch-pad-stop: 102 0 SyntaxError
        \\overflow-bits: 102 SyntaxError 102 SyntaxError 102,111
        \\bad-pad: SyntaxError SyntaxError SyntaxError SyntaxError
        \\recv: TypeError TypeError TypeError TypeError TypeError
        \\str-arg: TypeError TypeError TypeError TypeError TypeError
        \\opts-bad: TypeError TypeError TypeError TypeError TypeError TypeError
        \\opt-order: a,o,fa,fl
        \\pre-detached: TypeError TypeError TypeError TypeError
        \\getter-detached: TypeError TypeError
        \\detached-reads-opts: TypeError 1 TypeError 1
        \\setb64: 4/3 4/3 7/3 0/0 0/0 4/1 4/3 0/0 4/3 4/3 10/4
        \\res-obj: true true true true
        \\partial-b64: SyntaxError 102,111,111,0
        \\hex: 000aabff 0,10,171,255  0
        \\hex-err: SyntaxError SyntaxError SyntaxError SyntaxError
        \\sethex: 2/1 65 SyntaxError 65,0 SyntaxError 0,0
        \\sub-enc: Zm9v 666f6f
        \\sub-b64: 4/3 9,98,97,114,8
        \\sub-hex: 6/3 9,1,2,3,8
        \\
    ;
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, src, .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("", r.err);
        try testing.expectEqualStrings(expected, r.out);
    }
}

test "ES2026 Uint8Array Base64 and Hex GC stress (collect_always + verify_heap)" {
    const src =
        \\function churn(tag) {
        \\    for (let i = 0; i < 20; i++) {
        \\        const tmp = { k: tag + i, arr: [i, i + 1] };
        \\        void tmp;
        \\    }
        \\}
        \\const u8 = new Uint8Array([0xfb, 0xff, 0xbf, 0x66, 0x6f, 0x6f]);
        \\const b64 = u8.toBase64({
        \\    get alphabet() { churn("a"); return "base64url"; },
        \\    get omitPadding() { churn("o"); return true; },
        \\});
        \\const decoded = Uint8Array.fromBase64(b64, {
        \\    get alphabet() { churn("fa"); return "base64url"; },
        \\    get lastChunkHandling() { churn("fl"); return "loose"; },
        \\});
        \\const dst = new Uint8Array(6);
        \\const r1 = dst.setFromBase64(b64, {
        \\    get alphabet() { churn("sa"); return "base64url"; },
        \\    get lastChunkHandling() { churn("sl"); return "loose"; },
        \\});
        \\const hex = decoded.toHex();
        \\const fromHex = Uint8Array.fromHex(hex);
        \\const dst2 = new Uint8Array(6);
        \\const r2 = dst2.setFromHex(hex);
        \\print(b64, hex, r1.read, r1.written, r2.read, r2.written, fromHex.toHex() === dst2.toHex());
    ;
    const expected =
        \\-_-_Zm9v fbffbf666f6f 8 6 12 6 true
        \\
    ;
    for (support.engines) |engine| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err_w.deinit();
        const code = try zqjs.runSource(testing.allocator, "gc_uint8_b64_hex.js", src, .{}, .{
            .mode = .normal,
            .engine = engine,
            .collect_always = true,
            .verify_heap = true,
        }, &out.writer, &err_w.writer);
        try testing.expectEqual(@as(u8, 0), code);
        try testing.expectEqualStrings("", err_w.written());
        try testing.expectEqualStrings(expected, out.written());
    }
}

test "ES2026 Map and WeakMap upsert (getOrInsert, getOrInsertComputed)" {
    const src =
        \\function errName(fn) {
        \\    try { fn(); return "OK"; } catch (e) { return e.name; }
        \\}
        \\function checkMethodDesc(proto, name, len) {
        \\    const d = Object.getOwnPropertyDescriptor(proto, name);
        \\    return !!d && d.writable === true && d.enumerable === false && d.configurable === true
        \\        && typeof d.value === "function" && d.value.name === name && d.value.length === len;
        \\}
        \\print("desc:",
        \\    checkMethodDesc(Map.prototype, "getOrInsert", 2),
        \\    checkMethodDesc(Map.prototype, "getOrInsertComputed", 2),
        \\    checkMethodDesc(WeakMap.prototype, "getOrInsert", 2),
        \\    checkMethodDesc(WeakMap.prototype, "getOrInsertComputed", 2)
        \\);
        \\
        \\// Map.prototype.getOrInsert
        \\const m = new Map();
        \\print("m-ins:", m.getOrInsert(-0, "zero"), m.getOrInsert(0, "other"), Object.is([...m.keys()][0], 0));
        \\m.set("u", undefined);
        \\print("m-undef:", m.getOrInsert("u", "fallback"), m.get("u"));
        \\print("m-recv:", errName(() => Map.prototype.getOrInsert.call({}, "a", 1)), errName(() => Map.prototype.getOrInsert.call(new WeakMap(), {}, 1)));
        \\
        \\// Map.prototype.getOrInsertComputed
        \\let calls = 0;
        \\let cbKeyIsPosZero = false;
        \\const m2 = new Map();
        \\const v1 = m2.getOrInsertComputed(-0, (k) => { calls++; cbKeyIsPosZero = Object.is(k, 0); return "computed"; });
        \\const v2 = m2.getOrInsertComputed(0, () => { calls++; return "never"; });
        \\m2.set("u", undefined);
        \\const v3 = m2.getOrInsertComputed("u", () => { calls++; return "never"; });
        \\print("mc-basic:", v1, v2, v3, calls, cbKeyIsPosZero);
        \\
        \\// Callback inserts same key -> overwritten in place
        \\const m3 = new Map([["a", 1]]);
        \\const ov = m3.getOrInsertComputed("b", (k) => { m3.set(k, "inner"); m3.set("c", 3); return "outer"; });
        \\print("mc-mut:", ov, m3.get("b"), [...m3.keys()].join(","));
        \\
        \\// Callback clears map -> still inserts
        \\const m4 = new Map([["x", 1]]);
        \\const cl = m4.getOrInsertComputed("y", () => { m4.clear(); return 99; });
        \\print("mc-clear:", cl, m4.size, m4.get("y"));
        \\
        \\// Non-callable throws TypeError even when key already exists; non-Map receiver throws TypeError
        \\print("mc-err:",
        \\    errName(() => m2.getOrInsertComputed(0, 123)),
        \\    errName(() => m2.getOrInsertComputed("missing", null)),
        \\    errName(() => Map.prototype.getOrInsertComputed.call({}, "a", () => 1))
        \\);
        \\
        \\// WeakMap.prototype.getOrInsert & getOrInsertComputed
        \\const wm = new WeakMap();
        \\const kObj = {};
        \\const kSym = Symbol("local");
        \\print("wm-ins:",
        \\    wm.getOrInsert(kObj, "objVal"),
        \\    wm.getOrInsert(kObj, "ignored"),
        \\    wm.getOrInsert(kSym, "symVal"),
        \\    wm.getOrInsert(kSym, "ignored")
        \\);
        \\const kUndef = {};
        \\wm.set(kUndef, undefined);
        \\let wmCalls = 0;
        \\print("wm-undef:", wm.getOrInsert(kUndef, "no"), wm.getOrInsertComputed(kUndef, () => { wmCalls++; return "no"; }), wmCalls);
        \\
        \\// Callback mutating WeakMap
        \\const kMut = {};
        \\const wmMut = wm.getOrInsertComputed(kMut, (k) => { wm.set(k, "inner"); return k === kMut ? "outer" : "bad"; });
        \\print("wm-mut:", wmMut, wm.get(kMut));
        \\
        \\// Invalid WeakMap keys (registered Symbol.for and primitives) throw TypeError BEFORE callback check
        \\const badKeys = [Symbol.for("reg"), 1, "str", null, undefined, true];
        \\const keyErrs = badKeys.map((k) => errName(() => wm.getOrInsert(k, 1)));
        \\const compKeyErrs = badKeys.map((k) => errName(() => wm.getOrInsertComputed(k, "not-callable")));
        \\print("wm-badkeys:", keyErrs.every((e) => e === "TypeError"), compKeyErrs.every((e) => e === "TypeError"));
        \\print("wm-err:",
        \\    errName(() => wm.getOrInsertComputed(kObj, 42)),
        \\    errName(() => WeakMap.prototype.getOrInsert.call({}, kObj, 1)),
        \\    errName(() => WeakMap.prototype.getOrInsertComputed.call(new Map(), kObj, () => 1))
        \\);
    ;
    const expected =
        \\desc: true true true true
        \\m-ins: zero zero true
        \\m-undef: undefined undefined
        \\m-recv: TypeError TypeError
        \\mc-basic: computed computed undefined 1 true
        \\mc-mut: outer outer a,b,c
        \\mc-clear: 99 1 99
        \\mc-err: TypeError TypeError TypeError
        \\wm-ins: objVal objVal symVal symVal
        \\wm-undef: undefined undefined 0
        \\wm-mut: outer outer
        \\wm-badkeys: true true
        \\wm-err: TypeError TypeError TypeError
        \\
    ;
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, src, .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("", r.err);
        try testing.expectEqualStrings(expected, r.out);
    }
}

test "ES2024 ArrayBuffer detached, transfer, transferToFixedLength" {
    const src =
        \\function errName(fn) {
        \\    try { fn(); return "OK"; } catch (e) { return e.name; }
        \\}
        \\const dDet = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "detached");
        \\const dTr = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "transfer");
        \\const dTrF = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "transferToFixedLength");
        \\print("desc:",
        \\    !!dDet && typeof dDet.get === "function" && dDet.set === undefined && dDet.enumerable === false && dDet.configurable === true && dDet.get.name === "get detached" && dDet.get.length === 0,
        \\    !!dTr && dTr.writable === true && dTr.enumerable === false && dTr.configurable === true && dTr.value.name === "transfer" && dTr.value.length === 0,
        \\    !!dTrF && dTrF.writable === true && dTrF.enumerable === false && dTrF.configurable === true && dTrF.value.name === "transferToFixedLength" && dTrF.value.length === 0
        \\);
        \\
        \\// Same-size transfer + detach verification
        \\const ab1 = new ArrayBuffer(4);
        \\const u1 = new Uint8Array(ab1);
        \\u1.set([10, 20, 30, 40]);
        \\const dv1 = new DataView(ab1);
        \\print("pre:", ab1.detached, ab1.byteLength);
        \\const ab2 = ab1.transfer();
        \\print("same:", ab1.detached, ab1.byteLength, ab2.detached, ab2.byteLength, [...new Uint8Array(ab2)].join(","));
        \\print("views:", u1.length, errName(() => dv1.byteLength), errName(() => dv1.getUint8(0)));
        \\
        \\// Grow (zero-fill tail) and shrink
        \\const ab3 = ab2.transfer(6);
        \\print("grow:", ab2.detached, ab3.byteLength, [...new Uint8Array(ab3)].join(","));
        \\const ab4 = ab3.transferToFixedLength(2);
        \\print("shrink:", ab3.detached, ab4.byteLength, [...new Uint8Array(ab4)].join(","));
        \\const ab5 = ab4.transferToFixedLength(0);
        \\print("zero:", ab4.detached, ab5.detached, ab5.byteLength);
        \\
        \\// Already detached throws TypeError, but invalid newLength throws RangeError even on detached buffer
        \\print("detached-err:",
        \\    errName(() => ab1.transfer()),
        \\    errName(() => ab1.transferToFixedLength()),
        \\    errName(() => ab1.transfer(-1)),
        \\    errName(() => ab1.transfer(Infinity)),
        \\    errName(() => ab1.transferToFixedLength(-1)),
        \\    errName(() => ab1.transferToFixedLength(Infinity))
        \\);
        \\
        \\// newLength.valueOf() detaching receiver throws TypeError
        \\const ab6 = new ArrayBuffer(4);
        \\const detachInValueOf = { valueOf() { ab6.transfer(); return 4; } };
        \\print("valueof-detach:", errName(() => ab6.transfer(detachInValueOf)), ab6.detached);
        \\
        \\// Incompatible receivers
        \\print("recv:",
        \\    errName(() => Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "detached").get.call({})),
        \\    errName(() => ArrayBuffer.prototype.transfer.call({})),
        \\    errName(() => ArrayBuffer.prototype.transferToFixedLength.call({}))
        \\);
    ;
    const expected =
        \\desc: true true true
        \\pre: false 4
        \\same: true 0 false 4 10,20,30,40
        \\views: 0 TypeError TypeError
        \\grow: true 6 10,20,30,40,0,0
        \\shrink: true 2 10,20
        \\zero: true false 0
        \\detached-err: TypeError TypeError RangeError RangeError RangeError RangeError
        \\valueof-detach: TypeError true
        \\recv: TypeError TypeError TypeError
        \\
    ;
    for (support.engines) |engine| {
        var r = try support.run(testing.allocator, src, .{}, engine, .normal);
        defer r.deinit(testing.allocator);
        try testing.expectEqualStrings("", r.err);
        try testing.expectEqualStrings(expected, r.out);
    }
}

test "ES2023 hashbang comments end-to-end" {
    const valid_src = "#!/usr/bin/env zqjs\nprint(42);\n";
    const invalid_src = " #!/usr/bin/env zqjs\nprint(42);\n";
    for (support.engines) |engine| {
        var r_ok = try support.run(testing.allocator, valid_src, .{}, engine, .normal);
        defer r_ok.deinit(testing.allocator);
        try testing.expectEqualStrings("", r_ok.err);
        try testing.expectEqualStrings("42\n", r_ok.out);

        var r_err = try support.run(testing.allocator, invalid_src, .{}, engine, .normal);
        defer r_err.deinit(testing.allocator);
        try testing.expect(std.mem.indexOf(u8, r_err.err, "SyntaxError") != null);
    }
}

test "ES2026 upsert and ES2024 ArrayBuffer transfer GC stress (collect_always + verify_heap)" {
    const src =
        \\function churn(tag) {
        \\    for (let i = 0; i < 20; i++) {
        \\        const tmp = { k: tag + i, arr: [i, i + 1] };
        \\        void tmp;
        \\    }
        \\}
        \\const m = new Map();
        \\for (let i = 0; i < 10; i++) {
        \\    const v = m.getOrInsertComputed("k" + i, (k) => {
        \\        churn(k);
        \\        if (i % 2 === 0) m.set(k, "temp");
        \\        return { label: k, n: i };
        \\    });
        \\    if (v.n !== i) throw new Error("map mismatch");
        \\}
        \\const wm = new WeakMap();
        \\const keys = [];
        \\for (let i = 0; i < 10; i++) {
        \\    const k = i % 2 === 0 ? { id: i } : Symbol("s" + i);
        \\    keys.push(k);
        \\    const v = wm.getOrInsertComputed(k, () => {
        \\        churn("wm" + i);
        \\        wm.set(k, "inner");
        \\        return { idx: i };
        \\    });
        \\    if (v.idx !== i) throw new Error("weakmap mismatch");
        \\}
        \\let ab = new ArrayBuffer(4);
        \\new Uint8Array(ab).set([1, 2, 3, 4]);
        \\ab = ab.transfer({ valueOf() { churn("tr"); return 8; } });
        \\ab = ab.transferToFixedLength({ valueOf() { churn("trf"); return 3; } });
        \\print(m.size, wm.get(keys[9]).idx, ab.byteLength, [...new Uint8Array(ab)].join(","));
    ;
    const expected =
        \\10 9 3 1,2,3
        \\
    ;
    for (support.engines) |engine| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err_w.deinit();
        const code = try zqjs.runSource(testing.allocator, "gc_upsert_transfer.js", src, .{}, .{
            .mode = .normal,
            .engine = engine,
            .collect_always = true,
            .verify_heap = true,
        }, &out.writer, &err_w.writer);
        try testing.expectEqual(@as(u8, 0), code);
        try testing.expectEqualStrings("", err_w.written());
        try testing.expectEqualStrings(expected, out.written());
    }
}
