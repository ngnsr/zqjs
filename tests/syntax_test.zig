//! Runs every case in syntax/cases.jsonl through the ZQJS parser.
//! Line format: [outcome, source, expected_dump?] where outcome is
//! "ok", "syntax" or "unsupported:<feature id>" (LANGUAGE.md §2).
//! The same file is checked against node by harness/check_syntax_cases.js.

const std = @import("std");
const zqjs = @import("zqjs");
const support = @import("support.zig");

fn frontend(arena: std.mem.Allocator, source: []const u8, diag: *zqjs.Diagnostic, w: *std.Io.Writer) !void {
    const script = try zqjs.parse(arena, source, .{}, diag);
    const resolution = try zqjs.resolve(arena, script, diag);
    try zqjs.dump.script(script, resolution, w);
}

test "watchdog: this binary fails, instead of hanging, if a test gets stuck" {
    support.watchdog(@src().file);
}

test "syntax cases" {
    const gpa = std.testing.allocator;
    var failures: usize = 0;
    var lines = std.mem.splitScalar(u8, @embedFile("syntax/cases.jsonl"), '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice([]const []const u8, gpa, line, .{});
        defer parsed.deinit();
        const case = parsed.value;
        const outcome, const source = .{ case[0], case[1] };

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var diag: zqjs.Diagnostic = .{};
        var got: std.Io.Writer.Allocating = .init(arena.allocator());
        if (frontend(arena.allocator(), source, &diag, &got.writer)) {
            const dump = std.mem.trimEnd(u8, got.written(), "\n");
            if (!std.mem.eql(u8, outcome, "ok") or (case.len > 2 and !std.mem.eql(u8, dump, case[2]))) {
                std.debug.print("cases.jsonl:{d}: expected {s}, got ok: {s}\n", .{ line_no, outcome, dump });
                failures += 1;
            }
        } else |err| {
            if (err == error.OutOfMemory) return err;
            const actual = switch (diag.detail) {
                .syntax_error => "syntax",
                .unsupported => |f| try std.fmt.allocPrint(arena.allocator(), "unsupported:{s}", .{@tagName(f)}),
                .limit_exceeded => "limit",
            };
            if (!std.mem.eql(u8, outcome, actual)) {
                try diag.render(source, "case", &got.writer);
                std.debug.print("cases.jsonl:{d}: expected {s}, got {s}\n{s}", .{ line_no, outcome, actual, got.written() });
                failures += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
