//! Tests over the whole frontend (parse → resolve → dump): allocation-failure paths
//! and fuzzing. Lives here, not in src/, so no frontend file depends on a later stage.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zqjs = @import("zqjs_internal");
const support = @import("support.zig");
const Diagnostic = zqjs.Diagnostic;
const Limits = zqjs.Limits;
const parse = zqjs.parse;

/// The whole frontend: parse, resolve, dump. Used by the error-path and fuzz tests.
fn frontendOnce(allocator: Allocator, source: []const u8, limits: Limits) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const script = parse(arena.allocator(), source, limits, &d) catch |err| return checkFailure(err, d, source);
    const res = zqjs.resolve(arena.allocator(), script, &d) catch |err| return checkFailure(err, d, source);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    try zqjs.dump.script(script, res, &discard.writer);
}

fn checkFailure(err: anyerror, d: Diagnostic, source: []const u8) !void {
    if (err == error.OutOfMemory) return err;
    try testing.expect(d.start <= d.end and d.end <= source.len);
}

test "watchdog: this binary fails, instead of hanging, if a test gets stuck" {
    support.watchdog(@src().file);
}

test "error paths: every allocation failing once leaks nothing" {
    const sources = [_][]const u8{
        "1 + 2 * 3; 'a\\u{1F600}b'; -(4 ** 2) / 5 % 6;",
        "1 + 2; 3 *",
        "((1 + 2) * 'x') === null && !true || 2 ** 3 ** 2;",
        "let a = 1, b; { const c = a; b = c ** 2; } for (let i = 0; i < 3; i++) { if (i) continue; else break; }",
        "let x = 1; while (x < 9) { x += 2; x++; } let x;", // fails in the resolver
        "async function f(a, b = 1) { return await a + b; } let g = async x => await x;",
    };
    for (sources) |src| try testing.checkAllAllocationFailures(testing.allocator, frontendOnce, .{ src, Limits{} });
}

fn parseNanos(source: []const u8) !i96 {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const start = std.Io.Timestamp.now(testing.io, .awake);
    _ = try parse(arena.allocator(), source, .{}, &d);
    return start.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toNanoseconds();
}

test "M20: the arrow lookahead keeps nested parentheses linear" {
    // Scanning to the matching `)` at every level made this ~200x the flat parse.
    const depth = 200;
    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(testing.allocator);
    try flat.append(testing.allocator, '[');
    for (0..20_000) |_| try flat.appendSlice(testing.allocator, "1,");
    try flat.append(testing.allocator, ']');
    var nested: std.ArrayList(u8) = .empty;
    defer nested.deinit(testing.allocator);
    try nested.appendNTimes(testing.allocator, '(', depth);
    try nested.appendSlice(testing.allocator, flat.items);
    try nested.appendNTimes(testing.allocator, ')', depth);
    try flat.append(testing.allocator, ';');
    try nested.append(testing.allocator, ';');
    const t_flat = @max(try parseNanos(flat.items), 1);
    const t_nested = try parseNanos(nested.items);
    try testing.expect(t_nested < 20 * t_flat);
}

test "M26: cover grammar keeps deeply nested parens/arrays/objects followed by => linear" {
    const depth = 150;
    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(testing.allocator);
    try flat.append(testing.allocator, '[');
    for (0..10_000) |_| try flat.appendSlice(testing.allocator, "1,");
    try flat.appendSlice(testing.allocator, "];");

    // Deeply nested (([{"k": ...}])) => 1 (invalid arrow head, must fail in linear time).
    var nested_arrow: std.ArrayList(u8) = .empty;
    defer nested_arrow.deinit(testing.allocator);
    try nested_arrow.appendNTimes(testing.allocator, '(', depth);
    try nested_arrow.appendNTimes(testing.allocator, '[', 50);
    for (0..10_000) |_| try nested_arrow.appendSlice(testing.allocator, "{a:1},");
    try nested_arrow.appendNTimes(testing.allocator, ']', 50);
    try nested_arrow.appendNTimes(testing.allocator, ')', depth);
    try nested_arrow.appendSlice(testing.allocator, " => 1;");

    const t_flat = @max(try parseNanos(flat.items), 1);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const start = std.Io.Timestamp.now(testing.io, .awake);
    try testing.expectError(error.SyntaxError, parse(arena.allocator(), nested_arrow.items, .{}, &d));
    const t_nested = start.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toNanoseconds();
    try testing.expect(t_nested < 30 * t_flat);
}

test "M27: 200 nested try/finally with return compiles linearly in time and code size" {
    const depth = 200;
    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(testing.allocator);
    try flat.appendSlice(testing.allocator, "function f() { ");
    for (0..depth) |_| try flat.appendSlice(testing.allocator, "try { } finally { let x = 1; } ");
    try flat.appendSlice(testing.allocator, "return 1; }");

    var nested: std.ArrayList(u8) = .empty;
    defer nested.deinit(testing.allocator);
    try nested.appendSlice(testing.allocator, "function f() { ");
    for (0..depth) |_| try nested.appendSlice(testing.allocator, "try { ");
    try nested.appendSlice(testing.allocator, "return 1;");
    for (0..depth) |_| try nested.appendSlice(testing.allocator, " } finally { let x = 1; }");
    try nested.appendSlice(testing.allocator, " }");

    const compileOnce = struct {
        fn run(src: []const u8) !struct { nanos: i96, code_len: usize } {
            var arena = std.heap.ArenaAllocator.init(testing.allocator);
            defer arena.deinit();
            var d: Diagnostic = .{};
            const script = try parse(arena.allocator(), src, .{}, &d);
            const res = try zqjs.resolve(arena.allocator(), script, &d);
            var h = zqjs.heap.Heap.init(testing.allocator, .{});
            defer h.deinit();
            const start = std.Io.Timestamp.now(testing.io, .awake);
            var proto = try zqjs.compile(testing.allocator, &h, script, res, .{}, &d);
            defer proto.deinit(testing.allocator);
            const elapsed = start.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toNanoseconds();
            return .{ .nanos = elapsed, .code_len = proto.functions[0].code.len };
        }
    }.run;

    const r_flat = try compileOnce(flat.items);
    const r_nested = try compileOnce(nested.items);
    try testing.expect(r_nested.nanos < 20 * @max(r_flat.nanos, 1));
    // Each finally level is a constant number of bytes (~80-120 bytes); exponential would be > 2^200.
    try testing.expect(r_nested.code_len < depth * 256);
}

fn fuzzOne(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    try frontendOnce(testing.allocator, buf[0..smith.slice(&buf)], .{ .max_nesting_depth = 64 });
}

test "fuzz: frontend accepts or diagnoses any input without crashing" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        "1 + 2 * 3;",
        "'\\u{1F600}\\uD800' === \"x\";",
        "(-2) ** 2 ** 3 < 4 && !null || .5e3;",
        "1 /* c */ // d\n;",
        "let x = 1; { let x = x; } for (let i = 0; i < 3; i++) { x += i; if (x) break; }",
        "const c = 1; while (c) { c = c - 1; continue; }",
    } });
}
