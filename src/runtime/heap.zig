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
//!
//! Object-internal buffers (M7: property tables, array elements, the atom table) grow
//! and shrink, so they go through `allocator()`, a counting std.mem.Allocator with the
//! same charging rule (D7). It can only report OutOfMemory; when the refusal was the
//! heap limit it sets `refused`, and `failed()` turns that back into LimitExceeded.
//!
//! GC traceability (M7 acceptance, DESIGN_DECISIONS D38): `forEachChild` enumerates
//! every reference from a heap object to another, for every kind. M8's marking is that
//! enumeration; a kind added without updating it fails the exhaustive switch.
//!
//! Reference stores (M8, DESIGN_DECISIONS D8/I3): after construction, every reference
//! written into a heap object goes through the `store*`/`append*` functions below, so a
//! later write barrier (incremental marking, generations) has one place to hook into. In
//! M8 the barrier is a no-op: collection is stop-the-world and only at safepoints, so no
//! store can happen during a collection. `tests/gc_test.zig` greps for raw stores.

const std = @import("std");
const Allocator = std.mem.Allocator;
/// `-Dgc-stress` (GC_DESIGN §11): collect at every safepoint, turn freed objects into
/// tombstones, verify the heap after every collection. In any build mode, ReleaseSafe too.
pub const gc_stress = @import("build_options").gc_stress;
const limits_mod = @import("../limits.zig");
const Limits = limits_mod.Limits;
const Limit = limits_mod.Limit;
const Value = @import("value.zig").Value;
const Builtin = @import("builtin_names.zig").Builtin;

pub const Error = error{ LimitExceeded, OutOfMemory };

pub const per_allocation_overhead = 16;

pub const Obj = struct {
    kind: Kind,
    /// The list of every object (the sweep list).
    next: ?*Obj,
    /// Set during a collection's mark phase; cleared by the sweep (D8).
    marked: bool = false,
    /// The gray list while marking: intrusive, so marking never allocates (D9).
    gray_next: ?*Obj = null,
    /// Stress builds only: an allocation number, and the kind a tombstone used to be.
    debug: Debug = if (gc_stress) .{} else {},

    pub const Kind = enum {
        string,
        cell,
        closure,
        env,
        object,
        /// A tombstone (stress builds): a collected object kept so any later use of it is a
        /// deterministic panic naming what it was, instead of a read of freed memory.
        dead,
    };

    pub const Debug = if (gc_stress) struct { id: u64 = 0, was: Kind = .dead } else void;

    /// Panics if `obj` was collected (only tombstones can fail this, so only in stress
    /// builds; the check itself is one compare).
    pub inline fn checkLive(obj: *const Obj) void {
        if (gc_stress and obj.kind == .dead)
            std.debug.panic("zqjs GC bug: use of a collected {s} (allocation #{d})", .{ @tagName(obj.debug.was), obj.debug.id });
    }
};

/// What a tombstoned string's units become: visible in any output that reads it anyway.
const poison_units = [_]u16{ '<', 'c', 'o', 'l', 'l', 'e', 'c', 't', 'e', 'd', '>' };

/// A captured variable (VM, DESIGN_DECISIONS D36). `null` = TDZ. Shared by every closure
/// that captured it, so writes through any of them are seen by all.
pub const Cell = struct {
    obj: Obj,
    value: ?Value,
};

/// A function value. Each engine creates and reads only its own variant; the payload
/// pointers are opaque here so the heap does not depend on the AST or the bytecode.
pub const Closure = struct {
    obj: Obj,
    impl: union(enum) {
        /// `proto: *const bytecode.Proto`; `captures` filled by `make_closure`.
        vm: struct { proto: *const anyopaque, captures: []*Cell },
        /// `func: *const ast.Function`; `env` is the environment it was created in.
        tree: struct { func: *const anyopaque, env: ?*Env },
    },
};

/// An environment record of the tree-walker (DESIGN_DECISIONS D37): the bindings of one
/// scope (`null` = TDZ) and the enclosing record.
pub const Env = struct {
    obj: Obj,
    parent: ?*Env,
    scope: u32,
    values: []?Value,
};

pub const String = struct {
    obj: Obj,
    /// UTF-16 code units, possibly with lone surrogates. Immutable.
    units: []const u16,
    /// Set for atoms (interned property keys, D11), which are compared by pointer.
    atom: ?struct {
        /// The canonical array index this key denotes ("0", "17"; not "01", "-1"), if any:
        /// a canonical numeric string ≤ 2^32 − 2 (D13).
        index: ?u32,
    } = null,
};

/// An own property. Everything is a data property (no getters/setters in ZQJS); all are
/// writable and configurable. Built-in methods are not enumerable, as in node.
pub const Property = struct {
    value: Value,
    enumerable: bool = true,
};

/// An ordinary object or an array (DESIGN_DECISIONS D13).
pub const Object = struct {
    obj: Obj,
    /// The prototype. Only Object.create and the built-ins set it, always to an existing
    /// object or null, so a chain can never form a cycle.
    proto: ?*Object,
    /// Own properties in insertion order, keyed by atom. Index-like keys of ordinary
    /// objects live here too; `ownKeys` puts them first, ascending.
    props: std.AutoArrayHashMapUnmanaged(*String, Property) = .empty,
    kind: union(enum) {
        ordinary,
        /// Dense elements 0 … len-1: no holes, ever (D13).
        array: std.ArrayList(Value),
    } = .ordinary,
    /// Set on the built-in objects: which node object's names classify lookups that
    /// miss here (builtin_names.zig, D39).
    builtin: ?Builtin = null,
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
    /// Accounted bytes currently allocated (live, until M8: everything not rolled back).
    bytes: usize = 0,
    /// Highest value `bytes` has had.
    peak: usize = 0,
    /// All bytes ever charged (never decreases; frees don't subtract).
    allocated: u64 = 0,
    /// Which limit was hit, when an operation returns error.LimitExceeded.
    limit_hit: ?Limit = null,
    /// Interned property keys (D11). Strong until the M8 GC makes it weak.
    atoms: std.HashMapUnmanaged(*String, void, AtomContext, 80) = .empty,
    /// `allocator()` refused an allocation because of the heap limit (see `failed`).
    refused: bool = false,
    /// When `bytes` passes this, a collection is requested for the next safepoint.
    next_gc: usize = 0,
    collect_requested: bool = false,
    /// Collect at every safepoint, not only when requested (tests; always under -Dgc-stress).
    collect_always: bool = gc_stress,
    /// Bytes charged through `allocator()` (object-internal buffers), for the verifier's
    /// accounting check: `bytes` = Σ live objects' fixed charges + `buffer_bytes`.
    buffer_bytes: usize = 0,
    /// Stress builds: allocation numbers, and collected objects kept as tombstones.
    next_id: u64 = 0,
    tombstones: ?*Obj = null,
    /// The gray list while marking (empty otherwise).
    gray: ?*Obj = null,
    stats: Stats = .{},

    /// Deterministic collector statistics (D8): work units, not wall-clock time.
    pub const Stats = struct {
        collections: u64 = 0,
        /// Cumulative bytes freed by collections.
        bytes_freed: u64 = 0,
        /// Accounted bytes surviving the last collection.
        live_after_last: usize = 0,
        /// Cumulative objects surviving collections, and freed by them.
        marked: u64 = 0,
        swept: u64 = 0,
    };

    pub fn init(gpa: Allocator, limits: Limits) Heap {
        var h: Heap = .{ .gpa = gpa, .max_bytes = limits.max_heap_bytes, .max_string_length = limits.max_string_length };
        h.next_gc = h.schedule(0);
        return h;
    }

    // ---- the collector (D8; GC_DESIGN §6). Runs only at safepoints, by the engine.

    /// The next collection trigger after `live` bytes survived (D8): grow by the live size
    /// (at least 256 KiB), but never beyond half the room left under the limit. So small
    /// heaps collect after doubling, and near the limit each collection needs half the
    /// remaining room allocated first: a program filling its heap with live data collects
    /// O(log limit) times, never at every safepoint. Overflow-free: the result is at most
    /// `live + (max − live) / 2 ≤ max`.
    pub fn schedule(h: *const Heap, live: usize) usize {
        const min_growth = 256 * 1024;
        const room = (h.max_bytes -| live) / 2;
        return live + @min(@max(live, min_growth), room);
    }

    /// Marks `obj` and queues it for scanning, once.
    pub fn markObj(h: *Heap, obj: *Obj) void {
        obj.checkLive(); // a root or an edge to a collected object (stress builds)
        if (obj.marked) return;
        obj.marked = true;
        obj.gray_next = h.gray;
        h.gray = obj;
    }

    pub fn markValue(h: *Heap, v: Value) void {
        visitValue(v, h, markObj);
    }

    /// A full stop-the-world collection. `markRoots(roots, h)` marks every root (with
    /// `markObj`/`markValue`); everything not reachable from them is freed. Allocates
    /// nothing and can't fail (I4).
    pub fn collect(h: *Heap, roots: anytype, comptime markRoots: fn (@TypeOf(roots), *Heap) void) void {
        std.debug.assert(h.gray == null);
        markRoots(roots, h);
        // Drain: each gray object's children (D38's edges), iteratively, never recursively.
        while (h.gray) |obj| {
            h.gray = obj.gray_next;
            obj.gray_next = null;
            forEachChild(obj, h, markObj);
        }
        // Weak atoms (D11, I6): rebuild the table from the marked atoms, before any atom is
        // freed. Walking the object list (not the table) keeps the rebuild deterministic,
        // and reinserting at most as many entries as were there needs no allocation.
        h.atoms.clearRetainingCapacity();
        var it = h.objects;
        while (it) |obj| : (it = obj.next) {
            if (obj.kind != .string or !obj.marked) continue;
            const str: *String = @fieldParentPtr("obj", obj);
            if (str.atom != null) h.atoms.putAssumeCapacityNoClobber(str, {});
        }
        // Sweep: free the unmarked, unmark the survivors.
        const before = h.bytes;
        var link: *?*Obj = &h.objects;
        while (link.*) |obj| {
            if (obj.marked) {
                obj.marked = false;
                h.stats.marked += 1;
                link = &obj.next;
            } else {
                link.* = obj.next;
                if (gc_stress) h.entomb(obj) else h.destroy(obj);
                h.stats.swept += 1;
            }
        }
        h.stats.collections += 1;
        h.stats.bytes_freed += before - h.bytes;
        h.stats.live_after_last = h.bytes;
        h.next_gc = h.schedule(h.bytes);
        h.collect_requested = false;
        if (gc_stress) h.verify() catch |e| std.debug.panic("zqjs GC bug: heap verification failed after a collection: {s}", .{@errorName(e)});
    }

    pub const VerifyError = error{ GrayListNotEmpty, EdgeToCollectedObject, CollectedObjectInList, AtomTableHoldsCollectedObject, AtomTableHoldsNonAtom, AccountingMismatch };

    /// The heap verifier (GC_DESIGN §11; after every collection in stress builds, and
    /// callable from tests): the gray list is empty; no live object references a collected
    /// one (roots are checked as they are marked, `markObj`); the atom table holds only live
    /// atoms; and the accounting is exact: `bytes` = Σ every live object's fixed charge +
    /// every buffer byte charged through `allocator()`. Allocates nothing.
    pub fn verify(h: *const Heap) VerifyError!void {
        if (h.gray != null) return error.GrayListNotEmpty;
        var sum: usize = h.buffer_bytes;
        const Check = struct {
            bad: bool = false,
            fn edge(c: *@This(), child: *Obj) void {
                if (child.kind == .dead) c.bad = true;
            }
        };
        var it = h.objects;
        while (it) |obj| : (it = obj.next) {
            if (obj.kind == .dead) return error.CollectedObjectInList;
            sum += fixedCharge(obj);
            var c: Check = .{};
            forEachChild(obj, &c, Check.edge);
            if (c.bad) return error.EdgeToCollectedObject;
        }
        var atoms = h.atoms.keyIterator();
        while (atoms.next()) |k| {
            if (k.*.obj.kind == .dead) return error.AtomTableHoldsCollectedObject;
            if (k.*.atom == null) return error.AtomTableHoldsNonAtom;
        }
        if (sum != h.bytes) return error.AccountingMismatch;
    }

    pub fn deinit(h: *Heap) void {
        h.atoms.deinit(h.allocator());
        var it = h.objects;
        while (it) |obj| {
            it = obj.next;
            h.destroy(obj);
        }
        var t = h.tombstones;
        while (t) |obj| {
            t = obj.next;
            h.freeStruct(obj, if (gc_stress) obj.debug.was else unreachable);
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
            if (obj.kind == .string) std.debug.assert(@as(*String, @fieldParentPtr("obj", obj)).atom == null); // the table would dangle
            h.objects = obj.next;
            h.destroy(obj);
        }
    }

    // ---- objects (M7)

    pub fn newObject(h: *Heap, proto: ?*Object) Error!*Object {
        const charge = try h.reserve(@sizeOf(Object), 0, 1);
        errdefer h.bytes -= charge;
        const o = try h.gpa.create(Object);
        o.* = .{ .obj = h.newHeader(.object), .proto = proto };
        h.objects = &o.obj;
        return o;
    }

    pub fn newArray(h: *Heap, proto: ?*Object) Error!*Object {
        const o = try h.newObject(proto);
        o.kind = .{ .array = .empty };
        return o;
    }

    // ---- the store API (GC_DESIGN §7, I3)
    //
    // After construction, every reference written into a heap object goes through one of
    // these. Each knows the owner, the old value and the new one: what an insertion barrier
    // (Dijkstra), a deletion barrier (Yuasa) or a generational remembered set needs. In M8
    // `barrier` does nothing; tests/gc_test.zig scans the sources for raw stores.

    /// `o[key] = value`: updates an own property in place (keeping its position and
    /// enumerability) or adds an enumerable one at the end (D13).
    pub fn storeProperty(h: *Heap, o: *Object, key: *String, value: Value) Error!void {
        o.obj.checkLive();
        const gop = o.props.getOrPut(h.allocator(), key) catch |e| return h.failed(e);
        const old: ?Value = if (gop.found_existing) gop.value_ptr.value else null;
        if (gop.found_existing) gop.value_ptr.value = value else gop.value_ptr.* = .{ .value = value };
        h.barrier(&o.obj, old, value);
    }

    /// Adds or replaces a property with explicit attributes (built-in method tables).
    pub fn defineProperty(h: *Heap, o: *Object, key: *String, p: Property) Error!void {
        o.obj.checkLive();
        const gop = o.props.getOrPut(h.allocator(), key) catch |e| return h.failed(e);
        const old: ?Value = if (gop.found_existing) gop.value_ptr.value else null;
        gop.value_ptr.* = p;
        h.barrier(&o.obj, old, p.value);
    }

    /// `delete o[key]` for an own property; keeps the others' order (O(n), D13).
    pub fn removeProperty(h: *Heap, o: *Object, key: *String) void {
        const old = o.props.get(key) orelse return;
        _ = o.props.orderedRemove(key);
        h.barrier(&o.obj, old.value, null);
    }

    pub fn appendElement(h: *Heap, arr: *Object, value: Value) Error!void {
        elementsOf(arr).append(h.allocator(), value) catch |e| return h.failed(e);
        h.barrier(&arr.obj, null, value);
    }

    pub fn appendElements(h: *Heap, arr: *Object, values: []const Value) Error!void {
        elementsOf(arr).appendSlice(h.allocator(), values) catch |e| return h.failed(e);
        for (values) |v| h.barrier(&arr.obj, null, v);
    }

    /// `arr[i] = value` for an existing element (i < length).
    pub fn storeElement(h: *Heap, arr: *Object, i: usize, value: Value) void {
        const slot = &elementsOf(arr).items[i];
        const old = slot.*;
        slot.* = value;
        h.barrier(&arr.obj, old, value);
    }

    /// Truncates to `len` (≤ length): `arr.length = len`.
    pub fn shrinkElements(h: *Heap, arr: *Object, len: usize) void {
        const elements = elementsOf(arr);
        for (elements.items[len..]) |old| h.barrier(&arr.obj, old, null);
        elements.shrinkRetainingCapacity(len);
    }

    pub fn popElement(h: *Heap, arr: *Object) ?Value {
        const old = elementsOf(arr).pop() orelse return null;
        h.barrier(&arr.obj, old, null);
        return old;
    }

    /// A captured binding's new value (null: back in the TDZ).
    pub fn storeCell(h: *Heap, c: *Cell, value: ?Value) void {
        const old = c.value;
        c.value = value;
        h.barrier(&c.obj, old, value);
    }

    /// A tree-walker binding's new value (null: back in the TDZ).
    pub fn storeEnv(h: *Heap, e: *Env, index: usize, value: ?Value) void {
        const old = e.values[index];
        e.values[index] = value;
        h.barrier(&e.obj, old, value);
    }

    /// The write barrier: `owner` now holds `new` where it held `old`. A no-op in M8:
    /// collection is stop-the-world and only at safepoints, so no store can happen during
    /// one (GC_DESIGN §7). M8.1 (incremental) and M8.2 (generations) change only this.
    inline fn barrier(h: *Heap, owner: *Obj, old: ?Value, new: ?Value) void {
        _ = h;
        _ = old;
        // Not the barrier's job, but every store passes here: in stress builds, a store
        // into or of a collected object is caught at the store.
        owner.checkLive();
        if (new) |v| checkValue(v);
    }

    fn elementsOf(arr: *Object) *std.ArrayList(Value) {
        return switch (arr.kind) {
            .array => |*elements| elements,
            .ordinary => unreachable, // only arrays have elements
        };
    }

    /// The atom for `units` (interning it if new).
    pub fn intern(h: *Heap, units: []const u16) Error!*String {
        return h.internAdapted(units, Utf16Adapter{});
    }

    /// The atom for ASCII text (a property name from the source).
    pub fn internAscii(h: *Heap, text: []const u8) Error!*String {
        return h.internAdapted(text, AsciiAdapter{});
    }

    fn internAdapted(h: *Heap, key: anytype, adapter: anytype) Error!*String {
        const gop = h.atoms.getOrPutContextAdapted(h.allocator(), key, adapter, .{}) catch |e| return h.failed(e);
        if (gop.found_existing) return gop.key_ptr.*;
        errdefer h.atoms.removeByPtr(gop.key_ptr);
        const s = try h.newString(&.{if (@TypeOf(key) == []const u8) .{ .ascii = key } else .{ .utf16 = key }});
        s.atom = .{ .index = arrayIndex(s.units) };
        gop.key_ptr.* = s;
        return s;
    }

    /// A counting allocator for object-internal buffers (see the file comment).
    pub fn allocator(h: *Heap) Allocator {
        return .{ .ptr = h, .vtable = &counting_vtable };
    }

    /// Translates an `allocator()` failure: LimitExceeded if the heap limit refused it.
    pub fn failed(h: *Heap, e: Allocator.Error) Error {
        switch (e) { // always OutOfMemory; `refused` says why
            error.OutOfMemory => {},
        }
        if (h.refused) {
            h.refused = false;
            h.limit_hit = .heap_bytes;
            return error.LimitExceeded;
        }
        return error.OutOfMemory;
    }

    const counting_vtable: Allocator.VTable = .{ .alloc = countAlloc, .resize = countResize, .remap = countRemap, .free = countFree };

    /// Charges `len` bytes plus `allocations` overheads, or records the refusal.
    fn chargeBytes(h: *Heap, len: usize, allocations: usize) bool {
        _ = h.reserve(0, len, allocations) catch {
            h.refused = true;
            return false;
        };
        return true;
    }

    fn countAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const h: *Heap = @ptrCast(@alignCast(ctx));
        if (!h.chargeBytes(len, 1)) return null;
        const p = h.gpa.rawAlloc(len, alignment, ret) orelse {
            h.bytes -= len + per_allocation_overhead;
            return null;
        };
        h.buffer_bytes += len + per_allocation_overhead;
        return p;
    }

    fn countResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const h: *Heap = @ptrCast(@alignCast(ctx));
        // Growth is charged without an overhead: the allocation already exists.
        if (new_len > memory.len and !h.chargeBytes(new_len - memory.len, 0)) return false;
        if (!h.gpa.rawResize(memory, alignment, new_len, ret)) {
            if (new_len > memory.len) h.bytes -= new_len - memory.len;
            return false;
        }
        if (new_len < memory.len) h.bytes -= memory.len - new_len;
        h.buffer_bytes = h.buffer_bytes + new_len - memory.len;
        return true;
    }

    fn countRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const h: *Heap = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len and !h.chargeBytes(new_len - memory.len, 0)) return null;
        const p = h.gpa.rawRemap(memory, alignment, new_len, ret) orelse {
            if (new_len > memory.len) h.bytes -= new_len - memory.len;
            return null;
        };
        if (new_len < memory.len) h.bytes -= memory.len - new_len;
        h.buffer_bytes = h.buffer_bytes + new_len - memory.len;
        return p;
    }

    fn countFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const h: *Heap = @ptrCast(@alignCast(ctx));
        h.bytes -= memory.len + per_allocation_overhead;
        h.buffer_bytes -= memory.len + per_allocation_overhead;
        h.gpa.rawFree(memory, alignment, ret);
    }

    pub fn newCell(h: *Heap, value: ?Value) Error!*Cell {
        const charge = try h.reserve(@sizeOf(Cell), 0, 1);
        errdefer h.bytes -= charge;
        const c = try h.gpa.create(Cell);
        c.* = .{ .obj = h.newHeader(.cell), .value = value };
        h.objects = &c.obj;
        return c;
    }

    /// A VM closure with `n` captures, all `undefined` until the caller fills them.
    pub fn newVmClosure(h: *Heap, proto: *const anyopaque, n: usize) Error!*Closure {
        const payload = std.math.mul(usize, n, @sizeOf(*Cell)) catch return h.exceeded(.heap_bytes);
        const charge = try h.reserve(@sizeOf(Closure), payload, 2);
        errdefer h.bytes -= charge;
        const captures = try h.gpa.alloc(*Cell, n);
        errdefer h.gpa.free(captures);
        const c = try h.gpa.create(Closure);
        c.* = .{ .obj = h.newHeader(.closure), .impl = .{ .vm = .{ .proto = proto, .captures = captures } } };
        h.objects = &c.obj;
        return c;
    }

    pub fn newTreeClosure(h: *Heap, func: *const anyopaque, env: ?*Env) Error!*Closure {
        const charge = try h.reserve(@sizeOf(Closure), 0, 2); // same charge as a VM closure
        errdefer h.bytes -= charge;
        const c = try h.gpa.create(Closure);
        c.* = .{ .obj = h.newHeader(.closure), .impl = .{ .tree = .{ .func = func, .env = env } } };
        h.objects = &c.obj;
        return c;
    }

    /// An environment record with `len` bindings, all in the TDZ.
    pub fn newEnv(h: *Heap, parent: ?*Env, scope: u32, len: usize) Error!*Env {
        const payload = std.math.mul(usize, len, @sizeOf(?Value)) catch return h.exceeded(.heap_bytes);
        const charge = try h.reserve(@sizeOf(Env), payload, 2);
        errdefer h.bytes -= charge;
        const values = try h.gpa.alloc(?Value, len);
        errdefer h.gpa.free(values);
        @memset(values, null);
        const e = try h.gpa.create(Env);
        e.* = .{ .obj = h.newHeader(.env), .parent = parent, .scope = scope, .values = values };
        h.objects = &e.obj;
        return e;
    }

    /// Frees one object and gives its charge back.
    fn destroy(h: *Heap, obj: *Obj) void {
        const kind = obj.kind;
        h.release(obj);
        h.freeStruct(obj, kind);
    }

    /// Stress builds: free what a collected object owns and give its charge back, but keep
    /// its struct as a tombstone, with every payload emptied or poisoned, so a later use is
    /// a deterministic panic (`checkLive`) or at worst a visibly wrong value, never a read
    /// of freed memory.
    fn entomb(h: *Heap, obj: *Obj) void {
        const kind = obj.kind;
        h.release(obj);
        obj.kind = .dead;
        if (gc_stress) obj.debug.was = kind;
        obj.marked = false;
        obj.next = h.tombstones;
        h.tombstones = obj;
    }

    /// The charge an object's constructor made for the object itself (its struct and
    /// fixed-size payload). Buffers that grow are charged separately (`buffer_bytes`).
    fn fixedCharge(obj: *const Obj) usize {
        return switch (obj.kind) {
            .string => @sizeOf(String) + @as(*const String, @alignCast(@fieldParentPtr("obj", obj))).units.len * @sizeOf(u16) + 2 * per_allocation_overhead,
            .cell => @sizeOf(Cell) + per_allocation_overhead,
            .closure => switch (@as(*const Closure, @alignCast(@fieldParentPtr("obj", obj))).impl) {
                .vm => |v| @sizeOf(Closure) + v.captures.len * @sizeOf(*Cell) + 2 * per_allocation_overhead,
                .tree => @sizeOf(Closure) + 2 * per_allocation_overhead,
            },
            .env => @sizeOf(Env) + @as(*const Env, @alignCast(@fieldParentPtr("obj", obj))).values.len * @sizeOf(?Value) + 2 * per_allocation_overhead,
            .object => @sizeOf(Object) + per_allocation_overhead,
            .dead => 0,
        };
    }

    /// Gives back the charge and frees everything `obj` owns except its struct, leaving
    /// empty (or poisoned) payloads behind.
    fn release(h: *Heap, obj: *Obj) void {
        h.bytes -= fixedCharge(obj);
        switch (obj.kind) {
            .string => {
                const s: *String = @fieldParentPtr("obj", obj);
                h.gpa.free(s.units);
                s.units = &poison_units;
                s.atom = null;
            },
            .cell => @as(*Cell, @fieldParentPtr("obj", obj)).value = null,
            .closure => {
                const c: *Closure = @fieldParentPtr("obj", obj);
                switch (c.impl) {
                    .vm => |*v| {
                        h.gpa.free(v.captures);
                        v.captures = &.{};
                    },
                    .tree => |*t| t.env = null,
                }
            },
            .env => {
                const e: *Env = @fieldParentPtr("obj", obj);
                h.gpa.free(e.values);
                e.values = &.{};
                e.parent = null;
            },
            .object => {
                const o: *Object = @fieldParentPtr("obj", obj);
                o.props.deinit(h.allocator()); // refunds through the counting allocator
                o.props = .empty;
                switch (o.kind) {
                    .ordinary => {},
                    .array => |*elements| elements.deinit(h.allocator()),
                }
                o.kind = .ordinary;
                o.proto = null;
            },
            .dead => unreachable, // tombstones are never released twice
        }
    }

    fn freeStruct(h: *Heap, obj: *Obj, kind: Obj.Kind) void {
        switch (kind) {
            .string => h.gpa.destroy(@as(*String, @fieldParentPtr("obj", obj))),
            .cell => h.gpa.destroy(@as(*Cell, @fieldParentPtr("obj", obj))),
            .closure => h.gpa.destroy(@as(*Closure, @fieldParentPtr("obj", obj))),
            .env => h.gpa.destroy(@as(*Env, @fieldParentPtr("obj", obj))),
            .object => h.gpa.destroy(@as(*Object, @fieldParentPtr("obj", obj))),
            .dead => unreachable,
        }
    }

    /// A new object's header, linked into the object list (with an allocation number in
    /// stress builds).
    fn newHeader(h: *Heap, kind: Obj.Kind) Obj {
        var o: Obj = .{ .kind = kind, .next = h.objects };
        if (gc_stress) {
            h.next_id += 1;
            o.debug.id = h.next_id;
        }
        return o;
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
        s.* = .{ .obj = h.newHeader(.string), .units = units };
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
        if (total > h.next_gc) h.collect_requested = true; // collected at the next safepoint
        h.peak = @max(h.peak, total);
        h.allocated += charge;
        return charge;
    }

    fn exceeded(h: *Heap, which: Limit) Error {
        h.limit_hit = which;
        return error.LimitExceeded;
    }
};

/// Calls `visit(ctx, child)` for every heap object `obj` references directly: the edges
/// M8's marking follows (D38). Atoms used as property keys are edges too (D11).
pub fn forEachChild(obj: *Obj, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *Obj) void) void {
    switch (obj.kind) {
        .string => {},
        .dead => unreachable, // markObj rejects tombstones before they are scanned
        .cell => {
            const c: *Cell = @fieldParentPtr("obj", obj);
            if (c.value) |v| visitValue(v, ctx, visit);
        },
        .closure => {
            const c: *Closure = @fieldParentPtr("obj", obj);
            switch (c.impl) {
                // The Proto (and its string constants) is not a heap object yet; M8 roots it.
                .vm => |v| for (v.captures) |cell| visit(ctx, &cell.obj),
                .tree => |t| if (t.env) |e| visit(ctx, &e.obj),
            }
        },
        .env => {
            const e: *Env = @fieldParentPtr("obj", obj);
            if (e.parent) |p| visit(ctx, &p.obj);
            for (e.values) |slot| if (slot) |v| visitValue(v, ctx, visit);
        },
        .object => {
            const o: *Object = @fieldParentPtr("obj", obj);
            if (o.proto) |p| visit(ctx, &p.obj);
            for (o.props.keys(), o.props.values()) |k, p| {
                visit(ctx, &k.obj);
                visitValue(p.value, ctx, visit);
            }
            switch (o.kind) {
                .ordinary => {},
                .array => |elements| for (elements.items) |v| visitValue(v, ctx, visit),
            }
        },
    }
}

pub fn visitValue(v: Value, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *Obj) void) void {
    switch (v) {
        .undefined, .null, .boolean, .number, .native => {}, // natives are static
        .string => |s| visit(ctx, @constCast(&s.obj)),
        .closure => |c| visit(ctx, @constCast(&c.obj)),
        .object => |o| visit(ctx, &o.obj),
    }
}

/// Panics if `v` is a collected heap object (stress builds; one compare otherwise skipped).
pub inline fn checkValue(v: Value) void {
    switch (v) {
        .string => |x| x.obj.checkLive(),
        .closure => |x| x.obj.checkLive(),
        .object => |x| x.obj.checkLive(),
        .undefined, .null, .boolean, .number, .native => {},
    }
}

/// The canonical array index a key denotes: "0" or [1-9][0-9]* with value ≤ 2^32 − 2.
fn arrayIndex(units: []const u16) ?u32 {
    if (units.len == 0 or units.len > 10) return null;
    if (units[0] == '0') return if (units.len == 1) 0 else null;
    var n: u64 = 0;
    for (units) |u| {
        if (u < '0' or u > '9') return null;
        n = n * 10 + (u - '0');
    }
    return if (n <= std.math.maxInt(u32) - 1) @intCast(n) else null;
}

/// Atoms hash by content (FNV-1a over code units, so ASCII and UTF-16 lookups agree).
fn hashUnits(comptime T: type, units: []const T) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (units) |u| {
        h ^= @as(u16, u);
        h *%= 0x100000001b3;
    }
    return h;
}

const AtomContext = struct {
    pub fn hash(_: AtomContext, s: *String) u64 {
        return hashUnits(u16, s.units);
    }
    pub fn eql(_: AtomContext, a: *String, b: *String) bool {
        return a == b;
    }
};

const Utf16Adapter = struct {
    pub fn hash(_: Utf16Adapter, units: []const u16) u64 {
        return hashUnits(u16, units);
    }
    pub fn eql(_: Utf16Adapter, units: []const u16, s: *String) bool {
        return std.mem.eql(u16, units, s.units);
    }
};

const AsciiAdapter = struct {
    pub fn hash(_: AsciiAdapter, text: []const u8) u64 {
        return hashUnits(u8, text);
    }
    pub fn eql(_: AsciiAdapter, text: []const u8, s: *String) bool {
        if (text.len != s.units.len) return false;
        for (text, s.units) |c, u| if (c != u) return false;
        return true;
    }
};

const testing = std.testing;

test "atoms: interned once, by content, from ASCII or UTF-16; array indices classified" {
    var h = Heap.init(testing.allocator, .{});
    defer h.deinit();
    const a = try h.internAscii("length");
    try testing.expectEqual(a, try h.intern(std.unicode.utf8ToUtf16LeStringLiteral("length")));
    try testing.expectEqual(a, try h.internAscii("length"));
    try testing.expect(a != try h.internAscii("lengths"));
    try testing.expectEqual(@as(?u32, 4294967294), (try h.internAscii("4294967294")).atom.?.index);
    for ([_][]const u8{ "4294967295", "01", "-1", "1.0", "", "1e3" }) |k| try testing.expectEqual(@as(?u32, null), (try h.internAscii(k)).atom.?.index);
    try testing.expectEqual(@as(?u32, 0), (try h.internAscii("0")).atom.?.index);
}

test "object storage is charged to the heap limit and refunded exactly" {
    var h = Heap.init(testing.allocator, .{});
    defer h.deinit();
    const o = try h.newObject(null);
    const arr = try h.newArray(o);
    const k = try h.internAscii("k");
    const before = h.bytes;
    try o.props.put(h.allocator(), k, .{ .value = .null });
    try arr.kind.array.append(h.allocator(), .{ .number = 1 });
    try testing.expect(h.bytes > before);
    _ = o.props.orderedRemove(k);
    o.props.clearAndFree(h.allocator());
    arr.kind.array.clearAndFree(h.allocator());
    try testing.expectEqual(before, h.bytes);
    // The limit refuses buffer growth too, reported as LimitExceeded, not OutOfMemory.
    var small = Heap.init(testing.allocator, .{ .max_heap_bytes = 200 });
    defer small.deinit();
    const big = try small.newArray(null);
    try testing.expectError(error.LimitExceeded, big.kind.array.appendNTimes(small.allocator(), .null, 100) catch |e| small.failed(e));
    try testing.expectEqual(Limit.heap_bytes, small.limit_hit.?);
}

test "forEachChild enumerates every reference edge (what the M8 GC will mark)" {
    var h = Heap.init(testing.allocator, .{});
    defer h.deinit();
    const proto = try h.newObject(null);
    const o = try h.newObject(proto);
    const key = try h.internAscii("x");
    const str = try h.ascii("value");
    const arr = try h.newArray(proto);
    try arr.kind.array.append(h.allocator(), .{ .string = str });
    try o.props.put(h.allocator(), key, .{ .value = .{ .object = arr } });
    const cell = try h.newCell(.{ .object = o });
    const env = try h.newEnv(null, 0, 1);
    env.values[0] = .{ .string = str };
    const env2 = try h.newEnv(env, 1, 0);
    const tree = try h.newTreeClosure(@ptrCast(&h), env2);
    const vm = try h.newVmClosure(@ptrCast(&h), 1);
    vm.impl.vm.captures[0] = cell;

    const Collect = struct {
        found: [8]*Obj = undefined,
        n: usize = 0,
        fn add(c: *@This(), child: *Obj) void {
            c.found[c.n] = child;
            c.n += 1;
        }
        fn expect(obj: *Obj, want: []const *Obj) !void {
            var c: @This() = .{};
            forEachChild(obj, &c, add);
            try testing.expectEqualSlices(*Obj, want, c.found[0..c.n]);
        }
    };
    try Collect.expect(&o.obj, &.{ &proto.obj, &key.obj, &arr.obj }); // prototype, key, value
    try Collect.expect(&arr.obj, &.{ &proto.obj, &str.obj }); // prototype, elements
    try Collect.expect(&cell.obj, &.{&o.obj});
    try Collect.expect(&vm.obj, &.{&cell.obj}); // captured cells
    try Collect.expect(&tree.obj, &.{&env2.obj});
    try Collect.expect(&env2.obj, &.{&env.obj}); // parent
    try Collect.expect(&env.obj, &.{&str.obj});
    try Collect.expect(&str.obj, &.{});
}

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

test "cells, closures and environments are accounted and freed" {
    var h = Heap.init(testing.allocator, .{});
    defer h.deinit(); // testing.allocator reports leaks
    const c = try h.newCell(null);
    const vm = try h.newVmClosure(@ptrCast(&h), 2);
    vm.impl.vm.captures[0] = c;
    vm.impl.vm.captures[1] = c;
    const e = try h.newEnv(null, 0, 3);
    _ = try h.newTreeClosure(@ptrCast(&h), e);
    const m = h.mark();
    const before = h.bytes;
    _ = try h.newEnv(e, 1, 5);
    _ = try h.newCell(.{ .number = 1 });
    h.rollback(m);
    try testing.expectEqual(before, h.bytes); // charges given back exactly
}

test "allocation failure leaves the accounting unchanged" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var h = Heap.init(failing.allocator(), .{});
    defer h.deinit();
    try testing.expectError(error.OutOfMemory, h.ascii("x"));
    try testing.expectEqual(@as(usize, 0), h.bytes);
}
