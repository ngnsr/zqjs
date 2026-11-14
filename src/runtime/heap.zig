//! The runtime heap (DESIGN_DECISIONS D7): the only code that allocates runtime values.
//!
//! M3 has no garbage collector. Every object is linked into `objects` and lives until
//! `deinit`. The list is what the M8 collector will sweep, so only marking is missing.
//!
//! Accounting (revision for M3): every allocation is charged
//!     @sizeOf(header struct) + payload bytes + `per_allocation_overhead`
//! *before* it is made, with overflow-checked arithmetic, and the charge is refused if
//! it would exceed `max_heap_bytes`. The overhead constant stands in for allocator
//! bookkeeping we can't observe through `std.mem.Allocator`; charging it per
//! allocation means many tiny allocations can't slip under the limit.

const std = @import("std");
const Allocator = std.mem.Allocator;
const limits_mod = @import("../limits.zig");
const Limits = limits_mod.Limits;
const Limit = limits_mod.Limit;

pub const Error = error{ LimitExceeded, OutOfMemory };

pub const per_allocation_overhead = 16;

pub const Obj = struct {
    kind: Kind,
    next: ?*Obj,

    pub const Kind = enum { string };
};

pub const String = struct {
    obj: Obj,
    /// UTF-16 code units, possibly with lone surrogates. Immutable.
    units: []const u16,
};

/// A part of a string being built: either UTF-16 units or ASCII bytes (numbers,
/// `true`, error messages), widened while copying.
pub const Piece = union(enum) {
    utf16: []const u16,
    ascii: []const u8,

    fn len(p: Piece) usize {
        return switch (p) {
            inline else => |s| s.len,
        };
    }
};

pub const Heap = struct {
    gpa: Allocator,
    max_bytes: usize,
    max_string_length: usize,
    objects: ?*Obj = null,
    /// Accounted bytes currently allocated.
    bytes: usize = 0,
    /// Which limit was hit, when an operation returns error.LimitExceeded.
    limit_hit: ?Limit = null,

    pub fn init(gpa: Allocator, limits: Limits) Heap {
        return .{ .gpa = gpa, .max_bytes = limits.max_heap_bytes, .max_string_length = limits.max_string_length };
    }

    pub fn deinit(h: *Heap) void {
        var it = h.objects;
        while (it) |obj| {
            it = obj.next;
            h.destroy(obj);
        }
        h.* = undefined;
    }

    /// The current newest object, for `rollback`.
    pub fn mark(h: *const Heap) ?*Obj {
        return h.objects;
    }

    /// Frees every object allocated since `m` (a value of `mark()`), newest first, and
    /// gives their charge back to the accounting. Used when a compilation fails: the strings it created are
    /// unreachable, so they are freed at once instead of lingering until `deinit`.
    /// Only valid if nothing allocated since `m` is referenced anywhere.
    pub fn rollback(h: *Heap, m: ?*Obj) void {
        while (h.objects != m) {
            const obj = h.objects.?; // `m` must be in the list
            h.objects = obj.next;
            h.destroy(obj);
        }
    }

    fn destroy(h: *Heap, obj: *Obj) void {
        switch (obj.kind) {
            .string => {
                const s: *String = @fieldParentPtr("obj", obj);
                h.bytes -= @sizeOf(String) + s.units.len * @sizeOf(u16) + 2 * per_allocation_overhead;
                h.gpa.free(s.units);
                h.gpa.destroy(s);
            },
        }
    }

    /// A new string made of the concatenation of `pieces`.
    pub fn newString(h: *Heap, pieces: []const Piece) Error!*String {
        var len: usize = 0;
        for (pieces) |p| len = std.math.add(usize, len, p.len()) catch return h.exceeded(.string_length);
        if (len > h.max_string_length) return h.exceeded(.string_length);

        const payload = std.math.mul(usize, len, @sizeOf(u16)) catch return h.exceeded(.heap_bytes);
        const charge = try h.reserve(@sizeOf(String), payload, 2);
        errdefer h.bytes -= charge;

        const units = try h.gpa.alloc(u16, len);
        errdefer h.gpa.free(units);
        var i: usize = 0;
        for (pieces) |p| switch (p) {
            .utf16 => |s| {
                @memcpy(units[i..][0..s.len], s);
                i += s.len;
            },
            .ascii => |s| for (s) |c| {
                units[i] = c;
                i += 1;
            },
        };

        const s = try h.gpa.create(String);
        s.* = .{ .obj = .{ .kind = .string, .next = h.objects }, .units = units };
        h.objects = &s.obj;
        return s;
    }

    pub fn ascii(h: *Heap, text: []const u8) Error!*String {
        return h.newString(&.{.{ .ascii = text }});
    }

    /// Charges `header + payload + allocations * overhead`, or fails without charging.
    fn reserve(h: *Heap, header: usize, payload: usize, allocations: usize) Error!usize {
        const overhead = std.math.mul(usize, allocations, per_allocation_overhead) catch return h.exceeded(.heap_bytes);
        const size = std.math.add(usize, header, payload) catch return h.exceeded(.heap_bytes);
        const charge = std.math.add(usize, size, overhead) catch return h.exceeded(.heap_bytes);
        const total = std.math.add(usize, h.bytes, charge) catch return h.exceeded(.heap_bytes);
        if (total > h.max_bytes) return h.exceeded(.heap_bytes);
        h.bytes = total;
        return charge;
    }

    fn exceeded(h: *Heap, which: Limit) Error {
        h.limit_hit = which;
        return error.LimitExceeded;
    }
};

const testing = std.testing;

test "strings are built from pieces and freed by deinit" {
    var h = Heap.init(testing.allocator, .{});
    defer h.deinit();
    const s = try h.newString(&.{ .{ .ascii = "ab" }, .{ .utf16 = &.{ 0xD83D, 0xDE00 } } });
    try testing.expectEqualSlices(u16, &.{ 'a', 'b', 0xD83D, 0xDE00 }, s.units);
    try testing.expectEqual(@as(usize, @sizeOf(String) + 8 + 2 * per_allocation_overhead), h.bytes);
}

test "heap limit counts headers, payload and per-allocation overhead" {
    const one = @sizeOf(String) + 2 * 2 + 2 * per_allocation_overhead; // a 2-unit string
    var h = Heap.init(testing.allocator, .{ .max_heap_bytes = 2 * one });
    defer h.deinit();
    _ = try h.ascii("ab");
    _ = try h.ascii("cd");
    try testing.expectError(error.LimitExceeded, h.ascii("ef"));
    try testing.expectEqual(Limit.heap_bytes, h.limit_hit.?);
    try testing.expectEqual(2 * one, h.bytes); // the refused charge was not kept
    // Empty strings still cost header + overhead, so a loop of them can't evade the limit.
    try testing.expectError(error.LimitExceeded, h.ascii(""));
}

test "string length limit and overflow-safe size arithmetic" {
    var h = Heap.init(testing.allocator, .{ .max_string_length = 3 });
    defer h.deinit();
    try testing.expectError(error.LimitExceeded, h.ascii("abcd"));
    try testing.expectEqual(Limit.string_length, h.limit_hit.?);
    // Lengths whose sum overflows usize are reported as a limit, never wrap around.
    const huge: []const u8 = @as([*]const u8, @ptrFromInt(0x1000))[0 .. std.math.maxInt(usize) / 2 + 1];
    try testing.expectError(error.LimitExceeded, h.newString(&.{ .{ .ascii = huge }, .{ .ascii = huge } }));
}

test "rollback frees exactly the objects allocated since the mark" {
    var h = Heap.init(testing.allocator, .{});
    defer h.deinit();
    const keep = try h.ascii("keep");
    const before = h.bytes;
    const m = h.mark();
    _ = try h.ascii("a");
    _ = try h.ascii("bcd");
    h.rollback(m);
    try testing.expectEqual(before, h.bytes);
    try testing.expectEqual(&keep.obj, h.objects.?);
    try testing.expectEqual(@as(?*Obj, null), h.objects.?.next);
}

test "allocation failure leaves the accounting unchanged" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var h = Heap.init(failing.allocator(), .{});
    defer h.deinit();
    try testing.expectError(error.OutOfMemory, h.ascii("x"));
    try testing.expectEqual(@as(usize, 0), h.bytes);
}
