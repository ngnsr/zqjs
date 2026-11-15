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
    if (std.mem.eql(u8, scenario, "handle-after-slot-reuse")) {
        const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_handles = 1 } });
        const h1 = try rt.newNumber(7);
        h1.release();
        const h2 = try rt.newNumber(99); // reuses slot 0 with generation 1
        std.debug.assert(h2.number() == 99);
        _ = h1.number(); // stale handle (generation 0 != 1) → panics (D50)
        return;
    }
    if (std.mem.eql(u8, scenario, "dup-original-released-after-reuse")) {
        const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_handles = 2 } });
        const h1 = try rt.newNumber(7);
        const h2 = try h1.dup();
        h1.release();
        const h3 = try rt.newNumber(8); // reuses h1's slot while h2 stays live
        std.debug.assert(h2.number() == 7 and h3.number() == 8);
        _ = h1.number(); // stale original handle → panics (D50)
        return;
    }
    if (std.mem.eql(u8, scenario, "writer-call")) {
        var buf: [1]u8 = undefined;
        const cb = struct {
            var h: zqjs.Handle = undefined;
            fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
                _ = child_rt.?.call(h, null, &.{}, null) catch {}; // host re-entry via call (E2/D52)
                return 0;
            }
        };
        var writer: std.Io.Writer = .{ .buffer = &buf, .vtable = &.{ .drain = cb.drain } };
        const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &writer });
        child_rt = rt;
        cb.h = try rt.newNumber(1);
        const p = try rt.compile("s.js", "print('hello');", null);
        rt.run(p, null) catch {};
        return;
    }
    if (std.mem.eql(u8, scenario, "call-released-callee")) {
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        const h = try rt.newNumber(7);
        h.release();
        _ = rt.call(h, null, &.{}, null) catch {}; // dead callee handle → panics (E1/D50)
        return;
    }
    if (std.mem.eql(u8, scenario, "call-released-arg")) {
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        const f = try rt.newNumber(1);
        const arg = try rt.newNumber(2);
        arg.release();
        _ = rt.call(f, null, &.{arg}, null) catch {}; // dead argument handle → panics (E1/D50)
        return;
    }
    if (std.mem.eql(u8, scenario, "call-foreign-callee")) {
        const rt1 = try zqjs.Runtime.create(testing.allocator, .{});
        const rt2 = try zqjs.Runtime.create(testing.allocator, .{});
        const h = try rt2.newNumber(7);
        _ = rt1.call(h, null, &.{}, null) catch {}; // foreign callee handle → panics (D50)
        return;
    }
    if (std.mem.eql(u8, scenario, "call-foreign-arg")) {
        const rt1 = try zqjs.Runtime.create(testing.allocator, .{});
        const rt2 = try zqjs.Runtime.create(testing.allocator, .{});
        const f = try rt1.newNumber(1);
        const arg = try rt2.newNumber(2);
        _ = rt1.call(f, null, &.{arg}, null) catch {}; // foreign argument handle → panics (D50)
        return;
    }
    if (std.mem.eql(u8, scenario, "call-foreign-this")) {
        const rt1 = try zqjs.Runtime.create(testing.allocator, .{});
        const rt2 = try zqjs.Runtime.create(testing.allocator, .{});
        const f = try rt1.newNumber(1);
        const this_h = try rt2.newNumber(2);
        _ = rt1.call(f, this_h, &.{}, null) catch {}; // foreign `this` handle → panics (D50)
        return;
    }
    if (std.mem.eql(u8, scenario, "native-thrown-without-throwjs")) {
        const S = struct {
            fn cb(_: *zqjs.Runtime, _: ?*anyopaque, _: ?zqjs.Handle, _: []const zqjs.Handle, _: *zqjs.NativeOut) zqjs.NativeError!void {
                return error.Thrown; // without calling throwJs → panics (D53)
            }
        };
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        try rt.defineGlobalFunction("bad", S.cb, null);
        const p = try rt.compile("t.js", "bad();", null);
        _ = rt.run(p, null) catch {};
        return;
    }
    if (std.mem.eql(u8, scenario, "native-throwjs-without-thrown")) {
        const S = struct {
            fn cb(rt_in: *zqjs.Runtime, _: ?*anyopaque, _: ?zqjs.Handle, _: []const zqjs.Handle, _: *zqjs.NativeOut) zqjs.NativeError!void {
                const msg = [_]u16{ 'o', 'o', 'p', 's' };
                rt_in.throwJs(.TypeError, &msg);
                // returning Ok after throwJs → panics (D53)
            }
        };
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        try rt.defineGlobalFunction("bad", S.cb, null);
        const p = try rt.compile("t.js", "bad();", null);
        _ = rt.run(p, null) catch {};
        return;
    }
    if (std.mem.eql(u8, scenario, "native-host-error-empty-msg")) {
        const S = struct {
            fn cb(_: *zqjs.Runtime, _: ?*anyopaque, _: ?zqjs.Handle, _: []const zqjs.Handle, _: *zqjs.NativeOut) zqjs.NativeError!void {
                return error.HostError; // empty host_message → panics (D53)
            }
        };
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        try rt.defineGlobalFunction("bad", S.cb, null);
        const p = try rt.compile("t.js", "bad();", null);
        _ = rt.run(p, null) catch {};
        return;
    }
    if (std.mem.eql(u8, scenario, "native-resume-outer")) {
        const S = struct {
            fn cb(_: *zqjs.Runtime, raw: ?*anyopaque, _: ?zqjs.Handle, _: []const zqjs.Handle, _: *zqjs.NativeOut) zqjs.NativeError!void {
                const ex: *zqjs.Execution = @ptrCast(@alignCast(raw.?));
                _ = ex.@"resume"(1, null) catch {}; // host-entry inside callback → panics (D52)
            }
        };
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        const p = try rt.compile("t.js", "reenter();", null);
        const ex = try rt.start(p);
        try rt.defineGlobalFunction("reenter", S.cb, ex);
        _ = ex.@"resume"(100, null) catch {};
        return;
    }
    if (std.mem.eql(u8, scenario, "native-define-global")) {
        const S = struct {
            fn dummy(_: *zqjs.Runtime, _: ?*anyopaque, _: ?zqjs.Handle, _: []const zqjs.Handle, _: *zqjs.NativeOut) zqjs.NativeError!void {}
            fn cb(rt_in: *zqjs.Runtime, _: ?*anyopaque, _: ?zqjs.Handle, _: []const zqjs.Handle, _: *zqjs.NativeOut) zqjs.NativeError!void {
                rt_in.defineGlobalFunction("inner", dummy, null) catch {}; // host-entry inside callback → panics (D52)
            }
        };
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        try rt.defineGlobalFunction("outer", S.cb, null);
        const p = try rt.compile("t.js", "outer();", null);
        _ = rt.run(p, null) catch {};
        return;
    }
    if (std.mem.eql(u8, scenario, "native-destroy-program")) {
        const S = struct {
            fn cb(_: *zqjs.Runtime, raw: ?*anyopaque, _: ?zqjs.Handle, _: []const zqjs.Handle, _: *zqjs.NativeOut) zqjs.NativeError!void {
                const p: *zqjs.Program = @ptrCast(@alignCast(raw.?));
                p.destroy(); // host-entry inside callback → panics (D52)
            }
        };
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        const p2 = try rt.compile("p2.js", "let x = 1;", null);
        try rt.defineGlobalFunction("killProg", S.cb, p2);
        const p1 = try rt.compile("p1.js", "killProg();", null);
        _ = rt.run(p1, null) catch {};
        return;
    }
    if (std.mem.eql(u8, scenario, "native-use-temp-after-return")) {
        const Box = struct { h: zqjs.Handle = undefined };
        const S = struct {
            fn cb(_: *zqjs.Runtime, raw: ?*anyopaque, _: ?zqjs.Handle, args: []const zqjs.Handle, _: *zqjs.NativeOut) zqjs.NativeError!void {
                const slot: *Box = @ptrCast(@alignCast(raw.?));
                slot.h = args[0]; // saved without dup!
            }
        };
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        var box: Box = .{};
        try rt.defineGlobalFunction("stash", S.cb, &box);
        const p = try rt.compile("t.js", "stash(42);", null);
        try rt.run(p, null);
        _ = box.h.number(); // temporary token was released on callback teardown → panics (D50)
        return;
    }
    if (std.mem.eql(u8, scenario, "native-use-temp-after-slot-reuse")) {
        const Box = struct {
            first: zqjs.Handle = undefined,
            calls: usize = 0,
        };
        const S = struct {
            fn cb(_: *zqjs.Runtime, raw: ?*anyopaque, _: ?zqjs.Handle, args: []const zqjs.Handle, _: *zqjs.NativeOut) zqjs.NativeError!void {
                const slot: *Box = @ptrCast(@alignCast(raw.?));
                if (slot.calls == 0) slot.first = args[0]; // saved without dup!
                slot.calls += 1;
            }
        };
        const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_handles = 1 } });
        var box: Box = .{};
        try rt.defineGlobalFunction("stash", S.cb, &box);
        const p = try rt.compile("t.js", "stash(42); stash(99);", null);
        try rt.run(p, null);
        const live = try rt.newNumber(777); // slot 0 is now live with generation 2!
        std.debug.assert(live.number() == 777);
        _ = box.first.number(); // stale temporary handle from first call → panics (D50)
        return;
    }
    if (std.mem.eql(u8, scenario, "native-return-retained-without-dup")) {
        const Box = struct { h: zqjs.Handle };
        const S = struct {
            fn cb(_: *zqjs.Runtime, raw: ?*anyopaque, _: ?zqjs.Handle, _: []const zqjs.Handle, out: *zqjs.NativeOut) zqjs.NativeError!void {
                const slot: *Box = @ptrCast(@alignCast(raw.?));
                out.result = slot.h; // moves ownership of `slot.h` to the engine without `dup`!
            }
        };
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        var box: Box = .{ .h = try rt.newNumber(77) };
        try rt.defineGlobalFunction("takeRetained", S.cb, &box);
        const p = try rt.compile("t.js", "takeRetained();", null);
        try rt.run(p, null);
        _ = box.h.number(); // engine consumed and released `box.h` at teardown → panics (D50)
        return;
    }
    if (std.mem.eql(u8, scenario, "writer-reenter-inside-nested-call")) {
        const S = struct {
            rt: *zqjs.Runtime = undefined,
            w: std.Io.Writer = .{
                .vtable = &.{ .drain = drain },
                .buffer = &.{},
            },
            fn drain(w: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
                const self: *@This() = @fieldParentPtr("w", w);
                _ = self.rt.memory(); // writer re-entry during nested print inside callback → panics (D52)
                return 0;
            }
            fn cb(rt_in: *zqjs.Runtime, _: ?*anyopaque, _: ?zqjs.Handle, args: []const zqjs.Handle, _: *zqjs.NativeOut) zqjs.NativeError!void {
                const r = rt_in.call(args[0], null, &.{}, null) catch return error.Internal;
                r.release();
            }
        };
        var s: S = .{};
        s.rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &s.w });
        try s.rt.defineGlobalFunction("invoke", S.cb, null);
        const p = try s.rt.compile("t.js", "invoke(function() { print('hi'); });", null);
        _ = s.rt.run(p, null) catch {};
        return;
    }
    @panic("unknown guard scenario");
}

test "the public API declares exactly the approved names (D46: a new export is a reviewed decision)" {
    const approved = [_][]const u8{
        "CompileError",
        "Diagnostic",
        "ErrorName",
        "Execution",
        "Failure",
        "Handle",
        "HandleError",
        "HandleKind",
        "Limit",
        "Limits",
        "Memory",
        "NativeError",
        "NativeFn",
        "NativeOut",
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
        error.Source, error.Busy => return,
        error.Internal => return error.Internal,
    };
    defer prog.destroy();

    const ex = rt.start(prog) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LimitExceeded, error.Busy => return,
        error.Internal => return error.Internal,
    };
    defer ex.destroy();

    var failure: zqjs.Failure = .{};
    while (true) {
        const status = ex.@"resume"(50, &failure) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OutputFailed => return error.OutOfMemory,
            error.Thrown, error.HostError, error.LimitExceeded, error.Unsupported => return,
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

test "handles: max_handles caps concurrent slot capacity and release recycles slots (D50)" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_handles = 8 } });
    defer rt.destroy();

    var toks: [8]zqjs.Handle = undefined;
    for (&toks, 0..) |*slot, i| slot.* = try rt.newNumber(@floatFromInt(i));
    // All 8 slots are concurrently live: minting or duping a 9th fails with LimitExceeded (E6).
    try testing.expectError(error.LimitExceeded, rt.newNumber(99));
    try testing.expectError(error.LimitExceeded, rt.newBoolean(true));
    try testing.expectError(error.LimitExceeded, toks[0].dup());

    const cap_handle_bytes = rt.memory().handle_bytes;
    try testing.expect(cap_handle_bytes > 0);

    // Releasing tokens marks their slots dead, increments their generation, and pushes
    // them onto the free list so concurrent capacity is available again without growing
    // the handle table (D50).
    for (toks) |t| t.release();
    for (&toks, 0..) |*slot, i| slot.* = try rt.newNumber(@floatFromInt(i + 100));
    try testing.expectEqual(cap_handle_bytes, rt.memory().handle_bytes);
    for (toks, 0..) |t, i| {
        try testing.expectEqual(@as(?f64, @floatFromInt(i + 100)), t.number());
        t.release();
    }

    // The runtime stays usable (E6).
    rt.collectGarbage();
    const p = try rt.compile("ok.js", "let x = 1; print(x);", null);
    defer p.destroy();
    try rt.run(p, null);
}

test "handles: churn within max_handles recycles slots indefinitely with flat handle_bytes (D50)" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_handles = 4 } });
    defer rt.destroy();

    try testing.expectEqual(@as(usize, 0), rt.memory().handle_bytes);

    // Warm 2 slots via mint + dup, then release both.
    {
        const h1 = try rt.newNumber(1);
        const h2 = try h1.dup();
        h1.release();
        h2.release();
    }
    const warm_handle_bytes = rt.memory().handle_bytes;
    try testing.expect(warm_handle_bytes > 0);

    // Create/release 1,000 times under `max_handles = 4`: slots recycle via the free list
    // and `handle_bytes` never grows beyond the initial allocation.
    for (0..1000) |i| {
        const h = try rt.newNumber(@floatFromInt(i));
        const d = try h.dup();
        h.release(); // releasing original leaves dup valid in its own slot
        try testing.expectEqual(@as(?f64, @floatFromInt(i)), d.number());
        d.release();
    }
    try testing.expectEqual(warm_handle_bytes, rt.memory().handle_bytes);
}

test "memory: separates heap_bytes, handle_bytes, and total bytes (D50)" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    defer rt.destroy();

    const m0 = rt.memory();
    try testing.expectEqual(@as(usize, 0), m0.handle_bytes);
    try testing.expectEqual(m0.heap_bytes, m0.bytes);

    // Minting a string allocates both on the JS heap (`heap_bytes`) and in the handle
    // slot table (`handle_bytes`), and `bytes == heap_bytes + handle_bytes`.
    const units = [_]u16{ 'h', 'e', 'a', 'p', '-', 's', 't', 'r', 'i', 'n', 'g' };
    const s = try rt.newStringUtf16(&units);
    const m1 = rt.memory();
    try testing.expect(m1.heap_bytes > m0.heap_bytes);
    try testing.expect(m1.handle_bytes > 0);
    try testing.expectEqual(m1.heap_bytes + m1.handle_bytes, m1.bytes);
    try testing.expect(m1.peak >= m1.bytes);

    // Releasing the handle and collecting garbage reclaims the JS string from `heap_bytes`
    // while the handle table retains its slot capacity in `handle_bytes`.
    s.release();
    rt.collectGarbage();
    const m2 = rt.memory();
    try testing.expectEqual(m0.heap_bytes, m2.heap_bytes);
    try testing.expectEqual(m1.handle_bytes, m2.handle_bytes);
    try testing.expectEqual(m2.heap_bytes + m2.handle_bytes, m2.bytes);
    try testing.expect(m2.collections > m1.collections);
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
        .{ .name = "writer-call", .message = guard_message }, // Runtime.call from the writer
        .{ .name = "threads", .message = guard_message }, // two threads hammering one runtime
        // The handle checks (D50) are not gated on runtime_safety: the slot generation
        // exists in every build mode, so release-then-use and cross-runtime panic everywhere.
        .{ .name = "handle-after-release", .message = "zqjs: Handle used after release" },
        .{ .name = "handle-after-slot-reuse", .message = "zqjs: Handle used after release" },
        .{ .name = "dup-original-released-after-reuse", .message = "zqjs: Handle used after release" },
        .{ .name = "call-released-callee", .message = "zqjs: Handle used after release" },
        .{ .name = "call-released-arg", .message = "zqjs: Handle used after release" },
        .{ .name = "call-foreign-callee", .message = "zqjs: Handle from another Runtime" },
        .{ .name = "call-foreign-arg", .message = "zqjs: Handle from another Runtime" },
        .{ .name = "call-foreign-this", .message = "zqjs: Handle from another Runtime" },
        .{ .name = "native-thrown-without-throwjs", .message = "zqjs: NativeFn returned error.Thrown without calling throwJs" },
        .{ .name = "native-throwjs-without-thrown", .message = "zqjs: throwJs called without returning error.Thrown" },
        .{ .name = "native-host-error-empty-msg", .message = "zqjs: NativeFn returned error.HostError with an empty host_message" },
        .{ .name = "native-resume-outer", .message = guard_message },
        .{ .name = "native-define-global", .message = guard_message },
        .{ .name = "native-destroy-program", .message = guard_message },
        .{ .name = "native-use-temp-after-return", .message = "zqjs: Handle used after release" },
        .{ .name = "native-use-temp-after-slot-reuse", .message = "zqjs: Handle used after release" },
        .{ .name = "native-return-retained-without-dup", .message = "zqjs: Handle used after release" },
        .{ .name = "writer-reenter-inside-nested-call", .message = guard_message },
        .{ .name = "program-after-destroy", .message = "zqjs: Program used after destroy" },
    };
    const count = if (std.debug.runtime_safety) scenarios.len else scenarios.len - 1;

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

test "Runtime.call: non-function callee throws TypeError (E5/D51)" {
    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    defer rt.destroy();

    const n = try rt.newNumber(42);
    defer n.release();
    const b = try rt.newBoolean(false);
    defer b.release();
    const units = [_]u16{ 'n', 'o', 't', '_', 'f', 'n' };
    const s = try rt.newStringUtf16(&units);
    defer s.release();

    for ([_]zqjs.Handle{ n, b, s }) |callee| {
        var failure: zqjs.Failure = .{};
        try testing.expectError(error.Thrown, rt.call(callee, n, &.{ b, s }, &failure));
        try testing.expectEqual(zqjs.Failure.Kind.thrown, failure.kind);
        try testing.expectEqualStrings("TypeError: value is not a function", failure.message());
    }

    // The runtime remains clean and usable after thrown call failures (E6).
    const p = try rt.compile("ok.js", "let x = 2 + 2;", null);
    defer p.destroy();
    try rt.run(p, null);
}

test "Runtime.call: works while another execution is suspended, leaving it intact (D51)" {
    var buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    const src =
        \\function add(a, b) { return a + b; }
        \\let s = 'keep-' + add(20, 22);
        \\print(s);
    ;
    const p = try rt.compile("susp.js", src, null);
    defer p.destroy();
    const ex = try rt.start(p);
    defer ex.destroy();

    // Suspend mid-execution.
    try testing.expectEqual(zqjs.Status.suspended, try ex.@"resume"(3, null));

    // Host invokes Runtime.call while `ex` is suspended: runs on a fresh chain and
    // leaves `ex`'s suspended state and step budget untouched.
    const n = try rt.newNumber(7);
    defer n.release();
    var failure: zqjs.Failure = .{};
    try testing.expectError(error.Thrown, rt.call(n, null, &.{n}, &failure));
    try testing.expectEqualStrings("TypeError: value is not a function", failure.message());

    rt.collectGarbage();

    // Resume the suspended execution to completion.
    try testing.expectEqual(zqjs.Status.finished, try ex.@"resume"(1000, null));
    try testing.expectEqualStrings("keep-42\n", out.buffered());
}

fn checkCallAllocFailOnce(allocator: std.mem.Allocator) !void {
    var discard: std.Io.Writer.Discarding = .init(&.{});
    const rt = zqjs.Runtime.create(allocator, .{ .output = &discard.writer }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer rt.destroy();

    const callee = rt.newNumber(1) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TestUnexpectedResult,
    };
    defer callee.release();

    const arg = rt.newNumber(2) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TestUnexpectedResult,
    };
    defer arg.release();

    var failure: zqjs.Failure = .{};
    const res = rt.call(callee, arg, &.{arg}, &failure) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Thrown => {
            try testing.expectEqual(zqjs.Failure.Kind.thrown, failure.kind);
            try testing.expectEqualStrings("TypeError: value is not a function", failure.message());
            return;
        },
        else => return error.TestUnexpectedResult,
    };
    res.release();
    return error.TestUnexpectedResult;
}

test "Runtime.call: allocation failures leave nothing behind (E6)" {
    try testing.checkAllAllocationFailures(testing.allocator, checkCallAllocFailOnce, .{});
}

// ---- Host natives and bidirectional callbacks (M9.1, P4/D50–D54):
// `defineGlobalFunction`, `NativeFn`, temporary argument/`this` handles, `dup`/`release`
// ownership, `throwJs`, `HostError`, sanctioned re-entry vs. `error.Busy`, and full
// JS → native → JS → native → JS round trips under GC and stack stress.

test "defineGlobalFunction: registration, ctx passing, this binding (D41), and duplicate rejection (D53)" {
    const State = struct {
        bias: f64 = 100,
        last_this_kind: ?zqjs.HandleKind = null,
        calls: usize = 0,
    };
    const S = struct {
        fn addWithBias(rt: *zqjs.Runtime, raw: ?*anyopaque, this: ?zqjs.Handle, args: []const zqjs.Handle, out: *zqjs.NativeOut) zqjs.NativeError!void {
            const st: *State = @ptrCast(@alignCast(raw.?));
            st.calls += 1;
            st.last_this_kind = if (this) |t| t.kind() else null;
            var sum: f64 = st.bias;
            for (args) |a| {
                sum += a.number() orelse 0;
            }
            out.result = try rt.newNumber(sum);
        }
    };

    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    var state: State = .{};
    try rt.defineGlobalFunction("addWithBias", S.addWithBias, &state);

    // Duplicate registration is rejected with `error.NameTaken`, including implemented
    // built-ins, node-known built-ins, and already-registered host globals (D53).
    for ([_][]const u8{
        "addWithBias",
        "print",
        "Object",
        "Array",
        "undefined",
        "NaN",
        "Infinity",
        "Math",
        "JSON",
        "Date",
        "parseInt",
        "eval",
    }) |dup_name| {
        try testing.expectError(error.NameTaken, rt.defineGlobalFunction(dup_name, S.addWithBias, null));
    }

    // 1. Plain call: `this` is null (D41), 0 and multiple arguments work.
    const p1 = try rt.compile("p1.js", "print(addWithBias()); print(addWithBias(1, 2, 3));", null);
    defer p1.destroy();
    try rt.run(p1, null);
    try testing.expectEqual(@as(?zqjs.HandleKind, null), state.last_this_kind);
    try testing.expectEqual(@as(usize, 2), state.calls);

    // 2. Method call on an object: `this` is an `.object` handle (D41).
    const p2 = try rt.compile("p2.js", "let o = { m: addWithBias }; print(o.m(5));", null);
    defer p2.destroy();
    try rt.run(p2, null);
    try testing.expectEqual(@as(?zqjs.HandleKind, .object), state.last_this_kind);

    // 3. Method call on a primitive: sloppy JS does not box in ZQJS, so `this` is null (D41).
    const p3 = try rt.compile("p3.js", "let p = Object.getPrototypeOf(''); p.m = addWithBias; print('hi'.m(7));", null);
    defer p3.destroy();
    try rt.run(p3, null);
    try testing.expectEqual(@as(?zqjs.HandleKind, null), state.last_this_kind);

    // 4. Realm persistence (E3): a second program sees the same registered global and updated ctx.
    state.bias = 200;
    const p4 = try rt.compile("p4.js", "print(addWithBias(10));", null);
    defer p4.destroy();
    try rt.run(p4, null);
    try testing.expectEqualStrings("100\n106\n105\n107\n210\n", out.buffered());
}

test "native callbacks: temporary handle ownership, dup/release, and returning args directly (D50)" {
    const Holder = struct {
        saved_fn: ?zqjs.Handle = null,
        saved_obj: ?zqjs.Handle = null,
    };
    const S = struct {
        // Returns `args[0]` directly as `out.result` (aliasing a temporary token) without
        // double-releasing it on teardown (D50).
        fn identity(_: *zqjs.Runtime, _: ?*anyopaque, _: ?zqjs.Handle, args: []const zqjs.Handle, out: *zqjs.NativeOut) zqjs.NativeError!void {
            if (args.len > 0) out.result = args[0];
        }

        // `dup`s both a closure and an object handle so they survive callback teardown,
        // and leaves `out.result = null` (which becomes JS `undefined`).
        fn keep(_: *zqjs.Runtime, raw: ?*anyopaque, _: ?zqjs.Handle, args: []const zqjs.Handle, _: *zqjs.NativeOut) zqjs.NativeError!void {
            const h: *Holder = @ptrCast(@alignCast(raw.?));
            h.saved_fn = try args[0].dup();
            h.saved_obj = try args[1].dup();
        }
    };

    var buf: [128]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    var holder: Holder = .{};
    defer {
        if (holder.saved_fn) |f| f.release();
        if (holder.saved_obj) |o| o.release();
    }

    try rt.defineGlobalFunction("identity", S.identity, null);
    try rt.defineGlobalFunction("keep", S.keep, &holder);

    const src =
        \\print(identity(42));
        \\print(identity('echo'));
        \\print(identity());
        \\let box = { v: 19 };
        \\let r = keep(function(b, delta) { return b.v + delta; }, box);
        \\print(r);
    ;
    const p = try rt.compile("own.js", src, null);
    defer p.destroy();
    try rt.run(p, null);
    try testing.expectEqualStrings("42\necho\nundefined\nundefined\n", out.buffered());

    // The temporary tokens from `keep` were released on teardown, but the `dup`ed tokens
    // remain live and root both the closure and `box` across a full GC!
    rt.collectGarbage();
    try testing.expectEqual(zqjs.HandleKind.function, holder.saved_fn.?.kind());
    try testing.expectEqual(zqjs.HandleKind.object, holder.saved_obj.?.kind());

    const delta = try rt.newNumber(23);
    defer delta.release();
    const res = try rt.call(holder.saved_fn.?, null, &.{ holder.saved_obj.?, delta }, null);
    defer res.release();
    try testing.expectEqual(@as(?f64, 42), res.number());

    // Returning a host-owned retained handle across multiple calls requires `dup` because
    // `out.result` transfers token ownership to the engine (D50). With `try h.dup()`, the
    // host's retained handle stays live across repeated calls and GC.
    const Retained = struct {
        fn getSavedObj(_: *zqjs.Runtime, raw: ?*anyopaque, _: ?zqjs.Handle, _: []const zqjs.Handle, out_r: *zqjs.NativeOut) zqjs.NativeError!void {
            const h: *Holder = @ptrCast(@alignCast(raw.?));
            out_r.result = try h.saved_obj.?.dup();
        }
    };
    try rt.defineGlobalFunction("getSavedObj", Retained.getSavedObj, &holder);
    out = .fixed(&buf);
    const p2 = try rt.compile("retained.js", "print(getSavedObj().v); print(getSavedObj().v + 1);", null);
    defer p2.destroy();
    try rt.run(p2, null);
    rt.collectGarbage();
    try testing.expectEqualStrings("19\n20\n", out.buffered());
    try testing.expectEqual(zqjs.HandleKind.object, holder.saved_obj.?.kind());
}

test "native callbacks: throwJs, HostError, LimitExceeded, Unsupported, OutOfMemory, and Internal (D53, E5–E7, E10)" {
    const Mode = enum {
        throw_type,
        throw_range,
        throw_ref,
        host_short,
        host_long_utf8,
        limit,
        unsupported,
        oom,
        internal,
    };
    const S = struct {
        fn failWith(rt: *zqjs.Runtime, raw: ?*anyopaque, _: ?zqjs.Handle, _: []const zqjs.Handle, out: *zqjs.NativeOut) zqjs.NativeError!void {
            const mode: *const Mode = @ptrCast(@alignCast(raw.?));
            // Also populate `out.result` before returning an error: teardown must still
            // release the transferred result token on every error outcome (D50, D53).
            const tmp = [_]u16{ 'd', 'r', 'o', 'p', 'p', 'e', 'd' };
            out.result = try rt.newStringUtf16(&tmp);
            switch (mode.*) {
                .throw_type => {
                    const msg = [_]u16{ 'b', 'a', 'd', ' ', 'a', 'r', 'g' };
                    rt.throwJs(.TypeError, &msg);
                    return error.Thrown;
                },
                .throw_range => {
                    const msg = [_]u16{ 'o', 'u', 't', ' ', 'o', 'f', ' ', 'b', 'o', 'u', 'n', 'd', 's' };
                    rt.throwJs(.RangeError, &msg);
                    return error.Thrown;
                },
                .throw_ref => {
                    const msg = [_]u16{ 'm', 'i', 's', 's', 'i', 'n', 'g' };
                    rt.throwJs(.ReferenceError, &msg);
                    return error.Thrown;
                },
                .host_short => {
                    out.host_message = "database connection refused";
                    return error.HostError;
                },
                .host_long_utf8 => {
                    // > 256 bytes with an invalid UTF-8 byte (0xFF) at the start: must be
                    // sanitized and truncated via E10 TextWriter rules.
                    const long_msg = "\xff" ++ (@as([300]u8, @splat('z')));
                    out.host_message = long_msg;
                    return error.HostError;
                },
                .limit => return error.LimitExceeded,
                .unsupported => return error.Unsupported,
                .oom => return error.OutOfMemory,
                .internal => return error.Internal,
            }
        }
    };

    const rt = try zqjs.Runtime.create(testing.allocator, .{});
    defer rt.destroy();

    var mode: Mode = .throw_type;
    try rt.defineGlobalFunction("trigger", S.failWith, &mode);
    const p = try rt.compile("err.js", "trigger();", null);
    defer p.destroy();
    const p_ok = try rt.compile("ok.js", "let x = 1 + 1;", null);
    defer p_ok.destroy();

    // 1. throwJs (TypeError, RangeError, ReferenceError) → error.Thrown, runtime stays usable.
    {
        mode = .throw_type;
        var f: zqjs.Failure = .{};
        try testing.expectError(error.Thrown, rt.run(p, &f));
        try testing.expectEqual(zqjs.Failure.Kind.thrown, f.kind);
        try testing.expectEqualStrings("TypeError: bad arg", f.message());

        mode = .throw_range;
        try testing.expectError(error.Thrown, rt.run(p, &f));
        try testing.expectEqualStrings("RangeError: out of bounds", f.message());

        mode = .throw_ref;
        try testing.expectError(error.Thrown, rt.run(p, &f));
        try testing.expectEqualStrings("ReferenceError: missing", f.message());
    }

    // 2. HostError → error.HostError, Failure.Kind.host, does NOT poison runtime (D53).
    {
        mode = .host_short;
        var f: zqjs.Failure = .{};
        try testing.expectError(error.HostError, rt.run(p, &f));
        try testing.expectEqual(zqjs.Failure.Kind.host, f.kind);
        try testing.expect(!f.truncated);
        try testing.expectEqualStrings("database connection refused", f.message());

        mode = .host_long_utf8;
        var f2: zqjs.Failure = .{};
        try testing.expectError(error.HostError, rt.run(p, &f2));
        try testing.expectEqual(zqjs.Failure.Kind.host, f2.kind);
        try testing.expect(f2.truncated);
        try testing.expect(std.unicode.utf8ValidateSlice(f2.message()));
        try testing.expect(std.mem.startsWith(u8, f2.message(), "\u{FFFD}z"));
        try testing.expect(std.mem.endsWith(u8, f2.message(), "\u{2026}"));

        // Runtime is NOT poisoned: running a healthy program succeeds.
        try rt.run(p_ok, null);
    }

    // 3. LimitExceeded, Unsupported, OutOfMemory from a native fault the run, leave runtime usable.
    {
        var f: zqjs.Failure = .{};
        mode = .limit;
        try testing.expectError(error.LimitExceeded, rt.run(p, &f));
        try testing.expectEqual(zqjs.Failure.Kind.limit, f.kind);

        mode = .unsupported;
        try testing.expectError(error.Unsupported, rt.run(p, &f));
        try testing.expectEqual(zqjs.Failure.Kind.unsupported, f.kind);

        mode = .oom;
        try testing.expectError(error.OutOfMemory, rt.run(p, &f));
        try testing.expectEqual(zqjs.Failure.Kind.out_of_memory, f.kind);

        // Every `out.result` string minted before failing was released at teardown, so
        // collecting garbage reclaims them all.
        const before_gc = rt.memory().bytes;
        rt.collectGarbage();
        try testing.expect(rt.memory().bytes < before_gc);

        try rt.run(p_ok, null);
    }

    // 4. Internal from a native poisons the runtime (E7/D49).
    {
        mode = .internal;
        var f: zqjs.Failure = .{};
        try testing.expectError(error.Internal, rt.run(p, &f));
        try testing.expectEqual(zqjs.Failure.Kind.internal, f.kind);
        try testing.expectEqualStrings("internal error", f.message());

        try testing.expectError(error.Internal, rt.run(p_ok, null));
        try testing.expectError(error.Internal, rt.compile("x.js", "1;", null));
        try testing.expectError(error.Internal, rt.start(p_ok));
        try testing.expectError(error.Internal, rt.newNumber(1));
        rt.collectGarbage();
        _ = rt.memory();
    }
}

fn callInNative(rt: *zqjs.Runtime, f: zqjs.Handle, this: ?zqjs.Handle, args: []const zqjs.Handle) zqjs.NativeError!zqjs.Handle {
    return rt.call(f, this, args, null) catch |e| switch (e) {
        error.OutputFailed => error.Internal,
        else => |ne| ne,
    };
}

test "sanctioned re-entry vs error.Busy inside a native callback (D52)" {
    const Ctx = struct {
        prog: *zqjs.Program,
        checked: bool = false,
    };
    const S = struct {
        fn checkApi(rt: *zqjs.Runtime, raw: ?*anyopaque, _: ?zqjs.Handle, args: []const zqjs.Handle, out: *zqjs.NativeOut) zqjs.NativeError!void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw.?));

            // 1. `compile`, `start`, and `run` return `error.Busy` without affecting the active execution.
            if (rt.compile("inner.js", "1 + 1;", null)) |_| return error.Internal else |e| {
                if (e != error.Busy) return error.Internal;
            }
            if (rt.start(ctx.prog)) |_| return error.Internal else |e| {
                if (e != error.Busy) return error.Internal;
            }
            if (rt.run(ctx.prog, null)) |_| return error.Internal else |e| {
                if (e != error.Busy) return error.Internal;
            }

            // 2. Sanctioned re-entrant operations all work: handle creation, dup/release,
            //    readers, `collectGarbage`, `memory`, and `rt.call`.
            const n = try rt.newNumber(10);
            defer n.release();
            const n_dup = try n.dup();
            defer n_dup.release();
            const b = try rt.newBoolean(true);
            defer b.release();
            const units = [_]u16{ 'o', 'k' };
            const s = try rt.newStringUtf16(&units);
            defer s.release();
            var sbuf: [4]u16 = undefined;
            if (n_dup.number() != 10 or b.boolean() != true or s.string(&sbuf) != 2) return error.Internal;

            rt.collectGarbage();
            _ = rt.memory();

            const call_res = try callInNative(rt, args[0], null, &.{n_dup});
            ctx.checked = true;
            out.result = call_res;
        }
    };

    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    const p_other = try rt.compile("other.js", "let z = 0;", null);
    defer p_other.destroy();
    var ctx: Ctx = .{ .prog = p_other };

    try rt.defineGlobalFunction("checkApi", S.checkApi, &ctx);
    const p = try rt.compile("main.js", "print(checkApi(function(x) { return x * 3; }));", null);
    defer p.destroy();
    try rt.run(p, null);

    try testing.expect(ctx.checked);
    try testing.expectEqualStrings("30\n", out.buffered());
}

test "R1: native callback invokes nested JS that grows stacks and creates closures; outer VM and args stay intact" {
    const S = struct {
        fn bridge(rt: *zqjs.Runtime, _: ?*anyopaque, _: ?zqjs.Handle, args: []const zqjs.Handle, out: *zqjs.NativeOut) zqjs.NativeError!void {
            // args[0] = callback closure, args[1] = number 10, args[2] = string " suffix"
            const n_before = args[1].number() orelse return error.Internal;
            const factor = try rt.newNumber(4);
            defer factor.release();

            // Call back into JS: the nested JS recurses deeply and creates closures before
            // and after stack growth (`-Dstack-stress` moves stacks on every call).
            const nested = try callInNative(rt, args[0], null, &.{ args[1], factor, args[2] });
            defer nested.release();

            // After the nested VM returns, our temporary `args` handles are still valid
            // and untouched.
            const n_after = args[1].number() orelse return error.Internal;
            if (n_before != n_after) return error.Internal;

            out.result = try nested.dup();
        }
    };

    var buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    try rt.defineGlobalFunction("bridge", S.bridge, null);

    const src =
        \\function outerWork(x) {
        \\  let beforeClosure = function(v) { return v + x; };
        \\  function deep(n, acc) {
        \\    if (n <= 0) return acc;
        \\    let midClosure = function(d) { return acc + d; };
        \\    return deep(n - 1, midClosure(1));
        \\  }
        \\  let res = bridge(function(base, mult, tag) {
        \\    let pre = function() { return base * mult; };
        \\    let climbed = deep(12, pre());
        \\    let post = function(s) { return climbed + s; };
        \\    return post(tag);
        \\  }, 10, '-done');
        \\  return beforeClosure(2) + ':' + res;
        \\}
        \\print(outerWork(5));
    ;
    const p = try rt.compile("r1.js", src, null);
    defer p.destroy();
    try rt.run(p, null);
    try testing.expectEqualStrings("7:52-done\n", out.buffered());
}

test "R2: JS passes an object to a native; native retains handle, calls back into JS that triggers GC, then reads original object" {
    const Mode = enum { ok, js_throw, js_limit, host_err };
    const Ctx = struct {
        mode: Mode = .ok,
        dup_survived: bool = false,
    };
    const S = struct {
        // args[0] = obj (`{ x: 42, label: 'kept' }`)
        // args[1] = churnFn (allocates heavy garbage in nested JS and mutates `obj.y = 8`)
        // args[2] = readFn (`function(o) { return o.x + o.y + ':' + o.label; }`)
        fn inspectAfterGc(rt: *zqjs.Runtime, raw: ?*anyopaque, _: ?zqjs.Handle, args: []const zqjs.Handle, out: *zqjs.NativeOut) zqjs.NativeError!void {
            const ctx: *Ctx = @ptrCast(@alignCast(raw.?));
            if (args[0].kind() != .object) return error.Internal;

            // Retain a dup of the object handle across nested JS execution + explicit GC,
            // and release it before returning to verify cleanup on every path.
            const kept_obj = try args[0].dup();
            defer kept_obj.release();

            // 1. Call back into JS: nested JS allocates garbage objects/strings/arrays to
            //    trigger GC while the outer VM is suspended and `kept_obj` is held by the native.
            const churn_res = try callInNative(rt, args[1], kept_obj, &.{kept_obj});
            churn_res.release();

            // 2. Also trigger an explicit full collection inside the callback.
            rt.collectGarbage();

            if (ctx.mode == .host_err) {
                out.host_message = "simulated failure after GC";
                return error.HostError;
            }

            // 3. Verify `kept_obj` and `args[0]` both survived collection intact, then pass
            //    `kept_obj` into `readFn` to read its properties (`x`, `y`, `label`).
            if (kept_obj.kind() != .object or args[0].kind() != .object) return error.Internal;
            ctx.dup_survived = true;
            out.result = try callInNative(rt, args[2], null, &.{kept_obj});
        }
    };

    // 1. Success path: object survives nested JS allocation churn + explicit GC, properties read cleanly.
    {
        var buf: [256]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &out });
        defer rt.destroy();

        var ctx: Ctx = .{ .mode = .ok };
        try rt.defineGlobalFunction("inspectAfterGc", S.inspectAfterGc, &ctx);

        const src =
            \\function run() {
            \\  let outerSurvivor = { tag: 'outer' };
            \\  let target = { x: 42, label: 'kept' };
            \\  let churn = function(o) {
            \\    for (let i = 0; i < 150; i++) {
            \\      let g = { a: [i, i + 1, 'garbage-' + i], b: { c: i } };
            \\    }
            \\    o.y = 8;
            \\    return o.x;
            \\  };
            \\  let reader = function(o) {
            \\    return (o.x + o.y) + ':' + o.label;
            \\  };
            \\  let r = inspectAfterGc(target, churn, reader);
            \\  print(outerSurvivor.tag + ':' + r + ':' + target.y);
            \\}
            \\run();
        ;
        const p = try rt.compile("r2_ok.js", src, null);
        defer p.destroy();
        try rt.run(p, null);
        try testing.expect(ctx.dup_survived);
        try testing.expectEqualStrings("outer:50:kept:8\n", out.buffered());
    }

    // 2. Failure path A: nested JS throws after allocating garbage → unwinds cleanly, no leaks.
    {
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        defer rt.destroy();
        var ctx: Ctx = .{ .mode = .js_throw };
        try rt.defineGlobalFunction("inspectAfterGc", S.inspectAfterGc, &ctx);

        const src =
            \\let target = { x: 42, label: 'kept' };
            \\inspectAfterGc(target, function(o) {
            \\  for (let i = 0; i < 50; i++) { let g = [i, 'trash-' + i]; }
            \\  null.boom;
            \\}, function(o) { return o.x; });
        ;
        const p = try rt.compile("r2_throw.js", src, null);
        defer p.destroy();
        var failure: zqjs.Failure = .{};
        try testing.expectError(error.Thrown, rt.run(p, &failure));
        try testing.expectEqual(zqjs.Failure.Kind.thrown, failure.kind);
        rt.collectGarbage();
    }

    // 3. Failure path B: nested JS hits step limit during allocation churn → unwinds cleanly, no leaks.
    {
        const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_steps = 200 } });
        defer rt.destroy();
        var ctx: Ctx = .{ .mode = .js_limit };
        try rt.defineGlobalFunction("inspectAfterGc", S.inspectAfterGc, &ctx);

        const src =
            \\let target = { x: 42, label: 'kept' };
            \\inspectAfterGc(target, function(o) {
            \\  while (true) { let g = { a: 1 }; }
            \\}, function(o) { return o.x; });
        ;
        const p = try rt.compile("r2_limit.js", src, null);
        defer p.destroy();
        var failure: zqjs.Failure = .{};
        try testing.expectError(error.LimitExceeded, rt.run(p, &failure));
        try testing.expectEqual(@as(?zqjs.Limit, .steps), failure.limit);
        rt.collectGarbage();
    }

    // 4. Failure path C: native returns `error.HostError` after nested GC → unwinds cleanly, no leaks.
    {
        const rt = try zqjs.Runtime.create(testing.allocator, .{});
        defer rt.destroy();
        var ctx: Ctx = .{ .mode = .host_err };
        try rt.defineGlobalFunction("inspectAfterGc", S.inspectAfterGc, &ctx);

        const src =
            \\let target = { x: 42, label: 'kept' };
            \\inspectAfterGc(target, function(o) {
            \\  for (let i = 0; i < 50; i++) { let g = { a: i }; }
            \\}, function(o) { return o.x; });
        ;
        const p = try rt.compile("r2_host.js", src, null);
        defer p.destroy();
        var failure: zqjs.Failure = .{};
        try testing.expectError(error.HostError, rt.run(p, &failure));
        try testing.expectEqualStrings("simulated failure after GC", failure.message());
        rt.collectGarbage();
    }
}

test "nested JS -> native -> JS -> native -> JS: 3 levels deep and shared max_call_depth (D51)" {
    const S = struct {
        // Calls `args[0]` with `args[1..]`.
        fn passthrough(rt: *zqjs.Runtime, _: ?*anyopaque, _: ?zqjs.Handle, args: []const zqjs.Handle, out: *zqjs.NativeOut) zqjs.NativeError!void {
            out.result = try callInNative(rt, args[0], null, args[1..]);
        }
    };

    // 1. 3-level round-trip: JS (level 0) -> n1 -> JS (level 1) -> n2 -> JS (level 2)
    {
        var buf: [128]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        const rt = try zqjs.Runtime.create(testing.allocator, .{ .output = &out });
        defer rt.destroy();

        try rt.defineGlobalFunction("n1", S.passthrough, null);
        try rt.defineGlobalFunction("n2", S.passthrough, null);

        const src =
            \\function level2(x) { return x + 1; }
            \\function level1(x) { return n2(level2, x * 2) + 10; }
            \\print(n1(level1, 5));
        ;
        const p = try rt.compile("three_levels.js", src, null);
        defer p.destroy();
        try rt.run(p, null);
        try testing.expectEqualStrings("21\n", out.buffered());
    }

    // 2. Mutual recursion across JS and native callbacks shares one `call_depth` counter
    //    and stops cleanly at `max_call_depth` (D51 #2).
    {
        const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_call_depth = 12 } });
        defer rt.destroy();

        try rt.defineGlobalFunction("hop", S.passthrough, null);
        const src =
            \\function bounce(n) {
            \\  return hop(bounce, n + 1);
            \\}
            \\bounce(0);
        ;
        const p = try rt.compile("depth.js", src, null);
        defer p.destroy();
        var failure: zqjs.Failure = .{};
        try testing.expectError(error.LimitExceeded, rt.run(p, &failure));
        try testing.expectEqual(zqjs.Failure.Kind.limit, failure.kind);
        try testing.expectEqual(@as(?zqjs.Limit, .call_depth), failure.limit);

        // Unwound cleanly: a shallow call on the same runtime still works.
        const p2 = try rt.compile("ok.js", "let x = hop(function(a) { return a + 1; }, 41);", null);
        defer p2.destroy();
        try rt.run(p2, null);
    }
}

test "slice overshoot and latched budget exhaustion across native callbacks (D51, Q8, S10)" {
    const LatchMode = enum { propagate, swallow_ok, swallow_host_err, swallow_throw };
    const S = struct {
        fn runNested(rt: *zqjs.Runtime, raw: ?*anyopaque, _: ?zqjs.Handle, args: []const zqjs.Handle, out: *zqjs.NativeOut) zqjs.NativeError!void {
            const mode: *const LatchMode = @ptrCast(@alignCast(raw.?));
            const res = rt.call(args[0], null, &.{}, null) catch |e| switch (mode.*) {
                .propagate => return switch (e) {
                    error.OutputFailed => error.Internal,
                    else => |ne| ne,
                },
                .swallow_ok => {
                    // Attempt to swallow `LimitExceeded` and return a normal value: the
                    // latched `budget_fault` must still fault the outer execution (S10).
                    out.result = try rt.newNumber(999);
                    return;
                },
                .swallow_host_err => {
                    out.host_message = "tried to replace step limit with HostError";
                    return error.HostError;
                },
                .swallow_throw => {
                    const msg = [_]u16{ 'h', 'i', 'd', 'e' };
                    rt.throwJs(.TypeError, &msg);
                    return error.Thrown;
                },
            };
            out.result = res;
        }
    };

    // 1. Slice overshoot (Q8, D51): `resume(1)` enters a native callback whose nested JS
    //    executes ~100 steps; the native callback cannot suspend mid-stack, so it overshoots
    //    the 1-step slice and returns `.suspended` once the outer VM finishes the `.call`
    //    step, with all nested steps charged to the execution's cumulative budget.
    {
        var buf: [64]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buf);
        const rt = try zqjs.Runtime.create(testing.allocator, .{
            .limits = .{ .max_steps = 500 },
            .output = &out,
        });
        defer rt.destroy();

        var mode: LatchMode = .propagate;
        try rt.defineGlobalFunction("runNested", S.runNested, &mode);

        const src =
            \\let r = runNested(function() {
            \\  let s = 0;
            \\  for (let i = 0; i < 20; i++) { s = s + i; }
            \\  return s;
            \\});
            \\print(r);
        ;
        const p = try rt.compile("overshoot.js", src, null);
        defer p.destroy();
        const ex = try rt.start(p);
        defer ex.destroy();

        // Step 1-by-1: the step that invokes `runNested` overshoots the 1-step slice,
        // completes the nested loop, and yields `.suspended` before `print(r)`.
        var slices: usize = 0;
        while (true) {
            const st = try ex.@"resume"(1, null);
            slices += 1;
            if (st == .finished) break;
        }
        try testing.expect(slices > 1 and slices < 25); // the 20-iteration loop ran inside one outer step!
        try testing.expectEqualStrings("190\n", out.buffered());
    }

    // 2. Hard stop at `max_steps` + latched `budget_fault` (S10): even if the native
    //    attempts to swallow `error.LimitExceeded` and return `Ok`, `HostError`, or `Thrown`,
    //    the outer execution always faults with `LimitExceeded(steps)`.
    for ([_]LatchMode{ .propagate, .swallow_ok, .swallow_host_err, .swallow_throw }) |m| {
        const rt = try zqjs.Runtime.create(testing.allocator, .{ .limits = .{ .max_steps = 50 } });
        defer rt.destroy();

        var mode: LatchMode = m;
        try rt.defineGlobalFunction("runNested", S.runNested, &mode);

        const p = try rt.compile("runaway.js", "runNested(function() { while (true) {} });", null);
        defer p.destroy();
        const ex = try rt.start(p);
        defer ex.destroy();

        var failure: zqjs.Failure = .{};
        try testing.expectError(error.LimitExceeded, ex.@"resume"(3, &failure));
        try testing.expectEqual(zqjs.Failure.Kind.limit, failure.kind);
        try testing.expectEqual(@as(?zqjs.Limit, .steps), failure.limit);
        try testing.expectEqualStrings("LimitExceeded(steps)", failure.message());
    }
}

fn checkNativeRoundTripAllocFailOnce(allocator: std.mem.Allocator) !void {
    const S = struct {
        fn nativeStep(rt: *zqjs.Runtime, _: ?*anyopaque, _: ?zqjs.Handle, args: []const zqjs.Handle, out: *zqjs.NativeOut) zqjs.NativeError!void {
            // args[0] = callback, args[1] = object, args[2] = number
            const kept = try args[1].dup();
            defer kept.release();

            const extra = try rt.newNumber(5);
            defer extra.release();

            const res = rt.call(args[0], kept, &.{ kept, args[2], extra }, null) catch |e| return switch (e) {
                error.OutputFailed => error.OutOfMemory,
                else => |ne| ne,
            };
            out.result = res;
        }
    };

    var discard: std.Io.Writer.Discarding = .init(&.{});
    const rt = zqjs.Runtime.create(allocator, .{ .output = &discard.writer }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer rt.destroy();

    rt.defineGlobalFunction("nativeStep", S.nativeStep, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NameTaken => return error.TestUnexpectedResult,
    };

    const src =
        \\let box = { base: 10 };
        \\let r = nativeStep(function(o, a, b) {
        \\  return o.base + a + b;
        \\}, box, 27);
        \\print(r);
    ;
    const p = rt.compile("alloc.js", src, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TestUnexpectedResult,
    };
    defer p.destroy();

    rt.run(p, null) catch |e| switch (e) {
        error.OutOfMemory, error.OutputFailed => return error.OutOfMemory,
        else => return error.TestUnexpectedResult,
    };
}

test "native callbacks: checkAllAllocationFailures across defineGlobalFunction and JS -> native -> JS round trip (E6)" {
    try testing.checkAllAllocationFailures(testing.allocator, checkNativeRoundTripAllocFailOnce, .{});
}

test "stress: 1,000,000+ native calls under max_handles = 16 recycle slots with flat handle_bytes (D50)" {
    const State = struct {
        calls: u64 = 0,
    };
    const S = struct {
        // Each call receives 3 temporary argument handles and mints 1 result handle
        // (4 handle creations/releases per call = 4,000,000 handle slot cycles across 1M calls).
        fn tick(rt: *zqjs.Runtime, raw: ?*anyopaque, _: ?zqjs.Handle, args: []const zqjs.Handle, out: *zqjs.NativeOut) zqjs.NativeError!void {
            const st: *State = @ptrCast(@alignCast(raw.?));
            st.calls += 1;
            const a = args[0].number() orelse return error.Internal;
            const b = args[1].number() orelse return error.Internal;
            const c = args[2].number() orelse return error.Internal;
            out.result = try rt.newNumber(a + b - c);
        }
    };

    var buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buf);
    const rt = try zqjs.Runtime.create(testing.allocator, .{
        .limits = .{
            .max_handles = 16,
            .max_steps = 25_000_000,
        },
        .output = &out,
    });
    defer rt.destroy();

    var state: State = .{};
    try rt.defineGlobalFunction("tick", S.tick, &state);

    // Hold 2 long-lived handles across the entire 1,000,000-call run to verify live
    // handles coexist with high-frequency slot recycling in the same small table.
    const anchor = try rt.newNumber(42);
    defer anchor.release();
    const anchor_dup = try anchor.dup();
    defer anchor_dup.release();

    const p = try rt.compile(
        "stress_handles.js",
        \\let acc = 0;
        \\for (let i = 0; i < 1000000; i++) {
        \\  acc = tick(acc, 3, 2);
        \\}
        \\print(acc);
    ,
        null,
    );
    defer p.destroy();

    // Warm 1 call so the initial slot table capacity is established, then run the 1M-call script.
    const p_warm = try rt.compile("warm.js", "tick(1, 2, 3);", null);
    defer p_warm.destroy();
    try rt.run(p_warm, null);
    const warm_mem = rt.memory();
    try testing.expect(warm_mem.handle_bytes > 0);
    try testing.expect(warm_mem.handle_bytes <= 16 * 64);

    try rt.run(p, null);

    const after_mem = rt.memory();
    try testing.expectEqual(@as(u64, 1_000_001), state.calls);
    try testing.expectEqualStrings("1000000\n", out.buffered());
    // Handle table memory and JS heap memory did not grow across 1,000,000 native calls!
    try testing.expectEqual(warm_mem.handle_bytes, after_mem.handle_bytes);
    try testing.expectEqual(warm_mem.heap_bytes, after_mem.heap_bytes);
    try testing.expectEqual(@as(?f64, 42), anchor.number());
    try testing.expectEqual(@as(?f64, 42), anchor_dup.number());
}

test "M9.1: Memory reports minor/major GC counts and last/max pause durations with Options.clock" {
    const FakeClock = struct {
        now_ns: u64 = 1_000_000,
        step_ns: u64 = 10_000,

        fn tick(raw: ?*anyopaque) u64 {
            const c: *@This() = @ptrCast(@alignCast(raw.?));
            const cur = c.now_ns;
            c.now_ns += c.step_ns;
            return cur;
        }
    };

    var clock: FakeClock = .{};
    const rt = try zqjs.Runtime.create(testing.allocator, .{
        .limits = .{
            .nursery_bytes = 4 * 1024,
            .max_heap_bytes = 512 * 1024,
        },
        .clock = FakeClock.tick,
        .clock_ctx = &clock,
    });
    defer rt.destroy();

    const p = try rt.compile(
        "gc_telemetry.js",
        \\let sink = 0;
        \\for (let i = 0; i < 300; i = i + 1) {
        \\  let tmp = { a: i, b: i + 1 };
        \\  sink = sink + tmp.a;
        \\}
    ,
        null,
    );
    defer p.destroy();
    try rt.run(p, null);

    const after_minor = rt.memory();
    try testing.expect(after_minor.minor_collections >= 1);
    try testing.expectEqual(
        after_minor.collections,
        after_minor.minor_collections + after_minor.major_collections,
    );
    try testing.expect(after_minor.last_gc_pause_ns > 0);
    try testing.expect(after_minor.max_gc_pause_ns >= after_minor.last_gc_pause_ns);

    // Force a shorter pause on an explicit major collection and verify max_gc_pause_ns stays at the high-water mark.
    const prev_max = after_minor.max_gc_pause_ns;
    clock.step_ns = 1_000;
    rt.collectGarbage();

    const after_major = rt.memory();
    try testing.expectEqual(after_minor.major_collections + 1, after_major.major_collections);
    try testing.expectEqual(
        after_major.collections,
        after_major.minor_collections + after_major.major_collections,
    );
    try testing.expect(after_major.last_gc_pause_ns > 0);
    try testing.expect(after_major.last_gc_pause_ns < prev_max);
    try testing.expectEqual(prev_max, after_major.max_gc_pause_ns);
}
