//! GC report (M8.1): runs bench/*.js and bench/gc/*.js on both engines, `runs` times
//! each, with a heap observer. Per (program, engine) one line of run totals, then one line
//! per collection kind (minor, major; M8 only has major):
//!   ms, alloc MB, MB/s   wall time of a run (parse → run) and allocation volume and rate
//!   live MB              largest heap left after a collection
//!   gc %                 share of the run spent collecting
//!   gcs                  collections of that kind in one run (identical across runs)
//!   p50, p95, max        pause percentiles of one run, in ms: the median over the runs,
//!                        and for max also its spread over the runs [min-max]
//!   rem p95              minor only: p95 of the remembered-set scan part of the pause
//!   buckets              every pause of every run, counted by length:
//!                        <0.1 ms, 0.1-1, 1-4, 4-16, >16 (a 60 fps frame)
//! Then, for bench/gc/*.js, every collection of the first run (pause against live size),
//! and one timed scan of the largest array's children, reading each child's header: what
//! a per-object remembered set would pay per minor collection once that array is remembered.
//!
//! Medians of several runs, with the spread shown: one run's max pause is noise (24 ms in
//! one run and 41 ms in the next, for game_100k under M8). Steps aren't counted here, but
//! allocation and the collection counts must be identical across runs, or the run fails.
//! The clock lives here, not in the runtime: the heap only calls the observer it is given.
//! Timings are machine-dependent; compare only on the same machine and build mode.
//!
//!   zig build gc-report              (always ReleaseFast)
//!   zig build gc-report > bench/gc/baseline-m8.txt

const std = @import("std");
const builtin = @import("builtin");
const zqjs = @import("zqjs");
const Heap = zqjs.heap.Heap;

const limits: zqjs.Limits = .{
    .max_steps = std.math.maxInt(u64),
    .max_heap_bytes = 4 << 30,
};

const max_samples = 1 << 16;

const Recorder = struct {
    io: std.Io,
    samples: std.ArrayList(Heap.Sample),
    dropped: bool = false,

    fn clock(ctx: *anyopaque) u64 {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        return @intCast(std.Io.Timestamp.now(r.io, .awake).nanoseconds);
    }

    fn record(ctx: *anyopaque, sample: Heap.Sample) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        // No allocation inside a collection (D7): capacity is reserved up front.
        r.samples.appendBounded(sample) catch {
            r.dropped = true;
        };
    }
};

const Result = struct { ns: u64, allocated: u64, live: usize, scan: Scan = .{} };

/// One child scan of the largest array left at the end of a run (median of `scan_runs`).
const Scan = struct { elements: usize = 0, ns: u64 = 0 };
const scan_runs = 21;
const runs = 5;

const Kind = @FieldType(Heap.Sample, "kind");
const bucket_limits_ns = [_]u64{ 100_000, 1_000_000, 4_000_000, 16_666_667 };

/// One run's pauses of one kind.
const PerRun = struct { count: usize = 0, gc_ns: u64 = 0, p50: u64 = 0, p95: u64 = 0, max: u64 = 0, rem_p95: u64 = 0 };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("# zqjs GC report: zig {s}, {s}-{s} ({s}), {s}, {d} runs per row (medians; max also [min-max])\n", .{
        builtin.zig_version_string, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), builtin.cpu.model.name, @tagName(builtin.mode), runs,
    });
    try out.print("{s:<22} {s:<8} {s:>7} {s:>8} {s:>6} {s:>7} {s:>5} | {s:<5} {s:>5} {s:>7} {s:>7} {s:>7} {s:>15} {s:>7} | {s:>5} {s:>5} {s:>5} {s:>5} {s:>5}\n", .{
        "program", "engine", "ms", "alloc MB", "MB/s", "live MB", "gc %", "kind", "gcs", "p50", "p95", "max", "max spread", "rem p95", "<0.1", "<1", "<4", "<16", ">16",
    });

    var rec: Recorder = .{ .io = io, .samples = try .initCapacity(gpa, max_samples) };
    defer rec.samples.deinit(gpa);

    var series: std.Io.Writer.Allocating = .init(arena);
    for ([_][]const u8{ "bench", "bench/gc" }) |path| {
        const game = std.mem.eql(u8, path, "bench/gc");
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        for (try sortedScripts(arena, io, dir)) |name| {
            const source = try dir.readFileAlloc(io, name, arena, .limited(1 << 20));
            for ([_]zqjs.Engine{ .vm, .treewalk }) |engine| {
                var results: [runs]Result = undefined;
                var samples: [runs][]Heap.Sample = undefined;
                for (&results, &samples, 0..) |*r, *ss, i| {
                    rec.samples.clearRetainingCapacity();
                    rec.dropped = false;
                    r.* = try runOnce(gpa, io, source, engine, &rec, game and i == 0);
                    if (rec.dropped) return error.TooManyCollections;
                    ss.* = try arena.dupe(Heap.Sample, rec.samples.items);
                    if (r.allocated != results[0].allocated or ss.len != samples[0].len) return error.NonDeterministic;
                }
                try summary(out, gpa, name, engine, &results, &samples);
                if (game) {
                    try collections(&series.writer, name, engine, samples[0]);
                    try series.writer.print("largest array: {d} elements, one child scan {d:.3} ms\n", .{ results[0].scan.elements, ns_f(results[0].scan.ns) / 1e6 });
                }
            }
        }
    }
    try out.writeAll(series.written());
    return 0;
}

fn sortedScripts(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".js")) try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return names.items;
}

fn summary(out: *std.Io.Writer, gpa: std.mem.Allocator, name: []const u8, engine: zqjs.Engine, results: *const [runs]Result, samples: *const [runs][]Heap.Sample) !void {
    var ns: [runs]u64 = undefined;
    var gc_pct: [runs]u64 = undefined; // in 0.1% units, so the median stays an integer
    var live: usize = 0;
    for (results, samples, &ns, &gc_pct) |r, ss, *n, *g| {
        n.* = r.ns;
        var gc_ns: u64 = 0;
        for (ss) |x| gc_ns += x.duration_ns;
        g.* = gc_ns * 1000 / @max(r.ns, 1);
        live = @max(live, r.live);
    }
    const ms = ns_f(median(&ns)) / 1e6;
    const alloc = mb(results[0].allocated);
    try out.print("{s:<22} {s:<8} {d:>7.1} {d:>8.1} {d:>6.0} {d:>7.1} {d:>5.1} |", .{ name, @tagName(engine), ms, alloc, alloc / (ms / 1e3), mb(live), ns_f(median(&gc_pct)) / 10 });
    var first = true;
    for ([_]Kind{ .minor, .major }) |kind| {
        var per: [runs]PerRun = undefined;
        var buckets: [bucket_limits_ns.len + 1]usize = @splat(0);
        for (samples, &per) |ss, *p| p.* = try perRun(gpa, ss, kind, &buckets);
        if (per[0].count == 0) continue;
        if (!first) try out.print("{s:<22} {s:<8} {s:>7} {s:>8} {s:>6} {s:>7} {s:>5} |", .{ "", "", "", "", "", "", "" });
        first = false;
        var p50: [runs]u64 = undefined;
        var p95: [runs]u64 = undefined;
        var max: [runs]u64 = undefined;
        var rem: [runs]u64 = undefined;
        for (per, &p50, &p95, &max, &rem) |p, *a, *b, *c, *d| {
            a.* = p.p50;
            b.* = p.p95;
            c.* = p.max;
            d.* = p.rem_p95;
        }
        var spread: [32]u8 = undefined;
        const lo = std.mem.min(u64, &max);
        const hi = std.mem.max(u64, &max);
        const spread_text = try std.fmt.bufPrint(&spread, "[{d:.2}-{d:.2}]", .{ ns_f(lo) / 1e6, ns_f(hi) / 1e6 });
        try out.print(" {s:<5} {d:>5} {d:>7.3} {d:>7.3} {d:>7.3} {s:>15} {d:>7.3} |", .{ @tagName(kind), per[0].count, ns_f(median(&p50)) / 1e6, ns_f(median(&p95)) / 1e6, ns_f(median(&max)) / 1e6, spread_text, ns_f(median(&rem)) / 1e6 });
        for (buckets) |b| try out.print(" {d:>5}", .{b});
        try out.writeAll("\n");
    }
    if (first) try out.writeAll(" none\n");
}

/// The pauses of one kind in one run; adds every pause to `buckets`.
fn perRun(gpa: std.mem.Allocator, samples: []const Heap.Sample, kind: Kind, buckets: []usize) !PerRun {
    var pauses: std.ArrayList(u64) = .empty;
    defer pauses.deinit(gpa);
    var rems: std.ArrayList(u64) = .empty;
    defer rems.deinit(gpa);
    var p: PerRun = .{};
    for (samples) |s| {
        if (s.kind != kind) continue;
        try pauses.append(gpa, s.duration_ns);
        try rems.append(gpa, s.remembered_ns);
        p.gc_ns += s.duration_ns;
        var b: usize = 0;
        while (b < bucket_limits_ns.len and s.duration_ns >= bucket_limits_ns[b]) b += 1;
        buckets[b] += 1;
    }
    p.count = pauses.items.len;
    if (p.count == 0) return p;
    std.mem.sort(u64, pauses.items, {}, std.sort.asc(u64));
    std.mem.sort(u64, rems.items, {}, std.sort.asc(u64));
    p.p50 = pauses.items[(p.count - 1) / 2];
    p.p95 = pauses.items[(p.count * 95 - 1) / 100];
    p.max = pauses.items[p.count - 1];
    p.rem_p95 = rems.items[(p.count * 95 - 1) / 100];
    return p;
}

fn median(xs: []u64) u64 {
    std.mem.sort(u64, xs, {}, std.sort.asc(u64));
    return xs[xs.len / 2];
}

fn collections(out: *std.Io.Writer, name: []const u8, engine: zqjs.Engine, samples: []const Heap.Sample) !void {
    try out.print("\n# {s} {s}: every collection (first run)\n{s:>4} {s:<5} {s:>10} {s:>10} {s:>10} {s:>10} {s:>9} {s:>9}\n", .{ name, @tagName(engine), "#", "kind", "at ms", "live objs", "freed objs", "live MB", "pause ms", "rem ms" });
    const t0 = if (samples.len == 0) 0 else samples[0].start_ns;
    for (samples, 1..) |s, i| {
        try out.print("{d:>4} {s:<5} {d:>10.1} {d:>10} {d:>10} {d:>10.1} {d:>9.3} {d:>9.3}\n", .{ i, @tagName(s.kind), ns_f(s.start_ns - t0) / 1e6, s.marked, s.swept, mb(s.bytes_after), ns_f(s.duration_ns) / 1e6, ns_f(s.remembered_ns) / 1e6 });
    }
}

fn ns_f(ns: u64) f64 {
    return @floatFromInt(ns);
}

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1 << 20);
}

fn runOnce(gpa: std.mem.Allocator, io: std.Io, source: []const u8, engine: zqjs.Engine, rec: *Recorder, probe: bool) !Result {
    const start = std.Io.Timestamp.now(io, .awake);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var diag: zqjs.Diagnostic = .{};
    const script = try zqjs.parse(arena.allocator(), source, limits, &diag);
    const res = try zqjs.resolve(arena.allocator(), script, &diag);
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var rt = zqjs.Runtime.init(gpa, limits, &discard.writer);
    defer rt.deinit();
    rt.heap.observer = .{ .ctx = rec, .clock = Recorder.clock, .record = Recorder.record };
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
    var live: usize = 0;
    for (rec.samples.items) |x| live = @max(live, x.bytes_after);
    return .{ .ns = @intCast(ns), .allocated = rt.heap.allocated, .live = live, .scan = if (probe) scanLargestArray(io, &rt.heap) else .{} };
}

fn scanLargestArray(io: std.Io, h: *zqjs.heap.Heap) Scan {
    var largest: ?*zqjs.heap.Obj = null;
    var elements: usize = 0;
    var it = h.objects;
    while (it) |obj| : (it = obj.next) {
        if (obj.kind != .object) continue;
        const o: *zqjs.heap.Object = @fieldParentPtr("obj", obj);
        if (o.kind == .array and o.kind.array.items.len > elements) {
            largest = obj;
            elements = o.kind.array.items.len;
        }
    }
    const array = largest orelse return .{};
    const Visit = struct {
        seen: usize = 0,
        fn child(v: *@This(), obj: *zqjs.heap.Obj) void {
            if (!obj.marked) v.seen += 1; // stands in for `if (obj.old) return`
        }
    };
    var times: [scan_runs]u64 = undefined;
    var v: Visit = .{};
    for (&times) |*t| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        zqjs.heap.forEachChild(array, &v, Visit.child);
        t.* = @intCast(t0.durationTo(std.Io.Timestamp.now(io, .awake)).toNanoseconds());
    }
    std.mem.doNotOptimizeAway(v.seen);
    std.mem.sort(u64, &times, {}, std.sort.asc(u64));
    return .{ .elements = elements, .ns = times[scan_runs / 2] };
}
