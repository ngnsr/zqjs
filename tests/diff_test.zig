//! Differential tests: every tests/diff/*.js runs under ZQJS in harness mode, and its
//! output must equal tests/diff/*.out, which node produced (tests/harness/golden.js).
//! A program that ZQJS rejects (SyntaxError, Unsupported, LimitExceeded) prints a
//! diagnostic node never prints, so it fails here too.

const std = @import("std");
const testing = std.testing;
const zqjs = @import("zqjs");

test "tests/diff programs produce node's output" {
    const io = testing.io;
    const gpa = testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/diff", .{ .iterate = true });
    defer dir.close(io);

    var count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".js")) continue;
        count += 1;
        const source = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        defer gpa.free(source);
        const out_name = try std.fmt.allocPrint(gpa, "{s}.out", .{entry.name[0 .. entry.name.len - 3]});
        defer gpa.free(out_name);
        const expected = try dir.readFileAlloc(io, out_name, gpa, .limited(1 << 20));
        defer gpa.free(expected);

        var got: std.Io.Writer.Allocating = .init(gpa);
        defer got.deinit();
        var discard: std.Io.Writer.Discarding = .init(&.{});
        _ = try zqjs.runSource(gpa, entry.name, source, .{ .max_steps = 50_000_000 }, .harness, &got.writer, &discard.writer);
        if (!std.mem.eql(u8, got.written(), expected)) {
            std.debug.print("\n== {s}\n-- expected (node)\n{s}-- got (zqjs)\n{s}", .{ entry.name, expected, got.written() });
            failures += 1;
        }
    }
    try testing.expect(count > 0);
    try testing.expectEqual(@as(usize, 0), failures);
}
