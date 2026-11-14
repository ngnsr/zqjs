//! Benchmark baseline: runs every bench/*.js on both engines and prints one row per
//! (program, engine):
//!   steps   budget steps charged (VM: instructions executed; tree-walker: statements,
//!           expressions, iterations). Deterministic: identical on every machine.
//!   heap    accounted heap bytes at the end (no GC yet, so: everything allocated).
//!           Deterministic too.
//!   median  wall time of `runs` in-process runs (parse → resolve → [compile → verify] →
//!           run), in milliseconds. Machine-dependent; compare only on the same machine.
//!
//!   zig build bench                  (always ReleaseFast)
//!   zig build bench > bench/baseline.txt
//!
//! A change in steps or heap means the engines do different work; a change in time
//! alone means the same work got faster or slower.

const std = @import("std");
const builtin = @import("builtin");
const zqjs = @import("zqjs");

const runs = 5;

const limits: zqjs.Limits = .{
    .max_steps = std.math.maxInt(u64),
    .max_heap_bytes = 4 << 30, // the tree-walker allocates per scope entry (D37)
};

const Result = struct { steps: u64, heap: usize, ns: u64 };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    var dir = try std.Io.Dir.cwd().openDir(io, "bench", .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".js")) try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    try out.print("# zqjs benchmark baseline: zig {s}, {s}-{s} ({s}), {s}, median of {d} runs\n", .{
        builtin.zig_version_string, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), builtin.cpu.model.name, @tagName(builtin.mode), runs,
    });
    try out.print("{s:<22} {s:<9} {s:>12} {s:>12} {s:>10}\n", .{ "program", "engine", "steps", "heap", "median ms" });
    for (names.items) |name| {
        const source = try dir.readFileAlloc(io, name, arena, .limited(1 << 20));
        for ([_]zqjs.Engine{ .vm, .treewalk }) |engine| {
            var times: [runs]u64 = undefined;
            var first: ?Result = null;
            for (&times) |*t| {
                const r = try runOnce(gpa, io, source, engine);
                // Steps and heap must not vary between runs; if they do, something is
                // nondeterministic and the baseline would be meaningless.
                if (first) |f| if (f.steps != r.steps or f.heap != r.heap) return error.NonDeterministic;
                first = r;
                t.* = r.ns;
            }
            std.mem.sort(u64, &times, {}, std.sort.asc(u64));
            const median = times[runs / 2];
            try out.print("{s:<22} {s:<9} {d:>12} {d:>12} {d:>10.1}\n", .{ name, @tagName(engine), first.?.steps, first.?.heap, @as(f64, @floatFromInt(median)) / 1e6 });
        }
    }
    return 0;
}

fn runOnce(gpa: std.mem.Allocator, io: std.Io, source: []const u8, engine: zqjs.Engine) !Result {
    const start = std.Io.Timestamp.now(io, .awake);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var diag: zqjs.Diagnostic = .{};
    const script = try zqjs.parse(arena.allocator(), source, limits, &diag);
    const res = try zqjs.resolve(arena.allocator(), script, &diag);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var rt = zqjs.Runtime.init(gpa, limits, &discard.writer);
    defer rt.deinit();
    switch (engine) {
        .treewalk => try zqjs.interpret(&rt, script, res),
        .vm => {
            var proto = try zqjs.compile(gpa, &rt.heap, script, res, limits, &diag);
            defer proto.deinit(gpa);
            var failure: zqjs.verify.Failure = .{};
            _ = try zqjs.verify.verify(gpa, &proto, limits, &failure);
            var vm = try zqjs.Vm.init(&rt, &proto);
            defer vm.deinit();
            try vm.run();
        },
    }
    const ns = start.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds();
    return .{ .steps = rt.steps, .heap = rt.heap.bytes, .ns = @intCast(ns) };
}
