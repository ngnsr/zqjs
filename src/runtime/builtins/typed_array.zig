//! ArrayBuffer, DataView, and TypedArray built-ins.

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
const bigint = @import("../bigint.zig");
const names = @import("../builtin_names.zig");
const builtins = @import("../builtins.zig");
const common = @import("common.zig");
const array_builtins = @import("array.zig");
const function_error = @import("function_error.zig");
const proxy_reflect = @import("proxy_reflect.zig");

pub fn viewsRealm(rt: *Runtime) Error!*const builtins.ViewsRealm {
    _ = try builtins.realm(rt);
    const r = &rt.realm.?;
    if (r.views) |*v| return v;
    const h = &rt.heap;
    var v: builtins.ViewsRealm = .{
        .array_buffer_prototype = try common.builtin(h, r.object_prototype, .array_buffer_prototype),
        .array_buffer_namespace = try common.builtin(h, null, .array_buffer_constructor),
        .data_view_prototype = try common.builtin(h, r.object_prototype, .data_view_prototype),
        .data_view_namespace = try common.builtin(h, null, .data_view_constructor),
        .typed_array_prototype = try common.builtin(h, r.object_prototype, .typed_array_prototype),
        .typed_array_namespace = try common.builtin(h, null, .typed_array_constructor),
        .typed_array_prototypes = undefined,
        .typed_array_namespaces = undefined,
    };
    const ta_proto_builtins = [_]names.Builtin{
        .int8_array_prototype,
        .uint8_array_prototype,
        .uint8_clamped_array_prototype,
        .int16_array_prototype,
        .uint16_array_prototype,
        .int32_array_prototype,
        .uint32_array_prototype,
        .float32_array_prototype,
        .float64_array_prototype,
        .bigint64_array_prototype,
        .biguint64_array_prototype,
    };
    const ta_ctor_builtins = [_]names.Builtin{
        .int8_array_constructor,
        .uint8_array_constructor,
        .uint8_clamped_array_constructor,
        .int16_array_constructor,
        .uint16_array_constructor,
        .int32_array_constructor,
        .uint32_array_constructor,
        .float32_array_constructor,
        .float64_array_constructor,
        .bigint64_array_constructor,
        .biguint64_array_constructor,
    };
    for (0..11) |i| {
        v.typed_array_prototypes[i] = try common.builtin(h, v.typed_array_prototype, ta_proto_builtins[i]);
        v.typed_array_namespaces[i] = try common.builtin(h, null, ta_ctor_builtins[i]);
    }
    try initArrayBufferAndViews(rt, r, &v);
    r.views = v;
    return &r.views.?;
}

fn initArrayBufferAndViews(rt: *Runtime, r: *const builtins.Realm, v: *builtins.ViewsRealm) Error!void {
    // ArrayBuffer
    try rt.heap.defineProperty(v.array_buffer_namespace, try rt.heap.internAscii("prototype"), .{
        .value = Value.fromObject(v.array_buffer_prototype),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try common.method(rt, v.array_buffer_namespace, "isView", &ab_is_view);
    try object.defineAccessor(rt, Value.fromObject(v.array_buffer_namespace), .{ .symbol = r.sym_species }, Value.fromNative(&common.species_getter), false, false);
    try common.constant(rt, v.array_buffer_prototype, "constructor", Value.fromNative(&builtins.array_buffer_global));
    try object.defineAccessor(rt, Value.fromObject(v.array_buffer_prototype), try object.named(rt, "byteLength"), Value.fromNative(&ab_byte_length_getter), false, false);
    try common.method(rt, v.array_buffer_prototype, "slice", &ab_slice);
    try common.defineToStringTag(rt, v.array_buffer_prototype, r.sym_to_string_tag, "ArrayBuffer");

    // DataView
    try rt.heap.defineProperty(v.data_view_namespace, try rt.heap.internAscii("prototype"), .{
        .value = Value.fromObject(v.data_view_prototype),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try common.constant(rt, v.data_view_prototype, "constructor", Value.fromNative(&builtins.data_view_global));
    try object.defineAccessor(rt, Value.fromObject(v.data_view_prototype), try object.named(rt, "buffer"), Value.fromNative(&dv_buffer_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(v.data_view_prototype), try object.named(rt, "byteLength"), Value.fromNative(&dv_byte_length_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(v.data_view_prototype), try object.named(rt, "byteOffset"), Value.fromNative(&dv_byte_offset_getter), false, false);
    try common.method(rt, v.data_view_prototype, "getInt8", &dv_get_int8);
    try common.method(rt, v.data_view_prototype, "setInt8", &dv_set_int8);
    try common.method(rt, v.data_view_prototype, "getUint8", &dv_get_uint8);
    try common.method(rt, v.data_view_prototype, "setUint8", &dv_set_uint8);
    try common.method(rt, v.data_view_prototype, "getInt16", &dv_get_int16);
    try common.method(rt, v.data_view_prototype, "setInt16", &dv_set_int16);
    try common.method(rt, v.data_view_prototype, "getUint16", &dv_get_uint16);
    try common.method(rt, v.data_view_prototype, "setUint16", &dv_set_uint16);
    try common.method(rt, v.data_view_prototype, "getInt32", &dv_get_int32);
    try common.method(rt, v.data_view_prototype, "setInt32", &dv_set_int32);
    try common.method(rt, v.data_view_prototype, "getUint32", &dv_get_uint32);
    try common.method(rt, v.data_view_prototype, "setUint32", &dv_set_uint32);
    try common.method(rt, v.data_view_prototype, "getFloat16", &dv_get_float16);
    try common.method(rt, v.data_view_prototype, "setFloat16", &dv_set_float16);
    try common.method(rt, v.data_view_prototype, "getFloat32", &dv_get_float32);
    try common.method(rt, v.data_view_prototype, "setFloat32", &dv_set_float32);
    try common.method(rt, v.data_view_prototype, "getFloat64", &dv_get_float64);
    try common.method(rt, v.data_view_prototype, "setFloat64", &dv_set_float64);
    try common.method(rt, v.data_view_prototype, "getBigInt64", &dv_get_bigint64);
    try common.method(rt, v.data_view_prototype, "setBigInt64", &dv_set_bigint64);
    try common.method(rt, v.data_view_prototype, "getBigUint64", &dv_get_biguint64);
    try common.method(rt, v.data_view_prototype, "setBigUint64", &dv_set_biguint64);
    try common.defineToStringTag(rt, v.data_view_prototype, r.sym_to_string_tag, "DataView");

    // %TypedArray%
    try rt.heap.defineProperty(v.typed_array_namespace, try rt.heap.internAscii("prototype"), .{
        .value = Value.fromObject(v.typed_array_prototype),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try common.method(rt, v.typed_array_namespace, "from", &ta_from);
    try common.method(rt, v.typed_array_namespace, "of", &ta_of);
    try object.defineAccessor(rt, Value.fromObject(v.typed_array_namespace), .{ .symbol = r.sym_species }, Value.fromNative(&common.species_getter), false, false);
    try common.constant(rt, v.typed_array_prototype, "constructor", Value.fromNative(&builtins.typed_array_global));
    try object.defineAccessor(rt, Value.fromObject(v.typed_array_prototype), try object.named(rt, "buffer"), Value.fromNative(&ta_buffer_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(v.typed_array_prototype), try object.named(rt, "byteLength"), Value.fromNative(&ta_byte_length_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(v.typed_array_prototype), try object.named(rt, "byteOffset"), Value.fromNative(&ta_byte_offset_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(v.typed_array_prototype), try object.named(rt, "length"), Value.fromNative(&ta_length_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(v.typed_array_prototype), .{ .symbol = r.sym_to_string_tag }, Value.fromNative(&ta_to_string_tag_getter), false, false);
    try common.method(rt, v.typed_array_prototype, "set", &ta_set);
    try common.method(rt, v.typed_array_prototype, "subarray", &ta_subarray);
    try common.method(rt, v.typed_array_prototype, "slice", &ta_slice);
    try common.method(rt, v.typed_array_prototype, "fill", &ta_fill);
    try common.method(rt, v.typed_array_prototype, "copyWithin", &ta_copy_within);
    try common.method(rt, v.typed_array_prototype, "reverse", &ta_reverse);
    try common.method(rt, v.typed_array_prototype, "sort", &ta_sort);
    try common.method(rt, v.typed_array_prototype, "toReversed", &ta_to_reversed);
    try common.method(rt, v.typed_array_prototype, "toSorted", &ta_to_sorted);
    try common.method(rt, v.typed_array_prototype, "with", &ta_with);
    try common.method(rt, v.typed_array_prototype, "indexOf", &ta_index_of);
    try common.method(rt, v.typed_array_prototype, "lastIndexOf", &ta_last_index_of);
    try common.method(rt, v.typed_array_prototype, "includes", &ta_includes);
    try common.method(rt, v.typed_array_prototype, "find", &ta_find);
    try common.method(rt, v.typed_array_prototype, "findIndex", &ta_find_index);
    try common.method(rt, v.typed_array_prototype, "findLast", &ta_find_last);
    try common.method(rt, v.typed_array_prototype, "findLastIndex", &ta_find_last_index);
    try common.method(rt, v.typed_array_prototype, "every", &ta_every);
    try common.method(rt, v.typed_array_prototype, "some", &ta_some);
    try common.method(rt, v.typed_array_prototype, "forEach", &ta_for_each);
    try common.method(rt, v.typed_array_prototype, "map", &ta_map);
    try common.method(rt, v.typed_array_prototype, "filter", &ta_filter);
    try common.method(rt, v.typed_array_prototype, "reduce", &ta_reduce);
    try common.method(rt, v.typed_array_prototype, "reduceRight", &ta_reduce_right);
    try common.method(rt, v.typed_array_prototype, "at", &ta_at);
    try common.method(rt, v.typed_array_prototype, "join", &ta_join);
    try common.method(rt, v.typed_array_prototype, "toString", &array_builtins.array_to_string);
    try common.method(rt, v.typed_array_prototype, "toLocaleString", &ta_to_locale_string);
    try common.method(rt, v.typed_array_prototype, "keys", &ta_keys);
    try common.method(rt, v.typed_array_prototype, "values", &ta_values);
    try common.method(rt, v.typed_array_prototype, "entries", &ta_entries);
    try common.symbolMethod(rt, v.typed_array_prototype, r.sym_iterator, &ta_values);

    // 11 concrete TypedArray constructors & prototypes
    const bpe_atom = try rt.heap.internAscii("BYTES_PER_ELEMENT");
    const proto_atom = try rt.heap.internAscii("prototype");
    const ctor_atom = try rt.heap.internAscii("constructor");
    for (0..11) |i| {
        const kind: heap_mod.TypedArrayKind = @fromBackingInt(@intCast(i));
        const bpe_val: Value = Value.fromNumber(@floatFromInt(kind.bytesPerElement()));
        const ns = v.typed_array_namespaces[i];
        const proto = v.typed_array_prototypes[i];
        try rt.heap.defineProperty(ns, proto_atom, .{
            .value = Value.fromObject(proto),
            .enumerable = false,
            .writable = false,
            .configurable = false,
        });
        try rt.heap.defineProperty(ns, bpe_atom, .{
            .value = bpe_val,
            .enumerable = false,
            .writable = false,
            .configurable = false,
        });
        try rt.heap.defineProperty(proto, ctor_atom, .{
            .value = Value.fromNative(&builtins.typed_array_ctors[i]),
            .enumerable = false,
            .writable = true,
            .configurable = true,
        });
        try rt.heap.defineProperty(proto, bpe_atom, .{
            .value = bpe_val,
            .enumerable = false,
            .writable = false,
            .configurable = false,
        });
    }

    // Uint8Array-only Base64 and Hex methods (ES2026)
    const uint8_idx = @backingInt(heap_mod.TypedArrayKind.uint8);
    const uint8_ns = v.typed_array_namespaces[uint8_idx];
    const uint8_proto = v.typed_array_prototypes[uint8_idx];
    try common.method(rt, uint8_ns, "fromBase64", &u8_from_base64);
    try common.method(rt, uint8_ns, "fromHex", &u8_from_hex);
    try common.method(rt, uint8_proto, "toBase64", &u8_to_base64);
    try common.method(rt, uint8_proto, "toHex", &u8_to_hex);
    try common.method(rt, uint8_proto, "setFromBase64", &u8_set_from_base64);
    try common.method(rt, uint8_proto, "setFromHex", &u8_set_from_hex);
}

fn toIndex(rt: *Runtime, v: Value) Error!usize {
    if (v.isUndefined()) return 0;
    const n = try common.toIntegerOrInfinity(rt, v);
    if (n < 0 or n > 9007199254740991.0) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Invalid array buffer length" }});
    }
    const max_usize_f: f64 = @floatFromInt(std.math.maxInt(usize));
    if (n > max_usize_f) return rt.heap.exceeded(.heap_bytes);
    return @intFromFloat(n);
}

fn relativeIndex(rt: *Runtime, v: Value, len: usize, default_val: usize) Error!usize {
    if (v.isUndefined()) return default_val;
    const n = try common.toIntegerOrInfinity(rt, v);
    const len_f: f64 = @floatFromInt(len);
    if (n < 0) {
        const res = len_f + n;
        return if (res <= 0) 0 else @intFromFloat(res);
    }
    return if (n >= len_f) len else @intFromFloat(n);
}

// ---- ArrayBuffer

pub fn arrayBufferWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor ArrayBuffer requires 'new'" }});
}

pub fn arrayBufferConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const byte_len = try toIndex(rt, common.arg(args, 0));
    const vr = try viewsRealm(rt);
    return Value.fromObject(try rt.heap.newArrayBuffer(vr.array_buffer_prototype, byte_len));
}

const ab_is_view: Native = .{ .name = "isView", .length = 1, .call = abIsView };

const ab_byte_length_getter: Native = .{ .name = "get byteLength", .call = abByteLengthGetter };

const ab_slice: Native = .{ .name = "slice", .length = 2, .call = abSlice };

fn abIsView(_: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = common.arg(args, 0);
    if (!v.isObject()) return Value.fromBool(false);
    return Value.fromBool(switch (v.asObject().kind) {
        .typed_array, .data_view => true,
        else => false,
    });
}

fn requireArrayBuffer(rt: *Runtime, v: Value) Error!*Object {
    if (!v.isObject() or v.asObject().kind != .array_buffer) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Method ArrayBuffer.prototype called on incompatible receiver" }});
    }
    return v.asObject();
}

fn abByteLengthGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireArrayBuffer(rt, this);
    const ab = o.kind.array_buffer;
    return Value.fromNumber(if (ab.detached) 0 else @floatFromInt(ab.data.len));
}

fn abSlice(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireArrayBuffer(rt, this);
    var root_buf = [_]Value{ this, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot slice a detached ArrayBuffer" }});
    const len = o.kind.array_buffer.data.len;
    const first = try relativeIndex(rt, common.arg(args, 0), len, 0);
    const final = try relativeIndex(rt, common.arg(args, 1), len, len);
    const new_len = if (final > first) final - first else 0;

    const ctor = try common.speciesConstructor(rt, this, Value.fromNative(&builtins.array_buffer_global));
    root_buf[1] = ctor;
    var new_ab: *Object = undefined;
    if (ctor.isNative() and ctor.asNative() == &builtins.array_buffer_global) {
        const vr = try viewsRealm(rt);
        new_ab = try rt.heap.newArrayBuffer(vr.array_buffer_prototype, new_len);
    } else {
        const new_val = try common.constructValue(rt, ctor, &.{Value.fromNumber(@floatFromInt(new_len))});
        root_buf[2] = new_val;
        if (!new_val.isObject() or new_val.asObject().kind != .array_buffer) {
            return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer species constructor did not return an ArrayBuffer" }});
        }
        new_ab = new_val.asObject();
        if (new_ab.kind.array_buffer.detached) {
            return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer species constructor returned a detached ArrayBuffer" }});
        }
        if (new_ab == o) {
            return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer species constructor returned the same ArrayBuffer" }});
        }
        if (new_ab.kind.array_buffer.data.len < new_len) {
            return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer species constructor returned a buffer that is too small" }});
        }
    }
    if (o.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot slice a detached ArrayBuffer" }});
    if (new_len > 0) {
        @memcpy(new_ab.kind.array_buffer.data[0..new_len], o.kind.array_buffer.data[first .. first + new_len]);
    }
    return Value.fromObject(new_ab);
}

// ---- DataView

pub fn dataViewWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor DataView requires 'new'" }});
}

pub fn dataViewConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const buf_val = common.arg(args, 0);
    if (!buf_val.isObject() or buf_val.asObject().kind != .array_buffer) {
        return rt.throw(.TypeError, &.{.{ .ascii = "First argument to DataView constructor must be an ArrayBuffer" }});
    }
    var root_buf = [_]Value{buf_val};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const offset = try toIndex(rt, common.arg(args, 1));
    const ab = buf_val.asObject().kind.array_buffer;
    if (ab.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot construct DataView on a detached ArrayBuffer" }});
    if (offset > ab.data.len) return rt.throw(.RangeError, &.{.{ .ascii = "Start offset is outside the bounds of the buffer" }});
    const view_byte_len: usize = if (common.arg(args, 2).isUndefined()) blk: {
        if (buf_val.asObject().kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot construct DataView on a detached ArrayBuffer" }});
        break :blk buf_val.asObject().kind.array_buffer.data.len - offset;
    } else blk: {
        const l = try toIndex(rt, common.arg(args, 2));
        if (buf_val.asObject().kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot construct DataView on a detached ArrayBuffer" }});
        const cur_len = buf_val.asObject().kind.array_buffer.data.len;
        const end = std.math.add(usize, offset, l) catch return rt.throw(.RangeError, &.{.{ .ascii = "Invalid DataView length" }});
        if (end > cur_len) return rt.throw(.RangeError, &.{.{ .ascii = "Invalid DataView length" }});
        break :blk l;
    };
    const vr = try viewsRealm(rt);
    return Value.fromObject(try rt.heap.newDataView(vr.data_view_prototype, buf_val.asObject(), offset, view_byte_len));
}

fn requireDataView(rt: *Runtime, this: Value) Error!*Object {
    if (!this.isObject() or this.asObject().kind != .data_view) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Method DataView.prototype called on incompatible receiver" }});
    }
    return this.asObject();
}

const dv_buffer_getter: Native = .{ .name = "get buffer", .call = dvBufferGetter };

const dv_byte_length_getter: Native = .{ .name = "get byteLength", .call = dvByteLengthGetter };

const dv_byte_offset_getter: Native = .{ .name = "get byteOffset", .call = dvByteOffsetGetter };

fn dvBufferGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDataView(rt, this);
    return Value.fromObject(o.kind.data_view.buffer);
}

fn dvByteLengthGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDataView(rt, this);
    const dv = o.kind.data_view;
    if (dv.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer is detached" }});
    return Value.fromNumber(@floatFromInt(dv.byte_length));
}

fn dvByteOffsetGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDataView(rt, this);
    const dv = o.kind.data_view;
    if (dv.buffer.kind.array_buffer.detached) return Value.fromNumber(0);
    return Value.fromNumber(@floatFromInt(dv.byte_offset));
}

const DataViewElem = enum { int8, uint8, int16, uint16, int32, uint32, float16, float32, float64, bigint64, biguint64 };

fn dvElemSize(comptime elem: DataViewElem) usize {
    return switch (elem) {
        .int8, .uint8 => 1,
        .int16, .uint16, .float16 => 2,
        .int32, .uint32, .float32 => 4,
        .float64, .bigint64, .biguint64 => 8,
    };
}

fn dvGet(comptime elem: DataViewElem, rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireDataView(rt, this);
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const get_idx = try toIndex(rt, common.arg(args, 0));
    const little = ops.toBoolean(common.arg(args, 1));
    const dv = o.kind.data_view;
    if (dv.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer is detached" }});
    const size = dvElemSize(elem);
    const end = std.math.add(usize, get_idx, size) catch return rt.throw(.RangeError, &.{.{ .ascii = "Offset is outside the bounds of the DataView" }});
    if (end > dv.byte_length) return rt.throw(.RangeError, &.{.{ .ascii = "Offset is outside the bounds of the DataView" }});
    const bytes = dv.buffer.kind.array_buffer.data[dv.byte_offset + get_idx ..];
    const endian: std.builtin.Endian = if (little) .little else .big;
    return switch (elem) {
        .bigint64 => Value.fromBigInt(try bigint.fromI64(rt, std.mem.readInt(i64, bytes[0..8], endian))),
        .biguint64 => Value.fromBigInt(try bigint.fromU64(rt, std.mem.readInt(u64, bytes[0..8], endian))),
        else => Value.fromNumber(switch (elem) {
            .int8 => @floatFromInt(@as(i8, @bitCast(bytes[0]))),
            .uint8 => @floatFromInt(bytes[0]),
            .int16 => @floatFromInt(std.mem.readInt(i16, bytes[0..2], endian)),
            .uint16 => @floatFromInt(std.mem.readInt(u16, bytes[0..2], endian)),
            .int32 => @floatFromInt(std.mem.readInt(i32, bytes[0..4], endian)),
            .uint32 => @floatFromInt(std.mem.readInt(u32, bytes[0..4], endian)),
            .float16 => @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, bytes[0..2], endian)))),
            .float32 => @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], endian)))),
            .float64 => @bitCast(std.mem.readInt(u64, bytes[0..8], endian)),
            .bigint64, .biguint64 => unreachable,
        }),
    };
}

fn dvSet(comptime elem: DataViewElem, rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireDataView(rt, this);
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const get_idx = try toIndex(rt, common.arg(args, 0));
    const is_bigint = (elem == .bigint64 or elem == .biguint64);
    const big_val = if (is_bigint) try ops.toBigInt(rt, common.arg(args, 1)) else undefined;
    const n = if (!is_bigint) try ops.toNumber(rt, common.arg(args, 1)) else 0.0;
    const little = ops.toBoolean(common.arg(args, 2));
    const dv = o.kind.data_view;
    if (dv.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer is detached" }});
    const size = dvElemSize(elem);
    const end = std.math.add(usize, get_idx, size) catch return rt.throw(.RangeError, &.{.{ .ascii = "Offset is outside the bounds of the DataView" }});
    if (end > dv.byte_length) return rt.throw(.RangeError, &.{.{ .ascii = "Offset is outside the bounds of the DataView" }});
    const bytes = dv.buffer.kind.array_buffer.data[dv.byte_offset + get_idx ..];
    const endian: std.builtin.Endian = if (little) .little else .big;
    switch (elem) {
        .int8 => bytes[0] = @bitCast(@as(i8, @truncate(ops.toInt32(n)))),
        .uint8 => bytes[0] = @truncate(ops.toUint32(n)),
        .int16 => std.mem.writeInt(i16, bytes[0..2], @truncate(ops.toInt32(n)), endian),
        .uint16 => std.mem.writeInt(u16, bytes[0..2], @truncate(ops.toUint32(n)), endian),
        .int32 => std.mem.writeInt(i32, bytes[0..4], ops.toInt32(n), endian),
        .uint32 => std.mem.writeInt(u32, bytes[0..4], ops.toUint32(n), endian),
        .float16 => {
            const f: f16 = @floatCast(n);
            std.mem.writeInt(u16, bytes[0..2], @bitCast(f), endian);
        },
        .float32 => {
            const f: f32 = @floatCast(n);
            std.mem.writeInt(u32, bytes[0..4], @bitCast(f), endian);
        },
        .float64 => std.mem.writeInt(u64, bytes[0..8], @bitCast(n), endian),
        .bigint64 => std.mem.writeInt(i64, bytes[0..8], bigint.toI64Wrapping(big_val), endian),
        .biguint64 => std.mem.writeInt(u64, bytes[0..8], bigint.toU64Wrapping(big_val), endian),
    }
    return .undefined;
}

const dv_get_int8: Native = .{ .name = "getInt8", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.int8, rt, t, a);
    }
}.f };

const dv_set_int8: Native = .{ .name = "setInt8", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.int8, rt, t, a);
    }
}.f };

const dv_get_uint8: Native = .{ .name = "getUint8", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.uint8, rt, t, a);
    }
}.f };

const dv_set_uint8: Native = .{ .name = "setUint8", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.uint8, rt, t, a);
    }
}.f };

const dv_get_int16: Native = .{ .name = "getInt16", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.int16, rt, t, a);
    }
}.f };

const dv_set_int16: Native = .{ .name = "setInt16", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.int16, rt, t, a);
    }
}.f };

const dv_get_uint16: Native = .{ .name = "getUint16", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.uint16, rt, t, a);
    }
}.f };

const dv_set_uint16: Native = .{ .name = "setUint16", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.uint16, rt, t, a);
    }
}.f };

const dv_get_int32: Native = .{ .name = "getInt32", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.int32, rt, t, a);
    }
}.f };

const dv_set_int32: Native = .{ .name = "setInt32", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.int32, rt, t, a);
    }
}.f };

const dv_get_uint32: Native = .{ .name = "getUint32", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.uint32, rt, t, a);
    }
}.f };

const dv_set_uint32: Native = .{ .name = "setUint32", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.uint32, rt, t, a);
    }
}.f };

const dv_get_float16: Native = .{ .name = "getFloat16", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.float16, rt, t, a);
    }
}.f };

const dv_set_float16: Native = .{ .name = "setFloat16", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.float16, rt, t, a);
    }
}.f };

const dv_get_float32: Native = .{ .name = "getFloat32", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.float32, rt, t, a);
    }
}.f };

const dv_set_float32: Native = .{ .name = "setFloat32", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.float32, rt, t, a);
    }
}.f };

const dv_get_float64: Native = .{ .name = "getFloat64", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.float64, rt, t, a);
    }
}.f };

const dv_set_float64: Native = .{ .name = "setFloat64", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.float64, rt, t, a);
    }
}.f };

const dv_get_bigint64: Native = .{ .name = "getBigInt64", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.bigint64, rt, t, a);
    }
}.f };

const dv_set_bigint64: Native = .{ .name = "setBigInt64", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.bigint64, rt, t, a);
    }
}.f };

const dv_get_biguint64: Native = .{ .name = "getBigUint64", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.biguint64, rt, t, a);
    }
}.f };

const dv_set_biguint64: Native = .{ .name = "setBigUint64", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.biguint64, rt, t, a);
    }
}.f };

// ---- %TypedArray% & Concrete Constructors

pub fn typedArrayAbstractCall(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Abstract class TypedArray not directly constructable" }});
}

pub fn typedArrayAbstractConstruct(rt: *Runtime, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Abstract class TypedArray not directly constructable" }});
}

pub fn typedArrayWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray constructor requires 'new'" }});
}

pub fn typedArrayConstructInt8(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .int8, args);
}

pub fn typedArrayConstructUint8(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .uint8, args);
}

pub fn typedArrayConstructUint8Clamped(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .uint8_clamped, args);
}

pub fn typedArrayConstructInt16(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .int16, args);
}

pub fn typedArrayConstructUint16(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .uint16, args);
}

pub fn typedArrayConstructInt32(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .int32, args);
}

pub fn typedArrayConstructUint32(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .uint32, args);
}

pub fn typedArrayConstructFloat32(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .float32, args);
}

pub fn typedArrayConstructFloat64(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .float64, args);
}

pub fn typedArrayConstructBigInt64(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .bigint64, args);
}

pub fn typedArrayConstructBigUint64(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .biguint64, args);
}

fn allocateTypedArray(rt: *Runtime, kind: heap_mod.TypedArrayKind, len: usize) Error!*Object {
    const vr = try viewsRealm(rt);
    const bpe = kind.bytesPerElement();
    const byte_len = std.math.mul(usize, len, bpe) catch return rt.throw(.RangeError, &.{.{ .ascii = "Invalid typed array length" }});
    const ab = try rt.heap.newArrayBuffer(vr.array_buffer_prototype, byte_len);
    var root_buf = [_]Value{Value.fromObject(ab)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    return rt.heap.newTypedArray(vr.typed_array_prototypes[@backingInt(kind)], ab, kind, 0, len);
}

fn collectIterableToArray(rt: *Runtime, source: Value, method_fn: Value) Error!*Object {
    const r = try builtins.realm(rt);
    const arr = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ source, method_fn, Value.fromObject(arr), .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const iter = try rt.callCallable(method_fn, source, &.{});
    if (!iter.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
    root_buf[3] = iter;
    const next_fn = try object.get(rt, iter, try object.named(rt, "next"));
    if (!next_fn.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator next is not a function" }});
    root_buf[4] = next_fn;

    const done_key = try object.named(rt, "done");
    root_buf[5] = Value.fromString(done_key.atom);
    const value_key = try object.named(rt, "value");
    root_buf[6] = Value.fromString(value_key.atom);
    while (true) {
        try rt.step();
        const step = try rt.callCallable(next_fn, iter, &.{});
        if (!step.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
        var step_buf = [_]Value{step};
        var step_roots: rt_mod.ValueRoots = .{ .values = &step_buf };
        try step_roots.register(rt);
        defer step_roots.unregister(rt);
        if (ops.toBoolean(try object.get(rt, step, done_key))) break;
        const val = try object.get(rt, step, value_key);
        try rt.heap.appendElement(arr, val);
    }
    return arr;
}

fn typedArrayConstructKind(rt: *Runtime, kind: heap_mod.TypedArrayKind, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const vr = try viewsRealm(rt);
    const proto = vr.typed_array_prototypes[@backingInt(kind)];
    if (args.len == 0) {
        return Value.fromObject(try allocateTypedArray(rt, kind, 0));
    }
    const arg0 = args[0];
    if (!arg0.isObjectLike()) {
        const len = try toIndex(rt, arg0);
        return Value.fromObject(try allocateTypedArray(rt, kind, len));
    }
    if (arg0.isObject()) switch (arg0.asObject().kind) {
        .typed_array => |src| {
            if (src.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Source TypedArray buffer is detached" }});
            if (src.kind.isBigInt() != kind.isBigInt()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "Cannot mix BigInt and other types, use explicit conversions" }});
            }
            var root_buf = [_]Value{arg0};
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);
            const dst = try allocateTypedArray(rt, kind, src.length);
            const dst_ta = dst.kind.typed_array;
            for (0..src.length) |i| {
                const v = try object.readTypedArrayElement(rt, src, i);
                try object.writeTypedArrayElement(rt, dst_ta, i, v);
            }
            return Value.fromObject(dst);
        },
        .array_buffer => {
            var root_buf = [_]Value{arg0};
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);
            const bpe = kind.bytesPerElement();
            const offset = try toIndex(rt, common.arg(args, 1));
            if (arg0.asObject().kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer is detached" }});
            if (offset % bpe != 0) {
                return rt.throw(.RangeError, &.{.{ .ascii = "Start offset of TypedArray should be a multiple of element size" }});
            }
            const new_len: usize = if (common.arg(args, 2).isUndefined()) blk: {
                if (arg0.asObject().kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer is detached" }});
                const buf_len = arg0.asObject().kind.array_buffer.data.len;
                if (buf_len % bpe != 0 or offset > buf_len) {
                    return rt.throw(.RangeError, &.{.{ .ascii = "Byte length of TypedArray should be a multiple of element size" }});
                }
                break :blk (buf_len - offset) / bpe;
            } else blk: {
                const l = try toIndex(rt, common.arg(args, 2));
                if (arg0.asObject().kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer is detached" }});
                const buf_len = arg0.asObject().kind.array_buffer.data.len;
                const needed = std.math.mul(usize, l, bpe) catch return rt.throw(.RangeError, &.{.{ .ascii = "Invalid typed array length" }});
                const end = std.math.add(usize, offset, needed) catch return rt.throw(.RangeError, &.{.{ .ascii = "Invalid typed array length" }});
                if (end > buf_len) return rt.throw(.RangeError, &.{.{ .ascii = "Invalid typed array length" }});
                break :blk l;
            };
            if (arg0.asObject().kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer is detached" }});
            return Value.fromObject(try rt.heap.newTypedArray(proto, arg0.asObject(), kind, offset, new_len));
        },
        else => {},
    };
    var root_buf = [_]Value{ arg0, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const iter_prop = try object.get(rt, arg0, .{ .symbol = r.sym_iterator });
    if (!iter_prop.isUndefined() and !iter_prop.isNull()) {
        if (!iter_prop.isFunction()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Iterator is not a function" }});
        }
        const arr = try collectIterableToArray(rt, arg0, iter_prop);
        root_buf[1] = Value.fromObject(arr);
        const len = arr.kind.array.items.len;
        const dst = try allocateTypedArray(rt, kind, len);
        root_buf[0] = Value.fromObject(dst);
        for (0..len) |i| {
            try object.writeTypedArrayElement(rt, dst.kind.typed_array, i, arr.kind.array.items[i]);
        }
        return Value.fromObject(dst);
    }
    const len_f = try common.toLength(rt, try object.get(rt, arg0, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const dst = try allocateTypedArray(rt, kind, len);
    root_buf[1] = Value.fromObject(dst);
    for (0..len) |i| {
        const v = try object.get(rt, arg0, .{ .index = @intCast(i) });
        try object.writeTypedArrayElement(rt, dst.kind.typed_array, i, v);
    }
    return Value.fromObject(dst);
}

fn constructorTypedArrayKind(v: Value) ?heap_mod.TypedArrayKind {
    if (!v.isNative()) return null;
    for (&builtins.typed_array_ctors, 0..) |*ctor, i| {
        if (v.asNative() == ctor) return @fromBackingInt(@intCast(i));
    }
    return null;
}

const ta_from: Native = .{ .name = "from", .length = 1, .call = taFrom };

const ta_of: Native = .{ .name = "of", .length = 0, .call = taOf };

fn typedArrayCreateLen(rt: *Runtime, ctor: Value, len: usize) Error!*Object {
    if (constructorTypedArrayKind(ctor)) |kind| {
        return allocateTypedArray(rt, kind, len);
    }
    const res = try proxy_reflect.constructWithNewTarget(rt, ctor, &.{Value.fromNumber(@floatFromInt(len))}, ctor);
    if (!res.isObject() or res.asObject().kind != .typed_array) {
        return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray constructor did not return a TypedArray" }});
    }
    if (res.asObject().kind.typed_array.length < len) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Derived TypedArray constructor created an array that was too small" }});
    }
    return res.asObject();
}

fn taFrom(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!function_error.isConstructor(this)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray.from requires a constructor" }});
    }
    const source = common.arg(args, 0);
    if (source.isUndefined() or source.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const map_fn = common.arg(args, 1);
    const has_map = !map_fn.isUndefined();
    if (has_map and !map_fn.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray.from mapFn is not a function" }});
    }
    const this_arg = common.arg(args, 2);
    const r = try builtins.realm(rt);
    var root_buf = [_]Value{ this, source, map_fn, this_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (try object.getMethod(rt, source, .{ .symbol = r.sym_iterator })) |iter_fn| {
        const arr = try collectIterableToArray(rt, source, iter_fn);
        root_buf[4] = Value.fromObject(arr);
        const len = arr.kind.array.items.len;
        const dst = try typedArrayCreateLen(rt, this, len);
        root_buf[5] = Value.fromObject(dst);
        for (0..len) |i| {
            const elem = arr.kind.array.items[i];
            const val = if (has_map)
                try rt.callCallable(map_fn, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)) })
            else
                elem;
            _ = try object.setWithReceiver(rt, Value.fromObject(dst), .{ .index = @intCast(i) }, val, Value.fromObject(dst), true);
        }
        return Value.fromObject(dst);
    }

    const len_f = try common.toLength(rt, try object.get(rt, source, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const dst = try typedArrayCreateLen(rt, this, len);
    root_buf[4] = Value.fromObject(dst);
    for (0..len) |i| {
        const elem = try object.get(rt, source, .{ .index = @intCast(i) });
        const val = if (has_map)
            try rt.callCallable(map_fn, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)) })
        else
            elem;
        _ = try object.setWithReceiver(rt, Value.fromObject(dst), .{ .index = @intCast(i) }, val, Value.fromObject(dst), true);
    }
    return Value.fromObject(dst);
}

fn taOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!function_error.isConstructor(this)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray.of requires a constructor" }});
    }
    const dst = if (constructorTypedArrayKind(this)) |kind| blk: {
        break :blk try allocateTypedArray(rt, kind, args.len);
    } else blk: {
        const res = try proxy_reflect.constructWithNewTarget(rt, this, &.{Value.fromNumber(@floatFromInt(args.len))}, this);
        const obj = try requireLiveTypedArray(rt, res);
        if (obj.kind.typed_array.length < args.len) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Derived TypedArray constructor created an array that was too small" }});
        }
        break :blk obj;
    };
    var root_buf = [_]Value{Value.fromObject(dst)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    for (args, 0..) |a, i| {
        try object.writeTypedArrayElement(rt, dst.kind.typed_array, i, a);
    }
    return Value.fromObject(dst);
}

fn requireTypedArray(rt: *Runtime, this: Value) Error!*Object {
    if (!this.isObject() or this.asObject().kind != .typed_array) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Method TypedArray.prototype called on incompatible receiver" }});
    }
    return this.asObject();
}

fn requireLiveTypedArray(rt: *Runtime, this: Value) Error!*Object {
    const o = try requireTypedArray(rt, this);
    if (o.kind.typed_array.buffer.kind.array_buffer.detached) {
        return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
    }
    return o;
}

const ta_buffer_getter: Native = .{ .name = "get buffer", .call = taBufferGetter };

const ta_byte_length_getter: Native = .{ .name = "get byteLength", .call = taByteLengthGetter };

const ta_byte_offset_getter: Native = .{ .name = "get byteOffset", .call = taByteOffsetGetter };

const ta_length_getter: Native = .{ .name = "get length", .call = taLengthGetter };

const ta_to_string_tag_getter: Native = .{ .name = "get [Symbol.toStringTag]", .call = taToStringTagGetter };

fn taBufferGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireTypedArray(rt, this);
    return Value.fromObject(o.kind.typed_array.buffer);
}

fn taByteLengthGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireTypedArray(rt, this);
    const ta = o.kind.typed_array;
    if (ta.buffer.kind.array_buffer.detached) return Value.fromNumber(0);
    return Value.fromNumber(@floatFromInt(ta.length * ta.kind.bytesPerElement()));
}

fn taByteOffsetGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireTypedArray(rt, this);
    const ta = o.kind.typed_array;
    if (ta.buffer.kind.array_buffer.detached) return Value.fromNumber(0);
    return Value.fromNumber(@floatFromInt(ta.byte_offset));
}

fn taLengthGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireTypedArray(rt, this);
    const ta = o.kind.typed_array;
    if (ta.buffer.kind.array_buffer.detached) return Value.fromNumber(0);
    return Value.fromNumber(@floatFromInt(ta.length));
}

fn taToStringTagGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().kind != .typed_array) return .undefined;
    return Value.fromString(try rt.heap.ascii(this.asObject().kind.typed_array.kind.name()));
}

const ta_set: Native = .{ .name = "set", .length = 1, .call = taSet };

const ta_subarray: Native = .{ .name = "subarray", .length = 2, .call = taSubarray };

const ta_slice: Native = .{ .name = "slice", .length = 2, .call = taSlice };

const ta_fill: Native = .{ .name = "fill", .length = 1, .call = taFill };

const ta_copy_within: Native = .{ .name = "copyWithin", .length = 2, .call = taCopyWithin };

const ta_reverse: Native = .{ .name = "reverse", .length = 0, .call = taReverse };

const ta_sort: Native = .{ .name = "sort", .length = 1, .call = taSort };

const ta_to_reversed: Native = .{ .name = "toReversed", .length = 0, .call = taToReversed };

const ta_to_sorted: Native = .{ .name = "toSorted", .length = 1, .call = taToSorted };

const ta_with: Native = .{ .name = "with", .length = 2, .call = taWith };

const ta_index_of: Native = .{ .name = "indexOf", .length = 1, .call = taIndexOf };

const ta_last_index_of: Native = .{ .name = "lastIndexOf", .length = 1, .call = taLastIndexOf };

const ta_includes: Native = .{ .name = "includes", .length = 1, .call = taIncludes };

const ta_find: Native = .{ .name = "find", .length = 1, .call = taFind };

const ta_find_index: Native = .{ .name = "findIndex", .length = 1, .call = taFindIndex };

const ta_find_last: Native = .{ .name = "findLast", .length = 1, .call = taFindLast };

const ta_find_last_index: Native = .{ .name = "findLastIndex", .length = 1, .call = taFindLastIndex };

const ta_every: Native = .{ .name = "every", .length = 1, .call = taEvery };

const ta_some: Native = .{ .name = "some", .length = 1, .call = taSome };

const ta_for_each: Native = .{ .name = "forEach", .length = 1, .call = taForEach };

const ta_map: Native = .{ .name = "map", .length = 1, .call = taMap };

const ta_filter: Native = .{ .name = "filter", .length = 1, .call = taFilter };

const ta_reduce: Native = .{ .name = "reduce", .length = 1, .call = taReduce };

const ta_reduce_right: Native = .{ .name = "reduceRight", .length = 1, .call = taReduceRight };

const ta_at: Native = .{ .name = "at", .length = 1, .call = taAt };

const ta_join: Native = .{ .name = "join", .length = 1, .call = taJoin };

const ta_to_locale_string: Native = .{ .name = "toLocaleString", .length = 0, .call = taToLocaleString };

const ta_keys: Native = .{ .name = "keys", .length = 0, .call = taKeys };

const ta_values: Native = .{ .name = "values", .length = 0, .call = taValues };

const ta_entries: Native = .{ .name = "entries", .length = 0, .call = taEntries };

fn taSet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const dst = o.kind.typed_array;
    const src_val = common.arg(args, 0);
    var root_buf = [_]Value{ this, src_val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const target_off_f = if (args.len > 1) try common.toIntegerOrInfinity(rt, common.arg(args, 1)) else 0.0;
    if (target_off_f < 0.0) return rt.throw(.RangeError, &.{.{ .ascii = "offset is out of bounds" }});
    if (dst.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});

    if (src_val.isObject() and src_val.asObject().kind == .typed_array) {
        const src = src_val.asObject().kind.typed_array;
        if (src.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Source TypedArray buffer is detached" }});
        if (target_off_f + @as(f64, @floatFromInt(src.length)) > @as(f64, @floatFromInt(dst.length))) {
            return rt.throw(.RangeError, &.{.{ .ascii = "offset is out of bounds" }});
        }
        const target_off: usize = @intFromFloat(target_off_f);
        if (src.length == 0) return .undefined;
        const dst_bpe = dst.kind.bytesPerElement();
        const src_bpe = src.kind.bytesPerElement();
        const dst_data = dst.buffer.kind.array_buffer.data[dst.byte_offset + target_off * dst_bpe ..][0 .. src.length * dst_bpe];
        const src_data = src.buffer.kind.array_buffer.data[src.byte_offset..][0 .. src.length * src_bpe];
        if (src.kind.isBigInt() != dst.kind.isBigInt()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Cannot mix BigInt and other types, use explicit conversions" }});
        }
        if (src.buffer == dst.buffer) {
            if (src.kind == dst.kind) {
                if (@intFromPtr(dst_data.ptr) < @intFromPtr(src_data.ptr)) {
                    std.mem.copyForwards(u8, dst_data, src_data);
                } else {
                    std.mem.copyBackwards(u8, dst_data, src_data);
                }
            } else if (src.kind.isBigInt()) {
                const tmp = try rt.gpa.alloc(Value, src.length);
                defer rt.gpa.free(tmp);
                for (0..src.length) |i| tmp[i] = try object.readTypedArrayElement(rt, src, i);
                for (tmp, 0..) |v, i| try object.writeTypedArrayElement(rt, dst, target_off + i, v);
            } else {
                const tmp = try rt.gpa.alloc(f64, src.length);
                defer rt.gpa.free(tmp);
                for (0..src.length) |i| tmp[i] = object.readTypedArrayNumber(src, i).asNumber();
                for (tmp, 0..) |n, i| object.writeTypedArrayNumber(dst, target_off + i, n);
            }
        } else if (src.kind == dst.kind) {
            @memcpy(dst_data, src_data);
        } else if (src.kind.isBigInt()) {
            for (0..src.length) |i| {
                const v = try object.readTypedArrayElement(rt, src, i);
                try object.writeTypedArrayElement(rt, dst, target_off + i, v);
            }
        } else {
            for (0..src.length) |i| {
                object.writeTypedArrayNumber(dst, target_off + i, object.readTypedArrayNumber(src, i).asNumber());
            }
        }
        return .undefined;
    }

    if (src_val.isNullish()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const src_len_f = try common.toLength(rt, try object.get(rt, src_val, try object.named(rt, "length")));
    if (target_off_f + src_len_f > @as(f64, @floatFromInt(dst.length))) {
        return rt.throw(.RangeError, &.{.{ .ascii = "offset is out of bounds" }});
    }
    const target_off: usize = @intFromFloat(target_off_f);
    const src_len: usize = @intFromFloat(src_len_f);
    for (0..src_len) |i| {
        const v = try object.get(rt, src_val, .{ .index = @intCast(i) });
        try object.writeTypedArrayElement(rt, dst, target_off + i, v);
    }
    return .undefined;
}

fn typedArraySpeciesCreate(rt: *Runtime, exemplar: *Object, args: []const Value, min_len: ?usize) Error!*Object {
    const ta = exemplar.kind.typed_array;
    const default_ctor = Value.fromNative(&builtins.typed_array_ctors[@backingInt(ta.kind)]);
    const ctor = try common.speciesConstructor(rt, Value.fromObject(exemplar), default_ctor);
    if (ctor.isNative() and ctor.asNative() == &builtins.typed_array_ctors[@backingInt(ta.kind)]) {
        const created = try typedArrayConstructKind(rt, ta.kind, args);
        const dst = created.asObject();
        if (min_len) |ml| {
            if (dst.kind.typed_array.length < ml) {
                return rt.throw(.TypeError, &.{.{ .ascii = "Derived TypedArray constructor created too small array" }});
            }
        }
        return dst;
    }
    const created = try common.constructValue(rt, ctor, args);
    const dst = try requireLiveTypedArray(rt, created);
    if (min_len) |ml| {
        if (dst.kind.typed_array.length < ml) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Derived TypedArray constructor created too small array" }});
        }
    }
    return dst;
}

fn taSubarray(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireTypedArray(rt, this);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const src_len: usize = if (ta.buffer.kind.array_buffer.detached) 0 else ta.length;
    const begin_idx = try relativeIndex(rt, common.arg(args, 0), src_len, 0);
    const end_idx = try relativeIndex(rt, common.arg(args, 1), src_len, src_len);
    const new_len = if (end_idx > begin_idx) end_idx - begin_idx else 0;
    const new_off = ta.byte_offset + begin_idx * ta.kind.bytesPerElement();
    const dst = try typedArraySpeciesCreate(rt, o, &.{
        Value.fromObject(ta.buffer),
        Value.fromNumber(@floatFromInt(new_off)),
        Value.fromNumber(@floatFromInt(new_len)),
    }, null);
    return Value.fromObject(dst);
}

fn taSlice(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const start_idx = try relativeIndex(rt, common.arg(args, 0), ta.length, 0);
    const end_idx = try relativeIndex(rt, common.arg(args, 1), ta.length, ta.length);
    const count = if (end_idx > start_idx) end_idx - start_idx else 0;
    const dst = try typedArraySpeciesCreate(rt, o, &.{Value.fromNumber(@floatFromInt(count))}, count);
    root_buf[1] = Value.fromObject(dst);
    if (count > 0) {
        if (ta.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
        const dst_ta = dst.kind.typed_array;
        if (dst_ta.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
        if (dst_ta.kind == ta.kind and dst_ta.buffer != ta.buffer) {
            const bpe = ta.kind.bytesPerElement();
            const src_bytes = ta.buffer.kind.array_buffer.data[ta.byte_offset + start_idx * bpe ..][0 .. count * bpe];
            @memcpy(dst_ta.buffer.kind.array_buffer.data[dst_ta.byte_offset..][0 .. count * bpe], src_bytes);
        } else {
            if (ta.kind.isBigInt() != dst_ta.kind.isBigInt()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "Cannot mix BigInt and other TypedArray types" }});
            }
            for (0..count) |i| {
                const v = try object.readTypedArrayElement(rt, ta, start_idx + i);
                try object.writeTypedArrayElement(rt, dst_ta, i, v);
            }
        }
    }
    return Value.fromObject(dst);
}

fn taFill(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (ta.kind.isBigInt()) {
        const b = try ops.toBigInt(rt, common.arg(args, 0));
        const start_idx = try relativeIndex(rt, common.arg(args, 1), ta.length, 0);
        const end_idx = try relativeIndex(rt, common.arg(args, 2), ta.length, ta.length);
        if (ta.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
        if (end_idx > start_idx) {
            for (start_idx..end_idx) |i| object.writeTypedArrayBigInt(ta, i, b);
        }
    } else {
        const val = try ops.toNumber(rt, common.arg(args, 0));
        const start_idx = try relativeIndex(rt, common.arg(args, 1), ta.length, 0);
        const end_idx = try relativeIndex(rt, common.arg(args, 2), ta.length, ta.length);
        if (ta.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
        if (end_idx > start_idx) {
            for (start_idx..end_idx) |i| object.writeTypedArrayNumber(ta, i, val);
        }
    }
    return this;
}

fn taCopyWithin(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const to_idx = try relativeIndex(rt, common.arg(args, 0), ta.length, 0);
    const from_idx = try relativeIndex(rt, common.arg(args, 1), ta.length, 0);
    const end_idx = try relativeIndex(rt, common.arg(args, 2), ta.length, ta.length);
    if (end_idx <= from_idx or to_idx >= ta.length) return this;
    const count = @min(end_idx - from_idx, ta.length - to_idx);
    if (ta.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
    const bpe = ta.kind.bytesPerElement();
    const data = ta.buffer.kind.array_buffer.data;
    const dst_bytes = data[ta.byte_offset + to_idx * bpe ..][0 .. count * bpe];
    const src_bytes = data[ta.byte_offset + from_idx * bpe ..][0 .. count * bpe];
    if (to_idx < from_idx) {
        std.mem.copyForwards(u8, dst_bytes, src_bytes);
    } else if (to_idx > from_idx) {
        std.mem.copyBackwards(u8, dst_bytes, src_bytes);
    }
    return this;
}

fn taReverse(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    if (ta.length <= 1) return this;
    const bpe = ta.kind.bytesPerElement();
    const data = ta.buffer.kind.array_buffer.data[ta.byte_offset..][0 .. ta.length * bpe];
    var i: usize = 0;
    var j: usize = ta.length - 1;
    var tmp: [8]u8 = undefined;
    while (i < j) : ({
        i += 1;
        j -= 1;
    }) {
        const a_slice = data[i * bpe ..][0..bpe];
        const b_slice = data[j * bpe ..][0..bpe];
        @memcpy(tmp[0..bpe], a_slice);
        @memcpy(a_slice, b_slice);
        @memcpy(b_slice, tmp[0..bpe]);
    }
    return this;
}

fn numericSortLess(_: void, a: f64, b: f64) bool {
    if (std.math.isNan(a)) return false;
    if (std.math.isNan(b)) return true;
    if (a < b) return true;
    if (a > b) return false;
    // -0 before +0
    return std.math.signbit(a) and !std.math.signbit(b);
}

fn mergeSortTypedArray(
    rt: *Runtime,
    arr: []f64,
    tmp: []f64,
    cmp: Value,
) Error!void {
    if (arr.len <= 1) return;
    const mid = arr.len / 2;
    try mergeSortTypedArray(rt, arr[0..mid], tmp[0..mid], cmp);
    try mergeSortTypedArray(rt, arr[mid..], tmp[mid..], cmp);
    var i: usize = 0;
    var j: usize = mid;
    var k: usize = 0;
    while (i < mid and j < arr.len) : (k += 1) {
        try rt.step();
        const res = try rt.callCallable(cmp, .undefined, &.{ Value.fromNumber(arr[i]), Value.fromNumber(arr[j]) });
        const order = try ops.toNumber(rt, res);
        if (order <= 0 or std.math.isNan(order)) {
            tmp[k] = arr[i];
            i += 1;
        } else {
            tmp[k] = arr[j];
            j += 1;
        }
    }
    while (i < mid) : ({
        i += 1;
        k += 1;
    }) tmp[k] = arr[i];
    while (j < arr.len) : ({
        j += 1;
        k += 1;
    }) tmp[k] = arr[j];
    @memcpy(arr, tmp[0..arr.len]);
}

fn mergeSortTypedArrayValues(
    rt: *Runtime,
    arr: []Value,
    tmp: []Value,
    cmp: Value,
) Error!void {
    if (arr.len <= 1) return;
    const mid = arr.len / 2;
    try mergeSortTypedArrayValues(rt, arr[0..mid], tmp[0..mid], cmp);
    try mergeSortTypedArrayValues(rt, arr[mid..], tmp[mid..], cmp);
    var i: usize = 0;
    var j: usize = mid;
    var k: usize = 0;
    while (i < mid and j < arr.len) : (k += 1) {
        try rt.step();
        const res = try rt.callCallable(cmp, .undefined, &.{ arr[i], arr[j] });
        const order = try ops.toNumber(rt, res);
        if (order <= 0 or std.math.isNan(order)) {
            tmp[k] = arr[i];
            i += 1;
        } else {
            tmp[k] = arr[j];
            j += 1;
        }
    }
    while (i < mid) : ({
        i += 1;
        k += 1;
    }) tmp[k] = arr[i];
    while (j < arr.len) : ({
        j += 1;
        k += 1;
    }) tmp[k] = arr[j];
    @memcpy(arr, tmp[0..arr.len]);
}

fn taSort(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cmp = common.arg(args, 0);
    if (!cmp.isUndefined() and !cmp.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "The comparison function must be either a function or undefined" }});
    }
    const ta = o.kind.typed_array;
    if (ta.length <= 1) return this;

    if (ta.kind.isBigInt()) {
        if (cmp.isUndefined()) {
            if (ta.kind == .bigint64) {
                const vals = try rt.gpa.alloc(i64, ta.length);
                defer rt.gpa.free(vals);
                for (0..ta.length) |i| vals[i] = object.readTypedArrayI64(ta, i);
                std.mem.sort(i64, vals, {}, std.sort.asc(i64));
                const data = ta.buffer.kind.array_buffer.data;
                const native_endian = @import("builtin").cpu.arch.endian();
                for (vals, 0..) |v, i| {
                    std.mem.writeInt(i64, data[ta.byte_offset + i * 8 ..][0..8], v, native_endian);
                }
            } else {
                const vals = try rt.gpa.alloc(u64, ta.length);
                defer rt.gpa.free(vals);
                for (0..ta.length) |i| vals[i] = object.readTypedArrayU64(ta, i);
                std.mem.sort(u64, vals, {}, std.sort.asc(u64));
                const data = ta.buffer.kind.array_buffer.data;
                const native_endian = @import("builtin").cpu.arch.endian();
                for (vals, 0..) |v, i| {
                    std.mem.writeInt(u64, data[ta.byte_offset + i * 8 ..][0..8], v, native_endian);
                }
            }
        } else {
            const vals = try rt.gpa.alloc(Value, ta.length);
            defer rt.gpa.free(vals);
            for (0..ta.length) |i| vals[i] = try object.readTypedArrayElement(rt, ta, i);
            var root_buf = [_]Value{ this, cmp };
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);
            var val_roots: rt_mod.ValueRoots = .{ .values = vals };
            try val_roots.register(rt);
            defer val_roots.unregister(rt);
            const scratch = try rt.gpa.alloc(Value, ta.length);
            defer rt.gpa.free(scratch);
            try mergeSortTypedArrayValues(rt, vals, scratch, cmp);
            if (!ta.buffer.kind.array_buffer.detached) {
                for (vals, 0..) |v, i| try object.writeTypedArrayElement(rt, ta, i, v);
            }
        }
        return this;
    }

    const vals = try rt.gpa.alloc(f64, ta.length);
    defer rt.gpa.free(vals);
    for (0..ta.length) |i| vals[i] = object.readTypedArrayNumber(ta, i).asNumber();

    if (cmp.isUndefined()) {
        std.mem.sort(f64, vals, {}, numericSortLess);
    } else {
        var root_buf = [_]Value{ this, cmp };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);
        const scratch = try rt.gpa.alloc(f64, ta.length);
        defer rt.gpa.free(scratch);
        try mergeSortTypedArray(rt, vals, scratch, cmp);
    }
    if (!ta.buffer.kind.array_buffer.detached) {
        for (vals, 0..) |n, i| object.writeTypedArrayNumber(ta, i, n);
    }
    return this;
}

fn taToReversed(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const ta = o.kind.typed_array;
    const dst = try allocateTypedArray(rt, ta.kind, ta.length);
    const dst_ta = dst.kind.typed_array;
    const bpe = ta.kind.bytesPerElement();
    const src_data = ta.buffer.kind.array_buffer.data[ta.byte_offset..][0 .. ta.length * bpe];
    const dst_data = dst_ta.buffer.kind.array_buffer.data[dst_ta.byte_offset..][0 .. ta.length * bpe];
    for (0..ta.length) |k| {
        const from = ta.length - 1 - k;
        @memcpy(dst_data[k * bpe ..][0..bpe], src_data[from * bpe ..][0..bpe]);
    }
    return Value.fromObject(dst);
}

fn taToSorted(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const cmp = common.arg(args, 0);
    if (!cmp.isUndefined() and !cmp.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "The comparison function must be either a function or undefined" }});
    }
    const o = try requireLiveTypedArray(rt, this);
    var root_buf = [_]Value{ this, cmp, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const ta = o.kind.typed_array;
    const dst = try allocateTypedArray(rt, ta.kind, ta.length);
    root_buf[2] = Value.fromObject(dst);
    const dst_ta = dst.kind.typed_array;
    if (ta.length == 0) return Value.fromObject(dst);
    if (ta.length == 1) {
        const bpe = ta.kind.bytesPerElement();
        @memcpy(
            dst_ta.buffer.kind.array_buffer.data[dst_ta.byte_offset..][0..bpe],
            ta.buffer.kind.array_buffer.data[ta.byte_offset..][0..bpe],
        );
        return Value.fromObject(dst);
    }

    if (ta.kind.isBigInt()) {
        if (cmp.isUndefined()) {
            if (ta.kind == .bigint64) {
                const vals = try rt.gpa.alloc(i64, ta.length);
                defer rt.gpa.free(vals);
                for (0..ta.length) |i| vals[i] = object.readTypedArrayI64(ta, i);
                std.mem.sort(i64, vals, {}, std.sort.asc(i64));
                const data = dst_ta.buffer.kind.array_buffer.data;
                const native_endian = @import("builtin").cpu.arch.endian();
                for (vals, 0..) |v, i| {
                    std.mem.writeInt(i64, data[dst_ta.byte_offset + i * 8 ..][0..8], v, native_endian);
                }
            } else {
                const vals = try rt.gpa.alloc(u64, ta.length);
                defer rt.gpa.free(vals);
                for (0..ta.length) |i| vals[i] = object.readTypedArrayU64(ta, i);
                std.mem.sort(u64, vals, {}, std.sort.asc(u64));
                const data = dst_ta.buffer.kind.array_buffer.data;
                const native_endian = @import("builtin").cpu.arch.endian();
                for (vals, 0..) |v, i| {
                    std.mem.writeInt(u64, data[dst_ta.byte_offset + i * 8 ..][0..8], v, native_endian);
                }
            }
        } else {
            const vals = try rt.gpa.alloc(Value, ta.length);
            defer rt.gpa.free(vals);
            for (0..ta.length) |i| vals[i] = try object.readTypedArrayElement(rt, ta, i);
            var val_roots: rt_mod.ValueRoots = .{ .values = vals };
            try val_roots.register(rt);
            defer val_roots.unregister(rt);
            const scratch = try rt.gpa.alloc(Value, ta.length);
            defer rt.gpa.free(scratch);
            try mergeSortTypedArrayValues(rt, vals, scratch, cmp);
            for (vals, 0..) |v, i| try object.writeTypedArrayElement(rt, dst_ta, i, v);
        }
        return Value.fromObject(dst);
    }

    const vals = try rt.gpa.alloc(f64, ta.length);
    defer rt.gpa.free(vals);
    for (0..ta.length) |i| vals[i] = object.readTypedArrayNumber(ta, i).asNumber();

    if (cmp.isUndefined()) {
        std.mem.sort(f64, vals, {}, numericSortLess);
    } else {
        const scratch = try rt.gpa.alloc(f64, ta.length);
        defer rt.gpa.free(scratch);
        try mergeSortTypedArray(rt, vals, scratch, cmp);
    }
    for (vals, 0..) |n, i| object.writeTypedArrayNumber(dst_ta, i, n);
    return Value.fromObject(dst);
}

fn taWith(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const idx_arg = common.arg(args, 0);
    const val_arg = common.arg(args, 1);
    var root_buf = [_]Value{ this, idx_arg, val_arg, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const ta = o.kind.typed_array;
    const len = ta.length;
    const rel = try common.toIntegerOrInfinity(rt, idx_arg);
    const actual_f = if (rel >= 0.0) rel else @as(f64, @floatFromInt(len)) + rel;

    const is_bigint = ta.kind.isBigInt();
    const big_val: *const heap_mod.BigInt = if (is_bigint) blk: {
        const b = try ops.toBigInt(rt, val_arg);
        root_buf[3] = Value.fromBigInt(b);
        break :blk b;
    } else undefined;
    const num_val: f64 = if (!is_bigint) try ops.toNumber(rt, val_arg) else 0.0;

    if (ta.buffer.kind.array_buffer.detached or !std.math.isFinite(actual_f) or actual_f < 0.0 or actual_f >= @as(f64, @floatFromInt(len))) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Invalid typed array index" }});
    }
    const actual_idx: usize = @intFromFloat(actual_f);
    const dst = try allocateTypedArray(rt, ta.kind, len);
    const dst_ta = dst.kind.typed_array;
    const bpe = ta.kind.bytesPerElement();
    @memcpy(
        dst_ta.buffer.kind.array_buffer.data[dst_ta.byte_offset..][0 .. len * bpe],
        ta.buffer.kind.array_buffer.data[ta.byte_offset..][0 .. len * bpe],
    );
    if (is_bigint) {
        object.writeTypedArrayBigInt(dst_ta, actual_idx, big_val);
    } else {
        object.writeTypedArrayNumber(dst_ta, actual_idx, num_val);
    }
    return Value.fromObject(dst);
}

fn taIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    if (ta.length == 0) return Value.fromNumber(-1);
    const search = common.arg(args, 0);
    const from_n = if (args.len > 1) try common.toIntegerOrInfinity(rt, common.arg(args, 1)) else 0.0;
    if (ta.kind.isBigInt()) {
        if (!search.isBigInt()) return Value.fromNumber(-1);
    } else if (!search.isNumber()) return Value.fromNumber(-1);
    if (ta.buffer.kind.array_buffer.detached) return Value.fromNumber(-1);
    const len_f: f64 = @floatFromInt(ta.length);
    if (from_n >= len_f) return Value.fromNumber(-1);
    const start: usize = if (from_n < 0) blk: {
        const k = len_f + from_n;
        break :blk if (k <= 0) 0 else @intFromFloat(k);
    } else @intFromFloat(from_n);
    for (start..ta.length) |i| {
        if (ta.buffer.kind.array_buffer.detached) return Value.fromNumber(-1);
        const elem = try object.readTypedArrayElement(rt, ta, i);
        if (ops.strictEquals(elem, search)) return Value.fromNumber(@floatFromInt(i));
    }
    return Value.fromNumber(-1);
}

fn taLastIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    if (ta.length == 0) return Value.fromNumber(-1);
    const search = common.arg(args, 0);
    const len_f: f64 = @floatFromInt(ta.length);
    const from_n = if (args.len > 1) try common.toIntegerOrInfinity(rt, common.arg(args, 1)) else len_f - 1.0;
    if (ta.kind.isBigInt()) {
        if (!search.isBigInt()) return Value.fromNumber(-1);
    } else if (!search.isNumber()) return Value.fromNumber(-1);
    if (ta.buffer.kind.array_buffer.detached) return Value.fromNumber(-1);
    const k_f = if (from_n >= 0) @min(from_n, len_f - 1.0) else len_f + from_n;
    if (k_f < 0) return Value.fromNumber(-1);
    var i: usize = @intFromFloat(k_f);
    while (true) {
        if (ta.buffer.kind.array_buffer.detached) return Value.fromNumber(-1);
        const elem = try object.readTypedArrayElement(rt, ta, i);
        if (ops.strictEquals(elem, search)) return Value.fromNumber(@floatFromInt(i));
        if (i == 0) break;
        i -= 1;
    }
    return Value.fromNumber(-1);
}

fn taIncludes(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    if (ta.length == 0) return Value.fromBool(false);
    const search = common.arg(args, 0);
    const from_n = if (args.len > 1) try common.toIntegerOrInfinity(rt, common.arg(args, 1)) else 0.0;
    const len_f: f64 = @floatFromInt(ta.length);
    if (from_n >= len_f) return Value.fromBool(false);
    const start: usize = if (from_n < 0) blk: {
        const k = len_f + from_n;
        break :blk if (k <= 0) 0 else @intFromFloat(k);
    } else @intFromFloat(from_n);
    for (start..ta.length) |i| {
        const elem = try object.readTypedArrayElement(rt, ta, i);
        if (heap_mod.sameValueZero(elem, search)) return Value.fromBool(true);
    }
    return Value.fromBool(false);
}

fn taAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    const idx_f = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
    const len_f: f64 = @floatFromInt(ta.length);
    const k = if (idx_f >= 0) idx_f else len_f + idx_f;
    if (k < 0 or k >= len_f) return .undefined;
    return object.readTypedArrayElement(rt, ta, @intFromFloat(k));
}

fn taJoin(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    var sep_buf: ops.NumberBuf = undefined;
    var sep_units_buf: [64]u16 = undefined;
    const sep: []const u16 = if (common.arg(args, 0).isUndefined())
        &.{','}
    else switch (try ops.toPiece(rt, common.arg(args, 0), &sep_buf)) {
        .utf16 => |u| u,
        .ascii => |a| blk: {
            for (a, 0..) |c, i| sep_units_buf[i] = c;
            break :blk sep_units_buf[0..a.len];
        },
    };
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);
    for (0..ta.length) |i| {
        if (i > 0) try out.appendSlice(rt.gpa, sep);
        var buf: ops.NumberBuf = undefined;
        const elem = try object.readTypedArrayElement(rt, ta, i);
        if (elem.isUndefined()) continue;
        switch (try ops.toPiece(rt, elem, &buf)) {
            .ascii => |s| for (s) |c| try out.append(rt.gpa, c),
            .utf16 => |u| try out.appendSlice(rt.gpa, u),
        }
        if (out.items.len > rt.heap.max_string_length) return rt.limit(.string_length);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn taToLocaleString(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);
    for (0..ta.length) |i| {
        if (i > 0) try out.append(rt.gpa, ',');
        const elem = try object.readTypedArrayElement(rt, ta, i);
        if (elem.isUndefined() or elem.isNull()) continue;
        root_buf[1] = elem;
        const m = try object.get(rt, elem, try object.named(rt, "toLocaleString"));
        if (m.isNative() or m.isClosure()) {
            const res = try rt.callCallable(m, elem, args);
            const str = try common.toStringObj(rt, res);
            root_buf[2] = Value.fromString(str);
            try common.appendUnits(rt, &out, str.units);
        } else {
            var buf: ops.NumberBuf = undefined;
            switch (try ops.toPiece(rt, elem, &buf)) {
                .ascii => |s| for (s) |c| try out.append(rt.gpa, c),
                .utf16 => |u| try common.appendUnits(rt, &out, u),
            }
        }
        if (out.items.len > rt.heap.max_string_length) return rt.limit(.string_length);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn taKeys(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try requireLiveTypedArray(rt, this);
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).array_iterator_prototype, this, .array_keys));
}

fn taValues(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try requireLiveTypedArray(rt, this);
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).array_iterator_prototype, this, .array_values));
}

fn taEntries(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try requireLiveTypedArray(rt, this);
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).array_iterator_prototype, this, .array_entries));
}

fn taForEach(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cb = try common.requireCallable(rt, common.arg(args, 0));
    const this_arg = common.arg(args, 1);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, cb, this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    for (0..ta.length) |i| {
        const elem = try object.readTypedArrayElement(rt, ta, i);
        _ = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), this });
    }
    return .undefined;
}

fn taEvery(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cb = try common.requireCallable(rt, common.arg(args, 0));
    const this_arg = common.arg(args, 1);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, cb, this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    for (0..ta.length) |i| {
        const elem = try object.readTypedArrayElement(rt, ta, i);
        const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), this });
        if (!ops.toBoolean(res)) return Value.fromBool(false);
    }
    return Value.fromBool(true);
}

fn taSome(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cb = try common.requireCallable(rt, common.arg(args, 0));
    const this_arg = common.arg(args, 1);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, cb, this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    for (0..ta.length) |i| {
        const elem = try object.readTypedArrayElement(rt, ta, i);
        const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), this });
        if (ops.toBoolean(res)) return Value.fromBool(true);
    }
    return Value.fromBool(false);
}

fn taFindImpl(rt: *Runtime, this: Value, args: []const Value, reverse: bool, return_index: bool) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cb = try common.requireCallable(rt, common.arg(args, 0));
    const this_arg = common.arg(args, 1);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, cb, this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    if (ta.length == 0) return if (return_index) Value.fromNumber(-1) else .undefined;
    var i: usize = if (reverse) ta.length - 1 else 0;
    while (true) {
        const elem = try object.readTypedArrayElement(rt, ta, i);
        const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), this });
        if (ops.toBoolean(res)) return if (return_index) Value.fromNumber(@floatFromInt(i)) else elem;
        if (reverse) {
            if (i == 0) break;
            i -= 1;
        } else {
            i += 1;
            if (i >= ta.length) break;
        }
    }
    return if (return_index) Value.fromNumber(-1) else .undefined;
}

fn taFind(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return taFindImpl(rt, this, args, false, false);
}

fn taFindIndex(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return taFindImpl(rt, this, args, false, true);
}

fn taFindLast(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return taFindImpl(rt, this, args, true, false);
}

fn taFindLastIndex(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return taFindImpl(rt, this, args, true, true);
}

fn taMap(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cb = try common.requireCallable(rt, common.arg(args, 0));
    const this_arg = common.arg(args, 1);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, cb, this_arg, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const dst = try typedArraySpeciesCreate(rt, o, &.{Value.fromNumber(@floatFromInt(ta.length))}, ta.length);
    root_buf[3] = Value.fromObject(dst);
    for (0..ta.length) |i| {
        const elem = try object.readTypedArrayElement(rt, ta, i);
        const mapped = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), this });
        try object.writeTypedArrayElement(rt, dst.kind.typed_array, i, mapped);
    }
    return Value.fromObject(dst);
}

fn taFilter(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cb = try common.requireCallable(rt, common.arg(args, 0));
    const this_arg = common.arg(args, 1);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, cb, this_arg, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    var kept: std.ArrayList(Value) = .empty;
    defer kept.deinit(rt.gpa);
    for (0..ta.length) |i| {
        const elem = try object.readTypedArrayElement(rt, ta, i);
        root_buf[3] = elem;
        var kept_roots: rt_mod.ValueRoots = .{ .values = kept.items };
        try kept_roots.register(rt);
        defer kept_roots.unregister(rt);
        const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), this });
        if (ops.toBoolean(res)) try kept.append(rt.gpa, root_buf[3]);
    }
    var kept_roots: rt_mod.ValueRoots = .{ .values = kept.items };
    try kept_roots.register(rt);
    defer kept_roots.unregister(rt);
    const dst = try typedArraySpeciesCreate(rt, o, &.{Value.fromNumber(@floatFromInt(kept.items.len))}, kept.items.len);
    root_buf[3] = Value.fromObject(dst);
    for (kept.items, 0..) |v, i| try object.writeTypedArrayElement(rt, dst.kind.typed_array, i, v);
    return Value.fromObject(dst);
}

fn taReduceImpl(rt: *Runtime, this: Value, args: []const Value, right: bool) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cb = try common.requireCallable(rt, common.arg(args, 0));
    const ta = o.kind.typed_array;
    if (ta.length == 0 and args.len < 2) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Reduce of empty typed array with no initial value" }});
    }
    var acc: Value = undefined;
    var start_i: usize = undefined;
    if (args.len >= 2) {
        acc = common.arg(args, 1);
        start_i = if (right) ta.length else 0;
    } else {
        acc = try object.readTypedArrayElement(rt, ta, if (right) ta.length - 1 else 0);
        start_i = if (right) ta.length - 1 else 1;
    }
    var root_buf = [_]Value{ this, cb, acc };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    if (right) {
        var i = start_i;
        while (i > 0) {
            i -= 1;
            const elem = try object.readTypedArrayElement(rt, ta, i);
            root_buf[2] = try rt.callCallable(cb, .undefined, &.{ root_buf[2], elem, Value.fromNumber(@floatFromInt(i)), this });
        }
    } else {
        for (start_i..ta.length) |i| {
            const elem = try object.readTypedArrayElement(rt, ta, i);
            root_buf[2] = try rt.callCallable(cb, .undefined, &.{ root_buf[2], elem, Value.fromNumber(@floatFromInt(i)), this });
        }
    }
    return root_buf[2];
}

fn taReduce(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return taReduceImpl(rt, this, args, false);
}

fn taReduceRight(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return taReduceImpl(rt, this, args, true);
}

// ---- Uint8Array Base64 & Hex (ES2026 / TC39 proposal-arraybuffer-base64)

const u8_from_base64: Native = .{ .name = "fromBase64", .length = 1, .call = u8FromBase64 };
const u8_from_hex: Native = .{ .name = "fromHex", .length = 1, .call = u8FromHex };
const u8_to_base64: Native = .{ .name = "toBase64", .length = 0, .call = u8ToBase64 };
const u8_to_hex: Native = .{ .name = "toHex", .length = 0, .call = u8ToHex };
const u8_set_from_base64: Native = .{ .name = "setFromBase64", .length = 1, .call = u8SetFromBase64 };
const u8_set_from_hex: Native = .{ .name = "setFromHex", .length = 1, .call = u8SetFromHex };

const Base64Alphabet = enum { base64, base64url };
const LastChunkHandling = enum { loose, strict, stop_before_partial };

fn requireLiveUint8Array(rt: *Runtime, this: Value) Error!*Object {
    if (!this.isObject() or this.asObject().kind != .typed_array) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Method Uint8Array.prototype called on incompatible receiver" }});
    }
    const o = this.asObject();
    if (o.kind.typed_array.kind != .uint8) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Method Uint8Array.prototype requires a Uint8Array receiver" }});
    }
    if (o.kind.typed_array.buffer.kind.array_buffer.detached) {
        return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
    }
    return o;
}

fn stringEqualsAscii(s: *const heap_mod.String, ascii: []const u8) bool {
    if (s.units.len != ascii.len) return false;
    for (s.units, ascii) |u, c| {
        if (u != c) return false;
    }
    return true;
}

fn readAlphabetOption(rt: *Runtime, opts: Value) Error!Base64Alphabet {
    const val = try object.get(rt, opts, try object.named(rt, "alphabet"));
    if (val.isUndefined()) return .base64;
    if (!val.isString()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Expected alphabet option to be 'base64' or 'base64url'" }});
    }
    const s = val.asString();
    if (stringEqualsAscii(s, "base64")) return .base64;
    if (stringEqualsAscii(s, "base64url")) return .base64url;
    return rt.throw(.TypeError, &.{.{ .ascii = "Expected alphabet option to be 'base64' or 'base64url'" }});
}

fn readLastChunkHandlingOption(rt: *Runtime, opts: Value) Error!LastChunkHandling {
    const val = try object.get(rt, opts, try object.named(rt, "lastChunkHandling"));
    if (val.isUndefined()) return .loose;
    if (!val.isString()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Expected lastChunkHandling option to be 'loose', 'strict', or 'stop-before-partial'" }});
    }
    const s = val.asString();
    if (stringEqualsAscii(s, "loose")) return .loose;
    if (stringEqualsAscii(s, "strict")) return .strict;
    if (stringEqualsAscii(s, "stop-before-partial")) return .stop_before_partial;
    return rt.throw(.TypeError, &.{.{ .ascii = "Expected lastChunkHandling option to be 'loose', 'strict', or 'stop-before-partial'" }});
}

inline fn isBase64AsciiWhitespace(u: u16) bool {
    return u == 0x09 or u == 0x0A or u == 0x0C or u == 0x0D or u == 0x20;
}

fn skipAsciiWhitespace(units: []const u16, start: usize) usize {
    var i = start;
    while (i < units.len and isBase64AsciiWhitespace(units[i])) : (i += 1) {}
    return i;
}

fn decodeBase64Char(u: u16, alphabet: Base64Alphabet) ?u8 {
    if (u >= 'A' and u <= 'Z') return @intCast(u - 'A');
    if (u >= 'a' and u <= 'z') return @intCast(u - 'a' + 26);
    if (u >= '0' and u <= '9') return @intCast(u - '0' + 52);
    return switch (alphabet) {
        .base64 => if (u == '+') 62 else if (u == '/') 63 else null,
        .base64url => if (u == '-') 62 else if (u == '_') 63 else null,
    };
}

fn hexDigit(u: u16) ?u8 {
    if (u >= '0' and u <= '9') return @intCast(u - '0');
    if (u >= 'a' and u <= 'f') return @intCast(u - 'a' + 10);
    if (u >= 'A' and u <= 'F') return @intCast(u - 'A' + 10);
    return null;
}

const Base64DecodeResult = struct {
    read: usize,
    written: usize,
    syntax_error: bool,
};

fn decodeBase64Chunk(chunk: [4]u8, chunk_len: usize, throw_on_extra_bits: bool, out_bytes: *[3]u8) ?usize {
    switch (chunk_len) {
        2 => {
            if (throw_on_extra_bits and (chunk[1] & 0x0F) != 0) return null;
            out_bytes[0] = (chunk[0] << 2) | (chunk[1] >> 4);
            return 1;
        },
        3 => {
            if (throw_on_extra_bits and (chunk[2] & 0x03) != 0) return null;
            out_bytes[0] = (chunk[0] << 2) | (chunk[1] >> 4);
            out_bytes[1] = ((chunk[1] & 0x0F) << 4) | (chunk[2] >> 2);
            return 2;
        },
        4 => {
            out_bytes[0] = (chunk[0] << 2) | (chunk[1] >> 4);
            out_bytes[1] = ((chunk[1] & 0x0F) << 4) | (chunk[2] >> 2);
            out_bytes[2] = ((chunk[2] & 0x03) << 6) | chunk[3];
            return 3;
        },
        else => unreachable,
    }
}

/// Core `FromBase64` algorithm. Writes into `fixed_dst` when non-null (for `setFromBase64`),
/// or appends to `dyn_dst` when `fixed_dst` is null (for `fromBase64`).
fn fromBase64Core(
    rt: *Runtime,
    units: []const u16,
    alphabet: Base64Alphabet,
    last_chunk_handling: LastChunkHandling,
    fixed_dst: ?[]u8,
    dyn_dst: ?*std.ArrayList(u8),
) Error!Base64DecodeResult {
    const max_len: usize = if (fixed_dst) |d| d.len else std.math.maxInt(usize);
    if (max_len == 0) return .{ .read = 0, .written = 0, .syntax_error = false };

    var read_idx: usize = 0;
    var written: usize = 0;
    var chunk: [4]u8 = undefined;
    var chunk_len: usize = 0;
    var index: usize = 0;
    const length = units.len;

    while (true) {
        index = skipAsciiWhitespace(units, index);
        if (index == length) {
            if (chunk_len > 0) {
                if (last_chunk_handling == .stop_before_partial) {
                    return .{ .read = read_idx, .written = written, .syntax_error = false };
                }
                if (last_chunk_handling == .loose) {
                    if (chunk_len == 1) {
                        return .{ .read = read_idx, .written = written, .syntax_error = true };
                    }
                    var decoded: [3]u8 = undefined;
                    const n = decodeBase64Chunk(chunk, chunk_len, false, &decoded).?;
                    try emitDecodedBytes(rt, fixed_dst, dyn_dst, &written, decoded[0..n]);
                    return .{ .read = length, .written = written, .syntax_error = false };
                }
                return .{ .read = read_idx, .written = written, .syntax_error = true };
            }
            return .{ .read = length, .written = written, .syntax_error = false };
        }

        const ch = units[index];
        index += 1;

        if (ch == '=') {
            if (chunk_len < 2) {
                return .{ .read = read_idx, .written = written, .syntax_error = true };
            }
            index = skipAsciiWhitespace(units, index);
            if (chunk_len == 2) {
                if (index == length) {
                    if (last_chunk_handling == .stop_before_partial) {
                        return .{ .read = read_idx, .written = written, .syntax_error = false };
                    }
                    return .{ .read = read_idx, .written = written, .syntax_error = true };
                }
                if (units[index] == '=') {
                    index = skipAsciiWhitespace(units, index + 1);
                } else {
                    return .{ .read = read_idx, .written = written, .syntax_error = true };
                }
            }
            if (index < length) {
                return .{ .read = read_idx, .written = written, .syntax_error = true };
            }
            var decoded: [3]u8 = undefined;
            const throw_extra = last_chunk_handling == .strict;
            const n = decodeBase64Chunk(chunk, chunk_len, throw_extra, &decoded) orelse {
                return .{ .read = read_idx, .written = written, .syntax_error = true };
            };
            try emitDecodedBytes(rt, fixed_dst, dyn_dst, &written, decoded[0..n]);
            return .{ .read = length, .written = written, .syntax_error = false };
        }

        const val = decodeBase64Char(ch, alphabet) orelse {
            return .{ .read = read_idx, .written = written, .syntax_error = true };
        };

        const remaining = max_len - written;
        if ((remaining == 1 and chunk_len == 2) or (remaining == 2 and chunk_len == 3)) {
            return .{ .read = read_idx, .written = written, .syntax_error = false };
        }

        chunk[chunk_len] = val;
        chunk_len += 1;
        if (chunk_len == 4) {
            var decoded: [3]u8 = undefined;
            const n = decodeBase64Chunk(chunk, 4, false, &decoded).?;
            try emitDecodedBytes(rt, fixed_dst, dyn_dst, &written, decoded[0..n]);
            chunk_len = 0;
            read_idx = index;
            if (written == max_len) {
                return .{ .read = read_idx, .written = written, .syntax_error = false };
            }
        }
    }
}

fn emitDecodedBytes(
    rt: *Runtime,
    fixed_dst: ?[]u8,
    dyn_dst: ?*std.ArrayList(u8),
    written: *usize,
    bytes: []const u8,
) Error!void {
    if (fixed_dst) |dst| {
        @memcpy(dst[written.*..][0..bytes.len], bytes);
        written.* += bytes.len;
    } else {
        const list = dyn_dst.?;
        if (list.items.len + bytes.len > rt.heap.max_bytes) return rt.heap.exceeded(.heap_bytes);
        try list.appendSlice(rt.gpa, bytes);
        written.* += bytes.len;
    }
}

fn makeReadWrittenObject(rt: *Runtime, read_count: usize, written_count: usize) Error!Value {
    const r = try builtins.realm(rt);
    const res = try rt.heap.newObject(r.object_prototype);
    var root_buf = [_]Value{Value.fromObject(res)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    try rt.heap.defineProperty(res, try rt.heap.internAscii("read"), .{
        .value = Value.fromNumber(@floatFromInt(read_count)),
    });
    try rt.heap.defineProperty(res, try rt.heap.internAscii("written"), .{
        .value = Value.fromNumber(@floatFromInt(written_count)),
    });
    return Value.fromObject(res);
}

fn u8ToBase64(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveUint8Array(rt, this);
    const options = common.arg(args, 0);
    var root_buf = [_]Value{ this, options };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var alphabet: Base64Alphabet = .base64;
    var omit_padding: bool = false;
    if (!options.isUndefined()) {
        if (!options.isObjectLike()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Options must be an object" }});
        }
        alphabet = try readAlphabetOption(rt, options);
        const omit_val = try object.get(rt, options, try object.named(rt, "omitPadding"));
        omit_padding = ops.toBoolean(omit_val);
    }

    const ta = o.kind.typed_array;
    if (ta.buffer.kind.array_buffer.detached) {
        return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
    }
    const src = ta.buffer.kind.array_buffer.data[ta.byte_offset .. ta.byte_offset + ta.length];
    if (src.len == 0) return Value.fromString(try rt.heap.ascii(""));

    const full_triples = src.len / 3;
    const rem = src.len % 3;
    const base_len = std.math.mul(usize, full_triples, 4) catch return rt.limit(.string_length);
    const tail_len: usize = if (rem == 0) 0 else if (omit_padding) rem + 1 else 4;
    const out_len = std.math.add(usize, base_len, tail_len) catch return rt.limit(.string_length);
    if (out_len > rt.heap.max_string_length) return rt.limit(.string_length);
    if (out_len > rt.heap.max_bytes) return rt.heap.exceeded(.heap_bytes);

    const out = try rt.gpa.alloc(u8, out_len);
    defer rt.gpa.free(out);

    const table: *const [64]u8 = switch (alphabet) {
        .base64 => "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
        .base64url => "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_",
    };

    var si: usize = 0;
    var di: usize = 0;
    const triple_end = full_triples * 3;
    while (si < triple_end) : (si += 3) {
        const b0 = src[si];
        const b1 = src[si + 1];
        const b2 = src[si + 2];
        out[di] = table[b0 >> 2];
        out[di + 1] = table[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[di + 2] = table[((b1 & 0x0F) << 2) | (b2 >> 6)];
        out[di + 3] = table[b2 & 0x3F];
        di += 4;
    }
    if (rem == 1) {
        const b0 = src[si];
        out[di] = table[b0 >> 2];
        out[di + 1] = table[(b0 & 0x03) << 4];
        if (!omit_padding) {
            out[di + 2] = '=';
            out[di + 3] = '=';
        }
    } else if (rem == 2) {
        const b0 = src[si];
        const b1 = src[si + 1];
        out[di] = table[b0 >> 2];
        out[di + 1] = table[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[di + 2] = table[(b1 & 0x0F) << 2];
        if (!omit_padding) {
            out[di + 3] = '=';
        }
    }

    return Value.fromString(try rt.heap.ascii(out));
}

fn u8FromBase64(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const str_val = common.arg(args, 0);
    if (!str_val.isString()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Uint8Array.fromBase64 requires a string argument" }});
    }
    const options = common.arg(args, 1);
    var root_buf = [_]Value{ str_val, options };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var alphabet: Base64Alphabet = .base64;
    var last_chunk_handling: LastChunkHandling = .loose;
    if (!options.isUndefined()) {
        if (!options.isObjectLike()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Options must be an object" }});
        }
        alphabet = try readAlphabetOption(rt, options);
        last_chunk_handling = try readLastChunkHandlingOption(rt, options);
    }

    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(rt.gpa);

    const res = try fromBase64Core(rt, str_val.asString().units, alphabet, last_chunk_handling, null, &bytes);
    if (res.syntax_error) {
        return rt.throw(.SyntaxError, &.{.{ .ascii = "Invalid base64 string" }});
    }

    const ta = try allocateTypedArray(rt, .uint8, bytes.items.len);
    if (bytes.items.len > 0) {
        @memcpy(ta.kind.typed_array.buffer.kind.array_buffer.data[0..bytes.items.len], bytes.items);
    }
    return Value.fromObject(ta);
}

fn u8SetFromBase64(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveUint8Array(rt, this);
    const str_val = common.arg(args, 0);
    if (!str_val.isString()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Uint8Array.prototype.setFromBase64 requires a string argument" }});
    }
    const options = common.arg(args, 1);
    var root_buf = [_]Value{ this, str_val, options };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var alphabet: Base64Alphabet = .base64;
    var last_chunk_handling: LastChunkHandling = .loose;
    if (!options.isUndefined()) {
        if (!options.isObjectLike()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Options must be an object" }});
        }
        alphabet = try readAlphabetOption(rt, options);
        last_chunk_handling = try readLastChunkHandlingOption(rt, options);
    }

    const ta = o.kind.typed_array;
    if (ta.buffer.kind.array_buffer.detached) {
        return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
    }
    const dst = ta.buffer.kind.array_buffer.data[ta.byte_offset .. ta.byte_offset + ta.length];
    const res = try fromBase64Core(rt, str_val.asString().units, alphabet, last_chunk_handling, dst, null);
    if (res.syntax_error) {
        return rt.throw(.SyntaxError, &.{.{ .ascii = "Invalid base64 string" }});
    }
    return makeReadWrittenObject(rt, res.read, res.written);
}

fn u8ToHex(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireLiveUint8Array(rt, this);
    const ta = o.kind.typed_array;
    const src = ta.buffer.kind.array_buffer.data[ta.byte_offset .. ta.byte_offset + ta.length];
    if (src.len == 0) return Value.fromString(try rt.heap.ascii(""));

    const out_len = std.math.mul(usize, src.len, 2) catch return rt.limit(.string_length);
    if (out_len > rt.heap.max_string_length) return rt.limit(.string_length);
    if (out_len > rt.heap.max_bytes) return rt.heap.exceeded(.heap_bytes);

    const out = try rt.gpa.alloc(u8, out_len);
    defer rt.gpa.free(out);

    const hex_chars = "0123456789abcdef";
    for (src, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0x0F];
    }
    return Value.fromString(try rt.heap.ascii(out));
}

fn u8FromHex(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const str_val = common.arg(args, 0);
    if (!str_val.isString()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Uint8Array.fromHex requires a string argument" }});
    }
    const units = str_val.asString().units;
    if (units.len % 2 != 0) {
        return rt.throw(.SyntaxError, &.{.{ .ascii = "Hex string must have an even length" }});
    }
    for (units) |u| {
        if (hexDigit(u) == null) {
            return rt.throw(.SyntaxError, &.{.{ .ascii = "Invalid hex character" }});
        }
    }

    var root_buf = [_]Value{str_val};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const byte_len = units.len / 2;
    const ta = try allocateTypedArray(rt, .uint8, byte_len);
    const dst = ta.kind.typed_array.buffer.kind.array_buffer.data;
    const rooted_units = str_val.asString().units;
    for (0..byte_len) |i| {
        const hi = hexDigit(rooted_units[i * 2]).?;
        const lo = hexDigit(rooted_units[i * 2 + 1]).?;
        dst[i] = (hi << 4) | lo;
    }
    return Value.fromObject(ta);
}

fn u8SetFromHex(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveUint8Array(rt, this);
    const str_val = common.arg(args, 0);
    if (!str_val.isString()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Uint8Array.prototype.setFromHex requires a string argument" }});
    }
    const units = str_val.asString().units;
    if (units.len % 2 != 0) {
        return rt.throw(.SyntaxError, &.{.{ .ascii = "Hex string must have an even length" }});
    }

    const ta = o.kind.typed_array;
    const dst = ta.buffer.kind.array_buffer.data[ta.byte_offset .. ta.byte_offset + ta.length];
    const pair_count = @min(units.len / 2, dst.len);
    for (0..pair_count) |i| {
        const hi = hexDigit(units[i * 2]) orelse {
            return rt.throw(.SyntaxError, &.{.{ .ascii = "Invalid hex character" }});
        };
        const lo = hexDigit(units[i * 2 + 1]) orelse {
            return rt.throw(.SyntaxError, &.{.{ .ascii = "Invalid hex character" }});
        };
        dst[i] = (hi << 4) | lo;
    }
    return makeReadWrittenObject(rt, pair_count * 2, pair_count);
}

// ---------------------------------------------------------------- Proxy & Reflect (M46, D76)
