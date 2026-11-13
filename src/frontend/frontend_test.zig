//! Tests over the whole frontend (parse → resolve → dump): allocation-failure paths
//! and fuzzing. Kept out of parser.zig so the parser doesn't depend on later stages.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Diagnostic = @import("diag.zig").Diagnostic;
const Limits = @import("../limits.zig").Limits;
const parse = @import("parser.zig").parse;
const resolver = @import("resolver.zig");
const dump = @import("dump.zig");

/// The whole frontend: parse, resolve, dump. Used by the error-path and fuzz tests.
fn frontendOnce(allocator: Allocator, source: []const u8, limits: Limits) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var d: Diagnostic = .{};
    const script = parse(arena.allocator(), source, limits, &d) catch |err| return checkFailure(err, d, source);
    const res = resolver.resolve(arena.allocator(), script, &d) catch |err| return checkFailure(err, d, source);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    try dump.script(script, res, &discard.writer);
}

fn checkFailure(err: anyerror, d: Diagnostic, source: []const u8) !void {
    if (err == error.OutOfMemory) return err;
    try testing.expect(d.start <= d.end and d.end <= source.len);
}

test "error paths: every allocation failing once leaks nothing" {
    const sources = [_][]const u8{
        "1 + 2 * 3; 'a\\u{1F600}b'; -(4 ** 2) / 5 % 6;",
        "1 + 2; 3 *",
        "((1 + 2) * 'x') === null && !true || 2 ** 3 ** 2;",
        "let a = 1, b; { const c = a; b = c ** 2; } for (let i = 0; i < 3; i++) { if (i) continue; else break; }",
        "let x = 1; while (x < 9) { x += 2; x++; } let x;", // fails in the resolver
    };
    for (sources) |src| try testing.checkAllAllocationFailures(testing.allocator, frontendOnce, .{ src, Limits{} });
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
