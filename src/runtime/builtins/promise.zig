//! Promise and Promise.prototype built-ins.

const std = @import("std");
const Value = @import("../value.zig").Value;
const Native = @import("../value.zig").Native;
const heap_mod = @import("../heap.zig");
const Object = heap_mod.Object;
const rt_mod = @import("../runtime.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const ops = @import("../ops.zig");
const object = @import("../object.zig");
const builtins = @import("../builtins.zig");
const common = @import("common.zig");
const function_error = @import("function_error.zig");
const iterator = @import("iterator.zig");
const proxy_reflect = @import("proxy_reflect.zig");

pub fn register(rt: *Runtime, r: *const builtins.Realm) Error!void {
    try common.method(rt, r.promise_prototype, "then", &promise_then);
    try common.method(rt, r.promise_prototype, "catch", &promise_catch);
    try common.method(rt, r.promise_prototype, "finally", &promise_finally);
    try common.method(rt, r.promise_namespace, "resolve", &promise_resolve_static);
    try common.method(rt, r.promise_namespace, "reject", &promise_reject_static);
    try common.method(rt, r.promise_namespace, "all", &promise_all_static);
    try common.method(rt, r.promise_namespace, "allSettled", &promise_all_settled_static);
    try common.method(rt, r.promise_namespace, "race", &promise_race_static);
    try common.method(rt, r.promise_namespace, "any", &promise_any_static);
    try common.method(rt, r.promise_namespace, "withResolvers", &promise_with_resolvers_static);
    try common.method(rt, r.promise_namespace, "try", &promise_try_static);
    try common.immutableConstant(rt, r.promise_namespace, "prototype", Value.fromObject(r.promise_prototype));
    try common.constant(rt, r.promise_prototype, "constructor", Value.fromNative(&builtins.promise_global));
    try object.defineAccessor(rt, Value.fromObject(r.promise_namespace), .{ .symbol = r.sym_species }, Value.fromNative(&common.species_getter), false, false);
    try common.defineToStringTag(rt, r.promise_prototype, r.sym_to_string_tag, "Promise");
}

const promise_resolve_static: Native = .{ .name = "resolve", .length = 1, .call = promiseResolveStatic };

const promise_reject_static: Native = .{ .name = "reject", .length = 1, .call = promiseRejectStatic };

const promise_with_resolvers_static: Native = .{ .name = "withResolvers", .call = promiseWithResolversStatic };

const promise_try_static: Native = .{ .name = "try", .length = 1, .call = promiseTryStatic };

const promise_all_static: Native = .{ .name = "all", .length = 1, .call = promiseAllStatic };

const promise_all_settled_static: Native = .{ .name = "allSettled", .length = 1, .call = promiseAllSettledStatic };

const promise_race_static: Native = .{ .name = "race", .length = 1, .call = promiseRaceStatic };

const promise_any_static: Native = .{ .name = "any", .length = 1, .call = promiseAnyStatic };

const promise_then: Native = .{ .name = "then", .length = 2, .call = promiseThen };

const promise_catch: Native = .{ .name = "catch", .length = 1, .call = promiseCatch };

const promise_finally: Native = .{ .name = "finally", .length = 1, .call = promiseFinally };

fn thisPromise(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .promise) return this.asObject();
    return common.unsupportedReceiver(rt, name);
}

fn capReactionRun(rt: *Runtime, env: *Object, val: Value, is_reject_branch: bool) Error!Value {
    var root_buf = [_]Value{ Value.fromObject(env), val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const res_cap = env.kind.array.items[0];
    const rej_cap = env.kind.array.items[1];
    const user_cb = env.kind.array.items[2];
    if (user_cb.isFunction()) {
        if (rt.callCallable(user_cb, .undefined, &.{val})) |ret| {
            root_buf[2] = ret;
            _ = try rt.callCallable(res_cap, .undefined, &.{ret});
        } else |e| {
            if (e != error.Thrown) return e;
            const err_val = try rt.catchValue();
            root_buf[2] = err_val;
            _ = try rt.callCallable(rej_cap, .undefined, &.{err_val});
        }
    } else if (is_reject_branch) {
        _ = try rt.callCallable(rej_cap, .undefined, &.{val});
    } else {
        _ = try rt.callCallable(res_cap, .undefined, &.{val});
    }
    return .undefined;
}

fn capFulfillCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    return capReactionRun(rt, env, common.arg(args, 0), false);
}

fn capRejectCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    return capReactionRun(rt, env, common.arg(args, 0), true);
}

pub fn promiseThen(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const p_obj = try thisPromise(rt, this, "then");
    const raw_f = common.arg(args, 0);
    const raw_r = common.arg(args, 1);
    const on_fulfilled: Value = if (raw_f.isFunction()) raw_f else .undefined;
    const on_rejected: Value = if (raw_r.isFunction()) raw_r else .undefined;

    var root_buf = [_]Value{ Value.fromObject(p_obj), on_fulfilled, on_rejected, .undefined, .undefined, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const ctor = try common.speciesConstructor(rt, this, Value.fromNative(&builtins.promise_global));
    root_buf[3] = ctor;

    if (ctor.isNative() and ctor.asNative() == &builtins.promise_global) {
        const r = try builtins.realm(rt);
        const child = try rt.heap.newPromise(r.promise_prototype);
        root_buf[4] = Value.fromObject(child);
        try performPromiseThenCap(rt, p_obj, on_fulfilled, on_rejected, child);
        return Value.fromObject(child);
    }

    const cap = try newPromiseCapabilityRecord(rt, ctor);
    root_buf[4] = cap.promise;
    root_buf[5] = cap.resolve;
    root_buf[6] = cap.reject;

    const ful_env = try rt.heap.newArray(null);
    root_buf[7] = Value.fromObject(ful_env);
    try rt.heap.appendElements(ful_env, &.{ cap.resolve, cap.reject, on_fulfilled });
    const ful_cb = Value.fromClosure(try rt.heap.newNativeClosure(&capFulfillCb, ful_env));
    root_buf[7] = ful_cb;

    const rej_env = try rt.heap.newArray(null);
    root_buf[8] = Value.fromObject(rej_env);
    try rt.heap.appendElements(rej_env, &.{ cap.resolve, cap.reject, on_rejected });
    const rej_cb = Value.fromClosure(try rt.heap.newNativeClosure(&capRejectCb, rej_env));
    root_buf[8] = rej_cb;

    try performPromiseThenCap(rt, p_obj, ful_cb, rej_cb, null);
    return cap.promise;
}

/// PerformPromiseThen without a result capability (internal reactions, D68): `p` must be
/// a native promise; the handlers are callables.
pub fn performPromiseThen(rt: *Runtime, p_obj: *Object, on_fulfilled: Value, on_rejected: Value) Error!void {
    return performPromiseThenCap(rt, p_obj, on_fulfilled, on_rejected, null);
}

/// PerformPromiseThen with result promise `child` (or none): a non-callable handler
/// passes the settlement through to `child`.
pub fn performPromiseThenCap(rt: *Runtime, p_obj: *Object, on_fulfilled: Value, on_rejected: Value, child: ?*Object) Error!void {
    const pr = &p_obj.kind.promise;
    if (pr.state == .pending) {
        pr.reactions.ensureUnusedCapacity(rt.heap.allocator(), 1) catch |e| return rt.heap.failed(e);
        pr.reactions.appendAssumeCapacity(.{ .child = child, .on_fulfilled = on_fulfilled, .on_rejected = on_rejected });
        if (child) |ch| rt.heap.barrierObj(&p_obj.obj, &ch.obj);
        rt.heap.barrier(&p_obj.obj, null, on_fulfilled);
        rt.heap.barrier(&p_obj.obj, null, on_rejected);
    } else {
        const is_rejected = (pr.state == .rejected);
        const cb = if (is_rejected) on_rejected else on_fulfilled;
        try rt.microtasks.ensureUnusedCapacity(rt.gpa, 1);
        rt.microtasks.appendAssumeCapacity(.{
            .kind = if (cb.isFunction()) .reaction else .adopt,
            .child = child,
            .cb = cb,
            .arg = pr.result,
            .adopt_rejected = is_rejected,
        });
    }
}

fn promiseCatch(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const on_rejected = common.arg(args, 0);
    var root_buf = [_]Value{ this, on_rejected, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const then_fn = try object.get(rt, this, try object.named(rt, "then"));
    root_buf[2] = then_fn;
    return rt.callCallable(then_fn, this, &.{ .undefined, on_rejected });
}

fn promiseFinally(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Promise.prototype.finally called on non-object" }});
    }
    const raw_f = common.arg(args, 0);
    var root_buf = [_]Value{ this, raw_f, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const ctor = try common.speciesConstructor(rt, this, Value.fromNative(&builtins.promise_global));
    root_buf[2] = ctor;

    var then_arg: Value = raw_f;
    var catch_arg: Value = raw_f;
    if (raw_f.isFunction()) {
        const env = try rt.heap.newArray(null);
        root_buf[3] = Value.fromObject(env);
        try rt.heap.appendElements(env, &.{ raw_f, ctor });
        const then_fn = try rt.heap.newNativeClosureWithLength(&finallyThenCb, env, 1);
        root_buf[4] = Value.fromClosure(then_fn);
        const catch_fn = try rt.heap.newNativeClosureWithLength(&finallyCatchCb, env, 1);
        root_buf[5] = Value.fromClosure(catch_fn);
        then_arg = root_buf[4];
        catch_arg = root_buf[5];
    }
    const then_method = try object.get(rt, this, try object.named(rt, "then"));
    if (!then_method.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Promise.prototype.finally: then is not a function" }});
    }
    return rt.callCallable(then_method, this, &.{ then_arg, catch_arg });
}

fn finallyThenCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    return finallyRunCb(rt, env, common.arg(args, 0), false);
}

fn finallyCatchCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    return finallyRunCb(rt, env, common.arg(args, 0), true);
}

fn finallyRunCb(rt: *Runtime, env: *Object, val: Value, is_catch: bool) Error!Value {
    var root_buf = [_]Value{ Value.fromObject(env), val, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const on_finally = env.kind.array.items[0];
    const ctor = env.kind.array.items[1];
    const res = try rt.callCallable(on_finally, .undefined, &.{});
    root_buf[2] = res;
    const p_val = try promiseResolveWithCtor(rt, ctor, res);
    root_buf[3] = p_val;

    const env2 = try rt.heap.newArray(null);
    root_buf[4] = Value.fromObject(env2);
    try rt.heap.appendElements(env2, &.{val});

    const cb_ptr: *const anyopaque = if (is_catch) &finallyThrower else &finallyValueThunk;
    const cb = try rt.heap.newNativeClosure(cb_ptr, env2);
    root_buf[5] = Value.fromClosure(cb);
    const then_method = try object.get(rt, p_val, try object.named(rt, "then"));
    if (!then_method.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "then is not a function" }});
    }
    return rt.callCallable(then_method, p_val, &.{root_buf[5]});
}

fn finallyValueThunk(_: *Runtime, env: *Object, _: []const Value) Error!Value {
    return env.kind.array.items[0];
}

fn finallyThrower(rt: *Runtime, env: *Object, _: []const Value) Error!Value {
    return rt.throwValue(env.kind.array.items[0]);
}

pub fn promiseWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor Promise requires 'new'" }});
}

pub fn promiseConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const exec = try common.requireCallable(rt, common.arg(args, 0));
    const r = try builtins.realm(rt);
    const p = try rt.heap.newPromise(r.promise_prototype);
    const res_cap = try rt.heap.newPromiseCapability(p, false);
    const rej_cap = try rt.heap.newPromiseCapability(p, true);
    const p_val: Value = Value.fromObject(p);
    const res_val: Value = Value.fromClosure(res_cap);
    const rej_val: Value = Value.fromClosure(rej_cap);

    var root_buf = [_]Value{ p_val, exec, res_val, rej_val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    _ = rt.callCallable(exec, .undefined, &.{ res_val, rej_val }) catch |e| {
        if (e != error.Thrown) return e;
        const err_val = try rt.catchValue();
        if (!p.kind.promise.already_resolved) {
            try settlePromiseFromJob(rt, p, true, err_val);
        }
    };
    return p_val;
}

pub fn resolveToPromise(rt: *Runtime, x: Value) Error!Value {
    const r = try builtins.realm(rt);
    if (x.isObject() and x.asObject().kind == .promise and x.asObject().proto == r.promise_prototype) {
        return x;
    }
    const p = try rt.heap.newPromise(r.promise_prototype);
    var root_buf = [_]Value{ Value.fromObject(p), x };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    try resolvePromiseValue(rt, p, x);
    return Value.fromObject(p);
}

const PromiseCapRecord = struct {
    promise: Value,
    resolve: Value,
    reject: Value,
};

fn getCapabilitiesExecutor(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    if (!env.kind.array.items[0].isUndefined() or !env.kind.array.items[1].isUndefined()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Promise capability executor already called" }});
    }
    rt.heap.storeElement(env, 0, common.arg(args, 0));
    rt.heap.storeElement(env, 1, common.arg(args, 1));
    return .undefined;
}

fn newPromiseCapabilityRecord(rt: *Runtime, ctor: Value) Error!PromiseCapRecord {
    if (!ctor.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Promise constructor is not an object" }});
    }
    if (ctor.isNative() and ctor.asNative() == &builtins.promise_global) {
        const r = try builtins.realm(rt);
        const p = try rt.heap.newPromise(r.promise_prototype);
        var root_buf = [_]Value{ Value.fromObject(p), .undefined, .undefined };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);
        const res_fn = try rt.heap.newPromiseCapability(p, false);
        root_buf[1] = Value.fromClosure(res_fn);
        const rej_fn = try rt.heap.newPromiseCapability(p, true);
        root_buf[2] = Value.fromClosure(rej_fn);
        return .{ .promise = root_buf[0], .resolve = root_buf[1], .reject = root_buf[2] };
    }
    var root_buf = [_]Value{ ctor, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const env = try rt.heap.newArray(null);
    root_buf[1] = Value.fromObject(env);
    try rt.heap.appendElements(env, &.{ .undefined, .undefined });

    const exec = try rt.heap.newNativeClosureWithLength(&getCapabilitiesExecutor, env, 2);
    root_buf[2] = Value.fromClosure(exec);

    const promise_val = try proxy_reflect.constructWithNewTarget(rt, ctor, &.{root_buf[2]}, ctor);
    root_buf[3] = promise_val;
    const res_fn = env.kind.array.items[0];
    const rej_fn = env.kind.array.items[1];
    if (!res_fn.isFunction() or !rej_fn.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Promise resolve or reject function is not callable" }});
    }
    return .{ .promise = promise_val, .resolve = res_fn, .reject = rej_fn };
}

fn promiseResolveWithCtor(rt: *Runtime, ctor: Value, x: Value) Error!Value {
    if (!ctor.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Promise.resolve called on non-object" }});
    }
    var root_buf = [_]Value{ ctor, x, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (x.isObject() and x.asObject().kind == .promise) {
        const x_ctor = try object.get(rt, x, try object.named(rt, "constructor"));
        if (ops.strictEquals(x_ctor, ctor)) return x;
    }
    const cap = try newPromiseCapabilityRecord(rt, ctor);
    root_buf[2] = cap.promise;
    root_buf[3] = cap.resolve;
    _ = try rt.callCallable(cap.resolve, .undefined, &.{x});
    return cap.promise;
}

fn promiseResolveStatic(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return promiseResolveWithCtor(rt, this, common.arg(args, 0));
}

fn promiseRejectStatic(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const reason = common.arg(args, 0);
    var root_buf = [_]Value{ this, reason, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const cap = try newPromiseCapabilityRecord(rt, this);
    root_buf[2] = cap.promise;
    root_buf[3] = cap.reject;
    _ = try rt.callCallable(cap.reject, .undefined, &.{reason});
    return cap.promise;
}

fn promiseWithResolversStatic(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    var root_buf = [_]Value{ this, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const cap = try newPromiseCapabilityRecord(rt, this);
    root_buf[1] = cap.promise;
    root_buf[2] = cap.resolve;
    root_buf[3] = cap.reject;

    const out = try rt.heap.newObject(r.object_prototype);
    root_buf[4] = Value.fromObject(out);
    try object.define(rt, out, try object.named(rt, "promise"), cap.promise);
    try object.define(rt, out, try object.named(rt, "resolve"), cap.resolve);
    try object.define(rt, out, try object.named(rt, "reject"), cap.reject);
    return Value.fromObject(out);
}

fn promiseTryStatic(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Promise.try called on non-object" }});
    }
    const cb = common.arg(args, 0);
    var root_buf = [_]Value{ this, cb, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const call_args = if (args.len > 1) args[1..] else &[_]Value{};
    var threw = false;
    const outcome: Value = blk: {
        if (!cb.isFunction()) {
            threw = true;
            break :blk try function_error.makeEngineError(rt, .TypeError, try rt.heap.ascii("Promise.try requires a callable argument"));
        }
        break :blk rt.callCallable(cb, .undefined, call_args) catch |e| {
            if (e != error.Thrown) return e;
            threw = true;
            break :blk try rt.catchValue();
        };
    };
    root_buf[5] = outcome;
    if (threw) {
        const cap = try newPromiseCapabilityRecord(rt, this);
        root_buf[2] = cap.promise;
        root_buf[3] = cap.resolve;
        root_buf[4] = cap.reject;
        _ = try rt.callCallable(cap.reject, .undefined, &.{root_buf[5]});
        return cap.promise;
    }
    return promiseResolveWithCtor(rt, this, root_buf[5]);
}

const CombinatorKind = enum { all, all_settled, race, any };

fn promiseAllStatic(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return promiseCombinator(rt, .all, this, common.arg(args, 0));
}

fn promiseAllSettledStatic(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return promiseCombinator(rt, .all_settled, this, common.arg(args, 0));
}

fn promiseRaceStatic(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return promiseCombinator(rt, .race, this, common.arg(args, 0));
}

fn promiseAnyStatic(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return promiseCombinator(rt, .any, this, common.arg(args, 0));
}

fn capabilityExecutor(rt: *Runtime, cap_arr: *Object, args: []const Value) Error!Value {
    if (!cap_arr.kind.array.items[0].isUndefined() or !cap_arr.kind.array.items[1].isUndefined()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Promise capability executor already called" }});
    }
    rt.heap.storeElement(cap_arr, 0, common.arg(args, 0));
    rt.heap.storeElement(cap_arr, 1, common.arg(args, 1));
    return .undefined;
}

fn rejectCapabilityCaught(rt: *Runtime, rej_cap: Value, p_out: Value) Error!Value {
    const err_val = try rt.catchValue();
    var root_buf = [_]Value{ p_out, rej_cap, err_val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    _ = try rt.callCallable(rej_cap, .undefined, &.{err_val});
    return p_out;
}

fn promiseCombinator(rt: *Runtime, comptime kind: CombinatorKind, ctor: Value, iterable: Value) Error!Value {
    if (!function_error.isConstructor(ctor)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Promise combinator requires a constructor" }});
    }
    const r = try builtins.realm(rt);

    var root_buf = [_]Value{
        ctor,
        iterable,
        .undefined, // [2] p_out
        .undefined, // [3] res_cap
        .undefined, // [4] rej_cap
        .undefined, // [5] promise_resolve
        .undefined, // [6] iter
        .undefined, // [7] results_arr
        .undefined, // [8] state_arr: [p_out, results_arr, remaining, res_cap, rej_cap, settled]
        .undefined, // [9] elem / next_p
        .undefined, // [10] elem_env: [state_arr, index, called]
        .undefined, // [11] cb_f
        .undefined, // [12] cb_r
    };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const is_builtin_promise = ctor.isNative() and ctor.asNative() == &builtins.promise_global;
    if (is_builtin_promise) {
        const p_obj = try rt.heap.newPromise(r.promise_prototype);
        root_buf[2] = Value.fromObject(p_obj);
        root_buf[3] = Value.fromClosure(try rt.heap.newPromiseCapability(p_obj, false));
        root_buf[4] = Value.fromClosure(try rt.heap.newPromiseCapability(p_obj, true));
    } else {
        const cap_arr = try rt.heap.newArray(null);
        root_buf[9] = Value.fromObject(cap_arr);
        try rt.heap.appendElements(cap_arr, &.{ .undefined, .undefined });
        const exec = try rt.heap.newNativeClosureWithLength(&capabilityExecutor, cap_arr, 2);
        root_buf[10] = Value.fromClosure(exec);
        root_buf[2] = try proxy_reflect.constructWithNewTarget(rt, ctor, &.{Value.fromClosure(exec)}, ctor);
        const res_cap = cap_arr.kind.array.items[0];
        const rej_cap = cap_arr.kind.array.items[1];
        if (!res_cap.isFunction() or !rej_cap.isFunction()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Promise resolve or reject function is not callable" }});
        }
        root_buf[3] = res_cap;
        root_buf[4] = rej_cap;
        root_buf[9] = .undefined;
        root_buf[10] = .undefined;
    }

    const p_out = root_buf[2];
    const res_cap = root_buf[3];
    const rej_cap = root_buf[4];

    const promise_resolve = object.get(rt, ctor, try object.named(rt, "resolve")) catch |e| {
        if (e != error.Thrown) return e;
        return rejectCapabilityCaught(rt, rej_cap, p_out);
    };
    root_buf[5] = promise_resolve;
    if (!promise_resolve.isFunction()) {
        const err_val = try function_error.makeEngineError(rt, .TypeError, try rt.heap.ascii("Promise resolve is not a function"));
        root_buf[9] = err_val;
        _ = try rt.callCallable(rej_cap, .undefined, &.{err_val});
        return p_out;
    }

    const iter = iterator.getIterator(rt, iterable) catch |e| {
        if (e != error.Thrown) return e;
        return rejectCapabilityCaught(rt, rej_cap, p_out);
    };
    root_buf[6] = Value.fromObject(iter);

    if (kind != .race) {
        const results_arr = try rt.heap.newArray(r.array_prototype);
        root_buf[7] = Value.fromObject(results_arr);
        const state_arr = try rt.heap.newArray(null);
        root_buf[8] = Value.fromObject(state_arr);
        try rt.heap.appendElements(state_arr, &.{
            p_out,
            Value.fromObject(results_arr),
            Value.fromNumber(0),
            res_cap,
            rej_cap,
            Value.fromBool(false),
        });
    }

    var count: usize = 0;
    while (true) {
        const maybe_elem = iterator.iteratorNextVal(rt, iter) catch |e| {
            if (e != error.Thrown) return e;
            return rejectCapabilityCaught(rt, rej_cap, p_out);
        };
        const elem = maybe_elem orelse break;
        root_buf[9] = elem;

        const next_p = (if (is_builtin_promise and promise_resolve.isNative() and promise_resolve.asNative() == &promise_resolve_static)
            resolveToPromise(rt, elem)
        else
            rt.callCallable(promise_resolve, ctor, &.{elem})) catch |e| {
            if (e != error.Thrown) return e;
            try iterator.iteratorClose(rt, iter, true);
            return rejectCapabilityCaught(rt, rej_cap, p_out);
        };
        root_buf[9] = next_p;

        if (kind != .race) {
            try rt.heap.appendElements(root_buf[7].asObject(), &.{.undefined});
            const elem_env = try rt.heap.newArray(null);
            root_buf[10] = Value.fromObject(elem_env);
            try rt.heap.appendElements(elem_env, &.{ root_buf[8], Value.fromNumber(@floatFromInt(count)), Value.fromBool(false) });
        }

        const cb_f: Value = switch (kind) {
            .all => Value.fromClosure(try rt.heap.newNativeClosureWithLength(&allFulfillCb, root_buf[10].asObject(), 1)),
            .all_settled => Value.fromClosure(try rt.heap.newNativeClosureWithLength(&allSettledFulfillCb, root_buf[10].asObject(), 1)),
            .race, .any => res_cap,
        };
        root_buf[11] = cb_f;

        const cb_r: Value = switch (kind) {
            .all, .race => rej_cap,
            .all_settled => Value.fromClosure(try rt.heap.newNativeClosureWithLength(&allSettledRejectCb, root_buf[10].asObject(), 1)),
            .any => Value.fromClosure(try rt.heap.newNativeClosureWithLength(&anyRejectCb, root_buf[10].asObject(), 1)),
        };
        root_buf[12] = cb_r;

        const then_fn = object.get(rt, next_p, try object.named(rt, "then")) catch |e| {
            if (e != error.Thrown) return e;
            try iterator.iteratorClose(rt, iter, true);
            return rejectCapabilityCaught(rt, rej_cap, p_out);
        };
        _ = rt.callCallable(then_fn, next_p, &.{ cb_f, cb_r }) catch |e| {
            if (e != error.Thrown) return e;
            try iterator.iteratorClose(rt, iter, true);
            return rejectCapabilityCaught(rt, rej_cap, p_out);
        };
        count += 1;
    }

    if (count == 0) {
        switch (kind) {
            .all, .all_settled => {
                _ = rt.callCallable(res_cap, .undefined, &.{root_buf[7]}) catch |e| {
                    if (e != error.Thrown) return e;
                    return rejectCapabilityCaught(rt, rej_cap, p_out);
                };
            },
            .race => {},
            .any => {
                const agg = try makeAggregateError(rt, root_buf[7]);
                root_buf[9] = agg;
                _ = rt.callCallable(rej_cap, .undefined, &.{agg}) catch |e| {
                    if (e != error.Thrown) return e;
                    return rejectCapabilityCaught(rt, rej_cap, p_out);
                };
            },
        }
    } else if (kind != .race) {
        // Set remaining count after iteration so reactions (queued via microtasks) see final count.
        const state_arr = root_buf[8].asObject();
        const cur_rem: isize = @intFromFloat(state_arr.kind.array.items[2].asNumber());
        const total_rem = cur_rem + @as(isize, @intCast(count));
        rt.heap.storeElement(state_arr, 2, Value.fromNumber(@floatFromInt(total_rem)));
        if (total_rem == 0 and !state_arr.kind.array.items[5].asBool()) {
            rt.heap.storeElement(state_arr, 5, Value.fromBool(true));
            switch (kind) {
                .all, .all_settled => {
                    _ = rt.callCallable(res_cap, .undefined, &.{root_buf[7]}) catch |e| {
                        if (e != error.Thrown) return e;
                        return rejectCapabilityCaught(rt, rej_cap, p_out);
                    };
                },
                .any => {
                    const agg = try makeAggregateError(rt, root_buf[7]);
                    root_buf[9] = agg;
                    _ = rt.callCallable(rej_cap, .undefined, &.{agg}) catch |e| {
                        if (e != error.Thrown) return e;
                        return rejectCapabilityCaught(rt, rej_cap, p_out);
                    };
                },
                .race => unreachable,
            }
        }
    }

    return p_out;
}

fn allFulfillCb(rt: *Runtime, elem_env: *Object, args: []const Value) Error!Value {
    if (elem_env.kind.array.items[2].asBool()) return .undefined;
    rt.heap.storeElement(elem_env, 2, Value.fromBool(true));
    const state_arr = elem_env.kind.array.items[0].asObject();
    if (state_arr.kind.array.items[5].asBool()) return .undefined;

    const idx: usize = @intFromFloat(elem_env.kind.array.items[1].asNumber());
    const results_arr = state_arr.kind.array.items[1].asObject();
    rt.heap.storeElement(results_arr, idx, common.arg(args, 0));

    const rem: isize = @intFromFloat(state_arr.kind.array.items[2].asNumber());
    const next_rem = rem - 1;
    rt.heap.storeElement(state_arr, 2, Value.fromNumber(@floatFromInt(next_rem)));
    if (next_rem == 0) {
        rt.heap.storeElement(state_arr, 5, Value.fromBool(true));
        _ = try rt.callCallable(state_arr.kind.array.items[3], .undefined, &.{Value.fromObject(results_arr)});
    }
    return .undefined;
}

fn allSettledFulfillCb(rt: *Runtime, elem_env: *Object, args: []const Value) Error!Value {
    return allSettledCb(rt, elem_env, common.arg(args, 0), false);
}

fn allSettledRejectCb(rt: *Runtime, elem_env: *Object, args: []const Value) Error!Value {
    return allSettledCb(rt, elem_env, common.arg(args, 0), true);
}

fn allSettledCb(rt: *Runtime, elem_env: *Object, val: Value, is_rejected: bool) Error!Value {
    if (elem_env.kind.array.items[2].asBool()) return .undefined;
    rt.heap.storeElement(elem_env, 2, Value.fromBool(true));
    const state_arr = elem_env.kind.array.items[0].asObject();
    if (state_arr.kind.array.items[5].asBool()) return .undefined;

    var root_buf = [_]Value{ Value.fromObject(elem_env), val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const r = try builtins.realm(rt);
    const obj = try rt.heap.newObject(r.object_prototype);
    root_buf[2] = Value.fromObject(obj);
    const status_str = try rt.heap.newString(&.{.{ .ascii = if (is_rejected) "rejected" else "fulfilled" }});
    root_buf[3] = Value.fromString(status_str);
    try object.define(rt, obj, try object.named(rt, "status"), root_buf[3]);
    try object.define(rt, obj, try object.named(rt, if (is_rejected) "reason" else "value"), val);

    const idx: usize = @intFromFloat(elem_env.kind.array.items[1].asNumber());
    const results_arr = state_arr.kind.array.items[1].asObject();

    rt.heap.storeElement(results_arr, idx, root_buf[2]);
    const rem: isize = @intFromFloat(state_arr.kind.array.items[2].asNumber());
    const next_rem = rem - 1;
    rt.heap.storeElement(state_arr, 2, Value.fromNumber(@floatFromInt(next_rem)));
    if (next_rem == 0) {
        rt.heap.storeElement(state_arr, 5, Value.fromBool(true));
        _ = try rt.callCallable(state_arr.kind.array.items[3], .undefined, &.{Value.fromObject(results_arr)});
    }
    return .undefined;
}

fn anyRejectCb(rt: *Runtime, elem_env: *Object, args: []const Value) Error!Value {
    if (elem_env.kind.array.items[2].asBool()) return .undefined;
    rt.heap.storeElement(elem_env, 2, Value.fromBool(true));
    const state_arr = elem_env.kind.array.items[0].asObject();
    if (state_arr.kind.array.items[5].asBool()) return .undefined;

    const idx: usize = @intFromFloat(elem_env.kind.array.items[1].asNumber());
    const errors_arr = state_arr.kind.array.items[1].asObject();
    rt.heap.storeElement(errors_arr, idx, common.arg(args, 0));

    const rem: isize = @intFromFloat(state_arr.kind.array.items[2].asNumber());
    const next_rem = rem - 1;
    rt.heap.storeElement(state_arr, 2, Value.fromNumber(@floatFromInt(next_rem)));
    if (next_rem == 0) {
        rt.heap.storeElement(state_arr, 5, Value.fromBool(true));
        var root_buf = [_]Value{ Value.fromObject(state_arr), Value.fromObject(errors_arr), .undefined };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);

        const agg = try makeAggregateError(rt, Value.fromObject(errors_arr));
        root_buf[2] = agg;
        _ = try rt.callCallable(state_arr.kind.array.items[4], .undefined, &.{agg});
    }
    return .undefined;
}

fn makeAggregateError(rt: *Runtime, errors_arr_val: Value) Error!Value {
    const r = try builtins.realm(rt);
    var root_buf = [_]Value{ errors_arr_val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const err_obj = try rt.heap.newObject(r.aggregate_error_prototype);
    err_obj.ordinary_tag = .@"error";
    root_buf[1] = Value.fromObject(err_obj);
    const msg_str = try rt.heap.newString(&.{.{ .ascii = "All promises were rejected" }});
    root_buf[2] = Value.fromString(msg_str);
    try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("message"), .{ .value = root_buf[2], .enumerable = false });
    try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("errors"), .{ .value = errors_arr_val, .enumerable = false });
    return root_buf[1];
}

pub fn callPromiseCapability(rt: *Runtime, p_obj: *Object, is_reject: bool, args: []const Value) Error!Value {
    if (p_obj.kind.promise.already_resolved) return .undefined;
    const val = common.arg(args, 0);
    var root_buf = [_]Value{ Value.fromObject(p_obj), val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (is_reject) {
        try settlePromiseFromJob(rt, p_obj, true, val);
    } else {
        try resolvePromiseValue(rt, p_obj, val);
    }
    return .undefined;
}

fn isDefaultPromiseForFastResolve(rt: *Runtime, p_obj: *Object) Error!bool {
    const r = try builtins.realm(rt);
    if (p_obj.proto != r.promise_prototype) return false;
    const ctor_pk = heap_mod.PropKey.fromAtom(try rt.heap.internAscii("constructor"));
    if (p_obj.props.get(ctor_pk) != null) return false;
    const proto_ctor = r.promise_prototype.props.get(ctor_pk) orelse return false;
    if (proto_ctor.is_accessor or !proto_ctor.value.isNative() or proto_ctor.value.asNative() != &builtins.promise_global) return false;
    const sp = r.promise_namespace.props.get(heap_mod.PropKey.fromSymbol(r.sym_species)) orelse return false;
    return sp.is_accessor and sp.value.isNative() and sp.value.asNative() == &common.species_getter;
}

/// Atomic Promise resolution: all allocations and queue reservations succeed
/// before any Promise state or reaction list is mutated.
pub fn resolvePromiseValue(rt: *Runtime, p_obj: *Object, val: Value) Error!void {
    if (val.isObject() and val.asObject() == p_obj) {
        const r = try builtins.realm(rt);
        var err_roots_buf = [_]Value{ Value.fromObject(p_obj), .undefined, .undefined };
        var err_roots: rt_mod.ValueRoots = .{ .values = &err_roots_buf };
        try err_roots.register(rt);
        defer err_roots.unregister(rt);

        const err_obj = try rt.heap.newObject(r.type_error_prototype);
        err_obj.ordinary_tag = .@"error";
        err_roots_buf[1] = Value.fromObject(err_obj);
        const msg_str = try rt.heap.newString(&.{.{ .ascii = "Chaining cycle detected for promise" }});
        err_roots_buf[2] = Value.fromString(msg_str);
        try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("message"), .{ .value = err_roots_buf[2], .enumerable = false });
        try settlePromiseFromJob(rt, p_obj, true, err_roots_buf[1]);
        return;
    }

    if (val.isObjectLike()) {
        var root_buf = [_]Value{ Value.fromObject(p_obj), val, .undefined, .undefined, .undefined };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);

        const then_val = object.get(rt, val, try object.named(rt, "then")) catch |e| {
            if (e == error.Thrown) {
                try settlePromiseFromJob(rt, p_obj, true, try rt.catchValue());
                return;
            }
            return e;
        };
        root_buf[2] = then_val;
        if (val.isObject() and val.asObject().kind == .promise and then_val.isNative() and then_val.asNative() == &promise_then and try isDefaultPromiseForFastResolve(rt, val.asObject())) {
            try rt.microtasks.ensureUnusedCapacity(rt.gpa, 1);
            p_obj.kind.promise.already_resolved = true;
            rt.microtasks.appendAssumeCapacity(.{
                .kind = .resolve_promise,
                .child = p_obj,
                .cb = .undefined,
                .arg = val,
            });
            return;
        }
        if (then_val.isFunction()) {
            const env = try rt.heap.newArray(null);
            root_buf[3] = Value.fromObject(env);
            try rt.heap.appendElements(env, &.{ Value.fromObject(p_obj), val, then_val, Value.fromBool(false) });
            const job_cb = try rt.heap.newNativeClosure(&thenableJobCb, env);
            root_buf[4] = Value.fromClosure(job_cb);
            try rt.microtasks.ensureUnusedCapacity(rt.gpa, 1);
            p_obj.kind.promise.already_resolved = true;
            rt.microtasks.appendAssumeCapacity(.{
                .kind = .reaction,
                .child = null,
                .cb = root_buf[4],
                .arg = .undefined,
            });
            return;
        }
    }

    try settlePromiseFromJob(rt, p_obj, false, val);
}

fn thenableJobCb(rt: *Runtime, env: *Object, _: []const Value) Error!Value {
    var root_buf = [_]Value{ Value.fromObject(env), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const res_fn = try rt.heap.newNativeClosureWithLength(&thenableResolveCb, env, 1);
    root_buf[1] = Value.fromClosure(res_fn);
    const rej_fn = try rt.heap.newNativeClosureWithLength(&thenableRejectCb, env, 1);
    root_buf[2] = Value.fromClosure(rej_fn);

    _ = rt.callCallable(env.kind.array.items[2], env.kind.array.items[1], &.{ root_buf[1], root_buf[2] }) catch |e| {
        if (e == error.Thrown) {
            if (!env.kind.array.items[3].asBool()) {
                rt.heap.storeElement(env, 3, Value.fromBool(true));
                try settlePromiseFromJob(rt, env.kind.array.items[0].asObject(), true, try rt.catchValue());
            } else {
                _ = rt.catchValue() catch {};
            }
            return .undefined;
        }
        return e;
    };
    return .undefined;
}

fn thenableResolveCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    if (env.kind.array.items[3].asBool()) return .undefined;
    rt.heap.storeElement(env, 3, Value.fromBool(true));
    try resolvePromiseValue(rt, env.kind.array.items[0].asObject(), common.arg(args, 0));
    return .undefined;
}

fn thenableRejectCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    if (env.kind.array.items[3].asBool()) return .undefined;
    rt.heap.storeElement(env, 3, Value.fromBool(true));
    try settlePromiseFromJob(rt, env.kind.array.items[0].asObject(), true, common.arg(args, 0));
    return .undefined;
}

pub fn adoptPromiseNow(rt: *Runtime, p_obj: *Object, other: *Object) Error!void {
    const other_pr = &other.kind.promise;
    if (other_pr.state == .pending) {
        try other_pr.reactions.ensureUnusedCapacity(rt.heap.allocator(), 1);
        other_pr.reactions.appendAssumeCapacity(.{ .child = p_obj, .on_fulfilled = .undefined, .on_rejected = .undefined });
        rt.heap.barrier(&other.obj, null, Value.fromObject(p_obj));
    } else {
        try rt.microtasks.ensureUnusedCapacity(rt.gpa, 1);
        rt.microtasks.appendAssumeCapacity(.{
            .kind = .adopt,
            .child = p_obj,
            .cb = .undefined,
            .arg = other_pr.result,
            .adopt_rejected = (other_pr.state == .rejected),
        });
    }
}

/// Atomic Promise settlement: reserves microtask queue capacity before mutating
/// Promise state or moving reactions.
pub fn settlePromiseFromJob(rt: *Runtime, p_obj: *Object, is_rejected: bool, val: Value) Error!void {
    const pr = &p_obj.kind.promise;
    if (pr.state != .pending) return;
    try rt.microtasks.ensureUnusedCapacity(rt.gpa, pr.reactions.items.len);

    pr.already_resolved = true;
    pr.state = if (is_rejected) .rejected else .fulfilled;
    rt.heap.barrier(&p_obj.obj, pr.result, val);
    pr.result = val;

    for (pr.reactions.items) |rx| {
        if (rx.coroutine) |co| {
            rt.microtasks.appendAssumeCapacity(.{
                .kind = .await_resume,
                .coroutine = co,
                .arg = val,
                .adopt_rejected = is_rejected,
            });
            continue;
        }
        const cb = if (is_rejected) rx.on_rejected else rx.on_fulfilled;
        const is_adopt = !cb.isFunction();
        rt.microtasks.appendAssumeCapacity(.{
            .kind = if (is_adopt) .adopt else .reaction,
            .child = rx.child,
            .cb = cb,
            .arg = val,
            .adopt_rejected = is_rejected,
        });
    }
    pr.reactions.clearRetainingCapacity();
}

// ---------------------------------------------------------------- Iterators (M14.4, M36 D66)
