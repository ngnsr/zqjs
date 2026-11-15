//! A test binary's watchdog, with no dependency on ZQJS (tests/api_test.zig may import only
//! the public `zqjs`): if the binary is still running after `limit_s`, it says which binary
//! and aborts, so a hung test fails the build instead of hanging it (the build runner has no
//! timeouts).

const std = @import("std");

pub fn start(file: []const u8, limit_s: i64) void {
    const t = std.Thread.spawn(.{}, struct {
        fn run(name: []const u8, seconds: i64) void {
            std.Io.sleep(std.testing.io, .fromSeconds(seconds), .awake) catch return;
            std.debug.print("\n{s}: still running after {d} s, so a test is probably stuck. The last test the runner printed is the suspect; rerun it alone with -Dtest-filter.\n", .{ name, seconds });
            std.process.abort();
        }
    }.run, .{ file, limit_s }) catch return; // no watchdog is better than a failed suite
    t.detach();
}
