//! Differential tests: every tests/diff/*.js runs under ZQJS in harness mode, on *both*
//! engines, and each output must equal tests/diff/*.out, which node produced
//! (tests/harness/golden.js). A program that ZQJS rejects (SyntaxError, Unsupported,
//! LimitExceeded) prints a diagnostic node never prints, so it fails here too.

const std = @import("std");
const testing = std.testing;
const zqjs = @import("zqjs");
const support = @import("support.zig");

test "tests/diff programs produce node's output on both engines" {
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

        for (support.engines) |engine| {
            var got = try support.run(gpa, source, .{ .max_steps = 50_000_000 }, engine, .harness);
            defer got.deinit(gpa);
            if (!std.mem.eql(u8, got.out, expected)) {
                std.debug.print("\n== {s} on {s}\n-- source\n{s}\n-- expected (node)\n{s}", .{ entry.name, @tagName(engine), source, expected });
                support.printOutcome(@tagName(engine), got);
                if (engine == .vm) support.printBytecode(gpa, source);
                failures += 1;
            }
        }
    }
    try testing.expect(count > 0);
    try testing.expectEqual(@as(usize, 0), failures);
}
