//! Runtime state shared by the interpreter and native functions: the heap, the output
//! writer, the step budget, and the record of why execution stopped.
//!
//! Errors are split by who caused them (LANGUAGE.md §1):
//!   error.Thrown         a JavaScript exception; details in `exception`
//!   error.LimitExceeded  a resource limit; which one in `limitHit()`
//!   error.Unsupported    outside ZQJS at runtime; which feature in `unsupported`
//!   error.OutOfMemory    the host allocator failed
//!   error.WriteFailed    the host's output writer failed
//!   error.Internal       a VM defensive check failure (an engine bug, D49): the runtime
//!                        is poisoned, because the VM's state can no longer be trusted
//! Only Thrown is a JavaScript-visible event; the others are never catchable by scripts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const heap_mod = @import("heap.zig");
const Heap = heap_mod.Heap;
const handles = @import("handles.zig");
const Limits = @import("../limits.zig").Limits;
const Limit = @import("../limits.zig").Limit;
const Feature = @import("../frontend/diag.zig").Feature;

pub const Error = error{ Thrown, LimitExceeded, Unsupported, OutOfMemory, WriteFailed, Internal };

pub const ErrorName = enum { ReferenceError, TypeError, RangeError };

/// The tag a live runtime carries; cleared on destroy (E1). The embedding API's checks
/// and the handle operations read this one (the internal runtime is what a handle names).
pub const alive_magic: u32 = 0x5A514A53; // "ZQJS"

/// A JavaScript exception, until M7 gives us Error objects.
/// Ownership: `name` is static; `message` is a heap string owned by `Runtime.heap`,
/// valid until `Runtime.deinit`. So the exception outlives the unwinding of the
/// interpreter and can be printed by the host afterwards.
pub const Exception = struct {
    name: ErrorName,
    message: *const heap_mod.String,
};

/// How an engine lets the collector mark the values only it holds.
pub const EngineRoots = struct {
    ctx: *anyopaque,
    mark: *const fn (ctx: *anyopaque, h: *Heap) void,
};

/// A host native call in flight (M9.1, D53): the engine's record of the crossing —
/// its temporary argument tokens (D50), the caller VM's result slot and pc, a depth
/// charge. The record is the guard's engine capability (D52): native dispatch pushes it
/// on the execution context and consumes it — releasing the tokens — at teardown, on
/// every outcome, so it cannot be reused after its callback ends. Internal only; never
/// exported through `zqjs`. (Native dispatch arrives in M9.1 P4; the type and the
/// context's record stack exist from P3, so the guard's invariants are in place first.)
pub const NativeRecord = struct {
    /// Set while the record is on an execution context's stack; consumed (null) at
    /// teardown. A stale record reference fails the stack-top check (D52).
    live: bool = false,
};

/// The shared execution context (M9.1, D51): one per top-level entry — a `resume` of an
/// execution, or a host `rt.call` at guard depth 0. It owns the four things a model B
/// chain shares, and every nested call (a nested VM, or a native-call record) charges
/// the same instance instead of installing a fresh one. It lives on the runtime and is
/// `active` only while a chain is in flight; outside a chain everything below is inert.
pub const ExecContext = struct {
    /// A chain is in flight: the budget, depth and registrations below are meaningful.
    active: bool = false,
    /// The chain's cumulative budget (E4). While active it is mirrored in
    /// `rt.steps`/`rt.max_steps` — the counters `rt.step()` charges — so every VM in the
    /// chain shares one counter and a nested call never installs a fresh budget. The
    /// outer execution adopts its `used` here and saves the updated count back at the
    /// chain's end (E4: cumulative over its resumes); a host `rt.call` begins at 0 and
    /// discards the count (no slicing in M9.1, Q8).
    used: u64 = 0,
    max: u64 = 0,
    /// The latched budget fault (Q8, review-frozen): the first exhaustion latches
    /// `LimitExceeded`, so later nested execution cannot consume instructions
    /// (`rt.step()` faults at once) and no native callback can clear or replace it. The
    /// native boundary check (P4) faults the outer execution with the latch whatever the
    /// native returned. Cleared when a new chain begins.
    budget_fault: ?Error = null,
    /// Logical call depth across the chain (D51 #2): every chained VM's live frames
    /// plus every native-call record, checked against `max_call_depth` as one number.
    /// A chain-less VM (the CLI's) keeps its own per-VM check in `Vm.enter`.
    call_depth: u32 = 0,
    /// The guard's engine entries (D52): one per in-flight native-call record, pushed
    /// by native dispatch with the record as proof and popped (consumed) at its
    /// teardown. The host entry needs no stack entry: the atomic `in_call` claim is the
    /// depth-0 host entry, and any further host entry panics against it exactly as in
    /// M9.0 (E2). Empty outside a chain.
    records: std.ArrayList(*NativeRecord) = .empty,
    /// VMs created inside the chain (D51 #4): registered while alive, so every
    /// collection traces their stacks; a suspended VM stays registered for its whole
    /// suspension. Empty outside a chain (asserted at chain begin and end).
    vms: std.ArrayList(EngineRoots) = .empty,

    /// The chain's top engine record, or null at depth 0 (no native in flight).
    pub fn topRecord(cx: *const ExecContext) ?*NativeRecord {
        return if (cx.records.items.len > 0) cx.records.items[cx.records.items.len - 1] else null;
    }
};

pub const Runtime = struct {
    gpa: Allocator,
    heap: Heap,
    out: *std.Io.Writer,
    max_steps: u64,
    /// All limits, for the engines (call depth, stack slots, interpreter depth).
    limits: Limits,
    steps: u64 = 0,
    /// Host handles (M9.1, D50): the table is one GC root set (marked in `markRoots`).
    handles: handles.Table,
    /// The shared execution context (M9.1, D51): a chain's budget, depth, engine records
    /// and active-VM registrations. Inert (inactive, lists empty) outside a chain.
    exec_ctx: ExecContext = .{},
    /// Overlap guard state (E2): true while a call into the runtime is running. The
    /// embedding API's Guard claims it (M9.0), as do handle operations (M9.1); entry
    /// kinds arrive with the execution context (P3). Atomic: cross-thread entry loses.
    in_call: std.atomic.Value(bool) = .init(false),
    /// Use-after-destroy tag (E1): safe builds check it at every entry point. Best
    /// effort: freed memory may be reused, so the check can miss; documented as such.
    magic: u32 = alive_magic,
    exception: ?Exception = null,
    unsupported: ?Feature = null,
    /// For Unsupported(builtin): which global or member (an atom on the heap).
    unsupported_name: ?*const heap_mod.String = null,
    /// The built-in objects, created on first use (builtins.zig).
    realm: ?@import("builtins.zig").Realm = null,
    /// Arrays being converted to strings right now (cycle detection, object.join).
    joining: std.ArrayList(*heap_mod.Object) = .empty,
    /// The running engine's roots (its stacks and frames), marked by `collect` (D8).
    engine_roots: ?EngineRoots = null,
    /// More root sets, marked by every collection (M9.0): the embedding API registers each
    /// live program (its constants) and execution (its VM, suspended or not) here.
    extra_roots: std.ArrayList(EngineRoots) = .empty,
    limit_hit: ?Limit = null,
    /// Set by a defensive-check failure (D49): an invariant of the VM, compiler or
    /// verifier is broken, so nothing about the state can be trusted. The embedding API
    /// checks this at every entry point and then returns `error.Internal` until
    /// `deinit`; the CLI reports the failure and exits.
    poisoned: bool = false,
    /// What the first defensive check that failed said (a static string; never
    /// allocated). Only for the host's report; the failure's text stays fixed (E10).
    internal_reason: ?[]const u8 = null,

    pub fn init(gpa: Allocator, limits: Limits, out: *std.Io.Writer) Runtime {
        return .{
            .gpa = gpa,
            .heap = .init(gpa, limits),
            .out = out,
            .max_steps = limits.max_steps,
            .limits = limits,
            .handles = .{ .gpa = gpa, .max_tokens = limits.max_handles },
        };
    }

    pub fn deinit(rt: *Runtime) void {
        rt.magic = 0; // handles and API entries must not enter after this (E1)
        rt.handles.deinit();
        rt.exec_ctx.records.deinit(rt.gpa);
        rt.exec_ctx.vms.deinit(rt.gpa);
        rt.joining.deinit(rt.gpa);
        rt.extra_roots.deinit(rt.gpa);
        rt.heap.deinit();
        rt.* = undefined;
    }

    /// Charges one step of the execution budget, *before* the work it pays for. Checks
    /// first, so `steps` never exceeds `max_steps` and cannot overflow (even with
    /// `max_steps = maxInt(u64)`). What a step is depends on the engine (Limits.max_steps).
    /// Under a chain (M9.1, D51) the counter is the execution context's: shared by every
    /// VM and native record, and an exhaustion latches `budget_fault` (Q8) so no nested
    /// call or native can clear or replace it.
    pub fn step(rt: *Runtime) Error!void {
        if (rt.steps >= rt.max_steps) {
            rt.limit_hit = .steps;
            if (rt.exec_ctx.active and rt.exec_ctx.budget_fault == null)
                rt.exec_ctx.budget_fault = error.LimitExceeded;
            return error.LimitExceeded;
        }
        rt.steps += 1;
    }

    /// Begins a chain (M9.1, D51): one per top-level entry. Installs the cumulative
    /// budget as the live counters, so every VM in the chain charges it via `rt.step()`;
    /// resets the per-chain state. The guard's host entry (E2) must already be held.
    pub fn beginChain(rt: *Runtime, used: u64, max: u64) void {
        const cx = &rt.exec_ctx;
        std.debug.assert(!cx.active);
        std.debug.assert(cx.records.items.len == 0);
        std.debug.assert(cx.vms.items.len == 0); // the last chain's VMs all deregistered
        cx.active = true;
        cx.used = used;
        cx.max = max;
        cx.budget_fault = null;
        cx.call_depth = 0;
        rt.steps = used;
        rt.max_steps = max;
    }

    /// Ends the chain: returns the cumulative step count for the caller to save back
    /// (E4), and deactivates the context. The engine records and VM registrations must
    /// already be gone (their teardowns pop/subtract as they go).
    pub fn endChain(rt: *Runtime) u64 {
        const cx = &rt.exec_ctx;
        std.debug.assert(cx.active);
        std.debug.assert(cx.records.items.len == 0);
        std.debug.assert(cx.vms.items.len == 0);
        cx.active = false;
        return rt.steps;
    }

    /// Records a JavaScript exception and returns error.Thrown. If building the message
    /// itself fails (heap limit, OOM), that failure is returned instead.
    pub fn throw(rt: *Runtime, name: ErrorName, message: []const heap_mod.Piece) Error {
        const msg = try rt.heap.newString(message);
        rt.exception = .{ .name = name, .message = msg };
        return error.Thrown;
    }

    pub fn fail(rt: *Runtime, feature: Feature) Error {
        rt.unsupported = feature;
        return error.Unsupported;
    }

    pub fn limit(rt: *Runtime, which: Limit) Error {
        rt.limit_hit = which;
        return error.LimitExceeded;
    }

    /// A defensive check failed (D49): a bug in ZQJS, never in the script. Poisons the
    /// runtime and returns `error.Internal`. `what` is a static string for the host's
    /// report; the first reason wins, because later failures may follow from the first.
    pub fn bug(rt: *Runtime, comptime what: []const u8) Error {
        rt.poisoned = true;
        if (rt.internal_reason == null) rt.internal_reason = what;
        return error.Internal;
    }

    /// A full collection. Engines call it only at safepoints (D8); tests may call it when
    /// no engine holds values outside the roots.
    pub fn collect(rt: *Runtime) void {
        rt.heap.collect(rt, markRoots);
    }

    /// The runtime's own roots (GC_DESIGN §4), then the running engine's.
    fn markRoots(rt: *Runtime, h: *Heap) void {
        if (rt.realm) |*r| for (r.objects()) |o| h.markObj(&o.obj);
        if (rt.exception) |e| h.markObj(@constCast(&e.message.obj));
        if (rt.unsupported_name) |n| h.markObj(@constCast(&n.obj));
        // Only non-empty inside an instruction, never at a safepoint.
        std.debug.assert(rt.joining.items.len == 0);
        if (rt.engine_roots) |e| e.mark(e.ctx, h);
        for (rt.extra_roots.items) |e| e.mark(e.ctx, h);
        // The chain's nested VMs (M9.1, D51 #4): registered while alive, so a collection
        // inside a native callback keeps a suspended VM's stacks and everything they
        // reference. Empty outside a chain.
        for (rt.exec_ctx.vms.items) |e| e.mark(e.ctx, h);
        rt.handles.mark(h); // host handles (M9.1, D50): slots with a reference
    }

    /// Adds a root set every collection marks, until `removeRoots` (M9.0).
    pub fn addRoots(rt: *Runtime, roots: EngineRoots) error{OutOfMemory}!void {
        try rt.extra_roots.append(rt.gpa, roots);
    }

    pub fn removeRoots(rt: *Runtime, ctx: *anyopaque) void {
        for (rt.extra_roots.items, 0..) |e, i| if (e.ctx == ctx) {
            _ = rt.extra_roots.swapRemove(i);
            return;
        };
        unreachable; // removing a root set that was never added
    }

    pub fn limitHit(rt: *const Runtime) ?Limit {
        return rt.limit_hit orelse rt.heap.limit_hit;
    }
};
