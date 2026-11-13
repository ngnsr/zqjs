//! Interpreter tests that node can't check: resource limits, allocation failures,
//! exception ownership, and fuzzing of the whole pipeline. (Observable JS behaviour is
//! tested against node in tests/diff.)

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zqjs = @import("zqjs");
const Limits = zqjs.Limits;
const Limit = zqjs.Limit;
const Diagnostic = zqjs.Diagnostic;
const parse = zqjs.parse;
const resolve = zqjs.resolve;
const Runtime = zqjs.Runtime;

/// Runs `source` and returns the runtime error (or null on success), keeping the
/// runtime alive so the caller can inspect it. Output is discarded.
fn runScript(arena: Allocator, rt: *Runtime, source: []const u8) !?anyerror {
    var d: Diagnostic = .{};
    const script = try parse(arena, source, .{}, &d);
    const res = try resolve(arena, script, &d);
    zqjs.interpret(rt, script, res) catch |e| return @as(?anyerror, e); // as a value, not as an error
    return null;
}

fn expectLimit(source: []const u8, limits: Limits, which: Limit) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var rt = Runtime.init(testing.allocator, limits, &discard.writer);
    defer rt.deinit();
    try testing.expectEqual(@as(?anyerror, error.LimitExceeded), try runScript(arena.allocator(), &rt, source));
    try testing.expectEqual(which, rt.limitHit().?);
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

test "heap and string limits stop runaway strings" {
    try expectLimit("let s = 'ab'; while (true) { s += s; }", .{ .max_heap_bytes = 1 << 20 }, .heap_bytes);
    try expectLimit("let s = 'ab'; while (true) { s += s; }", .{ .max_string_length = 1000 }, .string_length);
    // Many small strings: per-allocation overhead is charged, so this can't evade the limit.
    try expectLimit("while (true) { ''; }", .{ .max_heap_bytes = 1 << 16 }, .heap_bytes);
}

test "an exception outlives unwinding and is freed by Runtime.deinit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var rt = Runtime.init(testing.allocator, .{}, &discard.writer);
    defer rt.deinit(); // testing.allocator reports a leak if the message isn't freed
    try testing.expectEqual(@as(?anyerror, error.Thrown), try runScript(arena.allocator(), &rt, "{ let longName = 1; } longName;"));
    const ex = rt.exception.?;
    try testing.expectEqual(zqjs.ErrorName.ReferenceError, ex.name);
    const expected = std.unicode.utf8ToUtf16LeStringLiteral("longName is not defined");
    try testing.expectEqualSlices(u16, expected, ex.message.units);
}

test "converting a native function to a string is Unsupported, not a mismatch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var rt = Runtime.init(testing.allocator, .{}, &discard.writer);
    defer rt.deinit();
    try testing.expectEqual(@as(?anyerror, error.Unsupported), try runScript(arena.allocator(), &rt, "print(print);"));
}

fn runOnce(allocator: Allocator, source: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = zqjs.runSource(allocator, "t", source, .{ .max_steps = 100_000 }, .harness, &out.writer, &discard.writer) catch |e| switch (e) {
        // The output writer allocates too; under injected failure it reports WriteFailed.
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
}

test "error paths: every allocation failing once leaks nothing" {
    const sources = [_][]const u8{
        "let s = 'a'; for (let i = 0; i < 3; i++) { s += i + '!'; } print(s, +'0x10', 1 / 3);",
        "let x = 1; { x; let x = 2; }", // ends in an exception whose message is allocated
        "const c = 1; c = print('rhs');",
    };
    for (sources) |src| try testing.checkAllAllocationFailures(testing.allocator, runOnce, .{src});
}

fn fuzzOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const source = buf[0..smith.slice(&buf)];
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try zqjs.runSource(testing.allocator, "fuzz", source, .{
        .max_nesting_depth = 64,
        .max_steps = 20_000,
        .max_heap_bytes = 1 << 20,
        .max_string_length = 1 << 12,
    }, .harness, &out.writer, &discard.writer);
}

test "fuzz: any input runs to an outcome within its budgets" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        "let s = ''; for (let i = 0; i < 10; i++) { if (i === 5) continue; s += i; } print(s);",
        "let x = 1; x = x + (x = 10); print(x, x ** 0.5, -0, 1 / -0, '\\uD83D' + '\\uDE00');",
        "const c = 1; while (true) { c++; }",
        "print(+' 0x1f ', 'a' < 'b', null >= 0, 1e21, 5e-324);",
    } });
}
