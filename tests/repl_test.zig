//! Integration tests for M41 (D71): Interactive REPL.

const std = @import("std");
const testing = std.testing;
const zqjs = @import("zqjs_internal");
const Session = zqjs.repl.Session;
const inspect = zqjs.repl.inspect;
const complete = zqjs.repl.complete;
const editor = zqjs.repl.editor;
const Engine = zqjs.Engine;

fn makeDiscardWriter() std.Io.Writer.Discarding {
    var buf: [256]u8 = undefined;
    return .init(&buf);
}

fn evalInspect(s: *Session, src: []const u8, color: bool) ![]u8 {
    var out_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();

    const outcome = try s.eval(src);
    switch (outcome) {
        .value => |v| {
            try inspect.inspect(&s.rt, v, &out_aw.writer, .{ .color = color });
            return out_aw.toOwnedSlice();
        },
        .thrown => return testing.allocator.dupe(u8, "<thrown>"),
        .failed => return testing.allocator.dupe(u8, "<failed>"),
        .empty => return testing.allocator.dupe(u8, "<empty>"),
    }
}

fn expectEval(s: *Session, src: []const u8, expected: []const u8) !void {
    const actual = try evalInspect(s, src, false);
    defer testing.allocator.free(actual);
    if (!std.mem.eql(u8, expected, "<failed>") and std.mem.eql(u8, actual, "<failed>")) {
        std.debug.print("\n[expectEval FAILED] src={s}\n", .{src});
    }
    try testing.expectEqualStrings(expected, actual);
}

test "repl: persistent bindings, closures, destructuring, redeclaration, _ and _error (vm & treewalk)" {
    for ([_]Engine{ .vm, .treewalk }) |eng| {
        var out_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out_aw.deinit();
        var err_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err_aw.deinit();

        const s = try Session.create(testing.allocator, &out_aw.writer, &err_aw.writer, .{
            .engine = eng,
            .limits = .{ .max_steps = 500_000 },
        });
        defer s.destroy();

        // let + closure across lines
        try expectEval(s, "let x = 1;", "undefined");
        try expectEval(s, "function inc() { x = x + 1; return x; }", "undefined");
        try expectEval(s, "inc();", "2");
        try expectEval(s, "x;", "2");
        // `_` tracks last expression value
        try expectEval(s, "_ + 10;", "12");

        // const persistence and write rejection
        try expectEval(s, "const c = 42;", "undefined");
        try expectEval(s, "c;", "42");
        try expectEval(s, "c = 99;", "<thrown>");
        // `_error` tracks last uncaught error
        try expectEval(s, "_error.name;", "'TypeError'");

        // Cross-chunk const redeclaration is SyntaxError
        err_aw.clearRetainingCapacity();
        try expectEval(s, "const c = 100;", "<failed>");
        try testing.expect(std.mem.indexOf(u8, err_aw.written(), "SyntaxError") != null);
        try expectEval(s, "let c = 100;", "<failed>");

        // Cross-chunk let/function/class redeclaration replaces entry
        try expectEval(s, "let x = 100;", "undefined");
        try expectEval(s, "x;", "100");
        // Old closure still sees its captured cell (which was 2)
        try expectEval(s, "inc();", "3");

        // Same-chunk redeclaration remains SyntaxError
        try expectEval(s, "let dup = 1; let dup = 2;", "<failed>");

        // Destructuring & class across lines
        try expectEval(s, "const { a, b } = { a: 7, b: 8 };", "undefined");
        try expectEval(s, "const [p, q] = [10, 20];", "undefined");
        try expectEval(s, "a + b + p + q;", "45");

        try expectEval(s, "class Point { constructor(x, y) { this.x = x; this.y = y; } }", "undefined");
        try expectEval(s, "new Point(3, 4);", "Point { x: 3, y: 4 }");
    }
}

test "repl: transactional error recovery & LimitExceeded(steps) recovery (vm & treewalk)" {
    for ([_]Engine{ .vm, .treewalk }) |eng| {
        var out_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out_aw.deinit();
        var err_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err_aw.deinit();

        const s = try Session.create(testing.allocator, &out_aw.writer, &err_aw.writer, .{
            .engine = eng,
            .limits = .{ .max_steps = 5_000 },
        });
        defer s.destroy();

        try expectEval(s, "let good = 10;", "undefined");
        // Runtime throw before initialization must clean up TDZ cell
        try expectEval(s, "function boom() { throw new Error('kaboom'); }", "undefined");
        try expectEval(s, "let bad = boom();", "<thrown>");
        // `bad` should not be poisoned in TDZ; redeclaring it works, reading it is ReferenceError
        try expectEval(s, "bad;", "<thrown>");
        try expectEval(s, "_error.message;", "'bad is not defined'");
        try expectEval(s, "let bad = 77;", "undefined");
        try expectEval(s, "bad;", "77");

        // Infinite loop hits LimitExceeded(steps), but session recovers on next line
        err_aw.clearRetainingCapacity();
        try expectEval(s, "let loopVar = (() => { while (true) {} })();", "<failed>");
        try testing.expect(std.mem.indexOf(u8, err_aw.written(), "LimitExceeded(steps)") != null);
        try expectEval(s, "good + 5;", "15");
        try expectEval(s, "let loopVar = 99;", "undefined");
        try expectEval(s, "loopVar;", "99");
    }
}

test "repl: top-level await & for await (vm & treewalk)" {
    for ([_]Engine{ .vm, .treewalk }) |eng| {
        var out_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out_aw.deinit();
        var err_aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer err_aw.deinit();

        const s = try Session.create(testing.allocator, &out_aw.writer, &err_aw.writer, .{
            .engine = eng,
        });
        defer s.destroy();

        try expectEval(s, "let val = await Promise.resolve(21);", "undefined");
        try expectEval(s, "val * 2;", "42");
        try expectEval(s, "await Promise.resolve('ok');", "'ok'");
        try expectEval(s, "_;", "'ok'");

        // Pending promise
        try expectEval(s, "await new Promise(() => {});", "Promise { <pending> }");

        // Rejected top-level await
        err_aw.clearRetainingCapacity();
        try expectEval(s, "await Promise.reject(new TypeError('nope'));", "<thrown>");
        try testing.expect(std.mem.indexOf(u8, err_aw.written(), "TypeError: nope") != null);
        try expectEval(s, "_error.message;", "'nope'");

        // Top-level for await
        try expectEval(s, "async function* gen() { yield 1; yield 2; yield 3; }", "undefined");
        try expectEval(s, "let sum = 0;", "undefined");
        try expectEval(s, "for await (const n of gen()) { sum += n; }", "undefined");
        try expectEval(s, "sum;", "6");
    }
}

test "repl: object literal heuristic and missing trailing semicolon" {
    var out_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();
    var err_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_aw.deinit();

    const s = try Session.create(testing.allocator, &out_aw.writer, &err_aw.writer, .{});
    defer s.destroy();

    try expectEval(s, "{ a: 1, b: 'hi' }", "{ a: 1, b: 'hi' }");
    try expectEval(s, "{ let x = 1; x; }", "undefined");
    try expectEval(s, "1 + 2", "3");
    try expectEval(s, "let y = 10", "undefined");
    try expectEval(s, "y * 3", "30");
}

test "repl: value inspector (all kinds, cycles, depth, getters, toStringTag, ANSI)" {
    var out_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();
    var err_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_aw.deinit();

    const s = try Session.create(testing.allocator, &out_aw.writer, &err_aw.writer, .{});
    defer s.destroy();

    try expectEval(s, "undefined", "undefined");
    try expectEval(s, "null", "null");
    try expectEval(s, "true", "true");
    try expectEval(s, "-0", "-0");
    try expectEval(s, "NaN", "NaN");
    try expectEval(s, "Infinity", "Infinity");
    try expectEval(s, "'hello\\nworld'", "'hello\\nworld'");
    try expectEval(s, "Symbol('tag')", "Symbol(tag)");
    try expectEval(s, "[1, 2, 3]", "[ 1, 2, 3 ]");
    try expectEval(s, "/abc/gi", "/abc/gi");
    try expectEval(s, "new Map([['a', 1]])", "Map(1) { 'a' => 1 }");
    try expectEval(s, "new Set([1, 2])", "Set(2) { 1, 2 }");
    try expectEval(s, "Promise.resolve(5)", "Promise { 5 }");
    try expectEval(s, "new Promise(() => {})", "Promise { <pending> }");
    try expectEval(s, "new RangeError('bad')", "RangeError: bad");
    try expectEval(s, "function foo() {} foo;", "[Function: foo]");
    try expectEval(s, "async function bar() {} bar;", "[AsyncFunction: bar]");
    try expectEval(s, "function* gen() {} gen;", "[GeneratorFunction: gen]");
    try expectEval(s, "async function* agen() {} agen;", "[AsyncGeneratorFunction: agen]");
    try expectEval(s, "gen()", "Object [Generator] {}");
    try expectEval(s, "agen()", "Object [AsyncGenerator] {}");
    try expectEval(s, "class MyClass {} MyClass;", "[class MyClass]");
    try expectEval(s, "Object.create(null)", "[Object: null prototype] {}");
    try expectEval(s, "({ [Symbol.toStringTag]: 'Custom' })", "Object [Custom] { [Symbol(Symbol.toStringTag)]: 'Custom' }");

    // Cyclic object and array
    try expectEval(s, "const cyc = {}; cyc.self = cyc; cyc;", "<ref *1> { self: [Circular *1] }");
    try expectEval(s, "const arr = []; arr.push(arr); arr;", "<ref *1> [\n  [Circular *1]\n]");

    // Depth limit (default depth 4)
    try expectEval(s, "({ a: { b: { c: { d: { e: 1 } } } } })", "{ a: { b: { c: { d: [Object] } } } }");

    // Getter safety: inspecting must NEVER invoke getter
    try expectEval(s, "let getterCalled = 0; const gObj = { get x() { getterCalled++; return 99; } }; gObj;", "{ x: [Getter] }");
    try expectEval(s, "getterCalled;", "0");

    // ANSI color on/off
    const colored = try evalInspect(s, "42", true);
    defer testing.allocator.free(colored);
    try testing.expect(std.mem.indexOf(u8, colored, "\x1b[") != null);
}

test "repl: completeness checker and read-only Tab completion" {
    // Completeness
    try testing.expect(complete.isComplete("1 + 2"));
    try testing.expect(!complete.isComplete("1 +"));
    try testing.expect(!complete.isComplete("function f() {"));
    try testing.expect(!complete.isComplete("const a = [1, 2"));
    try testing.expect(!complete.isComplete("`hello ${1 +"));
    try testing.expect(!complete.isComplete("/* unterminated"));
    try testing.expect(complete.isComplete("`hello ${1 + 2}`"));
    try testing.expect(complete.isComplete("const x = (a) => { return a; }"));

    // Tab completion & getter safety
    var out_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();
    var err_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_aw.deinit();

    const s = try Session.create(testing.allocator, &out_aw.writer, &err_aw.writer, .{});
    defer s.destroy();

    try expectEval(s, "let myVar = { alpha: 1, beta: 2, get trap() { getterHit++; return 1; } }; let getterHit = 0;", "undefined");

    var res1 = try complete.complete(testing.allocator, "myV", 3, &s.rt, s.completionLookup());
    defer res1.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), res1.matches.len);
    try testing.expectEqualStrings("myVar", res1.matches[0]);

    var res2 = try complete.complete(testing.allocator, "myVar.", 6, &s.rt, s.completionLookup());
    defer res2.deinit(testing.allocator);
    try testing.expect(res2.matches.len >= 3);

    var res3 = try complete.complete(testing.allocator, "myVar.tr", 8, &s.rt, s.completionLookup());
    defer res3.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), res3.matches.len);
    try testing.expectEqualStrings("trap", res3.matches[0]);

    var res4 = try complete.complete(testing.allocator, "myVar.trap.", 11, &s.rt, s.completionLookup());
    defer res4.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), res4.matches.len);
    // Getter must NEVER be invoked during completion
    try expectEval(s, "getterHit;", "0");

    // Dot command completion
    var res5 = try complete.complete(testing.allocator, ".he", 3, &s.rt, s.completionLookup());
    defer res5.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), res5.matches.len);
    try testing.expectEqualStrings(".help", res5.matches[0]);

    // Object. completion
    var res6 = try complete.complete(testing.allocator, "Object.ke", 9, &s.rt, s.completionLookup());
    defer res6.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), res6.matches.len);
    try testing.expectEqualStrings("keys", res6.matches[0]);

    // console and console. completion
    var res7 = try complete.complete(testing.allocator, "conso", 5, &s.rt, s.completionLookup());
    defer res7.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), res7.matches.len);
    try testing.expectEqualStrings("console", res7.matches[0]);

    var res8 = try complete.complete(testing.allocator, "console.l", 9, &s.rt, s.completionLookup());
    defer res8.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), res8.matches.len);
    try testing.expectEqualStrings("log", res8.matches[0]);

    var res9 = try complete.complete(testing.allocator, "console.", 8, &s.rt, s.completionLookup());
    defer res9.deinit(testing.allocator);
    try testing.expect(res9.matches.len >= 6);
}

test "repl: dot-commands (.ast, .bc, .gc, .mem, .clear, .load)" {
    var out_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();
    var err_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_aw.deinit();

    const s = try Session.create(testing.allocator, &out_aw.writer, &err_aw.writer, .{
        .io = std.testing.io,
    });
    defer s.destroy();

    _ = try s.runDotCommand(".ast 1 + 2");
    try testing.expect(std.mem.indexOf(u8, out_aw.written(), "(+ 1 2)") != null);

    out_aw.clearRetainingCapacity();
    _ = try s.runDotCommand(".bc 1 + 2");
    try testing.expect(std.mem.indexOf(u8, out_aw.written(), "save_repl_result") != null);

    out_aw.clearRetainingCapacity();
    _ = try s.runDotCommand(".gc");
    try testing.expect(std.mem.indexOf(u8, out_aw.written(), "GC:") != null);

    out_aw.clearRetainingCapacity();
    _ = try s.runDotCommand(".mem");
    try testing.expect(std.mem.indexOf(u8, out_aw.written(), "heap:") != null);

    try expectEval(s, "let kept = 123;", "undefined");
    _ = try s.runDotCommand(".clear");
    try expectEval(s, "kept;", "<thrown>");

    // .load from temp file
    const tmp_path = ".zig-cache/repl_load_test.js";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = tmp_path, .data = "let loadedVal = 777; loadedVal;\n" });
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, tmp_path) catch {};

    out_aw.clearRetainingCapacity();
    _ = try s.runDotCommand(".load .zig-cache/repl_load_test.js");
    try testing.expect(std.mem.indexOf(u8, out_aw.written(), "777") != null);
    try expectEval(s, "loadedVal;", "777");
}

test "repl: LineEditor synthetic byte-stream editing, UTF-8, history, Ctrl-R, Tab" {
    const SliceReader = struct {
        data: []const u8,
        pos: usize = 0,

        fn readByte(ctx: *anyopaque) anyerror!?u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (self.pos >= self.data.len) return null;
            const b = self.data[self.pos];
            self.pos += 1;
            return b;
        }

        fn interface(self: *@This()) editor.ByteReader {
            return .{ .ctx = self, .read_byte = readByte };
        }
    };

    var out_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();

    var ed = editor.LineEditor.init(testing.allocator, .{});
    defer ed.deinit();

    // 1. UTF-8 insert, Left arrow, Backspace, Ctrl-A, Ctrl-E, Ctrl-K, Ctrl-U, Ctrl-W
    // Type "hello 世界", Left 1, Backspace (deletes '世'), Ctrl-A, "1 ", Ctrl-E, "\r"
    var r1: SliceReader = .{ .data = "hello 世界\x1b[D\x7f\x01" ++ "1 \x05\r" };
    const res1 = try ed.readLineFromStream("zqjs> ", r1.interface(), &out_aw.writer);
    try testing.expectEqualStrings("1 hello 界", res1.line);

    // Ctrl-W and Ctrl-K
    var r2: SliceReader = .{ .data = "foo bar baz\x17\x01\x1b[C\x1b[C\x1b[C\x0b\r" };
    const res2 = try ed.readLineFromStream("zqjs> ", r2.interface(), &out_aw.writer);
    try testing.expectEqualStrings("foo", res2.line);

    // Ctrl-U
    var r3: SliceReader = .{ .data = "abc def\x15xyz\r" };
    const res3 = try ed.readLineFromStream("zqjs> ", r3.interface(), &out_aw.writer);
    try testing.expectEqualStrings("xyz", res3.line);

    // 2. History Up/Down and Ctrl-R reverse search
    try ed.addHistory("let alpha = 1;");
    try ed.addHistory("let beta = 2;");
    try ed.addHistory("let gamma = 3;");

    // Up twice -> "let beta = 2;", Down once -> "let gamma = 3;", Enter
    var r4: SliceReader = .{ .data = "\x1b[A\x1b[A\x1b[B\r" };
    const res4 = try ed.readLineFromStream("zqjs> ", r4.interface(), &out_aw.writer);
    try testing.expectEqualStrings("let gamma = 3;", res4.line);

    // Ctrl-R search for "alp" -> Enter
    var r5: SliceReader = .{ .data = "\x12alp\r\r" };
    const res5 = try ed.readLineFromStream("zqjs> ", r5.interface(), &out_aw.writer);
    try testing.expectEqualStrings("let alpha = 1;", res5.line);

    // 3. Tab completion in LineEditor
    const DummyComplete = struct {
        fn call(_: *anyopaque, _: []const u8, _: usize, gpa: std.mem.Allocator) std.mem.Allocator.Error!complete.CompletionResult {
            var list = try gpa.alloc([]const u8, 1);
            list[0] = try gpa.dupe(u8, "console");
            return .{ .replace_start = 0, .matches = list };
        }
    };
    var dummy: u8 = 0;
    var ed2 = editor.LineEditor.init(testing.allocator, .{
        .complete_ctx = &dummy,
        .complete_fn = DummyComplete.call,
    });
    defer ed2.deinit();

    var r6: SliceReader = .{ .data = "con\t\r" };
    const res6 = try ed2.readLineFromStream("zqjs> ", r6.interface(), &out_aw.writer);
    try testing.expectEqualStrings("console", res6.line);
}

test "repl: GC stress across 25+ chunks with closures, async generators, and objects" {
    var out_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out_aw.deinit();
    var err_aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_aw.deinit();

    const s = try Session.create(testing.allocator, &out_aw.writer, &err_aw.writer, .{});
    defer s.destroy();

    try expectEval(s, "let acc = 0;", "undefined");
    try expectEval(s, "function makeAdder(k) { return (v) => { acc += k + v; return { k, v, acc }; }; }", "undefined");
    try expectEval(s, "async function* seq(n) { for (let i = 0; i < n; i++) yield await Promise.resolve(i); }", "undefined");

    for (0..25) |i| {
        var buf: [128]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "const f_{d} = makeAdder({d}); f_{d}(1).acc;", .{ i, i, i });
        const res = try evalInspect(s, src, false);
        defer testing.allocator.free(res);
        try testing.expect(res.len > 0);
        if (i % 5 == 0) {
            const r_for = try evalInspect(s, "for await (const x of seq(3)) { acc += x; }", false);
            testing.allocator.free(r_for);
            s.rt.collect();
        }
    }
    try expectEval(s, "acc > 0;", "true");
}

test "repl: .trace on flushes buffered stderr immediately after each eval" {
    const BufferedSink = struct {
        gpa: std.mem.Allocator,
        flushed: std.ArrayList(u8) = .empty,
        buf: [1024]u8 = undefined,
        writer: std.Io.Writer = undefined,

        fn init(self: *@This(), gpa: std.mem.Allocator) void {
            self.* = .{ .gpa = gpa };
            self.writer = .{
                .vtable = &.{ .drain = drain },
                .buffer = &self.buf,
            };
        }

        fn deinit(self: *@This()) void {
            self.flushed.deinit(self.gpa);
        }

        fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @fieldParentPtr("writer", w);
            const buffered = w.buffered();
            if (buffered.len > 0) {
                self.flushed.appendSlice(self.gpa, buffered) catch return error.WriteFailed;
                w.end = 0;
            }
            for (data[0 .. data.len - 1]) |slice| {
                if (slice.len > 0) {
                    self.flushed.appendSlice(self.gpa, slice) catch return error.WriteFailed;
                }
            }
            const last = data[data.len - 1];
            if (last.len > 0) {
                for (0..splat) |_| {
                    self.flushed.appendSlice(self.gpa, last) catch return error.WriteFailed;
                }
            }
            return std.Io.Writer.countSplat(data, splat);
        }
    };

    var out_sink: BufferedSink = undefined;
    out_sink.init(testing.allocator);
    defer out_sink.deinit();

    var err_sink: BufferedSink = undefined;
    err_sink.init(testing.allocator);
    defer err_sink.deinit();

    const s = try Session.create(testing.allocator, &out_sink.writer, &err_sink.writer, .{});
    defer s.destroy();

    _ = try s.runDotCommand(".trace on");
    try testing.expect(std.mem.indexOf(u8, out_sink.flushed.items, "trace: on") != null);

    // A short expression produces well under 1024 bytes of trace output; it must
    // be flushed to stderr before eval() returns, not held until session exit.
    try expectEval(s, "1 + 2", "3");
    try testing.expect(err_sink.flushed.items.len > 0);
    try testing.expect(err_sink.flushed.items.len < err_sink.buf.len);
    try testing.expect(std.mem.indexOf(u8, err_sink.flushed.items, "add") != null);

    err_sink.flushed.clearRetainingCapacity();
    _ = try s.runDotCommand(".trace off");
    try expectEval(s, "4 + 5", "9");
    try testing.expectEqual(@as(usize, 0), err_sink.flushed.items.len);
}
