//! Iterators, ES2025 Iterator Helpers, Generators, and Async Generators.

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
const coroutine = @import("../coroutine.zig");
const builtins = @import("../builtins.zig");
const array = @import("array.zig");
const common = @import("common.zig");
const promise = @import("promise.zig");
const regexp = @import("regexp.zig");

pub fn register(rt: *Runtime, r: *const builtins.Realm) Error!void {
    try common.method(rt, r.iterator_prototype, "next", &iterator_next);
    try common.symbolMethod(rt, r.iterator_prototype, r.sym_iterator, &iterator_self);
    try common.immutableConstant(rt, r.iterator_namespace, "prototype", Value.fromObject(r.iterator_prototype));
    try common.method(rt, r.iterator_namespace, "from", &iterator_from);
    try object.defineAccessor(rt, Value.fromObject(r.iterator_prototype), try object.named(rt, "constructor"), Value.fromNative(&iterator_proto_ctor_get), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.iterator_prototype), try object.named(rt, "constructor"), Value.fromNative(&iterator_proto_ctor_set), true, false);
    try object.defineAccessor(rt, Value.fromObject(r.iterator_prototype), .{ .symbol = r.sym_to_string_tag }, Value.fromNative(&iterator_proto_tag_get), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.iterator_prototype), .{ .symbol = r.sym_to_string_tag }, Value.fromNative(&iterator_proto_tag_set), true, false);
    try common.method(rt, r.iterator_prototype, "map", &iterator_map);
    try common.method(rt, r.iterator_prototype, "filter", &iterator_filter);
    try common.method(rt, r.iterator_prototype, "take", &iterator_take);
    try common.method(rt, r.iterator_prototype, "drop", &iterator_drop);
    try common.method(rt, r.iterator_prototype, "flatMap", &iterator_flat_map);
    try common.method(rt, r.iterator_prototype, "reduce", &iterator_reduce);
    try common.method(rt, r.iterator_prototype, "toArray", &iterator_to_array);
    try common.method(rt, r.iterator_prototype, "forEach", &iterator_for_each);
    try common.method(rt, r.iterator_prototype, "some", &iterator_some);
    try common.method(rt, r.iterator_prototype, "every", &iterator_every);
    try common.method(rt, r.iterator_prototype, "find", &iterator_find);
    try common.method(rt, r.array_iterator_prototype, "next", &iterator_next);
    try common.defineToStringTag(rt, r.array_iterator_prototype, r.sym_to_string_tag, "Array Iterator");
    try common.method(rt, r.string_iterator_prototype, "next", &iterator_next);
    try common.defineToStringTag(rt, r.string_iterator_prototype, r.sym_to_string_tag, "String Iterator");
    try common.method(rt, r.regexp_string_iterator_prototype, "next", &iterator_next);
    try common.defineToStringTag(rt, r.regexp_string_iterator_prototype, r.sym_to_string_tag, "RegExp String Iterator");
    try common.method(rt, r.map_iterator_prototype, "next", &iterator_next);
    try common.defineToStringTag(rt, r.map_iterator_prototype, r.sym_to_string_tag, "Map Iterator");
    try common.method(rt, r.set_iterator_prototype, "next", &iterator_next);
    try common.defineToStringTag(rt, r.set_iterator_prototype, r.sym_to_string_tag, "Set Iterator");
    try common.method(rt, r.iterator_helper_prototype, "next", &iterator_helper_next);
    try common.method(rt, r.iterator_helper_prototype, "return", &iterator_helper_return);
    try common.defineToStringTag(rt, r.iterator_helper_prototype, r.sym_to_string_tag, "Iterator Helper");
    try common.method(rt, r.iterator_wrap_prototype, "next", &iterator_wrap_next);
    try common.method(rt, r.iterator_wrap_prototype, "return", &iterator_wrap_return);
    try common.method(rt, r.generator_prototype, "next", &generator_next);
    try common.method(rt, r.generator_prototype, "return", &generator_return);
    try common.method(rt, r.generator_prototype, "throw", &generator_throw);
    try common.symbolMethod(rt, r.async_iterator_prototype, r.sym_async_iterator, &async_iterator_self);
    try common.method(rt, r.async_generator_prototype, "next", &async_generator_next);
    try common.method(rt, r.async_generator_prototype, "return", &async_generator_return);
    try common.method(rt, r.async_generator_prototype, "throw", &async_generator_throw);
    try common.method(rt, r.async_from_sync_iterator_prototype, "next", &async_from_sync_next);
    try common.method(rt, r.async_from_sync_iterator_prototype, "return", &async_from_sync_return);
    try common.method(rt, r.async_from_sync_iterator_prototype, "throw", &async_from_sync_throw);
    // %GeneratorFunction.prototype%.prototype ⇄ %GeneratorPrototype%.constructor (and the
    // async pair); both non-writable and non-enumerable, as in node (D68).
    try common.link(rt, r.generator_function_prototype, "prototype", r.generator_prototype);
    try common.link(rt, r.generator_prototype, "constructor", r.generator_function_prototype);
    try common.link(rt, r.async_generator_function_prototype, "prototype", r.async_generator_prototype);
    try common.link(rt, r.async_generator_prototype, "constructor", r.async_generator_function_prototype);
    try common.defineToStringTag(rt, r.generator_prototype, r.sym_to_string_tag, "Generator");
    try common.defineToStringTag(rt, r.async_generator_prototype, r.sym_to_string_tag, "AsyncGenerator");
    try common.defineToStringTag(rt, r.generator_function_prototype, r.sym_to_string_tag, "GeneratorFunction");
    try common.defineToStringTag(rt, r.async_generator_function_prototype, r.sym_to_string_tag, "AsyncGeneratorFunction");
    try common.defineToStringTag(rt, r.async_function_prototype, r.sym_to_string_tag, "AsyncFunction");
}

const iterator_next: Native = .{ .name = "next", .call = iteratorNext };

const iterator_self: Native = .{ .name = "[Symbol.iterator]", .call = iteratorSelf };

fn iteratorSelf(_: *Runtime, this: Value, _: []const Value) Error!Value {
    return this;
}

// ---------------------------------------------------------------- ES2025 Iterator Helpers

const iterator_from: Native = .{ .name = "from", .length = 1, .call = iteratorFrom };

const iterator_proto_ctor_get: Native = .{ .name = "get constructor", .call = iteratorProtoCtorGet };

const iterator_proto_ctor_set: Native = .{ .name = "set constructor", .length = 1, .call = iteratorProtoCtorSet };

const iterator_proto_tag_get: Native = .{ .name = "get [Symbol.toStringTag]", .call = iteratorProtoTagGet };

const iterator_proto_tag_set: Native = .{ .name = "set [Symbol.toStringTag]", .length = 1, .call = iteratorProtoTagSet };

const iterator_map: Native = .{ .name = "map", .length = 1, .call = iteratorMap };

const iterator_filter: Native = .{ .name = "filter", .length = 1, .call = iteratorFilter };

const iterator_take: Native = .{ .name = "take", .length = 1, .call = iteratorTake };

const iterator_drop: Native = .{ .name = "drop", .length = 1, .call = iteratorDrop };

const iterator_flat_map: Native = .{ .name = "flatMap", .length = 1, .call = iteratorFlatMap };

const iterator_reduce: Native = .{ .name = "reduce", .length = 1, .call = iteratorReduce };

const iterator_to_array: Native = .{ .name = "toArray", .length = 0, .call = iteratorToArray };

const iterator_for_each: Native = .{ .name = "forEach", .length = 1, .call = iteratorForEach };

const iterator_some: Native = .{ .name = "some", .length = 1, .call = iteratorSome };

const iterator_every: Native = .{ .name = "every", .length = 1, .call = iteratorEvery };

const iterator_find: Native = .{ .name = "find", .length = 1, .call = iteratorFind };

const iterator_helper_next: Native = .{ .name = "next", .length = 0, .call = iteratorHelperNext };

const iterator_helper_return: Native = .{ .name = "return", .length = 0, .call = iteratorHelperReturn };

const iterator_wrap_next: Native = .{ .name = "next", .length = 0, .call = iteratorWrapNext };

const iterator_wrap_return: Native = .{ .name = "return", .length = 0, .call = iteratorWrapReturn };

pub fn iteratorWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor Iterator requires 'new'" }});
}

pub fn iteratorConstruct(rt: *Runtime, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Abstract class Iterator not directly constructable" }});
}

fn iteratorProtoCtorGet(_: *Runtime, _: Value, _: []const Value) Error!Value {
    return Value.fromNative(&builtins.iterator_global);
}

fn iteratorProtoCtorSet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.constructor setter called on non-object" }});
    }
    if (this.isObject() and this.asObject() == r.iterator_prototype) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot set constructor on Iterator.prototype" }});
    }
    const v = common.arg(args, 0);
    const k = try object.named(rt, "constructor");
    if (this.isObject()) {
        if (try object.ownProp(rt, this.asObject(), k)) |_| {
            try object.setStrict(rt, this, k, v);
            return .undefined;
        }
        try object.define(rt, this.asObject(), k, v);
        return .undefined;
    }
    try object.setStrict(rt, this, k, v);
    return .undefined;
}

fn iteratorProtoTagGet(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return Value.fromString(try rt.heap.ascii("Iterator"));
}

fn iteratorProtoTagSet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype[Symbol.toStringTag] setter called on non-object" }});
    }
    if (this.isObject() and this.asObject() == r.iterator_prototype) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot set Symbol.toStringTag on Iterator.prototype" }});
    }
    const v = common.arg(args, 0);
    const k: object.Key = .{ .symbol = r.sym_to_string_tag };
    if (this.isObject()) {
        if (try object.ownProp(rt, this.asObject(), k)) |_| {
            try object.setStrict(rt, this, k, v);
            return .undefined;
        }
        try object.define(rt, this.asObject(), k, v);
        return .undefined;
    }
    try object.setStrict(rt, this, k, v);
    return .undefined;
}

fn iteratorCloseDirect(rt: *Runtime, iter: Value, is_throw: bool) Error!void {
    if (!iter.isObjectLike()) return;
    if (is_throw) {
        const saved_thrown = rt.thrown_value;
        const saved_exc = rt.exception;
        rt.thrown_value = null;
        rt.exception = null;
        defer {
            rt.thrown_value = saved_thrown;
            rt.exception = saved_exc;
        }
        // The stashed exception is off `rt` while `return()` runs, so root it here.
        var root_buf = [_]Value{
            saved_thrown orelse .undefined,
            if (saved_exc) |ex| Value.fromString(ex.message) else .undefined,
            if (saved_exc) |ex| (if (ex.stack) |st| Value.fromString(st) else .undefined) else .undefined,
        };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);
        if (object.getMethod(rt, iter, try object.named(rt, "return")) catch null) |ret_fn| {
            _ = rt.callCallable(ret_fn, iter, &.{}) catch {};
        }
        return;
    }
    if (try object.getMethod(rt, iter, try object.named(rt, "return"))) |ret_fn| {
        const res = try rt.callCallable(ret_fn, iter, &.{});
        if (!res.isObjectLike()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Iterator return result is not an object" }});
        }
    }
}

fn iteratorStepDirect(rt: *Runtime, iter: Value, next_method: Value) Error!?Value {
    const res = try rt.callCallable(next_method, iter, &.{});
    if (!res.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
    }
    var root_buf = [_]Value{res};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const done = try object.get(rt, res, try object.named(rt, "done"));
    if (ops.toBoolean(done)) return null;
    return try object.get(rt, res, try object.named(rt, "value"));
}

fn makeIterResult(rt: *Runtime, val: Value, done: bool) Error!Value {
    const r = try builtins.realm(rt);
    var root_buf = [_]Value{ val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const o = try rt.heap.newObject(r.object_prototype);
    root_buf[1] = Value.fromObject(o);
    try object.define(rt, o, try object.named(rt, "value"), val);
    try object.define(rt, o, try object.named(rt, "done"), Value.fromBool(done));
    return Value.fromObject(o);
}

fn iteratorFrom(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const o = common.arg(args, 0);
    if (!o.isObjectLike() and !o.isString()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.from called on non-object" }});
    }
    const r = try builtins.realm(rt);
    var root_buf = [_]Value{ o, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var iter_val: Value = o;
    if (try object.getMethod(rt, o, .{ .symbol = r.sym_iterator })) |iter_fn| {
        iter_val = try rt.callCallable(iter_fn, o, &.{});
        root_buf[1] = iter_val;
        if (!iter_val.isObjectLike()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.from: Symbol.iterator did not return an object" }});
        }
    }
    const next_fn = try object.get(rt, iter_val, try object.named(rt, "next"));
    root_buf[2] = next_fn;

    // If iter_val already inherits from Iterator.prototype, return it directly.
    if (try object.ordinaryHasInstance(rt, Value.fromNative(&builtins.iterator_global), iter_val)) {
        return iter_val;
    }

    const env = try rt.heap.newArray(null);
    root_buf[3] = Value.fromObject(env);
    try rt.heap.appendElements(env, &.{ iter_val, next_fn });
    return Value.fromObject(try rt.heap.newIterator(r.iterator_wrap_prototype, root_buf[3], .wrap));
}

fn iteratorWrapNextVal(rt: *Runtime, iter: *Object) Error!?Value {
    const env = iter.kind.iterator.target.asObject();
    return iteratorStepDirect(rt, env.kind.array.items[0], env.kind.array.items[1]);
}

fn iteratorWrapNext(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().kind != .iterator or this.asObject().kind.iterator.kind != .wrap) {
        return rt.throw(.TypeError, &.{.{ .ascii = "WrapForValidIterator.next called on incompatible receiver" }});
    }
    const env = this.asObject().kind.iterator.target.asObject();
    return rt.callCallable(env.kind.array.items[1], env.kind.array.items[0], &.{});
}

fn iteratorWrapReturn(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().kind != .iterator or this.asObject().kind.iterator.kind != .wrap) {
        return rt.throw(.TypeError, &.{.{ .ascii = "WrapForValidIterator.return called on incompatible receiver" }});
    }
    const env = this.asObject().kind.iterator.target.asObject();
    const underlying = env.kind.array.items[0];
    if (try object.getMethod(rt, underlying, try object.named(rt, "return"))) |ret_fn| {
        return rt.callCallable(ret_fn, underlying, &.{});
    }
    return makeIterResult(rt, .undefined, true);
}

// Helper env layout:
// [0]=kind (0=map, 1=filter, 2=take, 3=drop, 4=flatMap)
// [1]=underlying iter, [2]=underlying next_method, [3]=fn or remaining,
// [4]=counter, [5]=state (0=suspendedStart, 1=executing, 2=completed),
// [6]=inner_iter (flatMap), [7]=inner_next (flatMap)

fn newIteratorHelper(rt: *Runtime, kind_id: f64, iter: Value, next_fn: Value, param: Value) Error!Value {
    const r = try builtins.realm(rt);
    const env = try rt.heap.newArray(null);
    var root_buf = [_]Value{ iter, next_fn, param, Value.fromObject(env) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    try rt.heap.appendElements(env, &.{
        Value.fromNumber(kind_id),
        iter,
        next_fn,
        param,
        Value.fromNumber(0),
        Value.fromNumber(0),
        .undefined,
        .undefined,
    });
    return Value.fromObject(try rt.heap.newIterator(r.iterator_helper_prototype, Value.fromObject(env), .helper));
}

fn iteratorMap(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.map called on non-object" }});
    const cb = common.arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.map callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    return newIteratorHelper(rt, 0, this, next_fn, cb);
}

fn iteratorFilter(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.filter called on non-object" }});
    const cb = common.arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.filter callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    return newIteratorHelper(rt, 1, this, next_fn, cb);
}

fn iteratorTakeOrDrop(rt: *Runtime, this: Value, args: []const Value, kind_id: f64) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator helper called on non-object" }});
    var root_buf = [_]Value{ this, common.arg(args, 0), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const num_lim = ops.toNumber(rt, root_buf[1]) catch |e| {
        if (e == error.Thrown) try iteratorCloseDirect(rt, this, true);
        return e;
    };
    if (std.math.isNan(num_lim)) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.RangeError, &.{.{ .ascii = "Iterator limit must not be NaN" }});
    }
    if (std.math.isFinite(num_lim) and num_lim > 9007199254740991.0) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.RangeError, &.{.{ .ascii = "Iterator limit must not exceed Number.MAX_SAFE_INTEGER" }});
    }
    const int_lim = if (!std.math.isFinite(num_lim) or num_lim == 0.0) num_lim else @trunc(num_lim);
    if (int_lim < 0.0) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.RangeError, &.{.{ .ascii = "Iterator limit must be non-negative" }});
    }
    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    return newIteratorHelper(rt, kind_id, this, next_fn, Value.fromNumber(if (int_lim == 0.0) 0.0 else int_lim));
}

fn iteratorTake(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return iteratorTakeOrDrop(rt, this, args, 2);
}

fn iteratorDrop(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return iteratorTakeOrDrop(rt, this, args, 3);
}

fn iteratorFlatMap(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.flatMap called on non-object" }});
    const cb = common.arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.flatMap callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    return newIteratorHelper(rt, 4, this, next_fn, cb);
}

fn iteratorHelperNextVal(rt: *Runtime, iter: *Object) Error!?Value {
    const env = iter.kind.iterator.target.asObject();
    const state = env.kind.array.items[5].asNumber();
    if (state == 2.0) return null;
    if (state == 1.0) return rt.throw(.TypeError, &.{.{ .ascii = "Generator is already executing" }});

    var root_buf = [_]Value{ Value.fromObject(iter), Value.fromObject(env), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    rt.heap.storeElement(env, 5, Value.fromNumber(1.0));
    errdefer rt.heap.storeElement(env, 5, Value.fromNumber(2.0));

    const kind_id: u8 = @intFromFloat(env.kind.array.items[0].asNumber());
    const underlying = env.kind.array.items[1];
    const next_fn = env.kind.array.items[2];

    switch (kind_id) {
        0 => { // map
            const val = (try iteratorStepDirect(rt, underlying, next_fn)) orelse {
                rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
                return null;
            };
            root_buf[2] = val;
            const counter = env.kind.array.items[4].asNumber();
            rt.heap.storeElement(env, 4, Value.fromNumber(counter + 1.0));
            const mapped = rt.callCallable(env.kind.array.items[3], .undefined, &.{ val, Value.fromNumber(counter) }) catch |e| {
                if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
                return e;
            };
            rt.heap.storeElement(env, 5, Value.fromNumber(0.0));
            return mapped;
        },
        1 => { // filter
            while (true) {
                const val = (try iteratorStepDirect(rt, underlying, next_fn)) orelse {
                    rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
                    return null;
                };
                root_buf[2] = val;
                const counter = env.kind.array.items[4].asNumber();
                rt.heap.storeElement(env, 4, Value.fromNumber(counter + 1.0));
                const keep = rt.callCallable(env.kind.array.items[3], .undefined, &.{ val, Value.fromNumber(counter) }) catch |e| {
                    if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
                    return e;
                };
                if (ops.toBoolean(keep)) {
                    rt.heap.storeElement(env, 5, Value.fromNumber(0.0));
                    return root_buf[2];
                }
            }
        },
        2 => { // take
            const rem = env.kind.array.items[3].asNumber();
            if (rem == 0.0) {
                rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
                try iteratorCloseDirect(rt, underlying, false);
                return null;
            }
            if (std.math.isFinite(rem)) rt.heap.storeElement(env, 3, Value.fromNumber(rem - 1.0));
            const val = (try iteratorStepDirect(rt, underlying, next_fn)) orelse {
                rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
                return null;
            };
            rt.heap.storeElement(env, 5, Value.fromNumber(0.0));
            return val;
        },
        3 => { // drop
            var rem = env.kind.array.items[3].asNumber();
            while (rem > 0.0) {
                if (std.math.isFinite(rem)) {
                    rem -= 1.0;
                    rt.heap.storeElement(env, 3, Value.fromNumber(rem));
                }
                if ((try iteratorStepDirect(rt, underlying, next_fn)) == null) {
                    rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
                    return null;
                }
            }
            const val = (try iteratorStepDirect(rt, underlying, next_fn)) orelse {
                rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
                return null;
            };
            rt.heap.storeElement(env, 5, Value.fromNumber(0.0));
            return val;
        },
        4 => { // flatMap
            const r = try builtins.realm(rt);
            while (true) {
                if (!env.kind.array.items[6].isUndefined()) {
                    const inner_iter = env.kind.array.items[6];
                    const inner_next = env.kind.array.items[7];
                    const maybe_inner = iteratorStepDirect(rt, inner_iter, inner_next) catch |e| {
                        rt.heap.storeElement(env, 6, .undefined);
                        rt.heap.storeElement(env, 7, .undefined);
                        if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
                        return e;
                    };
                    if (maybe_inner) |iv| {
                        rt.heap.storeElement(env, 5, Value.fromNumber(0.0));
                        return iv;
                    }
                    rt.heap.storeElement(env, 6, .undefined);
                    rt.heap.storeElement(env, 7, .undefined);
                }
                const val = (try iteratorStepDirect(rt, underlying, next_fn)) orelse {
                    rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
                    return null;
                };
                root_buf[2] = val;
                const counter = env.kind.array.items[4].asNumber();
                rt.heap.storeElement(env, 4, Value.fromNumber(counter + 1.0));
                const mapped = rt.callCallable(env.kind.array.items[3], .undefined, &.{ val, Value.fromNumber(counter) }) catch |e| {
                    if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
                    return e;
                };
                root_buf[2] = mapped;
                if (!mapped.isObjectLike()) {
                    try iteratorCloseDirect(rt, underlying, false);
                    return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.flatMap mapper did not return an object" }});
                }
                const inner_iter: Value = blk: {
                    const maybe_sym = object.getMethod(rt, mapped, .{ .symbol = r.sym_iterator }) catch |e| {
                        if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
                        return e;
                    };
                    if (maybe_sym) |iter_m| {
                        const res = rt.callCallable(iter_m, mapped, &.{}) catch |e| {
                            if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
                            return e;
                        };
                        if (!res.isObjectLike()) {
                            try iteratorCloseDirect(rt, underlying, false);
                            return rt.throw(.TypeError, &.{.{ .ascii = "flatMap inner iterator is not an object" }});
                        }
                        break :blk res;
                    }
                    break :blk mapped;
                };
                root_buf[3] = inner_iter;
                const inner_next = object.get(rt, inner_iter, try object.named(rt, "next")) catch |e| {
                    if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
                    return e;
                };
                rt.heap.storeElement(env, 6, inner_iter);
                rt.heap.storeElement(env, 7, inner_next);
            }
        },
        else => unreachable,
    }
}

fn iteratorHelperNext(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().kind != .iterator or this.asObject().kind.iterator.kind != .helper) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator Helper.next called on incompatible receiver" }});
    }
    if (try iteratorHelperNextVal(rt, this.asObject())) |v| {
        return makeIterResult(rt, v, false);
    }
    return makeIterResult(rt, .undefined, true);
}

fn iteratorHelperReturn(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().kind != .iterator or this.asObject().kind.iterator.kind != .helper) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator Helper.return called on incompatible receiver" }});
    }
    const env = this.asObject().kind.iterator.target.asObject();
    const state = env.kind.array.items[5].asNumber();
    if (state == 1.0) return rt.throw(.TypeError, &.{.{ .ascii = "Generator is already executing" }});
    if (state == 2.0) return makeIterResult(rt, .undefined, true);

    var root_buf = [_]Value{ this, Value.fromObject(env) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
    const inner_iter = env.kind.array.items[6];
    const underlying = env.kind.array.items[1];
    if (!inner_iter.isUndefined()) {
        rt.heap.storeElement(env, 6, .undefined);
        rt.heap.storeElement(env, 7, .undefined);
        iteratorCloseDirect(rt, inner_iter, false) catch |e| {
            if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
            return e;
        };
    }
    try iteratorCloseDirect(rt, underlying, false);
    return makeIterResult(rt, .undefined, true);
}

fn iteratorToArray(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.toArray called on non-object" }});
    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ this, Value.fromObject(out), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    while (try iteratorStepDirect(rt, this, next_fn)) |val| {
        root_buf[3] = val;
        try rt.heap.appendElement(out, val);
        root_buf[3] = .undefined;
    }
    return Value.fromObject(out);
}

fn iteratorForEach(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.forEach called on non-object" }});
    const cb = common.arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.forEach callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    var counter: f64 = 0;
    while (try iteratorStepDirect(rt, this, next_fn)) |val| : (counter += 1) {
        root_buf[3] = val;
        _ = rt.callCallable(cb, .undefined, &.{ val, Value.fromNumber(counter) }) catch |e| {
            if (e == error.Thrown) try iteratorCloseDirect(rt, this, true);
            return e;
        };
        root_buf[3] = .undefined;
    }
    return .undefined;
}

fn iteratorReduce(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.reduce called on non-object" }});
    const cb = common.arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.reduce callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, common.arg(args, 1), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[3] = next_fn;
    var counter: f64 = 0;
    if (args.len < 2) {
        const first = (try iteratorStepDirect(rt, this, next_fn)) orelse {
            return rt.throw(.TypeError, &.{.{ .ascii = "Reduce of empty iterator with no initial value" }});
        };
        root_buf[2] = first;
        counter = 1;
    }
    while (try iteratorStepDirect(rt, this, next_fn)) |val| : (counter += 1) {
        root_buf[4] = val;
        root_buf[2] = rt.callCallable(cb, .undefined, &.{ root_buf[2], val, Value.fromNumber(counter) }) catch |e| {
            if (e == error.Thrown) try iteratorCloseDirect(rt, this, true);
            return e;
        };
        root_buf[4] = .undefined;
    }
    return root_buf[2];
}

fn iteratorSome(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.some called on non-object" }});
    const cb = common.arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.some callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    var counter: f64 = 0;
    while (try iteratorStepDirect(rt, this, next_fn)) |val| : (counter += 1) {
        root_buf[3] = val;
        const res = rt.callCallable(cb, .undefined, &.{ val, Value.fromNumber(counter) }) catch |e| {
            if (e == error.Thrown) try iteratorCloseDirect(rt, this, true);
            return e;
        };
        if (ops.toBoolean(res)) {
            try iteratorCloseDirect(rt, this, false);
            return Value.fromBool(true);
        }
        root_buf[3] = .undefined;
    }
    return Value.fromBool(false);
}

fn iteratorEvery(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.every called on non-object" }});
    const cb = common.arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.every callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    var counter: f64 = 0;
    while (try iteratorStepDirect(rt, this, next_fn)) |val| : (counter += 1) {
        root_buf[3] = val;
        const res = rt.callCallable(cb, .undefined, &.{ val, Value.fromNumber(counter) }) catch |e| {
            if (e == error.Thrown) try iteratorCloseDirect(rt, this, true);
            return e;
        };
        if (!ops.toBoolean(res)) {
            try iteratorCloseDirect(rt, this, false);
            return Value.fromBool(false);
        }
        root_buf[3] = .undefined;
    }
    return Value.fromBool(true);
}

fn iteratorFind(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.find called on non-object" }});
    const cb = common.arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.find callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    var counter: f64 = 0;
    while (try iteratorStepDirect(rt, this, next_fn)) |val| : (counter += 1) {
        root_buf[3] = val;
        const res = rt.callCallable(cb, .undefined, &.{ val, Value.fromNumber(counter) }) catch |e| {
            if (e == error.Thrown) try iteratorCloseDirect(rt, this, true);
            return e;
        };
        if (ops.toBoolean(res)) {
            try iteratorCloseDirect(rt, this, false);
            return root_buf[3];
        }
        root_buf[3] = .undefined;
    }
    return .undefined;
}

fn isAsciiKey(key: heap_mod.PropKey, comptime ascii: []const u8) bool {
    if (key.isSymbol()) return false;
    const units = key.asAtom().units;
    if (units.len != ascii.len) return false;
    inline for (ascii, 0..) |c, i| {
        if (units[i] != c) return false;
    }
    return true;
}

/// Returns true iff `Array.prototype[Symbol.iterator]` is the unmodified built-in
/// `&array.array_values` and `ArrayIterator.prototype.next` is the unmodified built-in
/// `&iterator_next` with `ArrayIterator.prototype.__proto__ === Iterator.prototype`.
/// Performs zero allocations and zero atom interning.
fn hasUnmodifiedArrayIterator(r: *const builtins.Realm) bool {
    const sym_iter = r.array_prototype.props.get(heap_mod.PropKey.fromSymbol(r.sym_iterator)) orelse return false;
    if (sym_iter.is_accessor or !sym_iter.value.isNative() or sym_iter.value.asNative() != &array.array_values) {
        return false;
    }
    const aip = r.array_iterator_prototype;
    if (aip.proto != r.iterator_prototype) return false;
    switch (aip.props) {
        .shaped => |sh| {
            var cur: ?*const heap_mod.Shape = sh.shape;
            while (cur) |s| : (cur = s.parent) {
                if (s.count == 0) return false;
                if (isAsciiKey(s.key, "next")) {
                    const val = aip.props.getShapedSlot(s.slot);
                    return val.isNative() and val.asNative() == &iterator_next;
                }
            }
            return false;
        },
        .dict => return false,
    }
}

pub fn getIterator(rt: *Runtime, iterable: Value) Error!*Object {
    if (iterable.isUndefined() or iterable.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "value is not iterable" }});
    }
    const r = try builtins.realm(rt);

    // Dense-array fast path: skip ValueRoots, property lookups, Symbol.iterator callCallable,
    // and "next" interning when Array.prototype[Symbol.iterator] and ArrayIterator.prototype.next
    // are unmodified built-ins.
    if (iterable.isObject()) {
        const arr = iterable.asObject();
        if (arr.kind == .array and
            arr.proto == r.array_prototype and
            !arr.has_index_overrides and
            arr.props.get(heap_mod.PropKey.fromSymbol(r.sym_iterator)) == null and
            hasUnmodifiedArrayIterator(r))
        {
            return rt.heap.newIterator(r.array_iterator_prototype, iterable, .array_values);
        }
    }

    var root_buf = [_]Value{ iterable, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const method_fn = try object.get(rt, iterable, .{ .symbol = r.sym_iterator });
    root_buf[1] = method_fn;
    if (method_fn.isUndefined() or method_fn.isNull() or !method_fn.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "value is not iterable" }});
    }
    return getIteratorWithMethod(rt, iterable, method_fn);
}

pub fn getIteratorWithMethod(rt: *Runtime, iterable: Value, method_fn: Value) Error!*Object {
    const r = try builtins.realm(rt);
    var root_buf = [_]Value{ iterable, method_fn, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const iter_val = try rt.callCallable(method_fn, iterable, &.{});
    root_buf[2] = iter_val;
    if (!iter_val.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Result of the Symbol.iterator method is not an object" }});
    }
    const next_fn = try object.get(rt, iter_val, try object.named(rt, "next"));
    root_buf[3] = next_fn;
    if (iter_val.isObject() and iter_val.asObject().kind == .iterator and
        next_fn.isNative() and next_fn.asNative() == &iterator_next)
    {
        return iter_val.asObject();
    }
    return rt.heap.newCustomIterator(r.iterator_prototype, iter_val, next_fn);
}

pub fn makePairArray(rt: *Runtime, a: Value, b: Value) Error!Value {
    const r = try builtins.realm(rt);
    const pair = try rt.heap.newArray(r.array_prototype);
    try rt.heap.appendElements(pair, &.{ a, b });
    return Value.fromObject(pair);
}

pub fn iteratorNextVal(rt: *Runtime, iter: *Object) Error!?Value {
    const it = &iter.kind.iterator;
    if (it.done) return null;
    switch (it.kind) {
        .for_in => unreachable,
        .map_entries, .map_keys, .map_values => {
            if (it.target.asObject().kind.map.nextLive(&it.cursor, &it.epoch)) |e| {
                return switch (it.kind) {
                    .map_entries => try makePairArray(rt, e.key, e.value),
                    .map_keys => e.key,
                    .map_values => e.value,
                    else => unreachable,
                };
            }
        },
        .set_values, .set_entries => {
            if (it.target.asObject().kind.set.nextLive(&it.cursor, &it.epoch)) |e| {
                return switch (it.kind) {
                    .set_values => e.key,
                    .set_entries => try makePairArray(rt, e.key, e.key),
                    else => unreachable,
                };
            }
        },
        .array_values, .array_keys, .array_entries => {
            if (it.target.asObject().kind == .typed_array) {
                const ta = it.target.asObject().kind.typed_array;
                if (ta.buffer.kind.array_buffer.detached) {
                    return rt.throw(.TypeError, &.{.{ .ascii = "Cannot perform ArrayIterator.prototype.next on a detached ArrayBuffer" }});
                }
                if (it.cursor < ta.length) {
                    const i = it.cursor;
                    it.cursor += 1;
                    const idx_val: Value = Value.fromNumber(@floatFromInt(i));
                    return switch (it.kind) {
                        .array_values => try object.readTypedArrayElement(rt, ta, i),
                        .array_keys => idx_val,
                        .array_entries => try makePairArray(rt, idx_val, try object.readTypedArrayElement(rt, ta, i)),
                        else => unreachable,
                    };
                }
            } else if (it.target.isObject() and it.target.asObject().kind == .array) {
                const arr = it.target.asObject();
                const items = arr.kind.array.items;
                if (it.cursor < items.len) {
                    const i = it.cursor;
                    it.cursor += 1;
                    if (it.kind == .array_values) {
                        if (!arr.has_index_overrides and !items[i].isHole()) {
                            return items[i];
                        }
                        return try object.get(rt, it.target, .{ .index = @intCast(i) });
                    }
                    const idx_val: Value = Value.fromNumber(@floatFromInt(i));
                    if (it.kind == .array_keys) return idx_val;
                    const elem = if (arr.has_index_overrides or items[i].isHole())
                        try object.get(rt, it.target, .{ .index = @intCast(i) })
                    else
                        items[i];
                    return try makePairArray(rt, idx_val, elem);
                }
            } else {
                // Generic array-like iteration (e.g. `arguments` or `Array.prototype.values.call(obj)`).
                var root_buf = [_]Value{ Value.fromObject(iter), it.target };
                var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
                try roots.register(rt);
                defer roots.unregister(rt);
                const len_val = try object.get(rt, it.target, .{ .atom = try rt.heap.internUtf8("length") });
                const len = try common.toLength(rt, len_val);
                if (@as(f64, @floatFromInt(it.cursor)) < len) {
                    const i = it.cursor;
                    it.cursor += 1;
                    const idx_val: Value = Value.fromNumber(@floatFromInt(i));
                    if (it.kind == .array_keys) return idx_val;
                    const elem = try object.get(rt, it.target, try object.key(rt, idx_val));
                    return switch (it.kind) {
                        .array_values => elem,
                        .array_entries => try makePairArray(rt, idx_val, elem),
                        else => unreachable,
                    };
                }
            }
        },
        .string_chars => {
            const units = it.target.asString().units;
            if (it.cursor < units.len) {
                const start = it.cursor;
                const first = units[start];
                const step: usize = if (first >= 0xD800 and first <= 0xDBFF and
                    start + 1 < units.len and
                    units[start + 1] >= 0xDC00 and units[start + 1] <= 0xDFFF) 2 else 1;
                it.cursor += step;
                return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = units[start .. start + step] }}));
            }
        },
        .async_from_sync => return rt.bug("a sync step on an async-from-sync iterator"),
        .helper => return iteratorHelperNextVal(rt, iter),
        .wrap => return iteratorWrapNextVal(rt, iter),
        .regexp_match_all => {
            const matcher = it.target;
            const s = it.next_method.asString();
            const is_global = (it.cursor & 1) != 0;
            const is_unicode = (it.cursor & 2) != 0;
            var root_buf = [_]Value{ Value.fromObject(iter), matcher, Value.fromString(s), .undefined };
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);

            const match_val = try regexp.regExpExecGeneric(rt, matcher, Value.fromString(s));
            if (match_val.isNull()) {
                it.done = true;
                it.target = .undefined;
                it.next_method = .undefined;
                return null;
            }
            root_buf[3] = match_val;
            if (!is_global) {
                it.done = true;
                it.target = .undefined;
                it.next_method = .undefined;
                return match_val;
            }
            const m0 = try object.get(rt, match_val, .{ .index = 0 });
            const match_str = try common.toStringObj(rt, m0);
            if (match_str.units.len == 0) {
                const li_key = try object.named(rt, "lastIndex");
                const this_idx = try common.toLength(rt, try object.get(rt, matcher, li_key));
                const next_idx = regexp.advanceStringIndex(s.units, @intFromFloat(this_idx), is_unicode);
                try object.setStrict(rt, matcher, li_key, Value.fromNumber(@floatFromInt(next_idx)));
            }
            return match_val;
        },
        .custom => {
            var root_buf = [_]Value{ Value.fromObject(iter), .undefined };
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);

            // Per ES IteratorStep: if next() throws, IteratorClose is not called.
            errdefer {
                it.done = true;
                it.target = .undefined;
                it.next_method = .undefined;
            }
            if (!it.next_method.isFunction()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "iterator.next is not a function" }});
            }
            const res = try rt.callCallable(it.next_method, it.target, &.{});
            root_buf[1] = res;
            if (!res.isObjectLike()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
            }
            const done_val = try object.get(rt, res, try object.named(rt, "done"));
            if (!ops.toBoolean(done_val)) {
                return try object.get(rt, res, try object.named(rt, "value"));
            }
            it.next_method = .undefined;
        },
    }
    it.done = true;
    it.target = .undefined; // permanently exhausted; allow target collection
    return null;
}

pub fn iteratorClose(rt: *Runtime, iter: *Object, is_throw: bool) Error!void {
    const it = &iter.kind.iterator;
    if (it.done) return;
    const is_custom = it.kind == .custom;
    const target: Value = if (is_custom) it.target else Value.fromObject(iter);
    if (is_custom) {
        it.done = true;
        it.target = .undefined;
        it.next_method = .undefined;
    }

    const saved_ex = if (is_throw) rt.exception else null;
    const saved_tv = if (is_throw) rt.thrown_value else null;
    if (is_throw) {
        rt.exception = null;
        rt.thrown_value = null;
    }
    defer if (is_throw) {
        rt.exception = saved_ex;
        rt.thrown_value = saved_tv;
    };

    var root_buf = [_]Value{
        target,
        .undefined,
        .undefined,
        if (saved_ex) |ex| Value.fromString(ex.message) else .undefined,
        saved_tv orelse .undefined,
        if (saved_ex) |ex| (if (ex.stack) |st| Value.fromString(st) else .undefined) else .undefined,
    };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const ret = object.get(rt, target, try object.named(rt, "return")) catch |e| {
        if (e == error.Thrown and is_throw) {
            rt.clearThrown();
            return;
        }
        return e;
    };
    if (ret.isUndefined() or ret.isNull()) return;
    if (!ret.isFunction()) {
        if (is_throw) return;
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator return method is not a function" }});
    }
    root_buf[1] = ret;
    const res = rt.callCallable(ret, target, &.{}) catch |e| {
        if (e == error.Thrown and is_throw) {
            rt.clearThrown();
            return;
        }
        return e;
    };
    root_buf[2] = res;
    if (!is_throw and !res.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
    }
}

/// `{ value, done }`.
pub fn iterResult(rt: *Runtime, value: Value, done: bool) Error!Value {
    const r = try builtins.realm(rt);
    const out = try rt.heap.newObject(r.object_prototype);
    try object.define(rt, out, try object.named(rt, "value"), value);
    try object.define(rt, out, try object.named(rt, "done"), Value.fromBool(done));
    return Value.fromObject(out);
}

/// One round of `yield*` (D67, spec 14.4.14): forwards `received` to the inner iterator's
/// next/throw/return per `mode`. Shared by both engines.
pub const YieldStarStep = struct {
    value: Value,
    kind: enum { yield, done, @"return" },
};

pub fn yieldStarStep(rt: *Runtime, iter: *Object, received: Value, mode: coroutine.ResumeMode) Error!YieldStarStep {
    if (iter.kind != .iterator) return rt.bug("yield* on a non-iterator");
    const it = &iter.kind.iterator;
    const inner: Value = if (it.kind == .custom) it.target else Value.fromObject(iter);
    var root_buf = [_]Value{ Value.fromObject(iter), received, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const method_fn: Value = switch (mode) {
        .next => if (it.kind == .custom) it.next_method else Value.fromNative(&iterator_next),
        .throw, .@"return" => try object.get(rt, inner, try object.named(rt, if (mode == .throw) "throw" else "return")),
    };
    root_buf[2] = method_fn;
    if (method_fn.isUndefined() or method_fn.isNull()) switch (mode) {
        .next => {},
        .throw => {
            try iteratorClose(rt, iter, false);
            return rt.throw(.TypeError, &.{.{ .ascii = "The iterator does not provide a 'throw' method." }});
        },
        .@"return" => return .{ .value = received, .kind = .@"return" },
    };
    if (!method_fn.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "iterator method is not a function" }});
    const res = try rt.callCallable(method_fn, inner, &.{received});
    root_buf[3] = res;
    if (!res.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
    if (!ops.toBoolean(try object.get(rt, res, try object.named(rt, "done")))) return .{ .value = res, .kind = .yield };
    const v = try object.get(rt, res, try object.named(rt, "value"));
    return .{ .value = v, .kind = if (mode == .@"return") .@"return" else .done };
}

// ---------------------------------------------------------------- Generators (M37, D67)

const generator_next: Native = .{ .name = "next", .length = 1, .call = generatorNext };

const generator_return: Native = .{ .name = "return", .length = 1, .call = generatorReturn };

const generator_throw: Native = .{ .name = "throw", .length = 1, .call = generatorThrow };

fn generatorResume(rt: *Runtime, this: Value, args: []const Value, mode: coroutine.ResumeMode, name: []const u8) Error!Value {
    if (!this.isObject() or this.asObject().kind != .generator or this.asObject().kind.generator.is_async) {
        return rt.throw(.TypeError, &.{ .{ .ascii = name }, .{ .ascii = " method called on incompatible receiver" } });
    }
    return coroutine.resumeGenerator(rt, this.asObject(), mode, common.arg(args, 0));
}

// ---------------------------------------------------------------- Async generators & iteration (M38, D68)

const async_iterator_self: Native = .{ .name = "[Symbol.asyncIterator]", .call = iteratorSelf };

const async_generator_next: Native = .{ .name = "next", .length = 1, .call = asyncGeneratorNext };

const async_generator_return: Native = .{ .name = "return", .length = 1, .call = asyncGeneratorReturn };

const async_generator_throw: Native = .{ .name = "throw", .length = 1, .call = asyncGeneratorThrow };

const async_from_sync_next: Native = .{ .name = "next", .length = 1, .call = asyncFromSyncNext };

const async_from_sync_return: Native = .{ .name = "return", .length = 1, .call = asyncFromSyncReturn };

const async_from_sync_throw: Native = .{ .name = "throw", .length = 1, .call = asyncFromSyncThrow };

fn asyncGeneratorNext(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return coroutine.asyncGeneratorRequest(rt, this, .next, common.arg(args, 0));
}

fn asyncGeneratorReturn(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return coroutine.asyncGeneratorRequest(rt, this, .@"return", common.arg(args, 0));
}

fn asyncGeneratorThrow(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return coroutine.asyncGeneratorRequest(rt, this, .throw, common.arg(args, 0));
}

/// GetMethod: `undefined` for a missing (undefined/null) method, TypeError if not callable.
fn getMethod(rt: *Runtime, v: Value, name: []const u8) Error!Value {
    const m = try object.get(rt, v, try object.named(rt, name));
    if (m.isUndefined() or m.isNull()) return .undefined;
    if (!m.isFunction()) return rt.throw(.TypeError, &.{ .{ .ascii = "iterator." }, .{ .ascii = name }, .{ .ascii = " is not a function" } });
    return m;
}

/// GetIterator(e, async) (D68): an iterator record (a `.custom` iterator holding the
/// async iterator and its cached `next`); a sync iterable is wrapped in an
/// async-from-sync iterator.
pub fn getAsyncIterator(rt: *Runtime, iterable: Value) Error!*Object {
    if (iterable.isUndefined() or iterable.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "value is not async iterable" }});
    }
    const r = try builtins.realm(rt);
    var root_buf = [_]Value{ iterable, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const method_fn = try object.get(rt, iterable, .{ .symbol = r.sym_async_iterator });
    root_buf[1] = method_fn;
    if (method_fn.isUndefined() or method_fn.isNull()) {
        const sync = try getIterator(rt, iterable);
        root_buf[2] = Value.fromObject(sync);
        const afs = try rt.heap.newIterator(r.async_from_sync_iterator_prototype, root_buf[2], .async_from_sync);
        root_buf[3] = Value.fromObject(afs);
        return rt.heap.newCustomIterator(r.iterator_prototype, root_buf[3], Value.fromNative(&async_from_sync_next));
    }
    if (!method_fn.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "value is not async iterable" }});
    const iter_val = try rt.callCallable(method_fn, iterable, &.{});
    root_buf[2] = iter_val;
    if (!iter_val.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Result of the Symbol.asyncIterator method is not an object" }});
    }
    const next_fn = try object.get(rt, iter_val, try object.named(rt, "next"));
    root_buf[3] = next_fn;
    return rt.heap.newCustomIterator(r.iterator_prototype, iter_val, next_fn);
}

/// `for await` step, before the await: `Call(next, iterator)`.
pub fn asyncIterNext(rt: *Runtime, rec: *Object) Error!Value {
    if (rec.kind != .iterator) return rt.bug("asyncIterNext on a non-iterator");
    const it = &rec.kind.iterator;
    if (!it.next_method.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "iterator.next is not a function" }});
    return rt.callCallable(it.next_method, it.target, &.{});
}

/// `for await` step, after the await: the value, or null when done.
pub fn asyncIterValue(rt: *Runtime, res: Value) Error!?Value {
    if (!res.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
    var root_buf = [_]Value{res};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    if (ops.toBoolean(try object.get(rt, res, try object.named(rt, "done")))) return null;
    return try object.get(rt, res, try object.named(rt, "value"));
}

/// AsyncIteratorClose, before the await: `return()`'s result to await, or null when there
/// is nothing to await. `is_throw`: the completion is a throw, so errors are swallowed
/// (the original exception wins). Closes `rec` at most once.
pub fn asyncIterCloseStart(rt: *Runtime, rec: *Object, is_throw: bool) Error!?Value {
    if (rec.kind != .iterator) return rt.bug("asyncIterClose on a non-iterator");
    const it = &rec.kind.iterator;
    if (it.done) return null;
    const target = it.target;
    it.done = true;
    it.target = .undefined;
    it.next_method = .undefined;
    var root_buf = [_]Value{ target, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const ret = getMethod(rt, target, "return") catch |e| {
        if (e != error.Thrown or !is_throw) return e;
        rt.clearThrown();
        return null;
    };
    if (ret.isUndefined()) return null;
    root_buf[1] = ret;
    return rt.callCallable(ret, target, &.{}) catch |e| {
        if (e != error.Thrown or !is_throw) return e;
        rt.clearThrown();
        return null;
    };
}

/// AsyncIteratorClose, after the await (normal completions only).
pub fn asyncIterCloseCheck(rt: *Runtime, v: Value) Error!void {
    if (!v.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
}

/// Async `yield*` round, before its await (D68): `value` is the inner call's result, or for
/// `missing_return` the received value (awaited, then returned), or for `missing_throw`
/// the inner `return()`'s result (awaited, checked, then a TypeError).
pub const AsyncYieldStar = struct {
    value: Value,
    kind: enum(u8) { call, call_return, missing_return, missing_throw },
};

pub fn asyncYieldStarCall(rt: *Runtime, rec: *Object, received: Value, mode: coroutine.ResumeMode) Error!AsyncYieldStar {
    if (rec.kind != .iterator) return rt.bug("async yield* on a non-iterator");
    const it = &rec.kind.iterator;
    const inner = it.target;
    var root_buf = [_]Value{ Value.fromObject(rec), received, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    switch (mode) {
        .next => {
            if (!it.next_method.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "iterator.next is not a function" }});
            return .{ .value = try rt.callCallable(it.next_method, inner, &.{received}), .kind = .call };
        },
        .throw => {
            const thr = try getMethod(rt, inner, "throw");
            if (thr.isUndefined()) {
                const ret = try getMethod(rt, inner, "return");
                if (ret.isUndefined()) return rt.throw(.TypeError, &.{.{ .ascii = "The iterator does not provide a 'throw' method" }});
                root_buf[2] = ret;
                return .{ .value = try rt.callCallable(ret, inner, &.{}), .kind = .missing_throw };
            }
            root_buf[2] = thr;
            return .{ .value = try rt.callCallable(thr, inner, &.{received}), .kind = .call };
        },
        .@"return" => {
            const ret = try getMethod(rt, inner, "return");
            if (ret.isUndefined()) return .{ .value = received, .kind = .missing_return };
            root_buf[2] = ret;
            return .{ .value = try rt.callCallable(ret, inner, &.{received}), .kind = .call_return };
        },
    }
}

/// Async `yield*` round, after its await: what the expression does next.
pub fn asyncYieldStarResult(rt: *Runtime, kind: @FieldType(AsyncYieldStar, "kind"), v: Value) Error!YieldStarStep {
    switch (kind) {
        .missing_return => return .{ .value = v, .kind = .@"return" },
        .missing_throw => {
            try asyncIterCloseCheck(rt, v);
            return rt.throw(.TypeError, &.{.{ .ascii = "The iterator does not provide a 'throw' method" }});
        },
        .call, .call_return => {
            if (!v.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
            var root_buf = [_]Value{v};
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);
            const done = ops.toBoolean(try object.get(rt, v, try object.named(rt, "done")));
            const value = try object.get(rt, v, try object.named(rt, "value"));
            if (!done) return .{ .value = value, .kind = .yield };
            return .{ .value = value, .kind = if (kind == .call_return) .@"return" else .done };
        },
    }
}

/// The sync iterator record inside an async-from-sync iterator (`this`).
fn asyncFromSyncRecord(this: Value) ?*Object {
    if (!this.isObject() or this.asObject().kind != .iterator) return null;
    const it = &this.asObject().kind.iterator;
    if (it.kind != .async_from_sync or !it.target.isObject()) return null;
    return it.target.asObject();
}

/// Runs `body` for an async-from-sync method: its abrupt completion rejects the promise
/// (IfAbruptRejectPromise).
fn asyncFromSync(rt: *Runtime, this: Value, args: []const Value, comptime mode: coroutine.ResumeMode) Error!Value {
    const r = try builtins.realm(rt);
    const p = try rt.heap.newPromise(r.promise_prototype);
    var root_buf = [_]Value{ Value.fromObject(p), this };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const rec = asyncFromSyncRecord(this) orelse return rt.bug("an async-from-sync method on a foreign receiver");
    asyncFromSyncStep(rt, p, rec, args, mode) catch |e| {
        if (e != error.Thrown) return e;
        try promise.settlePromiseFromJob(rt, p, true, try rt.catchValue());
    };
    return root_buf[0];
}

fn asyncFromSyncStep(rt: *Runtime, p: *Object, rec: *Object, args: []const Value, comptime mode: coroutine.ResumeMode) Error!void {
    const it = &rec.kind.iterator;
    const sync_iter: Value = if (it.kind == .custom) it.target else Value.fromObject(rec);
    var root_buf = [_]Value{ Value.fromObject(rec), sync_iter, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const res: Value = switch (mode) {
        .next => blk: {
            const next_fn: Value = if (it.kind == .custom) it.next_method else Value.fromNative(&iterator_next);
            if (!next_fn.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "iterator.next is not a function" }});
            break :blk try rt.callCallable(next_fn, sync_iter, args[0..@min(args.len, 1)]);
        },
        .@"return" => blk: {
            const ret = try getMethod(rt, sync_iter, "return");
            if (ret.isUndefined()) {
                root_buf[3] = try iterResult(rt, common.arg(args, 0), true);
                return promise.resolvePromiseValue(rt, p, root_buf[3]);
            }
            root_buf[2] = ret;
            break :blk try rt.callCallable(ret, sync_iter, args[0..@min(args.len, 1)]);
        },
        .throw => blk: {
            const thr = try getMethod(rt, sync_iter, "throw");
            if (thr.isUndefined()) {
                try iteratorClose(rt, rec, false);
                return rt.throw(.TypeError, &.{.{ .ascii = "The iterator does not provide a 'throw' method" }});
            }
            root_buf[2] = thr;
            break :blk try rt.callCallable(thr, sync_iter, args[0..@min(args.len, 1)]);
        },
    };
    root_buf[3] = res;
    if (!res.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
    // AsyncFromSyncIteratorContinuation; a rejected value closes the sync iterator, except
    // for `return` (closeOnRejection false) or a done result.
    const done = ops.toBoolean(try object.get(rt, res, try object.named(rt, "done")));
    const value = try object.get(rt, res, try object.named(rt, "value"));
    root_buf[2] = value;
    const wrapper = promise.resolveToPromise(rt, value) catch |e| {
        if (e != error.Thrown) return e;
        if (!done and mode != .@"return") {
            const err_val = try rt.catchValue();
            root_buf[2] = err_val;
            try iteratorClose(rt, rec, true);
            return rt.throwValue(root_buf[2]);
        }
        return e;
    };
    root_buf[2] = wrapper;
    const on_ful = try rt.heap.newNativeClosure(if (done) @ptrCast(&asyncFromSyncUnwrapDone) else @ptrCast(&asyncFromSyncUnwrap), rec);
    root_buf[3] = Value.fromClosure(on_ful);
    const on_rej: Value = if (done or mode == .@"return") .undefined else Value.fromClosure(try rt.heap.newNativeClosure(@ptrCast(&asyncFromSyncCloseOnReject), rec));
    try promise.performPromiseThenCap(rt, wrapper.asObject(), root_buf[3], on_rej, p);
}

fn asyncFromSyncUnwrap(rt: *Runtime, _: *Object, args: []const Value) Error!Value {
    return iterResult(rt, common.arg(args, 0), false);
}

fn asyncFromSyncUnwrapDone(rt: *Runtime, _: *Object, args: []const Value) Error!Value {
    return iterResult(rt, common.arg(args, 0), true);
}

fn asyncFromSyncCloseOnReject(rt: *Runtime, rec: *Object, args: []const Value) Error!Value {
    var root_buf = [_]Value{common.arg(args, 0)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    try iteratorClose(rt, rec, true);
    return rt.throwValue(root_buf[0]);
}

fn asyncFromSyncNext(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return asyncFromSync(rt, this, args, .next);
}

fn asyncFromSyncReturn(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return asyncFromSync(rt, this, args, .@"return");
}

fn asyncFromSyncThrow(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return asyncFromSync(rt, this, args, .throw);
}

fn generatorNext(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return generatorResume(rt, this, args, .next, "next");
}

fn generatorReturn(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return generatorResume(rt, this, args, .@"return", "return");
}

fn generatorThrow(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return generatorResume(rt, this, args, .throw, "throw");
}

fn iteratorNext(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().kind != .iterator) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.next called on incompatible receiver" }});
    }
    const r = try builtins.realm(rt);
    const next_v = try iteratorNextVal(rt, this.asObject());
    const out = try rt.heap.newObject(r.object_prototype);
    try object.define(rt, out, try object.named(rt, "value"), next_v orelse .undefined);
    try object.define(rt, out, try object.named(rt, "done"), Value.fromBool(next_v == null));
    return Value.fromObject(out);
}

// ---------------------------------------------------------------- Unit Tests

fn runIterTestSource(source: []const u8, expected_out: []const u8) !void {
    const run = @import("../../run.zig");
    const gpa = std.testing.allocator;
    for ([_]run.Engine{ .treewalk, .vm }) |engine| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var err: std.Io.Writer.Allocating = .init(gpa);
        defer err.deinit();
        const code = try run.runSource(gpa, "iter_test.js", source, .{}, .{ .mode = .normal, .engine = engine }, &out.writer, &err.writer);
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings(expected_out, out.written());
    }
}

test "dense-array for..of fast path: basic, shrinking, growing, holes, and index overrides" {
    try runIterTestSource(
        \\// Basic dense array + empty array
        \\let sum = 0;
        \\for (const x of [10, 20, 30]) sum += x;
        \\for (const x of []) sum += 1000;
        \\print("sum:" + sum);
        \\
        \\// Shrinking during iteration
        \\const shrink = [1, 2, 3, 4];
        \\const seenShrink = [];
        \\for (const x of shrink) {
        \\  seenShrink.push(x);
        \\  if (x === 2) shrink.length = 2;
        \\}
        \\print("shrink:" + seenShrink.join(","));
        \\
        \\// Growing during iteration
        \\const grow = [1, 2];
        \\const seenGrow = [];
        \\for (const x of grow) {
        \\  seenGrow.push(x);
        \\  if (x === 2) grow.push(3, 4);
        \\}
        \\print("grow:" + seenGrow.join(","));
        \\
        \\// Holes created during iteration fall back to prototype lookup
        \\const holed = [1, 2, 3];
        \\Array.prototype[1] = 99;
        \\const seenHole = [];
        \\try {
        \\  for (const x of holed) {
        \\    seenHole.push(x);
        \\    if (x === 1) delete holed[1];
        \\  }
        \\} finally {
        \\  delete Array.prototype[1];
        \\}
        \\print("hole:" + seenHole.join(","));
        \\
        \\// Index override (getter) defined during iteration
        \\const ov = [10, 20, 30];
        \\let getterCalls = 0;
        \\const seenOv = [];
        \\for (const x of ov) {
        \\  seenOv.push(x);
        \\  if (x === 10) {
        \\    Object.defineProperty(ov, 1, { get() { getterCalls++; return 200; }, configurable: true });
        \\  }
        \\}
        \\print("ov:" + seenOv.join(",") + ":" + getterCalls);
    ,
        \\sum:60
        \\shrink:1,2
        \\grow:1,2,3,4
        \\hole:1,99,3
        \\ov:10,200,30:1
        \\
    );
}

test "dense-array for..of slow path: mutated Symbol.iterator, ArrayIterator.prototype.next, and Iterator.prototype.return" {
    try runIterTestSource(
        \\// 1. Own [Symbol.iterator] on array instance
        \\const own = [1, 2];
        \\own[Symbol.iterator] = function() {
        \\  let i = 0;
        \\  return { next() { return i < 2 ? { value: 100 + i++, done: false } : { value: undefined, done: true }; } };
        \\};
        \\const ownOut = [];
        \\for (const x of own) ownOut.push(x);
        \\print("own:" + ownOut.join(","));
        \\
        \\// 2. Mutated Array.prototype[Symbol.iterator]
        \\const origSymIter = Array.prototype[Symbol.iterator];
        \\Array.prototype[Symbol.iterator] = function() {
        \\  let i = this.length;
        \\  const self = this;
        \\  return { next() { return i > 0 ? { value: self[--i], done: false } : { value: undefined, done: true }; } };
        \\};
        \\const revOut = [];
        \\try {
        \\  for (const x of [1, 2, 3]) revOut.push(x);
        \\} finally {
        \\  Array.prototype[Symbol.iterator] = origSymIter;
        \\}
        \\print("protoIter:" + revOut.join(","));
        \\
        \\// 3. Mutated ArrayIterator.prototype.next
        \\const arrayIterProto = Object.getPrototypeOf([][Symbol.iterator]());
        \\const origNext = arrayIterProto.next;
        \\let customNextCalls = 0;
        \\arrayIterProto.next = function() {
        \\  customNextCalls++;
        \\  const r = origNext.call(this);
        \\  return r.done ? r : { value: r.value * 10, done: false };
        \\};
        \\const nextOut = [];
        \\try {
        \\  for (const x of [1, 2, 3]) nextOut.push(x);
        \\} finally {
        \\  arrayIterProto.next = origNext;
        \\}
        \\print("protoNext:" + nextOut.join(",") + ":" + customNextCalls);
        \\
        \\// 4. Custom Iterator.prototype.return called on break
        \\const iterProto = Object.getPrototypeOf(arrayIterProto);
        \\let returnCalls = 0;
        \\iterProto.return = function() {
        \\  returnCalls++;
        \\  return { value: undefined, done: true };
        \\};
        \\const breakOut = [];
        \\try {
        \\  for (const x of [1, 2, 3, 4]) {
        \\    breakOut.push(x);
        \\    if (x === 2) break;
        \\  }
        \\} finally {
        \\  delete iterProto.return;
        \\}
        \\print("protoReturn:" + breakOut.join(",") + ":" + returnCalls);
    ,
        \\own:100,101
        \\protoIter:3,2,1
        \\protoNext:10,20,30:4
        \\protoReturn:1,2:1
        \\
    );
}

// ---------------------------------------------------------------- Errors (M25)
