//! Host handles (M9.1, D50): values crossing the boundary, GC-safe with explicit
//! ownership. A *slot* stores a `Value` and is rooted while referenced; a *token* is one
//! independently owned reference to a slot. The public `zqjs.Handle` is a pointer to a
//! token; every operation validates the token (state + generation) before use, so a
//! released handle is caught deterministically while the runtime is alive.
//!
//! Ownership rules (D50):
//! - `mint`/`dup` create tokens; `release` kills one and drops the slot's reference count.
//!   The slot (generation bumped) is reused; a token record is **never reused**, so a
//!   stale public pointer always aliases a dead record and stays detectable.
//! - Nothing here runs script code or allocates through the heap, so every operation
//!   works while the runtime is poisoned (E7), like `collectGarbage`/`memory`.
//! - Token-pool growth is bounded (`max_tokens`, `Limits.max_handles`) and accounted:
//!   the table's bytes are added to `memory()` by the API layer (D50).
//! - Validation is by **owner-pointer equality** (a token records the runtime that minted
//!   it): a token passed to another live runtime is rejected (D50's identity rule).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Runtime = @import("runtime.zig").Runtime;
const Error = @import("runtime.zig").Error;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const heap = @import("heap.zig");

/// What a handle refers to (D54/Q10's uniform model; objects vs arrays distinguished).
pub const Kind = enum { @"undefined", @"null", boolean, number, string, function, object, array };

pub fn kindOf(v: Value) Kind {
    return switch (v) {
        .undefined => .@"undefined",
        .null => .@"null",
        .boolean => .boolean,
        .number => .number,
        .string => .string,
        .native, .closure => .function,
        .object => |o| if (o.kind == .array) .array else .object,
    };
}

/// One independently owned reference to a slot (D50). The public handle is a pointer to
/// this record, which the runtime owns and never frees or reuses until `Runtime.destroy`.
pub const Token = struct {
    /// The runtime that minted it; identity validation is pointer equality.
    owner: *Runtime,
    /// Index into the owner's slot table.
    slot: u32,
    /// The slot's generation at mint time. For a live token this always matches (the
    /// token itself holds a reference, so the slot cannot have been freed); the check is
    /// the belt that catches corruption, and it is checked at the token level (D50).
    generation: u32,
    state: enum(u8) { live, dead },

    /// Panics on the host bugs the token checks can catch (E1, D50): use after release,
    /// or a token handed to a runtime that did not mint it. Use through a *destroyed*
    /// runtime is a host lifetime violation no check can promise (the checking memory is
    /// freed); documented, not detected.
    fn validate(t: *const Token, rt: ?*Runtime) void {
        if (t.state != .live) @panic("zqjs: Handle used after release");
        if (rt) |r| {
            if (t.owner != r) @panic("zqjs: Handle from another Runtime");
        }
        if (t.generation != t.owner.handles.slots.items[t.slot].generation)
            @panic("zqjs: Handle used after release");
    }

    fn value(t: *const Token) Value {
        return t.owner.handles.slots.items[t.slot].value;
    }

    /// Reads, under the caller's guard: leaves copy (never allocate, Q10/D54).
    pub fn kind(t: *const Token) Kind {
        validate(t, null);
        return kindOf(t.value());
    }

    pub fn number(t: *const Token) ?f64 {
        validate(t, null);
        return switch (t.value()) {
            .number => |n| n,
            else => null,
        };
    }

    pub fn boolean(t: *const Token) ?bool {
        validate(t, null);
        return switch (t.value()) {
            .boolean => |b| b,
            else => null,
        };
    }

    /// Wrong kind → null. Otherwise the string's full UTF-16 length; copies
    /// min(len, buf.len) units, so a too-small buffer truncates *visibly* (D54).
    pub fn string(t: *const Token, buf: []u16) ?usize {
        validate(t, null);
        const v = t.value();
        if (v != .string) return null;
        const units = v.string.units;
        const n = @min(units.len, buf.len);
        @memcpy(buf[0..n], units[0..n]);
        return units.len;
    }

    /// Kills this token and drops its slot reference (D50). The caller holds the guard.
    /// The last reference frees the slot for reuse (generation bumped, so any token that
    /// somehow still names it is caught); the token record itself stays, dead forever.
    pub fn release(t: *Token) void {
        validate(t, null);
        const h = &t.owner.handles;
        const s = &h.slots.items[t.slot];
        s.refs -= 1;
        if (s.refs == 0) {
            s.generation +%= 1;
            s.next_free = h.free_slot_head;
            h.free_slot_head = t.slot;
        }
        t.state = .dead;
        h.live_tokens -= 1;
    }
};

const no_slot: u32 = std.math.maxInt(u32);

/// One handle-table slot: the value, its reference count, and the free-list chain for
/// when the count reaches zero (slots are internal, so reuse is safe; the generation
/// bump above invalidates any token that somehow still names this index).
pub const Slot = struct {
    value: Value,
    refs: u32 = 0,
    generation: u32 = 0,
    /// Meaningful only while `refs == 0`: the next free slot's index.
    next_free: u32 = no_slot,
};

/// The runtime's handle table (one GC root set, GC_DESIGN §4). Capacity growth is driven
/// here (never behind our back), so the accounted byte count is exact (D50: the pool is
/// bounded and accounted).
pub const Table = struct {
    gpa: Allocator,
    /// Most tokens ever minted, live and dead together (`Limits.max_handles`).
    max_tokens: u32,
    slots: std.ArrayList(Slot) = .empty,
    free_slot_head: u32 = no_slot,
    /// Every token ever minted (for deinit); the public handles point into it.
    tokens: std.ArrayList(*Token) = .empty,
    tokens_ever: u32 = 0,
    live_tokens: u32 = 0,
    /// Table bytes, accounted like heap bytes (D28) and added to `memory()` by the API.
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

    fn ensureTokens(t: *Table, needed: usize) error{OutOfMemory}!void {
        const old_cap = t.tokens.capacity;
        if (needed <= old_cap) return;
        var new_cap = if (old_cap == 0) 16 else old_cap * 2;
        while (new_cap < needed) new_cap *= 2;
        try t.tokens.ensureTotalCapacity(t.gpa, new_cap);
        t.charge((new_cap - old_cap) * @sizeOf(*Token));
    }

    /// A new token owning `v` in a fresh (or recycled) slot. `rt` records ownership and
    /// receives the limit report. May fail with `LimitExceeded(handles)` (the pool's cap,
    /// D50) or `OutOfMemory`; on failure nothing is minted, not even a reservation, and
    /// the runtime stays usable (E6).
    pub fn mint(rt: *Runtime, v: Value) Error!*Token {
        const t = &rt.handles;
        if (t.tokens_ever >= t.max_tokens) {
            rt.limit_hit = .handles;
            return error.LimitExceeded;
        }
        const token = rt.gpa.create(Token) catch return error.OutOfMemory;
        errdefer rt.gpa.destroy(token);
        // All reservations first: a failure here leaves every counter untouched.
        const reuse: ?u32 = if (t.free_slot_head == no_slot) null else t.free_slot_head;
        if (reuse == null) t.ensureSlots(t.slots.items.len + 1) catch return error.OutOfMemory;
        t.ensureTokens(t.tokens.items.len + 1) catch return error.OutOfMemory;
        // Now mutate:
        const slot_idx = reuse orelse blk: {
            t.slots.appendAssumeCapacity(undefined);
            break :blk @as(u32, @intCast(t.slots.items.len - 1));
        };
        const s = &t.slots.items[slot_idx];
        s.value = v;
        s.refs = 1;
        if (reuse != null) t.free_slot_head = s.next_free;
        token.* = .{ .owner = rt, .slot = slot_idx, .generation = s.generation, .state = .live };
        t.tokens.appendAssumeCapacity(token);
        t.tokens_ever += 1;
        t.live_tokens += 1;
        t.charge(@sizeOf(Token));
        return token;
    }

    /// A new token for the same value as `t`, sharing its slot (refs + 1, D50).
    pub fn dup(rt: *Runtime, t: *const Token) Error!*Token {
        t.validate(rt);
        const h = &rt.handles;
        if (h.tokens_ever >= h.max_tokens) {
            rt.limit_hit = .handles;
            return error.LimitExceeded;
        }
        const s = &h.slots.items[t.slot];
        if (s.refs == std.math.maxInt(u32)) {
            rt.limit_hit = .handles;
            return error.LimitExceeded;
        }
        const token = rt.gpa.create(Token) catch return error.OutOfMemory;
        s.refs += 1;
        token.* = .{ .owner = rt, .slot = t.slot, .generation = s.generation, .state = .live };
        h.ensureTokens(h.tokens.items.len + 1) catch {
            s.refs -= 1; // roll back: the failed dup leaves nothing behind (E6)
            rt.gpa.destroy(token);
            return error.OutOfMemory;
        };
        h.tokens.appendAssumeCapacity(token);
        h.tokens_ever += 1;
        h.live_tokens += 1;
        h.charge(@sizeOf(Token));
        return token;
    }

    /// Marks every rooted value (GC_DESIGN §4): slots with a reference. `markValue`
    /// handles both generations (D8/M8.1): a young value survives a minor collection and
    /// is promoted; an old one needs no marking there.
    pub fn mark(t: *Table, h: *heap.Heap) void {
        for (t.slots.items) |s| if (s.refs > 0) h.markValue(s.value);
    }

    /// Frees every token record (E1: nothing outlives its runtime) and the storage.
    pub fn deinit(t: *Table) void {
        for (t.tokens.items) |token| t.gpa.destroy(token);
        t.tokens.deinit(t.gpa);
        t.slots.deinit(t.gpa);
        t.* = undefined;
    }
};
