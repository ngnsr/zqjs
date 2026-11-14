//! CLI.
//!   zqjs [options] FILE | zqjs [options] -e SOURCE
//! options:
//!   --test           harness output mode (used to compare with node)
//!   --dump-ast       print the resolved AST instead of running
//!   --dump-bytecode  compile, verify and print the bytecode instead of running
//!   --max-steps N    execution budget; 0 = unlimited (default: cli_default_steps)

const std = @import("std");
const zqjs = @import("zqjs");

const usage =
    \\usage: zqjs [--test | --dump-ast | --dump-bytecode] [--max-steps N] FILE
    \\       zqjs [--test | --dump-ast | --dump-bytecode] [--max-steps N] -e SOURCE
    \\
    \\  --max-steps N   stop after N execution steps (0 = unlimited, default 200000000)
    \\
;

/// The library default is unlimited (embedders choose their own budget), but at the
/// command line an accidental infinite loop should stop by itself: ~25M steps/s in a
/// Debug build, so this ends a runaway script within seconds.
const cli_default_steps: u64 = 200_000_000;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator(); // process lifetime
    const args = try init.minimal.args.toSlice(arena);

    // Streaming, not positional, writers: with `> file 2>&1` both descriptors share one
    // file offset, and positional writers would each start at 0 and overwrite each other.
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    var err_buf: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const out = &stdout.interface;
    const err = &stderr.interface;
    defer err.flush() catch {};
    defer out.flush() catch {}; // runs first: program output before the error report

    var rest = args[1..];
    const Command = enum { run, @"test", dump, dump_bytecode };
    var command: Command = .run;
    var limits: zqjs.Limits = .{ .max_steps = cli_default_steps };
    while (rest.len > 0 and std.mem.startsWith(u8, rest[0], "--")) {
        if (std.mem.eql(u8, rest[0], "--test")) {
            command = .@"test";
        } else if (std.mem.eql(u8, rest[0], "--dump-ast")) {
            command = .dump;
        } else if (std.mem.eql(u8, rest[0], "--dump-bytecode")) {
            command = .dump_bytecode;
        } else if (std.mem.eql(u8, rest[0], "--max-steps") and rest.len > 1) {
            const n = std.fmt.parseInt(u64, rest[1], 10) catch {
                try err.print("--max-steps: not a number: {s}\n", .{rest[1]});
                return 2;
            };
            limits.max_steps = if (n == 0) std.math.maxInt(u64) else n;
            rest = rest[1..];
        } else {
            try err.writeAll(usage);
            return 2;
        }
        rest = rest[1..];
    }

    const name: []const u8, const source: []const u8 = blk: {
        if (rest.len == 2 and std.mem.eql(u8, rest[0], "-e")) break :blk .{ "<eval>", rest[1] };
        if (rest.len == 1) break :blk .{ rest[0], std.Io.Dir.cwd().readFileAlloc(io, rest[0], arena, .limited(limits.max_source_bytes + 1)) catch |e| switch (e) {
            error.StreamTooLong => {
                try err.print("{s}: LimitExceeded(source_bytes)\n", .{rest[0]});
                return 1;
            },
            else => {
                try err.print("{s}: cannot read file: {s}\n", .{ rest[0], @errorName(e) });
                return 1;
            },
        } };
        try err.writeAll(usage);
        return 2;
    };

    switch (command) {
        .run => return zqjs.runSource(init.gpa, name, source, limits, .normal, out, err),
        .@"test" => return zqjs.runSource(init.gpa, name, source, limits, .harness, out, err),
        .dump => return dump(arena, name, source, limits, out, err),
        .dump_bytecode => return dumpBytecode(init.gpa, arena, name, source, limits, out, err),
    }
}

fn dump(arena: std.mem.Allocator, name: []const u8, source: []const u8, limits: zqjs.Limits, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
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

fn dumpBytecode(gpa: std.mem.Allocator, arena: std.mem.Allocator, name: []const u8, source: []const u8, limits: zqjs.Limits, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
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
    var heap = zqjs.Heap.init(gpa, limits);
    defer heap.deinit();
    var proto = zqjs.compile(gpa, &heap, script, resolution, limits, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.LimitExceeded => {
            try diag.render(source, name, err);
            return 1;
        },
    };
    defer proto.deinit(gpa);
    var failure: zqjs.verify.Failure = .{};
    _ = zqjs.verify.verify(gpa, proto, limits, &failure) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.InvalidBytecode => {
            // No listing: the disassembler trusts operands, which is exactly what failed.
            try err.print("{s}: internal error: invalid bytecode at {d}: {s}\n", .{ name, failure.pc, failure.reason });
            return 70;
        },
    };
    try zqjs.disassemble(proto, out);
    return 0;
}
