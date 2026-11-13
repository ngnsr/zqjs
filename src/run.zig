//! Source text → parse → resolve → run, with outcome reporting. Shared by the CLI and
//! the differential tests so both print exactly the same thing.
//!
//! Modes:
//!   .normal   program output to `out`; diagnostics and `Uncaught …` to `err`
//!   .harness  everything to `out`, and an uncaught exception prints only
//!             `Uncaught <Name>`, which is what tests/harness/golden.js prints for node
//!             (messages are never compared, LANGUAGE.md §1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Limits = @import("limits.zig").Limits;
const Diagnostic = @import("frontend/diag.zig").Diagnostic;
const parse = @import("frontend/parser.zig").parse;
const resolve = @import("frontend/resolver.zig").resolve;
const Runtime = @import("runtime/runtime.zig").Runtime;
const ops = @import("runtime/ops.zig");
const treewalk = @import("interp/treewalk.zig");

pub const Mode = enum { normal, harness };

pub const Error = Allocator.Error || Writer.Error;

/// Returns the process exit code: 0 on success, 1 if the script did not complete.
pub fn runSource(gpa: Allocator, name: []const u8, source: []const u8, limits: Limits, mode: Mode, out: *Writer, err: *Writer) Error!u8 {
    const report = if (mode == .harness) out else err;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var diag: Diagnostic = .{};

    const script = parse(arena.allocator(), source, limits, &diag) catch |e|
        return frontendFailure(e, diag, source, name, report);
    const res = resolve(arena.allocator(), script, &diag) catch |e|
        return frontendFailure(e, diag, source, name, report);

    var rt = Runtime.init(gpa, limits, out);
    defer rt.deinit();
    treewalk.run(&rt, script, res) catch |e| {
        switch (e) {
            error.OutOfMemory, error.WriteFailed => |host| return host,
            error.Thrown => {
                const ex = rt.exception.?;
                try report.print("Uncaught {s}", .{@tagName(ex.name)});
                if (mode == .normal) {
                    try report.writeAll(": ");
                    try ops.writeUtf16(report, ex.message.units);
                }
                try report.writeByte('\n');
            },
            error.LimitExceeded => try report.print("{s}: LimitExceeded({s})\n", .{ name, @tagName(rt.limitHit().?) }),
            error.Unsupported => try report.print("{s}: Unsupported({s}): {s}\n", .{ name, @tagName(rt.unsupported.?), rt.unsupported.?.description() }),
        }
        return 1;
    };
    return 0;
}

fn frontendFailure(e: anyerror, diag: Diagnostic, source: []const u8, name: []const u8, report: *Writer) Error!u8 {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    try diag.render(source, name, report);
    return 1;
}
