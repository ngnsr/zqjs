//! Object, Object.prototype, property descriptors, and for-in built-ins.

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
const array_builtins = @import("array.zig");
const iterator = @import("iterator.zig");
const proxy_reflect = @import("proxy_reflect.zig");

pub fn register(rt: *Runtime, r: *const builtins.Realm) Error!void {
    try common.method(rt, r.object_prototype, "toString", &object_to_string);
    try common.method(rt, r.object_prototype, "valueOf", &object_value_of);
    try common.method(rt, r.object_prototype, "hasOwnProperty", &object_proto_has_own_property);
    try common.method(rt, r.object_prototype, "isPrototypeOf", &object_proto_is_prototype_of);
    try common.method(rt, r.object_prototype, "propertyIsEnumerable", &object_proto_property_is_enumerable);
    try common.method(rt, r.object_namespace, "keys", &object_keys);
    try common.method(rt, r.object_namespace, "values", &object_values);
    try common.method(rt, r.object_namespace, "entries", &object_entries);
    try common.method(rt, r.object_namespace, "assign", &object_assign);
    try common.method(rt, r.object_namespace, "create", &object_create);
    try common.method(rt, r.object_namespace, "getPrototypeOf", &object_get_prototype_of);
    try common.method(rt, r.object_namespace, "defineProperty", &object_define_property);
    try common.method(rt, r.object_namespace, "defineProperties", &object_define_properties);
    try common.method(rt, r.object_namespace, "getOwnPropertyDescriptor", &object_get_own_property_descriptor);
    try common.method(rt, r.object_namespace, "getOwnPropertyDescriptors", &object_get_own_property_descriptors);
    try common.method(rt, r.object_namespace, "getOwnPropertySymbols", &object_get_own_property_symbols);
    try common.method(rt, r.object_namespace, "getOwnPropertyNames", &object_get_own_property_names);
    try common.method(rt, r.object_namespace, "setPrototypeOf", &object_set_prototype_of);
    try common.method(rt, r.object_namespace, "preventExtensions", &object_prevent_extensions);
    try common.method(rt, r.object_namespace, "isExtensible", &object_is_extensible);
    try common.method(rt, r.object_namespace, "seal", &object_seal);
    try common.method(rt, r.object_namespace, "isSealed", &object_is_sealed);
    try common.method(rt, r.object_namespace, "freeze", &object_freeze);
    try common.method(rt, r.object_namespace, "isFrozen", &object_is_frozen);
    try common.method(rt, r.object_namespace, "hasOwn", &object_has_own);
    try common.method(rt, r.object_namespace, "is", &object_is);
    try common.method(rt, r.object_namespace, "fromEntries", &object_from_entries);
    try common.method(rt, r.object_namespace, "groupBy", &object_group_by);
    try common.immutableConstant(rt, r.object_namespace, "prototype", Value.fromObject(r.object_prototype));
    try common.constant(rt, r.object_prototype, "constructor", Value.fromNative(&builtins.object_global));
}

pub fn newArgumentsObject(rt: *Runtime, args: []const Value) Error!*heap_mod.Object {
    const r = try builtins.realm(rt);
    const obj = try rt.heap.newObject(r.object_prototype);
    obj.ordinary_tag = .arguments;
    var root_buf = [_]Value{Value.fromObject(obj)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var idx_buf: [20]u8 = undefined;
    for (args, 0..) |v, i| {
        const s = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
        const k = try rt.heap.internUtf8(s);
        try rt.heap.defineProperty(obj, k, .{
            .value = v,
            .writable = true,
            .enumerable = true,
            .configurable = true,
        });
    }
    const len_key = try rt.heap.internUtf8("length");
    try rt.heap.defineProperty(obj, len_key, .{
        .value = Value.fromNumber(@floatFromInt(args.len)),
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });
    const callee_k = try rt.heap.internUtf8("callee");
    const tte_val: Value = blk: {
        if (r.function_prototype.props.get(heap_mod.PropKey.fromAtom(try rt.heap.internUtf8("caller")))) |p| {
            if (p.is_accessor and p.value.isClosure()) break :blk p.value;
        }
        break :blk Value.fromClosure(try function_error.createThrowTypeError(rt, r));
    };
    var tte_root = [_]Value{tte_val};
    var tte_roots: rt_mod.ValueRoots = .{ .values = &tte_root };
    try tte_roots.register(rt);
    defer tte_roots.unregister(rt);
    try rt.heap.defineProperty(obj, callee_k, .{
        .is_accessor = true,
        .value = tte_root[0],
        .setter = tte_root[0],
        .enumerable = false,
        .configurable = false,
        .writable = false,
    });
    try common.symbolMethod(rt, obj, r.sym_iterator, &array_builtins.array_values);
    return obj;
}

const object_to_string: Native = .{ .name = "toString", .call = objectToString };

const object_value_of: Native = .{ .name = "valueOf", .call = objectValueOf };

pub fn objectToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined()) return Value.fromString(try rt.heap.ascii("[object Undefined]"));
    if (this.isNull()) return Value.fromString(try rt.heap.ascii("[object Null]"));
    var roots_buf = [_]Value{this};
    var roots = rt_mod.ValueRoots{ .values = &roots_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const is_proxy_arr = if (this.isObject() and this.asObject().kind == .proxy) try array_builtins.isArray(rt, this) else false;
    const builtin_tag: []const u8 = switch (this.unpack()) {
        .undefined, .null => unreachable,
        .boolean => "Boolean",
        .number => "Number",
        .string => "String",
        .symbol => "Object",
        .bigint => "Object",
        .native, .closure => "Function",
        .object => |o| switch (o.kind) {
            .array => "Array",
            .proxy => if (is_proxy_arr) "Array" else if (o.kind.proxy.is_callable) "Function" else "Object",
            .iterator => |it| switch (it.kind) {
                .string_chars => "String Iterator",
                .regexp_match_all => "RegExp String Iterator",
                .map_entries, .map_keys, .map_values, .set_values, .set_entries, .array_values, .array_keys, .array_entries, .helper, .wrap, .custom, .async_from_sync, .for_in => "Object",
            },
            .regexp => "RegExp",
            .date => "Date",
            .module_namespace => "Module",
            .ordinary => switch (o.ordinary_tag) {
                .arguments => "Arguments",
                .@"error" => "Error",
                .plain => if (o.builtin == .number_prototype) "Number" else if (o.builtin == .boolean_prototype) "Boolean" else if (o.builtin == .string_prototype) "String" else if (o.builtin == .function_prototype) "Function" else "Object",
            },
            .primitive_wrapper => |pv| switch (pv.unpack()) {
                .boolean => "Boolean",
                .number => "Number",
                .string => "String",
                else => "Object",
            },
            else => "Object",
        },
    };
    const r = try builtins.realm(rt);
    const tag_val = try object.get(rt, this, .{ .symbol = r.sym_to_string_tag });
    if (tag_val.isString()) {
        roots_buf[0] = tag_val;
        return Value.fromString(try rt.heap.newString(&.{ .{ .ascii = "[object " }, .{ .utf16 = tag_val.asString().units }, .{ .ascii = "]" } }));
    }
    return Value.fromString(try rt.heap.newString(&.{ .{ .ascii = "[object " }, .{ .ascii = builtin_tag }, .{ .ascii = "]" } }));
}

fn objectValueOf(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    return objectConstruct(rt, &.{this});
}

// ---------------------------------------------------------------- Array.prototype

const object_keys: Native = .{ .name = "keys", .length = 1, .call = objectKeys };

const object_values: Native = .{ .name = "values", .length = 1, .call = objectValues };

const object_entries: Native = .{ .name = "entries", .length = 1, .call = objectEntries };

const object_assign: Native = .{ .name = "assign", .length = 2, .call = objectAssign };

const object_create: Native = .{ .name = "create", .length = 2, .call = objectCreate };

const object_get_prototype_of: Native = .{ .name = "getPrototypeOf", .length = 1, .call = objectGetPrototypeOf };

const object_define_property: Native = .{ .name = "defineProperty", .length = 3, .call = objectDefineProperty };

const object_define_properties: Native = .{ .name = "defineProperties", .length = 2, .call = objectDefineProperties };

const object_get_own_property_descriptor: Native = .{ .name = "getOwnPropertyDescriptor", .length = 2, .call = objectGetOwnPropertyDescriptor };

const object_get_own_property_descriptors: Native = .{ .name = "getOwnPropertyDescriptors", .length = 1, .call = objectGetOwnPropertyDescriptors };

const object_get_own_property_symbols: Native = .{ .name = "getOwnPropertySymbols", .length = 1, .call = objectGetOwnPropertySymbols };

const object_get_own_property_names: Native = .{ .name = "getOwnPropertyNames", .length = 1, .call = objectGetOwnPropertyNames };

const object_set_prototype_of: Native = .{ .name = "setPrototypeOf", .length = 2, .call = objectSetPrototypeOf };

const object_prevent_extensions: Native = .{ .name = "preventExtensions", .length = 1, .call = objectPreventExtensions };

const object_is_extensible: Native = .{ .name = "isExtensible", .length = 1, .call = objectIsExtensible };

const object_seal: Native = .{ .name = "seal", .length = 1, .call = objectSeal };

const object_is_sealed: Native = .{ .name = "isSealed", .length = 1, .call = objectIsSealed };

const object_freeze: Native = .{ .name = "freeze", .length = 1, .call = objectFreeze };

const object_is_frozen: Native = .{ .name = "isFrozen", .length = 1, .call = objectIsFrozen };

const object_has_own: Native = .{ .name = "hasOwn", .length = 2, .call = objectHasOwn };

const object_is: Native = .{ .name = "is", .length = 2, .call = objectIs };

const object_from_entries: Native = .{ .name = "fromEntries", .length = 1, .call = objectFromEntries };

const object_group_by: Native = .{ .name = "groupBy", .length = 2, .call = objectGroupBy };

const object_proto_has_own_property: Native = .{ .name = "hasOwnProperty", .length = 1, .call = objectProtoHasOwnProperty };

const object_proto_is_prototype_of: Native = .{ .name = "isPrototypeOf", .length = 1, .call = objectProtoIsPrototypeOf };

const object_proto_property_is_enumerable: Native = .{ .name = "propertyIsEnumerable", .length = 1, .call = objectProtoPropertyIsEnumerable };

fn objectKeys(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    const target = common.arg(args, 0);
    var root_buf = [_]Value{ target, Value.fromObject(out) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    switch (target.unpack()) {
        .undefined, .null => return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }}),
        .boolean, .number, .bigint, .symbol => {},
        .closure, .native => {
            const keys = try proxy_reflect.ownKeysAllValue(rt, target);
            defer rt.gpa.free(keys);
            const key_vals = try rt.gpa.alloc(Value, keys.len);
            defer rt.gpa.free(key_vals);
            for (keys, key_vals) |k, *dst| dst.* = common.keyToRootValue(k);
            var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
            try key_roots.register(rt);
            defer key_roots.unregister(rt);
            for (keys) |k| {
                if (k == .symbol) continue;
                const desc = (try getOwnPropertyRaw(rt, target, k)) orelse continue;
                if (desc.enumerable) try pushKey(rt, out, k);
            }
        },
        .string => |s| for (0..s.units.len) |i| try pushKey(rt, out, .{ .index = @intCast(i) }),
        .object => |o| {
            const keys = try object.ownKeys(rt, o);
            defer rt.gpa.free(keys);
            const key_vals = try rt.gpa.alloc(Value, keys.len);
            defer rt.gpa.free(key_vals);
            for (keys, key_vals) |k, *dst| dst.* = common.keyToRootValue(k);
            var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
            try key_roots.register(rt);
            defer key_roots.unregister(rt);
            for (keys) |k| try pushKey(rt, out, k);
        },
    }
    return Value.fromObject(out);
}

fn pushKey(rt: *Runtime, out: *Object, k: object.Key) Error!void {
    const s = switch (k) {
        .atom => |a| a,
        .index => |i| blk: {
            var buf: [10]u8 = undefined;
            break :blk try rt.heap.ascii(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
        },
        .symbol => unreachable,
    };
    try rt.heap.appendElement(out, Value.fromString(s));
}

fn objectGetOwnPropertySymbols(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const v = common.arg(args, 0);
    if (v.isUndefined() or v.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ v, Value.fromObject(out) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const syms: []*heap_mod.Symbol = switch (v.unpack()) {
        .object => |o| try object.ownSymbolKeys(rt, o, true),
        .closure => |c| try object.ownSymbolKeysClosure(rt, c, true),
        .native => |n| if (try builtins.namespaceObject(rt, n)) |ns| try object.ownSymbolKeys(rt, ns, true) else &.{},
        else => &.{},
    };
    defer rt.gpa.free(syms);
    for (syms) |sym| {
        try rt.heap.appendElement(out, Value.fromSymbol(sym));
    }
    return Value.fromObject(out);
}

fn objectCreate(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const proto: ?*Object = switch (common.arg(args, 0).unpack()) {
        .object => |o| o,
        .null => null,
        // A function is an object in node; ZQJS functions aren't (yet).
        .native, .closure => return rt.fail(.function_properties),
        else => return rt.throw(.TypeError, &.{.{ .ascii = "Object prototype may only be an Object or null" }}),
    };
    const out = try rt.heap.newObject(proto);
    const out_val: Value = Value.fromObject(out);
    if (args.len > 1 and !args[1].isUndefined()) {
        var root_buf = [_]Value{out_val};
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);
        _ = try objectDefineProperties(rt, .undefined, &.{ out_val, args[1] });
    }
    return out_val;
}

fn objectGetPrototypeOf(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const v = common.arg(args, 0);
    return switch (v.unpack()) {
        .undefined, .null => rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }}),
        .boolean => Value.fromObject(r.boolean_prototype),
        .number => Value.fromObject(r.number_prototype),
        .string => Value.fromObject(r.string_prototype),
        .symbol => Value.fromObject(r.symbol_prototype),
        .bigint => Value.fromObject(r.bigint_prototype),
        .native, .closure, .object => object.getPrototypeOfValue(rt, v),
    };
}

pub fn descriptorToObject(rt: *Runtime, p: heap_mod.Property) Error!Value {
    const r = try builtins.realm(rt);
    const out = try rt.heap.newObject(r.object_prototype);
    var root_buf = [_]Value{ Value.fromObject(out), p.value, p.setter };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (p.is_accessor) {
        try rt.heap.storeProperty(out, try rt.heap.internAscii("get"), p.value);
        try rt.heap.storeProperty(out, try rt.heap.internAscii("set"), p.setter);
    } else {
        try rt.heap.storeProperty(out, try rt.heap.internAscii("value"), p.value);
        try rt.heap.storeProperty(out, try rt.heap.internAscii("writable"), Value.fromBool(p.writable));
    }
    try rt.heap.storeProperty(out, try rt.heap.internAscii("enumerable"), Value.fromBool(p.enumerable));
    try rt.heap.storeProperty(out, try rt.heap.internAscii("configurable"), Value.fromBool(p.configurable));
    return Value.fromObject(out);
}

pub fn getOwnPropertyRaw(rt: *Runtime, target: Value, k: object.Key) Error!?heap_mod.Property {
    switch (target.unpack()) {
        .object => |o| {
            switch (o.kind) {
                .array => |elements| switch (k) {
                    .index => |i| return if (i < elements.items.len and !elements.items[i].isHole()) .{
                        .value = elements.items[i],
                        .writable = o.array_elements_writable,
                        .configurable = o.array_elements_configurable,
                    } else null,
                    .atom => if (object.isNamed(k, "length")) {
                        return .{
                            .value = Value.fromNumber(@floatFromInt(elements.items.len)),
                            .enumerable = false,
                            .writable = o.array_length_writable,
                            .configurable = false,
                        };
                    },
                    .symbol => {},
                },
                .regexp => |re| if (object.isNamed(k, "lastIndex")) {
                    return .{
                        .value = re.last_index,
                        .enumerable = false,
                        .writable = o.regexp_last_index_writable,
                        .configurable = false,
                    };
                },
                .module_namespace => |ns| {
                    if (k == .atom) {
                        for (ns.entries) |e| {
                            if (e.name == k.atom) {
                                const v = e.cell.value orelse return rt.throw(.ReferenceError, &.{
                                    .{ .ascii = "Cannot access '" },
                                    .{ .utf16 = e.name.units },
                                    .{ .ascii = "' before initialization" },
                                });
                                return .{ .value = v, .enumerable = true, .writable = true, .configurable = false };
                            }
                        }
                    }
                },
                .typed_array => |ta| {
                    if (object.canonicalNumericIndex(k)) |n| {
                        if (object.validIntegerIndex(ta, n)) |idx| {
                            return .{
                                .value = try object.readTypedArrayElement(rt, ta, idx),
                                .enumerable = true,
                                .writable = true,
                                .configurable = true,
                            };
                        }
                        return null;
                    }
                },
                .proxy => return proxy_reflect.proxyGetOwnPropertyDescriptor(rt, o, k),
                .primitive_wrapper => |pv| if (pv.isString()) {
                    const s = pv.asString();
                    switch (k) {
                        .index => |i| if (i < s.units.len) {
                            const ch = try rt.heap.newString(&.{.{ .utf16 = s.units[i..][0..1] }});
                            return .{ .value = Value.fromString(ch), .writable = false, .configurable = false };
                        },
                        .atom => if (object.isNamed(k, "length")) {
                            return .{ .value = Value.fromNumber(@floatFromInt(s.units.len)), .enumerable = false, .writable = false, .configurable = false };
                        },
                        .symbol => {},
                    }
                },
                .ordinary, .map, .set, .iterator, .promise, .generator, .array_buffer, .data_view, .weak_map, .weak_set, .date => {},
            }
            if (o.props.count() > 0) {
                if (o.props.get(try object.propKey(rt, k))) |p| return p;
            }
            if (o.builtin == .global and k == .atom) {
                return builtins.globalOwnProp(rt, k.atom);
            }
            return null;
        },
        .closure => |c| {
            if (c.meta) |m| if (m.props.count() > 0) {
                if (m.props.get(try object.propKey(rt, k))) |p| return p;
            };
            if (object.isNamed(k, "length") and !(c.meta != null and c.meta.?.length_deleted)) return .{
                .value = Value.fromNumber(@floatFromInt(function_error.closureLength(c))),
                .enumerable = false,
                .writable = false,
                .configurable = if (c.meta) |m| m.length_configurable else true,
            };
            if (object.isNamed(k, "name") and !(c.meta != null and c.meta.?.name_deleted)) return .{
                .value = Value.fromString(try function_error.closureName(rt, c)),
                .enumerable = false,
                .writable = false,
                .configurable = if (c.meta) |m| m.name_configurable else true,
            };
            if (object.isNamed(k, "prototype")) {
                const proto_w = if (c.meta) |m| m.prototype_writable else true;
                if (c.meta) |m| if (m.prototype) |p| {
                    return .{ .value = p, .enumerable = false, .writable = proto_w, .configurable = false };
                };
                if (function_error.hasAutoPrototype(c)) {
                    const p = try function_error.materializeClosurePrototype(rt, @constCast(c));
                    return .{ .value = Value.fromObject(p), .enumerable = false, .writable = proto_w, .configurable = false };
                }
            }
            return null;
        },
        .string => |s| switch (k) {
            .index => |i| if (i < s.units.len) {
                const ch = try rt.heap.newString(&.{.{ .utf16 = s.units[i..][0..1] }});
                return .{ .value = Value.fromString(ch), .writable = false, .configurable = false };
            },
            .atom => if (object.isNamed(k, "length")) {
                return .{ .value = Value.fromNumber(@floatFromInt(s.units.len)), .enumerable = false, .writable = false, .configurable = false };
            },
            .symbol => {},
        },
        .native => |n| {
            if (object.isNamed(k, "length") and !rt.isNativePropDeleted(n, true)) return .{ .value = Value.fromNumber(@floatFromInt(n.length)), .enumerable = false, .writable = false };
            if (object.isNamed(k, "name") and !rt.isNativePropDeleted(n, false)) return .{ .value = Value.fromString(try rt.heap.ascii(n.name)), .enumerable = false, .writable = false };
            if (try builtins.namespaceObject(rt, n)) |ns| return ns.props.get(try object.propKey(rt, k));
        },
        else => {},
    }
    return null;
}

fn objectGetOwnPropertyDescriptor(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = common.arg(args, 0);
    if (target.isUndefined() or target.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const k = try object.key(rt, common.arg(args, 1));
    const p = (try getOwnPropertyRaw(rt, target, k)) orelse return .undefined;
    return descriptorToObject(rt, p);
}

fn objectGetOwnPropertyDescriptors(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = common.arg(args, 0);
    if (target.isUndefined() or target.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const r = try builtins.realm(rt);
    const out = try rt.heap.newObject(r.object_prototype);
    var root_buf = [_]Value{ target, Value.fromObject(out), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (target.isString()) {
        const s = target.asString();
        for (0..s.units.len) |i| {
            const k = try common.indexKey(rt, i);
            if (try getOwnPropertyRaw(rt, target, k)) |p| {
                const desc = try descriptorToObject(rt, p);
                root_buf[2] = desc;
                const pk = try object.propKey(rt, k);
                try rt.heap.definePropKey(out, pk, .{ .value = desc });
                root_buf[2] = .undefined;
            }
        }
        const len_k = try object.named(rt, "length");
        if (try getOwnPropertyRaw(rt, target, len_k)) |p| {
            const desc = try descriptorToObject(rt, p);
            root_buf[2] = desc;
            const pk = try object.propKey(rt, len_k);
            try rt.heap.definePropKey(out, pk, .{ .value = desc });
            root_buf[2] = .undefined;
        }
        return Value.fromObject(out);
    }
    if (target.isObjectLike()) {
        const keys = try proxy_reflect.ownKeysAllValue(rt, target);
        defer rt.gpa.free(keys);
        const key_vals = try rt.gpa.alloc(Value, keys.len);
        defer rt.gpa.free(key_vals);
        for (keys, key_vals) |k, *dst| dst.* = common.keyToRootValue(k);
        var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
        try key_roots.register(rt);
        defer key_roots.unregister(rt);

        for (keys) |k| {
            if (try getOwnPropertyRaw(rt, target, k)) |p| {
                const desc = try descriptorToObject(rt, p);
                root_buf[2] = desc;
                const pk = try object.propKey(rt, k);
                try rt.heap.definePropKey(out, pk, .{ .value = desc });
                root_buf[2] = .undefined;
            }
        }
    }
    return Value.fromObject(out);
}

pub const ParsedDesc = struct {
    has_enum: bool = false,
    enum_val: bool = false,
    has_conf: bool = false,
    conf_val: bool = false,
    has_val: bool = false,
    val: Value = .undefined,
    has_writ: bool = false,
    writ_val: bool = false,
    has_get: bool = false,
    get_val: Value = .undefined,
    has_set: bool = false,
    set_val: Value = .undefined,

    pub fn isData(d: ParsedDesc) bool {
        return d.has_val or d.has_writ;
    }

    pub fn isAccessor(d: ParsedDesc) bool {
        return d.has_get or d.has_set;
    }

    pub fn toCompleteProperty(d: ParsedDesc) heap_mod.Property {
        if (d.isAccessor()) {
            return .{
                .is_accessor = true,
                .value = if (d.has_get) d.get_val else .undefined,
                .setter = if (d.has_set) d.set_val else .undefined,
                .enumerable = if (d.has_enum) d.enum_val else false,
                .configurable = if (d.has_conf) d.conf_val else false,
                .writable = false,
            };
        }
        return .{
            .is_accessor = false,
            .value = if (d.has_val) d.val else .undefined,
            .writable = if (d.has_writ) d.writ_val else false,
            .enumerable = if (d.has_enum) d.enum_val else false,
            .configurable = if (d.has_conf) d.conf_val else false,
        };
    }
};

pub fn parsePropertyDescriptor(rt: *Runtime, desc: Value) Error!ParsedDesc {
    if (!desc.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Property description must be an object" }});
    }
    var out: ParsedDesc = .{};
    var root_buf = [_]Value{ desc, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    out.has_enum = try object.has(rt, .{ .atom = try rt.heap.internAscii("enumerable") }, desc);
    if (out.has_enum) out.enum_val = ops.toBoolean(try object.get(rt, desc, .{ .atom = try rt.heap.internAscii("enumerable") }));
    out.has_conf = try object.has(rt, .{ .atom = try rt.heap.internAscii("configurable") }, desc);
    if (out.has_conf) out.conf_val = ops.toBoolean(try object.get(rt, desc, .{ .atom = try rt.heap.internAscii("configurable") }));

    out.has_val = try object.has(rt, .{ .atom = try rt.heap.internAscii("value") }, desc);
    if (out.has_val) {
        out.val = try object.get(rt, desc, .{ .atom = try rt.heap.internAscii("value") });
        root_buf[1] = out.val;
    }
    out.has_writ = try object.has(rt, .{ .atom = try rt.heap.internAscii("writable") }, desc);
    if (out.has_writ) out.writ_val = ops.toBoolean(try object.get(rt, desc, .{ .atom = try rt.heap.internAscii("writable") }));

    out.has_get = try object.has(rt, .{ .atom = try rt.heap.internAscii("get") }, desc);
    if (out.has_get) {
        out.get_val = try object.get(rt, desc, .{ .atom = try rt.heap.internAscii("get") });
        root_buf[2] = out.get_val;
        if (!out.get_val.isUndefined() and !out.get_val.isFunction()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Getter must be a function" }});
        }
    }

    out.has_set = try object.has(rt, .{ .atom = try rt.heap.internAscii("set") }, desc);
    if (out.has_set) {
        out.set_val = try object.get(rt, desc, .{ .atom = try rt.heap.internAscii("set") });
        root_buf[3] = out.set_val;
        if (!out.set_val.isUndefined() and !out.set_val.isFunction()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Setter must be a function" }});
        }
    }

    if (out.isData() and out.isAccessor()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Invalid property descriptor. Cannot both specify accessors and a value or writable attribute" }});
    }
    return out;
}

fn parsedDescToObject(rt: *Runtime, d: ParsedDesc) Error!Value {
    const r = try builtins.realm(rt);
    const out = try rt.heap.newObject(r.object_prototype);
    var root_buf = [_]Value{ Value.fromObject(out), d.val, d.get_val, d.set_val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (d.has_val) try rt.heap.storeProperty(out, try rt.heap.internAscii("value"), d.val);
    if (d.has_writ) try rt.heap.storeProperty(out, try rt.heap.internAscii("writable"), Value.fromBool(d.writ_val));
    if (d.has_get) try rt.heap.storeProperty(out, try rt.heap.internAscii("get"), d.get_val);
    if (d.has_set) try rt.heap.storeProperty(out, try rt.heap.internAscii("set"), d.set_val);
    if (d.has_enum) try rt.heap.storeProperty(out, try rt.heap.internAscii("enumerable"), Value.fromBool(d.enum_val));
    if (d.has_conf) try rt.heap.storeProperty(out, try rt.heap.internAscii("configurable"), Value.fromBool(d.conf_val));
    return Value.fromObject(out);
}

pub fn isCompatiblePropertyDescriptor(d: ParsedDesc, cur: heap_mod.Property) bool {
    if (!cur.configurable) {
        if (d.has_conf and d.conf_val) return false;
        if (d.has_enum and d.enum_val != cur.enumerable) return false;
    }
    if (!d.isData() and !d.isAccessor()) return true;
    if (cur.is_accessor != d.isAccessor()) {
        if (!cur.configurable) return false;
    } else if (!cur.is_accessor) {
        if (!cur.configurable and !cur.writable) {
            if (d.has_writ and d.writ_val) return false;
            if (d.has_val and !common.sameValue(d.val, cur.value)) return false;
        }
    } else {
        if (!cur.configurable) {
            if (d.has_get and !common.sameValue(d.get_val, cur.value)) return false;
            if (d.has_set and !common.sameValue(d.set_val, cur.setter)) return false;
        }
    }
    return true;
}

pub fn defineOwnPropertyParsed(rt: *Runtime, target: Value, k: object.Key, d: ParsedDesc, throw_on_reject: bool) Error!bool {
    var root_buf = [_]Value{ target, d.val, d.get_val, d.set_val, common.keyToRootValue(k) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (target.isObject() and target.asObject().kind == .proxy) {
        const desc_obj = try parsedDescToObject(rt, d);
        const ok = try proxy_reflect.proxyDefineProperty(rt, target.asObject(), k, d, desc_obj);
        if (!ok and throw_on_reject) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'defineProperty' on proxy: trap returned falsish" }});
        }
        return ok;
    }

    if (target.isObject() and target.asObject().kind == .typed_array) {
        if (object.canonicalNumericIndex(k)) |n| {
            const ta = target.asObject().kind.typed_array;
            if (object.validIntegerIndex(ta, n) == null or
                (d.has_conf and !d.conf_val) or
                (d.has_enum and !d.enum_val) or
                d.isAccessor() or
                (d.has_writ and !d.writ_val))
            {
                if (throw_on_reject) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot redefine property" }});
                return false;
            }
            if (d.has_val) {
                if (ta.kind.isBigInt()) {
                    const b = try ops.toBigInt(rt, d.val);
                    if (object.validIntegerIndex(ta, n)) |idx| {
                        object.writeTypedArrayBigInt(ta, idx, b);
                    }
                } else {
                    const num = try ops.toNumber(rt, d.val);
                    if (object.validIntegerIndex(ta, n)) |idx| {
                        object.writeTypedArrayNumber(ta, idx, num);
                    }
                }
            }
            return true;
        }
    }

    var desc = d;
    if (target.isObject() and target.asObject().kind == .array and k == .atom and object.isNamed(k, "length") and desc.has_val) {
        // ES ArraySetLength: coerce [[Value]] twice before validating against existing length descriptor.
        const new_len = ops.toUint32(try ops.toNumber(rt, desc.val));
        const number_len = try ops.toNumber(rt, desc.val);
        if (@as(f64, @floatFromInt(new_len)) != number_len) {
            return rt.throw(.RangeError, &.{.{ .ascii = "Invalid array length" }});
        }
        desc.val = Value.fromNumber(@floatFromInt(new_len));
        root_buf[1] = desc.val;
    }

    const current = try getOwnPropertyRaw(rt, target, k);
    var next: heap_mod.Property = undefined;

    if (current == null) {
        const extensible = switch (target.unpack()) {
            .object => |o| o.extensible,
            .closure => |c| if (c.meta) |m| m.extensible else true,
            .native => true,
            else => false,
        };
        if (!extensible) {
            if (throw_on_reject) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot define property, object is not extensible" }});
            return false;
        }
        next = desc.toCompleteProperty();
    } else {
        const cur = current.?;
        if (!isCompatiblePropertyDescriptor(desc, cur)) {
            if (throw_on_reject) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot redefine property" }});
            return false;
        }
        if (!desc.isData() and !desc.isAccessor()) {
            next = cur;
        } else if (cur.is_accessor != desc.isAccessor()) {
            if (desc.isAccessor()) {
                next = .{
                    .is_accessor = true,
                    .value = if (desc.has_get) desc.get_val else .undefined,
                    .setter = if (desc.has_set) desc.set_val else .undefined,
                    .enumerable = cur.enumerable,
                    .configurable = cur.configurable,
                    .writable = false,
                };
            } else {
                next = .{
                    .is_accessor = false,
                    .value = if (desc.has_val) desc.val else .undefined,
                    .writable = if (desc.has_writ) desc.writ_val else false,
                    .enumerable = cur.enumerable,
                    .configurable = cur.configurable,
                };
            }
        } else if (!cur.is_accessor) {
            next = .{
                .is_accessor = false,
                .value = if (desc.has_val) desc.val else cur.value,
                .writable = if (desc.has_writ) desc.writ_val else cur.writable,
                .enumerable = if (desc.has_enum) desc.enum_val else cur.enumerable,
                .configurable = if (desc.has_conf) desc.conf_val else cur.configurable,
            };
        } else {
            next = .{
                .is_accessor = true,
                .value = if (desc.has_get) desc.get_val else cur.value,
                .setter = if (desc.has_set) desc.set_val else cur.setter,
                .enumerable = if (desc.has_enum) desc.enum_val else cur.enumerable,
                .configurable = if (desc.has_conf) desc.conf_val else cur.configurable,
                .writable = false,
            };
        }
        if (desc.has_enum) next.enumerable = desc.enum_val;
        if (desc.has_conf) next.configurable = desc.conf_val;
    }

    if (target.isObject() and target.asObject().kind == .array and k == .index) {
        const arr = target.asObject();
        const cur_len = arr.kind.array.items.len;
        if (k.index >= cur_len and !arr.array_length_writable) {
            if (throw_on_reject) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot add property to array with non-writable length" }});
            return false;
        }
        if (k.index >= heap_mod.Heap.MAX_DENSE_ARRAY_LEN) return rt.fail(.sparse_array);
        if (next.is_accessor or !next.enumerable or next.writable != arr.array_elements_writable or next.configurable != arr.array_elements_configurable) {
            return common.unsupportedReceiver(rt, "defineProperty");
        }
        if (k.index < cur_len) {
            if (desc.has_val) rt.heap.storeElement(arr, k.index, next.value) else if (arr.kind.array.items[k.index].isHole()) rt.heap.storeElement(arr, k.index, .undefined);
        } else {
            if (k.index > cur_len) try rt.heap.growElementsWithHoles(arr, k.index);
            try rt.heap.appendElement(arr, next.value);
        }
        return true;
    }

    if (target.isObject() and target.asObject().kind == .array and k == .atom and object.isNamed(k, "length")) {
        const arr = target.asObject();
        const cur_len = arr.kind.array.items.len;
        if (desc.has_val) {
            const new_len: usize = @intFromFloat(next.value.asNumber());
            if (new_len > cur_len) {
                if (new_len > heap_mod.Heap.MAX_DENSE_ARRAY_LEN) return rt.fail(.sparse_array);
                try rt.heap.growElementsWithHoles(arr, new_len);
            } else if (new_len < cur_len) {
                if (!arr.array_elements_configurable) {
                    var keep = cur_len;
                    while (keep > new_len and arr.kind.array.items[keep - 1].isHole()) : (keep -= 1) {}
                    rt.heap.shrinkElements(arr, keep);
                    if (keep > new_len) {
                        if (desc.has_writ and !next.writable) arr.array_length_writable = false;
                        if (throw_on_reject) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property of non-configurable array" }});
                        return false;
                    }
                } else {
                    rt.heap.shrinkElements(arr, new_len);
                }
            }
        }
        if (desc.has_writ and !next.writable) arr.array_length_writable = false;
        return true;
    }
    if (target.isObject() and target.asObject().kind == .regexp and object.isNamed(k, "lastIndex")) {
        if (d.has_val) {
            if (!target.asObject().regexp_last_index_writable and !common.sameValue(next.value, target.asObject().kind.regexp.last_index)) {
                if (throw_on_reject) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot redefine property" }});
                return false;
            }
            rt.heap.storeRegExpLastIndex(target.asObject(), next.value);
        }
        if (d.has_writ and !next.writable) target.asObject().regexp_last_index_writable = false;
        return true;
    }
    if (target.isClosure() and object.isNamed(k, "prototype") and function_error.hasAutoPrototype(target.asClosure())) {
        if (d.has_val) try rt.heap.storeClosurePrototype(@constCast(target.asClosure()), next.value);
        if (d.has_writ and !next.writable) (try rt.heap.ensureClosureMeta(@constCast(target.asClosure()))).prototype_writable = false;
        return true;
    }
    if (target.isClosure() and (object.isNamed(k, "name") or object.isNamed(k, "length"))) {
        const m = try rt.heap.ensureClosureMeta(@constCast(target.asClosure()));
        if (object.isNamed(k, "name")) {
            m.name_configurable = next.configurable;
            m.name_deleted = false;
        } else {
            m.length_configurable = next.configurable;
            m.length_deleted = false;
        }
        const pk = try object.propKey(rt, k);
        try rt.heap.defineClosurePropKey(@constCast(target.asClosure()), pk, next);
        return true;
    }
    if (target.isNative()) {
        const n = target.asNative();
        if (object.isNamed(k, "name") or object.isNamed(k, "length")) {
            const is_len = object.isNamed(k, "length");
            try rt.setNativePropDeleted(n, is_len, false);
            return true;
        }
        if (try builtins.namespaceObject(rt, n)) |ns| {
            const pk = try object.propKey(rt, k);
            try rt.heap.definePropKey(ns, pk, next);
            return true;
        }
        return rt.fail(.function_properties);
    }

    const pk = try object.propKey(rt, k);
    switch (target.unpack()) {
        .object => |o| try rt.heap.definePropKey(o, pk, next),
        .closure => |c| try rt.heap.defineClosurePropKey(@constCast(c), pk, next),
        else => unreachable,
    }
    return true;
}

fn defineOwnPropertyFromDesc(rt: *Runtime, target: Value, k: object.Key, desc: Value) Error!void {
    const parsed = try parsePropertyDescriptor(rt, desc);
    _ = try defineOwnPropertyParsed(rt, target, k, parsed, true);
}

pub fn ordinarySetWithReceiver(rt: *Runtime, receiver: Value, k: object.Key, v: Value, strict: bool) Error!bool {
    var root_buf = [_]Value{ receiver, v, common.keyToRootValue(k) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const existing = try getOwnPropertyRaw(rt, receiver, k);
    if (existing) |ex| {
        if (ex.is_accessor or !ex.writable) {
            if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property" }});
            return false;
        }
        return defineOwnPropertyParsed(rt, receiver, k, .{ .has_val = true, .val = v }, strict);
    }
    return defineOwnPropertyParsed(rt, receiver, k, .{
        .has_val = true,
        .val = v,
        .has_writ = true,
        .writ_val = true,
        .has_enum = true,
        .enum_val = true,
        .has_conf = true,
        .conf_val = true,
    }, strict);
}

fn objectDefineProperty(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = common.arg(args, 0);
    if (!target.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Object.defineProperty called on non-object" }});
    }
    const k = try object.key(rt, common.arg(args, 1));
    try defineOwnPropertyFromDesc(rt, target, k, common.arg(args, 2));
    return target;
}

fn objectDefineProperties(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = common.arg(args, 0);
    if (!target.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Object.defineProperties called on non-object" }});
    }
    const props = common.arg(args, 1);
    if (props.isUndefined() or props.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    var root_buf = [_]Value{ target, props, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const keys: []object.Key = switch (props.unpack()) {
        .object => |o| try object.ownAllKeys(rt, o),
        .closure => |c| try object.ownAllKeysClosure(rt, c),
        .string => |s| blk: {
            if (s.units.len > 0) return rt.throw(.TypeError, &.{.{ .ascii = "Property description must be an object" }});
            break :blk &.{};
        },
        else => &.{},
    };
    defer rt.gpa.free(keys);
    if (keys.len > 0) {
        const key_vals = try rt.gpa.alloc(Value, keys.len);
        defer rt.gpa.free(key_vals);
        for (keys, key_vals) |k, *dst| dst.* = common.keyToRootValue(k);
        var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
        try key_roots.register(rt);
        defer key_roots.unregister(rt);

        for (keys) |k| {
            const desc = try object.get(rt, props, k);
            root_buf[2] = desc;
            try defineOwnPropertyFromDesc(rt, target, k, desc);
            root_buf[2] = .undefined;
        }
    }
    return target;
}

fn ownKeyValue(rt: *Runtime, o: *Object, k: object.Key) Error!Value {
    if (o.kind == .array and k == .index) return o.kind.array.items[k.index];
    return object.get(rt, Value.fromObject(o), k);
}

fn objectValuesEntriesImpl(rt: *Runtime, args: []const Value, comptime is_entries: bool) Error!Value {
    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    const target = common.arg(args, 0);
    var root_buf = [_]Value{ target, Value.fromObject(out), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    switch (target.unpack()) {
        .undefined, .null => return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }}),
        .boolean, .number, .bigint, .symbol => {},
        .string => |s| for (0..s.units.len) |i| {
            const ch = try rt.heap.newString(&.{.{ .utf16 = s.units[i .. i + 1] }});
            root_buf[2] = Value.fromString(ch);
            if (is_entries) {
                const key_s = try common.keyToString(rt, try common.indexKey(rt, i));
                root_buf[3] = Value.fromString(key_s);
                const pair = try iterator.makePairArray(rt, root_buf[3], root_buf[2]);
                root_buf[2] = pair;
                try rt.heap.appendElement(out, pair);
            } else {
                try rt.heap.appendElement(out, root_buf[2]);
            }
            root_buf[2] = .undefined;
            root_buf[3] = .undefined;
        },
        .object, .closure, .native => {
            const keys = try proxy_reflect.ownKeysAllValue(rt, target);
            defer rt.gpa.free(keys);
            const key_vals = try rt.gpa.alloc(Value, keys.len);
            defer rt.gpa.free(key_vals);
            for (keys, key_vals) |k, *dst| dst.* = common.keyToRootValue(k);
            var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
            try key_roots.register(rt);
            defer key_roots.unregister(rt);

            for (keys) |k| {
                if (k == .symbol) continue;
                const desc = (try getOwnPropertyRaw(rt, target, k)) orelse continue;
                if (!desc.enumerable) continue;
                const val = if (target.isObject() and target.asObject().kind == .array and k == .index and k.index < target.asObject().kind.array.items.len and !target.asObject().kind.array.items[k.index].isHole())
                    target.asObject().kind.array.items[k.index]
                else
                    try object.get(rt, target, k);
                if (is_entries) {
                    root_buf[3] = val;
                    const key_s = try common.keyToString(rt, k);
                    root_buf[2] = Value.fromString(key_s);
                    const pair = try iterator.makePairArray(rt, root_buf[2], root_buf[3]);
                    root_buf[2] = pair;
                    try rt.heap.appendElement(out, pair);
                    root_buf[2] = .undefined;
                    root_buf[3] = .undefined;
                } else {
                    try rt.heap.appendElement(out, val);
                }
            }
        },
    }
    return Value.fromObject(out);
}

fn objectValues(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return objectValuesEntriesImpl(rt, args, false);
}

fn objectEntries(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return objectValuesEntriesImpl(rt, args, true);
}

fn objectAssign(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target_in = common.arg(args, 0);
    if (target_in.isUndefined() or target_in.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    if (target_in.isNative()) return rt.fail(.function_properties);
    const target = if (target_in.isObjectLike()) target_in else try objectConstruct(rt, &.{target_in});
    if (args.len <= 1) return target;

    var root_buf = [_]Value{ target, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (args[1..]) |src| {
        root_buf[1] = src;
        switch (src.unpack()) {
            .undefined, .null, .boolean, .number, .bigint, .symbol, .native => {},
            .closure => |c| {
                const keys = try object.ownAllKeysClosure(rt, c);
                defer rt.gpa.free(keys);
                const key_vals = try rt.gpa.alloc(Value, keys.len);
                defer rt.gpa.free(key_vals);
                for (keys, key_vals) |k, *dst| dst.* = common.keyToRootValue(k);
                var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
                try key_roots.register(rt);
                defer key_roots.unregister(rt);
                for (keys) |k| {
                    const val = try object.get(rt, src, k);
                    root_buf[2] = val;
                    try object.setStrict(rt, target, k, val);
                    root_buf[2] = .undefined;
                }
            },
            .string => |s| for (0..s.units.len) |i| {
                const ch = try rt.heap.newString(&.{.{ .utf16 = s.units[i .. i + 1] }});
                root_buf[2] = Value.fromString(ch);
                try object.setStrict(rt, target, .{ .index = @intCast(i) }, root_buf[2]);
                root_buf[2] = .undefined;
            },
            .object => |src_obj| {
                const keys = try object.ownAllKeys(rt, src_obj);
                defer rt.gpa.free(keys);
                const key_vals = try rt.gpa.alloc(Value, keys.len);
                defer rt.gpa.free(key_vals);
                for (keys, key_vals) |k, *dst| dst.* = common.keyToRootValue(k);
                var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
                try key_roots.register(rt);
                defer key_roots.unregister(rt);
                for (keys) |k| {
                    const val = try ownKeyValue(rt, src_obj, k);
                    root_buf[2] = val;
                    try object.setStrict(rt, target, k, val);
                    root_buf[2] = .undefined;
                }
            },
        }
        root_buf[1] = .undefined;
    }
    return target;
}

pub fn setPrototypeOfValue(rt: *Runtime, target: Value, proto: Value) Error!bool {
    switch (proto.unpack()) {
        .object, .null => {},
        .native, .closure => return rt.fail(.function_properties),
        else => return rt.throw(.TypeError, &.{.{ .ascii = "Object prototype may only be an Object or null" }}),
    }
    const r = try builtins.realm(rt);
    if (target.isObject() and target.asObject() == r.object_prototype) {
        return proto.isNull();
    }
    switch (target.unpack()) {
        .object => |o| if (o.kind == .proxy) return proxy_reflect.proxySetPrototypeOf(rt, o, proto),
        .closure => {},
        .native => return rt.fail(.function_properties),
        else => return true,
    }
    const cur_proto = try object.getPrototypeOfValue(rt, target);
    if (common.sameValue(proto, cur_proto)) return true;

    const extensible = switch (target.unpack()) {
        .object => |o| o.extensible,
        .closure => |c| if (c.meta) |m| m.extensible else true,
        else => unreachable,
    };
    if (!extensible) return false;

    var p = proto;
    while (!p.isNull()) {
        if (common.sameValue(p, target)) return false;
        if (p.isObject() and p.asObject().kind == .proxy) break;
        p = try object.getPrototypeOfValue(rt, p);
    }

    switch (target.unpack()) {
        .object => |o| rt.heap.storeObjectProto(o, if (proto.isNull()) null else proto.asObject()),
        .closure => |c| try rt.heap.storeClosureProto(@constCast(c), proto),
        else => unreachable,
    }
    return true;
}

fn objectSetPrototypeOf(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = common.arg(args, 0);
    const proto = common.arg(args, 1);
    if (target.isUndefined() or target.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    if (!try setPrototypeOfValue(rt, target, proto)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Object.setPrototypeOf failed" }});
    }
    return target;
}

pub fn preventExtensionsValue(rt: *Runtime, target: Value) Error!bool {
    switch (target.unpack()) {
        .object => |o| {
            if (o.kind == .proxy) return proxy_reflect.proxyPreventExtensions(rt, o);
            o.extensible = false;
        },
        .closure => |c| (try rt.heap.ensureClosureMeta(@constCast(c))).extensible = false,
        .native => return rt.fail(.function_properties),
        else => {},
    }
    return true;
}

fn objectPreventExtensions(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = common.arg(args, 0);
    if (!try preventExtensionsValue(rt, target)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot prevent extensions" }});
    }
    return target;
}

pub fn isExtensibleValue(rt: *Runtime, target: Value) Error!bool {
    return switch (target.unpack()) {
        .object => |o| if (o.kind == .proxy) proxy_reflect.proxyIsExtensible(rt, o) else o.extensible,
        .closure => |c| if (c.meta) |m| m.extensible else true,
        .native => true,
        else => false,
    };
}

fn objectIsExtensible(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(try isExtensibleValue(rt, common.arg(args, 0)));
}

fn setIntegrityLevel(rt: *Runtime, target: Value, freeze: bool) Error!Value {
    switch (target.unpack()) {
        .object => |o| {
            if (o.kind == .proxy) {
                if (!try preventExtensionsValue(rt, target)) {
                    return rt.throw(.TypeError, &.{.{ .ascii = "Cannot prevent extensions" }});
                }
                var root_buf = [_]Value{target};
                var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
                try roots.register(rt);
                defer roots.unregister(rt);

                const keys = try proxy_reflect.ownKeysAllValue(rt, target);
                defer rt.gpa.free(keys);
                const key_vals = try rt.gpa.alloc(Value, keys.len);
                defer rt.gpa.free(key_vals);
                for (keys, key_vals) |k, *dst| dst.* = common.keyToRootValue(k);
                var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
                try key_roots.register(rt);
                defer key_roots.unregister(rt);

                for (keys) |k| {
                    const desc = try getOwnPropertyRaw(rt, target, k);
                    if (desc) |d| {
                        var pd: ParsedDesc = .{ .has_conf = true, .conf_val = false };
                        if (freeze and !d.is_accessor) {
                            pd.has_writ = true;
                            pd.writ_val = false;
                        }
                        _ = try defineOwnPropertyParsed(rt, target, k, pd, true);
                    }
                }
                return target;
            }
            o.extensible = false;
            if (o.props.count() > 0) {
                try rt.heap.toDictionary(o);
                for (o.props.dict.values()) |*p| {
                    p.configurable = false;
                    if (freeze and !p.is_accessor) p.writable = false;
                }
            }
            switch (o.kind) {
                .array => {
                    o.array_elements_configurable = false;
                    if (freeze) {
                        o.array_elements_writable = false;
                        o.array_length_writable = false;
                    }
                },
                .regexp => if (freeze) {
                    o.regexp_last_index_writable = false;
                },
                .typed_array => |ta| if (ta.length > 0) {
                    return rt.throw(.TypeError, &.{.{ .ascii = "Cannot freeze array buffer views with elements" }});
                },
                else => {},
            }
        },
        .closure => |c| {
            const m = try rt.heap.ensureClosureMeta(@constCast(c));
            m.extensible = false;
            m.name_configurable = false;
            m.length_configurable = false;
            if (freeze) m.prototype_writable = false;
            for (m.props.values()) |*p| {
                p.configurable = false;
                if (freeze and !p.is_accessor) p.writable = false;
            }
        },
        .native => return rt.fail(.function_properties),
        else => {},
    }
    return target;
}

fn testIntegrityLevel(rt: *Runtime, target: Value, freeze: bool) Error!bool {
    return switch (target.unpack()) {
        .object => |o| {
            if (o.kind == .proxy) {
                if (try isExtensibleValue(rt, target)) return false;
                var root_buf = [_]Value{target};
                var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
                try roots.register(rt);
                defer roots.unregister(rt);

                const keys = try proxy_reflect.ownKeysAllValue(rt, target);
                defer rt.gpa.free(keys);
                const key_vals = try rt.gpa.alloc(Value, keys.len);
                defer rt.gpa.free(key_vals);
                for (keys, key_vals) |k, *dst| dst.* = common.keyToRootValue(k);
                var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
                try key_roots.register(rt);
                defer key_roots.unregister(rt);

                for (keys) |k| {
                    if (try getOwnPropertyRaw(rt, target, k)) |d| {
                        if (d.configurable) return false;
                        if (freeze and !d.is_accessor and d.writable) return false;
                    }
                }
                return true;
            }
            if (o.extensible) return false;
            var pit = o.props.iterator();
            while (pit.next()) |entry| {
                const p = entry.value_ptr.*;
                if (p.configurable) return false;
                if (freeze and !p.is_accessor and p.writable) return false;
            }
            switch (o.kind) {
                .array => |elements| {
                    if (elements.items.len > 0) {
                        if (o.array_elements_configurable) return false;
                        if (freeze and o.array_elements_writable) return false;
                    }
                    if (freeze and o.array_length_writable) return false;
                },
                .regexp => if (freeze and o.regexp_last_index_writable) return false,
                .typed_array => |ta| if (freeze and ta.length > 0) return false,
                else => {},
            }
            return true;
        },
        .closure => |c| {
            const m = c.meta orelse return false;
            if (m.extensible) return false;
            if (m.name_configurable or m.length_configurable) return false;
            if (freeze and function_error.hasAutoPrototype(c) and m.prototype_writable) return false;
            for (m.props.values()) |p| {
                if (p.configurable) return false;
                if (freeze and !p.is_accessor and p.writable) return false;
            }
            return true;
        },
        .native => return false,
        else => true,
    };
}

fn objectSeal(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return setIntegrityLevel(rt, common.arg(args, 0), false);
}

fn objectIsSealed(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(try testIntegrityLevel(rt, common.arg(args, 0), false));
}

fn objectFreeze(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return setIntegrityLevel(rt, common.arg(args, 0), true);
}

fn objectIsFrozen(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(try testIntegrityLevel(rt, common.arg(args, 0), true));
}

fn objectHasOwn(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = common.arg(args, 0);
    if (target.isUndefined() or target.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const k = try object.key(rt, common.arg(args, 1));
    return Value.fromBool(try object.hasOwn(rt, target, k));
}

fn objectIs(_: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(common.sameValue(common.arg(args, 0), common.arg(args, 1)));
}

fn objectGetOwnPropertyNames(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = common.arg(args, 0);
    if (target.isUndefined() or target.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ target, Value.fromObject(out) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    switch (target.unpack()) {
        .object => |o| {
            if (o.kind == .proxy) {
                const keys = try object.ownPropertyNames(rt, o);
                defer rt.gpa.free(keys);
                const key_vals = try rt.gpa.alloc(Value, keys.len);
                defer rt.gpa.free(key_vals);
                for (keys, key_vals) |k, *dst| dst.* = common.keyToRootValue(k);
                var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
                try key_roots.register(rt);
                defer key_roots.unregister(rt);
                for (keys) |k| {
                    const s = try common.keyToString(rt, k);
                    try rt.heap.appendElement(out, Value.fromString(s));
                }
            } else {
                const keys = try object.ownPropertyNames(rt, o);
                defer rt.gpa.free(keys);
                var idx_end: usize = 0;
                while (idx_end < keys.len and keys[idx_end] == .index) : (idx_end += 1) {}
                for (keys[0..idx_end]) |k| {
                    const s = try common.keyToString(rt, k);
                    try rt.heap.appendElement(out, Value.fromString(s));
                }
                const is_str_wrap = o.kind == .primitive_wrapper and o.kind.primitive_wrapper.isString();
                if (o.kind == .array or is_str_wrap) {
                    try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("length")));
                } else if (o.kind == .regexp) {
                    try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("lastIndex")));
                }
                for (keys[idx_end..]) |k| {
                    if (is_str_wrap and object.isNamed(k, "length")) continue;
                    const s = try common.keyToString(rt, k);
                    try rt.heap.appendElement(out, Value.fromString(s));
                }
            }
        },
        .closure => |c| {
            const keys = try object.ownPropertyNamesClosure(rt, c);
            defer rt.gpa.free(keys);
            var idx_end: usize = 0;
            while (idx_end < keys.len and keys[idx_end] == .index) : (idx_end += 1) {}
            for (keys[0..idx_end]) |k| {
                const s = try common.keyToString(rt, k);
                try rt.heap.appendElement(out, Value.fromString(s));
            }
            if (!(c.meta != null and c.meta.?.length_deleted)) {
                try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("length")));
            }
            if (!(c.meta != null and c.meta.?.name_deleted)) {
                try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("name")));
            }
            if (function_error.hasAutoPrototype(c)) {
                try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("prototype")));
            }
            for (keys[idx_end..]) |k| {
                if ((object.isNamed(k, "length") and !(c.meta != null and c.meta.?.length_deleted)) or
                    (object.isNamed(k, "name") and !(c.meta != null and c.meta.?.name_deleted))) continue;
                const s = try common.keyToString(rt, k);
                try rt.heap.appendElement(out, Value.fromString(s));
            }
        },
        .native => |n| {
            if (!rt.isNativePropDeleted(n, true)) {
                try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("length")));
            }
            if (!rt.isNativePropDeleted(n, false)) {
                try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("name")));
            }
            if (try builtins.namespaceObject(rt, n)) |ns| {
                const keys = try object.ownPropertyNames(rt, ns);
                defer rt.gpa.free(keys);
                for (keys) |k| {
                    if ((object.isNamed(k, "length") and !rt.isNativePropDeleted(n, true)) or
                        (object.isNamed(k, "name") and !rt.isNativePropDeleted(n, false))) continue;
                    const s = try common.keyToString(rt, k);
                    try rt.heap.appendElement(out, Value.fromString(s));
                }
            }
        },
        .string => |s| {
            for (0..s.units.len) |i| {
                try rt.heap.appendElement(out, Value.fromString(try common.keyToString(rt, try common.indexKey(rt, i))));
            }
            try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("length")));
        },
        else => {},
    }
    return Value.fromObject(out);
}

fn objectFromEntries(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const iterable = common.arg(args, 0);
    const r = try builtins.realm(rt);
    const out = try rt.heap.newObject(r.object_prototype);
    const iter = try iterator.getIterator(rt, iterable);
    var root_buf = [_]Value{ Value.fromObject(out), Value.fromObject(iter), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    while (try iterator.iteratorNextVal(rt, iter)) |item| {
        root_buf[2] = item;
        if (!item.isObject() and !item.isClosure() and !item.isNative()) {
            try iterator.iteratorClose(rt, iter, false);
            return rt.throw(.TypeError, &.{.{ .ascii = "Iterator value is not an entry object" }});
        }
        const k_val = object.get(rt, item, .{ .index = 0 }) catch |e| {
            iterator.iteratorClose(rt, iter, true) catch {};
            return e;
        };
        root_buf[3] = k_val;
        const v_val = object.get(rt, item, .{ .index = 1 }) catch |e| {
            iterator.iteratorClose(rt, iter, true) catch {};
            return e;
        };
        const k = object.key(rt, k_val) catch |e| {
            iterator.iteratorClose(rt, iter, true) catch {};
            return e;
        };
        try object.definePublicField(rt, Value.fromObject(out), k, v_val);
        root_buf[2] = .undefined;
        root_buf[3] = .undefined;
    }
    return Value.fromObject(out);
}

fn objectGroupBy(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const iterable = common.arg(args, 0);
    const cb = try common.requireCallable(rt, common.arg(args, 1));
    var root_buf = [_]Value{ iterable, cb, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const iter = try iterator.getIterator(rt, iterable);
    root_buf[2] = Value.fromObject(iter);
    const r = try builtins.realm(rt);
    const out = try rt.heap.newObject(null);
    root_buf[0] = Value.fromObject(out);

    var idx: usize = 0;
    while (try iterator.iteratorNextVal(rt, iter)) |item| : (idx += 1) {
        root_buf[3] = item;
        const raw_key = rt.callCallable(cb, .undefined, &.{ item, Value.fromNumber(@floatFromInt(idx)) }) catch |e| {
            if (e == error.Thrown) try iterator.iteratorClose(rt, iter, true);
            return e;
        };
        root_buf[4] = raw_key;
        const k = object.key(rt, raw_key) catch |e| {
            if (e == error.Thrown) try iterator.iteratorClose(rt, iter, true);
            return e;
        };
        const group_arr: *Object = blk: {
            if (try object.ownProp(rt, out, k)) |p| {
                break :blk p.value.asObject();
            }
            const arr = try rt.heap.newArray(r.array_prototype);
            root_buf[5] = Value.fromObject(arr);
            try object.definePublicField(rt, Value.fromObject(out), k, Value.fromObject(arr));
            break :blk arr;
        };
        try rt.heap.appendElement(group_arr, item);
        root_buf[3] = .undefined;
        root_buf[4] = .undefined;
        root_buf[5] = .undefined;
    }
    return Value.fromObject(out);
}

fn objectProtoHasOwnProperty(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const k = try object.key(rt, common.arg(args, 0));
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    return Value.fromBool(try object.hasOwn(rt, this, k));
}

fn objectProtoIsPrototypeOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const v = common.arg(args, 0);
    if (!v.isObject() and !v.isClosure() and !v.isNative()) return Value.fromBool(false);
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    var cur = try object.getPrototypeOfValue(rt, v);
    while (!cur.isNull()) {
        if (common.sameValue(cur, this)) return Value.fromBool(true);
        cur = try object.getPrototypeOfValue(rt, cur);
    }
    return Value.fromBool(false);
}

fn objectProtoPropertyIsEnumerable(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const k = try object.key(rt, common.arg(args, 0));
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const desc = (try getOwnPropertyRaw(rt, this, k)) orelse return Value.fromBool(false);
    return Value.fromBool(desc.enumerable);
}

/// Builds a `for...in` iterator over `target`'s own and inherited enumerable string keys (D69).
pub fn forInInit(rt: *Runtime, target: Value) Error!*Object {
    const keys_arr = try rt.heap.newArray(null);
    var root_buf = [_]Value{ target, Value.fromObject(keys_arr) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    switch (target.unpack()) {
        .undefined, .null, .boolean, .number, .bigint, .symbol => return rt.heap.newForInIterator(target, keys_arr),
        .string => |s| {
            for (0..s.units.len) |i| {
                try rt.heap.appendElement(keys_arr, Value.fromString(try common.keyToString(rt, .{ .index = @intCast(i) })));
            }
            return rt.heap.newForInIterator(target, keys_arr);
        },
        .object, .closure, .native => {},
    }

    var seen: std.AutoHashMapUnmanaged(*heap_mod.String, void) = .empty;
    defer seen.deinit(rt.gpa);

    var cur: Value = target;
    var cur_root = [_]Value{cur};
    var cur_roots: rt_mod.ValueRoots = .{ .values = &cur_root };
    try cur_roots.register(rt);
    defer cur_roots.unregister(rt);

    while (!cur.isNull()) {
        cur_root[0] = cur;
        switch (cur.unpack()) {
            .object => |o| {
                const keys = try object.ownPropertyNames(rt, o);
                defer rt.gpa.free(keys);
                const key_vals = try rt.gpa.alloc(Value, keys.len);
                defer rt.gpa.free(key_vals);
                for (keys, key_vals) |k, *dst| dst.* = common.keyToRootValue(k);
                var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
                try key_roots.register(rt);
                defer key_roots.unregister(rt);
                for (keys) |k| {
                    const atom = try object.atomOf(rt, k);
                    const gop = try seen.getOrPut(rt.gpa, atom);
                    if (gop.found_existing) continue;
                    const desc = (try getOwnPropertyRaw(rt, cur, k)) orelse continue;
                    if (desc.enumerable) {
                        try rt.heap.appendElement(keys_arr, Value.fromString(atom));
                    }
                }
            },
            .closure => |c| {
                const keys = try object.ownPropertyNamesClosure(rt, c);
                defer rt.gpa.free(keys);
                const key_vals = try rt.gpa.alloc(Value, keys.len);
                defer rt.gpa.free(key_vals);
                for (keys, key_vals) |k, *dst| dst.* = common.keyToRootValue(k);
                var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
                try key_roots.register(rt);
                defer key_roots.unregister(rt);
                for (keys) |k| {
                    const atom = try object.atomOf(rt, k);
                    const gop = try seen.getOrPut(rt.gpa, atom);
                    if (gop.found_existing) continue;
                    const desc = (try getOwnPropertyRaw(rt, cur, k)) orelse continue;
                    if (desc.enumerable) {
                        try rt.heap.appendElement(keys_arr, Value.fromString(atom));
                    }
                }
            },
            else => {},
        }
        cur = try object.getPrototypeOfValue(rt, cur);
    }

    return rt.heap.newForInIterator(target, keys_arr);
}

/// Returns the next still-present enumerable key for a `for...in` iterator, or `null` when done (D69).
pub fn forInNext(rt: *Runtime, iter: *Object) Error!?Value {
    var root_buf = [_]Value{ Value.fromObject(iter), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const it = &iter.kind.iterator;
    while (it.cursor < it.next_method.asObject().kind.array.items.len) {
        const key_str = it.next_method.asObject().kind.array.items[it.cursor].asString();
        it.cursor += 1;
        if (it.target.isString()) return Value.fromString(key_str);
        const k: object.Key = if (key_str.atom.?.index) |idx| .{ .index = idx } else .{ .atom = @constCast(key_str) };
        var cur: Value = it.target;
        while (!cur.isNull()) {
            root_buf[1] = cur;
            if (try getOwnPropertyRaw(rt, cur, k)) |desc| {
                if (desc.enumerable) return Value.fromString(key_str);
                break; // shadowed by non-enumerable property
            }
            cur = try object.getPrototypeOfValue(rt, cur);
        }
    }
    return null;
}

pub fn objectCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return objectConstruct(rt, args);
}

pub fn objectConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const v = common.arg(args, 0);
    const r = try builtins.realm(rt);
    return switch (v.unpack()) {
        .undefined, .null => Value.fromObject(try rt.heap.newObject(r.object_prototype)),
        .object, .closure, .native => v,
        .boolean => Value.fromObject(try rt.heap.newPrimitiveWrapper(r.boolean_prototype, v)),
        .number => Value.fromObject(try rt.heap.newPrimitiveWrapper(r.number_prototype, v)),
        .string => Value.fromObject(try rt.heap.newPrimitiveWrapper(r.string_prototype, v)),
        .symbol => Value.fromObject(try rt.heap.newPrimitiveWrapper(r.symbol_prototype, v)),
        .bigint => Value.fromObject(try rt.heap.newPrimitiveWrapper(r.bigint_prototype, v)),
    };
}
