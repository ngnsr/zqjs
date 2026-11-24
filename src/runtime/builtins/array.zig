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

const array_push: Native = .{ .name = "push", .length = 1, .call = arrayPush };

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

fn checkArrayMutate(rt: *Runtime, a: *Object, opts: struct {
    grow: bool = false,
    shrink: bool = false,
    write_elements: bool = false,
    write_length: bool = false,
}) Error!void {
    if (opts.write_length and !a.array_length_writable) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property 'length'" }});
    }
    if (opts.grow and (!a.extensible or !a.array_length_writable)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot add property, object is not extensible" }});
    }
    if (opts.shrink and (!a.array_elements_configurable or !a.array_length_writable)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property of non-configurable array" }});
    }
    if (opts.write_elements and !a.array_elements_writable) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property" }});
    }
}

fn arrayPush(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "push");
    try checkArrayMutate(rt, a, .{ .grow = args.len > 0, .write_length = true });
    if (args.len == 1) {
        try rt.heap.appendElement(a, args[0]);
    } else if (args.len > 1) {
        try rt.heap.appendElements(a, args);
    }
    return Value.fromNumber(@floatFromInt(a.kind.array.items.len));
}

fn arrayPop(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const a = try thisArray(rt, this, "pop");
    try checkArrayMutate(rt, a, .{ .shrink = a.kind.array.items.len > 0, .write_length = true });
    const popped = rt.heap.popElement(a) orelse return .undefined;
    return popped.unwrapHole();
}

fn arraySlice(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isObject() and this.asObject().kind == .array) {
        var root_buf = [_]Value{ this, .undefined };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);

        const a = this.asObject();
        const len = a.kind.array.items.len;
        const start = if (common.arg(args, 0).isUndefined()) 0 else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 0)), len);
        const end = if (common.arg(args, 1).isUndefined()) len else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 1)), len);
        const count = if (end > start) end - start else 0;
        const out_val = try common.arraySpeciesCreate(rt, this, count);
        root_buf[1] = out_val;
        if (out_val.isObject() and out_val.asObject().kind == .array and out_val.asObject().kind.array.items.len == 0) {
            const cur_items = a.kind.array.items;
            const actual_end = @min(end, cur_items.len);
            if (start < actual_end) try rt.heap.appendElements(out_val.asObject(), cur_items[start..actual_end]);
            return out_val;
        }
        var n: usize = 0;
        var k: usize = start;
        while (k < end) : ({
            k += 1;
            n += 1;
        }) {
            if (k < a.kind.array.items.len) {
                try common.arrayAppendOrDefine(rt, out_val, n, a.kind.array.items[k]);
            }
        }
        try object.setStrict(rt, out_val, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(n)));
        return out_val;
    }
    const o_val = try common.toObjectReceiver(rt, this);
    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ o_val, Value.fromObject(out), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const start = if (common.arg(args, 0).isUndefined()) 0 else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 0)), len);
    const end = if (common.arg(args, 1).isUndefined()) len else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 1)), len);
    var k: usize = start;
    while (k < end) : (k += 1) {
        if (!try object.has(rt, .{ .index = @intCast(k) }, o_val)) {
            try rt.heap.appendElement(out, .hole);
            continue;
        }
        root_buf[2] = try object.get(rt, o_val, .{ .index = @intCast(k) });
        try rt.heap.appendElement(out, root_buf[2]);
        root_buf[2] = .undefined;
    }
    return Value.fromObject(out);
}

fn arrayIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isObject() and this.asObject().kind == .array) {
        const items = this.asObject().kind.array.items;
        if (items.len == 0) return Value.fromNumber(-1);
        const needle = common.arg(args, 0);
        const from_n = if (args.len >= 2) try common.toIntegerOrInfinity(rt, args[1]) else 0;
        const start = common.resolveSearchStart(from_n, items.len) orelse return Value.fromNumber(-1);
        for (items[start..], start..) |item, i| {
            if (item.isHole()) continue;
            if (ops.strictEquals(item, needle)) return Value.fromNumber(@floatFromInt(i));
        }
        return Value.fromNumber(-1);
    }
    const o_val = try common.toObjectReceiver(rt, this);
    const needle = common.arg(args, 0);
    var root_buf = [_]Value{ o_val, needle };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    if (len == 0) return Value.fromNumber(-1);
    const from_n = if (args.len >= 2) try common.toIntegerOrInfinity(rt, args[1]) else 0;
    const start = common.resolveSearchStart(from_n, len) orelse return Value.fromNumber(-1);
    for (start..len) |i| {
        if (try object.has(rt, .{ .index = @intCast(i) }, o_val)) {
            const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
            if (ops.strictEquals(elem, needle)) return Value.fromNumber(@floatFromInt(i));
        }
    }
    return Value.fromNumber(-1);
}

fn arrayIncludes(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isObject() and this.asObject().kind == .array) {
        const items = this.asObject().kind.array.items;
        if (items.len == 0) return Value.fromBool(false);
        const needle = common.arg(args, 0);
        const from_n = if (args.len >= 2) try common.toIntegerOrInfinity(rt, args[1]) else 0;
        const start = common.resolveSearchStart(from_n, items.len) orelse return Value.fromBool(false);
        for (items[start..], start..) |item, i| {
            const v = if (item.isHole()) try object.get(rt, this, .{ .index = @intCast(i) }) else item;
            if (common.sameValueZero(v, needle)) return Value.fromBool(true);
        }
        return Value.fromBool(false);
    }
    const o_val = try common.toObjectReceiver(rt, this);
    const needle = common.arg(args, 0);
    var root_buf = [_]Value{ o_val, needle };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    if (len == 0) return Value.fromBool(false);
    const from_n = if (args.len >= 2) try common.toIntegerOrInfinity(rt, args[1]) else 0;
    const start = common.resolveSearchStart(from_n, len) orelse return Value.fromBool(false);
    for (start..len) |i| {
        const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
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
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).iterator_prototype, this, .array_keys));
}

fn arrayValues(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).iterator_prototype, this, .array_values));
}

fn arrayEntries(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).iterator_prototype, this, .array_entries));
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
            if (i >= a.kind.array.items.len) continue;
            const raw = a.kind.array.items[i];
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
            if (i >= a.kind.array.items.len) continue;
            const raw = a.kind.array.items[i];
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
            if (i >= a.kind.array.items.len) continue;
            const raw = a.kind.array.items[i];
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
            if (i >= a.kind.array.items.len) continue;
            const raw = a.kind.array.items[i];
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
    if (!v.isObject() and !v.isClosure() and !v.isNative()) return false;
    const r = try builtins.realm(rt);
    const spreadable = try object.get(rt, v, .{ .symbol = r.sym_is_concat_spreadable });
    if (!spreadable.isUndefined()) return ops.toBoolean(spreadable);
    return v.isObject() and v.asObject().kind == .array;
}

fn concatAppendItem(rt: *Runtime, out: Value, n: *usize, item: Value, elem_root: *Value) Error!void {
    if (try isConcatSpreadable(rt, item)) {
        if (item.isObject() and item.asObject().kind == .array) {
            const items = item.asObject().kind.array.items;
            if (out.isObject() and out.asObject().kind == .array and n.* == out.asObject().kind.array.items.len) {
                try rt.heap.appendElements(out.asObject(), items);
                n.* += items.len;
            } else {
                for (items) |v| {
                    elem_root.* = v;
                    try common.arrayAppendOrDefine(rt, out, n.*, v);
                    n.* += 1;
                    elem_root.* = .undefined;
                }
            }
        } else {
            const len_f = try common.toLength(rt, try object.get(rt, item, try object.named(rt, "length")));
            const len: usize = @intFromFloat(len_f);
            for (0..len) |i| {
                if (!try object.has(rt, .{ .index = @intCast(i) }, item)) {
                    if (out.isObject() and out.asObject().kind == .array) {
                        try rt.heap.growElementsWithHoles(out.asObject(), n.* + 1);
                    }
                    n.* += 1;
                    continue;
                }
                elem_root.* = try object.get(rt, item, .{ .index = @intCast(i) });
                try common.arrayAppendOrDefine(rt, out, n.*, elem_root.*);
                n.* += 1;
                elem_root.* = .undefined;
            }
        }
    } else {
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
    if (!out.isObject() or out.asObject().kind != .array) {
        try object.setStrict(rt, out, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(n)));
    }
    return out;
}

fn arrayReverse(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        if (len > 1) try checkArrayMutate(rt, a, .{ .write_elements = true });
        var lo: usize = 0;
        while (lo < len / 2) : (lo += 1) {
            const hi = len - 1 - lo;
            const tmp = a.kind.array.items[lo];
            rt.heap.storeElement(a, lo, a.kind.array.items[hi]);
            rt.heap.storeElement(a, hi, tmp);
        }
        return o_val;
    }
    var root_buf = [_]Value{ o_val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    var lo: usize = 0;
    while (lo < len / 2) : (lo += 1) {
        const hi = len - 1 - lo;
        const lo_k: object.Key = .{ .index = @intCast(lo) };
        const hi_k: object.Key = .{ .index = @intCast(hi) };
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
        const raw = a.kind.array.items[@intFromFloat(k)];
        return if (raw.isHole()) try object.get(rt, this, .{ .index = @intFromFloat(k) }) else raw;
    }
    var root_buf = [_]Value{o_val};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const rel = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
    const k = if (rel >= 0) rel else len_f + rel;
    if (k < 0 or k >= len_f) return .undefined;
    return object.get(rt, o_val, .{ .index = @intFromFloat(k) });
}

fn arrayLastIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isObject() and this.asObject().kind == .array) {
        const items = this.asObject().kind.array.items;
        if (items.len == 0) return Value.fromNumber(-1);
        const needle = common.arg(args, 0);
        const len_f: f64 = @floatFromInt(items.len);
        const n = if (args.len >= 2) try common.toIntegerOrInfinity(rt, args[1]) else len_f - 1;
        const k_f = if (n >= 0) @min(n, len_f - 1) else len_f + n;
        if (k_f < 0) return Value.fromNumber(-1);
        var k: usize = @intFromFloat(k_f);
        while (true) : (k -= 1) {
            if (!items[k].isHole() and ops.strictEquals(items[k], needle)) return Value.fromNumber(@floatFromInt(k));
            if (k == 0) break;
        }
        return Value.fromNumber(-1);
    }
    const o_val = try common.toObjectReceiver(rt, this);
    const needle = common.arg(args, 0);
    var root_buf = [_]Value{ o_val, needle };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    if (len_f == 0) return Value.fromNumber(-1);
    const n = if (args.len >= 2) try common.toIntegerOrInfinity(rt, args[1]) else len_f - 1;
    const k_f = if (n >= 0) @min(n, len_f - 1) else len_f + n;
    if (k_f < 0) return Value.fromNumber(-1);
    var k: usize = @intFromFloat(k_f);
    while (true) : (k -= 1) {
        if (try object.has(rt, .{ .index = @intCast(k) }, o_val)) {
            const elem = try object.get(rt, o_val, .{ .index = @intCast(k) });
            if (ops.strictEquals(elem, needle)) return Value.fromNumber(@floatFromInt(k));
        }
        if (k == 0) break;
    }
    return Value.fromNumber(-1);
}

fn arrayFill(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    const val = common.arg(args, 0);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const start = if (common.arg(args, 1).isUndefined()) 0 else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 1)), len);
        const end = if (common.arg(args, 2).isUndefined()) len else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 2)), len);
        if (start < end) try checkArrayMutate(rt, a, .{ .write_elements = true });
        for (start..end) |i| {
            if (i < a.kind.array.items.len) {
                rt.heap.storeElement(a, i, val);
            } else {
                try object.setStrict(rt, o_val, .{ .index = @intCast(i) }, val);
            }
        }
        return o_val;
    }
    var root_buf = [_]Value{ o_val, val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const start = if (common.arg(args, 1).isUndefined()) 0 else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 1)), len);
    const end = if (common.arg(args, 2).isUndefined()) len else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 2)), len);
    for (start..end) |i| try object.setStrict(rt, o_val, .{ .index = @intCast(i) }, val);
    return o_val;
}

fn arrayShift(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const items = a.kind.array.items;
        if (items.len == 0) {
            try checkArrayMutate(rt, a, .{ .write_length = true });
            return .undefined;
        }
        try checkArrayMutate(rt, a, .{ .shrink = true, .write_elements = items.len > 1, .write_length = true });
        const first = if (items[0].isHole()) try object.get(rt, o_val, .{ .index = 0 }) else items[0];
        for (1..items.len) |i| rt.heap.storeElement(a, i - 1, items[i]);
        rt.heap.shrinkElements(a, items.len - 1);
        return first;
    }
    var root_buf = [_]Value{ o_val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    if (len_f == 0) {
        try object.setStrict(rt, o_val, try object.named(rt, "length"), Value.fromNumber(0));
        return .undefined;
    }
    const len: usize = @intFromFloat(len_f);
    root_buf[1] = try object.get(rt, o_val, .{ .index = 0 });
    for (1..len) |i| {
        const from_k: object.Key = .{ .index = @intCast(i) };
        const to_k: object.Key = .{ .index = @intCast(i - 1) };
        if (try object.has(rt, from_k, o_val)) {
            root_buf[2] = try object.get(rt, o_val, from_k);
            try object.setStrict(rt, o_val, to_k, root_buf[2]);
            root_buf[2] = .undefined;
        } else {
            if (!try object.delete(rt, o_val, to_k)) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
        }
    }
    if (!try object.delete(rt, o_val, .{ .index = @intCast(len - 1) })) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
    try object.setStrict(rt, o_val, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(len - 1)));
    return root_buf[1];
}

fn arrayUnshift(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const old_len = a.kind.array.items.len;
        const ins_len = args.len;
        try checkArrayMutate(rt, a, .{
            .grow = ins_len > 0,
            .write_elements = ins_len > 0 and old_len > 0,
            .write_length = true,
        });
        if (ins_len > 0) {
            // Grow upfront so OOM leaves the array untouched.
            try rt.heap.appendElements(a, args);
            var i: usize = old_len;
            while (i > 0) {
                i -= 1;
                rt.heap.storeElement(a, i + ins_len, a.kind.array.items[i]);
            }
            for (args, 0..) |v, j| rt.heap.storeElement(a, j, v);
        }
        return Value.fromNumber(@floatFromInt(a.kind.array.items.len));
    }
    var root_buf = [_]Value{ o_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const ins_len = args.len;
    if (ins_len > 0) {
        if (len_f + @as(f64, @floatFromInt(ins_len)) > 9007199254740991.0) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Invalid array length" }});
        }
        var i: usize = @intFromFloat(len_f);
        while (i > 0) {
            i -= 1;
            const from_k: object.Key = .{ .index = @intCast(i) };
            const to_k: object.Key = .{ .index = @intCast(i + ins_len) };
            if (try object.has(rt, from_k, o_val)) {
                root_buf[1] = try object.get(rt, o_val, from_k);
                try object.setStrict(rt, o_val, to_k, root_buf[1]);
                root_buf[1] = .undefined;
            } else {
                if (!try object.delete(rt, o_val, to_k)) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
            }
        }
        for (args, 0..) |v, j| try object.setStrict(rt, o_val, .{ .index = @intCast(j) }, v);
    }
    const new_len = len_f + @as(f64, @floatFromInt(ins_len));
    try object.setStrict(rt, o_val, try object.named(rt, "length"), Value.fromNumber(new_len));
    return Value.fromNumber(new_len);
}

fn arraySplice(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "splice");
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
    try checkArrayMutate(rt, a, .{
        .grow = insert_count > actual_delete,
        .shrink = insert_count < actual_delete,
        .write_elements = insert_count > 0 or (insert_count < actual_delete and actual_start + actual_delete < len),
        .write_length = insert_count != actual_delete,
    });

    var root_buf = [_]Value{ this, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const out = try common.arraySpeciesCreate(rt, this, actual_delete);
    root_buf[1] = out;

    if (out.isObject() and out.asObject().kind == .array and out.asObject().kind.array.items.len == 0) {
        try rt.heap.appendElements(out.asObject(), a.kind.array.items[actual_start .. actual_start + actual_delete]);
    } else {
        for (0..actual_delete) |k| {
            const elem = if (actual_start + k < a.kind.array.items.len) a.kind.array.items[actual_start + k] else Value.undefined;
            try common.arrayAppendOrDefine(rt, out, k, elem);
        }
        try object.setStrict(rt, out, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(actual_delete)));
    }

    if (insert_count > actual_delete) {
        const delta = insert_count - actual_delete;
        // Grow upfront with the new items slice so OOM leaves `a` untouched.
        try rt.heap.appendElements(a, insert_items[0..delta]);
        var i: usize = len;
        while (i > actual_start + actual_delete) {
            i -= 1;
            rt.heap.storeElement(a, i + delta, a.kind.array.items[i]);
        }
    } else if (insert_count < actual_delete) {
        const tail_start = actual_start + actual_delete;
        for (tail_start..len) |i| {
            rt.heap.storeElement(a, i - actual_delete + insert_count, a.kind.array.items[i]);
        }
        rt.heap.shrinkElements(a, len - actual_delete + insert_count);
    }

    for (insert_items, 0..) |v, j| {
        rt.heap.storeElement(a, actual_start + j, v);
    }
    return out;
}

fn arraySort(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "sort");
    const cb: ?Value = if (args.len >= 1 and !args[0].isUndefined()) try common.requireCallable(rt, args[0]) else null;
    const len = a.kind.array.items.len;
    if (len <= 1) return this;
    try checkArrayMutate(rt, a, .{ .write_elements = true });

    const snap = try rt.heap.newArray(null);
    const tmp = try rt.heap.newArray(null);
    var root_buf = [_]Value{ this, cb orelse .undefined, Value.fromObject(snap), Value.fromObject(tmp), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var undef_count: usize = 0;
    for (a.kind.array.items) |v| {
        if (v.isHole()) continue;
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

    // Write back to `a` only after all comparisons succeed, handling comparator mutations safely.
    const cur_len = a.kind.array.items.len;
    const write_len = @min(len, cur_len);
    for (0..write_len) |i| {
        const v: Value = if (i < defined_count) snap.kind.array.items[i] else if (i < defined_count + undef_count) .undefined else .hole;
        rt.heap.storeElement(a, i, v);
    }
    if (cur_len < len) {
        for (cur_len..len) |i| {
            const v: Value = if (i < defined_count) snap.kind.array.items[i] else if (i < defined_count + undef_count) .undefined else .hole;
            try rt.heap.appendElement(a, v);
        }
    }
    return this;
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
            if (idx >= a.kind.array.items.len) continue;
            const raw = a.kind.array.items[idx];
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

fn flattenIntoArray(rt: *Runtime, out: *Object, src: *Object, depth_left: f64, rec_depth: u16) Error!void {
    if (rec_depth >= rt.limits.max_nesting_depth) return rt.limit(.nesting_depth);
    const items = src.kind.array.items;
    for (items) |elem| {
        if (depth_left > 0 and elem.isObject() and elem.asObject().kind == .array) {
            try flattenIntoArray(rt, out, elem.asObject(), depth_left - 1, rec_depth + 1);
        } else {
            try rt.heap.appendElement(out, elem);
        }
    }
}

fn arrayFlat(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "flat");
    const depth = if (args.len >= 1 and !args[0].isUndefined()) try common.toIntegerOrInfinity(rt, args[0]) else 1.0;
    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ this, Value.fromObject(out) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    try flattenIntoArray(rt, out, a, depth, 0);
    return Value.fromObject(out);
}

fn arrayFlatMap(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "flatMap");
    const cb = try common.requireCallable(rt, common.arg(args, 0));
    const this_arg = common.arg(args, 1);
    const len = a.kind.array.items.len;
    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ this, cb, this_arg, Value.fromObject(out), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (0..len) |i| {
        const elem = if (i < a.kind.array.items.len) a.kind.array.items[i] else Value.undefined;
        const mapped = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), this });
        root_buf[4] = mapped;
        if (mapped.isObject() and mapped.asObject().kind == .array) {
            try rt.heap.appendElements(out, mapped.asObject().kind.array.items);
        } else {
            try rt.heap.appendElement(out, mapped);
        }
        root_buf[4] = .undefined;
    }
    return Value.fromObject(out);
}

fn arrayCopyWithin(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const to = common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 0)), len);
        const from = common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 1)), len);
        const final_idx = if (common.arg(args, 2).isUndefined()) len else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 2)), len);
        const count = if (final_idx > from) @min(final_idx - from, len - to) else 0;
        if (count > 0) {
            try checkArrayMutate(rt, a, .{ .write_elements = true });
            if (from != to) {
                if (from < to and to < from + count) {
                    var i: usize = count;
                    while (i > 0) {
                        i -= 1;
                        rt.heap.storeElement(a, to + i, a.kind.array.items[from + i]);
                    }
                } else {
                    for (0..count) |i| {
                        rt.heap.storeElement(a, to + i, a.kind.array.items[from + i]);
                    }
                }
            }
        }
        return o_val;
    }
    var root_buf = [_]Value{ o_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const to = common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 0)), len);
    const from = common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 1)), len);
    const final_idx = if (common.arg(args, 2).isUndefined()) len else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 2)), len);
    const count = if (final_idx > from) @min(final_idx - from, len - to) else 0;
    if (count > 0 and from != to) {
        const back = from < to and to < from + count;
        for (0..count) |step| {
            const offset = if (back) count - 1 - step else step;
            const from_k: object.Key = .{ .index = @intCast(from + offset) };
            const to_k: object.Key = .{ .index = @intCast(to + offset) };
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
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ o_val, Value.fromObject(out), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        var i: usize = a.kind.array.items.len;
        while (i > 0) {
            i -= 1;
            const raw = a.kind.array.items[i];
            const elem = if (raw.isHole()) try object.get(rt, o_val, .{ .index = @intCast(i) }) else raw;
            try rt.heap.appendElement(out, elem);
        }
        return Value.fromObject(out);
    }
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    var i: usize = @intFromFloat(len_f);
    while (i > 0) {
        i -= 1;
        root_buf[2] = try object.get(rt, o_val, .{ .index = @intCast(i) });
        try rt.heap.appendElement(out, root_buf[2]);
        root_buf[2] = .undefined;
    }
    return Value.fromObject(out);
}

fn arrayToSorted(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "toSorted");
    const cb: ?Value = if (args.len >= 1 and !args[0].isUndefined()) try common.requireCallable(rt, args[0]) else null;
    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    const len = a.kind.array.items.len;
    if (len == 0) return Value.fromObject(out);

    const snap = try rt.heap.newArray(null);
    const tmp = try rt.heap.newArray(null);
    var root_buf = [_]Value{ this, cb orelse .undefined, Value.fromObject(out), Value.fromObject(snap), Value.fromObject(tmp), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (a.kind.array.items) |v| {
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
    var root_buf = [_]Value{ this, Value.fromObject(out) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    try rt.heap.appendElements(out, a.kind.array.items[0..actual_start]);
    if (insert_items.len > 0) try rt.heap.appendElements(out, insert_items);
    try rt.heap.appendElements(out, a.kind.array.items[actual_start + actual_delete .. len]);
    return Value.fromObject(out);
}

fn arrayWith(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try common.toObjectReceiver(rt, this);
    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    const val = common.arg(args, 1);
    var root_buf = [_]Value{ o_val, val, Value.fromObject(out), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const rel = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
        const actual_f = if (rel < 0) @as(f64, @floatFromInt(len)) + rel else rel;
        if (!std.math.isFinite(actual_f) or actual_f < 0 or actual_f >= @as(f64, @floatFromInt(len))) {
            return rt.throw(.RangeError, &.{.{ .ascii = "Invalid index" }});
        }
        const actual_idx: usize = @intFromFloat(actual_f);
        try rt.heap.appendElements(out, a.kind.array.items);
        rt.heap.storeElement(out, actual_idx, val);
        return Value.fromObject(out);
    }
    const len_f = try common.toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const rel = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
    const actual_f = if (rel < 0) len_f + rel else rel;
    if (!std.math.isFinite(actual_f) or actual_f < 0 or actual_f >= len_f) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Invalid index" }});
    }
    const actual_idx: usize = @intFromFloat(actual_f);
    const len: usize = @intFromFloat(len_f);
    for (0..len) |i| {
        if (i == actual_idx) {
            try rt.heap.appendElement(out, val);
        } else {
            root_buf[3] = try object.get(rt, o_val, .{ .index = @intCast(i) });
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
        const elem = try object.get(rt, items, .{ .index = @intCast(k) });
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
        const iter = try iterator.getIteratorWithMethod(rt, items, async_fn);
        iter_val = Value.fromObject(iter);
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
    const out_val: Value = if (custom_ctor)
        (if (next_method.isUndefined()) try common.constructValue(rt, this, &.{limit_val}) else try common.constructValue(rt, this, &.{}))
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

fn arrayFromAsyncCloseOnErr(rt: *Runtime, env: *Object, reason: Value) Error!void {
    const res_p = env.kind.array.items[0].asObject();
    const next_method = env.kind.array.items[5];
    if (!next_method.isUndefined()) {
        const iter = env.kind.array.items[4];
        if (iter.isObject()) {
            const is_async = env.kind.array.items[8].asBool();
            if (!is_async) {
                iterator.iteratorClose(rt, iter.asObject(), true) catch {};
            } else {
                const ret_m = object.getMethod(rt, iter, try object.named(rt, "return")) catch null;
                if (ret_m) |rm| {
                    _ = rt.callCallable(rm, iter, &.{}) catch {};
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

    if (!next_method.isUndefined()) {
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
