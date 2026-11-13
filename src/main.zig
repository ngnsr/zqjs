//! CLI. M1: `zqjs --dump-ast FILE` or `zqjs --dump-ast -e SOURCE`.

const std = @import("std");
const zqjs = @import("zqjs");

const usage =
    \\usage: zqjs --dump-ast FILE
    \\       zqjs --dump-ast -e SOURCE
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator(); // process lifetime; also holds the AST
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    var err_buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &err_buf);
    const out = &stdout.interface;
    const err = &stderr.interface;
    defer out.flush() catch {};
    defer err.flush() catch {};

    const limits: zqjs.Limits = .{};
    const name: []const u8, const source: []const u8 = blk: {
        if (args.len == 3 and std.mem.eql(u8, args[1], "--dump-ast"))
            break :blk .{ args[2], std.Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(limits.max_source_bytes + 1)) catch |e| switch (e) {
                error.StreamTooLong => {
                    try err.print("{s}: LimitExceeded(source_bytes)\n", .{args[2]});
                    return 1;
                },
                else => {
                    try err.print("{s}: cannot read file: {s}\n", .{ args[2], @errorName(e) });
                    return 1;
                },
            } };
        if (args.len == 4 and std.mem.eql(u8, args[1], "--dump-ast") and std.mem.eql(u8, args[2], "-e"))
            break :blk .{ "<eval>", args[3] };
        try err.writeAll(usage);
        return 2;
    };

    var diag: zqjs.Diagnostic = .{};
    const script = zqjs.parse(arena, source, limits, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            try diag.render(source, name, err);
            return 1;
        },
    };
    const resolution = zqjs.resolve(arena, script, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {
            try diag.render(source, name, err);
            return 1;
        },
    };
    try zqjs.dump.script(script, resolution, out);
    return 0;
}
