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

/// How a resume continues the coroutine (D67); defined in heap.zig for the request queue.
pub const ResumeMode = heap.ResumeMode;

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
    return Value.fromObject(p_obj);
}

/// Resumes a suspended coroutine from an `.await_resume` microtask. A coroutine
/// already marked `.done` (e.g. from an earlier fault) is a no-op.
pub fn resumeCoroutine(rt: *Runtime, co: *Coroutine, val: Value, rejected: bool) Error!void {
    if (co.state == .done) return;
    std.debug.assert(co.state == .suspended);
    if (co.generator) |gen| {
        const mode: ResumeMode = if (rejected) .throw else if (co.resume_return) .@"return" else .next;
        co.resume_return = false;
        return runAsyncGenerator(rt, gen, mode, val);
    }
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

pub fn finishStep(rt: *Runtime, co: *Coroutine, outcome0: Outcome) Error!void {
    const promise = co.promise orelse {
        co.state = .done;
        destroyEngine(rt, co);
        return rt.bug("an async step on a generator coroutine");
    };
    var roots: CoroutineRoots = .{ .promise = promise, .coroutine = co };
    try roots.register(rt);
    defer roots.unregister(rt);
    var outcome = outcome0;
    while (true) {
        switch (outcome) {
            .returned => |v| {
                co.state = .done;
                destroyEngine(rt, co);
                try builtins.resolvePromiseValue(rt, promise, v);
                return;
            },
            .threw => {
                co.state = .done;
                destroyEngine(rt, co);
                const err_val = try rt.catchValue();
                try builtins.settlePromiseFromJob(rt, promise, true, err_val);
                return;
            },
            .yielded => {
                co.state = .done;
                destroyEngine(rt, co);
                return rt.bug("yield in an async function");
            },
            .awaiting => |v| {
                const awaited_p = builtins.resolveToPromise(rt, v) catch |e| {
                    if (e == error.Thrown) {
                        const err_val = try rt.catchValue();
                        const eng = co.engine orelse {
                            co.state = .done;
                            destroyEngine(rt, co);
                            return rt.bug("an awaiting coroutine without an engine");
                        };
                        co.state = .running;
                        const resume_fn: ResumeFn = @ptrCast(@alignCast(co.vtable.@"resume"));
                        outcome = resume_fn(eng, err_val, .throw) catch |re| {
                            co.state = .done;
                            destroyEngine(rt, co);
                            return re;
                        };
                        continue;
                    }
                    co.state = .done;
                    destroyEngine(rt, co);
                    return e;
                };
                try suspendAwaitPromise(rt, co, awaited_p.asObject());
                return;
            },
        }
    }
}

/// D56's `await` suspension on an already-resolved promise: a reaction on `awaited_p`
/// resumes `co` from an `.await_resume` microtask. On a fault the coroutine is done.
fn suspendAwaitPromise(rt: *Runtime, co: *Coroutine, awaited_p: *heap.Object) Error!void {
    errdefer {
        co.state = .done;
        destroyEngine(rt, co);
    }
    var root_buf = [_]Value{Value.fromObject(awaited_p)};
    var val_roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try val_roots.register(rt);
    defer val_roots.unregister(rt);
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
/// `.prototype` if that is an object, else %GeneratorPrototype% (%AsyncGeneratorPrototype%
/// for an async generator, D68). A throw from a parameter default propagates, and no
/// generator object is created.
pub fn startGenerator(
    rt: *Runtime,
    vtable: *const CoroutineVTable,
    func: Value,
    is_async: bool,
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
    const proto = if (proto_val.isObject()) proto_val.asObject() else if (is_async) r.async_generator_prototype else r.generator_prototype;
    return Value.fromObject(try rt.heap.newGenerator(proto, co, is_async));
}

/// `%GeneratorPrototype%.next/throw/return` on generator `gen` (D67): the iterator result,
/// or the raw inner result of a `yield*`.
pub fn resumeGenerator(rt: *Runtime, gen: *heap.Object, mode: ResumeMode, val: Value) Error!Value {
    const g = &gen.kind.generator;
    switch (g.state) {
        .executing => return rt.throw(.TypeError, &.{.{ .ascii = "Generator is already running" }}),
        .suspended_start => if (mode != .next) completeGenerator(rt, gen),
        .suspended_yield, .completed => {},
        .awaiting_return => return rt.bug("a sync generator awaiting return"),
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

// ---------------------------------------------------------------- Async generators (D68)

/// `%AsyncGeneratorPrototype%.next/throw/return` (AsyncGeneratorEnqueue): never throws a
/// JS exception; a bad receiver gives a rejected promise.
pub fn asyncGeneratorRequest(rt: *Runtime, this: Value, mode: ResumeMode, val: Value) Error!Value {
    const r = try builtins.realm(rt);
    const p = try rt.heap.newPromise(r.promise_prototype);
    var root_buf = [_]Value{ Value.fromObject(p), this, val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (!this.isObject() or this.asObject().kind != .generator or !this.asObject().kind.generator.is_async) {
        const name = switch (mode) {
            .next => "next",
            .throw => "throw",
            .@"return" => "return",
        };
        const e = rt.throw(.TypeError, &.{ .{ .ascii = name }, .{ .ascii = " method called on incompatible receiver" } });
        if (e != error.Thrown) return e;
        try builtins.settlePromiseFromJob(rt, p, true, try rt.catchValue());
        return root_buf[0];
    }
    const gen = this.asObject();
    const g = &gen.kind.generator;
    switch (mode) {
        .next => if (g.state == .completed) {
            root_buf[3] = try builtins.iterResult(rt, .undefined, true);
            try builtins.resolvePromiseValue(rt, p, root_buf[3]);
            return root_buf[0];
        },
        .throw => {
            if (g.state == .suspended_start) completeGenerator(rt, gen);
            if (g.state == .completed) {
                try builtins.settlePromiseFromJob(rt, p, true, val);
                return root_buf[0];
            }
        },
        .@"return" => {},
    }
    try rt.heap.pushAsyncGenRequest(gen, .{ .mode = mode, .value = val, .promise = p });
    switch (g.state) {
        .suspended_start => if (mode == .@"return") {
            completeGenerator(rt, gen);
            try awaitReturn(rt, gen);
        } else try resumeAsyncGenerator(rt, gen, mode, val),
        .completed => try awaitReturn(rt, gen), // only `return` gets here
        .suspended_yield => try resumeAsyncGenerator(rt, gen, mode, val),
        .executing, .awaiting_return => {},
    }
    return root_buf[0];
}

/// AsyncGeneratorResume from `suspended_start`/`suspended_yield` with the head request. A
/// `return(v)` at a `yield` first awaits `v` (AsyncGeneratorUnwrapYieldResumption): the
/// driver does that await, so it covers `yield` and async `yield*` on both engines alike.
fn resumeAsyncGenerator(rt: *Runtime, gen: *heap.Object, mode: ResumeMode, val: Value) Error!void {
    const g = &gen.kind.generator;
    const at_yield = g.state == .suspended_yield;
    g.state = .executing;
    if (mode == .@"return" and at_yield) {
        const co = g.co.?;
        var root_buf = [_]Value{ Value.fromObject(gen), val };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);
        co.resume_return = true;
        const awaited_p = builtins.resolveToPromise(rt, val) catch |e| {
            if (e == error.Thrown) {
                co.resume_return = false;
                const err_val = try rt.catchValue();
                return runAsyncGenerator(rt, gen, .throw, err_val);
            }
            faultAsyncGenerator(rt, gen);
            return e;
        };
        suspendAwaitPromise(rt, co, awaited_p.asObject()) catch |e| {
            faultAsyncGenerator(rt, gen);
            return e;
        };
        return;
    }
    return runAsyncGenerator(rt, gen, mode, val);
}

/// Runs the generator's engine with `mode`/`val` and handles each outcome, continuing
/// without suspending while a `yield` finds more queued requests.
fn runAsyncGenerator(rt: *Runtime, gen: *heap.Object, mode0: ResumeMode, val0: Value) Error!void {
    const g = &gen.kind.generator;
    var mode = mode0;
    var val = val0;
    var gen_root_buf = [_]Value{ Value.fromObject(gen), .undefined };
    var gen_roots: rt_mod.ValueRoots = .{ .values = &gen_root_buf };
    try gen_roots.register(rt);
    defer gen_roots.unregister(rt);
    while (true) {
        const co = g.co orelse return rt.bug("an executing async generator without a coroutine");
        const eng = co.engine orelse return rt.bug("an executing async generator without an engine");
        rt.checkNativeStack() catch |e| { // D60
            faultAsyncGenerator(rt, gen);
            return e;
        };
        co.state = .running;
        const resume_fn: ResumeFn = @ptrCast(@alignCast(co.vtable.@"resume"));
        const outcome = resume_fn(eng, val, mode) catch |e| {
            faultAsyncGenerator(rt, gen);
            return e;
        };
        switch (outcome) {
            .awaiting => |v| {
                gen_root_buf[1] = v;
                const awaited_p = builtins.resolveToPromise(rt, v) catch |e| {
                    if (e == error.Thrown) {
                        mode = .throw;
                        val = try rt.catchValue();
                        gen_root_buf[1] = val;
                        continue;
                    }
                    faultAsyncGenerator(rt, gen);
                    return e;
                };
                gen_root_buf[1] = .undefined;
                suspendAwaitPromise(rt, co, awaited_p.asObject()) catch |e| {
                    faultAsyncGenerator(rt, gen);
                    return e;
                };
                return;
            },
            .yielded => |y| {
                // AsyncGeneratorYield: settle the head request, then go on with the next one.
                // `raw` (a `yield*` round) means nothing here: async `yield*` yields values.
                suspendGenerator(rt, co) catch |e| {
                    faultAsyncGenerator(rt, gen);
                    return e;
                };
                g.state = .suspended_yield;
                try completeStep(rt, gen, y.value, false, false);
                if (g.state != .suspended_yield or g.queue.items.len == 0) return;
                const next = g.queue.items[0];
                if (next.mode == .@"return") return resumeAsyncGenerator(rt, gen, next.mode, next.value);
                g.state = .executing;
                mode = next.mode;
                val = next.value;
            },
            .returned => |v| {
                completeGenerator(rt, gen);
                var root_buf = [_]Value{v};
                var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
                try roots.register(rt);
                defer roots.unregister(rt);
                try completeStep(rt, gen, v, true, false);
                return drainQueue(rt, gen);
            },
            .threw => {
                completeGenerator(rt, gen);
                const err_val = try rt.catchValue();
                var root_buf = [_]Value{err_val};
                var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
                try roots.register(rt);
                defer roots.unregister(rt);
                try completeStep(rt, gen, err_val, true, true);
                return drainQueue(rt, gen);
            },
        }
    }
}

/// AsyncGeneratorCompleteStep: removes the head request and resolves its promise with
/// `{ value, done }`, or rejects it with `value`.
fn completeStep(rt: *Runtime, gen: *heap.Object, value: Value, done: bool, rejected: bool) Error!void {
    const g = &gen.kind.generator;
    if (g.queue.items.len == 0) return rt.bug("an async generator step without a request");
    const p = g.queue.items[0].promise;
    var root_buf = [_]Value{ Value.fromObject(p), value, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    if (!rejected) root_buf[2] = try builtins.iterResult(rt, value, done);
    _ = g.queue.orderedRemove(0);
    if (rejected) {
        try builtins.settlePromiseFromJob(rt, p, true, value);
    } else {
        try builtins.resolvePromiseValue(rt, p, root_buf[2]);
    }
}

/// AsyncGeneratorDrainQueue on a completed generator: `next` → `{ undefined, true }`,
/// `throw` → rejected, `return(v)` → AsyncGeneratorAwaitReturn (which drains on after it).
fn drainQueue(rt: *Runtime, gen: *heap.Object) Error!void {
    const g = &gen.kind.generator;
    while (g.queue.items.len > 0) {
        const head = g.queue.items[0];
        switch (head.mode) {
            .@"return" => return awaitReturn(rt, gen),
            .throw => try completeStep(rt, gen, head.value, true, true),
            .next => try completeStep(rt, gen, .undefined, true, false),
        }
    }
    g.state = .completed;
}

/// AsyncGeneratorAwaitReturn: awaits the head `return(v)` request's `v` with a promise
/// reaction, then settles that request and drains the rest.
fn awaitReturn(rt: *Runtime, gen: *heap.Object) Error!void {
    const g = &gen.kind.generator;
    g.state = .awaiting_return;
    var root_buf = [_]Value{ Value.fromObject(gen), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    root_buf[1] = builtins.resolveToPromise(rt, g.queue.items[0].value) catch |e| {
        if (e != error.Thrown) return e;
        root_buf[1] = try rt.catchValue();
        g.state = .completed;
        try completeStep(rt, gen, root_buf[1], true, true);
        return drainQueue(rt, gen);
    };
    root_buf[2] = Value.fromClosure(try rt.heap.newNativeClosure(@ptrCast(&awaitReturnFulfilled), gen));
    root_buf[3] = Value.fromClosure(try rt.heap.newNativeClosure(@ptrCast(&awaitReturnRejected), gen));
    try builtins.performPromiseThen(rt, root_buf[1].asObject(), root_buf[2], root_buf[3]);
}

fn awaitReturnFulfilled(rt: *Runtime, gen: *heap.Object, args: []const Value) Error!Value {
    try awaitReturnSettled(rt, gen, if (args.len > 0) args[0] else .undefined, false);
    return .undefined;
}

fn awaitReturnRejected(rt: *Runtime, gen: *heap.Object, args: []const Value) Error!Value {
    try awaitReturnSettled(rt, gen, if (args.len > 0) args[0] else .undefined, true);
    return .undefined;
}

fn awaitReturnSettled(rt: *Runtime, gen: *heap.Object, v: Value, rejected: bool) Error!void {
    const g = &gen.kind.generator;
    if (g.state != .awaiting_return) return rt.bug("an AwaitReturn reaction on a generator not awaiting it");
    try completeStep(rt, gen, v, true, rejected);
    return drainQueue(rt, gen);
}

/// An uncatchable fault in an async generator: the engine is gone and the generator is
/// completed; queued request promises stay pending (D56's rule).
fn faultAsyncGenerator(rt: *Runtime, gen: *heap.Object) void {
    completeGenerator(rt, gen);
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
