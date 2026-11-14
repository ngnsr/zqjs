//! Shared by the engine tests: run a source on one engine and capture everything it
//! printed, compare the two engines, and report a mismatch with everything needed to
//! debug it (source, both results including exception names and messages, and the VM's
//! bytecode listing).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zqjs = @import("zqjs");

pub const engines = [_]zqjs.Engine{ .treewalk, .vm };

pub const Outcome = struct {
    out: []u8,
    err: []u8,
    code: u8,

    pub fn deinit(o: *Outcome, gpa: Allocator) void {
        gpa.free(o.out);
        gpa.free(o.err);
    }

    /// Limits are engine-defined (DESIGN_DECISIONS D35): outcomes that hit one are not
    /// compared across engines.
    pub fn hitLimit(o: Outcome) bool {
        return std.mem.indexOf(u8, o.out, "LimitExceeded") != null or std.mem.indexOf(u8, o.err, "LimitExceeded") != null;
    }

    pub fn eql(a: Outcome, b: Outcome) bool {
        return a.code == b.code and std.mem.eql(u8, a.out, b.out) and std.mem.eql(u8, a.err, b.err);
    }
};

pub fn run(gpa: Allocator, source: []const u8, limits: zqjs.Limits, engine: zqjs.Engine, mode: zqjs.RunMode) !Outcome {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    const code = try zqjs.runSource(gpa, "t.js", source, limits, .{ .mode = mode, .engine = engine }, &out.writer, &err.writer);
    const out_bytes = try out.toOwnedSlice();
    errdefer gpa.free(out_bytes);
    return .{ .out = out_bytes, .err = try err.toOwnedSlice(), .code = code };
}

/// Runs `source` on both engines in normal mode (so exception messages are compared,
/// not just names). Returns false after printing a report if they disagree.
pub fn enginesAgree(gpa: Allocator, source: []const u8, limits: zqjs.Limits) !bool {
    var tw = try run(gpa, source, limits, .treewalk, .normal);
    defer tw.deinit(gpa);
    var vm = try run(gpa, source, limits, .vm, .normal);
    defer vm.deinit(gpa);
    if (tw.hitLimit() or vm.hitLimit() or tw.eql(vm)) return true;
    std.debug.print("\n== engines disagree\n-- source\n{s}\n", .{source});
    printOutcome("treewalk", tw);
    printOutcome("vm", vm);
    printBytecode(gpa, source);
    return false;
}

pub fn printOutcome(label: []const u8, o: Outcome) void {
    std.debug.print("-- {s} (exit {d})\nstdout:\n{s}stderr:\n{s}", .{ label, o.code, o.out, o.err });
}

/// The `--dump-bytecode` listing of `source`, or why there is none.
pub fn printBytecode(gpa: Allocator, source: []const u8) void {
    var listing: std.Io.Writer.Allocating = .init(gpa);
    defer listing.deinit();
    writeBytecode(gpa, source, &listing.writer) catch |e| {
        std.debug.print("-- vm bytecode: unavailable ({s})\n", .{@errorName(e)});
        return;
    };
    std.debug.print("-- vm bytecode\n{s}", .{listing.written()});
}

fn writeBytecode(gpa: Allocator, source: []const u8, w: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var diag: zqjs.Diagnostic = .{};
    const script = try zqjs.parse(arena.allocator(), source, .{}, &diag);
    const res = try zqjs.resolve(arena.allocator(), script, &diag);
    var heap = zqjs.Heap.init(gpa, .{});
    defer heap.deinit();
    var proto = try zqjs.compile(gpa, &heap, script, res, .{}, &diag);
    defer proto.deinit(gpa);
    try zqjs.disassemble(proto, w);
}
