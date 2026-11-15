//! Tests of the public embedding API (M9.0). This file imports only `zqjs`, as an embedder
//! does: build.zig gives it no other module, so reaching an internal fails to build.

const std = @import("std");
const testing = std.testing;
const zqjs = @import("zqjs");

test "watchdog: this binary fails, instead of hanging, if a test gets stuck" {
    @import("watchdog.zig").start(@src().file, 20 * 60);
}

// The guard and tag checks (E1, E2) panic by design; an expected panic must run as a
// child process, so it doesn't kill this binary. The parent tests below spawn this same
// binary with `ZQJS_GUARD_CHILD` set to a scenario name; this test, second in the file
// so the child gets here fast, runs that scenario and panics, as the host bug it is.

/// The runtime a child scenario calls back into (set by the scenario, read by the writers).
var child_rt: ?*zqjs.Runtime = null;

/// A re-entrant `print` writer: its drain calls back into the runtime, from *inside* the
/// guarded region. The buffer is 1 byte, so every write drains.
fn drainIntoMemory(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    _ = w;
    _ = data;
    _ = splat;
    child_rt.?.collectGarbage(); // a call from inside the runtime's own writer (E2)
    return 0;
}

fn drainIntoDestroy(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    _ = w;
    _ = data;
    _ = splat;
    child_rt.?.destroy(); // destroying the runtime from inside its own writer (E2)
    return 0;
}

// The two-thread scenario's handoff: A signals from *inside* the guarded region (its
// writer's drain runs there) and blocks until B has observed it and attempted entry,
// so B always finds the guard held. The script's length plays no part.
var thread_a_inside = std.atomic.Value(bool).init(false);
var thread_b_go = std.atomic.Value(bool).init(false);

/// Thread A's writer: prove A is inside, then hold the region until B has come.
fn drainHoldForB(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    _ = w;
    _ = data;
    _ = splat;
    thread_a_inside.store(true, .seq_cst);
    while (!thread_b_go.load(.seq_cst)) std.Thread.yield() catch {};
    return 0;
}

fn childThreadB(p: *zqjs.Program) void {
    while (!thread_a_inside.load(.seq_cst)) std.Thread.yield() catch {};
    thread_b_go.store(true, .seq_cst);
    child_rt.?.run(p, null) catch {}; // the guard is provably held: this panics (E2)
}

test "child: run the guard scenario named by ZQJS_GUARD_CHILD (expected panic)" {
    const scenario = std.process.Environ.getPosix(std.testing.environ, "ZQJS_GUARD_CHILD") orelse return;
    if (std.mem.eql(u8, scenario, "writer-reenter") or std.mem.eql(u8, scenario, "writer-destroy")) {
        var buf: [1]u8 = undefined;
        var writer: std.Io.Writer = .{
            .buffer = &buf,
            .vtable = &.{ .drain = if (std.mem.eql(u8, scenario, "writer-reenter")) drainIntoMemory else drainIntoDestroy },
        };
        const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &writer });
        child_rt = rt;
        const p = try rt.compile("s.js", "print('hello');", null);
        rt.run(p, null) catch {};
        return; // the child must have panicked inside the writer
    }
    if (std.mem.eql(u8, scenario, "threads")) {
        var buf: [1]u8 = undefined;
        var writer: std.Io.Writer = .{ .buffer = &buf, .vtable = &.{ .drain = drainHoldForB } };
        const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &writer });
        child_rt = rt;
        const p = try rt.compile("s.js", "print('in A');", null);
        const work = struct {
            fn a(p_: *zqjs.Program) void {
                child_rt.?.run(p_, null) catch {}; // A's writer signals and holds (E2)
            }
        };
        const b = try std.Thread.spawn(.{}, childThreadB, .{p});
        const a = try std.Thread.spawn(.{}, work.a, .{p});
        a.join();
        b.join();
        return; // B must have panicked while A provably held the guard
    }
    if (std.mem.eql(u8, scenario, "program-after-destroy")) {
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        child_rt = rt;
        const p = try rt.compile("s.js", "let x = 1;", null);
        _ = try rt.start(p); // an execution keeps the program's impl alive
        p.destroy(); // the public handle dies at once (E1)
        rt.run(p, null) catch {}; // host bug: the dead handle → the tag check panics
        return;
    }
    if (std.mem.eql(u8, scenario, "handle-after-release")) {
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        const h = try rt.newNumber(7);
        h.release();
        _ = h.number(); // host bug: a dead handle → the token check panics (E1/D50)
        return;
    }
    @panic("unknown guard scenario");
}


test "the public API declares exactly the approved names (D46: a new export is a reviewed decision)" {
    const approved = [_][]const u8{
        "CompileError",
        "Diagnostic",
        "Execution",
        "Failure",
        "Handle",
        "HandleError",
        "HandleKind",
        "Limit",
        "Limits",
        "Memory",
        "Options",
        "Program",
        "RunError",
        "Runtime",
        "StartError",
        "Status",
    };
    const decls = comptime std.meta.declarations(zqjs); // the public ones only
    if (decls.len != approved.len) @compileError(std.fmt.comptimePrint("the public API now has {d} declarations, {d} approved: update `approved` only after review (D46)", .{ decls.len, approved.len }));
    var names: [decls.len][]const u8 = undefined;
    inline for (decls, 0..) |d, i| names[i] = d;
    std.mem.sort([]const u8, &names, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    try testing.expectEqual(approved.len, names.len);
    for (approved, names) |want, got| try testing.expectEqualStrings(want, got);
}

test "lifecycle: create and destroy leak nothing" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    rt.destroy();
}

test "lifecycle: Runtime.destroy with live programs and executions frees them all" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    const p1 = try rt.compile("p1.js", "let x = 1;", null);
    const p2 = try rt.compile("p2.js", "let y = 2;", null);
    _ = try rt.start(p1);
    _ = try rt.start(p2);
    rt.destroy();
}

test "lifecycle: several programs compiled but never run, then runtime destroyed" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    _ = try rt.compile("a.js", "let a = 'str1';", null);
    _ = try rt.compile("b.js", "let b = 'str2';", null);
    _ = try rt.compile("c.js", "let c = 'str3';", null);
    rt.destroy();
}

test "lifecycle: Program.destroy before runtime releases constants" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    defer rt.destroy();
    const before = rt.memory().bytes;
    const p = try rt.compile("const.js", "let s = 'some unique constant string here';", null);
    try testing.expect(rt.memory().bytes > before);
    p.destroy();
    rt.collectGarbage();
    try testing.expectEqual(before, rt.memory().bytes);
}

test "lifecycle: Program.destroy right after start keeps program alive until execution is destroyed" {
    var buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();
    const before = rt.memory().bytes;
    const p = try rt.compile("run.js", "let s = 'hello constant'; print(s);", null);
    try testing.expect(rt.memory().bytes > before);
    const ex = try rt.start(p);
    p.destroy();
    const status = try ex.@"resume"(1000, null);
    try testing.expectEqual(zqjs.Status.finished, status);
    try testing.expectEqualStrings("hello constant\n", out.buffered());
    rt.collectGarbage();
    try testing.expect(rt.memory().bytes > before);
    ex.destroy();
    rt.collectGarbage();
    try testing.expectEqual(before, rt.memory().bytes);
}

test "lifecycle: program compiled once and run 3 times gives the same output each time" {
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();
    const p = try rt.compile("p.js", "let x = 10; x += 5; print(x);", null);
    defer p.destroy();
    for (0..3) |_| {
        out = .fixed(&buf);
        try rt.run(p, null);
        try testing.expectEqualStrings("15\n", out.buffered());
    }
}

test "lifecycle: compile error leaves usable runtime with Diagnostic" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    defer rt.destroy();
    var diag: zqjs.Diagnostic = .{};
    const err = rt.compile("bad.js", "let a = ;\n", &diag);
    try testing.expectError(error.Source, err);
    try testing.expectEqual(@as(u32, 1), diag.line);
    try testing.expectEqual(@as(u32, 9), diag.column);
    try testing.expect(std.mem.startsWith(u8, diag.message(), "SyntaxError:"));

    var render_buf: [256]u8 = undefined;
    var render_w: std.Io.Writer = .fixed(&render_buf);
    try diag.render("let a = ;\n", "bad.js", &render_w);
    try testing.expect(std.mem.indexOf(u8, render_w.buffered(), "bad.js:1:9:") != null);

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const rt2 = try zqjs.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt2.destroy();
    const p = try rt2.compile("ok.js", "print('ok');", null);
    defer p.destroy();
    try rt2.run(p, null);
    try testing.expectEqualStrings("ok\n", out.buffered());
}

test "step cap holds across resumes (E4)" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_steps = 1000 } });
    defer rt.destroy();
    const p = try rt.compile("loop.js", "while (true) {}", null);
    defer p.destroy();

    const ex = try rt.start(p);
    defer ex.destroy();

    for (0..1000) |_| {
        const status = try ex.@"resume"(1, null);
        try testing.expectEqual(zqjs.Status.suspended, status);
    }

    var failure: zqjs.Failure = .{};
    const res = ex.@"resume"(1, &failure);
    try testing.expectError(error.LimitExceeded, res);
    try testing.expectEqual(zqjs.Failure.Kind.limit, failure.kind);
    try testing.expectEqual(@as(?zqjs.Limit, .steps), failure.limit);
    try testing.expectEqualStrings("LimitExceeded(steps)", failure.message());

    try testing.expectError(error.LimitExceeded, ex.@"resume"(1, null));

    const ex2 = try rt.start(p);
    defer ex2.destroy();
    try testing.expectEqual(zqjs.Status.suspended, try ex2.@"resume"(1, null));
}

test "step cap tie and resume(0) (E4)" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_steps = 10 } });
    defer rt.destroy();
    const p = try rt.compile("loop.js", "while (true) {}", null);
    defer p.destroy();

    const ex = try rt.start(p);
    defer ex.destroy();

    try testing.expectEqual(zqjs.Status.suspended, try ex.@"resume"(7, null));
    try testing.expectEqual(zqjs.Status.suspended, try ex.@"resume"(3, null));
    try testing.expectEqual(zqjs.Status.suspended, try ex.@"resume"(0, null));

    var failure: zqjs.Failure = .{};
    try testing.expectError(error.LimitExceeded, ex.@"resume"(1, &failure));
    try testing.expectEqualStrings("LimitExceeded(steps)", failure.message());
}

test "script completing exactly at max_steps finishes (E4)" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    defer rt.destroy();
    const p = try rt.compile("halt.js", "let a = 1; a = a + 1;", null);
    defer p.destroy();

    const ex = try rt.start(p);
    defer ex.destroy();
    var steps: u64 = 0;
    while (true) {
        const st = try ex.@"resume"(1, null);
        steps += 1;
        if (st == .finished) break;
    }

    const rt2 = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_steps = steps } });
    defer rt2.destroy();
    const p2 = try rt2.compile("halt.js", "let a = 1; a = a + 1;", null);
    defer p2.destroy();
    const ex2 = try rt2.start(p2);
    defer ex2.destroy();
    const st2 = try ex2.@"resume"(steps, null);
    try testing.expectEqual(zqjs.Status.finished, st2);
    try testing.expectEqual(zqjs.Status.finished, try ex2.@"resume"(0, null));
}

test "several executions: interleaved, isolated locals, shared realm (E5)" {
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    const p1 = try rt.compile("p1.js", "let x = 'A'; for (let i = 0; i < 2; i++) { print(x + i); }", null);
    defer p1.destroy();
    const p2 = try rt.compile("p2.js", "let x = 'B'; for (let i = 0; i < 2; i++) { print(x + i); }", null);
    defer p2.destroy();

    const ex1 = try rt.start(p1);
    defer ex1.destroy();
    const ex2 = try rt.start(p2);
    defer ex2.destroy();

    var st1: zqjs.Status = .suspended;
    var st2: zqjs.Status = .suspended;
    while (st1 == .suspended or st2 == .suspended) {
        if (st1 == .suspended) st1 = try ex1.@"resume"(2, null);
        rt.collectGarbage();
        if (st2 == .suspended) st2 = try ex2.@"resume"(2, null);
        rt.collectGarbage();
    }

    try testing.expectEqual(zqjs.Status.finished, st1);
    try testing.expectEqual(zqjs.Status.finished, st2);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "A0\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "A1\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "B0\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "B1\n") != null);
}

test "several executions: shared realm modification (E5)" {
    var buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    const p1 = try rt.compile("p1.js", "let p = Object.getPrototypeOf({}); p.shared_val = 99;", null);
    defer p1.destroy();
    const p2 = try rt.compile("p2.js", "let o = {}; print(o.shared_val);", null);
    defer p2.destroy();

    try rt.run(p1, null);
    try rt.run(p2, null);
    try testing.expectEqualStrings("99\n", out.buffered());
}

test "several executions: destroying one does not disturb others" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    defer rt.destroy();

    const p = try rt.compile("p.js", "let i = 0; while (i < 100) { i++; }", null);
    defer p.destroy();

    const ex1 = try rt.start(p);
    const ex2 = try rt.start(p);
    defer ex2.destroy();

    _ = try ex1.@"resume"(5, null);
    _ = try ex2.@"resume"(5, null);

    ex1.destroy();

    const st = try ex2.@"resume"(10_000, null);
    try testing.expectEqual(zqjs.Status.finished, st);
}

test "failure text rules (E10): truncation at code point boundary, valid UTF-8" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    defer rt.destroy();

    const long_key = @as([300]u8, @splat('a'));
    const src = "let key = '" ++ long_key ++ "'; null[key];";
    const p = try rt.compile("long_err.js", src, null);
    defer p.destroy();

    var failure: zqjs.Failure = .{};
    try testing.expectError(error.Thrown, rt.run(p, &failure));
    try testing.expectEqual(zqjs.Failure.Kind.thrown, failure.kind);
    try testing.expect(failure.truncated);
    try testing.expect(failure.text_len <= 256);
    try testing.expect(failure.message().len <= 256);
    try testing.expect(std.mem.endsWith(u8, failure.message(), "\u{2026}"));
    try testing.expect(std.unicode.utf8ValidateSlice(failure.message()));
}

test "failure text rules (E10): surrogate pair and lone surrogate" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    defer rt.destroy();

    const p1 = try rt.compile("lone.js", "let key = '\\uD800'; null[key];", null);
    defer p1.destroy();
    var f1: zqjs.Failure = .{};
    try testing.expectError(error.Thrown, rt.run(p1, &f1));
    try testing.expect(std.unicode.utf8ValidateSlice(f1.message()));
    try testing.expect(std.mem.indexOf(u8, f1.message(), "\u{FFFD}") != null);

    const p2 = try rt.compile("pair.js", "let key = '\\uD83D\\uDCA9'; null[key];", null);
    defer p2.destroy();
    var f2: zqjs.Failure = .{};
    try testing.expectError(error.Thrown, rt.run(p2, &f2));
    try testing.expect(std.unicode.utf8ValidateSlice(f2.message()));
    try testing.expect(std.mem.indexOf(u8, f2.message(), "💩") != null);
}

test "failure text rules (E10): fixed english text for out of memory and output" {
    const FailingWriter = struct {
        w: std.Io.Writer = .{
            .vtable = &.{ .drain = drain },
            .buffer = &.{},
        },

        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }
    };
    var fw: FailingWriter = .{};
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &fw.w });
    defer rt.destroy();
    const p = try rt.compile("out.js", "print('hello');", null);
    defer p.destroy();
    var failure: zqjs.Failure = .{};
    try testing.expectError(error.OutputFailed, rt.run(p, &failure));
    try testing.expectEqual(zqjs.Failure.Kind.output, failure.kind);
    try testing.expectEqualStrings("the output writer failed", failure.message());
}

test "slices change nothing: diff programs produce node output with slices of 1, 7, 1000 and unbounded" {
    const io = testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/diff", .{ .iterate = true });
    defer dir.close(io);

    const test_files = [_][]const u8{
        "arith.js",
        "compare.js",
        "logic.js",
        "loops.js",
        "obj_basics.js",
        "fn_recursion.js",
        "scope.js",
    };

    for (test_files) |file_name| {
        const source = try dir.readFileAlloc(io, file_name, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(source);
        const out_name = try std.fmt.allocPrint(testing.allocator, "{s}.out", .{file_name[0 .. file_name.len - 3]});
        defer testing.allocator.free(out_name);
        const expected = try dir.readFileAlloc(io, out_name, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(expected);

        for ([_]u64{ 1, 7, 1000, std.math.maxInt(u64) }) |slice_size| {
            var out_buf: std.Io.Writer.Allocating = .init(testing.allocator);
            defer out_buf.deinit();

            const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_steps = 50_000_000 }, .output = &out_buf.writer });
            defer rt.destroy();

            var diag: zqjs.Diagnostic = .{};
            const prog = try rt.compile(file_name, source, &diag);
            defer prog.destroy();

            const ex = try rt.start(prog);
            defer ex.destroy();

            var failure: zqjs.Failure = .{};
            while (true) {
                const status = try ex.@"resume"(slice_size, &failure);
                if (status == .finished) break;
                rt.collectGarbage();
            }

            const got = out_buf.written();
            try testing.expectEqualStrings(expected, got);
        }
    }
}

fn checkAllocFailOnce(allocator: std.mem.Allocator, src: []const u8) !void {
    var discard: std.Io.Writer.Discarding = .init(&.{});
    const rt = zqjs.Runtime.create(allocator, .{ .output = &discard.writer }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer rt.destroy();

    var diag: zqjs.Diagnostic = .{};
    const prog = rt.compile("t.js", src, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Source => return,
        error.Internal => return error.Internal,
    };
    defer prog.destroy();

    const ex = rt.start(prog) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LimitExceeded => return,
        error.Internal => return error.Internal,
    };
    defer ex.destroy();

    var failure: zqjs.Failure = .{};
    while (true) {
        const status = ex.@"resume"(50, &failure) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OutputFailed => return error.OutOfMemory,
            error.Thrown, error.LimitExceeded, error.Unsupported => return,
            error.Internal => return error.Internal,
        };
        if (status == .finished) break;
    }
}

test "error paths: checkAllAllocationFailures over create, compile, start, resume, destroy" {
    const sources = [_][]const u8{
        "let s = 'a'; for (let i = 0; i < 3; i++) { s += i + '!'; } print(s);",
        "let x = 1; { x; let x = 2; }",
        "",
    };
    for (sources) |src| {
        try testing.checkAllAllocationFailures(testing.allocator, checkAllocFailOnce, .{src});
    }
}

test "atomic guard: every API exit path releases guard on failure" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    defer rt.destroy();

    // 1. Compile failure (error.Source) releases guard
    var diag: zqjs.Diagnostic = .{};
    try testing.expectError(error.Source, rt.compile("bad.js", "let x = ;", &diag));
    // Guard is free: next compile succeeds
    const p1 = try rt.compile("ok1.js", "let x = 1; print(x);", null);
    defer p1.destroy();

    // 2. Start + resume with throw failure (error.Thrown) releases guard
    const p_throw = try rt.compile("throw.js", "let a = null; a();", null);
    defer p_throw.destroy();
    const ex_throw = try rt.start(p_throw);
    defer ex_throw.destroy();
    var f1: zqjs.Failure = .{};
    try testing.expectError(error.Thrown, ex_throw.@"resume"(100, &f1));
    // Guard is free: can call memory(), compile, start another execution
    _ = rt.memory();
    const ex_ok1 = try rt.start(p1);
    defer ex_ok1.destroy();

    // 3. Resume with limit failure (error.LimitExceeded) releases guard
    const rt_limited = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_steps = 10 } });
    defer rt_limited.destroy();
    const p_loop = try rt_limited.compile("loop.js", "while (true) {}", null);
    defer p_loop.destroy();
    const ex_loop = try rt_limited.start(p_loop);
    defer ex_loop.destroy();
    try testing.expectError(error.LimitExceeded, ex_loop.@"resume"(20, null));
    // Guard is free: can call rt_limited.collectGarbage(), start new execution
    rt_limited.collectGarbage();
    _ = rt_limited.memory();
    const ex_loop2 = try rt_limited.start(p_loop);
    defer ex_loop2.destroy();
    try testing.expectEqual(zqjs.Status.suspended, try ex_loop2.@"resume"(1, null));
}

// ---- Handles (M9.1, P2/D50): values crossing the boundary, GC-safe with explicit
// ownership. Every test here runs on the host thread at depth 0: the sanctioned
// re-entry (a native calling back, Q7) arrives with the entry-kind stack in P3.

test "handles: mint, read, release (D50, Q10/D54)" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    defer rt.destroy();
    var buf: [16]u16 = undefined;

    // Numbers copy out bit for bit (f64 through the boundary).
    const n = try rt.newNumber(-1.5);
    defer n.release();
    try testing.expectEqual(zqjs.HandleKind.number, n.kind());
    try testing.expectEqual(@as(?f64, -1.5), n.number());
    try testing.expectEqual(@as(?bool, null), n.boolean());
    try testing.expectEqual(@as(?usize, null), n.string(&buf));

    const b = try rt.newBoolean(true);
    defer b.release();
    try testing.expectEqual(zqjs.HandleKind.boolean, b.kind());
    try testing.expectEqual(@as(?bool, true), b.boolean());
    try testing.expectEqual(@as(?f64, null), b.number());

    // Strings are UTF-16 in and out (E10); lone surrogates are kept, not repaired.
    const units = [_]u16{ 'h', 'i', 0xD83D, 0xDE00, 0xD800 }; // "hi" + 😀 + lone surrogate
    const s = try rt.newStringUtf16(&units);
    defer s.release();
    try testing.expectEqual(zqjs.HandleKind.string, s.kind());
    try testing.expectEqual(@as(?bool, null), s.boolean());
    try testing.expectEqual(@as(?usize, units.len), s.string(&buf)); // the full length
    try testing.expectEqualSlices(u16, &units, buf[0..units.len]);

    // A too-small buffer copies min(len, buf.len) units and still reports the full
    // length, so truncation is visible (D54); copying never allocates (Q10).
    var small: [2]u16 = undefined;
    try testing.expectEqual(@as(?usize, units.len), s.string(&small));
    try testing.expectEqualSlices(u16, units[0..2], &small);

    // Wrong kind for a reader → null, separately from any length question (Q10).
    try testing.expectEqual(@as(?usize, null), n.string(&buf));
}

test "handles: dup mints an independent token (Q3/Q4)" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    defer rt.destroy();

    const n = try rt.newNumber(9);
    const n2 = try n.dup();
    n.release(); // the original token dies; the value lives through the dup
    try testing.expectEqual(@as(?f64, 9), n2.number());
    n2.release();

    // A dup of a string reads the same units through both tokens.
    const units = [_]u16{ 's', 'h', 'a', 'r', 'e', 'd' };
    const s2 = blk: {
        const s = try rt.newStringUtf16(&units);
        const dup = try s.dup();
        s.release(); // the original token dies; the value lives through the dup
        break :blk dup;
    };
    defer s2.release();
    var buf: [8]u16 = undefined;
    try testing.expectEqual(@as(?usize, 6), s2.string(&buf));
    try testing.expectEqualSlices(u16, &units, buf[0..6]);
}

test "handles: a held token roots its value; the last release makes it collectible (D50)" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    defer rt.destroy();

    // The string's only reference is the token: without the table's rooting, the
    // collection would free it.
    const want = [_]u16{ 'k', 'e', 'e', 'p', ' ', 'm', 'e' };
    const s = try rt.newStringUtf16(&want);
    _ = try rt.newNumber(0); // a second live token, so the table is non-trivially marked
    rt.collectGarbage();

    var buf: [16]u16 = undefined;
    try testing.expectEqual(@as(?usize, want.len), s.string(&buf));
    try testing.expectEqualSlices(u16, &want, buf[0..want.len]); // survived the collection

    const before_release = rt.memory().bytes;
    s.release(); // the last token: the value becomes garbage
    rt.collectGarbage();
    try testing.expect(rt.memory().bytes < before_release); // the sweep freed it
}

test "handles: a token survives collections taken by script activity (D50)" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    defer rt.destroy();

    const n = try rt.newNumber(3.25);
    const p = try rt.compile("churn.js", "for (let i = 0; i < 200; i++) { let o = { a: [i, i + 1] }; }", null);
    defer p.destroy();
    try rt.run(p, null); // allocates and drops plenty of garbage
    rt.collectGarbage();
    try testing.expectEqual(@as(?f64, 3.25), n.number()); // untouched by the churn
    n.release();
}

test "handles: the token pool is capped and accounted (D50: bounded growth)" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_handles = 8 } });
    defer rt.destroy();

    var toks: [8]*zqjs.Handle = undefined;
    for (&toks) |*slot| slot.* = try rt.newNumber(1);
    // The cap counts records, live and dead together: minting one more fails, and the
    // failure is catchable (E6).
    try testing.expectError(error.LimitExceeded, rt.newNumber(2));
    try testing.expectError(error.LimitExceeded, rt.newBoolean(true));
    for (toks) |t| t.release();
    // Released records are never reused (a stale handle must stay detectable, D50), so
    // the spent cap is not refunded: minting stays refused even with zero live tokens.
    try testing.expectError(error.LimitExceeded, rt.newNumber(2));
    // The runtime stays usable (E6): everything but minting works as before.
    rt.collectGarbage();
    _ = rt.memory();
    const p = try rt.compile("ok.js", "let x = 1; print(x);", null);
    defer p.destroy();
    try rt.run(p, null);
}

test "handles: churn within the cap recycles slots (D50)" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_handles = 64 } });
    defer rt.destroy();

    // Create/release cycles burn records but recycle slots, so the table itself does
    // not grow with the churn (the cap bounds the pool's memory).
    for (0..32) |i| {
        const h = try rt.newNumber(@floatFromInt(i));
        try testing.expectEqual(@as(?f64, @floatFromInt(i)), h.number());
        h.release();
    }
    // The runtime is still far from the cap and keeps minting.
    const h = try rt.newNumber(42);
    defer h.release();
    try testing.expectEqual(@as(?f64, 42), h.number());
}

fn checkHandleAllocFailOnce(allocator: std.mem.Allocator) !void {
    var discard: std.Io.Writer.Discarding = .init(&.{});
    const rt = zqjs.Runtime.create(allocator, .{ .output = &discard.writer }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer rt.destroy();

    const n = rt.newNumber(1) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LimitExceeded => return error.LimitExceeded, // impossible here: fresh runtime
        error.Internal => return error.Internal,
    };
    const units = [_]u16{'x'};
    const s = rt.newStringUtf16(&units) catch |e| switch (e) {
        error.OutOfMemory => {
            n.release();
            return error.OutOfMemory;
        },
        error.LimitExceeded => {
            n.release();
            return error.LimitExceeded;
        },
        error.Internal => return error.Internal,
    };
    const d = n.dup() catch |e| switch (e) {
        error.OutOfMemory => {
            s.release();
            n.release();
            return error.OutOfMemory;
        },
        error.LimitExceeded => {
            s.release();
            n.release();
            return error.LimitExceeded;
        },
        error.Internal => return error.Internal,
    };
    d.release();
    s.release();
    n.release();
}

test "handles: allocation failures leave nothing behind (E6)" {
    try testing.checkAllAllocationFailures(testing.allocator, checkHandleAllocFailOnce, .{});
}

test "handles: Runtime.destroy with live tokens frees everything (E1)" {
    // No releases before destroy: the table, the pool and the values die with the
    // runtime (the testing allocator's leak check is the assertion).
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    const n = try rt.newNumber(5);
    const n2 = try n.dup();
    const held_units = [_]u16{ 'h', 'e', 'l', 'd', ' ', 'a', 't', ' ', 'd', 'e', 's', 't', 'r', 'o', 'y' };
    const s = try rt.newStringUtf16(&held_units);
    _ = n2;
    _ = s;
    rt.destroy();
}

test "the guard and the tag checks panic, as expected, in a child process (E1, E2)" {
    if (std.process.Environ.getPosix(std.testing.environ, "ZQJS_GUARD_CHILD") != null) return; // we are the child

    const gpa = testing.allocator;
    const exe = try std.process.executablePathAlloc(std.testing.io, gpa);
    defer gpa.free(exe);

    const Scenario = struct { name: []const u8, message: []const u8 };
    const guard_message = "zqjs: Runtime entered while another call into it is running";
    // The first three panic through the guard, which is on in every build mode. The tag
    // check exists only in safe builds (E1), so in a ReleaseFast run it is skipped.
    const scenarios = [_]Scenario{
        .{ .name = "writer-reenter", .message = guard_message }, // resume, and a call from its own writer
        .{ .name = "writer-destroy", .message = guard_message }, // Runtime.destroy from the writer
        .{ .name = "threads", .message = guard_message }, // two threads hammering one runtime
        // The handle checks (D50) are not gated on runtime_safety: the token record
        // exists in every build mode, so release-then-use panics everywhere.
        .{ .name = "handle-after-release", .message = "zqjs: Handle used after release" },
        .{ .name = "program-after-destroy", .message = "zqjs: Program used after destroy" },
    };
    const count = if (std.debug.runtime_safety) scenarios.len else 4;

    var map = std.process.Environ.Map.init(gpa);
    defer map.deinit();
    for (scenarios[0..count]) |s| {
        try map.put("ZQJS_GUARD_CHILD", s.name);
        const res = try std.process.run(gpa, std.testing.io, .{ .argv = &.{exe}, .environ_map = &map });
        defer gpa.free(res.stdout);
        defer gpa.free(res.stderr);
        try testing.expect(!res.term.success()); // the panic killed the child
        try testing.expect(std.mem.indexOf(u8, res.stderr, s.message) != null);
    }
}

test "program refcount: all destruction orders with multiple executions (E1)" {
    // Case 1: Program first, then Execution (constants survive until Execution.destroy)
    {
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        defer rt.destroy();
        const base_mem = rt.memory().bytes;
        const p = try rt.compile("c1.js", "let s = 'constant 1';", null);
        try testing.expect(rt.memory().bytes > base_mem);
        const ex = try rt.start(p);
        p.destroy(); // p is destroyed by host; ex keeps it alive
        rt.collectGarbage();
        try testing.expect(rt.memory().bytes > base_mem);
        ex.destroy(); // last ref gone
        rt.collectGarbage();
        try testing.expectEqual(base_mem, rt.memory().bytes);
    }

    // Case 2: Execution first, then Program (constants survive until Program.destroy)
    {
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        defer rt.destroy();
        const base_mem = rt.memory().bytes;
        const p = try rt.compile("c2.js", "let s = 'constant 2';", null);
        const ex = try rt.start(p);
        ex.destroy(); // ex destroyed; p still has host ref
        rt.collectGarbage();
        try testing.expect(rt.memory().bytes > base_mem);
        p.destroy(); // host ref gone
        rt.collectGarbage();
        try testing.expectEqual(base_mem, rt.memory().bytes);
    }

    // Case 3: Multiple executions sharing one program (Program first, then Ex1, then Ex2)
    {
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        defer rt.destroy();
        const base_mem = rt.memory().bytes;
        const p = try rt.compile("c3.js", "let s = 'shared constant 3';", null);
        const ex1 = try rt.start(p);
        const ex2 = try rt.start(p);
        p.destroy(); // p destroyed by host, 2 executions keep it alive
        rt.collectGarbage();
        try testing.expect(rt.memory().bytes > base_mem);
        ex1.destroy(); // 1 execution remains
        rt.collectGarbage();
        try testing.expect(rt.memory().bytes > base_mem);
        ex2.destroy(); // last execution gone
        rt.collectGarbage();
        try testing.expectEqual(base_mem, rt.memory().bytes);
    }

    // Case 4: Multiple executions sharing one program (Ex1 first, then Program, then Ex2)
    {
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        defer rt.destroy();
        const base_mem = rt.memory().bytes;
        const p = try rt.compile("c4.js", "let s = 'shared constant 4';", null);
        const ex1 = try rt.start(p);
        const ex2 = try rt.start(p);
        ex1.destroy(); // Ex1 gone
        rt.collectGarbage();
        try testing.expect(rt.memory().bytes > base_mem);
        p.destroy(); // Program destroyed by host; Ex2 still holds a ref
        rt.collectGarbage();
        try testing.expect(rt.memory().bytes > base_mem);
        ex2.destroy(); // Ex2 gone
        rt.collectGarbage();
        try testing.expectEqual(base_mem, rt.memory().bytes);
    }

    // Case 5: Runtime first with live Program and multiple Executions (leaks nothing)
    {
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        const p = try rt.compile("c5.js", "let s = 'shared constant 5';", null);
        _ = try rt.start(p);
        _ = try rt.start(p);
        rt.destroy(); // frees runtime, program, both executions cleanly
    }

    // Case 6: Runtime first with Program destroyed earlier but multiple Executions still live
    {
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        const p = try rt.compile("c6.js", "let s = 'shared constant 6';", null);
        _ = try rt.start(p);
        _ = try rt.start(p);
        p.destroy();
        rt.destroy(); // frees runtime and both executions cleanly
    }
}

test "gc roots: stacks, frames, closures and cells survive collections between slices (E5)" {
    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    // Script with closures, captured variables (cells), and deep call stack
    const src1 =
        \\function makeCounter(init) {
        \\  let count = init;
        \\  return function() { count = count + 1; return count; };
        \\}
        \\let c1 = makeCounter(10);
        \\print(c1());
        \\print(c1());
    ;
    const src2 =
        \\function fact(n) {
        \\  if (n <= 1) return 1;
        \\  return n * fact(n - 1);
        \\}
        \\print(fact(4));
    ;

    const p1 = try rt.compile("p1.js", src1, null);
    defer p1.destroy();
    const p2 = try rt.compile("p2.js", src2, null);
    defer p2.destroy();

    const ex1 = try rt.start(p1);
    defer ex1.destroy();
    const ex2 = try rt.start(p2);
    defer ex2.destroy();

    // Run both in 1-step slices, with GC at every step
    var s1: zqjs.Status = .suspended;
    var s2: zqjs.Status = .suspended;
    while (s1 == .suspended or s2 == .suspended) {
        if (s1 == .suspended) {
            s1 = try ex1.@"resume"(1, null);
            rt.collectGarbage();
        }
        if (s2 == .suspended) {
            s2 = try ex2.@"resume"(1, null);
            rt.collectGarbage();
        }
    }

    try testing.expectEqual(zqjs.Status.finished, s1);
    try testing.expectEqual(zqjs.Status.finished, s2);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "11\n12\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "24\n") != null);
}

test "step accounting: 0, 1, slice equal to cap, completion at cap, unfinished at cap" {
    // 1. Budget 0 on unfinished execution: executes 0 steps, returns .suspended
    {
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        defer rt.destroy();
        const p = try rt.compile("t.js", "let x = 1; x = x + 1;", null);
        defer p.destroy();
        const ex = try rt.start(p);
        defer ex.destroy();
        try testing.expectEqual(zqjs.Status.suspended, try ex.@"resume"(0, null));
    }

    // 2. Budget 1: executes exactly 1 instruction and returns .suspended
    {
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        defer rt.destroy();
        const p = try rt.compile("t.js", "let x = 1; x = x + 1;", null);
        defer p.destroy();
        const ex = try rt.start(p);
        defer ex.destroy();
        try testing.expectEqual(zqjs.Status.suspended, try ex.@"resume"(1, null));
    }

    // 3. Slice equal to cap: tie returns .suspended; next resume fails
    {
        const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_steps = 5 } });
        defer rt.destroy();
        const p = try rt.compile("loop.js", "while (true) {}", null);
        defer p.destroy();
        const ex = try rt.start(p);
        defer ex.destroy();
        // slice of 5 equals max_steps of 5: tie -> .suspended
        try testing.expectEqual(zqjs.Status.suspended, try ex.@"resume"(5, null));
        // Next instruction past cap fails
        var failure: zqjs.Failure = .{};
        try testing.expectError(error.LimitExceeded, ex.@"resume"(1, &failure));
        try testing.expectEqualStrings("LimitExceeded(steps)", failure.message());
    }

    // 4. Completion exactly at cap: script takes K steps, max_steps = K -> .finished
    {
        // First determine step count K for this script
        const rt_measure = try zqjs.Runtime.create(testing.allocator, .{});
        defer rt_measure.destroy();
        const p_measure = try rt_measure.compile("k.js", "let a = 2 + 3;", null);
        defer p_measure.destroy();
        const ex_measure = try rt_measure.start(p_measure);
        defer ex_measure.destroy();
        var k: u64 = 0;
        while (true) {
            const st = try ex_measure.@"resume"(1, null);
            k += 1;
            if (st == .finished) break;
        }

        // Now run with max_steps = k
        const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_steps = k } });
        defer rt.destroy();
        const p = try rt.compile("k.js", "let a = 2 + 3;", null);
        defer p.destroy();
        const ex = try rt.start(p);
        defer ex.destroy();
        const status = try ex.@"resume"(k, null);
        try testing.expectEqual(zqjs.Status.finished, status);
        // Budget 0 on finished script returns .finished
        try testing.expectEqual(zqjs.Status.finished, try ex.@"resume"(0, null));
    }

    // 5. Unfinished execution at cap: script takes K steps, max_steps = K - 1
    {
        const rt_measure = try zqjs.Runtime.create(testing.allocator, .{});
        defer rt_measure.destroy();
        const p_measure = try rt_measure.compile("k.js", "let a = 2 + 3;", null);
        defer p_measure.destroy();
        const ex_measure = try rt_measure.start(p_measure);
        defer ex_measure.destroy();
        var k: u64 = 0;
        while (true) {
            const st = try ex_measure.@"resume"(1, null);
            k += 1;
            if (st == .finished) break;
        }

        const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_steps = k - 1 } });
        defer rt.destroy();
        const p = try rt.compile("k.js", "let a = 2 + 3;", null);
        defer p.destroy();
        const ex = try rt.start(p);
        defer ex.destroy();
        // At k - 1: tie ends at cap -> .suspended
        try testing.expectEqual(zqjs.Status.suspended, try ex.@"resume"(k - 1, null));
        // Attempting step k fails with LimitExceeded
        var failure: zqjs.Failure = .{};
        try testing.expectError(error.LimitExceeded, ex.@"resume"(1, &failure));
        try testing.expectEqualStrings("LimitExceeded(steps)", failure.message());
    }
}
