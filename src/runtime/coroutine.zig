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

pub const Outcome = union(enum) {
    returned: Value,
    threw,
    awaiting: Value,
};

pub const ResumeFn = *const fn (engine: *anyopaque, val: Value, rejected: bool) Error!Outcome;

const CoroutineRoots = struct {
    promise: *heap.Object,
    coroutine: ?*Coroutine = null,

    fn register(self: *CoroutineRoots, rt: *Runtime) error{OutOfMemory}!void {
        try rt.addRoots(.{ .ctx = self, .mark = mark });
    }

    fn unregister(self: *CoroutineRoots, rt: *Runtime) void {
        rt.removeRoots(self);
    }

    fn mark(ctx: *anyopaque, h: *heap.Heap) void {
        const self: *CoroutineRoots = @ptrCast(@alignCast(ctx));
        h.markObj(&self.promise.obj);
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
    const outcome = resume_fn(eng, val, rejected) catch |e| {
        co.state = .done;
        destroyEngine(rt, co);
        return e;
    };
    try finishStep(rt, co, outcome);
}

pub fn finishStep(rt: *Runtime, co: *Coroutine, outcome: Outcome) Error!void {
    switch (outcome) {
        .returned => |v| {
            co.state = .done;
            destroyEngine(rt, co);
            try builtins.resolvePromiseValue(rt, co.promise, v);
        },
        .threw => {
            co.state = .done;
            destroyEngine(rt, co);
            const err_val = try rt.catchValue();
            try builtins.settlePromiseFromJob(rt, co.promise, true, err_val);
        },
        .awaiting => |v| {
            errdefer {
                co.state = .done;
                destroyEngine(rt, co);
            }
            const awaited_p_val = try builtins.resolveToPromise(rt, v);
            const awaited_p = awaited_p_val.object;
            const eng = co.engine.?;
            co.vtable.shrink(eng);
            const new_charge = co.vtable.ownedBytes(eng);
            try rt.heap.adjustCharge(&co.charge, new_charge);

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

fn destroyEngine(rt: *Runtime, co: *Coroutine) void {
    if (co.engine) |eng| {
        co.vtable.destroy(eng);
        co.engine = null;
    }
    rt.heap.releaseExternalCharge(&co.charge);
}
