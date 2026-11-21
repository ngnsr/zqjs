//! Host handles (M9.1, D50): values crossing the boundary, GC-safe with explicit
//! ownership. A *slot* stores a `Value` and is rooted while `live`; a *token* (`Handle`)
//! is an independently owned value `{ owner, slot, generation }` naming one slot. Every
//! operation validates owner, bounds, liveness, and 64-bit generation before use, so a
//! released handle is caught deterministically while the runtime is alive — even after
//! its slot has been recycled for a newer handle.
//!
//! Ownership rules (D50):
//! - `mint` and `dup` each allocate an independent slot (reusing `free_slot_head` when
//!   available); `release` marks that slot dead, increments its 64-bit generation, and
//!   returns the slot to the free list (retiring the slot only on `u64` wraparound).
//! - Nothing here runs script code or allocates through the JS heap, so every read and
//!   `release` works while the runtime is poisoned (E7), like `collectGarbage`/`memory`.
//! - Concurrent slot capacity is bounded (`max_tokens`, `Limits.max_handles`) and
//!   accounted: the slot table's allocated bytes are reported in `memory()` (D50).
//! - Validation is by **owner-pointer equality** (a token records the runtime that minted
//!   it): a handle passed to another live runtime panics (D50's identity rule).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Runtime = @import("runtime.zig").Runtime;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const heap = @import("heap.zig");

/// What a handle refers to (D54/Q10's uniform model; objects vs arrays distinguished).
pub const Kind = enum { undefined, null, boolean, number, string, symbol, function, object, array, bigint };

pub fn kindOf(v: Value) Kind {
    return switch (v.unpack()) {
        .undefined => .undefined,
        .null => .null,
        .boolean => .boolean,
        .number => .number,
        .bigint => .bigint,
        .string => .string,
        .symbol => .symbol,
        .native, .closure => .function,
        .object => |o| if (o.kind == .array) .array else .object,
    };
}

/// One independently owned reference to a slot (D50), passed by value as `zqjs.Handle`.
pub const Token = struct {
    /// The runtime that minted it; identity validation is pointer equality.
    owner: *Runtime,
    /// Index into the owner's slot table.
    slot: u32,
    /// The slot's generation when this token was minted. `release` increments the slot's
    /// generation immediately, so stale tokens fail validation even after slot reuse.
    generation: u64,

    /// Panics on the host bugs the token checks can catch (E1, D50): use after release,
    /// or a token handed to a runtime that did not mint it. Use through a *destroyed*
    /// runtime is a host lifetime violation no check can promise (the checking memory is
    /// freed); documented, not detected.
    pub fn validate(t: Token, rt: ?*Runtime) void {
        if (rt) |r| {
            if (t.owner != r) @panic("zqjs: Handle from another Runtime");
        }
        const h = &t.owner.handles;
        if (t.slot >= h.slots.items.len) @panic("zqjs: Handle used after release");
        const s = &h.slots.items[t.slot];
        if (!s.live or t.generation != s.generation)
            @panic("zqjs: Handle used after release");
    }

    pub fn isLive(t: Token) bool {
        const h = &t.owner.handles;
        if (t.slot >= h.slots.items.len) return false;
        const s = &h.slots.items[t.slot];
        return s.live and t.generation == s.generation;
    }

    fn value(t: Token) Value {
        return t.owner.handles.slots.items[t.slot].value;
    }

    /// Validates the token against `rt` — live, and minted by *this* runtime: a token
    /// from another runtime panics (D50's identity rule; the callers that hand a runtime
    /// and a handle together, like `rt.call`, are where the check is exercisable) — and
    /// returns the value it names. The caller holds the guard.
    pub fn checkedValue(rt: *Runtime, t: Token) Value {
        t.validate(rt);
        return t.value();
    }

    /// Reads, under the caller's guard: leaves copy (never allocate, Q10/D54).
    pub fn kind(t: Token) Kind {
        validate(t, null);
        return kindOf(t.value());
    }

    pub fn number(t: Token) ?f64 {
        validate(t, null);
        const v = t.value();
        return if (v.isNumber()) v.asNumber() else null;
    }

    pub fn boolean(t: Token) ?bool {
        validate(t, null);
        const v = t.value();
        return if (v.isBool()) v.asBool() else null;
    }

    /// Wrong kind → null. Otherwise the string's full UTF-16 length; copies
    /// min(len, buf.len) units, so a too-small buffer truncates *visibly* (D54).
    pub fn string(t: Token, buf: []u16) ?usize {
        validate(t, null);
        const v = t.value();
        if (!v.isString()) return null;
        const units = v.asString().units;
        const n = @min(units.len, buf.len);
        @memcpy(buf[0..n], units[0..n]);
        return units.len;
    }

    /// Invalidates this token and recycles its slot (D50). The caller holds the guard.
    /// The slot's 64-bit generation is incremented before it joins the free list; if the
    /// generation reaches `maxInt(u64)`, the slot is permanently retired instead of
    /// wrapping around.
    pub fn release(t: Token) void {
        validate(t, null);
        const h = &t.owner.handles;
        const s = &h.slots.items[t.slot];
        s.live = false;
        s.value = .undefined;
        h.live_tokens -= 1;
        if (s.generation < std.math.maxInt(u64)) {
            s.generation += 1;
            s.next_free = h.free_slot_head;
            h.free_slot_head = t.slot;
        }
    }
};

const no_slot: u32 = std.math.maxInt(u32);

/// One handle-table slot: the rooted `Value`, its 64-bit generation counter, liveness
/// flag, and free-list link when `!live`.
pub const Slot = struct {
    value: Value,
    generation: u64 = 0,
    live: bool = false,
    /// Meaningful only while `!live`: the next free slot's index.
    next_free: u32 = no_slot,
};

/// The runtime's handle table (one GC root set, GC_DESIGN §4). Capacity growth is driven
/// here (never behind our back), so the accounted byte count is exact (D50: the table is
/// bounded and accounted).
pub const Table = struct {
    gpa: Allocator,
    /// Maximum slot / concurrent handle capacity (`Limits.max_handles`, D50).
    max_tokens: u32,
    slots: std.ArrayList(Slot) = .empty,
    free_slot_head: u32 = no_slot,
    live_tokens: u32 = 0,
    /// Allocated slot-table bytes, accounted like heap bytes (D28) and reported in `memory()`.
    accounted: usize = 0,
    peak: usize = 0,

    fn charge(t: *Table, delta: usize) void {
        t.accounted += delta;
        if (t.accounted > t.peak) t.peak = t.accounted;
    }

    /// Grows the slots array by doubling, charging the capacity delta. The list must
    /// never grow behind our back, so every append goes through this first.
    fn ensureSlots(t: *Table, needed: usize) error{OutOfMemory}!void {
        const old_cap = t.slots.capacity;
        if (needed <= old_cap) return;
        var new_cap = if (old_cap == 0) 16 else old_cap * 2;
        while (new_cap < needed) new_cap *= 2;
        try t.slots.ensureTotalCapacity(t.gpa, new_cap);
        t.charge((new_cap - old_cap) * @sizeOf(Slot));
    }

    /// Allocates a fresh (or recycled) slot for `v` and returns its value token. May fail
    /// with `LimitExceeded(handles)` (when concurrent + retired slots reach `max_tokens`,
    /// D50) or `OutOfMemory`; on failure nothing is mutated and the runtime stays usable (E6).
    pub fn mint(rt: *Runtime, v: Value) error{ OutOfMemory, LimitExceeded }!Token {
        const t = &rt.handles;
        const reuse: ?u32 = if (t.free_slot_head == no_slot) null else t.free_slot_head;
        if (reuse == null) {
            if (t.slots.items.len >= t.max_tokens) {
                rt.limit_hit = .handles;
                return error.LimitExceeded;
            }
            t.ensureSlots(t.slots.items.len + 1) catch return error.OutOfMemory;
        }
        const slot_idx = reuse orelse blk: {
            t.slots.appendAssumeCapacity(.{ .value = v, .generation = 0, .live = true });
            break :blk @as(u32, @intCast(t.slots.items.len - 1));
        };
        const s = &t.slots.items[slot_idx];
        if (reuse != null) {
            t.free_slot_head = s.next_free;
            s.value = v;
            s.live = true;
            s.next_free = no_slot;
        }
        t.live_tokens += 1;
        return .{ .owner = rt, .slot = slot_idx, .generation = s.generation };
    }

    /// Allocates an independent slot holding the same value as `t` (D50). Releasing `t`
    /// invalidates `t` without affecting the duplicated handle.
    pub fn dup(rt: *Runtime, t: Token) error{ OutOfMemory, LimitExceeded }!Token {
        t.validate(rt);
        const val = t.value();
        return mint(rt, val);
    }

    /// Marks every rooted value (GC_DESIGN §4): live slots. `markValue` handles both
    /// generations (D8/M8.1): a young value survives a minor collection and is promoted;
    /// an old one needs no marking there.
    pub fn mark(t: *Table, h: *heap.Heap) void {
        for (t.slots.items) |s| if (s.live) h.markValue(s.value);
    }

    /// Frees the slot storage (E1: nothing outlives its runtime).
    pub fn deinit(t: *Table) void {
        t.slots.deinit(t.gpa);
        t.* = undefined;
    }
};
