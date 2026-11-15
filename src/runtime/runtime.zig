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
const Limits = @import("../limits.zig").Limits;
const Limit = @import("../limits.zig").Limit;
const Feature = @import("../frontend/diag.zig").Feature;

pub const Error = error{ Thrown, LimitExceeded, Unsupported, OutOfMemory, WriteFailed, Internal };

pub const ErrorName = enum { ReferenceError, TypeError, RangeError };

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

pub const Runtime = struct {
    gpa: Allocator,
    heap: Heap,
    out: *std.Io.Writer,
    max_steps: u64,
    /// All limits, for the engines (call depth, stack slots, interpreter depth).
    limits: Limits,
    steps: u64 = 0,
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
        return .{ .gpa = gpa, .heap = .init(gpa, limits), .out = out, .max_steps = limits.max_steps, .limits = limits };
    }

    pub fn deinit(rt: *Runtime) void {
        rt.joining.deinit(rt.gpa);
        rt.extra_roots.deinit(rt.gpa);
        rt.heap.deinit();
        rt.* = undefined;
    }

    /// Charges one step of the execution budget, *before* the work it pays for. Checks
    /// first, so `steps` never exceeds `max_steps` and cannot overflow (even with
    /// `max_steps = maxInt(u64)`). What a step is depends on the engine (Limits.max_steps).
    pub fn step(rt: *Runtime) Error!void {
        if (rt.steps >= rt.max_steps) {
            rt.limit_hit = .steps;
            return error.LimitExceeded;
        }
        rt.steps += 1;
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
