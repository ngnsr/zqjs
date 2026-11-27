//! Array and Array.prototype built-ins.

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
const obj_builtins = @import("object.zig");
const function_error = @import("function_error.zig");
const iterator = @import("iterator.zig");
const promise = @import("promise.zig");
const proxy_reflect = @import("proxy_reflect.zig");

pub fn register(rt: *Runtime, r: *const builtins.Realm) Error!void {
    try common.method(rt, r.array_prototype, "push", &array_push);
    try common.method(rt, r.array_prototype, "pop", &array_pop);
    try common.method(rt, r.array_prototype, "slice", &array_slice);
    try common.method(rt, r.array_prototype, "indexOf", &array_index_of);
    try common.method(rt, r.array_prototype, "includes", &array_includes);
    try common.method(rt, r.array_prototype, "join", &array_join);
    try common.method(rt, r.array_prototype, "toString", &array_to_string);
    try common.method(rt, r.array_prototype, "keys", &array_keys);
    try common.method(rt, r.array_prototype, "values", &array_values);
    try common.method(rt, r.array_prototype, "entries", &array_entries);
    try common.method(rt, r.array_prototype, "forEach", &array_for_each);
    try common.method(rt, r.array_prototype, "map", &array_map);
    try common.method(rt, r.array_prototype, "filter", &array_filter);
    try common.method(rt, r.array_prototype, "reduce", &array_reduce);
    try common.method(rt, r.array_prototype, "find", &array_find);
    try common.method(rt, r.array_prototype, "findIndex", &array_find_index);
    try common.method(rt, r.array_prototype, "findLast", &array_find_last);
    try common.method(rt, r.array_prototype, "findLastIndex", &array_find_last_index);
    try common.method(rt, r.array_prototype, "some", &array_some);
    try common.method(rt, r.array_prototype, "every", &array_every);
    try common.method(rt, r.array_prototype, "concat", &array_concat);
    try common.method(rt, r.array_prototype, "reverse", &array_reverse);
    try common.method(rt, r.array_prototype, "at", &array_at);
    try common.method(rt, r.array_prototype, "lastIndexOf", &array_last_index_of);
    try common.method(rt, r.array_prototype, "fill", &array_fill);
    try common.method(rt, r.array_prototype, "shift", &array_shift);
    try common.method(rt, r.array_prototype, "unshift", &array_unshift);
    try common.method(rt, r.array_prototype, "splice", &array_splice);
    try common.method(rt, r.array_prototype, "sort", &array_sort);
    try common.method(rt, r.array_prototype, "reduceRight", &array_reduce_right);
    try common.method(rt, r.array_prototype, "flat", &array_flat);
    try common.method(rt, r.array_prototype, "flatMap", &array_flat_map);
    try common.method(rt, r.array_prototype, "copyWithin", &array_copy_within);
    try common.method(rt, r.array_prototype, "toReversed", &array_to_reversed);
    try common.method(rt, r.array_prototype, "toSorted", &array_to_sorted);
    try common.method(rt, r.array_prototype, "toSpliced", &array_to_spliced);
    try common.method(rt, r.array_prototype, "with", &array_with);
    try common.method(rt, r.array_namespace, "isArray", &array_is_array);
    try common.method(rt, r.array_namespace, "from", &array_from);
    try common.method(rt, r.array_namespace, "fromAsync", &array_from_async);
    try common.method(rt, r.array_namespace, "of", &array_of);
    try common.symbolMethod(rt, r.array_prototype, r.sym_iterator, &array_values);
    try common.immutableConstant(rt, r.array_namespace, "prototype", Value.fromObject(r.array_prototype));
    try common.constant(rt, r.array_prototype, "constructor", Value.fromNative(&builtins.array_global));
    try object.defineAccessor(rt, Value.fromObject(r.array_namespace), .{ .symbol = r.sym_species }, Value.fromNative(&common.species_getter), false, false);
}

pub const array_push: Native = .{ .name = "push", .length = 1, .call = arrayPush };

const array_pop: Native = .{ .name = "pop", .call = arrayPop };

const array_slice: Native = .{ .name = "slice", .length = 2, .call = arraySlice };

const array_index_of: Native = .{ .name = "indexOf", .length = 1, .call = arrayIndexOf };

const array_includes: Native = .{ .name = "includes", .length = 1, .call = arrayIncludes };

const array_join: Native = .{ .name = "join", .length = 1, .call = arrayJoin };

pub const array_to_string: Native = .{ .name = "toString", .call = arrayToString };

const array_keys: Native = .{ .name = "keys", .call = arrayKeys };

pub const array_values: Native = .{ .name = "values", .call = arrayValues };

const array_entries: Native = .{ .name = "entries", .call = arrayEntries };

const array_for_each: Native = .{ .name = "forEach", .length = 1, .call = arrayForEach };

const array_map: Native = .{ .name = "map", .length = 1, .call = arrayMap };

const array_filter: Native = .{ .name = "filter", .length = 1, .call = arrayFilter };

const array_reduce: Native = .{ .name = "reduce", .length = 1, .call = arrayReduce };

const array_find: Native = .{ .name = "find", .length = 1, .call = arrayFind };

const array_find_index: Native = .{ .name = "findIndex", .length = 1, .call = arrayFindIndex };

const array_find_last: Native = .{ .name = "findLast", .length = 1, .call = arrayFindLast };

const array_find_last_index: Native = .{ .name = "findLastIndex", .length = 1, .call = arrayFindLastIndex };

const array_some: Native = .{ .name = "some", .length = 1, .call = arraySome };

const array_every: Native = .{ .name = "every", .length = 1, .call = arrayEvery };

const array_concat: Native = .{ .name = "concat", .length = 1, .call = arrayConcat };

const array_reverse: Native = .{ .name = "reverse", .call = arrayReverse };

const array_at: Native = .{ .name = "at", .length = 1, .call = arrayAt };

const array_last_index_of: Native = .{ .name = "lastIndexOf", .length = 1, .call = arrayLastIndexOf };

const array_fill: Native = .{ .name = "fill", .length = 1, .call = arrayFill };

const array_shift: Native = .{ .name = "shift", .call = arrayShift };

const array_unshift: Native = .{ .name = "unshift", .length = 1, .call = arrayUnshift };

const array_splice: Native = .{ .name = "splice", .length = 2, .call = arraySplice };

const array_sort: Native = .{ .name = "sort", .length = 1, .call = arraySort };

const array_reduce_right: Native = .{ .name = "reduceRight", .length = 1, .call = arrayReduceRight };

const array_flat: Native = .{ .name = "flat", .call = arrayFlat };

const array_flat_map: Native = .{ .name = "flatMap", .length = 1, .call = arrayFlatMap };

const array_copy_within: Native = .{ .name = "copyWithin", .length = 2, .call = arrayCopyWithin };

const array_to_reversed: Native = .{ .name = "toReversed", .call = arrayToReversed };

const array_to_sorted: Native = .{ .name = "toSorted", .length = 1, .call = arrayToSorted };

const array_to_spliced: Native = .{ .name = "toSpliced", .length = 2, .call = arrayToSpliced };

const array_with: Native = .{ .name = "with", .length = 2, .call = arrayWith };

const array_is_array: Native = .{ .name = "isArray", .length = 1, .call = arrayIsArray };

const array_from: Native = .{ .name = "from", .length = 1, .call = arrayFrom };

const array_from_async: Native = .{ .name = "fromAsync", .length = 1, .call = arrayFromAsync };

const array_of: Native = .{ .name = "of", .call = arrayOf };

fn thisArray(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .array) return this.asObject();
    return common.unsupportedReceiver(rt, name);
}

pub inline fn hasCleanArrayProtoChainFast(rt: *const Runtime, a: *const Object) bool {
    const r = builtins.realmIfInit(rt) orelse return false;
    if (a.proto != r.array_prototype) return false;
    const ap = r.array_prototype;
    const op = r.object_prototype;
    if (ap.proto != op or op.proto != null) return false;
    if (op.props != .shaped or ap.props != .shaped) return false;
    const op_leaf = op.props.shaped.shape orelse return false;
    const ap_leaf = ap.props.shaped.shape orelse return false;
    return op_leaf.count == 6 and
        !op_leaf.key.isSymbol() and op_leaf.key.asAtom().units.len == 11 and op_leaf.key.asAtom().units[0] == 'c' and
        ap_leaf.count == 39 and
        !ap_leaf.key.isSymbol() and ap_leaf.key.asAtom().units.len == 11 and ap_leaf.key.asAtom().units[0] == 'c';
}

fn hasCleanArrayProtoChain(rt: *Runtime, a: *const Object) Error!bool {
    _ = try builtins.realm(rt);
    return hasCleanArrayProtoChainFast(rt, a);
}

fn hasHoles(items: []const Value) bool {
    for (items) |v| {
        if (v.isHole()) return true;
    }
    return false;
}

fn ensureWritableArrayLength(rt: *Runtime, o_val: Value) Error!void {
    if (o_val.isObject() and o_val.asObject().kind == .array and !o_val.asObject().array_length_writable) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property 'length'" }});
    }
}

fn arrayPush(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const cur = a.kind.array.items.len;
        if (a.extensible and a.array_length_writable and !a.has_index_overrides and
            args.len <= heap_mod.Heap.MAX_DENSE_ARRAY_LEN and
            cur <= heap_mod.Heap.MAX_DENSE_ARRAY_LEN - args.len and
            try hasCleanArrayProtoChain(rt, a))
        {
            if (args.len == 1) {
                try rt.heap.appendElement(a, args[0]);
            } else if (args.len > 1) {
                try rt.heap.appendElements(a, args);
            }
            return Value.fromNumber(@floatFromInt(a.kind.array.items.len));
        }
    }
    var root_buf = [_]Value{o_val};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const args_copy = try rt.gpa.dupe(Value, args);
    defer rt.gpa.free(args_copy);
    var arg_roots: rt_mod.ValueRoots = .{ .values = args_copy };
    try arg_roots.register(rt);
    defer arg_roots.unregister(rt);

    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    if (len_f + @as(f64, @floatFromInt(args_copy.len)) > 9007199254740991.0) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Invalid array length" }});
    }
    var len: usize = @intFromFloat(len_f);
    for (args_copy) |v| {
        try object.setStrict(rt, o_val, try common.indexKey(rt, len), v);
        len += 1;
    }
    try object.setStrict(rt, o_val, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(len)));
    try ensureWritableArrayLength(rt, o_val);
    return Value.fromNumber(@floatFromInt(len));
}

fn arrayPop(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const items = a.kind.array.items;
        if (items.len == 0) {
            try ensureWritableArrayLength(rt, o_val);
            return .undefined;
        }
        if (!items[items.len - 1].isHole() and
            a.array_elements_configurable and
            a.array_length_writable and
            try hasCleanArrayProtoChain(rt, a))
        {
            return rt.heap.popElement(a).?;
        }
    }
    var root_buf = [_]Value{ o_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    if (len_f == 0) {
        try object.setStrict(rt, o_val, try object.named(rt, "length"), Value.fromNumber(0));
        try ensureWritableArrayLength(rt, o_val);
        return .undefined;
    }
    const new_len: usize = @intFromFloat(len_f - 1.0);
    const k = try common.indexKey(rt, new_len);
    root_buf[1] = try object.get(rt, o_val, k);
    if (!try object.delete(rt, o_val, k)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
    }
    try object.setStrict(rt, o_val, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(new_len)));
    try ensureWritableArrayLength(rt, o_val);
    return root_buf[1];
}

fn arraySlice(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    var root_buf = [_]Value{ o_val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const is_dense_arr = o_val.isObject() and o_val.asObject().kind == .array;
    const len: usize = if (is_dense_arr)
        o_val.asObject().kind.array.items.len
    else
        @intFromFloat(try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length"))));

    const start = if (common.arg(args, 0).isUndefined()) 0 else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 0)), len);
    const end = if (common.arg(args, 1).isUndefined()) len else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 1)), len);
    const count = if (end > start) end - start else 0;

    const out_val = try common.arraySpeciesCreate(rt, o_val, count);
    root_buf[1] = out_val;

    if (is_dense_arr and out_val.isObject() and out_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const out_obj = out_val.asObject();
        const cur_items = a.kind.array.items;
        if (out_obj.extensible and out_obj.array_length_writable and
            out_obj.array_elements_writable and out_obj.array_elements_configurable and
            !out_obj.has_index_overrides and
            out_obj.kind.array.items.len == 0 and end <= cur_items.len and
            (start >= end or !hasHoles(cur_items[start..end])))
        {
            if (start < end) try rt.heap.appendElements(out_obj, cur_items[start..end]);
            return out_val;
        }
    }

    var n: usize = 0;
    var k: usize = start;
    while (k < end) : ({
        k += 1;
        n += 1;
    }) {
        const kk = try common.indexKey(rt, k);
        if (o_val.isObject() and o_val.asObject().kind == .array and k < o_val.asObject().kind.array.items.len and !o_val.asObject().kind.array.items[k].isHole()) {
            try common.arrayAppendOrDefine(rt, out_val, n, o_val.asObject().kind.array.items[k]);
        } else if (try object.has(rt, kk, o_val)) {
            root_buf[2] = try object.get(rt, o_val, kk);
            try common.arrayAppendOrDefine(rt, out_val, n, root_buf[2]);
            root_buf[2] = .undefined;
        }
    }
    try object.setStrict(rt, out_val, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(n)));
    try ensureWritableArrayLength(rt, out_val);
    return out_val;
}

fn arrayIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    const needle = common.arg(args, 0);
    var root_buf = [_]Value{ o_val, needle };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const is_arr = o_val.isObject() and o_val.asObject().kind == .array;
    const len: usize = if (is_arr)
        o_val.asObject().kind.array.items.len
    else
        @intFromFloat(try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length"))));
    if (len == 0) return Value.fromNumber(-1);

    const from_n = if (args.len >= 2) try common.toIntegerOrInfinity(rt, args[1]) else 0;
    const start = common.resolveSearchStart(from_n, len) orelse return Value.fromNumber(-1);

    for (start..len) |k| {
        if (is_arr) {
            const cur = o_val.asObject().kind.array.items;
            if (k < cur.len and !cur[k].isHole()) {
                if (ops.strictEquals(cur[k], needle)) return Value.fromNumber(@floatFromInt(k));
                continue;
            }
        }
        const key = try common.indexKey(rt, k);
        if (try object.has(rt, key, o_val)) {
            const elem = try object.get(rt, o_val, key);
            if (ops.strictEquals(elem, needle)) return Value.fromNumber(@floatFromInt(k));
        }
    }
    return Value.fromNumber(-1);
}

fn arrayIncludes(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    const needle = common.arg(args, 0);
    var root_buf = [_]Value{ o_val, needle };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const is_arr = o_val.isObject() and o_val.asObject().kind == .array;
    const len: usize = if (is_arr)
        o_val.asObject().kind.array.items.len
    else
        @intFromFloat(try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length"))));
    if (len == 0) return Value.fromBool(false);

    const from_n = if (args.len >= 2) try common.toIntegerOrInfinity(rt, args[1]) else 0;
    const start = common.resolveSearchStart(from_n, len) orelse return Value.fromBool(false);

    for (start..len) |k| {
        const elem = if (is_arr and k < o_val.asObject().kind.array.items.len and !o_val.asObject().kind.array.items[k].isHole())
            o_val.asObject().kind.array.items[k]
        else
            try object.get(rt, o_val, try common.indexKey(rt, k));
        if (common.sameValueZero(elem, needle)) return Value.fromBool(true);
    }
    return Value.fromBool(false);
}

fn arrayJoin(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    const sep = common.arg(args, 0);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        if (sep.isUndefined()) return Value.fromString(try object.join(rt, a, &.{','}));
        var roots_buf = [_]Value{ o_val, .undefined };
        var roots = rt_mod.ValueRoots{ .values = &roots_buf };
        try roots.register(rt);
        defer roots.unregister(rt);

        var buf: ops.NumberBuf = undefined;
        const piece = try ops.toPiece(rt, sep, &buf);
        const sep_str = try rt.heap.newString(&.{piece});
        roots_buf[1] = Value.fromString(sep_str);
        return Value.fromString(try object.join(rt, a, sep_str.units));
    }
    var roots_buf = [_]Value{ o_val, sep, .undefined, .undefined };
    var roots = rt_mod.ValueRoots{ .values = &roots_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const sep_units: []const u16 = if (sep.isUndefined())
        &.{','}
    else blk: {
        const s_obj = try common.toStringObj(rt, sep);
        roots_buf[2] = Value.fromString(s_obj);
        break :blk s_obj.units;
    };
    if (len_f == 0) return Value.fromString(try rt.heap.newString(&.{}));
    const len: usize = @intFromFloat(len_f);
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);
    for (0..len) |i| {
        if (i > 0) try common.appendUnits(rt, &out, sep_units);
        const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
        if (elem.isUndefined() or elem.isNull()) continue;
        const elem_s = try common.toStringObj(rt, elem);
        roots_buf[3] = Value.fromString(elem_s);
        try common.appendUnits(rt, &out, elem_s.units);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

/// Array.prototype.toString calls `this.join`, falling back to Object.prototype.toString.
fn arrayToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    var roots_buf = [_]Value{this};
    var roots = rt_mod.ValueRoots{ .values = &roots_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const j = try object.get(rt, this, try object.named(rt, "join"));
    if (j.isNative() and j.asNative() == &array_join) return arrayJoin(rt, this, &.{});
    if (j.isFunction()) return rt.callCallable(j, this, &.{});
    return obj_builtins.objectToString(rt, this, &.{}); // join not callable: the Object.prototype one
}

fn arrayKeys(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).array_iterator_prototype, this, .array_keys));
}

fn arrayValues(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).array_iterator_prototype, this, .array_values));
}

fn arrayEntries(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).array_iterator_prototype, this, .array_entries));
}

fn arrayForEach(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    const this_arg = common.arg(args, 1);
    var root_buf = [_]Value{ o_val, common.arg(args, 0), this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const cb = try common.requireCallable(rt, root_buf[1]);
        for (0..len) |i| {
            const raw = if (i < a.kind.array.items.len) a.kind.array.items[i] else Value.hole;
            if (raw.isHole()) {
                if (!try object.has(rt, .{ .index = @intCast(i) }, o_val)) continue;
                const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
                _ = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
                continue;
            }
            _ = try rt.callCallable(cb, this_arg, &.{ raw, Value.fromNumber(@floatFromInt(i)), o_val });
        }
        return .undefined;
    }
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const cb = try common.requireCallable(rt, root_buf[1]);
    for (0..len) |i| {
        if (try object.has(rt, .{ .index = @intCast(i) }, o_val)) {
            const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
            _ = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
        }
    }
    return .undefined;
}

fn arrayMap(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    const this_arg = common.arg(args, 1);
    var root_buf = [_]Value{ o_val, common.arg(args, 0), this_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const cb = try common.requireCallable(rt, root_buf[1]);
        const out_val = try common.arraySpeciesCreate(rt, o_val, len);
        root_buf[3] = out_val;
        for (0..len) |i| {
            const raw = if (i < a.kind.array.items.len) a.kind.array.items[i] else Value.hole;
            const elem = if (raw.isHole()) blk: {
                if (!try object.has(rt, .{ .index = @intCast(i) }, o_val)) {
                    if (out_val.isObject() and out_val.asObject().kind == .array and out_val.asObject().kind.array.items.len <= i) {
                        try rt.heap.growElementsWithHoles(out_val.asObject(), i + 1);
                    }
                    continue;
                }
                break :blk try object.get(rt, o_val, .{ .index = @intCast(i) });
            } else raw;
            root_buf[4] = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
            try common.arrayAppendOrDefine(rt, out_val, i, root_buf[4]);
            root_buf[4] = .undefined;
        }
        return out_val;
    }
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const cb = try common.requireCallable(rt, root_buf[1]);
    const out_val = try common.arraySpeciesCreate(rt, o_val, len);
    root_buf[3] = out_val;
    for (0..len) |i| {
        if (!try object.has(rt, .{ .index = @intCast(i) }, o_val)) {
            if (out_val.isObject() and out_val.asObject().kind == .array and out_val.asObject().kind.array.items.len <= i) {
                try rt.heap.growElementsWithHoles(out_val.asObject(), i + 1);
            }
            continue;
        }
        const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
        root_buf[4] = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
        try common.arrayAppendOrDefine(rt, out_val, i, root_buf[4]);
        root_buf[4] = .undefined;
    }
    return out_val;
}

fn arrayFilter(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    const this_arg = common.arg(args, 1);
    var root_buf = [_]Value{ o_val, common.arg(args, 0), this_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const cb = try common.requireCallable(rt, root_buf[1]);
        const out_val = try common.arraySpeciesCreate(rt, o_val, 0);
        root_buf[3] = out_val;
        var to: usize = 0;
        for (0..len) |i| {
            const raw = if (i < a.kind.array.items.len) a.kind.array.items[i] else Value.hole;
            const elem = if (raw.isHole()) blk: {
                if (!try object.has(rt, .{ .index = @intCast(i) }, o_val)) continue;
                break :blk try object.get(rt, o_val, .{ .index = @intCast(i) });
            } else raw;
            root_buf[4] = elem;
            const keep = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
            if (ops.toBoolean(keep)) {
                try common.arrayAppendOrDefine(rt, out_val, to, root_buf[4]);
                to += 1;
            }
            root_buf[4] = .undefined;
        }
        return out_val;
    }
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const cb = try common.requireCallable(rt, root_buf[1]);
    const out_val = try common.arraySpeciesCreate(rt, o_val, 0);
    root_buf[3] = out_val;
    var to: usize = 0;
    for (0..len) |i| {
        if (try object.has(rt, .{ .index = @intCast(i) }, o_val)) {
            const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
            root_buf[4] = elem;
            const keep = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
            if (ops.toBoolean(keep)) {
                try common.arrayAppendOrDefine(rt, out_val, to, root_buf[4]);
                to += 1;
            }
            root_buf[4] = .undefined;
        }
    }
    return out_val;
}

fn arrayReduce(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    var root_buf = [_]Value{ o_val, common.arg(args, 0), common.arg(args, 1) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const cb = try common.requireCallable(rt, root_buf[1]);
        const elems = a.kind.array.items;
        const len = elems.len;
        var start: usize = 0;
        if (args.len < 2) {
            var found = false;
            while (start < len) : (start += 1) {
                const raw = if (start < a.kind.array.items.len) a.kind.array.items[start] else Value.hole;
                if (raw.isHole()) {
                    if (!try object.has(rt, .{ .index = @intCast(start) }, o_val)) continue;
                    root_buf[2] = try object.get(rt, o_val, .{ .index = @intCast(start) });
                } else {
                    root_buf[2] = raw;
                }
                start += 1;
                found = true;
                break;
            }
            if (!found) return rt.throw(.TypeError, &.{.{ .ascii = "Reduce of empty array with no initial value" }});
        }
        for (start..len) |i| {
            const raw = if (i < a.kind.array.items.len) a.kind.array.items[i] else Value.hole;
            const elem = if (raw.isHole()) blk: {
                if (!try object.has(rt, .{ .index = @intCast(i) }, o_val)) continue;
                break :blk try object.get(rt, o_val, .{ .index = @intCast(i) });
            } else raw;
            root_buf[2] = try rt.callCallable(cb, .undefined, &.{ root_buf[2], elem, Value.fromNumber(@floatFromInt(i)), o_val });
        }
        return root_buf[2];
    }
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const cb = try common.requireCallable(rt, root_buf[1]);
    var k: usize = 0;
    if (args.len < 2) {
        var found = false;
        while (k < len) : (k += 1) {
            if (try object.has(rt, .{ .index = @intCast(k) }, o_val)) {
                root_buf[2] = try object.get(rt, o_val, .{ .index = @intCast(k) });
                k += 1;
                found = true;
                break;
            }
        }
        if (!found) return rt.throw(.TypeError, &.{.{ .ascii = "Reduce of empty array with no initial value" }});
    }
    while (k < len) : (k += 1) {
        if (try object.has(rt, .{ .index = @intCast(k) }, o_val)) {
            const elem = try object.get(rt, o_val, .{ .index = @intCast(k) });
            root_buf[2] = try rt.callCallable(cb, .undefined, &.{ root_buf[2], elem, Value.fromNumber(@floatFromInt(k)), o_val });
        }
    }
    return root_buf[2];
}

const FindMode = enum { find, find_index, find_last, find_last_index };

fn arrayFindImpl(rt: *Runtime, this: Value, args: []const Value, _: []const u8, comptime mode: FindMode) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    const this_arg = common.arg(args, 1);
    var root_buf = [_]Value{ o_val, common.arg(args, 0), this_arg, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const reverse = (mode == .find_last or mode == .find_last_index);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const cb = try common.requireCallable(rt, root_buf[1]);
        for (0..len) |step| {
            const i = if (reverse) len - 1 - step else step;
            const raw = if (i < a.kind.array.items.len) a.kind.array.items[i] else Value.hole;
            const elem = if (raw.isHole()) try object.get(rt, o_val, .{ .index = @intCast(i) }) else raw;
            root_buf[3] = elem;
            const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
            if (ops.toBoolean(res)) {
                return switch (mode) {
                    .find, .find_last => root_buf[3],
                    .find_index, .find_last_index => Value.fromNumber(@floatFromInt(i)),
                };
            }
            root_buf[3] = .undefined;
        }
    } else {
        const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
        const cb = try common.requireCallable(rt, root_buf[1]);
        const len: usize = @intFromFloat(len_f);
        for (0..len) |step| {
            const i = if (reverse) len - 1 - step else step;
            const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
            root_buf[3] = elem;
            const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
            if (ops.toBoolean(res)) {
                return switch (mode) {
                    .find, .find_last => root_buf[3],
                    .find_index, .find_last_index => Value.fromNumber(@floatFromInt(i)),
                };
            }
            root_buf[3] = .undefined;
        }
    }
    return switch (mode) {
        .find, .find_last => .undefined,
        .find_index, .find_last_index => Value.fromNumber(-1),
    };
}

fn arrayFind(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return arrayFindImpl(rt, this, args, "find", .find);
}

fn arrayFindIndex(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return arrayFindImpl(rt, this, args, "findIndex", .find_index);
}

fn arrayFindLast(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return arrayFindImpl(rt, this, args, "findLast", .find_last);
}

fn arrayFindLastIndex(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return arrayFindImpl(rt, this, args, "findLastIndex", .find_last_index);
}

fn arraySomeEveryImpl(rt: *Runtime, this: Value, args: []const Value, _: []const u8, comptime is_every: bool) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    const this_arg = common.arg(args, 1);
    var root_buf = [_]Value{ o_val, common.arg(args, 0), this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const cb = try common.requireCallable(rt, root_buf[1]);
        for (0..len) |i| {
            const raw = if (i < a.kind.array.items.len) a.kind.array.items[i] else Value.hole;
            const elem = if (raw.isHole()) blk: {
                if (!try object.has(rt, .{ .index = @intCast(i) }, o_val)) continue;
                break :blk try object.get(rt, o_val, .{ .index = @intCast(i) });
            } else raw;
            const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
            const b = ops.toBoolean(res);
            if (is_every and !b) return Value.fromBool(false);
            if (!is_every and b) return Value.fromBool(true);
        }
        return Value.fromBool(is_every);
    }
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const cb = try common.requireCallable(rt, root_buf[1]);
    for (0..len) |i| {
        if (try object.has(rt, .{ .index = @intCast(i) }, o_val)) {
            const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
            const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
            const b = ops.toBoolean(res);
            if (is_every and !b) return Value.fromBool(false);
            if (!is_every and b) return Value.fromBool(true);
        }
    }
    return Value.fromBool(is_every);
}

fn arraySome(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return arraySomeEveryImpl(rt, this, args, "some", false);
}

fn arrayEvery(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return arraySomeEveryImpl(rt, this, args, "every", true);
}

fn isConcatSpreadable(rt: *Runtime, v: Value) Error!bool {
    if (!v.isObjectLike()) return false;
    const r = try builtins.realm(rt);
    const spreadable = try object.get(rt, v, .{ .symbol = r.sym_is_concat_spreadable });
    if (!spreadable.isUndefined()) return ops.toBoolean(spreadable);
    return isArray(rt, v);
}

fn concatAppendItem(rt: *Runtime, out: Value, n: *usize, item: Value, elem_root: *Value) Error!void {
    if (try isConcatSpreadable(rt, item)) {
        const out_fast = out.isObject() and out.asObject().kind == .array and
            out.asObject().extensible and out.asObject().array_length_writable and
            out.asObject().array_elements_writable and out.asObject().array_elements_configurable and
            !out.asObject().has_index_overrides;
        if (item.isObject() and item.asObject().kind == .array) {
            const items = item.asObject().kind.array.items;
            if (out_fast and n.* == out.asObject().kind.array.items.len and !hasHoles(items) and
                items.len <= heap_mod.Heap.MAX_DENSE_ARRAY_LEN and
                n.* <= heap_mod.Heap.MAX_DENSE_ARRAY_LEN - items.len)
            {
                try rt.heap.appendElements(out.asObject(), items);
                n.* += items.len;
                return;
            }
            const len = items.len;
            for (0..len) |i| {
                const cur_items = item.asObject().kind.array.items;
                if (i < cur_items.len and !cur_items[i].isHole()) {
                    elem_root.* = cur_items[i];
                    try common.arrayAppendOrDefine(rt, out, n.*, elem_root.*);
                    elem_root.* = .undefined;
                } else {
                    const kk = try common.indexKey(rt, i);
                    if (try object.has(rt, kk, item)) {
                        elem_root.* = try object.get(rt, item, kk);
                        try common.arrayAppendOrDefine(rt, out, n.*, elem_root.*);
                        elem_root.* = .undefined;
                    }
                }
                n.* += 1;
            }
            return;
        }
        const len_f = try common.toLength(rt, try object.get(rt, item, try object.named(rt, "length")));
        const len: usize = @intFromFloat(len_f);
        const max_safe_int: u64 = 9007199254740991;
        if (@as(u64, n.*) > max_safe_int or @as(u64, len) > max_safe_int - @as(u64, n.*)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Array length exceeds maximum safe integer" }});
        }
        for (0..len) |i| {
            const kk = try common.indexKey(rt, i);
            if (try object.has(rt, kk, item)) {
                elem_root.* = try object.get(rt, item, kk);
                try common.arrayAppendOrDefine(rt, out, n.*, elem_root.*);
                elem_root.* = .undefined;
            }
            n.* += 1;
        }
    } else {
        const max_safe_int: u64 = 9007199254740991;
        if (@as(u64, n.*) >= max_safe_int) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Array length exceeds maximum safe integer" }});
        }
        try common.arrayAppendOrDefine(rt, out, n.*, item);
        n.* += 1;
    }
}

fn arrayConcat(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    var root_buf = [_]Value{ o_val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const out = try common.arraySpeciesCreate(rt, o_val, 0);
    root_buf[1] = out;
    var n: usize = 0;
    try concatAppendItem(rt, out, &n, o_val, &root_buf[2]);
    for (args) |v| {
        try concatAppendItem(rt, out, &n, v, &root_buf[2]);
    }
    try object.setStrict(rt, out, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(n)));
    try ensureWritableArrayLength(rt, out);
    return out;
}

fn arrayReverse(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        if (len <= 1) return o_val;
        if (!hasHoles(a.kind.array.items) and a.array_elements_writable and try hasCleanArrayProtoChain(rt, a)) {
            var lo: usize = 0;
            while (lo < len / 2) : (lo += 1) {
                const hi = len - 1 - lo;
                const tmp = a.kind.array.items[lo];
                rt.heap.storeElement(a, lo, a.kind.array.items[hi]);
                rt.heap.storeElement(a, hi, tmp);
            }
            return o_val;
        }
    }
    var root_buf = [_]Value{ o_val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_f = if (o_val.isObject() and o_val.asObject().kind == .array)
        @as(f64, @floatFromInt(o_val.asObject().kind.array.items.len))
    else
        try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    var lo: usize = 0;
    while (lo < len / 2) : (lo += 1) {
        const hi = len - 1 - lo;
        const lo_k = try common.indexKey(rt, lo);
        const hi_k = try common.indexKey(rt, hi);
        const lo_exists = try object.has(rt, lo_k, o_val);
        if (lo_exists) root_buf[1] = try object.get(rt, o_val, lo_k);
        const hi_exists = try object.has(rt, hi_k, o_val);
        if (hi_exists) root_buf[2] = try object.get(rt, o_val, hi_k);
        if (lo_exists and hi_exists) {
            try object.setStrict(rt, o_val, lo_k, root_buf[2]);
            try object.setStrict(rt, o_val, hi_k, root_buf[1]);
        } else if (!lo_exists and hi_exists) {
            try object.setStrict(rt, o_val, lo_k, root_buf[2]);
            if (!try object.delete(rt, o_val, hi_k)) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
        } else if (lo_exists and !hi_exists) {
            if (!try object.delete(rt, o_val, lo_k)) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
            try object.setStrict(rt, o_val, hi_k, root_buf[1]);
        }
        root_buf[1] = .undefined;
        root_buf[2] = .undefined;
    }
    return o_val;
}

fn arrayAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const rel = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
        const k = if (rel >= 0) rel else @as(f64, @floatFromInt(len)) + rel;
        if (k < 0 or k >= @as(f64, @floatFromInt(len))) return .undefined;
        const idx: usize = @intFromFloat(k);
        const cur = a.kind.array.items;
        if (idx < cur.len and !cur[idx].isHole()) return cur[idx];
        return object.get(rt, o_val, try common.indexKey(rt, idx));
    }
    var root_buf = [_]Value{o_val};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const rel = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
    const k = if (rel >= 0) rel else len_f + rel;
    if (k < 0 or k >= len_f) return .undefined;
    return object.get(rt, o_val, try common.indexKey(rt, @intFromFloat(k)));
}

fn arrayLastIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    const needle = common.arg(args, 0);
    var root_buf = [_]Value{ o_val, needle };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const is_arr = o_val.isObject() and o_val.asObject().kind == .array;
    const len_f: f64 = if (is_arr)
        @floatFromInt(o_val.asObject().kind.array.items.len)
    else
        try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    if (len_f == 0) return Value.fromNumber(-1);

    const n = if (args.len >= 2) try common.toIntegerOrInfinity(rt, args[1]) else len_f - 1;
    const k_f = if (n >= 0) @min(n, len_f - 1) else len_f + n;
    if (k_f < 0) return Value.fromNumber(-1);
    var k: usize = @intFromFloat(k_f);
    while (true) {
        if (is_arr) {
            const cur = o_val.asObject().kind.array.items;
            if (k < cur.len and !cur[k].isHole()) {
                if (ops.strictEquals(cur[k], needle)) return Value.fromNumber(@floatFromInt(k));
                if (k == 0) break;
                k -= 1;
                continue;
            }
        }
        const key = try common.indexKey(rt, k);
        if (try object.has(rt, key, o_val)) {
            const elem = try object.get(rt, o_val, key);
            if (ops.strictEquals(elem, needle)) return Value.fromNumber(@floatFromInt(k));
        }
        if (k == 0) break;
        k -= 1;
    }
    return Value.fromNumber(-1);
}

fn arrayFill(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    const val = common.arg(args, 0);
    var root_buf = [_]Value{ o_val, val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const is_arr = o_val.isObject() and o_val.asObject().kind == .array;
    const len: usize = if (is_arr)
        o_val.asObject().kind.array.items.len
    else
        @intFromFloat(try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length"))));

    const start = if (common.arg(args, 1).isUndefined()) 0 else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 1)), len);
    const end = if (common.arg(args, 2).isUndefined()) len else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 2)), len);

    if (start >= end) return o_val;
    if (is_arr) {
        const a = o_val.asObject();
        if (end <= a.kind.array.items.len and a.array_elements_writable and !hasHoles(a.kind.array.items[start..end]) and try hasCleanArrayProtoChain(rt, a)) {
            for (start..end) |i| rt.heap.storeElement(a, i, val);
            return o_val;
        }
    }
    for (start..end) |i| try object.setStrict(rt, o_val, try common.indexKey(rt, i), val);
    return o_val;
}

fn arrayShift(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const items = a.kind.array.items;
        if (items.len == 0) {
            try ensureWritableArrayLength(rt, o_val);
            return .undefined;
        }
        if (a.array_elements_configurable and a.array_elements_writable and a.array_length_writable and
            !hasHoles(items) and try hasCleanArrayProtoChain(rt, a))
        {
            const first = items[0];
            for (1..items.len) |i| rt.heap.storeElement(a, i - 1, items[i]);
            rt.heap.shrinkElements(a, items.len - 1);
            return first;
        }
    }
    var root_buf = [_]Value{ o_val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_f = if (o_val.isObject() and o_val.asObject().kind == .array)
        @as(f64, @floatFromInt(o_val.asObject().kind.array.items.len))
    else
        try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    if (len_f == 0) {
        try object.setStrict(rt, o_val, try object.named(rt, "length"), Value.fromNumber(0));
        try ensureWritableArrayLength(rt, o_val);
        return .undefined;
    }
    const len: usize = @intFromFloat(len_f);
    root_buf[1] = try object.get(rt, o_val, .{ .index = 0 });
    for (1..len) |i| {
        const from_k = try common.indexKey(rt, i);
        const to_k = try common.indexKey(rt, i - 1);
        if (try object.has(rt, from_k, o_val)) {
            root_buf[2] = try object.get(rt, o_val, from_k);
            try object.setStrict(rt, o_val, to_k, root_buf[2]);
            root_buf[2] = .undefined;
        } else {
            if (!try object.delete(rt, o_val, to_k)) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
        }
    }
    if (!try object.delete(rt, o_val, try common.indexKey(rt, len - 1))) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
    }
    try object.setStrict(rt, o_val, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(len - 1)));
    try ensureWritableArrayLength(rt, o_val);
    return root_buf[1];
}

fn arrayUnshift(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const old_len = a.kind.array.items.len;
        const ins_len = args.len;
        if (ins_len == 0) {
            try ensureWritableArrayLength(rt, o_val);
            return Value.fromNumber(@floatFromInt(old_len));
        }
        if (a.extensible and a.array_length_writable and a.array_elements_writable and a.array_elements_configurable and
            ins_len <= heap_mod.Heap.MAX_DENSE_ARRAY_LEN and
            old_len <= heap_mod.Heap.MAX_DENSE_ARRAY_LEN - ins_len and
            !hasHoles(a.kind.array.items) and try hasCleanArrayProtoChain(rt, a))
        {
            // Grow upfront so OOM leaves the array untouched.
            try rt.heap.appendElements(a, args);
            var i: usize = old_len;
            while (i > 0) {
                i -= 1;
                rt.heap.storeElement(a, i + ins_len, a.kind.array.items[i]);
            }
            for (args, 0..) |v, j| rt.heap.storeElement(a, j, v);
            return Value.fromNumber(@floatFromInt(a.kind.array.items.len));
        }
    }
    var root_buf = [_]Value{ o_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const args_copy = try rt.gpa.dupe(Value, args);
    defer rt.gpa.free(args_copy);
    var arg_roots: rt_mod.ValueRoots = .{ .values = args_copy };
    try arg_roots.register(rt);
    defer arg_roots.unregister(rt);

    const len_f = if (o_val.isObject() and o_val.asObject().kind == .array)
        @as(f64, @floatFromInt(o_val.asObject().kind.array.items.len))
    else
        try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const ins_len = args_copy.len;
    if (ins_len > 0) {
        if (len_f + @as(f64, @floatFromInt(ins_len)) > 9007199254740991.0) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Invalid array length" }});
        }
        var i: usize = @intFromFloat(len_f);
        while (i > 0) {
            i -= 1;
            const from_k = try common.indexKey(rt, i);
            const to_k = try common.indexKey(rt, i + ins_len);
            if (try object.has(rt, from_k, o_val)) {
                root_buf[1] = try object.get(rt, o_val, from_k);
                try object.setStrict(rt, o_val, to_k, root_buf[1]);
                root_buf[1] = .undefined;
            } else {
                if (!try object.delete(rt, o_val, to_k)) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
            }
        }
        for (args_copy, 0..) |v, j| try object.setStrict(rt, o_val, try common.indexKey(rt, j), v);
    }
    const new_len = len_f + @as(f64, @floatFromInt(ins_len));
    try object.setStrict(rt, o_val, try object.named(rt, "length"), Value.fromNumber(new_len));
    try ensureWritableArrayLength(rt, o_val);
    return Value.fromNumber(new_len);
}

fn arraySplice(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    if (!this.isObject() or this.asObject().kind != .array) {
        return common.unsupportedReceiver(rt, "splice");
    }
    const a = this.asObject();
    const len = a.kind.array.items.len;
    const actual_start: usize = if (args.len == 0) 0 else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, args[0]), len);
    const actual_delete: usize = if (args.len == 0)
        0
    else if (args.len == 1)
        len - actual_start
    else blk: {
        const dc = try common.toIntegerOrInfinity(rt, args[1]);
        const max_dc: f64 = @floatFromInt(len - actual_start);
        break :blk @intFromFloat(@min(@max(dc, 0), max_dc));
    };
    const insert_items = if (args.len > 2) args[2..] else &[_]Value{};
    const insert_count = insert_items.len;
    if (!a.has_index_overrides) {
        if ((insert_count != actual_delete) and !a.array_length_writable) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property 'length'" }});
        }
        if (insert_count > actual_delete and (!a.extensible or !a.array_length_writable)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Cannot add property, object is not extensible" }});
        }
        if (insert_count < actual_delete and (!a.array_elements_configurable or !a.array_length_writable)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property of non-configurable array" }});
        }
        if ((insert_count > 0 or (insert_count < actual_delete and actual_start + actual_delete < len)) and !a.array_elements_writable) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property" }});
        }
    }

    var root_buf = [_]Value{ this, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const out = try common.arraySpeciesCreate(rt, this, actual_delete);
    root_buf[1] = out;

    const out_fast = out.isObject() and out.asObject().kind == .array and
        out.asObject().extensible and out.asObject().array_length_writable and
        out.asObject().array_elements_writable and out.asObject().array_elements_configurable and
        !out.asObject().has_index_overrides and
        out.asObject().kind.array.items.len == 0 and
        actual_start + actual_delete <= a.kind.array.items.len and
        !hasHoles(a.kind.array.items[actual_start .. actual_start + actual_delete]);

    if (out_fast) {
        try rt.heap.appendElements(out.asObject(), a.kind.array.items[actual_start .. actual_start + actual_delete]);
    } else {
        for (0..actual_delete) |k| {
            const from_idx = actual_start + k;
            const cur_items = a.kind.array.items;
            if (from_idx < cur_items.len and !cur_items[from_idx].isHole()) {
                try common.arrayAppendOrDefine(rt, out, k, cur_items[from_idx]);
            } else {
                const fk = try common.indexKey(rt, from_idx);
                if (try object.has(rt, fk, this)) {
                    root_buf[2] = try object.get(rt, this, fk);
                    try common.arrayAppendOrDefine(rt, out, k, root_buf[2]);
                    root_buf[2] = .undefined;
                }
            }
        }
        try object.setStrict(rt, out, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(actual_delete)));
        try ensureWritableArrayLength(rt, out);
    }

    if (a.has_index_overrides) {
        const args_copy = try rt.gpa.dupe(Value, insert_items);
        defer rt.gpa.free(args_copy);
        var arg_roots: rt_mod.ValueRoots = .{ .values = args_copy };
        try arg_roots.register(rt);
        defer arg_roots.unregister(rt);

        if (insert_count < actual_delete) {
            var k: usize = actual_start;
            while (k < len - actual_delete) : (k += 1) {
                const from_k = try common.indexKey(rt, k + actual_delete);
                const to_k = try common.indexKey(rt, k + insert_count);
                if (try object.has(rt, from_k, this)) {
                    root_buf[2] = try object.get(rt, this, from_k);
                    try object.setStrict(rt, this, to_k, root_buf[2]);
                    root_buf[2] = .undefined;
                } else {
                    if (!try object.delete(rt, this, to_k)) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
                }
            }
            var del_k: usize = len;
            const target_len = len - actual_delete + insert_count;
            while (del_k > target_len) {
                del_k -= 1;
                if (!try object.delete(rt, this, try common.indexKey(rt, del_k))) {
                    return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
                }
            }
        } else if (insert_count > actual_delete) {
            var k: usize = len - actual_delete;
            while (k > actual_start) {
                k -= 1;
                const from_k = try common.indexKey(rt, k + actual_delete);
                const to_k = try common.indexKey(rt, k + insert_count);
                if (try object.has(rt, from_k, this)) {
                    root_buf[2] = try object.get(rt, this, from_k);
                    try object.setStrict(rt, this, to_k, root_buf[2]);
                    root_buf[2] = .undefined;
                } else {
                    if (!try object.delete(rt, this, to_k)) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
                }
            }
        }
        for (args_copy, 0..) |v, j| {
            try object.setStrict(rt, this, try common.indexKey(rt, actual_start + j), v);
        }
        const new_len = len - actual_delete + insert_count;
        try object.setStrict(rt, this, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(new_len)));
        try ensureWritableArrayLength(rt, this);
        return out;
    }

    const cur_len = a.kind.array.items.len;
    if (insert_count > actual_delete) {
        const delta = insert_count - actual_delete;
        try rt.heap.appendElements(a, insert_items[0..delta]);
        var i: usize = cur_len;
        while (i > actual_start + actual_delete) {
            i -= 1;
            rt.heap.storeElement(a, i + delta, a.kind.array.items[i]);
        }
    } else if (insert_count < actual_delete) {
        const tail_start = actual_start + actual_delete;
        if (tail_start < cur_len) {
            for (tail_start..cur_len) |i| {
                rt.heap.storeElement(a, i - actual_delete + insert_count, a.kind.array.items[i]);
            }
            rt.heap.shrinkElements(a, cur_len - actual_delete + insert_count);
        } else if (cur_len > actual_start + insert_count) {
            rt.heap.shrinkElements(a, actual_start + insert_count);
        }
    }

    for (insert_items, 0..) |v, j| {
        if (actual_start + j < a.kind.array.items.len) {
            rt.heap.storeElement(a, actual_start + j, v);
        } else {
            try common.arrayAppendOrDefine(rt, this, actual_start + j, v);
        }
    }
    return out;
}

fn arraySort(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const cb: ?Value = if (args.len >= 1 and !args[0].isUndefined()) try common.requireCallable(rt, args[0]) else null;
    const o_val = try common.toObjectReceiver(rt, this);
    const len_f: f64 = if (o_val.isObject() and o_val.asObject().kind == .array)
        @floatFromInt(o_val.asObject().kind.array.items.len)
    else
        try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    if (len_f <= 1.0) return o_val;
    const len: usize = @intFromFloat(len_f);

    const snap = try rt.heap.newArray(null);
    const tmp = try rt.heap.newArray(null);
    var root_buf = [_]Value{ o_val, cb orelse .undefined, Value.fromObject(snap), Value.fromObject(tmp), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const is_arr = o_val.isObject() and o_val.asObject().kind == .array;
    var undef_count: usize = 0;
    for (0..len) |i| {
        var v: Value = undefined;
        if (is_arr and i < o_val.asObject().kind.array.items.len and !o_val.asObject().kind.array.items[i].isHole()) {
            v = o_val.asObject().kind.array.items[i];
        } else {
            const k = try common.indexKey(rt, i);
            if (!try object.has(rt, k, o_val)) continue;
            v = try object.get(rt, o_val, k);
        }
        if (v.isUndefined()) {
            undef_count += 1;
        } else {
            try rt.heap.appendElement(snap, v);
        }
    }
    const defined_count = snap.kind.array.items.len;
    if (defined_count > 1) {
        try rt.heap.appendElements(tmp, snap.kind.array.items);
        try mergeSortRange(rt, cb, snap, tmp, 0, defined_count, &root_buf[4], &root_buf[5]);
    }

    const item_count = defined_count + undef_count;
    const clean_dense = is_arr and !o_val.asObject().has_index_overrides and o_val.asObject().array_elements_writable and try hasCleanArrayProtoChain(rt, o_val.asObject());
    for (0..item_count) |j| {
        const v: Value = if (j < defined_count) snap.kind.array.items[j] else .undefined;
        if (clean_dense and j < o_val.asObject().kind.array.items.len) {
            rt.heap.storeElement(o_val.asObject(), j, v);
        } else {
            try object.setStrict(rt, o_val, try common.indexKey(rt, j), v);
        }
    }
    for (item_count..len) |j| {
        if (is_arr and !o_val.asObject().has_index_overrides and j < o_val.asObject().kind.array.items.len and o_val.asObject().kind.array.items[j].isHole() and try hasCleanArrayProtoChain(rt, o_val.asObject())) {
            continue;
        }
        if (!try object.delete(rt, o_val, try common.indexKey(rt, j))) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
        }
    }
    return o_val;
}

fn mergeSortRange(
    rt: *Runtime,
    cb: ?Value,
    snap: *Object,
    tmp: *Object,
    lo: usize,
    hi: usize,
    root_a: *Value,
    root_b: *Value,
) Error!void {
    if (hi - lo <= 1) return;
    const mid = lo + (hi - lo) / 2;
    try mergeSortRange(rt, cb, snap, tmp, lo, mid, root_a, root_b);
    try mergeSortRange(rt, cb, snap, tmp, mid, hi, root_a, root_b);

    for (lo..hi) |k| rt.heap.storeElement(tmp, k, snap.kind.array.items[k]);

    var i = lo;
    var j = mid;
    var k = lo;
    while (i < mid and j < hi) : (k += 1) {
        const left_v = tmp.kind.array.items[i];
        const right_v = tmp.kind.array.items[j];
        const cmp = try sortCompare(rt, cb, left_v, right_v, root_a, root_b);
        if (cmp <= 0) {
            rt.heap.storeElement(snap, k, left_v);
            i += 1;
        } else {
            rt.heap.storeElement(snap, k, right_v);
            j += 1;
        }
    }
    while (i < mid) : ({
        i += 1;
        k += 1;
    }) rt.heap.storeElement(snap, k, tmp.kind.array.items[i]);
    while (j < hi) : ({
        j += 1;
        k += 1;
    }) rt.heap.storeElement(snap, k, tmp.kind.array.items[j]);
}

fn arrayReduceRight(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    var root_buf = [_]Value{ o_val, common.arg(args, 0), common.arg(args, 1) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const cb = try common.requireCallable(rt, root_buf[1]);
        const elems = a.kind.array.items;
        const len = elems.len;
        var idx: usize = len;
        if (args.len < 2) {
            var found = false;
            while (idx > 0) {
                idx -= 1;
                const raw = if (idx < a.kind.array.items.len) a.kind.array.items[idx] else Value.hole;
                if (raw.isHole()) {
                    if (!try object.has(rt, .{ .index = @intCast(idx) }, o_val)) continue;
                    root_buf[2] = try object.get(rt, o_val, .{ .index = @intCast(idx) });
                } else {
                    root_buf[2] = raw;
                }
                found = true;
                break;
            }
            if (!found) return rt.throw(.TypeError, &.{.{ .ascii = "Reduce of empty array with no initial value" }});
        }
        while (idx > 0) {
            idx -= 1;
            const raw = if (idx < a.kind.array.items.len) a.kind.array.items[idx] else Value.hole;
            const elem = if (raw.isHole()) blk: {
                if (!try object.has(rt, .{ .index = @intCast(idx) }, o_val)) continue;
                break :blk try object.get(rt, o_val, .{ .index = @intCast(idx) });
            } else raw;
            root_buf[2] = try rt.callCallable(cb, .undefined, &.{ root_buf[2], elem, Value.fromNumber(@floatFromInt(idx)), o_val });
        }
        return root_buf[2];
    }
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    var idx: usize = @intFromFloat(len_f);
    const cb = try common.requireCallable(rt, root_buf[1]);
    if (args.len < 2) {
        var found = false;
        while (idx > 0) {
            idx -= 1;
            if (try object.has(rt, .{ .index = @intCast(idx) }, o_val)) {
                root_buf[2] = try object.get(rt, o_val, .{ .index = @intCast(idx) });
                found = true;
                break;
            }
        }
        if (!found) return rt.throw(.TypeError, &.{.{ .ascii = "Reduce of empty array with no initial value" }});
    }
    while (idx > 0) {
        idx -= 1;
        if (try object.has(rt, .{ .index = @intCast(idx) }, o_val)) {
            const elem = try object.get(rt, o_val, .{ .index = @intCast(idx) });
            root_buf[2] = try rt.callCallable(cb, .undefined, &.{ root_buf[2], elem, Value.fromNumber(@floatFromInt(idx)), o_val });
        }
    }
    return root_buf[2];
}

fn flattenIntoArray(
    rt: *Runtime,
    target: Value,
    source: Value,
    source_len: usize,
    start: usize,
    depth: f64,
    mapper_fn: ?Value,
    this_arg: Value,
    rec_depth: u16,
) Error!usize {
    if (rec_depth >= rt.limits.max_nesting_depth) return rt.limit(.nesting_depth);
    var root_buf = [_]Value{ target, source, mapper_fn orelse .undefined, this_arg, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var target_index = start;
    var source_index: usize = 0;
    while (source_index < source_len) : (source_index += 1) {
        const p = try common.indexKey(rt, source_index);
        const exists: bool = blk: {
            if (source.isObject() and source.asObject().kind == .array) {
                const items = source.asObject().kind.array.items;
                if (source_index < items.len and !items[source_index].isHole()) break :blk true;
            }
            break :blk try object.has(rt, p, source);
        };
        if (!exists) continue;

        var element: Value = if (source.isObject() and source.asObject().kind == .array and source_index < source.asObject().kind.array.items.len and !source.asObject().kind.array.items[source_index].isHole())
            source.asObject().kind.array.items[source_index]
        else
            try object.get(rt, source, p);
        root_buf[4] = element;

        if (mapper_fn) |mf| {
            element = try rt.callCallable(mf, this_arg, &.{ element, Value.fromNumber(@floatFromInt(source_index)), source });
            root_buf[4] = element;
        }

        const should_flatten = if (depth > 0) try isArray(rt, element) else false;
        if (should_flatten) {
            const element_len_f = try common.toLength(rt, try object.get(rt, element, try object.named(rt, "length")));
            const element_len: usize = @intFromFloat(element_len_f);
            const next_depth = if (std.math.isInf(depth)) depth else depth - 1.0;
            target_index = try flattenIntoArray(rt, target, element, element_len, target_index, next_depth, null, .undefined, rec_depth + 1);
        } else {
            if (@as(u64, target_index) >= 9007199254740991) {
                return rt.throw(.TypeError, &.{.{ .ascii = "Array length exceeds maximum safe integer" }});
            }
            try common.arrayAppendOrDefine(rt, target, target_index, element);
            target_index += 1;
        }
        root_buf[4] = .undefined;
    }
    return target_index;
}

fn arrayFlat(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    var root_buf = [_]Value{ o_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const source_len: usize = if (o_val.isObject() and o_val.asObject().kind == .array)
        o_val.asObject().kind.array.items.len
    else
        @intFromFloat(try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length"))));
    const depth = if (args.len >= 1 and !args[0].isUndefined()) try common.toIntegerOrInfinity(rt, args[0]) else 1.0;
    const out = try common.arraySpeciesCreate(rt, o_val, 0);
    root_buf[1] = out;

    _ = try flattenIntoArray(rt, out, o_val, source_len, 0, depth, null, .undefined, 0);
    return out;
}

fn arrayFlatMap(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    var root_buf = [_]Value{ o_val, common.arg(args, 0), common.arg(args, 1), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const source_len: usize = if (o_val.isObject() and o_val.asObject().kind == .array)
        o_val.asObject().kind.array.items.len
    else
        @intFromFloat(try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length"))));
    const cb = try common.requireCallable(rt, root_buf[1]);
    root_buf[1] = cb;
    const out = try common.arraySpeciesCreate(rt, o_val, 0);
    root_buf[3] = out;

    _ = try flattenIntoArray(rt, out, o_val, source_len, 0, 1.0, cb, root_buf[2], 0);
    return out;
}

fn arrayCopyWithin(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    var root_buf = [_]Value{ o_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const is_arr = o_val.isObject() and o_val.asObject().kind == .array;
    const len: usize = if (is_arr)
        o_val.asObject().kind.array.items.len
    else
        @intFromFloat(try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length"))));

    const to = common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 0)), len);
    const from = common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 1)), len);
    const final_idx = if (common.arg(args, 2).isUndefined()) len else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 2)), len);
    const count = if (final_idx > from) @min(final_idx - from, len - to) else 0;
    if (count > 0) {
        if (is_arr) {
            const a = o_val.asObject();
            const items = a.kind.array.items;
            if (a.array_elements_writable and !a.has_index_overrides and
                from + count <= items.len and to + count <= items.len and
                !hasHoles(items[from .. from + count]) and
                try hasCleanArrayProtoChain(rt, a))
            {
                if (from != to) {
                    if (from < to and to < from + count) {
                        var i: usize = count;
                        while (i > 0) {
                            i -= 1;
                            rt.heap.storeElement(a, to + i, items[from + i]);
                        }
                    } else {
                        for (0..count) |i| {
                            rt.heap.storeElement(a, to + i, items[from + i]);
                        }
                    }
                }
                return o_val;
            }
        }
        const back = from < to and to < from + count;
        for (0..count) |step| {
            const offset = if (back) count - 1 - step else step;
            const from_k = try common.indexKey(rt, from + offset);
            const to_k = try common.indexKey(rt, to + offset);
            if (try object.has(rt, from_k, o_val)) {
                root_buf[1] = try object.get(rt, o_val, from_k);
                try object.setStrict(rt, o_val, to_k, root_buf[1]);
                root_buf[1] = .undefined;
            } else {
                if (!try object.delete(rt, o_val, to_k)) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
            }
        }
    }
    return o_val;
}

fn arrayToReversed(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    const r = try builtins.realm(rt);
    var root_buf = [_]Value{ o_val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const out = try rt.heap.newArray(r.array_prototype);
        root_buf[1] = Value.fromObject(out);
        var i: usize = a.kind.array.items.len;
        while (i > 0) {
            i -= 1;
            const cur = a.kind.array.items;
            const elem = if (i < cur.len and !cur[i].isHole()) cur[i] else try object.get(rt, o_val, try common.indexKey(rt, i));
            try rt.heap.appendElement(out, elem);
        }
        return Value.fromObject(out);
    }
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    if (len_f > @as(f64, @floatFromInt(std.math.maxInt(u32)))) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Invalid array length" }});
    }
    const out = try rt.heap.newArray(r.array_prototype);
    root_buf[1] = Value.fromObject(out);
    var i: usize = @intFromFloat(len_f);
    while (i > 0) {
        i -= 1;
        root_buf[2] = try object.get(rt, o_val, try common.indexKey(rt, i));
        try rt.heap.appendElement(out, root_buf[2]);
        root_buf[2] = .undefined;
    }
    return Value.fromObject(out);
}

fn arrayToSorted(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const cb: ?Value = if (args.len >= 1 and !args[0].isUndefined()) try common.requireCallable(rt, args[0]) else null;
    const o_val = try common.toObjectReceiver(rt, this);
    const len_f: f64 = if (o_val.isObject() and o_val.asObject().kind == .array)
        @floatFromInt(o_val.asObject().kind.array.items.len)
    else
        try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    if (len_f > @as(f64, @floatFromInt(std.math.maxInt(u32)))) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Invalid array length" }});
    }
    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    const len: usize = @intFromFloat(len_f);
    if (len == 0) return Value.fromObject(out);

    const snap = try rt.heap.newArray(null);
    const tmp = try rt.heap.newArray(null);
    var root_buf = [_]Value{ o_val, cb orelse .undefined, Value.fromObject(out), Value.fromObject(snap), Value.fromObject(tmp), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const is_arr = o_val.isObject() and o_val.asObject().kind == .array;
    for (0..len) |i| {
        const v: Value = if (is_arr and i < o_val.asObject().kind.array.items.len and !o_val.asObject().kind.array.items[i].isHole())
            o_val.asObject().kind.array.items[i]
        else
            try object.get(rt, o_val, try common.indexKey(rt, i));
        if (!v.isUndefined()) try rt.heap.appendElement(snap, v);
    }
    const defined_count = snap.kind.array.items.len;
    if (defined_count > 1) {
        try rt.heap.appendElements(tmp, snap.kind.array.items);
        try mergeSortRange(rt, cb, snap, tmp, 0, defined_count, &root_buf[5], &root_buf[6]);
    }

    try rt.heap.appendElements(out, snap.kind.array.items);
    for (defined_count..len) |_| {
        try rt.heap.appendElement(out, .undefined);
    }
    return Value.fromObject(out);
}

fn arrayToSpliced(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "toSpliced");
    const len = a.kind.array.items.len;
    const actual_start = if (args.len == 0) 0 else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, args[0]), len);
    const actual_delete: usize = if (args.len == 0)
        0
    else if (args.len == 1)
        len - actual_start
    else blk: {
        const dc = try common.toIntegerOrInfinity(rt, args[1]);
        if (dc <= 0) break :blk 0;
        const max_del: f64 = @floatFromInt(len - actual_start);
        break :blk @intFromFloat(@min(dc, max_del));
    };
    const insert_items = if (args.len > 2) args[2..] else &[_]Value{};

    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ this, Value.fromObject(out), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (0..actual_start) |i| {
        const cur = a.kind.array.items;
        const elem = if (i < cur.len and !cur[i].isHole()) cur[i] else try object.get(rt, this, try common.indexKey(rt, i));
        root_buf[2] = elem;
        try rt.heap.appendElement(out, elem);
        root_buf[2] = .undefined;
    }
    if (insert_items.len > 0) try rt.heap.appendElements(out, insert_items);
    for (actual_start + actual_delete..len) |i| {
        const cur = a.kind.array.items;
        const elem = if (i < cur.len and !cur[i].isHole()) cur[i] else try object.get(rt, this, try common.indexKey(rt, i));
        root_buf[2] = elem;
        try rt.heap.appendElement(out, elem);
        root_buf[2] = .undefined;
    }
    return Value.fromObject(out);
}

fn arrayWith(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    const r = try builtins.realm(rt);
    const val = common.arg(args, 1);
    var root_buf = [_]Value{ o_val, val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const is_arr = o_val.isObject() and o_val.asObject().kind == .array;
    const len_f: f64 = if (is_arr)
        @floatFromInt(o_val.asObject().kind.array.items.len)
    else
        try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const rel = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
    const actual_f = if (rel < 0) len_f + rel else rel;
    if (len_f > @as(f64, @floatFromInt(std.math.maxInt(u32)))) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Invalid array length" }});
    }
    if (!std.math.isFinite(actual_f) or actual_f < 0 or actual_f >= len_f) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Invalid index" }});
    }
    const out = try rt.heap.newArray(r.array_prototype);
    root_buf[2] = Value.fromObject(out);
    const actual_idx: usize = @intFromFloat(actual_f);
    const len: usize = @intFromFloat(len_f);
    for (0..len) |i| {
        if (i == actual_idx) {
            try rt.heap.appendElement(out, val);
        } else {
            const elem = if (is_arr and i < o_val.asObject().kind.array.items.len and !o_val.asObject().kind.array.items[i].isHole())
                o_val.asObject().kind.array.items[i]
            else
                try object.get(rt, o_val, try common.indexKey(rt, i));
            root_buf[3] = elem;
            try rt.heap.appendElement(out, root_buf[3]);
            root_buf[3] = .undefined;
        }
    }
    return Value.fromObject(out);
}

fn sortCompare(rt: *Runtime, cb: ?Value, x: Value, y: Value, root_a: *Value, root_b: *Value) Error!f64 {
    if (cb) |f| {
        const res = try rt.callCallable(f, .undefined, &.{ x, y });
        const v = try ops.toNumber(rt, res);
        return if (std.math.isNan(v)) 0 else v;
    }
    const xs = try common.toStringObj(rt, x);
    root_a.* = Value.fromString(xs);
    const ys = try common.toStringObj(rt, y);
    root_b.* = Value.fromString(ys);
    const ord = std.mem.order(u16, xs.units, ys.units);
    root_a.* = .undefined;
    root_b.* = .undefined;
    return switch (ord) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

// ---------------------------------------------------------------- String.prototype

pub fn isArray(rt: *Runtime, v: Value) Error!bool {
    var cur = v;
    while (cur.isObject()) {
        if (cur.asObject().kind == .array or cur.asObject().builtin == .array_prototype) return true;
        if (cur.asObject().kind != .proxy) return false;
        try rt.checkNativeStack();
        cur = cur.asObject().kind.proxy.target orelse return rt.throw(.TypeError, &.{.{ .ascii = "Cannot perform 'IsArray' on a proxy that has been revoked" }});
    }
    return false;
}

fn arrayIsArray(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(try isArray(rt, common.arg(args, 0)));
}

fn arrayOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    if (!this.isNative() or this.asNative() != &builtins.array_global) {
        if (function_error.isConstructor(this)) {
            const len_val: Value = Value.fromNumber(@floatFromInt(args.len));
            const a = try proxy_reflect.constructWithNewTarget(rt, this, &.{len_val}, this);
            var root_buf = [_]Value{a};
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);
            for (args, 0..) |v, i| {
                _ = try obj_builtins.defineOwnPropertyParsed(rt, a, .{ .index = @intCast(i) }, .{
                    .has_val = true,
                    .val = v,
                    .has_writ = true,
                    .writ_val = true,
                    .has_enum = true,
                    .enum_val = true,
                    .has_conf = true,
                    .conf_val = true,
                }, true);
            }
            _ = try object.setWithReceiver(rt, a, try object.named(rt, "length"), len_val, a, true);
            return a;
        }
    }
    const out = try rt.heap.newArray(r.array_prototype);
    try rt.heap.appendElements(out, args);
    return Value.fromObject(out);
}

fn arrayFrom(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const items = common.arg(args, 0);
    const has_map = args.len >= 2 and !args[1].isUndefined();
    const map_fn: Value = if (has_map) try common.requireCallable(rt, args[1]) else .undefined;
    const this_arg = common.arg(args, 2);

    const r = try builtins.realm(rt);
    var root_buf = [_]Value{ this, items, map_fn, this_arg, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (items.isUndefined() or items.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }

    const custom_ctor = function_error.isConstructor(this) and !(this.isNative() and this.asNative() == &builtins.array_global);

    if (try object.getMethod(rt, items, .{ .symbol = r.sym_iterator })) |iter_fn| {
        const out_val: Value = if (custom_ctor)
            try common.constructValue(rt, this, &.{})
        else
            Value.fromObject(try rt.heap.newArray(r.array_prototype));
        root_buf[4] = out_val;

        const iter = try iterator.getIteratorWithMethod(rt, items, iter_fn);
        root_buf[5] = Value.fromObject(iter);

        var k: usize = 0;
        while (try iterator.iteratorNextVal(rt, iter)) |elem| : (k += 1) {
            root_buf[6] = elem;
            const val = if (has_map)
                rt.callCallable(map_fn, this_arg, &.{ root_buf[6], Value.fromNumber(@floatFromInt(k)) }) catch |e| {
                    if (e == error.Thrown) try iterator.iteratorClose(rt, iter, true);
                    return e;
                }
            else
                elem;
            root_buf[6] = val;
            common.arrayAppendOrDefine(rt, out_val, k, val) catch |e| {
                if (e == error.Thrown) try iterator.iteratorClose(rt, iter, true);
                return e;
            };
            root_buf[6] = .undefined;
        }
        if (custom_ctor) {
            try object.setStrict(rt, out_val, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(k)));
        }
        return out_val;
    }

    const len_f = try common.toLength(rt, try object.get(rt, items, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const out_val: Value = if (custom_ctor)
        try common.constructValue(rt, this, &.{Value.fromNumber(len_f)})
    else
        Value.fromObject(try rt.heap.newArray(r.array_prototype));
    root_buf[4] = out_val;

    for (0..len) |k| {
        const elem = try object.get(rt, items, try common.indexKey(rt, k));
        root_buf[6] = elem;
        const val = if (has_map)
            try rt.callCallable(map_fn, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(k)) })
        else
            elem;
        root_buf[6] = val;
        try common.arrayAppendOrDefine(rt, out_val, k, val);
        root_buf[6] = .undefined;
    }
    if (custom_ctor) {
        try object.setStrict(rt, out_val, try object.named(rt, "length"), Value.fromNumber(len_f));
    }
    return out_val;
}

fn arrayFromAsync(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const res_p = try rt.heap.newPromise(r.promise_prototype);
    var root_buf = [_]Value{ this, Value.fromObject(res_p) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    arrayFromAsyncStart(rt, this, args, res_p) catch |e| {
        if (e == error.Thrown) {
            const reason = try rt.catchValue();
            try promise.settlePromiseFromJob(rt, res_p, true, reason);
            return Value.fromObject(res_p);
        }
        return e;
    };
    return Value.fromObject(res_p);
}

fn arrayFromAsyncStart(rt: *Runtime, this: Value, args: []const Value, res_p: *Object) Error!void {
    const items = common.arg(args, 0);
    const mapfn = common.arg(args, 1);
    const this_arg = common.arg(args, 2);
    if (!mapfn.isUndefined() and !mapfn.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Array.fromAsync: mapfn is not callable" }});
    }
    if (items.isUndefined() or items.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }

    const r = try builtins.realm(rt);
    const env = try rt.heap.newArray(null);
    var root_buf = [_]Value{ this, items, mapfn, this_arg, Value.fromObject(res_p), Value.fromObject(env), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var iter_val: Value = .undefined;
    var next_method: Value = .undefined;
    var is_async_iter = false;
    var limit_val: Value = .undefined;

    if (try object.getMethod(rt, items, .{ .symbol = r.sym_async_iterator })) |async_fn| {
        iter_val = try rt.callCallable(async_fn, items, &.{});
        if (!iter_val.isObjectLike()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Result of the Symbol.asyncIterator method is not an object" }});
        }
        root_buf[6] = iter_val;
        next_method = try object.get(rt, iter_val, try object.named(rt, "next"));
        root_buf[7] = next_method;
        is_async_iter = true;
    } else if (try object.getMethod(rt, items, .{ .symbol = r.sym_iterator })) |sync_fn| {
        const iter = try iterator.getIteratorWithMethod(rt, items, sync_fn);
        iter_val = Value.fromObject(iter);
        root_buf[6] = iter_val;
        next_method = try object.get(rt, iter_val, try object.named(rt, "next"));
        root_buf[7] = next_method;
        is_async_iter = false;
    } else {
        iter_val = items;
        const len_f = try common.toLength(rt, try object.get(rt, items, try object.named(rt, "length")));
        limit_val = Value.fromNumber(len_f);
    }

    const custom_ctor = function_error.isConstructor(this) and !(this.isNative() and this.asNative() == &builtins.array_global);
    const is_array_like = !limit_val.isUndefined();
    const out_val: Value = if (custom_ctor)
        (if (is_array_like) try common.constructValue(rt, this, &.{limit_val}) else try common.constructValue(rt, this, &.{}))
    else
        Value.fromObject(try rt.heap.newArray(r.array_prototype));
    root_buf[8] = out_val;

    // env layout: [0]=res_p, [1]=out, [2]=mapfn, [3]=this_arg, [4]=source/iter, [5]=next_method, [6]=index, [7]=limit, [8]=is_async_iter, [9]=custom_ctor
    try rt.heap.appendElements(env, &.{
        Value.fromObject(res_p),
        out_val,
        mapfn,
        this_arg,
        iter_val,
        next_method,
        Value.fromNumber(0),
        limit_val,
        Value.fromBool(is_async_iter),
        Value.fromBool(custom_ctor),
    });
    try arrayFromAsyncStep(rt, env);
}

fn arrayFromAsyncRejWithReasonCb(rt: *Runtime, env: *Object, _: []const Value) Error!Value {
    const res_p = env.kind.array.items[0].asObject();
    const reason = env.kind.array.items[1];
    try promise.settlePromiseFromJob(rt, res_p, true, reason);
    return .undefined;
}

fn arrayFromAsyncCloseOnErr(rt: *Runtime, env: *Object, reason: Value) Error!void {
    const res_p = env.kind.array.items[0].asObject();
    var root_buf = [_]Value{ Value.fromObject(env), Value.fromObject(res_p), reason, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (env.kind.array.items[7].isUndefined()) {
        const iter = env.kind.array.items[4];
        if (iter.isObjectLike()) {
            const is_async = env.kind.array.items[8].asBool();
            if (!is_async) {
                if (iter.isObject()) iterator.iteratorClose(rt, iter.asObject(), true) catch |e| {
                    if (e == error.Thrown) _ = rt.catchValue() catch {} else return e;
                };
            } else {
                const ret_m: ?Value = object.getMethod(rt, iter, try object.named(rt, "return")) catch |e| blk: {
                    if (e == error.Thrown) {
                        _ = rt.catchValue() catch {};
                        break :blk null;
                    }
                    return e;
                };
                if (ret_m) |rm| {
                    const maybe_ret: ?Value = rt.callCallable(rm, iter, &.{}) catch |e| blk: {
                        if (e == error.Thrown) {
                            _ = rt.catchValue() catch {};
                            break :blk null;
                        }
                        return e;
                    };
                    if (maybe_ret) |ret_val| {
                        root_buf[3] = ret_val;
                        const maybe_p: ?Value = promise.resolveToPromise(rt, ret_val) catch |e| blk: {
                            if (e == error.Thrown) {
                                _ = rt.catchValue() catch {};
                                break :blk null;
                            }
                            return e;
                        };
                        if (maybe_p) |ret_p| {
                            root_buf[3] = ret_p;
                            const rej_env = try rt.heap.newArray(null);
                            root_buf[4] = Value.fromObject(rej_env);
                            try rt.heap.appendElements(rej_env, &.{ Value.fromObject(res_p), reason });
                            const cb = try rt.heap.newNativeClosure(&arrayFromAsyncRejWithReasonCb, rej_env);
                            root_buf[5] = Value.fromClosure(cb);
                            _ = try promise.promiseThen(rt, ret_p, &.{ root_buf[5], root_buf[5] });
                            return;
                        }
                    }
                }
            }
        }
    }
    try promise.settlePromiseFromJob(rt, res_p, true, reason);
}

fn arrayFromAsyncStep(rt: *Runtime, env: *Object) Error!void {
    var root_buf = [_]Value{ Value.fromObject(env), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const res_p = env.kind.array.items[0].asObject();
    const source = env.kind.array.items[4];
    const next_method = env.kind.array.items[5];
    const is_async = env.kind.array.items[8].asBool();

    if (env.kind.array.items[7].isUndefined()) {
        const next_res = rt.callCallable(next_method, source, &.{}) catch |e| {
            if (e == error.Thrown) {
                try promise.settlePromiseFromJob(rt, res_p, true, try rt.catchValue());
                return;
            }
            return e;
        };
        root_buf[1] = next_res;
        if (is_async) {
            const p = promise.resolveToPromise(rt, next_res) catch |e| {
                if (e == error.Thrown) {
                    try promise.settlePromiseFromJob(rt, res_p, true, try rt.catchValue());
                    return;
                }
                return e;
            };
            root_buf[1] = p;
            const on_ful = try rt.heap.newNativeClosure(&arrayFromAsyncIterNextCb, env);
            root_buf[2] = Value.fromClosure(on_ful);
            const on_rej = try rt.heap.newNativeClosure(&arrayFromAsyncRejectCb, env);
            root_buf[3] = Value.fromClosure(on_rej);
            _ = try promise.promiseThen(rt, p, &.{ root_buf[2], root_buf[3] });
            return;
        }
        try arrayFromAsyncProcessIterResult(rt, env, next_res, false);
        return;
    }

    const k_f = env.kind.array.items[6].asNumber();
    const lim_f = env.kind.array.items[7].asNumber();
    if (k_f >= lim_f) {
        try arrayFromAsyncFinish(rt, env);
        return;
    }
    const key: object.Key = if (k_f <= @as(f64, @floatFromInt(std.math.maxInt(u32))))
        .{ .index = @intFromFloat(k_f) }
    else
        try object.key(rt, Value.fromNumber(k_f));
    const elem = object.get(rt, source, key) catch |e| {
        if (e == error.Thrown) {
            try promise.settlePromiseFromJob(rt, res_p, true, try rt.catchValue());
            return;
        }
        return e;
    };
    root_buf[1] = elem;
    const p = promise.resolveToPromise(rt, elem) catch |e| {
        if (e == error.Thrown) {
            try promise.settlePromiseFromJob(rt, res_p, true, try rt.catchValue());
            return;
        }
        return e;
    };
    root_buf[1] = p;
    const on_ful = try rt.heap.newNativeClosure(&arrayFromAsyncMapAndStoreCb, env);
    root_buf[2] = Value.fromClosure(on_ful);
    const on_rej = try rt.heap.newNativeClosure(&arrayFromAsyncRejectCb, env);
    root_buf[3] = Value.fromClosure(on_rej);
    _ = try promise.promiseThen(rt, p, &.{ root_buf[2], root_buf[3] });
}

fn arrayFromAsyncProcessIterResult(rt: *Runtime, env: *Object, next_res: Value, is_async: bool) Error!void {
    var root_buf = [_]Value{ Value.fromObject(env), next_res, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const res_p = env.kind.array.items[0].asObject();
    if (!next_res.isObject()) {
        const err_v = try function_error.makeEngineError(rt, .TypeError, try rt.heap.ascii("Iterator result is not an object"));
        try promise.settlePromiseFromJob(rt, res_p, true, err_v);
        return;
    }
    const done_v = object.get(rt, next_res, try object.named(rt, "done")) catch |e| {
        if (e == error.Thrown) {
            try promise.settlePromiseFromJob(rt, res_p, true, try rt.catchValue());
            return;
        }
        return e;
    };
    if (ops.toBoolean(done_v)) {
        try arrayFromAsyncFinish(rt, env);
        return;
    }
    const val = object.get(rt, next_res, try object.named(rt, "value")) catch |e| {
        if (e == error.Thrown) {
            try promise.settlePromiseFromJob(rt, res_p, true, try rt.catchValue());
            return;
        }
        return e;
    };
    root_buf[1] = val;
    if (is_async) {
        try arrayFromAsyncApplyMapOrStore(rt, env, val);
        return;
    }
    // Sync iterator: await the yielded value before mapping/storing.
    const p = promise.resolveToPromise(rt, val) catch |e| {
        if (e == error.Thrown) {
            try arrayFromAsyncCloseOnErr(rt, env, try rt.catchValue());
            return;
        }
        return e;
    };
    root_buf[1] = p;
    const on_ful = try rt.heap.newNativeClosure(&arrayFromAsyncMapAndStoreCb, env);
    root_buf[2] = Value.fromClosure(on_ful);
    const on_rej = try rt.heap.newNativeClosure(&arrayFromAsyncCloseRejectCb, env);
    root_buf[3] = Value.fromClosure(on_rej);
    _ = try promise.promiseThen(rt, p, &.{ root_buf[2], root_buf[3] });
}

fn arrayFromAsyncIterNextCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    try arrayFromAsyncProcessIterResult(rt, env, common.arg(args, 0), true);
    return .undefined;
}

fn arrayFromAsyncRejectCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    const res_p = env.kind.array.items[0].asObject();
    try promise.settlePromiseFromJob(rt, res_p, true, common.arg(args, 0));
    return .undefined;
}

fn arrayFromAsyncCloseRejectCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    try arrayFromAsyncCloseOnErr(rt, env, common.arg(args, 0));
    return .undefined;
}

fn arrayFromAsyncApplyMapOrStore(rt: *Runtime, env: *Object, val: Value) Error!void {
    var root_buf = [_]Value{ Value.fromObject(env), val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const mapfn = env.kind.array.items[2];
    const this_arg = env.kind.array.items[3];
    const k_val = env.kind.array.items[6];
    if (!mapfn.isUndefined()) {
        const mapped = rt.callCallable(mapfn, this_arg, &.{ val, k_val }) catch |e| {
            if (e == error.Thrown) {
                try arrayFromAsyncCloseOnErr(rt, env, try rt.catchValue());
                return;
            }
            return e;
        };
        root_buf[1] = mapped;
        const p = promise.resolveToPromise(rt, mapped) catch |e| {
            if (e == error.Thrown) {
                try arrayFromAsyncCloseOnErr(rt, env, try rt.catchValue());
                return;
            }
            return e;
        };
        root_buf[1] = p;
        const on_ful = try rt.heap.newNativeClosure(&arrayFromAsyncStoreCb, env);
        root_buf[2] = Value.fromClosure(on_ful);
        const on_rej = try rt.heap.newNativeClosure(&arrayFromAsyncCloseRejectCb, env);
        root_buf[3] = Value.fromClosure(on_rej);
        _ = try promise.promiseThen(rt, p, &.{ root_buf[2], root_buf[3] });
        return;
    }
    try arrayFromAsyncStoreAndAdvance(rt, env, val);
}

fn arrayFromAsyncMapAndStoreCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    try arrayFromAsyncApplyMapOrStore(rt, env, common.arg(args, 0));
    return .undefined;
}

fn arrayFromAsyncStoreCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    try arrayFromAsyncStoreAndAdvance(rt, env, common.arg(args, 0));
    return .undefined;
}

fn arrayFromAsyncFinish(rt: *Runtime, env: *Object) Error!void {
    const res_p = env.kind.array.items[0].asObject();
    const out = env.kind.array.items[1];
    if (env.kind.array.items[9].asBool()) {
        object.setStrict(rt, out, try object.named(rt, "length"), env.kind.array.items[6]) catch |e| {
            if (e == error.Thrown) {
                try promise.settlePromiseFromJob(rt, res_p, true, try rt.catchValue());
                return;
            }
            return e;
        };
    }
    try promise.settlePromiseFromJob(rt, res_p, false, out);
}

fn arrayFromAsyncStoreAndAdvance(rt: *Runtime, env: *Object, val: Value) Error!void {
    const out = env.kind.array.items[1];
    const k_f = env.kind.array.items[6].asNumber();
    const k: usize = @intFromFloat(k_f);
    common.arrayAppendOrDefine(rt, out, k, val) catch |e| {
        if (e == error.Thrown) {
            try arrayFromAsyncCloseOnErr(rt, env, try rt.catchValue());
            return;
        }
        return e;
    };
    rt.heap.storeElement(env, 6, Value.fromNumber(k_f + 1.0));
    try arrayFromAsyncStep(rt, env);
}

pub fn arrayCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return arrayConstruct(rt, args);
}

pub fn arrayConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    if (args.len == 0) {
        return Value.fromObject(try rt.heap.newArray(r.array_prototype));
    }
    if (args.len == 1) {
        const first = args[0];
        if (first.isNumber()) {
            const n = first.asNumber();
            const int_len = ops.toUint32(n);
            if (@as(f64, @floatFromInt(int_len)) != n) {
                return rt.throw(.RangeError, &.{.{ .ascii = "Invalid array length" }});
            }
            if (int_len > heap_mod.Heap.MAX_DENSE_ARRAY_LEN) return rt.fail(.sparse_array);
            const out = try rt.heap.newArray(r.array_prototype);
            if (int_len > 0) try rt.heap.growElementsWithHoles(out, int_len);
            return Value.fromObject(out);
        }
        const out = try rt.heap.newArray(r.array_prototype);
        try rt.heap.appendElement(out, first);
        return Value.fromObject(out);
    }
    const out = try rt.heap.newArray(r.array_prototype);
    try rt.heap.appendElements(out, args);
    return Value.fromObject(out);
}
