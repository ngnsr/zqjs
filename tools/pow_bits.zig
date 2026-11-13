//! Portability check for pow: computes `x ** y` for every input in tests/ops/pow.jsonl
//! and prints a SHA-256 of all result bit patterns. Build it for different targets and
//! optimisation modes and compare the digests; equal digests mean bit-identical results.
//!
//!   zig build pow-bits -- tests/ops/pow.jsonl
//!   zig build pow-bits -Dtarget=x86_64-macos -Dcpu=haswell -Doptimize=ReleaseFast -- tests/ops/pow.jsonl
//!
//! Results so far are recorded in DESIGN_DECISIONS D25.

const std = @import("std");
const pow = @import("zqjs").ops.pow;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: pow-bits tests/ops/pow.jsonl\n", .{});
        return 2;
    }
    const text = try std.Io.Dir.cwd().readFileAlloc(io, args[1], init.arena.allocator(), .limited(1 << 26));

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice([3][]const u8, init.gpa, line, .{});
        defer parsed.deinit();
        const x: f64 = @bitCast(try std.fmt.parseInt(u64, parsed.value[0], 16));
        const y: f64 = @bitCast(try std.fmt.parseInt(u64, parsed.value[1], 16));
        const result: u64 = @bitCast(pow(x, y));
        hash.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, result)));
        count += 1;
    }
    var buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const digest = hash.finalResult();
    try out.interface.print("{d} results, sha256 {x}\n", .{ count, digest });
    try out.interface.flush();
    return 0;
}
