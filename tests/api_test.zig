//! Tests of the public embedding API (M9.0). This file imports only `zqjs`, as an embedder
//! does: build.zig gives it no other module, so reaching an internal fails to build.

const std = @import("std");
const testing = std.testing;
const zqjs = @import("zqjs");

test "watchdog: this binary fails, instead of hanging, if a test gets stuck" {
    @import("watchdog.zig").start(@src().file, 20 * 60);
}

test "the public API declares exactly the approved names (D46: a new export is a reviewed decision)" {
    const approved = [_][]const u8{ "Limit", "Limits" };
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
