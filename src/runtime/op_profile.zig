//! Opt-in bytecode profile (`zig build -Dop-profile`), for finding the next optimisation:
//! executed opcodes, opcode -> next-opcode edges, calls into each native, and property-cache
//! misses per (function, pc, property). `Runtime.deinit` prints it to stderr as tab-separated
//! lines; `tools/op_graph.py` ranks the heaviest edges across workloads. Without the build
//! option `enabled` is false and every hook compiles away. The profile lives in a module
//! variable, not in `Runtime`: even a zero-size field reorders `Runtime`'s fields, and the
//! VM is sensitive to that layout. So it is one profile per process, for one runtime at a
//! time. Counts only, no timing: pair it with a sampling profiler (PERF_PLAN.md §5).

const std = @import("std");

pub const enabled: bool = @import("build_options").op_profile;

/// The profile being filled; created by the first VM, printed and freed by `finish`.
pub var active: ?*Profile = null;

pub fn ensure(gpa: std.mem.Allocator, op_names: []const []const u8) void {
    if (active != null) return;
    const p = gpa.create(Profile) catch return; // best effort: no profile, no failure
    p.* = .{ .gpa = gpa, .op_names = op_names };
    active = p;
}

/// Prints the profile to stderr and frees it (called by `Runtime.deinit`).
pub fn finish() void {
    const p = active orelse return;
    active = null;
    var buf: [4096]u8 = undefined;
    const stderr = std.debug.lockStderr(&buf);
    defer std.debug.unlockStderr();
    p.dump(&stderr.file_writer.interface) catch {};
    p.gpa.destroy(p);
}

pub const Profile = struct {
    gpa: std.mem.Allocator,
    /// Opcode names by byte, supplied by the VM (the runtime doesn't import the bytecode).
    op_names: []const []const u8,
    ops: [256]u64 = @splat(0),
    pairs: [256 * 256]u64 = @splat(0),
    prev: u8 = 0,
    natives: [1024]NativeEntry = @splat(.{}),
    sites: [8192]Site = @splat(.{}),

    const NativeEntry = struct { key: usize = 0, name: []const u8 = "", count: u64 = 0 };
    /// Names are copied on first sight: the dump runs after the programs are freed.
    const Site = struct {
        key: usize = 0,
        pc: u32 = 0,
        set: bool = false,
        count: u64 = 0,
        func: [40]u8 = undefined,
        func_len: u8 = 0,
        prop: [32]u8 = undefined,
        prop_len: u8 = 0,
    };

    pub fn op(p: *Profile, byte: u8) void {
        p.ops[byte] += 1;
        p.pairs[@as(usize, p.prev) * 256 + byte] += 1;
        p.prev = byte;
    }

    /// `name` must outlive the profile (natives' names are static).
    pub fn native(p: *Profile, id: usize, name: []const u8) void {
        var i = (id >> 4) & (p.natives.len - 1);
        for (0..p.natives.len) |_| {
            const e = &p.natives[i];
            if (e.key == id or e.key == 0) {
                if (e.key == 0) e.* = .{ .key = id, .name = name };
                e.count += 1;
                return;
            }
            i = (i + 1) & (p.natives.len - 1);
        }
    }

    /// A property-cache miss at `pc` of the function identified by `func_id`.
    pub fn miss(p: *Profile, func_id: usize, func: []const u8, pc: u32, prop: []const u16, set: bool) void {
        const key = ((func_id >> 4) ^ (@as(usize, pc) *% 2654435761)) | 1;
        var i = (key ^ @intFromBool(set)) & (p.sites.len - 1);
        for (0..p.sites.len) |_| {
            const s = &p.sites[i];
            if (s.key == 0) {
                s.* = .{ .key = key, .pc = pc, .set = set };
                s.func_len = @intCast(@min(func.len, s.func.len));
                @memcpy(s.func[0..s.func_len], func[0..s.func_len]);
                s.prop_len = @intCast(@min(prop.len, s.prop.len));
                for (s.prop[0..s.prop_len], prop[0..s.prop_len]) |*d, u| d.* = if (u < 128) @intCast(u) else '?';
            }
            if (s.key == key and s.pc == pc and s.set == set) {
                s.count += 1;
                return;
            }
            i = (i + 1) & (p.sites.len - 1);
        }
    }

    pub fn dump(p: *const Profile, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("OPPROFILE\t1\n");
        for (p.ops, 0..) |c, i| {
            if (c != 0) try w.print("OP\t{s}\t{d}\n", .{ p.opName(i), c });
        }
        for (p.pairs, 0..) |c, i| {
            if (c != 0) try w.print("PAIR\t{s}\t{s}\t{d}\n", .{ p.opName(i / 256), p.opName(i % 256), c });
        }
        for (p.natives) |e| {
            if (e.count != 0) try w.print("NAT\t{s}\t{d}\n", .{ e.name, e.count });
        }
        for (p.sites) |s| {
            if (s.count == 0) continue;
            const func = if (s.func_len > 0) s.func[0..s.func_len] else "<top>";
            try w.print("MISS\t{s}\t{s}\t{d}\t{s}\t{d}\n", .{ if (s.set) "set" else "get", func, s.pc, s.prop[0..s.prop_len], s.count });
        }
        try w.flush();
    }

    fn opName(p: *const Profile, byte: usize) []const u8 {
        return if (byte < p.op_names.len) p.op_names[byte] else "?";
    }
};

test "op profile counts ops, edges, natives and miss sites" {
    const gpa = std.testing.allocator;
    const p = try gpa.create(Profile);
    defer gpa.destroy(p);
    p.* = .{ .gpa = gpa, .op_names = &.{ "a", "b" } };
    p.op(0);
    p.op(1);
    p.op(1);
    try std.testing.expectEqual(@as(u64, 2), p.ops[1]);
    try std.testing.expectEqual(@as(u64, 1), p.pairs[0 * 256 + 1]);
    try std.testing.expectEqual(@as(u64, 1), p.pairs[1 * 256 + 1]);
    p.native(0x1000, "imul");
    p.native(0x1000, "imul");
    p.native(0x2000, "push");
    const units = [_]u16{ 'g', 'e', 't' };
    p.miss(0x40, "tick", 7, &units, false);
    p.miss(0x40, "tick", 7, &units, false);
    p.miss(0x40, "tick", 7, &units, true);
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try p.dump(&w);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "OP\tb\t2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "PAIR\ta\tb\t1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "NAT\timul\t2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "MISS\tget\ttick\t7\tget\t2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "MISS\tset\ttick\t7\tget\t1\n") != null);
}
