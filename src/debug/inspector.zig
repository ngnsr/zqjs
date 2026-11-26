//! Read-only heap browser and bounded, cycle-safe value inspector for the M11 debugger.
//! Never mutates the heap, never invokes JS getters or Proxy traps, and enforces
//! explicit depth, item, and string length caps so inspection cannot diverge on cycles
//! or huge graphs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const limits_mod = @import("../limits.zig");
const Value = @import("../runtime/value.zig").Value;
const Native = @import("../runtime/value.zig").Native;
const heap = @import("../runtime/heap.zig");
const Heap = heap.Heap;
const Obj = heap.Obj;
const Object = heap.Object;
const Closure = heap.Closure;
const Cell = heap.Cell;
const Env = heap.Env;
const String = heap.String;
const Symbol = heap.Symbol;
const BigInt = heap.BigInt;
const Coroutine = heap.Coroutine;
const PropKey = heap.PropKey;
const ops = @import("../runtime/ops.zig");
const date = @import("../runtime/date.zig");
const bc = @import("../bytecode/bytecode.zig");
const Proto = bc.Proto;
const ast = @import("../frontend/ast.zig");

/// Hard upper bound on inspection depth derived from `Limits.max_nesting_depth`.
pub const max_hard_depth: u16 = (limits_mod.Limits{}).max_nesting_depth;

/// Controls how deeply and broadly `inspectValue` / `formatValue` traverses heap graphs.
pub const InspectOptions = struct {
    max_depth: u16 = 4,
    max_items: usize = 64,
    max_string_len: usize = 128,
    include_non_enumerable: bool = false,

    pub fn effectiveDepth(self: InspectOptions) u16 {
        return @min(self.max_depth, max_hard_depth);
    }
};

/// Live object counts broken down by `heap.Obj.Kind`.
pub const KindCounts = struct {
    string: usize = 0,
    symbol: usize = 0,
    bigint: usize = 0,
    cell: usize = 0,
    closure: usize = 0,
    env: usize = 0,
    object: usize = 0,
    coroutine: usize = 0,

    pub fn total(self: KindCounts) usize {
        return self.string + self.symbol + self.bigint + self.cell +
            self.closure + self.env + self.object + self.coroutine;
    }

    fn inc(self: *KindCounts, kind: Obj.Kind) void {
        switch (kind) {
            .string => self.string += 1,
            .symbol => self.symbol += 1,
            .bigint => self.bigint += 1,
            .cell => self.cell += 1,
            .closure => self.closure += 1,
            .env => self.env += 1,
            .object => self.object += 1,
            .coroutine => self.coroutine += 1,
            .dead => {},
        }
    }
};

/// Snapshot of generational heap memory, live object counts, atoms, and GC counters.
pub const HeapStats = struct {
    /// Total accounted heap bytes (`nursery_bytes + old_bytes + buffer_bytes`).
    total_bytes: usize,
    /// Fixed-charge bytes currently in the young generation (nursery).
    nursery_bytes: usize,
    /// Fixed-charge bytes currently in the old generation.
    old_bytes: usize,
    /// Growable internal buffer bytes accounted via `Heap.allocator()`.
    buffer_bytes: usize,
    peak_bytes: usize,
    allocated_bytes: u64,
    nursery_limit: usize,
    max_bytes: usize,
    young_objects: usize,
    old_objects: usize,
    live_objects: usize,
    counts_by_kind: KindCounts,
    atom_count: usize,
    minor_gc_count: u64,
    major_gc_count: u64,
    total_gc_count: u64,
    bytes_freed: u64,
    marked_total: u64,
    swept_total: u64,
};

/// Collects a read-only snapshot of `h` without allocating.
pub fn inspectHeap(h: *const Heap) HeapStats {
    var counts: KindCounts = .{};
    var nursery_bytes: usize = 0;
    var old_bytes: usize = 0;
    var young_objects: usize = 0;
    var old_objects: usize = 0;

    var it = h.young;
    while (it) |obj| : (it = obj.next) {
        young_objects += 1;
        nursery_bytes += fixedCharge(obj);
        counts.inc(obj.kind);
    }

    it = h.old;
    while (it) |obj| : (it = obj.next) {
        old_objects += 1;
        old_bytes += fixedCharge(obj);
        counts.inc(obj.kind);
    }

    return .{
        .total_bytes = h.bytes,
        .nursery_bytes = nursery_bytes,
        .old_bytes = old_bytes,
        .buffer_bytes = h.buffer_bytes,
        .peak_bytes = h.peak,
        .allocated_bytes = h.allocated,
        .nursery_limit = h.nursery_bytes,
        .max_bytes = h.max_bytes,
        .young_objects = young_objects,
        .old_objects = old_objects,
        .live_objects = young_objects + old_objects,
        .counts_by_kind = counts,
        .atom_count = h.atoms.count(),
        .minor_gc_count = h.stats.minor,
        .major_gc_count = h.stats.collections - h.stats.minor,
        .total_gc_count = h.stats.collections,
        .bytes_freed = h.stats.bytes_freed,
        .marked_total = h.stats.marked,
        .swept_total = h.stats.swept,
    };
}

/// Formats `HeapStats` as a compact multi-line summary.
pub fn formatHeapStats(stats: HeapStats, w: *Writer) Writer.Error!void {
    try w.print(
        "heap: {d} bytes (nursery={d}, old={d}, buffers={d}, peak={d}, limit={d})\n" ++
            "objects: {d} live (young={d}, old={d}) [object={d}, string={d}, closure={d}, cell={d}, symbol={d}, bigint={d}, env={d}, coroutine={d}]\n" ++
            "atoms: {d}, gc: {d} total (minor={d}, major={d}, freed={d} bytes)\n",
        .{
            stats.total_bytes,
            stats.nursery_bytes,
            stats.old_bytes,
            stats.buffer_bytes,
            stats.peak_bytes,
            stats.max_bytes,
            stats.live_objects,
            stats.young_objects,
            stats.old_objects,
            stats.counts_by_kind.object,
            stats.counts_by_kind.string,
            stats.counts_by_kind.closure,
            stats.counts_by_kind.cell,
            stats.counts_by_kind.symbol,
            stats.counts_by_kind.bigint,
            stats.counts_by_kind.env,
            stats.counts_by_kind.coroutine,
            stats.atom_count,
            stats.total_gc_count,
            stats.minor_gc_count,
            stats.major_gc_count,
            stats.bytes_freed,
        },
    );
}

/// Mirrors `Heap.fixedCharge` so nursery/old byte breakdowns match heap accounting.
fn fixedCharge(obj: *const Obj) usize {
    const ovh = heap.per_allocation_overhead;
    return switch (obj.kind) {
        .string => @sizeOf(String) + @as(*const String, @alignCast(@fieldParentPtr("obj", obj))).units.len * @sizeOf(u16) + 2 * ovh,
        .symbol => @sizeOf(Symbol) + ovh,
        .bigint => @sizeOf(BigInt) + ovh,
        .cell => @sizeOf(Cell) + ovh,
        .closure => switch (@as(*const Closure, @alignCast(@fieldParentPtr("obj", obj))).impl) {
            .vm => |v| @sizeOf(Closure) + v.captures.len * @sizeOf(*Cell) + 2 * ovh,
            .tree, .promise_cap, .native_closure, .bound => @sizeOf(Closure) + 2 * ovh,
        },
        .env => @sizeOf(Env) + @as(*const Env, @alignCast(@fieldParentPtr("obj", obj))).values.len * @sizeOf(?Value) + 2 * ovh,
        .object => @sizeOf(Object) + ovh,
        .coroutine => @sizeOf(Coroutine) + ovh,
        .dead => 0,
    };
}

pub const ObjectKind = enum {
    ordinary,
    array,
    map,
    set,
    iterator,
    promise,
    regexp,
    generator,
    module_namespace,
    array_buffer,
    typed_array,
    data_view,
    weak_map,
    weak_set,
    proxy,
    date,
    primitive_wrapper,
};

pub const ClosureKind = enum {
    vm,
    tree,
    bound,
    native_closure,
    promise_cap,
};

pub const PropEntry = struct {
    key: []u8,
    enumerable: bool,
    is_accessor: bool,
    /// `null` for accessors (never invoked by the inspector).
    value: ?ValueInspection,

    pub fn deinit(self: *PropEntry, alloc: Allocator) void {
        alloc.free(self.key);
        if (self.value) |*v| v.deinit(alloc);
    }
};

pub const MapEntry = struct {
    key: ValueInspection,
    value: ValueInspection,

    pub fn deinit(self: *MapEntry, alloc: Allocator) void {
        self.key.deinit(alloc);
        self.value.deinit(alloc);
    }
};

pub const CaptureEntry = struct {
    index: usize,
    is_tdz: bool,
    value: ?ValueInspection,

    pub fn deinit(self: *CaptureEntry, alloc: Allocator) void {
        if (self.value) |*v| v.deinit(alloc);
    }
};

pub const ClosureInfo = struct {
    name: []u8,
    kind: ClosureKind,
    param_count: u32,
    capture_count: usize,
    captures: []CaptureEntry,
    truncated_captures: bool,
    ptr_id: usize,

    pub fn deinit(self: *ClosureInfo, alloc: Allocator) void {
        alloc.free(self.name);
        for (self.captures) |*c| c.deinit(alloc);
        alloc.free(self.captures);
    }
};

pub const ObjectInfo = struct {
    kind: ObjectKind,
    ptr_id: usize,
    own_prop_count: usize,
    properties: []PropEntry,
    truncated_props: bool,
    array_len: usize,
    elements: []ValueInspection,
    truncated_elements: bool,
    map_len: usize,
    map_entries: []MapEntry,
    truncated_map: bool,
    set_len: usize,
    set_entries: []ValueInspection,
    truncated_set: bool,

    pub fn deinit(self: *ObjectInfo, alloc: Allocator) void {
        for (self.properties) |*p| p.deinit(alloc);
        alloc.free(self.properties);
        for (self.elements) |*e| e.deinit(alloc);
        alloc.free(self.elements);
        for (self.map_entries) |*m| m.deinit(alloc);
        alloc.free(self.map_entries);
        for (self.set_entries) |*s| s.deinit(alloc);
        alloc.free(self.set_entries);
    }
};

/// Owned, bounded, cycle-safe inspection tree for any JS `Value`.
pub const ValueInspection = union(enum) {
    undefined,
    null,
    boolean: bool,
    number: f64,
    bigint: []u8,
    string: struct {
        text: []u8,
        utf16_len: usize,
        truncated: bool,
    },
    symbol: struct {
        description: ?[]u8,
        is_global: bool,
    },
    native: struct {
        name: []const u8,
    },
    closure: ClosureInfo,
    object: ObjectInfo,
    circular: usize,
    depth_limit: []const u8,

    pub fn deinit(self: *ValueInspection, alloc: Allocator) void {
        switch (self.*) {
            .bigint => |s| alloc.free(s),
            .string => |s| alloc.free(s.text),
            .symbol => |sym| if (sym.description) |d| alloc.free(d),
            .closure => |*c| c.deinit(alloc),
            .object => |*o| o.deinit(alloc),
            .undefined, .null, .boolean, .number, .native, .circular, .depth_limit => {},
        }
    }
};

/// Builds a bounded, cycle-safe structured `ValueInspection` of `v`.
pub fn inspectValue(alloc: Allocator, v: Value, opts: InspectOptions) Allocator.Error!ValueInspection {
    var active: std.ArrayList(*const Obj) = .empty;
    defer active.deinit(alloc);
    return inspectNode(alloc, v, opts, opts.effectiveDepth(), 0, &active);
}

fn isActive(active: []const *const Obj, target: *const Obj) bool {
    for (active) |p| {
        if (p == target) return true;
    }
    return false;
}

fn inspectNode(
    alloc: Allocator,
    v: Value,
    opts: InspectOptions,
    max_depth: u16,
    depth: u16,
    active: *std.ArrayList(*const Obj),
) Allocator.Error!ValueInspection {
    return switch (v.unpack()) {
        .undefined => .undefined,
        .null => .null,
        .boolean => |b| .{ .boolean = b },
        .number => |n| .{ .number = n },
        .bigint => |b| .{ .bigint = try formatBigIntAlloc(alloc, b) },
        .string => |s| blk: {
            const limit = @min(s.units.len, opts.max_string_len);
            const text = try utf16ToUtf8Alloc(alloc, s.units[0..limit]);
            break :blk .{ .string = .{
                .text = text,
                .utf16_len = s.units.len,
                .truncated = s.units.len > opts.max_string_len,
            } };
        },
        .symbol => |sym| .{ .symbol = .{
            .description = if (sym.description) |d|
                try utf16ToUtf8Alloc(alloc, d.units[0..@min(d.units.len, opts.max_string_len)])
            else
                null,
            .is_global = sym.is_global,
        } },
        .native => |n| .{ .native = .{ .name = n.name } },
        .closure => |c| inspectClosure(alloc, c, opts, max_depth, depth, active),
        .object => |o| inspectObject(alloc, o, opts, max_depth, depth, active),
    };
}

fn inspectClosure(
    alloc: Allocator,
    c: *const Closure,
    opts: InspectOptions,
    max_depth: u16,
    depth: u16,
    active: *std.ArrayList(*const Obj),
) Allocator.Error!ValueInspection {
    if (isActive(active.items, &c.obj)) return .{ .circular = @intFromPtr(c) };
    if (depth > max_depth) return .{ .depth_limit = "[Closure]" };

    try active.append(alloc, &c.obj);
    defer _ = active.pop();

    var kind: ClosureKind = undefined;
    var param_count: u32 = 0;
    var capture_count: usize = 0;
    var name_buf: []u8 = undefined;
    var vm_captures: []const *Cell = &.{};

    switch (c.impl) {
        .vm => |vm_cl| {
            kind = .vm;
            const p: *const Proto = @ptrCast(@alignCast(vm_cl.proto));
            param_count = p.param_count;
            capture_count = vm_cl.captures.len;
            vm_captures = vm_cl.captures;
            const raw = if (p.name.len > 0) p.name else if (p.inferred_name.len > 0) p.inferred_name else "<anonymous>";
            name_buf = try alloc.dupe(u8, raw);
        },
        .tree => |t| {
            kind = .tree;
            const f: *const ast.Function = @ptrCast(@alignCast(t.func));
            const raw: []const u8 = if (f.name) |n| n.name else if (f.inferred_name.len > 0) f.inferred_name else "<anonymous>";
            name_buf = try alloc.dupe(u8, raw);
        },
        .bound => |b| {
            kind = .bound;
            var out: Writer.Allocating = .init(alloc);
            errdefer out.deinit();
            out.writer.writeAll("bound ") catch return error.OutOfMemory;
            ops.writeUtf16(&out.writer, b.name.units) catch return error.OutOfMemory;
            name_buf = try out.toOwnedSlice();
        },
        .native_closure => |nc| {
            kind = .native_closure;
            param_count = nc.length;
            name_buf = try alloc.dupe(u8, "<native>");
        },
        .promise_cap => {
            kind = .promise_cap;
            param_count = 1;
            name_buf = try alloc.dupe(u8, "<promise-capability>");
        },
    }
    errdefer alloc.free(name_buf);

    var captures: std.ArrayList(CaptureEntry) = .empty;
    errdefer {
        for (captures.items) |*cap| cap.deinit(alloc);
        captures.deinit(alloc);
    }

    var truncated_captures = false;
    if (vm_captures.len > 0 and depth < max_depth) {
        const cap_limit = @min(vm_captures.len, opts.max_items);
        truncated_captures = vm_captures.len > cap_limit;
        for (vm_captures[0..cap_limit], 0..) |cell, i| {
            if (cell.value) |cv| {
                const inspected = try inspectNode(alloc, cv, opts, max_depth, depth + 1, active);
                try captures.append(alloc, .{ .index = i, .is_tdz = false, .value = inspected });
            } else {
                try captures.append(alloc, .{ .index = i, .is_tdz = true, .value = null });
            }
        }
    } else if (vm_captures.len > 0) {
        truncated_captures = true;
    }

    return .{ .closure = .{
        .name = name_buf,
        .kind = kind,
        .param_count = param_count,
        .capture_count = capture_count,
        .captures = try captures.toOwnedSlice(alloc),
        .truncated_captures = truncated_captures,
        .ptr_id = @intFromPtr(c),
    } };
}

fn objectKindTag(o: *const Object) ObjectKind {
    return switch (o.kind) {
        .ordinary => .ordinary,
        .array => .array,
        .map => .map,
        .set => .set,
        .iterator => .iterator,
        .promise => .promise,
        .regexp => .regexp,
        .generator => .generator,
        .module_namespace => .module_namespace,
        .array_buffer => .array_buffer,
        .typed_array => .typed_array,
        .data_view => .data_view,
        .weak_map => .weak_map,
        .weak_set => .weak_set,
        .proxy => .proxy,
        .date => .date,
        .primitive_wrapper => .primitive_wrapper,
    };
}

fn depthLimitLabel(kind: ObjectKind) []const u8 {
    return switch (kind) {
        .array => "[Array]",
        .map => "[Map]",
        .set => "[Set]",
        .regexp => "[RegExp]",
        .date => "[Date]",
        .promise => "[Promise]",
        .proxy => "[Proxy]",
        else => "[Object]",
    };
}

fn inspectObject(
    alloc: Allocator,
    o: *const Object,
    opts: InspectOptions,
    max_depth: u16,
    depth: u16,
    active: *std.ArrayList(*const Obj),
) Allocator.Error!ValueInspection {
    const kind = objectKindTag(o);
    if (isActive(active.items, &o.obj)) return .{ .circular = @intFromPtr(o) };
    if (depth >= max_depth) return .{ .depth_limit = depthLimitLabel(kind) };

    try active.append(alloc, &o.obj);
    defer _ = active.pop();

    var props_list: std.ArrayList(PropEntry) = .empty;
    errdefer {
        for (props_list.items) |*p| p.deinit(alloc);
        props_list.deinit(alloc);
    }

    var own_prop_count: usize = 0;
    var truncated_props = false;
    var prop_it = o.props.iterator();
    while (prop_it.next()) |entry| {
        if (!opts.include_non_enumerable and !entry.value_ptr.enumerable) continue;
        own_prop_count += 1;
        if (props_list.items.len >= opts.max_items) {
            truncated_props = true;
            continue;
        }
        const key_str = try formatPropKeyAlloc(alloc, entry.key_ptr.*, opts.max_string_len);
        errdefer alloc.free(key_str);
        const val_node: ?ValueInspection = if (entry.value_ptr.is_accessor)
            null
        else
            try inspectNode(alloc, entry.value_ptr.value, opts, max_depth, depth + 1, active);
        try props_list.append(alloc, .{
            .key = key_str,
            .enumerable = entry.value_ptr.enumerable,
            .is_accessor = entry.value_ptr.is_accessor,
            .value = val_node,
        });
    }

    var elements: std.ArrayList(ValueInspection) = .empty;
    errdefer {
        for (elements.items) |*e| e.deinit(alloc);
        elements.deinit(alloc);
    }
    var array_len: usize = 0;
    var truncated_elements = false;

    var map_entries: std.ArrayList(MapEntry) = .empty;
    errdefer {
        for (map_entries.items) |*m| m.deinit(alloc);
        map_entries.deinit(alloc);
    }
    var map_len: usize = 0;
    var truncated_map = false;

    var set_entries: std.ArrayList(ValueInspection) = .empty;
    errdefer {
        for (set_entries.items) |*s| s.deinit(alloc);
        set_entries.deinit(alloc);
    }
    var set_len: usize = 0;
    var truncated_set = false;

    switch (o.kind) {
        .array => |arr| {
            array_len = arr.items.len;
            const n = @min(arr.items.len, opts.max_items);
            truncated_elements = arr.items.len > n;
            for (arr.items[0..n]) |elem| {
                const node = try inspectNode(alloc, elem, opts, max_depth, depth + 1, active);
                try elements.append(alloc, node);
            }
        },
        .map => |m| {
            map_len = m.live_count;
            for (m.entries.items) |entry| {
                if (!entry.alive) continue;
                if (map_entries.items.len >= opts.max_items) {
                    truncated_map = true;
                    break;
                }
                var k_node = try inspectNode(alloc, entry.key, opts, max_depth, depth + 1, active);
                errdefer k_node.deinit(alloc);
                const v_node = try inspectNode(alloc, entry.value, opts, max_depth, depth + 1, active);
                try map_entries.append(alloc, .{ .key = k_node, .value = v_node });
            }
        },
        .set => |s| {
            set_len = s.live_count;
            for (s.entries.items) |entry| {
                if (!entry.alive) continue;
                if (set_entries.items.len >= opts.max_items) {
                    truncated_set = true;
                    break;
                }
                const k_node = try inspectNode(alloc, entry.key, opts, max_depth, depth + 1, active);
                try set_entries.append(alloc, k_node);
            }
        },
        else => {},
    }

    return .{ .object = .{
        .kind = kind,
        .ptr_id = @intFromPtr(o),
        .own_prop_count = own_prop_count,
        .properties = try props_list.toOwnedSlice(alloc),
        .truncated_props = truncated_props,
        .array_len = array_len,
        .elements = try elements.toOwnedSlice(alloc),
        .truncated_elements = truncated_elements,
        .map_len = map_len,
        .map_entries = try map_entries.toOwnedSlice(alloc),
        .truncated_map = truncated_map,
        .set_len = set_len,
        .set_entries = try set_entries.toOwnedSlice(alloc),
        .truncated_set = truncated_set,
    } };
}

/// Formats any `Value` directly to `w` with bounded depth, item count, and cycle detection.
/// Strictly read-only (never invokes getters).
pub fn formatValue(gpa: Allocator, v: Value, w: *Writer, opts: InspectOptions) (Allocator.Error || Writer.Error)!void {
    var active: std.ArrayList(*const Obj) = .empty;
    defer active.deinit(gpa);
    try writeValueNode(gpa, v, w, opts, opts.effectiveDepth(), 0, &active);
}

fn writeValueNode(
    gpa: Allocator,
    v: Value,
    w: *Writer,
    opts: InspectOptions,
    max_depth: u16,
    depth: u16,
    active: *std.ArrayList(*const Obj),
) (Allocator.Error || Writer.Error)!void {
    switch (v.unpack()) {
        .undefined => try w.writeAll("undefined"),
        .null => try w.writeAll("null"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .number => |n| {
            if (n == 0 and std.math.signbit(n)) {
                try w.writeAll("-0");
            } else {
                var buf: ops.NumberBuf = undefined;
                try w.writeAll(ops.formatNumber(&buf, n));
            }
        },
        .bigint => |b| {
            const s = try formatBigIntAlloc(gpa, b);
            defer gpa.free(s);
            try w.writeAll(s);
        },
        .string => |s| {
            try w.writeByte('"');
            const limit = @min(s.units.len, opts.max_string_len);
            for (s.units[0..limit]) |u| switch (u) {
                '"', '\\' => try w.print("\\{c}", .{@as(u8, @intCast(u))}),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try w.writeByte(@intCast(u)),
                else => try w.print("\\u{X:0>4}", .{u}),
            };
            if (s.units.len > opts.max_string_len) {
                try w.print("...({d} chars)", .{s.units.len});
            }
            try w.writeByte('"');
        },
        .symbol => |sym| {
            try w.writeAll("Symbol(");
            if (sym.description) |desc| {
                const limit = @min(desc.units.len, opts.max_string_len);
                try ops.writeUtf16(w, desc.units[0..limit]);
                if (desc.units.len > opts.max_string_len) try w.writeAll("...");
            }
            try w.writeByte(')');
        },
        .native => |n| {
            if (n.name.len > 0) {
                try w.print("[Native: {s}]", .{n.name});
            } else {
                try w.writeAll("[Native]");
            }
        },
        .closure => |c| {
            if (isActive(active.items, &c.obj)) {
                try w.writeAll("[Circular]");
                return;
            }
            switch (c.impl) {
                .vm => |vm_cl| {
                    const p: *const Proto = @ptrCast(@alignCast(vm_cl.proto));
                    const name = if (p.name.len > 0) p.name else if (p.inferred_name.len > 0) p.inferred_name else "<anonymous>";
                    try w.print("[Closure: {s} (captures: {d})]", .{ name, vm_cl.captures.len });
                },
                .tree => |t| {
                    const f: *const ast.Function = @ptrCast(@alignCast(t.func));
                    const name: []const u8 = if (f.name) |n| n.name else if (f.inferred_name.len > 0) f.inferred_name else "<anonymous>";
                    try w.print("[Closure: {s}]", .{name});
                },
                .bound => |b| {
                    try w.writeAll("[Closure: bound ");
                    try ops.writeUtf16(w, b.name.units);
                    try w.writeByte(']');
                },
                .native_closure, .promise_cap => try w.writeAll("[Closure: <native>]"),
            }
        },
        .object => |o| try writeObjectNode(gpa, o, w, opts, max_depth, depth, active),
    }
}

fn writeObjectNode(
    gpa: Allocator,
    o: *const Object,
    w: *Writer,
    opts: InspectOptions,
    max_depth: u16,
    depth: u16,
    active: *std.ArrayList(*const Obj),
) (Allocator.Error || Writer.Error)!void {
    const kind = objectKindTag(o);
    if (isActive(active.items, &o.obj)) {
        try w.writeAll("[Circular]");
        return;
    }
    if (depth >= max_depth) {
        try w.writeAll(depthLimitLabel(kind));
        return;
    }

    try active.append(gpa, &o.obj);
    defer _ = active.pop();

    switch (o.kind) {
        .array => |arr| {
            try w.writeByte('[');
            const n = @min(arr.items.len, opts.max_items);
            for (arr.items[0..n], 0..) |elem, i| {
                if (i > 0) try w.writeAll(", ");
                try writeValueNode(gpa, elem, w, opts, max_depth, depth + 1, active);
            }
            if (arr.items.len > n) {
                if (n > 0) try w.writeAll(", ");
                try w.print("... {d} more", .{arr.items.len - n});
            }
            try w.writeByte(']');
        },
        .map => |m| {
            try w.print("Map({d}) {{", .{m.live_count});
            var shown: usize = 0;
            for (m.entries.items) |entry| {
                if (!entry.alive) continue;
                if (shown >= opts.max_items) break;
                try w.writeAll(if (shown == 0) " " else ", ");
                try writeValueNode(gpa, entry.key, w, opts, max_depth, depth + 1, active);
                try w.writeAll(" => ");
                try writeValueNode(gpa, entry.value, w, opts, max_depth, depth + 1, active);
                shown += 1;
            }
            if (m.live_count > shown) {
                try w.print("{s}... {d} more", .{ if (shown == 0) " " else ", ", m.live_count - shown });
            }
            if (m.live_count > 0) try w.writeByte(' ');
            try w.writeByte('}');
        },
        .set => |s| {
            try w.print("Set({d}) {{", .{s.live_count});
            var shown: usize = 0;
            for (s.entries.items) |entry| {
                if (!entry.alive) continue;
                if (shown >= opts.max_items) break;
                try w.writeAll(if (shown == 0) " " else ", ");
                try writeValueNode(gpa, entry.key, w, opts, max_depth, depth + 1, active);
                shown += 1;
            }
            if (s.live_count > shown) {
                try w.print("{s}... {d} more", .{ if (shown == 0) " " else ", ", s.live_count - shown });
            }
            if (s.live_count > 0) try w.writeByte(' ');
            try w.writeByte('}');
        },
        .date => |tv| {
            if (std.math.isFinite(tv)) {
                var buf: [64]u8 = undefined;
                try w.writeAll(date.formatISO(&buf, tv));
            } else {
                try w.writeAll("Invalid Date");
            }
        },
        .regexp => |re| {
            try w.writeByte('/');
            try ops.writeUtf16(w, re.source.units);
            try w.writeByte('/');
            try ops.writeUtf16(w, re.flags.units);
        },
        .promise => |p| {
            try w.print("Promise<{s}>", .{@tagName(p.state)});
        },
        .weak_map => try w.writeAll("WeakMap { <items unknown> }"),
        .weak_set => try w.writeAll("WeakSet { <items unknown> }"),
        .proxy => try w.writeAll("Proxy"),
        else => {
            try w.writeByte('{');
            var it = o.props.iterator();
            var shown: usize = 0;
            var total: usize = 0;
            while (it.next()) |entry| {
                if (!opts.include_non_enumerable and !entry.value_ptr.enumerable) continue;
                total += 1;
                if (shown >= opts.max_items) continue;
                try w.writeAll(if (shown == 0) " " else ", ");
                try writePropKey(w, entry.key_ptr.*, opts.max_string_len);
                try w.writeAll(": ");
                if (entry.value_ptr.is_accessor) {
                    try w.writeAll("[Getter/Setter]");
                } else {
                    try writeValueNode(gpa, entry.value_ptr.value, w, opts, max_depth, depth + 1, active);
                }
                shown += 1;
            }
            if (total > shown) {
                try w.print("{s}... {d} more", .{ if (shown == 0) " " else ", ", total - shown });
            }
            if (total > 0) try w.writeByte(' ');
            try w.writeByte('}');
        },
    }
}

fn writePropKey(w: *Writer, key: PropKey, max_string_len: usize) Writer.Error!void {
    if (key.isSymbol()) {
        const sym = key.asSymbol();
        try w.writeAll("[Symbol(");
        if (sym.description) |desc| {
            const limit = @min(desc.units.len, max_string_len);
            try ops.writeUtf16(w, desc.units[0..limit]);
            if (desc.units.len > max_string_len) try w.writeAll("...");
        }
        try w.writeAll(")]");
    } else {
        const atom = key.asAtom();
        const limit = @min(atom.units.len, max_string_len);
        try ops.writeUtf16(w, atom.units[0..limit]);
        if (atom.units.len > max_string_len) try w.writeAll("...");
    }
}

fn formatPropKeyAlloc(alloc: Allocator, key: PropKey, max_string_len: usize) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    writePropKey(&out.writer, key, max_string_len) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn utf16ToUtf8Alloc(alloc: Allocator, units: []const u16) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    ops.writeUtf16(&out.writer, units) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn formatBigIntAlloc(alloc: Allocator, b: *const BigInt) Allocator.Error![]u8 {
    var out: Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    if (b.limbs.len == 0) {
        out.writer.writeAll("0n") catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
    if (b.negative) out.writer.writeByte('-') catch return error.OutOfMemory;
    if (b.limbs.len == 1) {
        out.writer.print("{d}n", .{b.limbs[0]}) catch return error.OutOfMemory;
        return out.toOwnedSlice();
    }
    const work = try alloc.dupe(u64, b.limbs);
    defer alloc.free(work);
    var chunks: std.ArrayList(u64) = .empty;
    defer chunks.deinit(alloc);

    const base: u64 = 10_000_000_000_000_000_000; // 10^19
    var len = work.len;
    while (len > 0) {
        var rem: u128 = 0;
        var i = len;
        while (i > 0) {
            i -= 1;
            const cur = (rem << 64) | work[i];
            work[i] = @truncate(cur / base);
            rem = cur % base;
        }
        while (len > 0 and work[len - 1] == 0) : (len -= 1) {}
        try chunks.append(alloc, @truncate(rem));
    }
    var i = chunks.items.len;
    if (i > 0) {
        i -= 1;
        out.writer.print("{d}", .{chunks.items[i]}) catch return error.OutOfMemory;
        while (i > 0) {
            i -= 1;
            out.writer.print("{d:0>19}", .{chunks.items[i]}) catch return error.OutOfMemory;
        }
    }
    out.writer.writeByte('n') catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

test "inspectHeap accounts nursery, old, and kind counts" {
    const testing = std.testing;
    var h = Heap.init(testing.allocator, .{});
    defer h.deinit();

    _ = try h.ascii("hello");
    _ = try h.newObject(null);
    const stats = inspectHeap(&h);
    try testing.expectEqual(@as(usize, 2), stats.young_objects);
    try testing.expectEqual(@as(usize, 0), stats.old_objects);
    try testing.expectEqual(@as(usize, 2), stats.live_objects);
    try testing.expectEqual(@as(usize, 1), stats.counts_by_kind.string);
    try testing.expectEqual(@as(usize, 1), stats.counts_by_kind.object);
    try testing.expectEqual(stats.total_bytes, stats.nursery_bytes + stats.old_bytes + stats.buffer_bytes);
}
