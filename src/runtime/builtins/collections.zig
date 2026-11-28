//! Map, Set, WeakMap, and WeakSet built-ins.

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
const iterator = @import("iterator.zig");

pub fn register(rt: *Runtime, r: *const builtins.Realm) Error!void {
    try common.method(rt, r.map_namespace, "groupBy", &map_group_by);
    try common.method(rt, r.map_prototype, "get", &map_get);
    try common.method(rt, r.map_prototype, "set", &map_set);
    try common.method(rt, r.map_prototype, "getOrInsert", &map_get_or_insert);
    try common.method(rt, r.map_prototype, "getOrInsertComputed", &map_get_or_insert_computed);
    try common.method(rt, r.map_prototype, "has", &map_has);
    try common.method(rt, r.map_prototype, "delete", &map_delete);
    try common.method(rt, r.map_prototype, "clear", &map_clear);
    try common.method(rt, r.map_prototype, "keys", &map_keys);
    try common.method(rt, r.map_prototype, "values", &map_values);
    try common.method(rt, r.map_prototype, "entries", &map_entries);
    try common.method(rt, r.map_prototype, "forEach", &map_for_each);
    try common.method(rt, r.set_prototype, "add", &set_add);
    try common.method(rt, r.set_prototype, "has", &set_has);
    try common.method(rt, r.set_prototype, "delete", &set_delete);
    try common.method(rt, r.set_prototype, "clear", &set_clear);
    try common.method(rt, r.set_prototype, "keys", &set_values);
    try common.method(rt, r.set_prototype, "values", &set_values);
    try common.method(rt, r.set_prototype, "entries", &set_entries);
    try common.method(rt, r.set_prototype, "forEach", &set_for_each);
    try common.method(rt, r.set_prototype, "union", &set_union);
    try common.method(rt, r.set_prototype, "intersection", &set_intersection);
    try common.method(rt, r.set_prototype, "difference", &set_difference);
    try common.method(rt, r.set_prototype, "symmetricDifference", &set_symmetric_difference);
    try common.method(rt, r.set_prototype, "isSubsetOf", &set_is_subset_of);
    try common.method(rt, r.set_prototype, "isSupersetOf", &set_is_superset_of);
    try common.method(rt, r.set_prototype, "isDisjointFrom", &set_is_disjoint_from);
    try common.constant(rt, r.weak_map_prototype, "constructor", Value.fromNative(&builtins.weak_map_global));
    try common.method(rt, r.weak_map_prototype, "get", &weak_map_get);
    try common.method(rt, r.weak_map_prototype, "set", &weak_map_set);
    try common.method(rt, r.weak_map_prototype, "getOrInsert", &weak_map_get_or_insert);
    try common.method(rt, r.weak_map_prototype, "getOrInsertComputed", &weak_map_get_or_insert_computed);
    try common.method(rt, r.weak_map_prototype, "has", &weak_map_has);
    try common.method(rt, r.weak_map_prototype, "delete", &weak_map_delete);
    try common.constant(rt, r.weak_set_prototype, "constructor", Value.fromNative(&builtins.weak_set_global));
    try common.method(rt, r.weak_set_prototype, "add", &weak_set_add);
    try common.method(rt, r.weak_set_prototype, "has", &weak_set_has);
    try common.method(rt, r.weak_set_prototype, "delete", &weak_set_delete);
    try common.symbolMethod(rt, r.map_prototype, r.sym_iterator, &map_entries);
    try common.symbolMethod(rt, r.set_prototype, r.sym_iterator, &set_values);
    try common.immutableConstant(rt, r.map_namespace, "prototype", Value.fromObject(r.map_prototype));
    try common.constant(rt, r.map_prototype, "constructor", Value.fromNative(&builtins.map_global));
    try object.defineAccessor(rt, Value.fromObject(r.map_prototype), try object.named(rt, "size"), Value.fromNative(&map_size_getter), false, false);
    try common.immutableConstant(rt, r.set_namespace, "prototype", Value.fromObject(r.set_prototype));
    try common.constant(rt, r.set_prototype, "constructor", Value.fromNative(&builtins.set_global));
    try object.defineAccessor(rt, Value.fromObject(r.set_prototype), try object.named(rt, "size"), Value.fromNative(&set_size_getter), false, false);
    try common.immutableConstant(rt, r.weak_map_namespace, "prototype", Value.fromObject(r.weak_map_prototype));
    try common.immutableConstant(rt, r.weak_set_namespace, "prototype", Value.fromObject(r.weak_set_prototype));
    try object.defineAccessor(rt, Value.fromObject(r.map_namespace), .{ .symbol = r.sym_species }, Value.fromNative(&common.species_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.set_namespace), .{ .symbol = r.sym_species }, Value.fromNative(&common.species_getter), false, false);
    try common.defineToStringTag(rt, r.map_prototype, r.sym_to_string_tag, "Map");
    try common.defineToStringTag(rt, r.set_prototype, r.sym_to_string_tag, "Set");
    try common.defineToStringTag(rt, r.weak_map_prototype, r.sym_to_string_tag, "WeakMap");
    try common.defineToStringTag(rt, r.weak_set_prototype, r.sym_to_string_tag, "WeakSet");
}

const map_size_getter: Native = .{ .name = "get size", .call = mapSizeGetter };

const map_get: Native = .{ .name = "get", .length = 1, .call = mapGet };

const map_set: Native = .{ .name = "set", .length = 2, .call = mapSet };

const map_get_or_insert: Native = .{ .name = "getOrInsert", .length = 2, .call = mapGetOrInsert };

const map_get_or_insert_computed: Native = .{ .name = "getOrInsertComputed", .length = 2, .call = mapGetOrInsertComputed };

const map_has: Native = .{ .name = "has", .length = 1, .call = mapHas };

const map_delete: Native = .{ .name = "delete", .length = 1, .call = mapDelete };

const map_clear: Native = .{ .name = "clear", .call = mapClear };

const map_keys: Native = .{ .name = "keys", .call = mapKeys };

const map_values: Native = .{ .name = "values", .call = mapValues };

const map_entries: Native = .{ .name = "entries", .call = mapEntries };

const map_for_each: Native = .{ .name = "forEach", .length = 1, .call = mapForEach };

fn mapSizeGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const m = try thisMap(rt, this, "get size");
    return Value.fromNumber(@floatFromInt(m.kind.map.live_count));
}

const map_group_by: Native = .{ .name = "groupBy", .length = 2, .call = mapGroupBy };

pub fn mapWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor Map requires 'new'" }});
}

pub fn mapConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const m = try rt.heap.newMap(r.map_prototype);
    const iterable = common.arg(args, 0);
    if (iterable.isUndefined() or iterable.isNull()) return Value.fromObject(m);

    var root_buf = [_]Value{ iterable, Value.fromObject(m), .undefined, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const adder = try object.get(rt, Value.fromObject(m), try object.named(rt, "set"));
    if (!adder.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "Map.prototype.set is not a function" }});
    root_buf[6] = adder;

    const iter = try iterator.getIterator(rt, iterable);
    root_buf[2] = Value.fromObject(iter);

    while (try iterator.iteratorNextVal(rt, iter)) |entry| {
        root_buf[3] = entry;
        if (!entry.isObjectLike()) {
            try iterator.iteratorClose(rt, iter, true);
            return rt.throw(.TypeError, &.{.{ .ascii = "Iterator value is not an entry object" }});
        }
        const k = object.get(rt, entry, .{ .index = 0 }) catch |e| {
            if (e == error.Thrown) try iterator.iteratorClose(rt, iter, true);
            return e;
        };
        root_buf[4] = k;
        const v = object.get(rt, entry, .{ .index = 1 }) catch |e| {
            if (e == error.Thrown) try iterator.iteratorClose(rt, iter, true);
            return e;
        };
        root_buf[5] = v;
        if (adder.isNative() and adder.asNative() == &map_set) {
            try rt.heap.mapSet(m, k, v);
        } else {
            _ = rt.callCallable(adder, Value.fromObject(m), &.{ k, v }) catch |e| {
                if (e == error.Thrown) try iterator.iteratorClose(rt, iter, true);
                return e;
            };
        }
        root_buf[3] = .undefined;
        root_buf[4] = .undefined;
        root_buf[5] = .undefined;
    }
    return Value.fromObject(m);
}

fn thisMap(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .map) return this.asObject();
    return common.unsupportedReceiver(rt, name);
}

fn mapGet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "get");
    return heap_mod.Heap.mapGet(m, common.arg(args, 0)) orelse .undefined;
}

fn mapSet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "set");
    try rt.heap.mapSet(m, common.arg(args, 0), common.arg(args, 1));
    return this;
}

fn requireMap(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .map) return this.asObject();
    return rt.throw(.TypeError, &.{ .{ .ascii = "Method Map.prototype." }, .{ .ascii = name }, .{ .ascii = " called on incompatible receiver" } });
}

fn mapGetOrInsert(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try requireMap(rt, this, "getOrInsert");
    const raw_key = common.arg(args, 0);
    const key = if (raw_key.isNumber() and raw_key.asNumber() == 0.0) Value.fromNumber(0.0) else raw_key;
    if (heap_mod.Heap.mapGet(m, key)) |existing| return existing;
    const val = common.arg(args, 1);
    try rt.heap.mapSet(m, key, val);
    return val;
}

fn mapGetOrInsertComputed(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try requireMap(rt, this, "getOrInsertComputed");
    const cb = try common.requireCallable(rt, common.arg(args, 1));
    const raw_key = common.arg(args, 0);
    const key = if (raw_key.isNumber() and raw_key.asNumber() == 0.0) Value.fromNumber(0.0) else raw_key;
    if (heap_mod.Heap.mapGet(m, key)) |existing| return existing;

    var root_buf = [_]Value{ this, key, cb, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const val = try rt.callCallable(cb, .undefined, &.{key});
    root_buf[3] = val;
    try rt.heap.mapSet(m, key, val);
    return val;
}

fn mapHas(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "has");
    return Value.fromBool(heap_mod.Heap.mapHas(m, common.arg(args, 0)));
}

fn mapDelete(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "delete");
    return Value.fromBool(heap_mod.Heap.mapDelete(m, common.arg(args, 0)));
}

fn mapClear(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const m = try thisMap(rt, this, "clear");
    heap_mod.Heap.mapClear(m);
    return .undefined;
}

fn mapKeys(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisMap(rt, this, "keys");
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).map_iterator_prototype, this, .map_keys));
}

fn mapValues(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisMap(rt, this, "values");
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).map_iterator_prototype, this, .map_values));
}

fn mapEntries(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisMap(rt, this, "entries");
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).map_iterator_prototype, this, .map_entries));
}

fn mapForEach(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "forEach");
    const cb = try common.requireCallable(rt, common.arg(args, 0));
    const this_arg = common.arg(args, 1);
    var root_buf = [_]Value{ this, cb, this_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var i: usize = 0;
    var epoch = m.kind.map.epoch;
    while (m.kind.map.nextLive(&i, &epoch)) |e| {
        root_buf[3] = e.key;
        root_buf[4] = e.value;
        _ = try rt.callCallable(cb, this_arg, &.{ e.value, e.key, this });
        root_buf[3] = .undefined;
        root_buf[4] = .undefined;
    }
    return .undefined;
}

fn mapGroupBy(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const iterable = common.arg(args, 0);
    const cb = try common.requireCallable(rt, common.arg(args, 1));
    var root_buf = [_]Value{ iterable, cb, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const iter = try iterator.getIterator(rt, iterable);
    root_buf[2] = Value.fromObject(iter);
    const r = try builtins.realm(rt);
    const out = try rt.heap.newMap(r.map_prototype);
    root_buf[0] = Value.fromObject(out);

    var idx: usize = 0;
    while (try iterator.iteratorNextVal(rt, iter)) |item| : (idx += 1) {
        root_buf[3] = item;
        const raw_key = rt.callCallable(cb, .undefined, &.{ item, Value.fromNumber(@floatFromInt(idx)) }) catch |e| {
            if (e == error.Thrown) try iterator.iteratorClose(rt, iter, true);
            return e;
        };
        const key = if (raw_key.isNumber() and raw_key.asNumber() == 0.0) Value.fromNumber(0.0) else raw_key;
        root_buf[4] = key;
        const group_arr: *Object = blk: {
            if (heap_mod.Heap.mapGet(out, key)) |existing| {
                break :blk existing.asObject();
            }
            const arr = try rt.heap.newArray(r.array_prototype);
            root_buf[5] = Value.fromObject(arr);
            try rt.heap.mapSet(out, key, Value.fromObject(arr));
            break :blk arr;
        };
        try rt.heap.appendElement(group_arr, item);
        root_buf[3] = .undefined;
        root_buf[4] = .undefined;
        root_buf[5] = .undefined;
    }
    return Value.fromObject(out);
}

// ---------------------------------------------------------------- Set

const set_size_getter: Native = .{ .name = "get size", .call = setSizeGetter };

const set_add: Native = .{ .name = "add", .length = 1, .call = setAdd };

const set_has: Native = .{ .name = "has", .length = 1, .call = setHas };

const set_delete: Native = .{ .name = "delete", .length = 1, .call = setDelete };

const set_clear: Native = .{ .name = "clear", .call = setClear };

const set_values: Native = .{ .name = "values", .call = setValues };

const set_entries: Native = .{ .name = "entries", .call = setEntries };

const set_for_each: Native = .{ .name = "forEach", .length = 1, .call = setForEach };

fn setSizeGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try thisSet(rt, this, "get size");
    return Value.fromNumber(@floatFromInt(s.kind.set.live_count));
}

const set_union: Native = .{ .name = "union", .length = 1, .call = setUnion };

const set_intersection: Native = .{ .name = "intersection", .length = 1, .call = setIntersection };

const set_difference: Native = .{ .name = "difference", .length = 1, .call = setDifference };

const set_symmetric_difference: Native = .{ .name = "symmetricDifference", .length = 1, .call = setSymmetricDifference };

const set_is_subset_of: Native = .{ .name = "isSubsetOf", .length = 1, .call = setIsSubsetOf };

const set_is_superset_of: Native = .{ .name = "isSupersetOf", .length = 1, .call = setIsSupersetOf };

const set_is_disjoint_from: Native = .{ .name = "isDisjointFrom", .length = 1, .call = setIsDisjointFrom };

pub fn setWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor Set requires 'new'" }});
}

pub fn setConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const s = try rt.heap.newSet(r.set_prototype);
    const iterable = common.arg(args, 0);
    if (iterable.isUndefined() or iterable.isNull()) return Value.fromObject(s);

    var root_buf = [_]Value{ iterable, Value.fromObject(s), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const adder = try object.get(rt, Value.fromObject(s), try object.named(rt, "add"));
    if (!adder.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "Set.prototype.add is not a function" }});
    root_buf[4] = adder;

    const iter = try iterator.getIterator(rt, iterable);
    root_buf[2] = Value.fromObject(iter);
    while (try iterator.iteratorNextVal(rt, iter)) |v| {
        root_buf[3] = v;
        if (adder.isNative() and adder.asNative() == &set_add) {
            try rt.heap.setAdd(s, v);
        } else {
            _ = rt.callCallable(adder, Value.fromObject(s), &.{v}) catch |e| {
                if (e == error.Thrown) try iterator.iteratorClose(rt, iter, true);
                return e;
            };
        }
        root_buf[3] = .undefined;
    }
    return Value.fromObject(s);
}

fn thisSet(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .set) return this.asObject();
    return common.unsupportedReceiver(rt, name);
}

fn setAdd(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "add");
    try rt.heap.setAdd(s, common.arg(args, 0));
    return this;
}

fn setHas(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "has");
    return Value.fromBool(heap_mod.Heap.setHas(s, common.arg(args, 0)));
}

fn setDelete(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "delete");
    return Value.fromBool(heap_mod.Heap.setDelete(s, common.arg(args, 0)));
}

fn setClear(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try thisSet(rt, this, "clear");
    heap_mod.Heap.setClear(s);
    return .undefined;
}

fn setValues(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisSet(rt, this, "values");
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).set_iterator_prototype, this, .set_values));
}

fn setEntries(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisSet(rt, this, "entries");
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).set_iterator_prototype, this, .set_entries));
}

fn setForEach(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "forEach");
    const cb = try common.requireCallable(rt, common.arg(args, 0));
    const this_arg = common.arg(args, 1);
    var root_buf = [_]Value{ this, cb, this_arg, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var i: usize = 0;
    var epoch = s.kind.set.epoch;
    while (s.kind.set.nextLive(&i, &epoch)) |e| {
        root_buf[3] = e.key;
        _ = try rt.callCallable(cb, this_arg, &.{ e.key, e.key, this });
        root_buf[3] = .undefined;
    }
    return .undefined;
}

const SetRecord = struct {
    obj: Value,
    size: f64,
    has: Value,
    keys: Value,
};

fn getSetRecord(rt: *Runtime, obj: Value) Error!SetRecord {
    if (!obj.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Argument must be an object" }});
    }
    var root_buf = [_]Value{ obj, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const raw_size = try object.get(rt, obj, try object.named(rt, "size"));
    const num_size = try ops.toNumber(rt, raw_size);
    if (std.math.isNan(num_size)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Set-like size must not be NaN" }});
    }
    const int_size = if (num_size == 0) 0 else @trunc(num_size);
    if (int_size < 0) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Set-like size must not be negative" }});
    }
    const has = try object.get(rt, obj, try object.named(rt, "has"));
    if (!has.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Set-like object must have a callable 'has' method" }});
    }
    root_buf[1] = has;
    const keys = try object.get(rt, obj, try object.named(rt, "keys"));
    if (!keys.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Set-like object must have a callable 'keys' method" }});
    }
    return .{ .obj = obj, .size = int_size, .has = has, .keys = keys };
}

fn getSetKeysIterator(rt: *Runtime, rec: SetRecord) Error!*Object {
    const r = try builtins.realm(rt);
    const iter_val = try rt.callCallable(rec.keys, rec.obj, &.{});
    if (!iter_val.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Set-like keys() must return an object" }});
    }
    var root_buf = [_]Value{iter_val};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next_fn = try object.get(rt, iter_val, try object.named(rt, "next"));
    if (!next_fn.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Set-like keys iterator must have a callable 'next' method" }});
    }
    return rt.heap.newCustomIterator(r.iterator_prototype, iter_val, next_fn);
}

fn cloneSet(rt: *Runtime, s: *Object) Error!*Object {
    const r = try builtins.realm(rt);
    const out = try rt.heap.newSet(r.set_prototype);
    var root_buf = [_]Value{ Value.fromObject(s), Value.fromObject(out) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (s.kind.set.entries.items) |e| {
        if (!e.alive) continue;
        try rt.heap.setAdd(out, e.key);
    }
    return out;
}

fn setUnion(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "union");
    const rec = try getSetRecord(rt, common.arg(args, 0));
    var root_buf = [_]Value{ this, rec.obj, rec.has, rec.keys, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const out = try cloneSet(rt, s);
    root_buf[4] = Value.fromObject(out);
    const iter = try getSetKeysIterator(rt, rec);
    root_buf[5] = Value.fromObject(iter);
    while (try iterator.iteratorNextVal(rt, iter)) |v| {
        root_buf[6] = v;
        try rt.heap.setAdd(out, v);
        root_buf[6] = .undefined;
    }
    return Value.fromObject(out);
}

fn setIntersection(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "intersection");
    const rec = try getSetRecord(rt, common.arg(args, 0));
    const r = try builtins.realm(rt);
    const out = try rt.heap.newSet(r.set_prototype);
    var root_buf = [_]Value{ this, rec.obj, rec.has, rec.keys, Value.fromObject(out), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (@as(f64, @floatFromInt(s.kind.set.live_count)) <= rec.size) {
        var i: usize = 0;
        var epoch = s.kind.set.epoch;
        while (s.kind.set.nextLive(&i, &epoch)) |e| {
            root_buf[6] = e.key;
            const res = try rt.callCallable(rec.has, rec.obj, &.{e.key});
            if (ops.toBoolean(res)) {
                try rt.heap.setAdd(out, root_buf[6]);
            }
            root_buf[6] = .undefined;
        }
    } else {
        const iter = try getSetKeysIterator(rt, rec);
        root_buf[5] = Value.fromObject(iter);
        while (try iterator.iteratorNextVal(rt, iter)) |v| {
            root_buf[6] = v;
            if (heap_mod.Heap.setHas(s, v)) {
                try rt.heap.setAdd(out, v);
            }
            root_buf[6] = .undefined;
        }
    }
    return Value.fromObject(out);
}

fn setDifference(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "difference");
    const rec = try getSetRecord(rt, common.arg(args, 0));
    var root_buf = [_]Value{ this, rec.obj, rec.has, rec.keys, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const out = try cloneSet(rt, s);
    root_buf[4] = Value.fromObject(out);
    if (@as(f64, @floatFromInt(s.kind.set.live_count)) <= rec.size) {
        var i: usize = 0;
        var epoch = s.kind.set.epoch;
        while (s.kind.set.nextLive(&i, &epoch)) |e| {
            root_buf[6] = e.key;
            const res = try rt.callCallable(rec.has, rec.obj, &.{e.key});
            if (ops.toBoolean(res)) {
                _ = heap_mod.Heap.setDelete(out, root_buf[6]);
            }
            root_buf[6] = .undefined;
        }
    } else {
        const iter = try getSetKeysIterator(rt, rec);
        root_buf[5] = Value.fromObject(iter);
        while (try iterator.iteratorNextVal(rt, iter)) |v| {
            root_buf[6] = v;
            _ = heap_mod.Heap.setDelete(out, v);
            root_buf[6] = .undefined;
        }
    }
    return Value.fromObject(out);
}

fn setSymmetricDifference(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "symmetricDifference");
    const rec = try getSetRecord(rt, common.arg(args, 0));
    var root_buf = [_]Value{ this, rec.obj, rec.has, rec.keys, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const iter = try getSetKeysIterator(rt, rec);
    root_buf[5] = Value.fromObject(iter);
    const out = try cloneSet(rt, s);
    root_buf[4] = Value.fromObject(out);
    while (try iterator.iteratorNextVal(rt, iter)) |v| {
        root_buf[6] = v;
        const in_result = heap_mod.Heap.setHas(out, v);
        if (heap_mod.Heap.setHas(s, v)) {
            if (in_result) _ = heap_mod.Heap.setDelete(out, v);
        } else {
            if (!in_result) try rt.heap.setAdd(out, v);
        }
        root_buf[6] = .undefined;
    }
    return Value.fromObject(out);
}

fn setIsSubsetOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "isSubsetOf");
    const rec = try getSetRecord(rt, common.arg(args, 0));
    if (@as(f64, @floatFromInt(s.kind.set.live_count)) > rec.size) return Value.fromBool(false);

    var root_buf = [_]Value{ this, rec.obj, rec.has, rec.keys, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var i: usize = 0;
    var epoch = s.kind.set.epoch;
    while (s.kind.set.nextLive(&i, &epoch)) |e| {
        root_buf[4] = e.key;
        const res = try rt.callCallable(rec.has, rec.obj, &.{e.key});
        if (!ops.toBoolean(res)) return Value.fromBool(false);
        root_buf[4] = .undefined;
    }
    return Value.fromBool(true);
}

fn setIsSupersetOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "isSupersetOf");
    const rec = try getSetRecord(rt, common.arg(args, 0));
    if (@as(f64, @floatFromInt(s.kind.set.live_count)) < rec.size) return Value.fromBool(false);

    var root_buf = [_]Value{ this, rec.obj, rec.has, rec.keys, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const iter = try getSetKeysIterator(rt, rec);
    root_buf[4] = Value.fromObject(iter);
    while (try iterator.iteratorNextVal(rt, iter)) |v| {
        root_buf[5] = v;
        if (!heap_mod.Heap.setHas(s, v)) {
            try iterator.iteratorClose(rt, iter, false);
            return Value.fromBool(false);
        }
        root_buf[5] = .undefined;
    }
    return Value.fromBool(true);
}

fn setIsDisjointFrom(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "isDisjointFrom");
    const rec = try getSetRecord(rt, common.arg(args, 0));
    var root_buf = [_]Value{ this, rec.obj, rec.has, rec.keys, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (@as(f64, @floatFromInt(s.kind.set.live_count)) <= rec.size) {
        var i: usize = 0;
        var epoch = s.kind.set.epoch;
        while (s.kind.set.nextLive(&i, &epoch)) |e| {
            root_buf[5] = e.key;
            const res = try rt.callCallable(rec.has, rec.obj, &.{e.key});
            if (ops.toBoolean(res)) return Value.fromBool(false);
            root_buf[5] = .undefined;
        }
    } else {
        const iter = try getSetKeysIterator(rt, rec);
        root_buf[4] = Value.fromObject(iter);
        while (try iterator.iteratorNextVal(rt, iter)) |v| {
            root_buf[5] = v;
            if (heap_mod.Heap.setHas(s, v)) {
                try iterator.iteratorClose(rt, iter, false);
                return Value.fromBool(false);
            }
            root_buf[5] = .undefined;
        }
    }
    return Value.fromBool(true);
}

// ---------------------------------------------------------------- WeakMap & WeakSet (M45, D75)

const weak_map_get: Native = .{ .name = "get", .length = 1, .call = weakMapGet };

const weak_map_set: Native = .{ .name = "set", .length = 2, .call = weakMapSet };

const weak_map_get_or_insert: Native = .{ .name = "getOrInsert", .length = 2, .call = weakMapGetOrInsert };

const weak_map_get_or_insert_computed: Native = .{ .name = "getOrInsertComputed", .length = 2, .call = weakMapGetOrInsertComputed };

const weak_map_has: Native = .{ .name = "has", .length = 1, .call = weakMapHas };

const weak_map_delete: Native = .{ .name = "delete", .length = 1, .call = weakMapDelete };

pub fn weakMapWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor WeakMap requires 'new'" }});
}

pub fn weakMapConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const wm = try rt.heap.newWeakMap(r.weak_map_prototype);
    const iterable = common.arg(args, 0);
    if (iterable.isUndefined() or iterable.isNull()) return Value.fromObject(wm);

    var root_buf = [_]Value{ iterable, Value.fromObject(wm), .undefined, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const adder = try common.requireCallable(rt, try object.get(rt, Value.fromObject(wm), try object.named(rt, "set")));
    root_buf[2] = adder;

    const iter = try iterator.getIterator(rt, iterable);
    root_buf[3] = Value.fromObject(iter);

    while (try iterator.iteratorNextVal(rt, iter)) |entry| {
        root_buf[4] = entry;
        if (!entry.isObjectLike()) {
            try iterator.iteratorClose(rt, iter, true);
            return rt.throw(.TypeError, &.{.{ .ascii = "Iterator value is not an entry object" }});
        }
        const k = object.get(rt, entry, .{ .index = 0 }) catch |e| {
            if (e == error.Thrown) try iterator.iteratorClose(rt, iter, true);
            return e;
        };
        root_buf[5] = k;
        const v = object.get(rt, entry, .{ .index = 1 }) catch |e| {
            if (e == error.Thrown) try iterator.iteratorClose(rt, iter, true);
            return e;
        };
        root_buf[6] = v;
        _ = rt.callCallable(adder, Value.fromObject(wm), &.{ k, v }) catch |e| {
            if (e == error.Thrown) try iterator.iteratorClose(rt, iter, true);
            return e;
        };
        root_buf[4] = .undefined;
        root_buf[5] = .undefined;
        root_buf[6] = .undefined;
    }
    return Value.fromObject(wm);
}

fn thisWeakMap(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .weak_map) return this.asObject();
    return rt.throw(.TypeError, &.{ .{ .ascii = "Method WeakMap.prototype." }, .{ .ascii = name }, .{ .ascii = " called on incompatible receiver" } });
}

fn weakMapGet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const wm = try thisWeakMap(rt, this, "get");
    const key = heap_mod.WeakKey.fromValue(common.arg(args, 0)) orelse return .undefined;
    return heap_mod.Heap.weakMapGet(wm, key) orelse .undefined;
}

fn weakMapSet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const wm = try thisWeakMap(rt, this, "set");
    const key = heap_mod.WeakKey.fromValue(common.arg(args, 0)) orelse return rt.throw(.TypeError, &.{.{ .ascii = "Invalid value used as weak map key" }});
    try rt.heap.weakMapSet(wm, key, common.arg(args, 1));
    return this;
}

fn weakMapGetOrInsert(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const wm = try thisWeakMap(rt, this, "getOrInsert");
    const key = heap_mod.WeakKey.fromValue(common.arg(args, 0)) orelse return rt.throw(.TypeError, &.{.{ .ascii = "Invalid value used as weak map key" }});
    if (heap_mod.Heap.weakMapGet(wm, key)) |existing| return existing;
    const val = common.arg(args, 1);
    try rt.heap.weakMapSet(wm, key, val);
    return val;
}

fn weakMapGetOrInsertComputed(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const wm = try thisWeakMap(rt, this, "getOrInsertComputed");
    const raw_key = common.arg(args, 0);
    // TC39 proposal-upsert validates CanBeHeldWeakly(key) before IsCallable(callbackfn).
    const key = heap_mod.WeakKey.fromValue(raw_key) orelse return rt.throw(.TypeError, &.{.{ .ascii = "Invalid value used as weak map key" }});
    const cb = try common.requireCallable(rt, common.arg(args, 1));
    if (heap_mod.Heap.weakMapGet(wm, key)) |existing| return existing;

    var root_buf = [_]Value{ this, raw_key, cb, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const val = try rt.callCallable(cb, .undefined, &.{raw_key});
    root_buf[3] = val;
    try rt.heap.weakMapSet(wm, key, val);
    return val;
}

fn weakMapHas(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const wm = try thisWeakMap(rt, this, "has");
    const key = heap_mod.WeakKey.fromValue(common.arg(args, 0)) orelse return Value.fromBool(false);
    return Value.fromBool(heap_mod.Heap.weakMapHas(wm, key));
}

fn weakMapDelete(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const wm = try thisWeakMap(rt, this, "delete");
    const key = heap_mod.WeakKey.fromValue(common.arg(args, 0)) orelse return Value.fromBool(false);
    return Value.fromBool(heap_mod.Heap.weakMapDelete(wm, key));
}

const weak_set_add: Native = .{ .name = "add", .length = 1, .call = weakSetAdd };

const weak_set_has: Native = .{ .name = "has", .length = 1, .call = weakSetHas };

const weak_set_delete: Native = .{ .name = "delete", .length = 1, .call = weakSetDelete };

pub fn weakSetWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor WeakSet requires 'new'" }});
}

pub fn weakSetConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const ws = try rt.heap.newWeakSet(r.weak_set_prototype);
    const iterable = common.arg(args, 0);
    if (iterable.isUndefined() or iterable.isNull()) return Value.fromObject(ws);

    var root_buf = [_]Value{ iterable, Value.fromObject(ws), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const adder = try common.requireCallable(rt, try object.get(rt, Value.fromObject(ws), try object.named(rt, "add")));
    root_buf[2] = adder;

    const iter = try iterator.getIterator(rt, iterable);
    root_buf[3] = Value.fromObject(iter);

    while (try iterator.iteratorNextVal(rt, iter)) |v| {
        root_buf[4] = v;
        _ = rt.callCallable(adder, Value.fromObject(ws), &.{v}) catch |e| {
            if (e == error.Thrown) try iterator.iteratorClose(rt, iter, true);
            return e;
        };
        root_buf[4] = .undefined;
    }
    return Value.fromObject(ws);
}

fn thisWeakSet(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .weak_set) return this.asObject();
    return rt.throw(.TypeError, &.{ .{ .ascii = "Method WeakSet.prototype." }, .{ .ascii = name }, .{ .ascii = " called on incompatible receiver" } });
}

fn weakSetAdd(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const ws = try thisWeakSet(rt, this, "add");
    const key = heap_mod.WeakKey.fromValue(common.arg(args, 0)) orelse return rt.throw(.TypeError, &.{.{ .ascii = "Invalid value used in weak set" }});
    try rt.heap.weakSetAdd(ws, key);
    return this;
}

fn weakSetHas(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const ws = try thisWeakSet(rt, this, "has");
    const key = heap_mod.WeakKey.fromValue(common.arg(args, 0)) orelse return Value.fromBool(false);
    return Value.fromBool(heap_mod.Heap.weakSetHas(ws, key));
}

fn weakSetDelete(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const ws = try thisWeakSet(rt, this, "delete");
    const key = heap_mod.WeakKey.fromValue(common.arg(args, 0)) orelse return Value.fromBool(false);
    return Value.fromBool(heap_mod.Heap.weakSetDelete(ws, key));
}

// ---------------------------------------------------------------- Promise (M18)
