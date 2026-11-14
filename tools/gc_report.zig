//! GC report (M8.1 baseline): runs bench/*.js and bench/gc/*.js on both engines with a
//! heap observer and prints, per (program, engine):
//!   ms          wall time of the whole run (parse → run)
//!   alloc MB    cumulative bytes charged (`heap.allocated`), and MB/s over the run
//!   gcs         collections, and collections per second
//!   pause ms    mean, p95 and max of the per-collection pauses
//!   >16ms       pauses longer than one 60 fps frame
//!   live MB     largest heap left after a collection (the "old generation" today)
//!   gc ms / %   total time in the collector, and its share of the run
//! and, for bench/gc/*.js, every collection: live objects and bytes after it, its pause.
//! That series is the M8 → M8.1 comparison: pause against live size.
//!
//! The clock lives here, not in the runtime: the heap only calls the observer it is given.
//! Timings are machine-dependent; compare only on the same machine. One run per row (a
//! series of pauses is the measurement; a median of runs would hide the outliers).
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

const Result = struct { ns: u64, allocated: u64 };

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    try out.print("# zqjs GC report: zig {s}, {s}-{s} ({s}), {s}, one run per row\n", .{
        builtin.zig_version_string, @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), builtin.cpu.model.name, @tagName(builtin.mode),
    });
    try out.print("{s:<20} {s:<9} {s:>8} {s:>9} {s:>8} {s:>6} {s:>6} {s:>8} {s:>8} {s:>8} {s:>5} {s:>8} {s:>8} {s:>5}\n", .{
        "program", "engine", "ms", "alloc MB", "MB/s", "gcs", "gc/s", "mean ms", "p95 ms", "max ms", ">16ms", "live MB", "gc ms", "gc %",
    });

    var rec: Recorder = .{ .io = io, .samples = try .initCapacity(gpa, max_samples) };
    defer rec.samples.deinit(gpa);

    var series: std.Io.Writer.Allocating = .init(arena);
    for ([_][]const u8{ "bench", "bench/gc" }) |path| {
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
        defer dir.close(io);
        for (try sortedScripts(arena, io, dir)) |name| {
            const source = try dir.readFileAlloc(io, name, arena, .limited(1 << 20));
            for ([_]zqjs.Engine{ .vm, .treewalk }) |engine| {
                rec.samples.clearRetainingCapacity();
                rec.dropped = false;
                const r = try runOnce(gpa, io, source, engine, &rec);
                if (rec.dropped) return error.TooManyCollections;
                try summary(out, name, engine, r, rec.samples.items, gpa);
                if (std.mem.eql(u8, path, "bench/gc")) try collections(&series.writer, name, engine, rec.samples.items);
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

fn summary(out: *std.Io.Writer, name: []const u8, engine: zqjs.Engine, r: Result, samples: []const Heap.Sample, gpa: std.mem.Allocator) !void {
    const pauses = try gpa.alloc(u64, samples.len);
    defer gpa.free(pauses);
    var gc_ns: u64 = 0;
    var live: usize = 0;
    var long: usize = 0;
    for (samples, pauses) |s, *p| {
        p.* = s.duration_ns;
        gc_ns += s.duration_ns;
        live = @max(live, s.bytes_after);
        if (s.duration_ns > 16_666_667) long += 1;
    }
    std.mem.sort(u64, pauses, {}, std.sort.asc(u64));
    const secs = ns_f(r.ns) / 1e9;
    const n: f64 = @floatFromInt(samples.len);
    const mean = if (samples.len == 0) 0 else ns_f(gc_ns) / n;
    const p95: u64 = if (samples.len == 0) 0 else pauses[(samples.len * 95 - 1) / 100];
    const max: u64 = if (samples.len == 0) 0 else pauses[samples.len - 1];
    try out.print("{s:<20} {s:<9} {d:>8.1} {d:>9.1} {d:>8.0} {d:>6} {d:>6.1} {d:>8.3} {d:>8.3} {d:>8.3} {d:>5} {d:>8.1} {d:>8.1} {d:>5.1}\n", .{
        name,                   @tagName(engine),
        ns_f(r.ns) / 1e6,       mb(r.allocated),
        mb(r.allocated) / secs, samples.len,
        n / secs,               mean / 1e6,
        ns_f(p95) / 1e6,        ns_f(max) / 1e6,
        long,                   mb(live),
        ns_f(gc_ns) / 1e6,      100 * ns_f(gc_ns) / ns_f(r.ns),
    });
}

fn collections(out: *std.Io.Writer, name: []const u8, engine: zqjs.Engine, samples: []const Heap.Sample) !void {
    try out.print("\n# {s} {s}: every collection\n{s:>4} {s:>10} {s:>10} {s:>10} {s:>10} {s:>9}\n", .{ name, @tagName(engine), "#", "at ms", "live objs", "freed objs", "live MB", "pause ms" });
    const t0 = if (samples.len == 0) 0 else samples[0].start_ns;
    for (samples, 1..) |s, i| {
        try out.print("{d:>4} {d:>10.1} {d:>10} {d:>10} {d:>10.1} {d:>9.3}\n", .{ i, ns_f(s.start_ns - t0) / 1e6, s.marked, s.swept, mb(s.bytes_after), ns_f(s.duration_ns) / 1e6 });
    }
}

fn ns_f(ns: u64) f64 {
    return @floatFromInt(ns);
}

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1 << 20);
}

fn runOnce(gpa: std.mem.Allocator, io: std.Io, source: []const u8, engine: zqjs.Engine, rec: *Recorder) !Result {
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
    return .{ .ns = @intCast(ns), .allocated = rt.heap.allocated };
}
