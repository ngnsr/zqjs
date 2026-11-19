//! The runtime heap (DESIGN_DECISIONS D7): the only code that allocates runtime values.
//!
//! Every object is linked into one of two lists (M8.1, generational, non-moving): `young`
//! (every new object) and `old` (everything that survived a collection). Nothing moves:
//! promotion relinks an object and sets its `old` bit.
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
//! write barrier has one place to hook into. M8.1's barrier keeps the remembered set: an
//! old object that stores a young reference is recorded, so a minor collection can find
//! young objects reachable only through old ones (GC_DESIGN.md §15). `tests/gc_test.zig`
//! greps for raw stores.

const std = @import("std");
const Allocator = std.mem.Allocator;
/// `-Dgc-stress` (GC_DESIGN §11): collect at every safepoint, turn freed objects into
/// tombstones, verify the heap after every collection. In any build mode, ReleaseSafe too.
pub const gc_stress = @import("build_options").gc_stress;
/// `-Dgc-mutation` (tests only: `zig build gc-mutants`): one deliberately broken piece of
/// the generational collector. Each `mutation:` test in tests/gc_test.zig must see the
/// verifier catch its mutant; `.none` everywhere else.
pub const Mutation = enum { none, no_element_barrier, no_card_set, keep_remembered_bit, clean_first_bitmap, minor_frees_atoms, no_prop_card_set, no_dirty_on_remove, clean_first_prop_bitmap };
pub const mutation: Mutation = std.meta.stringToEnum(Mutation, @import("build_options").gc_mutation) orelse @compileError("unknown -Dgc-mutation");
const limits_mod = @import("../limits.zig");
const Limits = limits_mod.Limits;
const Limit = limits_mod.Limit;
const card_elements = limits_mod.card_elements;
const Value = @import("value.zig").Value;
const Builtin = @import("builtin_names.zig").Builtin;
const regex = @import("../regex.zig");

pub const Error = error{ LimitExceeded, OutOfMemory };

pub const per_allocation_overhead = 16;

pub const Obj = struct {
    kind: Kind,
    /// The list of every object (the sweep list).
    next: ?*Obj,
    /// Set during a collection's mark phase; cleared by the sweep (D8).
    marked: bool = false,
    /// On the `old` list: survived a collection (M8.1). Never cleared.
    old: bool = false,
    /// An old object on the remembered list (it stored a young reference since the last
    /// collection). The list is linked through `gray_next`, free between collections.
    remembered: bool = false,
    /// The gray list while marking: intrusive, so marking never allocates (D9). Between
    /// collections, the remembered list (M8.1).
    gray_next: ?*Obj = null,
    /// Stress builds only: an allocation number, and the kind a tombstone used to be.
    debug: Debug = if (gc_stress) .{} else {},

    pub const Kind = enum {
        string,
        cell,
        closure,
        env,
        object,
        coroutine,
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

/// Lazily allocated own-property table, `.prototype` box, and lexical `this` for `Closure` (M31, D62).
pub const ClosureMeta = struct {
    props: std.AutoArrayHashMapUnmanaged(*String, Property) = .empty,
    /// On a constructable user closure: null until `.prototype` is lazily materialized
    /// or explicitly overwritten (`F.prototype = v`).
    prototype: ?Value = null,
    /// Lexical `this` captured when an arrow function closure is created inside a method/ctor.
    lexical_this: ?Value = null,
    /// Custom `[[Prototype]]` for derived class constructors (`Object.getPrototypeOf(Derived) === Base`).
    proto: ?Value = null,
    /// `[[HomeObject]]` for class methods (`C.prototype` or `C` for static methods), used by `super.prop`.
    home_object: ?Value = null,
};

/// Bound function payload created by `Function.prototype.bind` (M31, D62).
pub const BoundClosure = struct {
    target: Value,
    bound_this: Value,
    bound_args: []Value,
    name: *const String,
    length: u16,
};

/// A function value. Each engine creates and reads only its own variant; the payload
/// pointers are opaque here so the heap does not depend on the AST or the bytecode.
pub const Closure = struct {
    obj: Obj,
    meta: ?*ClosureMeta = null,
    impl: union(enum) {
        /// `proto: *const bytecode.Proto`; `captures` filled by `make_closure`.
        vm: struct { proto: *const anyopaque, captures: []*Cell },
        /// `func: *const ast.Function`; `env` is the environment it was created in.
        tree: struct { func: *const anyopaque, env: ?*Env },
        /// Native Promise resolve/reject capability (M18).
        promise_cap: struct { promise: *Object, is_reject: bool },
        /// Native closure with a bound environment object (M19).
        native_closure: struct { func: *const anyopaque, env: *Object },
        /// Bound function created by `Function.prototype.bind` (M31, D62).
        bound: *BoundClosure,
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

/// Insertion-ordered hash table with SameValueZero key equality, shared by Map and Set (M14).
pub const OrderedTable = struct {
    pub const Entry = struct {
        key: Value,
        value: Value,
        alive: bool,
    };

    const IndexContext = struct {
        entries: []const Entry,
        pub fn hash(ctx: @This(), idx: usize) u64 {
            return hashValue(ctx.entries[idx].key);
        }
        pub fn eql(ctx: @This(), a: usize, b: usize) bool {
            return sameValueZero(ctx.entries[a].key, ctx.entries[b].key);
        }
    };

    const LookupContext = struct {
        entries: []const Entry,
        pub fn hash(_: @This(), k: Value) u64 {
            return hashValue(k);
        }
        pub fn eql(ctx: @This(), k: Value, idx: usize) bool {
            return sameValueZero(k, ctx.entries[idx].key);
        }
    };

    entries: std.ArrayList(Entry) = .empty,
    index: std.HashMapUnmanaged(usize, void, IndexContext, std.hash_map.default_max_load_percentage) = .empty,
    live_count: usize = 0,

    pub fn deinit(t: *OrderedTable, alloc: Allocator) void {
        t.entries.deinit(alloc);
        t.index.deinit(alloc);
        t.* = .{};
    }

    pub fn get(t: *const OrderedTable, k: Value) ?Value {
        const idx = t.index.getKeyAdapted(k, LookupContext{ .entries = t.entries.items }) orelse return null;
        return t.entries.items[idx].value;
    }

    pub fn has(t: *const OrderedTable, k: Value) bool {
        return t.index.getKeyAdapted(k, LookupContext{ .entries = t.entries.items }) != null;
    }

    pub fn set(t: *OrderedTable, h: *Heap, owner: *Object, k_in: Value, v: Value) Error!void {
        const k = if (k_in == .number and k_in.number == 0) Value{ .number = 0.0 } else k_in;
        if (t.index.getKeyAdapted(k, LookupContext{ .entries = t.entries.items })) |idx| {
            h.barrier(&owner.obj, t.entries.items[idx].value, v);
            t.entries.items[idx].value = v;
            return;
        }
        const idx = t.entries.items.len;
        const alloc = h.allocator();
        t.entries.append(alloc, .{ .key = k, .value = v, .alive = true }) catch |e| return h.failed(e);
        errdefer _ = t.entries.pop();
        t.index.putContext(alloc, idx, {}, IndexContext{ .entries = t.entries.items }) catch |e| return h.failed(e);
        t.live_count += 1;
        h.barrier(&owner.obj, null, k);
        h.barrier(&owner.obj, null, v);
    }

    pub fn delete(t: *OrderedTable, k: Value) bool {
        const idx = t.index.getKeyAdapted(k, LookupContext{ .entries = t.entries.items }) orelse return false;
        _ = t.index.removeAdapted(k, LookupContext{ .entries = t.entries.items });
        t.entries.items[idx] = .{ .key = .undefined, .value = .undefined, .alive = false };
        t.live_count -= 1;
        return true;
    }

    pub fn clear(t: *OrderedTable) void {
        t.index.clearRetainingCapacity();
        // Preserve `entries.items.len` with dead tombstones so active iterators keep their
        // cursor and can still visit entries inserted after `clear()`.
        for (t.entries.items) |*e| e.* = .{ .key = .undefined, .value = .undefined, .alive = false };
        t.live_count = 0;
    }
};

pub fn sameValueZero(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .undefined, .null => true,
        .boolean => |x| x == b.boolean,
        .number => |x| (x == b.number) or (std.math.isNan(x) and std.math.isNan(b.number)),
        .string => |x| std.mem.eql(u16, x.units, b.string.units),
        .native => |x| x == b.native,
        .closure => |x| x == b.closure,
        .object => |x| x == b.object,
    };
}

pub fn hashValue(v: Value) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const tag: u8 = @backingInt(std.meta.activeTag(v));
    hasher.update(&.{tag});
    switch (v) {
        .undefined, .null => {},
        .boolean => |b| hasher.update(&.{@intFromBool(b)}),
        .number => |n| {
            const bits: u64 = if (std.math.isNan(n))
                0x7ff8_0000_0000_0000
            else if (n == 0)
                0
            else
                @bitCast(n);
            hasher.update(std.mem.asBytes(&bits));
        },
        .string => |s| hasher.update(std.mem.sliceAsBytes(s.units)),
        .native => |n| {
            const p: usize = @intFromPtr(n);
            hasher.update(std.mem.asBytes(&p));
        },
        .closure => |c| {
            const p: usize = @intFromPtr(c);
            hasher.update(std.mem.asBytes(&p));
        },
        .object => |o| {
            const p: usize = @intFromPtr(o);
            hasher.update(std.mem.asBytes(&p));
        },
    }
    return hasher.final();
}

pub const IteratorKind = enum {
    map_entries,
    map_keys,
    map_values,
    set_values,
    set_entries,
    array_values,
    array_keys,
    array_entries,
    string_chars,
};

pub const IteratorState = struct {
    target: Value,
    kind: IteratorKind,
    cursor: usize = 0,
    done: bool = false,
};

pub const PromiseStateTag = enum { pending, fulfilled, rejected };

pub const CoroutineVTable = struct {
    trace: *const fn (engine: *anyopaque, visit_ctx: *anyopaque, visit: *const fn (*anyopaque, *Obj) void) void,
    ownedBytes: *const fn (engine: *anyopaque) usize,
    shrink: *const fn (engine: *anyopaque) void,
    destroy: *const fn (engine: *anyopaque) void,
    @"resume": *const anyopaque,
};

pub const Coroutine = struct {
    obj: Obj,
    promise: *Object,
    state: enum { starting, running, suspended, done } = .starting,
    engine: ?*anyopaque = null,
    vtable: *const CoroutineVTable,
    charge: usize = 0,
};

pub const PromiseReaction = struct {
    child: ?*Object,
    on_fulfilled: Value,
    on_rejected: Value,
    coroutine: ?*Coroutine = null,
};

pub const PromiseState = struct {
    state: PromiseStateTag = .pending,
    already_resolved: bool = false,
    result: Value = .undefined,
    reactions: std.ArrayList(PromiseReaction) = .empty,
};

pub const RegExpState = struct {
    program: regex.Program,
    source: *const String,
    flags: *const String,
    global: bool = false,
    last_index: Value = .{ .number = 0 },
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
        /// Insertion-ordered collection storage shared by Map and Set (M14).
        map: OrderedTable,
        set: OrderedTable,
        /// Built-in iterator state (M14.4).
        iterator: IteratorState,
        /// Native Promise state (M18).
        promise: PromiseState,
        /// Compiled RegExp state (M30, D61); boxed so `Object` stays small.
        regexp: *RegExpState,
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
    /// The young generation (new objects, newest first) and the old one (M8.1).
    young: ?*Obj = null,
    old: ?*Obj = null,
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
    nursery_bytes: usize,
    /// When the heap left after a collection (all of it old) reaches this, the next
    /// collection is a major one (M8.1).
    next_major: usize = 0,
    /// The major-growth factor f ∈ {1, 2, 4} (M8.1 AS5, GC_DESIGN.md §15): doubled (to at most 4)
    /// after a major collection that freed under 10% of the heap, back to 1 after one that
    /// freed at least half, unchanged in between. Only byte counts decide it.
    growth: u8 = 1,
    /// Tests pin `growth` by clearing this.
    adapt_growth: bool = true,
    /// Make the next collection a major one (tests; heap pressure).
    major_requested: bool = false,
    /// While a minor collection marks: old objects are not traced.
    in_minor: bool = false,
    /// Old objects that stored a young reference since the last collection, linked
    /// through `gray_next` (M8.1). Each is on it once (`Obj.remembered`).
    remembered: ?*Obj = null,
    /// Card bitmaps of arrays with capacity ≥ `card_elements`: bit i covers elements
    /// [i·card_elements, (i+1)·card_elements). A side table, so Object doesn't grow;
    /// touched only when such an array's capacity grows, on a young store into an old
    /// one, and when a minor collection scans it.
    cards: std.AutoHashMapUnmanaged(*Object, []u64) = .empty,
    /// The same for property tables with ≥ `card_elements` entries (M8.1 P2b): bit i
    /// covers entries [i·card_elements, (i+1)·card_elements), key and value alike. Entry
    /// indices are insertion order; only `removeProperty` shifts them (and dirties).
    prop_cards: std.AutoHashMapUnmanaged(*Object, []u64) = .empty,
    /// Collect at every safepoint, not only when requested (tests; always under -Dgc-stress).
    collect_always: bool = gc_stress,
    /// Run the heap verifier after every collection (always under -Dgc-stress; a
    /// development option otherwise: RunOptions.verify_heap, `zqjs --verify-heap`).
    verify_always: bool = gc_stress,
    /// Bytes charged through `allocator()` (object-internal buffers), for the verifier's
    /// accounting check: `bytes` = Σ live objects' fixed charges + `buffer_bytes`.
    buffer_bytes: usize = 0,
    /// Stress builds: allocation numbers, and collected objects kept as tombstones.
    next_id: u64 = 0,
    tombstones: ?*Obj = null,
    /// The gray list while marking (empty otherwise).
    gray: ?*Obj = null,
    stats: Stats = .{},

    /// An optional observer of collections (the GC report tool). The runtime has no
    /// clock: the observer brings one, and gets one sample per collection. Unset (the
    /// default), collections don't call anything.
    observer: ?Observer = null,

    pub const Observer = struct {
        ctx: *anyopaque,
        /// Monotonic nanoseconds.
        clock: *const fn (ctx: *anyopaque) u64,
        record: *const fn (ctx: *anyopaque, sample: Sample) void,
    };

    /// One collection, as seen by an observer.
    pub const Sample = struct {
        kind: enum { minor, major },
        start_ns: u64,
        duration_ns: u64,
        bytes_before: usize,
        bytes_after: usize,
        /// Objects that survived (were marked) and that were freed, in this collection.
        marked: u64,
        swept: u64,
        /// Minor collections: the part of the pause spent scanning the remembered set.
        remembered_ns: u64 = 0,
        /// The part of the pause spent sweeping (freeing, promoting).
        sweep_ns: u64 = 0,
    };

    /// Deterministic collector statistics (D8): work units, not wall-clock time.
    pub const Stats = struct {
        collections: u64 = 0,
        /// How many of `collections` were minor (M8.1).
        minor: u64 = 0,
        /// Children checked while scanning remembered owners: the remembered-set work.
        remembered_children: u64 = 0,
        /// Cumulative bytes freed by collections.
        bytes_freed: u64 = 0,
        /// Accounted bytes surviving the last collection.
        live_after_last: usize = 0,
        /// Cumulative objects surviving collections, and freed by them.
        marked: u64 = 0,
        swept: u64 = 0,
    };

    pub fn init(gpa: Allocator, limits: Limits) Heap {
        var h: Heap = .{ .gpa = gpa, .max_bytes = limits.max_heap_bytes, .max_string_length = limits.max_string_length, .nursery_bytes = limits.nursery_bytes };
        h.next_major = h.schedule(0);
        h.next_gc = h.nextMinor();
        return h;
    }

    /// Under collect_always (stress), every this-many-th collection is a major one.
    pub const stress_major_every = 64;

    // ---- the collector (D8; GC_DESIGN §6). Runs only at safepoints, by the engine.

    /// The next major-collection trigger after `live` bytes survived a major collection
    /// (D8, M8.1 AS5): grow by `growth` × the live size (at least 256 KiB), but never beyond
    /// half the room left under the limit, or a quarter when `growth` > 1. So small heaps
    /// collect after growing (1 + growth)×, and near the limit each collection needs a
    /// share of the remaining room allocated first: a program filling its heap with live
    /// data collects O(log limit) times. The quarter keeps a burst's worst-case room at
    /// least as large as at growth 1 (the HL2 proof, GC_DESIGN.md §15). Overflow-free: the
    /// result is at most `live + (max − live) / 2 ≤ max`.
    pub fn schedule(h: *const Heap, live: usize) usize {
        const min_growth = 256 * 1024;
        const room = (h.max_bytes -| live) / @as(usize, if (h.growth > 1) 4 else 2);
        return live + @min(@max(live *| h.growth, min_growth), room);
    }

    /// AS5's rule, after a major collection that went from `before` to `after` bytes.
    fn adaptGrowth(h: *Heap, before: usize, after: usize) void {
        if (!h.adapt_growth) return;
        const freed = before - after;
        if (freed *| 10 < before) {
            h.growth = @min(h.growth * 2, 4);
        } else if (freed *| 2 >= before) {
            h.growth = 1;
        }
    }

    /// The next minor-collection trigger: a nursery's worth of allocation, or half the
    /// room left under the limit if that is less (so a heap filling up still collects
    /// O(log limit) times, as in M8).
    fn nextMinor(h: *const Heap) usize {
        return h.bytes + @min(h.nursery_bytes, (h.max_bytes -| h.bytes) / 2);
    }

    /// Whether the next collection is a major one (M8.1 scheduling, GC_DESIGN.md §15).
    pub fn majorDue(h: *const Heap) bool {
        if (h.major_requested or h.stats.live_after_last >= h.next_major) return true;
        return h.collect_always and (h.stats.collections + 1) % stress_major_every == 0;
    }

    /// Marks `obj` and queues it for scanning, once. A minor collection doesn't trace
    /// old objects: what they reach that is young, the remembered set reaches.
    pub fn markObj(h: *Heap, obj: *Obj) void {
        obj.checkLive(); // a root or an edge to a collected object (stress builds)
        if (obj.marked or (h.in_minor and obj.old)) return;
        obj.marked = true;
        obj.gray_next = h.gray;
        h.gray = obj;
    }

    pub fn markValue(h: *Heap, v: Value) void {
        visitValue(v, h, markObj);
    }

    /// One collection (D8, M8.1): minor or major as `majorDue` says. Minor: mark from the
    /// remembered set and the roots without tracing old objects, sweep only `young`.
    /// Major: mark everything, rebuild the weak atom table, sweep both lists. Either way
    /// every survivor ends up old, so afterwards `young` and the remembered set are empty.
    /// Allocates nothing and can't fail (I4).
    pub fn collect(h: *Heap, roots: anytype, comptime markRoots: fn (@TypeOf(roots), *Heap) void) void {
        const major = h.majorDue();
        if (h.verify_always) h.verify() catch |e| std.debug.panic("zqjs GC bug: heap verification failed before a collection: {s}", .{@errorName(e)});
        const start: u64 = if (h.observer) |o| o.clock(o.ctx) else 0;
        const bytes_before = h.bytes;
        const marked_before = h.stats.marked;
        const swept_before = h.stats.swept;
        var remembered_ns: u64 = 0;
        var sweep_start: u64 = 0;
        defer if (h.observer) |o| o.record(o.ctx, .{
            .kind = if (major) .major else .minor,
            .start_ns = start,
            .duration_ns = o.clock(o.ctx) - start,
            .bytes_before = bytes_before,
            .bytes_after = h.bytes,
            .marked = h.stats.marked - marked_before,
            .swept = h.stats.swept - swept_before,
            .remembered_ns = remembered_ns,
            .sweep_ns = o.clock(o.ctx) - sweep_start,
        });
        std.debug.assert(h.gray == null);
        if (major) {
            h.forgetRemembered(); // a major collection traces everything anyway
        } else {
            h.in_minor = true;
            const t0: u64 = if (h.observer) |o| o.clock(o.ctx) else 0;
            h.scanRemembered();
            if (h.observer) |o| remembered_ns = o.clock(o.ctx) - t0;
        }
        markRoots(roots, h);
        // Drain: each gray object's children (D38's edges), iteratively, never recursively.
        while (h.gray) |obj| {
            h.gray = obj.gray_next;
            obj.gray_next = null;
            forEachChild(obj, h, markObj);
        }
        h.in_minor = false;
        if (major) {
            // Weak atoms (D11, I6): rebuild the table from the marked atoms, before any atom
            // is freed. Walking the lists (not the table) keeps the rebuild deterministic,
            // and reinserting at most as many entries as were there needs no allocation.
            // A minor collection never frees an atom (below), so only here can one go.
            h.atoms.clearRetainingCapacity();
            for ([_]?*Obj{ h.young, h.old }) |list| {
                var it = list;
                while (it) |obj| : (it = obj.next) {
                    if (obj.kind != .string or !obj.marked) continue;
                    const str: *String = @fieldParentPtr("obj", obj);
                    if (str.atom != null) h.atoms.putAssumeCapacityNoClobber(str, {});
                }
            }
            if (h.atoms.count() == 0) h.atoms.clearAndFree(h.allocator());
        }
        const before = h.bytes;
        if (h.observer) |o| sweep_start = o.clock(o.ctx);
        // A major collection sweeps the old list first: survivors promoted below arrive
        // there unmarked.
        if (major) {
            var link: *?*Obj = &h.old;
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
        }
        // Sweep the young: survivors are promoted (relinked, never moved). In a minor
        // collection an unmarked atom is promoted too, not freed: the table still holds
        // it. Promotion is not marking: a string has no children, so it keeps nothing else.
        var it = h.young;
        h.young = null;
        while (it) |obj| {
            it = obj.next;
            if (obj.marked or (!major and isAtom(obj) and mutation != .minor_frees_atoms)) {
                obj.marked = false;
                obj.old = true;
                obj.next = h.old;
                h.old = obj;
                h.stats.marked += 1;
            } else {
                if (gc_stress) h.entomb(obj) else h.destroy(obj);
                h.stats.swept += 1;
            }
        }
        if (major) {
            h.adaptGrowth(bytes_before, h.bytes);
            h.next_major = h.schedule(h.bytes);
            h.major_requested = false;
        } else h.stats.minor += 1;
        h.stats.collections += 1;
        h.stats.bytes_freed += before - h.bytes;
        h.stats.live_after_last = h.bytes;
        h.next_gc = h.nextMinor();
        h.collect_requested = false;
        if (h.verify_always) h.verifyCollected() catch |e| std.debug.panic("zqjs GC bug: heap verification failed after a collection: {s}", .{@errorName(e)});
    }

    fn isAtom(obj: *Obj) bool {
        return obj.kind == .string and @as(*String, @fieldParentPtr("obj", obj)).atom != null;
    }

    /// Minor collection, first step: mark the young children of every remembered owner,
    /// emptying the list. An object with cards has only its dirty cards scanned (each card
    /// scanned, then cleared): property cards over its entries, element cards over an
    /// array's elements. Without a bitmap, that part is scanned whole.
    fn scanRemembered(h: *Heap) void {
        var scan: RememberedScan = .{ .h = h };
        while (h.remembered) |owner| {
            h.remembered = owner.gray_next;
            owner.gray_next = null;
            if (mutation != .keep_remembered_bit) owner.remembered = false;
            if (owner.kind != .object) {
                forEachChild(owner, &scan, RememberedScan.child);
                continue;
            }
            const o: *Object = @fieldParentPtr("obj", owner);
            if (o.proto) |p| scan.child(&p.obj);
            if (h.prop_cards.get(o)) |words| {
                scanDirty(words, o.props.count(), &scan, o, RememberedScan.entries);
            } else scan.entries(o, 0, o.props.count());
            switch (o.kind) {
                .ordinary => {},
                .array => |elements| if (h.cards.get(o)) |words| {
                    scanDirty(words, elements.items.len, &scan, o, RememberedScan.elements);
                } else scan.elements(o, 0, elements.items.len),
                .map, .set => |table| for (table.entries.items) |e| {
                    if (!e.alive) continue;
                    visitValue(e.key, &scan, RememberedScan.child);
                    visitValue(e.value, &scan, RememberedScan.child);
                },
                .iterator => |it| visitValue(it.target, &scan, RememberedScan.child),
                .promise => |pr| {
                    visitValue(pr.result, &scan, RememberedScan.child);
                    for (pr.reactions.items) |rx| {
                        if (rx.child) |ch| RememberedScan.child(&scan, &ch.obj);
                        if (rx.coroutine) |co| RememberedScan.child(&scan, &co.obj);
                        visitValue(rx.on_fulfilled, &scan, RememberedScan.child);
                        visitValue(rx.on_rejected, &scan, RememberedScan.child);
                    }
                },
                .regexp => |re| {
                    RememberedScan.child(&scan, @constCast(&re.source.obj));
                    RememberedScan.child(&scan, @constCast(&re.flags.obj));
                    visitValue(re.last_index, &scan, RememberedScan.child);
                },
            }
        }
    }

    const RememberedScan = struct {
        h: *Heap,
        fn child(c: *RememberedScan, obj: *Obj) void {
            c.h.stats.remembered_children += 1;
            c.h.markObj(obj);
        }
        fn entries(c: *RememberedScan, o: *Object, lo: usize, hi: usize) void {
            for (o.props.keys()[lo..hi], o.props.values()[lo..hi]) |k, p| {
                c.child(&k.obj);
                visitValue(p.value, c, child);
            }
        }
        fn elements(c: *RememberedScan, o: *Object, lo: usize, hi: usize) void {
            for (elementsOf(o).items[lo..hi]) |v| visitValue(v, c, child);
        }
    };

    /// Calls `visit(scan, o, lo, hi)` for each dirty card's range, clamped to `len` (cards
    /// past a pop, shrink or delete cover nothing), then clears each word it scanned.
    fn scanDirty(words: []u64, len: usize, scan: *RememberedScan, o: *Object, comptime visit: fn (*RememberedScan, *Object, usize, usize) void) void {
        for (words, 0..) |*w, wi| {
            var word = w.*;
            while (word != 0) : (word &= word - 1) {
                const lo = (wi * 64 + @ctz(word)) * card_elements;
                if (lo < len) visit(scan, o, lo, @min(lo + card_elements, len));
            }
            w.* = 0;
        }
    }

    /// Major collection, first step: empty the remembered list and every card of its
    /// owners (cards are dirty only on remembered owners).
    fn forgetRemembered(h: *Heap) void {
        while (h.remembered) |owner| {
            h.remembered = owner.gray_next;
            owner.gray_next = null;
            owner.remembered = false;
            if (owner.kind != .object) continue;
            const o: *Object = @fieldParentPtr("obj", owner);
            if (h.cards.get(o)) |words| @memset(words, 0);
            if (h.prop_cards.get(o)) |words| @memset(words, 0);
        }
    }

    pub const VerifyError = error{
        GrayListNotEmpty,
        EdgeToCollectedObject,
        CollectedObjectInList,
        AtomTableHoldsCollectedObject,
        AtomTableHoldsNonAtom,
        AccountingMismatch,
        /// I-gen1: an object on the wrong list for its `old` bit.
        WrongGenerationList,
        /// I-gen2: an old object holds a young reference but isn't remembered, or (a
        /// carded array) the card covering that element is clean: a missing barrier.
        UnrememberedOldToYoungEdge,
        CleanCardOverYoungElement,
        CleanCardOverYoungProperty,
        /// I-gen4: the remembered list isn't exactly the objects with `remembered` set,
        /// each old and live, each once.
        RememberedListCorrupt,
        /// I-gen3 (after a collection): something young, remembered or dirty is left.
        NurseryNotEmpty,
        RememberedSetNotEmpty,
        DirtyCardAfterCollection,
    };

    /// The heap verifier (GC_DESIGN §11; before and after every collection in stress
    /// builds, and callable from tests): the gray list is empty; no live object references
    /// a collected one (roots are checked as they are marked, `markObj`); the atom table
    /// holds only live atoms; the accounting is exact: `bytes` = Σ every live object's
    /// fixed charge + every buffer byte charged through `allocator()`; and the generational
    /// invariants I-gen1, 2 and 4 (GC_DESIGN.md §15). Allocates nothing.
    pub fn verify(h: *const Heap) VerifyError!void {
        if (h.gray != null) return error.GrayListNotEmpty;
        var sum: usize = h.buffer_bytes;
        var remembered: usize = 0;
        const Check = struct {
            bad: bool = false,
            young: bool = false,
            fn edge(c: *@This(), child: *Obj) void {
                if (child.kind == .dead) c.bad = true;
                if (!child.old) c.young = true;
            }
        };
        for ([_]?*Obj{ h.young, h.old }, [_]bool{ false, true }) |list, old| {
            var it = list;
            while (it) |obj| : (it = obj.next) {
                if (obj.kind == .dead) return error.CollectedObjectInList;
                if (obj.old != old) return error.WrongGenerationList;
                if (obj.remembered) remembered += 1;
                sum += fixedCharge(obj);
                if (obj.kind == .coroutine) {
                    sum += @as(*const Coroutine, @alignCast(@fieldParentPtr("obj", obj))).charge;
                }
                var c: Check = .{};
                forEachChild(obj, &c, Check.edge);
                if (c.bad) return error.EdgeToCollectedObject;
                if (old and c.young) {
                    if (!obj.remembered) return error.UnrememberedOldToYoungEdge;
                    if (obj.kind == .object) try h.checkCards(@fieldParentPtr("obj", obj));
                }
            }
        }
        // I-gen4: the walk is bounded by the count, so a cycle can't hang the verifier.
        var listed: usize = 0;
        var r = h.remembered;
        while (r) |obj| : (r = obj.gray_next) {
            listed += 1;
            if (listed > remembered or obj.kind == .dead or !obj.old or !obj.remembered) return error.RememberedListCorrupt;
        }
        if (listed != remembered) return error.RememberedListCorrupt;
        var atoms = h.atoms.keyIterator();
        while (atoms.next()) |k| {
            if (k.*.obj.kind == .dead) return error.AtomTableHoldsCollectedObject;
            if (k.*.atom == null) return error.AtomTableHoldsNonAtom;
        }
        if (sum != h.bytes) return error.AccountingMismatch;
    }

    /// I-gen2 for carded objects (PC8): walks every edge itself, and each young element,
    /// key or value must sit under a dirty card. The bitmap is only ever the thing checked.
    fn checkCards(h: *const Heap, o: *Object) VerifyError!void {
        if (h.prop_cards.get(o)) |words| {
            for (o.props.keys(), o.props.values(), 0..) |k, p, i| {
                if ((!k.obj.old or isYoung(p.value)) and !cardSet(words, i)) return error.CleanCardOverYoungProperty;
            }
        }
        if (o.kind == .array) if (h.cards.get(o)) |words| {
            for (elementsOf(o).items, 0..) |v, i| {
                if (isYoung(v) and !cardSet(words, i)) return error.CleanCardOverYoungElement;
            }
        };
    }

    fn cardSet(words: []const u64, i: usize) bool {
        const card = i / card_elements;
        return words[card / 64] & (@as(u64, 1) << @intCast(card % 64)) != 0;
    }

    fn setCard(words: []u64, i: usize) void {
        const card = i / card_elements;
        words[card / 64] |= @as(u64, 1) << @intCast(card % 64);
    }

    /// `verify`, plus what must hold right after a collection (I-gen3): nothing young,
    /// nothing remembered, no dirty card.
    pub fn verifyCollected(h: *const Heap) VerifyError!void {
        try h.verify();
        if (h.young != null) return error.NurseryNotEmpty;
        if (h.remembered != null) return error.RememberedSetNotEmpty;
        for ([_]*const std.AutoHashMapUnmanaged(*Object, []u64){ &h.cards, &h.prop_cards }) |table| {
            var it = table.valueIterator();
            while (it.next()) |words| for (words.*) |w| if (w != 0) return error.DirtyCardAfterCollection;
        }
    }

    pub fn deinit(h: *Heap) void {
        h.atoms.deinit(h.allocator());
        for ([_]?*Obj{ h.young, h.old }) |list| {
            var it = list;
            while (it) |obj| {
                it = obj.next;
                h.destroy(obj);
            }
        }
        std.debug.assert(h.cards.count() == 0 and h.prop_cards.count() == 0); // gone with their objects (release)
        h.cards.deinit(h.allocator());
        h.prop_cards.deinit(h.allocator());
        var t = h.tombstones;
        while (t) |obj| {
            t = obj.next;
            h.freeStruct(obj, if (gc_stress) obj.debug.was else unreachable);
        }
        h.* = undefined;
    }

    /// The current newest object, for `rollback`.
    pub fn mark(h: *const Heap) ?*Obj {
        return h.young;
    }

    /// Frees every object allocated since `m` (a value of `mark()`), newest first, and
    /// gives their charge back to the accounting. Used when a compilation fails: the strings it created are
    /// unreachable, so they are freed at once instead of lingering until `deinit`.
    /// Only valid if nothing allocated since `m` is referenced anywhere, and no collection
    /// ran in between (it would have promoted them).
    pub fn rollback(h: *Heap, m: ?*Obj) void {
        while (h.young != m) {
            const obj = h.young.?; // `m` must be in the list
            if (obj.kind == .string) {
                const str: *String = @fieldParentPtr("obj", obj);
                if (str.atom != null) _ = h.atoms.remove(str);
            }
            h.young = obj.next;
            h.destroy(obj);
        }
        if (h.atoms.count() == 0) h.atoms.clearAndFree(h.allocator());
    }

    // ---- objects (M7)

    pub fn newObject(h: *Heap, proto: ?*Object) Error!*Object {
        const charge = try h.reserve(@sizeOf(Object), 0, 1);
        errdefer h.bytes -= charge;
        const o = try h.gpa.create(Object);
        o.* = .{ .obj = h.newHeader(.object), .proto = proto };
        h.young = &o.obj;
        return o;
    }

    pub fn newArray(h: *Heap, proto: ?*Object) Error!*Object {
        const o = try h.newObject(proto);
        o.kind = .{ .array = .empty };
        return o;
    }

    pub fn newMap(h: *Heap, proto: ?*Object) Error!*Object {
        const o = try h.newObject(proto);
        o.kind = .{ .map = .{} };
        return o;
    }

    pub fn mapGet(o: *const Object, key: Value) ?Value {
        return o.kind.map.get(key);
    }

    pub fn mapHas(o: *const Object, key: Value) bool {
        return o.kind.map.has(key);
    }

    pub fn mapSet(h: *Heap, o: *Object, key: Value, val: Value) Error!void {
        try o.kind.map.set(h, o, key, val);
    }

    pub fn mapDelete(o: *Object, key: Value) bool {
        return o.kind.map.delete(key);
    }

    pub fn mapClear(o: *Object) void {
        o.kind.map.clear();
    }

    pub fn newSet(h: *Heap, proto: ?*Object) Error!*Object {
        const o = try h.newObject(proto);
        o.kind = .{ .set = .{} };
        return o;
    }

    pub fn setHas(o: *const Object, val: Value) bool {
        return o.kind.set.has(val);
    }

    pub fn setAdd(h: *Heap, o: *Object, val: Value) Error!void {
        try o.kind.set.set(h, o, val, .undefined);
    }

    pub fn setDelete(o: *Object, val: Value) bool {
        return o.kind.set.delete(val);
    }

    pub fn setClear(o: *Object) void {
        o.kind.set.clear();
    }

    pub fn newIterator(h: *Heap, proto: ?*Object, target: Value, kind: IteratorKind) Error!*Object {
        const o = try h.newObject(proto);
        o.kind = .{ .iterator = .{ .target = target, .kind = kind } };
        h.barrier(&o.obj, null, target);
        return o;
    }

    pub fn newPromise(h: *Heap, proto: ?*Object) Error!*Object {
        const o = try h.newObject(proto);
        o.kind = .{ .promise = .{} };
        return o;
    }

    pub fn newRegExp(
        h: *Heap,
        proto: ?*Object,
        program: regex.Program,
        source: *const String,
        flags: *const String,
        global: bool,
    ) Error!*Object {
        const state = h.allocator().create(RegExpState) catch |e| return h.failed(e);
        errdefer h.allocator().destroy(state);
        const o = try h.newObject(proto);
        state.* = .{
            .program = program,
            .source = source,
            .flags = flags,
            .global = global,
            .last_index = .{ .number = 0 },
        };
        o.kind = .{ .regexp = state };
        h.barrier(&o.obj, null, .{ .string = source });
        h.barrier(&o.obj, null, .{ .string = flags });
        return o;
    }

    pub fn storeRegExpLastIndex(h: *Heap, o: *Object, val: Value) void {
        const old = o.kind.regexp.last_index;
        o.kind.regexp.last_index = val;
        h.barrier(&o.obj, old, val);
    }

    // ---- the store API (GC_DESIGN §7, I3)
    //
    // After construction, every reference written into a heap object goes through one of
    // these. Each knows the owner, the old value and the new one: what an insertion barrier
    // (Dijkstra), a deletion barrier (Yuasa) or a generational remembered set needs. M8.1's
    // `barrier` keeps the remembered set; tests/gc_test.zig scans the sources for raw stores.

    /// `o[key] = value`: updates an own property in place (keeping its position and
    /// enumerability) or adds an enumerable one at the end (D13).
    pub fn storeProperty(h: *Heap, o: *Object, key: *String, value: Value) Error!void {
        o.obj.checkLive();
        try h.growPropCards(o);
        const gop = o.props.getOrPut(h.allocator(), key) catch |e| return h.failed(e);
        const old: ?Value = if (gop.found_existing) gop.value_ptr.value else null;
        if (gop.found_existing) gop.value_ptr.value = value else gop.value_ptr.* = .{ .value = value };
        if (!gop.found_existing) h.barrier(&o.obj, null, .{ .string = key }); // the key is a child too
        h.barrier(&o.obj, old, value);
        h.propertyBarrier(o, gop.index, key, value);
    }

    /// Adds or replaces a property with explicit attributes (built-in method tables).
    pub fn defineProperty(h: *Heap, o: *Object, key: *String, p: Property) Error!void {
        o.obj.checkLive();
        try h.growPropCards(o);
        const gop = o.props.getOrPut(h.allocator(), key) catch |e| return h.failed(e);
        const old: ?Value = if (gop.found_existing) gop.value_ptr.value else null;
        gop.value_ptr.* = p;
        if (!gop.found_existing) h.barrier(&o.obj, null, .{ .string = key }); // the key is a child too
        h.barrier(&o.obj, old, p.value);
        h.propertyBarrier(o, gop.index, key, p.value);
    }

    /// `delete o[key]` for an own property; keeps the others' order (O(n), D13). Every
    /// later entry moves down one index, so on a remembered carded table every card from
    /// the removed entry's on is dirtied (PC2): a young entry may have moved under a clean
    /// one. An owner that isn't remembered has nothing young to move.
    pub fn removeProperty(h: *Heap, o: *Object, key: *String) void {
        const index = o.props.getIndex(key) orelse return;
        const old = o.props.values()[index];
        o.props.orderedRemoveAt(index);
        h.barrier(&o.obj, old.value, null);
        if (!o.obj.remembered or mutation == .no_dirty_on_remove) return;
        const words = h.prop_cards.get(o) orelse return;
        const first = index / card_elements;
        words[first / 64] |= ~@as(u64, 0) << @intCast(first % 64);
        for (words[first / 64 + 1 ..]) |*w| w.* = ~@as(u64, 0);
    }

    /// Before an insertion: a table about to reach `card_elements` entries gets its
    /// bitmap, and one about to outgrow its bitmap gets a bigger one (PC3). Entry counts
    /// grow one at a time, so checking at exactly those counts sees every crossing. Grown
    /// before the table: if this fails nothing has changed, and if the table then can't
    /// grow, a bigger bitmap is harmless. A first bitmap for a remembered owner is all
    /// dirty (the hole rule, as for arrays).
    fn growPropCards(h: *Heap, o: *Object) Error!void {
        const per_word = 64 * card_elements;
        const n = o.props.count() + 1;
        if (n < card_elements or (n != card_elements and (n - 1) % per_word != 0)) return;
        const needed = (n + per_word - 1) / per_word;
        const gop = h.prop_cards.getOrPut(h.allocator(), o) catch |e| return h.failed(e);
        const fresh = !gop.found_existing;
        if (fresh) gop.value_ptr.* = &.{};
        const old = gop.value_ptr.*;
        if (old.len >= needed) return;
        const new = h.allocator().alloc(u64, @max(needed, 2 * old.len)) catch |e| {
            if (fresh) h.prop_cards.removeByPtr(gop.key_ptr);
            return h.failed(e);
        };
        @memcpy(new[0..old.len], old);
        @memset(new[old.len..], if (fresh and o.obj.remembered and mutation != .clean_first_prop_bitmap) std.math.maxInt(u64) else 0);
        h.allocator().free(old);
        gop.value_ptr.* = new;
    }

    /// A property store's card (PC6): after `barrier`, a young key or value in an old
    /// carded table dirties the card of entry `index`, new entry or updated one alike.
    /// Looked up whenever an old owner stores something young: a table can keep its
    /// bitmap after deletes take it below `card_elements` entries.
    inline fn propertyBarrier(h: *Heap, o: *Object, index: usize, key: *String, value: Value) void {
        if (!o.obj.old or (key.obj.old and !isYoung(value))) return;
        if (mutation == .no_prop_card_set) return;
        const words = h.prop_cards.get(o) orelse return; // no bitmap: scanned whole
        setCard(words, index);
    }

    pub fn appendElement(h: *Heap, arr: *Object, value: Value) Error!void {
        const elements = elementsOf(arr);
        try h.growElements(arr, elements.items.len + 1);
        elements.appendAssumeCapacity(value);
        h.barrier(&arr.obj, null, value);
        h.elementBarrier(arr, elements.items.len - 1, value);
    }

    pub fn appendElements(h: *Heap, arr: *Object, values: []const Value) Error!void {
        const elements = elementsOf(arr);
        const first = elements.items.len;
        try h.growElements(arr, std.math.add(usize, first, values.len) catch return h.exceeded(.heap_bytes));
        elements.appendSliceAssumeCapacity(values);
        for (values, first..) |v, i| {
            h.barrier(&arr.obj, null, v);
            h.elementBarrier(arr, i, v);
        }
    }

    /// `arr[i] = value` for an existing element (i < length).
    pub fn storeElement(h: *Heap, arr: *Object, i: usize, value: Value) void {
        const slot = &elementsOf(arr).items[i];
        const old = slot.*;
        slot.* = value;
        if (mutation == .no_element_barrier) return;
        h.barrier(&arr.obj, old, value);
        h.elementBarrier(arr, i, value);
    }

    /// Makes room for `needed` elements, growing the card bitmap first (GC_DESIGN.md §15): if
    /// the bitmap can't grow nothing has changed, and if the elements can't, a bitmap
    /// that is already big enough is harmless (its new bits are clean).
    fn growElements(h: *Heap, arr: *Object, needed: usize) Error!void {
        const elements = elementsOf(arr);
        if (elements.capacity >= needed) return;
        const capacity = std.ArrayList(Value).growCapacity(needed);
        if (capacity >= card_elements) try h.growCards(arr, capacity);
        elements.ensureTotalCapacityPrecise(h.allocator(), capacity) catch |e| return h.failed(e);
    }

    /// Makes `arr`'s card bitmap cover `capacity` elements. A first bitmap for an array
    /// that is already remembered starts all dirty: the array was remembered as a whole,
    /// and a clean bitmap would hide the young element that put it there.
    fn growCards(h: *Heap, arr: *Object, capacity: usize) Error!void {
        const words = (capacity + card_elements * 64 - 1) / (card_elements * 64);
        const gop = h.cards.getOrPut(h.allocator(), arr) catch |e| return h.failed(e);
        const fresh = !gop.found_existing;
        if (fresh) gop.value_ptr.* = &.{};
        const old = gop.value_ptr.*;
        if (old.len >= words) return;
        const new = h.allocator().alloc(u64, words) catch |e| {
            if (fresh) h.cards.removeByPtr(gop.key_ptr);
            return h.failed(e);
        };
        @memcpy(new[0..old.len], old);
        @memset(new[old.len..], if (fresh and arr.obj.remembered and mutation != .clean_first_bitmap) std.math.maxInt(u64) else 0);
        h.allocator().free(old);
        gop.value_ptr.* = new;
    }

    /// An element store's card: after `barrier`, a young value in an old carded array
    /// dirties the card covering index `i`.
    inline fn elementBarrier(h: *Heap, arr: *Object, i: usize, new: Value) void {
        if (!arr.obj.old or !isYoung(new) or elementsOf(arr).capacity < card_elements) return;
        h.remember(&arr.obj);
        if (mutation == .no_card_set) return;
        const words = h.cards.get(arr) orelse return; // no bitmap: scanned whole
        setCard(words, i);
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

    pub fn ensureClosureMeta(h: *Heap, c: *Closure) Error!*ClosureMeta {
        c.obj.checkLive();
        if (c.meta) |m| return m;
        const m = h.allocator().create(ClosureMeta) catch |e| return h.failed(e);
        m.* = .{};
        c.meta = m;
        return m;
    }

    pub fn storeClosurePrototype(h: *Heap, c: *Closure, value: Value) Error!void {
        const m = try h.ensureClosureMeta(c);
        const old = m.prototype;
        m.prototype = value;
        h.barrier(&c.obj, old, value);
    }

    pub fn storeClosureProperty(h: *Heap, c: *Closure, key: *String, value: Value) Error!void {
        try h.defineClosureProperty(c, key, .{ .value = value });
    }

    pub fn defineClosureProperty(h: *Heap, c: *Closure, key: *String, prop: Property) Error!void {
        const m = try h.ensureClosureMeta(c);
        const gop = m.props.getOrPut(h.allocator(), key) catch |e| return h.failed(e);
        const old: ?Value = if (gop.found_existing) gop.value_ptr.value else null;
        if (gop.found_existing) gop.value_ptr.value = prop.value else gop.value_ptr.* = prop;
        if (!gop.found_existing) h.barrier(&c.obj, null, .{ .string = key });
        h.barrier(&c.obj, old, prop.value);
    }

    pub fn removeClosureProperty(h: *Heap, c: *Closure, key: *String) void {
        c.obj.checkLive();
        const m = c.meta orelse return;
        const index = m.props.getIndex(key) orelse return;
        const old = m.props.values()[index];
        m.props.orderedRemoveAt(index);
        h.barrier(&c.obj, old.value, null);
    }

    pub fn storeClosureLexicalThis(h: *Heap, c: *Closure, this: Value) Error!void {
        const m = try h.ensureClosureMeta(c);
        const old = m.lexical_this;
        m.lexical_this = this;
        h.barrier(&c.obj, old, this);
    }

    pub fn storeClosureProto(h: *Heap, c: *Closure, proto_val: Value) Error!void {
        const m = try h.ensureClosureMeta(c);
        const old = m.proto;
        m.proto = proto_val;
        h.barrier(&c.obj, old, proto_val);
    }

    pub fn storeClosureHomeObject(h: *Heap, c: *Closure, home: Value) Error!void {
        const m = try h.ensureClosureMeta(c);
        const old = m.home_object;
        m.home_object = home;
        h.barrier(&c.obj, old, home);
    }

    pub fn storeObjectProto(h: *Heap, o: *Object, proto: ?*Object) void {
        const old: ?Value = if (o.proto) |p| .{ .object = p } else null;
        o.proto = proto;
        h.barrier(&o.obj, old, if (proto) |p| .{ .object = p } else null);
    }

    /// The write barrier: `owner` now holds `new` where it held `old` (GC_DESIGN §7). M8.1:
    /// an old owner storing a young reference joins the remembered set. It records owners,
    /// not edges, so a reference overwritten later keeps nothing alive. Never allocates.
    pub inline fn barrier(h: *Heap, owner: *Obj, old: ?Value, new: ?Value) void {
        _ = old;
        // Not the barrier's job, but every store passes here: in stress builds, a store
        // into or of a collected object is caught at the store.
        owner.checkLive();
        const v = new orelse return;
        checkValue(v);
        if (owner.old and isYoung(v)) h.remember(owner);
    }

    /// Puts an old object on the remembered list, once (the bit makes it idempotent).
    pub fn remember(h: *Heap, owner: *Obj) void {
        if (owner.remembered) return;
        owner.remembered = true;
        owner.gray_next = h.remembered;
        h.remembered = owner;
    }

    fn isYoung(v: Value) bool {
        return switch (v) {
            .undefined, .null, .boolean, .number, .native => false,
            .string => |s| !s.obj.old,
            .closure => |c| !c.obj.old,
            .object => |o| !o.obj.old,
        };
    }

    fn elementsOf(arr: *Object) *std.ArrayList(Value) {
        return switch (arr.kind) {
            .array => |*elements| elements,
            .ordinary, .map, .set, .iterator, .promise, .regexp => unreachable, // only arrays have elements
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
        h.young = &c.obj;
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
        h.young = &c.obj;
        return c;
    }

    pub fn newTreeClosure(h: *Heap, func: *const anyopaque, env: ?*Env) Error!*Closure {
        const charge = try h.reserve(@sizeOf(Closure), 0, 2); // same charge as a VM closure
        errdefer h.bytes -= charge;
        const c = try h.gpa.create(Closure);
        c.* = .{ .obj = h.newHeader(.closure), .impl = .{ .tree = .{ .func = func, .env = env } } };
        h.young = &c.obj;
        return c;
    }

    pub fn newPromiseCapability(h: *Heap, promise: *Object, is_reject: bool) Error!*Closure {
        const charge = try h.reserve(@sizeOf(Closure), 0, 2);
        errdefer h.bytes -= charge;
        const c = try h.gpa.create(Closure);
        c.* = .{ .obj = h.newHeader(.closure), .impl = .{ .promise_cap = .{ .promise = promise, .is_reject = is_reject } } };
        h.young = &c.obj;
        return c;
    }

    pub fn newNativeClosure(h: *Heap, func: *const anyopaque, env: *Object) Error!*Closure {
        const charge = try h.reserve(@sizeOf(Closure), 0, 2);
        errdefer h.bytes -= charge;
        const c = try h.gpa.create(Closure);
        c.* = .{ .obj = h.newHeader(.closure), .impl = .{ .native_closure = .{ .func = func, .env = env } } };
        h.young = &c.obj;
        return c;
    }

    pub fn newBoundClosure(
        h: *Heap,
        target: Value,
        bound_this: Value,
        bound_args: []const Value,
        name: *const String,
        length: u16,
    ) Error!*Closure {
        const args_copy = h.allocator().dupe(Value, bound_args) catch |e| return h.failed(e);
        errdefer h.allocator().free(args_copy);
        const b = h.allocator().create(BoundClosure) catch |e| return h.failed(e);
        errdefer h.allocator().destroy(b);
        const charge = try h.reserve(@sizeOf(Closure), 0, 2);
        errdefer h.bytes -= charge;
        const c = try h.gpa.create(Closure);
        b.* = .{
            .target = target,
            .bound_this = bound_this,
            .bound_args = args_copy,
            .name = name,
            .length = length,
        };
        c.* = .{ .obj = h.newHeader(.closure), .impl = .{ .bound = b } };
        h.young = &c.obj;
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
        h.young = &e.obj;
        return e;
    }

    pub fn newCoroutine(h: *Heap, promise: *Object, vtable: *const CoroutineVTable) Error!*Coroutine {
        const charge = try h.reserve(@sizeOf(Coroutine), 0, 1);
        errdefer h.bytes -= charge;
        const co = try h.gpa.create(Coroutine);
        co.* = .{
            .obj = h.newHeader(.coroutine),
            .promise = promise,
            .vtable = vtable,
        };
        h.young = &co.obj;
        return co;
    }

    /// Updates an externally owned byte charge (e.g. a suspended coroutine's engine
    /// memory) against `max_bytes`, failing before mutating `h.bytes` or `charge`.
    pub fn adjustCharge(h: *Heap, charge: *usize, new_charge: usize) Error!void {
        const old = charge.*;
        if (new_charge > old) {
            const delta = new_charge - old;
            const total = std.math.add(usize, h.bytes, delta) catch return h.exceeded(.heap_bytes);
            if (total > h.max_bytes) return h.exceeded(.heap_bytes);
            h.bytes = total;
            if (total > h.next_gc) h.collect_requested = true;
            h.peak = @max(h.peak, total);
            h.allocated += delta;
            charge.* = new_charge;
        } else if (new_charge < old) {
            h.bytes -= old - new_charge;
            charge.* = new_charge;
        }
    }

    pub fn releaseExternalCharge(h: *Heap, charge: *usize) void {
        if (charge.* > 0) {
            h.bytes -= charge.*;
            charge.* = 0;
        }
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
                .tree, .promise_cap, .native_closure, .bound => @sizeOf(Closure) + 2 * per_allocation_overhead,
            },
            .env => @sizeOf(Env) + @as(*const Env, @alignCast(@fieldParentPtr("obj", obj))).values.len * @sizeOf(?Value) + 2 * per_allocation_overhead,
            .object => @sizeOf(Object) + per_allocation_overhead,
            .coroutine => @sizeOf(Coroutine) + per_allocation_overhead,
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
                if (c.meta) |m| {
                    m.props.deinit(h.allocator());
                    h.allocator().destroy(m);
                    c.meta = null;
                }
                switch (c.impl) {
                    .vm => |*v| {
                        h.gpa.free(v.captures);
                        v.captures = &.{};
                    },
                    .tree => |*t| t.env = null,
                    .promise_cap, .native_closure => {},
                    .bound => |b| {
                        h.allocator().free(b.bound_args);
                        h.allocator().destroy(b);
                    },
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
                if (h.prop_cards.fetchRemove(o)) |kv| h.allocator().free(kv.value);
                switch (o.kind) {
                    .ordinary => {},
                    .array => |*elements| {
                        elements.deinit(h.allocator());
                        if (h.cards.fetchRemove(o)) |kv| h.allocator().free(kv.value);
                    },
                    .map, .set => |*table| table.deinit(h.allocator()),
                    .iterator => {},
                    .promise => |*pr| pr.reactions.deinit(h.allocator()),
                    .regexp => |re| {
                        re.program.deinit(h.allocator());
                        h.allocator().destroy(re);
                    },
                }
                o.kind = .ordinary;
                o.proto = null;
            },
            .coroutine => {
                const co: *Coroutine = @fieldParentPtr("obj", obj);
                if (co.engine) |eng| {
                    co.vtable.destroy(eng);
                    co.engine = null;
                }
                h.releaseExternalCharge(&co.charge);
                co.state = .done;
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
            .coroutine => h.gpa.destroy(@as(*Coroutine, @fieldParentPtr("obj", obj))),
            .dead => unreachable,
        }
    }

    /// A new object's header, linked into the object list (with an allocation number in
    /// stress builds).
    fn newHeader(h: *Heap, kind: Obj.Kind) Obj {
        var o: Obj = .{ .kind = kind, .next = h.young };
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
        h.young = &s.obj;
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
            if (c.meta) |m| {
                if (m.prototype) |p| visitValue(p, ctx, visit);
                if (m.lexical_this) |lt| visitValue(lt, ctx, visit);
                if (m.proto) |pr| visitValue(pr, ctx, visit);
                if (m.home_object) |ho| visitValue(ho, ctx, visit);
                for (m.props.keys(), m.props.values()) |k, p| {
                    visit(ctx, &k.obj);
                    visitValue(p.value, ctx, visit);
                }
            }
            switch (c.impl) {
                // The Proto (and its string constants) is not a heap object yet; M8 roots it.
                .vm => |v| for (v.captures) |cell| visit(ctx, &cell.obj),
                .tree => |t| if (t.env) |e| visit(ctx, &e.obj),
                .promise_cap => |pc| visit(ctx, &pc.promise.obj),
                .native_closure => |nc| visit(ctx, &nc.env.obj),
                .bound => |b| {
                    visitValue(b.target, ctx, visit);
                    visitValue(b.bound_this, ctx, visit);
                    for (b.bound_args) |arg| visitValue(arg, ctx, visit);
                    visit(ctx, @constCast(&b.name.obj));
                },
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
                .map, .set => |table| for (table.entries.items) |e| {
                    if (!e.alive) continue;
                    visitValue(e.key, ctx, visit);
                    visitValue(e.value, ctx, visit);
                },
                .iterator => |it| visitValue(it.target, ctx, visit),
                .promise => |pr| {
                    visitValue(pr.result, ctx, visit);
                    for (pr.reactions.items) |rx| {
                        if (rx.child) |ch| visit(ctx, &ch.obj);
                        if (rx.coroutine) |co| visit(ctx, &co.obj);
                        visitValue(rx.on_fulfilled, ctx, visit);
                        visitValue(rx.on_rejected, ctx, visit);
                    }
                },
                .regexp => |re| {
                    visit(ctx, @constCast(&re.source.obj));
                    visit(ctx, @constCast(&re.flags.obj));
                    visitValue(re.last_index, ctx, visit);
                },
            }
        },
        .coroutine => {
            const co: *Coroutine = @fieldParentPtr("obj", obj);
            visit(ctx, &co.promise.obj);
            if (co.state == .suspended) {
                if (co.engine) |eng| {
                    const Ctx = @TypeOf(ctx);
                    var c = ctx;
                    const Thunk = struct {
                        fn call(raw: *anyopaque, child: *Obj) void {
                            const ptr: *Ctx = @ptrCast(@alignCast(raw));
                            visit(ptr.*, child);
                        }
                    };
                    co.vtable.trace(eng, @ptrCast(&c), Thunk.call);
                }
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

    var rx_diag: regex.Diagnostic = .{};
    const rx_prog = try regex.compile(h.allocator(), &.{ 'a', 'b' }, .{}, &rx_diag);
    const rx_src = try h.ascii("ab");
    const rx_flags = try h.ascii("g");
    const rx_last = try h.ascii("0");
    const rx = try h.newRegExp(proto, rx_prog, rx_src, rx_flags, true);
    h.storeRegExpLastIndex(rx, .{ .string = rx_last });
    try Collect.expect(&rx.obj, &.{ &proto.obj, &rx_src.obj, &rx_flags.obj, &rx_last.obj });
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
    try testing.expectEqual(&keep.obj, h.young.?);
    try testing.expectEqual(@as(?*Obj, null), h.young.?.next);
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
