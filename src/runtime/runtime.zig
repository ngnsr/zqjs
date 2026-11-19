//! Runtime state shared by the interpreter and native functions: the heap, the output
//! writer, the step budget, and the record of why execution stopped.
//!
//! Errors are split by who caused them (LANGUAGE.md §1):
//!   error.Thrown         a JavaScript exception; details in `exception`
//!   error.HostError      a host native operation failed (M9.1, D53); message in `host_message`
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
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const Native = value_mod.Native;
const builtins_mod = @import("builtins.zig");
const object_mod = @import("object.zig");
const Limits = @import("../limits.zig").Limits;
const Limit = @import("../limits.zig").Limit;
const Feature = @import("../frontend/diag.zig").Feature;

pub const Error = error{ Thrown, HostError, LimitExceeded, Unsupported, OutOfMemory, WriteFailed, Internal };

pub const ErrorName = enum { ReferenceError, TypeError, RangeError, SyntaxError };

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

/// How an active engine invokes a JS closure from inside a built-in native (M16.1).
pub const ClosureCaller = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, c: *const heap_mod.Closure, this: ?Value, args: []const Value) Error!Value,
};

/// Stack-local GC root frame for built-ins that hold live JS values across callbacks (M16.1).
pub const ValueRoots = struct {
    values: []Value,

    pub fn register(self: *ValueRoots, rt: *Runtime) error{OutOfMemory}!void {
        try rt.addRoots(.{ .ctx = self, .mark = mark });
    }

    pub fn unregister(self: *ValueRoots, rt: *Runtime) void {
        rt.removeRoots(self);
    }

    fn mark(ctx: *anyopaque, h: *Heap) void {
        const self: *ValueRoots = @ptrCast(@alignCast(ctx));
        for (self.values) |v| h.markValue(v);
    }
};

/// Queued Promise reaction or adoption microtask (M18).
pub const Microtask = struct {
    kind: enum { reaction, adopt, resolve_promise, await_resume },
    child: ?*heap_mod.Object = null,
    cb: Value = .undefined,
    arg: Value = .undefined,
    adopt_rejected: bool = false,
    coroutine: ?*heap_mod.Coroutine = null,
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
    /// True while a nested `rt.call` inside this callback is running a VM or built-in
    /// native: while suspended, the callback's capability is paused (e.g. an output
    /// writer's `drain` during a nested `print` must still panic, D52).
    suspended: bool = false,
    /// Set by `rt.throwJs`: must be paired with returning `error.Thrown` from `NativeFn`
    /// (D53).
    threw_js: bool = false,
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

    /// Native dispatch (P4): pushes the record as the engine entry (D52). The record
    /// must be fresh — never already on a stack — so a consumed record cannot be pushed
    /// again (an engine bug, D49).
    pub fn pushRecord(cx: *ExecContext, gpa: Allocator, record: *NativeRecord) error{OutOfMemory}!void {
        std.debug.assert(!record.live);
        record.live = true;
        try cx.records.append(gpa, record);
    }

    /// Teardown (P4): consumes the record and pops its entry, on every outcome. The
    /// record must be the stack's top — the callback that owns it is the innermost one
    /// running — so a stale or foreign record reference cannot pop a different entry
    /// (D52's scoping requirement: the capability dies with its callback).
    pub fn popRecord(cx: *ExecContext, record: *NativeRecord) void {
        std.debug.assert(record.live);
        std.debug.assert(cx.topRecord() == record);
        record.live = false;
        _ = cx.records.pop();
    }

    /// Deregisters a chain VM at teardown (D51 #4). `ctx` is the VM whose `roots()` was
    /// added; removing one that was never added is an engine bug (D49).
    pub fn removeVm(cx: *ExecContext, ctx: *anyopaque) void {
        for (cx.vms.items, 0..) |e, i| if (e.ctx == ctx) {
            _ = cx.vms.swapRemove(i);
            return;
        };
        unreachable; // a chain VM torn down without its registration
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
    /// The thread holding the depth-0 host entry while `in_call` is true (D52). Only
    /// this thread may take a sanctioned engine descent while a native callback is active.
    owner_thread: ?std.Thread.Id = null,
    /// Use-after-destroy tag (E1): safe builds check it at every entry point. Best
    /// effort: freed memory may be reused, so the check can miss; documented as such.
    magic: u32 = alive_magic,
    exception: ?Exception = null,
    /// Arbitrary JS value thrown by `throw expr` (M11.2). Mutually exclusive with `exception`.
    thrown_value: ?Value = null,
    /// Set by `rt.throwJs` when building the exception message string itself fails
    /// (`OutOfMemory` or `LimitExceeded`): consumed when the native returns `error.Thrown`.
    pending_throw_fault: ?Error = null,
    unsupported: ?Feature = null,
    /// For Unsupported(builtin): which global or member (an atom on the heap).
    unsupported_name: ?*const heap_mod.String = null,
    /// Host-registered global functions (`defineGlobalFunction`, M9.1 D53). Persist
    /// across runs (E3) and die with the runtime (E1).
    host_globals: std.ArrayList(*Native) = .empty,
    /// For `error.HostError` (M9.1, D53): the native's `out.host_message` copied into a
    /// fixed buffer before the callback's stack unwinds, formatted into `Failure` via
    /// `TextWriter` (E10).
    host_message_buf: [256]u8 = undefined,
    host_message_len: usize = 0,
    host_message_truncated: bool = false,
    /// The built-in objects, created on first use (builtins.zig).
    realm: ?@import("builtins.zig").Realm = null,
    /// Arrays being converted to strings right now (cycle detection, object.join).
    joining: std.ArrayList(*heap_mod.Object) = .empty,
    /// The running engine's roots (its stacks and frames), marked by `collect` (D8).
    engine_roots: ?EngineRoots = null,
    /// The running engine's closure-invocation hook for JS → Builtin → JS reentrancy (M16.1).
    closure_caller: ?ClosureCaller = null,
    /// Frame address at the latest depth-0 entry (D60); 0 = unset, never faults.
    stack_base: usize = 0,
    /// Pending microtasks drained at the outermost turn checkpoint (M18).
    microtasks: std.ArrayList(Microtask) = .empty,
    microtask_head: usize = 0,
    /// Currently executing microtask job (traced by markRoots, D56 invariant 2).
    active_job: ?Microtask = null,
    /// More root sets, marked by every collection (M9.0): the embedding API registers each
    /// live program (its constants) and execution (its VM, suspended or not) here.
    extra_roots: std.ArrayList(EngineRoots) = .empty,
    /// Per-run cached tagged-template `TemplateStringsArray` objects (keyed by AST/Proto site pointer).
    template_cache: std.AutoHashMapUnmanaged(usize, *heap_mod.Object) = .empty,
    /// Global symbol registry (`Symbol.for` / `Symbol.keyFor`, M36 D66). Strong roots.
    global_symbols: std.HashMapUnmanaged(*const heap_mod.String, *heap_mod.Symbol, SymbolRegistryContext, 80) = .empty,
    limit_hit: ?Limit = null,
    /// Set by a defensive-check failure (D49): an invariant of the VM, compiler or
    /// verifier is broken, so nothing about the state can be trusted. The embedding API
    /// checks this at every entry point and then returns `error.Internal` until
    /// `deinit`; the CLI reports the failure and exits.
    poisoned: bool = false,
    /// What the first defensive check that failed said (a static string; never
    /// allocated). Only for the host's report; the failure's text stays fixed (E10).
    internal_reason: ?[]const u8 = null,
    /// Per-runtime PRNG state for `Math.random()` (M11.3: deterministic by default).
    rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(default_random_seed),
    /// Last top-level expression statement value in REPL mode (D71).
    repl_result: Value = .undefined,

    pub const default_random_seed: u64 = 0x9e3779b97f4a7c15;

    pub fn setRandomSeed(rt: *Runtime, seed: u64) void {
        rt.rng = std.Random.DefaultPrng.init(seed);
    }

    /// Uniform f64 in [0, 1) with 53 bits of precision.
    pub fn nextRandom(rt: *Runtime) f64 {
        return @as(f64, @floatFromInt(rt.rng.next() >> 11)) * 0x1.0p-53;
    }

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
        for (rt.host_globals.items) |n| {
            rt.gpa.free(n.name);
            rt.gpa.destroy(n);
        }
        rt.host_globals.deinit(rt.gpa);
        rt.handles.deinit();
        rt.exec_ctx.records.deinit(rt.gpa);
        rt.exec_ctx.vms.deinit(rt.gpa);
        rt.joining.deinit(rt.gpa);
        rt.extra_roots.deinit(rt.gpa);
        rt.template_cache.deinit(rt.gpa);
        rt.global_symbols.deinit(rt.gpa);
        rt.microtasks.deinit(rt.gpa);
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
        if (rt.exec_ctx.active) rt.exec_ctx.used = rt.steps;
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
        cx.used = 0;
        cx.max = 0;
        cx.budget_fault = null;
        cx.call_depth = 0;
        rt.max_steps = rt.limits.max_steps;
        return rt.steps;
    }

    /// Records a JavaScript exception and returns error.Thrown. If building the message
    /// itself fails (heap limit, OOM), that failure is returned instead.
    pub fn throw(rt: *Runtime, name: ErrorName, message: []const heap_mod.Piece) Error {
        const msg = try rt.heap.newString(message);
        rt.thrown_value = null;
        rt.exception = .{ .name = name, .message = msg };
        return error.Thrown;
    }

    /// Records an arbitrary JS value thrown by `throw expr` and returns error.Thrown.
    pub fn throwValue(rt: *Runtime, v: Value) Error {
        rt.exception = null;
        rt.thrown_value = v;
        return error.Thrown;
    }

    /// Clears any pending JS exception without materializing a value (for `catch {}`).
    pub fn clearThrown(rt: *Runtime) void {
        rt.exception = null;
        rt.thrown_value = null;
    }

    /// Materializes the pending JS exception (`thrown_value` or `{ name, message }` for
    /// a built-in/native `Exception`) and clears pending exception state only on success.
    pub fn catchValue(rt: *Runtime) Error!Value {
        if (rt.thrown_value) |v| {
            rt.thrown_value = null;
            rt.exception = null;
            return v;
        }
        const ex = rt.exception.?;
        const err_val = try builtins_mod.makeEngineError(rt, ex.name, ex.message);
        rt.exception = null;
        rt.thrown_value = null;
        return err_val;
    }

    pub fn fail(rt: *Runtime, feature: Feature) Error {
        rt.unsupported = feature;
        return error.Unsupported;
    }

    /// D60: call before a native→JS crossing nests another run loop. Stacks grow down
    /// on every supported target, so the bytes used are the base minus the frame address.
    pub fn checkNativeStack(rt: *Runtime) Error!void {
        if (rt.stack_base -| @frameAddress() > rt.limits.max_native_stack_bytes) return rt.limit(.native_stack);
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
        if (rt.realm) |*r| {
            for (r.objects()) |o| h.markObj(&o.obj);
            h.markObj(&r.sym_iterator.obj);
            h.markObj(&r.sym_async_iterator.obj);
            h.markObj(&r.sym_to_string_tag.obj);
        }
        var sym_it = rt.global_symbols.iterator();
        while (sym_it.next()) |e| {
            h.markObj(@constCast(&e.key_ptr.*.obj));
            h.markObj(&e.value_ptr.*.obj);
        }
        if (rt.exception) |e| h.markObj(@constCast(&e.message.obj));
        if (rt.thrown_value) |v| h.markValue(v);
        if (rt.unsupported_name) |n| h.markObj(@constCast(&n.obj));
        h.markValue(rt.repl_result);
        // Only non-empty inside an instruction, never at a safepoint.
        std.debug.assert(rt.joining.items.len == 0);
        if (rt.engine_roots) |e| e.mark(e.ctx, h);
        for (rt.extra_roots.items) |e| e.mark(e.ctx, h);
        // The chain's nested VMs (M9.1, D51 #4): registered while alive, so a collection
        // inside a native callback keeps a suspended VM's stacks and everything they
        // reference. Empty outside a chain.
        for (rt.exec_ctx.vms.items) |e| e.mark(e.ctx, h);
        for (rt.microtasks.items[rt.microtask_head..]) |mt| markMicrotask(h, mt);
        if (rt.active_job) |mt| markMicrotask(h, mt);
        var tpl_it = rt.template_cache.valueIterator();
        while (tpl_it.next()) |obj_ptr| h.markObj(&obj_ptr.*.obj);
        rt.handles.mark(h); // host handles (M9.1, D50): slots with a reference
    }

    fn markMicrotask(h: *Heap, mt: Microtask) void {
        if (mt.child) |ch| h.markObj(&ch.obj);
        if (mt.coroutine) |co| h.markObj(&co.obj);
        h.markValue(mt.cb);
        h.markValue(mt.arg);
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

    /// Invokes a JS callable (`native` or `closure`) from inside a built-in (M16.1).
    pub fn callCallable(rt: *Runtime, callee: Value, this_val: Value, args: []const Value) Error!Value {
        return switch (callee) {
            .native => |n| if (n.host) |h|
                h.call(rt, h.ctx, if (this_val.isObjectLike()) this_val else null, args)
            else
                n.call(rt, this_val, args),
            .closure => |c| {
                switch (c.impl) {
                    .promise_cap => |pc| return builtins_mod.callPromiseCapability(rt, pc.promise, pc.is_reject, args),
                    .native_closure => |nc| {
                        const f: *const fn (*Runtime, *heap_mod.Object, []const Value) Error!Value = @ptrCast(@alignCast(nc.func));
                        return f(rt, nc.env, args);
                    },
                    .bound => |b| {
                        try rt.checkNativeStack();
                        if (b.bound_args.len == 0) return rt.callCallable(b.target, b.bound_this, args);
                        const combined = try rt.gpa.alloc(Value, b.bound_args.len + args.len);
                        defer rt.gpa.free(combined);
                        @memcpy(combined[0..b.bound_args.len], b.bound_args);
                        @memcpy(combined[b.bound_args.len..], args);
                        return rt.callCallable(b.target, b.bound_this, combined);
                    },
                    .vm, .tree => {
                        try rt.checkNativeStack();
                        const cc = rt.closure_caller orelse return rt.bug("closure called without an active engine");
                        return cc.call(cc.ctx, c, if (this_val.isObjectLike()) this_val else null, args);
                    },
                }
            },
            else => rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }}),
        };
    }

    /// Drains queued microtasks FIFO at an outermost turn checkpoint (M18).
    /// On an uncatchable runtime fault, the active job is already consumed and
    /// remaining queued jobs are preserved for any later valid checkpoint.
    pub fn drainMicrotasks(rt: *Runtime) Error!void {
        while (rt.microtask_head < rt.microtasks.items.len) {
            const job = rt.microtasks.items[rt.microtask_head];
            rt.microtask_head += 1;
            try rt.runMicrotask(job);
        }
        rt.microtasks.clearRetainingCapacity();
        rt.microtask_head = 0;
    }

    fn runMicrotask(rt: *Runtime, job: Microtask) Error!void {
        // Restore, not clear: a host call inside a job may drain a nested checkpoint (D57).
        const prev = rt.active_job;
        rt.active_job = job;
        defer rt.active_job = prev;

        switch (job.kind) {
            .adopt => {
                if (job.child) |ch| {
                    try builtins_mod.settlePromiseFromJob(rt, ch, job.adopt_rejected, job.arg);
                }
            },
            .resolve_promise => {
                if (job.child) |ch| {
                    try builtins_mod.adoptPromiseNow(rt, ch, job.arg.object);
                }
            },
            .reaction => {
                if (job.cb == .native or job.cb == .closure) {
                    if (rt.callCallable(job.cb, .undefined, &.{job.arg})) |ret| {
                        if (job.child) |ch| try builtins_mod.resolvePromiseValue(rt, ch, ret);
                    } else |e| {
                        if (e != error.Thrown) return e;
                        const err_val = try rt.catchValue();
                        if (job.child) |ch| try builtins_mod.settlePromiseFromJob(rt, ch, true, err_val);
                    }
                } else if (job.child) |ch| {
                    try builtins_mod.settlePromiseFromJob(rt, ch, job.adopt_rejected, job.arg);
                }
            },
            .await_resume => {
                if (job.coroutine) |co| {
                    try @import("coroutine.zig").resumeCoroutine(rt, co, job.arg, job.adopt_rejected);
                }
            },
        }
    }

    pub fn limitHit(rt: *const Runtime) ?Limit {
        return rt.limit_hit orelse rt.heap.limit_hit;
    }
};

pub const SymbolRegistryContext = struct {
    pub fn hash(_: SymbolRegistryContext, s: *const heap_mod.String) u64 {
        return heap_mod.hashUnits(u16, s.units);
    }
    pub fn eql(_: SymbolRegistryContext, a: *const heap_mod.String, b: *const heap_mod.String) bool {
        return std.mem.eql(u16, a.units, b.units);
    }
};

pub const SymbolRegistryUtf16Adapter = struct {
    pub fn hash(_: SymbolRegistryUtf16Adapter, units: []const u16) u64 {
        return heap_mod.hashUnits(u16, units);
    }
    pub fn eql(_: SymbolRegistryUtf16Adapter, units: []const u16, s: *const heap_mod.String) bool {
        return std.mem.eql(u16, units, s.units);
    }
};
