//! Engine-agnostic async coroutine driver (DESIGN_DECISIONS D56).
//!
//! Coordinates coroutine lifecycle across both engines (VM and tree-walker) without
//! importing either: engines expose `CoroutineVTable` operations through `heap.zig`
//! and report each execution step as an `Outcome`.

const std = @import("std");
const Value = @import("value.zig").Value;
const heap = @import("heap.zig");
const Coroutine = heap.Coroutine;
const CoroutineVTable = heap.CoroutineVTable;
const rt_mod = @import("runtime.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const builtins = @import("builtins.zig");
const object = @import("object.zig");

pub const Outcome = union(enum) {
    returned: Value,
    threw,
    awaiting: Value,
    /// A generator suspended at `yield` (or at its start, D67). `raw`: a `yield*` inner
    /// result, handed to the caller of `next`/`throw`/`return` as is.
    yielded: struct { value: Value, raw: bool = false },
};

/// How a resume continues the coroutine: an async resume uses `next` (fulfilled) and
/// `throw` (rejected); a generator's `next`/`throw`/`return` use all three (D67).
pub const ResumeMode = enum { next, throw, @"return" };

pub const ResumeFn = *const fn (engine: *anyopaque, val: Value, mode: ResumeMode) Error!Outcome;

const CoroutineRoots = struct {
    promise: ?*heap.Object,
    coroutine: ?*Coroutine = null,

    fn register(self: *CoroutineRoots, rt: *Runtime) error{OutOfMemory}!void {
        try rt.addRoots(.{ .ctx = self, .mark = mark });
    }

    fn unregister(self: *CoroutineRoots, rt: *Runtime) void {
        rt.removeRoots(self);
    }

    fn mark(ctx: *anyopaque, h: *heap.Heap) void {
        const self: *CoroutineRoots = @ptrCast(@alignCast(ctx));
        if (self.promise) |p| h.markObj(&p.obj);
        if (self.coroutine) |co| h.markObj(&co.obj);
    }
};

/// Allocates the result promise `P` and `Coroutine` (rooted together per D56
/// invariant 1), runs the engine's initial synchronous step via `create_and_run`,
/// settles or suspends `co`, and returns `P`.
pub fn start(
    rt: *Runtime,
    vtable: *const CoroutineVTable,
    ctx: anytype,
    comptime create_and_run: fn (@TypeOf(ctx), *Coroutine) Error!Outcome,
) Error!Value {
    try rt.checkNativeStack(); // D60: the first step nests a run loop
    const r = try builtins.realm(rt);
    const p_obj = try rt.heap.newPromise(r.promise_prototype);
    var roots: CoroutineRoots = .{ .promise = p_obj };
    try roots.register(rt);
    defer roots.unregister(rt);

    const co = try rt.heap.newCoroutine(p_obj, vtable);
    roots.coroutine = co;

    const outcome = create_and_run(ctx, co) catch |e| {
        co.state = .done;
        destroyEngine(rt, co);
        return e;
    };
    try finishStep(rt, co, outcome);
    return .{ .object = p_obj };
}

/// Resumes a suspended coroutine from an `.await_resume` microtask. A coroutine
/// already marked `.done` (e.g. from an earlier fault) is a no-op.
pub fn resumeCoroutine(rt: *Runtime, co: *Coroutine, val: Value, rejected: bool) Error!void {
    if (co.state == .done) return;
    std.debug.assert(co.state == .suspended);
    const eng = co.engine orelse return;
    try rt.checkNativeStack(); // D60; co stays suspended on a fault
    co.state = .running;
    const resume_fn: ResumeFn = @ptrCast(@alignCast(co.vtable.@"resume"));
    const outcome = resume_fn(eng, val, if (rejected) .throw else .next) catch |e| {
        co.state = .done;
        destroyEngine(rt, co);
        return e;
    };
    try finishStep(rt, co, outcome);
}

pub fn finishStep(rt: *Runtime, co: *Coroutine, outcome: Outcome) Error!void {
    const promise = co.promise orelse {
        co.state = .done;
        destroyEngine(rt, co);
        return rt.bug("an async step on a generator coroutine");
    };
    switch (outcome) {
        .returned => |v| {
            co.state = .done;
            destroyEngine(rt, co);
            try builtins.resolvePromiseValue(rt, promise, v);
        },
        .threw => {
            co.state = .done;
            destroyEngine(rt, co);
            const err_val = try rt.catchValue();
            try builtins.settlePromiseFromJob(rt, promise, true, err_val);
        },
        .yielded => {
            co.state = .done;
            destroyEngine(rt, co);
            return rt.bug("yield in an async function");
        },
        .awaiting => |v| {
            errdefer {
                co.state = .done;
                destroyEngine(rt, co);
            }
            const awaited_p_val = try builtins.resolveToPromise(rt, v);
            const awaited_p = awaited_p_val.object;
            try chargeSuspended(rt, co);

            const pr = &awaited_p.kind.promise;
            if (pr.state == .pending) {
                pr.reactions.ensureUnusedCapacity(rt.heap.allocator(), 1) catch |e| return rt.heap.failed(e);
                pr.reactions.appendAssumeCapacity(.{
                    .child = null,
                    .on_fulfilled = .undefined,
                    .on_rejected = .undefined,
                    .coroutine = co,
                });
                if (awaited_p.obj.old and !co.obj.old) rt.heap.remember(&awaited_p.obj);
            } else {
                try rt.microtasks.ensureUnusedCapacity(rt.gpa, 1);
                rt.microtasks.appendAssumeCapacity(.{
                    .kind = .await_resume,
                    .coroutine = co,
                    .arg = pr.result,
                    .adopt_rejected = (pr.state == .rejected),
                });
            }
            if (co.obj.old) rt.heap.remember(&co.obj);
            co.state = .suspended;
        },
    }
}

/// Shrinks a suspending engine and charges what it keeps against `max_heap_bytes` (D56).
fn chargeSuspended(rt: *Runtime, co: *Coroutine) Error!void {
    const eng = co.engine.?;
    co.vtable.shrink(eng);
    try rt.heap.adjustCharge(&co.charge, co.vtable.ownedBytes(eng));
}

/// Suspension at a `yield` (D67): what an `await` suspension does for memory and GC.
fn suspendGenerator(rt: *Runtime, co: *Coroutine) Error!void {
    try chargeSuspended(rt, co);
    if (co.obj.old) rt.heap.remember(&co.obj);
    co.state = .suspended;
}

/// A generator call (D67): runs the engine through the parameter prologue to
/// `generator_start` and returns the generator object, its `[[Prototype]]` the function's
/// `.prototype` if that is an object, else %GeneratorPrototype%. A throw from a parameter
/// default propagates, and no generator object is created.
pub fn startGenerator(
    rt: *Runtime,
    vtable: *const CoroutineVTable,
    func: Value,
    ctx: anytype,
    comptime create_and_run: fn (@TypeOf(ctx), *Coroutine) Error!Outcome,
) Error!Value {
    try rt.checkNativeStack(); // D60: the first step nests a run loop
    var roots: CoroutineRoots = .{ .promise = null };
    try roots.register(rt);
    defer roots.unregister(rt);

    const co = try rt.heap.newCoroutine(null, vtable);
    roots.coroutine = co;
    errdefer {
        co.state = .done;
        destroyEngine(rt, co);
    }
    switch (try create_and_run(ctx, co)) {
        .yielded => {},
        .threw => return error.Thrown,
        .returned, .awaiting => return rt.bug("a generator ran past generator_start"),
    }
    try suspendGenerator(rt, co);
    const r = try builtins.realm(rt);
    const proto_val = try object.get(rt, func, try object.named(rt, "prototype"));
    const proto = if (proto_val == .object) proto_val.object else r.generator_prototype;
    return .{ .object = try rt.heap.newGenerator(proto, co) };
}

/// `%GeneratorPrototype%.next/throw/return` on generator `gen` (D67): the iterator result,
/// or the raw inner result of a `yield*`.
pub fn resumeGenerator(rt: *Runtime, gen: *heap.Object, mode: ResumeMode, val: Value) Error!Value {
    const g = &gen.kind.generator;
    switch (g.state) {
        .executing => return rt.throw(.TypeError, &.{.{ .ascii = "Generator is already running" }}),
        .suspended_start => if (mode != .next) completeGenerator(rt, gen),
        .suspended_yield, .completed => {},
    }
    if (g.state == .completed) return switch (mode) {
        .next => builtins.iterResult(rt, .undefined, true),
        .@"return" => builtins.iterResult(rt, val, true),
        .throw => rt.throwValue(val),
    };
    const co = g.co.?;
    const eng = co.engine orelse return rt.bug("a suspended generator without an engine");
    try rt.checkNativeStack(); // D60; the generator stays suspended on a fault
    g.state = .executing;
    co.state = .running;
    errdefer completeGenerator(rt, gen);
    const resume_fn: ResumeFn = @ptrCast(@alignCast(co.vtable.@"resume"));
    switch (try resume_fn(eng, val, mode)) {
        .yielded => |y| {
            try suspendGenerator(rt, co);
            g.state = .suspended_yield;
            return if (y.raw) y.value else builtins.iterResult(rt, y.value, false);
        },
        .returned => |v| {
            completeGenerator(rt, gen);
            return builtins.iterResult(rt, v, true);
        },
        .threw => return error.Thrown,
        .awaiting => return rt.bug("await in a generator"),
    }
}

fn completeGenerator(rt: *Runtime, gen: *heap.Object) void {
    const g = &gen.kind.generator;
    g.state = .completed;
    if (g.co) |co| {
        co.state = .done;
        destroyEngine(rt, co);
        g.co = null;
    }
}

fn destroyEngine(rt: *Runtime, co: *Coroutine) void {
    if (co.engine) |eng| {
        co.vtable.destroy(eng);
        co.engine = null;
    }
    rt.heap.releaseExternalCharge(&co.charge);
}
