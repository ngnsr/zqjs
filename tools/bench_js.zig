//! Split-phase ZQJS VM benchmark harness (always ReleaseFast, smp_allocator).
//!
//! For each script, measures:
//!   1. Split-phase samples (fresh Runtime per sample):
//!      - `compile_ns`: parse + resolve + compile + verify (after `Runtime.init`)
//!      - `exec_ns`:    `Vm.init` + `vm.run()` + `vm.deinit()` (excluding `Runtime.init` and `compile`)
//!   2. Direct end-to-end samples (separate pass, fresh Runtime per sample):
//!      - `total_ns`:   `Runtime.init` + parse + resolve + compile + verify + `Vm.init` + `vm.run()` + teardown
//!
//! Usage:
//!   zig build bench-js                 # runs bench/suite/js/*.js
//!   zig build bench-js -- --gc         # also runs bench/gc/*.js

const std = @import("std");
const builtin = @import("builtin");
const zqjs = @import("zqjs_internal");

const warmups = 2;
const measured = 11;

const limits: zqjs.Limits = .{
    .max_steps = std.math.maxInt(u64),
    .max_heap_bytes = 4 << 30,
};

const Stats = struct {
    steps: u64,
    allocated: u64,
    peak: usize,
    end: usize,
    collections: u64,
    minor: u64,
    major: u64,
};

const Sample = struct {
    compile_ns: u64,
    exec_ns: u64,
    total_ns: u64,
    stats: Stats,
};

fn nowNs(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Timestamp.now(io, .awake).nanoseconds));
}

fn runSampleOnce(gpa: std.mem.Allocator, io: std.Io, source: []const u8) !Sample {
    const t_start = nowNs(io);

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var rt = zqjs.Runtime.init(gpa, limits, &discard.writer);

    var arena = std.heap.ArenaAllocator.init(gpa);

    const c_start = nowNs(io);
    var diag: zqjs.Diagnostic = .{};
    const script = try zqjs.parse(arena.allocator(), source, limits, &diag);
    const res = try zqjs.resolve(arena.allocator(), script, &diag);
    var proto = try zqjs.compile(gpa, &rt.heap, script, res, limits, &diag);
    var failure: zqjs.verify.Failure = .{};
    _ = try zqjs.verify.verify(gpa, &proto, limits, &failure);
    const compile_ns = nowNs(io) - c_start;

    const e_start = nowNs(io);
    var vm = try zqjs.Vm.init(&rt, &proto);
    try vm.run();
    vm.deinit();
    const exec_ns = nowNs(io) - e_start;

    const stats: Stats = .{
        .steps = rt.steps,
        .allocated = rt.heap.allocated,
        .peak = rt.heap.peak,
        .end = rt.heap.bytes,
        .collections = rt.heap.stats.collections,
        .minor = rt.heap.stats.minor,
        .major = rt.heap.stats.collections - rt.heap.stats.minor,
    };

    proto.deinit(gpa);
    arena.deinit();
    rt.deinit();
    const total_ns = nowNs(io) - t_start;

    if (total_ns < compile_ns + exec_ns) return error.TimingInvariantViolated;
    return .{
        .compile_ns = compile_ns,
        .exec_ns = exec_ns,
        .total_ns = total_ns,
        .stats = stats,
    };
}

fn sameStats(a: Stats, b: Stats) bool {
    return a.steps == b.steps and
        a.allocated == b.allocated and
        a.peak == b.peak and
        a.end == b.end and
        a.collections == b.collections;
}

fn summarize(samples: []const u64) struct { median: f64, min: f64, max: f64 } {
    var sorted: [measured]u64 = undefined;
    @memcpy(sorted[0..measured], samples[0..measured]);
    std.mem.sort(u64, &sorted, {}, std.sort.asc(u64));
    return .{
        .median = @as(f64, @floatFromInt(sorted[measured / 2])) / 1e6,
        .min = @as(f64, @floatFromInt(sorted[0])) / 1e6,
        .max = @as(f64, @floatFromInt(sorted[measured - 1])) / 1e6,
    };
}

fn benchDir(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, dir_path: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".js")) {
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    for (names.items) |name| {
        const source = try dir.readFileAlloc(io, name, arena, .limited(1 << 20));

        for (0..warmups) |_| {
            _ = try runSampleOnce(gpa, io, source);
        }

        var compile_ns: [measured]u64 = undefined;
        var exec_ns: [measured]u64 = undefined;
        var total_ns: [measured]u64 = undefined;
        var baseline_stats: ?Stats = null;

        for (0..measured) |i| {
            const s = try runSampleOnce(gpa, io, source);
            if (baseline_stats) |bs| {
                if (!sameStats(bs, s.stats)) return error.NonDeterministic;
            } else {
                baseline_stats = s.stats;
            }
            compile_ns[i] = s.compile_ns;
            exec_ns[i] = s.exec_ns;
            total_ns[i] = s.total_ns;
        }

        const c_sum = summarize(&compile_ns);
        const e_sum = summarize(&exec_ns);
        const t_sum = summarize(&total_ns);
        const st = baseline_stats.?;

        try out.print("{s}/{s}\t{d}\t{d}\t{d}\t{d}\t{d}/{d}\t{d:.3}\t{d:.3}\t{d:.3}\t{d:.3}\t{d:.3}\t{d:.3}\t{d:.3}\t{d:.3}\t{d:.3}\n", .{
            dir_path,
            name,
            st.steps,
            st.allocated,
            st.peak,
            st.end,
            st.minor,
            st.major,
            c_sum.median,
            c_sum.min,
            c_sum.max,
            e_sum.median,
            e_sum.min,
            e_sum.max,
            t_sum.median,
            t_sum.min,
            t_sum.max,
        });
    }
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = std.heap.smp_allocator;
    const arena = init.arena.allocator();

    var include_gc = false;
    var args_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, arena);
    defer args_it.deinit();
    _ = args_it.next();
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--gc")) include_gc = true;
    }

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("# bench-js: zig {s}, {s}-{s} ({s}), {s}, warmups={d}, measured={d}, smp_allocator\n", .{
        builtin.zig_version_string,
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        builtin.cpu.model.name,
        @tagName(builtin.mode),
        warmups,
        measured,
    });
    try out.writeAll("program\tsteps\tallocated\tpeak\tend\tgc(m/M)\tcompile_med_ms\tcompile_min_ms\tcompile_max_ms\texec_med_ms\texec_min_ms\texec_max_ms\ttotal_med_ms\ttotal_min_ms\ttotal_max_ms\n");

    try benchDir(gpa, arena, io, out, "bench/suite/js");
    if (include_gc) {
        try benchDir(gpa, arena, io, out, "bench/gc");
    }
    return 0;
}
