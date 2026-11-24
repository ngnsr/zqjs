//! Proxy and Reflect built-ins.

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

pub fn register(rt: *Runtime, r: *const builtins.Realm) Error!void {
    try common.method(rt, r.proxy_namespace, "revocable", &proxy_revocable);
    try common.defineToStringTag(rt, r.reflect, r.sym_to_string_tag, "Reflect");
    try common.method(rt, r.reflect, "get", &reflect_get);
    try common.method(rt, r.reflect, "set", &reflect_set);
    try common.method(rt, r.reflect, "has", &reflect_has);
    try common.method(rt, r.reflect, "deleteProperty", &reflect_delete_property);
    try common.method(rt, r.reflect, "ownKeys", &reflect_own_keys);
    try common.method(rt, r.reflect, "getOwnPropertyDescriptor", &reflect_get_own_property_descriptor);
    try common.method(rt, r.reflect, "defineProperty", &reflect_define_property);
    try common.method(rt, r.reflect, "getPrototypeOf", &reflect_get_prototype_of);
    try common.method(rt, r.reflect, "setPrototypeOf", &reflect_set_prototype_of);
    try common.method(rt, r.reflect, "isExtensible", &reflect_is_extensible);
    try common.method(rt, r.reflect, "preventExtensions", &reflect_prevent_extensions);
    try common.method(rt, r.reflect, "apply", &reflect_apply);
    try common.method(rt, r.reflect, "construct", &reflect_construct);
}

const proxy_revocable: Native = .{ .name = "revocable", .length = 2, .call = proxyRevocable };

const reflect_get: Native = .{ .name = "get", .length = 2, .call = reflectGet };

const reflect_set: Native = .{ .name = "set", .length = 3, .call = reflectSet };

const reflect_has: Native = .{ .name = "has", .length = 2, .call = reflectHas };

const reflect_delete_property: Native = .{ .name = "deleteProperty", .length = 2, .call = reflectDeleteProperty };

const reflect_own_keys: Native = .{ .name = "ownKeys", .length = 1, .call = reflectOwnKeys };

const reflect_get_own_property_descriptor: Native = .{ .name = "getOwnPropertyDescriptor", .length = 2, .call = reflectGetOwnPropertyDescriptor };

const reflect_define_property: Native = .{ .name = "defineProperty", .length = 3, .call = reflectDefineProperty };

const reflect_get_prototype_of: Native = .{ .name = "getPrototypeOf", .length = 1, .call = reflectGetPrototypeOf };

const reflect_set_prototype_of: Native = .{ .name = "setPrototypeOf", .length = 2, .call = reflectSetPrototypeOf };

const reflect_is_extensible: Native = .{ .name = "isExtensible", .length = 1, .call = reflectIsExtensible };

const reflect_prevent_extensions: Native = .{ .name = "preventExtensions", .length = 1, .call = reflectPreventExtensions };

const reflect_apply: Native = .{ .name = "apply", .length = 3, .call = reflectApply };

const reflect_construct: Native = .{ .name = "construct", .length = 2, .call = reflectConstruct };

pub fn proxyCallThrow(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor Proxy requires 'new'" }});
}

pub fn proxyConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const target = common.arg(args, 0);
    const handler = common.arg(args, 1);
    if (!target.isObjectLike() or !handler.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot create proxy with a non-object as target or handler" }});
    }
    if (target.isObject() and target.asObject().kind == .proxy and target.asObject().kind.proxy.target == null) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot create proxy with a revoked proxy as target" }});
    }
    if (handler.isObject() and handler.asObject().kind == .proxy and handler.asObject().kind.proxy.target == null) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot create proxy with a revoked proxy as handler" }});
    }
    const is_callable = target.isFunction();
    const is_constructable = function_error.isConstructor(target);
    const px = try rt.heap.newProxy(null, target, handler, is_callable, is_constructable);
    return Value.fromObject(px);
}

fn proxyRevokeFn(rt: *Runtime, env: *Object, _: []const Value) Error!Value {
    const k = try rt.heap.internAscii("p");
    const pk = heap_mod.PropKey.fromAtom(k);
    if (env.props.get(pk)) |prop| {
        if (prop.value.isObject() and prop.value.asObject().kind == .proxy) {
            heap_mod.Heap.revokeProxy(prop.value.asObject());
        }
        try rt.heap.removePropKey(env, pk);
    }
    return .undefined;
}

fn proxyRevocable(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const px_val = try proxyConstruct(rt, args);
    const r = try builtins.realm(rt);
    var root_buf = [_]Value{ px_val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const env = try rt.heap.newObject(null);
    root_buf[1] = Value.fromObject(env);
    try rt.heap.storeProperty(env, try rt.heap.internAscii("p"), px_val);
    const revoke_fn = try rt.heap.newNativeClosure(@ptrCast(&proxyRevokeFn), env);
    root_buf[2] = Value.fromClosure(revoke_fn);

    const out = try rt.heap.newObject(r.object_prototype);
    try rt.heap.storeProperty(out, try rt.heap.internAscii("proxy"), px_val);
    try rt.heap.storeProperty(out, try rt.heap.internAscii("revoke"), Value.fromClosure(revoke_fn));
    return Value.fromObject(out);
}

const ProxyTrap = struct {
    target: Value,
    handler: Value,
    trap: ?Value,
};

fn getProxyTrap(rt: *Runtime, px_obj: *Object, trap_name: []const u8) Error!ProxyTrap {
    try rt.checkNativeStack();
    const px = px_obj.kind.proxy;
    const target = px.target orelse return rt.throw(.TypeError, &.{ .{ .ascii = "Cannot perform '" }, .{ .ascii = trap_name }, .{ .ascii = "' on a proxy that has been revoked" } });
    const handler = px.handler orelse return rt.throw(.TypeError, &.{ .{ .ascii = "Cannot perform '" }, .{ .ascii = trap_name }, .{ .ascii = "' on a proxy that has been revoked" } });
    var root_buf = [_]Value{ target, handler };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const trap = try object.getMethod(rt, handler, try object.named(rt, trap_name));
    return .{ .target = target, .handler = handler, .trap = trap };
}

pub fn proxyGet(rt: *Runtime, px_obj: *Object, k: object.Key, receiver: Value) Error!Value {
    var root_buf = [_]Value{ Value.fromObject(px_obj), receiver, common.keyToRootValue(k), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "get");
    if (t.trap == null) return object.getWithReceiver(rt, t.target, receiver, k);
    const prop_val = try common.keyToValue(rt, k);
    root_buf[3] = t.target;
    root_buf[4] = t.handler;
    root_buf[5] = prop_val;

    const trap_res = try rt.callCallable(t.trap.?, t.handler, &.{ t.target, prop_val, receiver });
    root_buf[4] = trap_res;

    if (try obj_builtins.getOwnPropertyRaw(rt, t.target, k)) |td| {
        if (!td.configurable) {
            if (!td.is_accessor and !td.writable and !common.sameValue(trap_res, td.value)) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'get' on proxy: property is a read-only and non-configurable data property on the proxy target but the proxy did not return its actual value" }});
            }
            if (td.is_accessor and td.value.isUndefined() and !trap_res.isUndefined()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'get' on proxy: property is a non-configurable accessor without a getter on the proxy target but the proxy did not return undefined" }});
            }
        }
    }
    return trap_res;
}

pub fn proxySet(rt: *Runtime, px_obj: *Object, k: object.Key, v: Value, receiver: Value) Error!bool {
    var root_buf = [_]Value{ Value.fromObject(px_obj), v, receiver, common.keyToRootValue(k), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "set");
    if (t.trap == null) return object.setWithReceiver(rt, t.target, k, v, receiver, false);
    const prop_val = try common.keyToValue(rt, k);
    root_buf[4] = t.target;
    root_buf[5] = t.handler;
    root_buf[6] = prop_val;

    const trap_res = ops.toBoolean(try rt.callCallable(t.trap.?, t.handler, &.{ t.target, prop_val, v, receiver }));
    if (!trap_res) return false;

    if (try obj_builtins.getOwnPropertyRaw(rt, t.target, k)) |td| {
        if (!td.configurable) {
            if (!td.is_accessor and !td.writable and !common.sameValue(v, td.value)) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'set' on proxy: trap returned truish for property which exists in the proxy target as a non-configurable and non-writable data property with a different value" }});
            }
            if (td.is_accessor and td.setter.isUndefined()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'set' on proxy: trap returned truish for property which exists in the proxy target as a non-configurable accessor without a setter" }});
            }
        }
    }
    return true;
}

pub fn proxyHas(rt: *Runtime, px_obj: *Object, k: object.Key) Error!bool {
    var root_buf = [_]Value{ Value.fromObject(px_obj), common.keyToRootValue(k), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "has");
    if (t.trap == null) return object.has(rt, k, t.target);
    const prop_val = try common.keyToValue(rt, k);
    root_buf[2] = t.target;
    root_buf[3] = t.handler;
    root_buf[4] = prop_val;

    const trap_res = ops.toBoolean(try rt.callCallable(t.trap.?, t.handler, &.{ t.target, prop_val }));
    if (!trap_res) {
        if (try obj_builtins.getOwnPropertyRaw(rt, t.target, k)) |td| {
            if (!td.configurable) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'has' on proxy: trap returned falsish for property which exists in the proxy target as non-configurable" }});
            }
            if (!try obj_builtins.isExtensibleValue(rt, t.target)) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'has' on proxy: trap returned falsish for property but the proxy target is not extensible" }});
            }
        }
    }
    return trap_res;
}

pub fn proxyDeleteProperty(rt: *Runtime, px_obj: *Object, k: object.Key) Error!bool {
    var root_buf = [_]Value{ Value.fromObject(px_obj), common.keyToRootValue(k), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "deleteProperty");
    if (t.trap == null) return object.delete(rt, t.target, k);
    const prop_val = try common.keyToValue(rt, k);
    root_buf[2] = t.target;
    root_buf[3] = t.handler;
    root_buf[4] = prop_val;

    const trap_res = ops.toBoolean(try rt.callCallable(t.trap.?, t.handler, &.{ t.target, prop_val }));
    if (!trap_res) return false;

    if (try obj_builtins.getOwnPropertyRaw(rt, t.target, k)) |td| {
        if (!td.configurable) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'deleteProperty' on proxy: trap returned truish for property which is non-configurable in the proxy target" }});
        }
        if (!try obj_builtins.isExtensibleValue(rt, t.target)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'deleteProperty' on proxy: trap returned truish for property but the proxy target is non-extensible" }});
        }
    }
    return true;
}

pub fn proxyGetPrototypeOf(rt: *Runtime, px_obj: *Object) Error!Value {
    var root_buf = [_]Value{ Value.fromObject(px_obj), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "getPrototypeOf");
    if (t.trap == null) return object.getPrototypeOfValue(rt, t.target);
    root_buf[1] = t.target;
    root_buf[2] = t.handler;

    const handler_proto = try rt.callCallable(t.trap.?, t.handler, &.{t.target});
    root_buf[2] = handler_proto;
    if (!handler_proto.isNull() and !handler_proto.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'getPrototypeOf' on proxy: trap returned neither object nor null" }});
    }
    if (try obj_builtins.isExtensibleValue(rt, t.target)) return handler_proto;
    const target_proto = try object.getPrototypeOfValue(rt, t.target);
    if (!common.sameValue(handler_proto, target_proto)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'getPrototypeOf' on proxy: proxy target is non-extensible but the trap did not return its actual prototype" }});
    }
    return handler_proto;
}

pub fn proxySetPrototypeOf(rt: *Runtime, px_obj: *Object, proto: Value) Error!bool {
    var root_buf = [_]Value{ Value.fromObject(px_obj), proto, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "setPrototypeOf");
    if (t.trap == null) return obj_builtins.setPrototypeOfValue(rt, t.target, proto);
    root_buf[2] = t.target;
    root_buf[3] = t.handler;

    const trap_res = ops.toBoolean(try rt.callCallable(t.trap.?, t.handler, &.{ t.target, proto }));
    if (!trap_res) return false;
    if (try obj_builtins.isExtensibleValue(rt, t.target)) return true;
    const target_proto = try object.getPrototypeOfValue(rt, t.target);
    if (!common.sameValue(proto, target_proto)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'setPrototypeOf' on proxy: trap returned truish for setting a new prototype on the non-extensible proxy target" }});
    }
    return true;
}

pub fn proxyIsExtensible(rt: *Runtime, px_obj: *Object) Error!bool {
    var root_buf = [_]Value{ Value.fromObject(px_obj), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "isExtensible");
    if (t.trap == null) return obj_builtins.isExtensibleValue(rt, t.target);
    root_buf[1] = t.target;
    root_buf[2] = t.handler;

    const trap_res = ops.toBoolean(try rt.callCallable(t.trap.?, t.handler, &.{t.target}));
    const target_ext = try obj_builtins.isExtensibleValue(rt, t.target);
    if (trap_res != target_ext) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'isExtensible' on proxy: trap result does not reflect extensibility of proxy target" }});
    }
    return trap_res;
}

pub fn proxyPreventExtensions(rt: *Runtime, px_obj: *Object) Error!bool {
    var root_buf = [_]Value{ Value.fromObject(px_obj), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "preventExtensions");
    if (t.trap == null) return obj_builtins.preventExtensionsValue(rt, t.target);
    root_buf[1] = t.target;
    root_buf[2] = t.handler;

    const trap_res = ops.toBoolean(try rt.callCallable(t.trap.?, t.handler, &.{t.target}));
    if (trap_res and try obj_builtins.isExtensibleValue(rt, t.target)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'preventExtensions' on proxy: trap returned truish but the proxy target is extensible" }});
    }
    return trap_res;
}

pub fn proxyGetOwnPropertyDescriptor(rt: *Runtime, px_obj: *Object, k: object.Key) Error!?heap_mod.Property {
    var root_buf = [_]Value{ Value.fromObject(px_obj), common.keyToRootValue(k), .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "getOwnPropertyDescriptor");
    if (t.trap == null) return obj_builtins.getOwnPropertyRaw(rt, t.target, k);
    const prop_val = try common.keyToValue(rt, k);
    root_buf[2] = t.target;
    root_buf[3] = t.handler;
    root_buf[4] = prop_val;

    const trap_res = try rt.callCallable(t.trap.?, t.handler, &.{ t.target, prop_val });
    root_buf[3] = trap_res;
    if (!trap_res.isUndefined() and !trap_res.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap returned neither object nor undefined" }});
    }

    const target_desc = try obj_builtins.getOwnPropertyRaw(rt, t.target, k);
    if (trap_res.isUndefined()) {
        if (target_desc) |td| {
            if (!td.configurable) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap returned undefined for property which is non-configurable in the proxy target" }});
            }
            if (!try obj_builtins.isExtensibleValue(rt, t.target)) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap returned undefined for property which exists in the non-extensible proxy target" }});
            }
        }
        return null;
    }

    const extensible_target = try obj_builtins.isExtensibleValue(rt, t.target);
    const parsed = try obj_builtins.parsePropertyDescriptor(rt, trap_res);
    const result_desc = parsed.toCompleteProperty();
    root_buf[4] = result_desc.value;
    root_buf[5] = result_desc.setter;

    if (target_desc == null) {
        if (!extensible_target) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap returned descriptor for property that does not exist on the non-extensible proxy target" }});
        }
        if (!result_desc.configurable) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap returned non-configurable descriptor for property that does not exist in the proxy target" }});
        }
    } else {
        const td = target_desc.?;
        const completed_parsed: obj_builtins.ParsedDesc = if (result_desc.is_accessor) .{
            .has_enum = true,
            .enum_val = result_desc.enumerable,
            .has_conf = true,
            .conf_val = result_desc.configurable,
            .has_get = true,
            .get_val = result_desc.value,
            .has_set = true,
            .set_val = result_desc.setter,
        } else .{
            .has_enum = true,
            .enum_val = result_desc.enumerable,
            .has_conf = true,
            .conf_val = result_desc.configurable,
            .has_val = true,
            .val = result_desc.value,
            .has_writ = true,
            .writ_val = result_desc.writable,
        };
        if (!obj_builtins.isCompatiblePropertyDescriptor(completed_parsed, td)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap returned descriptor that is incompatible with property on the proxy target" }});
        }
        if (!result_desc.configurable and td.configurable) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap reported non-configurability for property which is configurable in the proxy target" }});
        }
        if (!result_desc.configurable and !result_desc.is_accessor and !result_desc.writable and !td.is_accessor and td.writable) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap reported non-configurable and non-writable for property which is writable in the proxy target" }});
        }
    }
    return result_desc;
}

pub fn proxyDefineProperty(rt: *Runtime, px_obj: *Object, k: object.Key, parsed: obj_builtins.ParsedDesc, desc_obj: Value) Error!bool {
    var root_buf = [_]Value{ Value.fromObject(px_obj), desc_obj, parsed.val, parsed.get_val, parsed.set_val, common.keyToRootValue(k), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "defineProperty");
    if (t.trap == null) return obj_builtins.defineOwnPropertyParsed(rt, t.target, k, parsed, false);
    const prop_val = try common.keyToValue(rt, k);
    root_buf[6] = t.target;
    root_buf[7] = t.handler;
    root_buf[8] = prop_val;

    const trap_res = ops.toBoolean(try rt.callCallable(t.trap.?, t.handler, &.{ t.target, prop_val, desc_obj }));
    if (!trap_res) return false;

    const target_desc = try obj_builtins.getOwnPropertyRaw(rt, t.target, k);
    const extensible_target = try obj_builtins.isExtensibleValue(rt, t.target);
    const setting_non_conf = parsed.has_conf and !parsed.conf_val;

    if (target_desc == null) {
        if (!extensible_target) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'defineProperty' on proxy: trap returned truish for adding property to the non-extensible proxy target" }});
        }
        if (setting_non_conf) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'defineProperty' on proxy: trap returned truish for defining non-configurable property which is non-existent in the proxy target" }});
        }
    } else {
        const td = target_desc.?;
        if (!obj_builtins.isCompatiblePropertyDescriptor(parsed, td)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'defineProperty' on proxy: trap returned truish for defining incompatible property" }});
        }
        if (setting_non_conf and td.configurable) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'defineProperty' on proxy: trap returned truish for defining non-configurable property which is configurable in the proxy target" }});
        }
        if (!td.is_accessor and !td.configurable and td.writable and parsed.has_writ and !parsed.writ_val) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'defineProperty' on proxy: trap returned truish for defining non-writable property which is writable in the proxy target" }});
        }
    }
    return true;
}

pub fn ownKeysAllValue(rt: *Runtime, target: Value) Error![]object.Key {
    var out: std.ArrayList(object.Key) = .empty;
    errdefer out.deinit(rt.gpa);
    switch (target.unpack()) {
        .object => |o| {
            if (o.kind == .proxy) return proxyOwnKeys(rt, o);
            const prop_names = try object.ownPropertyNames(rt, o);
            defer rt.gpa.free(prop_names);
            var idx_end: usize = 0;
            while (idx_end < prop_names.len and prop_names[idx_end] == .index) : (idx_end += 1) {}
            try out.appendSlice(rt.gpa, prop_names[0..idx_end]);
            if (o.kind == .array) {
                try out.append(rt.gpa, .{ .atom = try rt.heap.internAscii("length") });
            } else if (o.kind == .regexp) {
                try out.append(rt.gpa, .{ .atom = try rt.heap.internAscii("lastIndex") });
            }
            try out.appendSlice(rt.gpa, prop_names[idx_end..]);
            const syms = try object.ownSymbolKeys(rt, o, true);
            defer rt.gpa.free(syms);
            for (syms) |s| try out.append(rt.gpa, .{ .symbol = s });
        },
        .closure => |c| {
            if (!(c.meta != null and c.meta.?.length_deleted)) {
                try out.append(rt.gpa, .{ .atom = try rt.heap.internAscii("length") });
            }
            if (!(c.meta != null and c.meta.?.name_deleted)) {
                try out.append(rt.gpa, .{ .atom = try rt.heap.internAscii("name") });
            }
            if (function_error.hasAutoPrototype(c)) {
                try out.append(rt.gpa, .{ .atom = try rt.heap.internAscii("prototype") });
            }
            const prop_names = try object.ownPropertyNamesClosure(rt, c);
            defer rt.gpa.free(prop_names);
            for (prop_names) |k| {
                if ((object.isNamed(k, "length") and !(c.meta != null and c.meta.?.length_deleted)) or
                    (object.isNamed(k, "name") and !(c.meta != null and c.meta.?.name_deleted))) continue;
                try out.append(rt.gpa, k);
            }
            const syms = try object.ownSymbolKeysClosure(rt, c, true);
            defer rt.gpa.free(syms);
            for (syms) |s| try out.append(rt.gpa, .{ .symbol = s });
        },
        .native => |n| {
            if (!rt.isNativePropDeleted(n, true)) {
                try out.append(rt.gpa, .{ .atom = try rt.heap.internAscii("length") });
            }
            if (!rt.isNativePropDeleted(n, false)) {
                try out.append(rt.gpa, .{ .atom = try rt.heap.internAscii("name") });
            }
        },
        else => {},
    }
    return out.toOwnedSlice(rt.gpa);
}

fn keyInList(k: object.Key, list: []const object.Key) bool {
    for (list) |item| {
        switch (k) {
            .atom => |a| if (item == .atom and item.atom == a) return true,
            .index => |i| if (item == .index and item.index == i) return true,
            .symbol => |s| if (item == .symbol and item.symbol == s) return true,
        }
    }
    return false;
}

fn proxyOwnKeys(rt: *Runtime, px_obj: *Object) Error![]object.Key {
    var root_buf = [_]Value{ Value.fromObject(px_obj), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "ownKeys");
    if (t.trap == null) return ownKeysAllValue(rt, t.target);
    root_buf[1] = t.target;
    root_buf[2] = t.handler;

    const trap_res = try rt.callCallable(t.trap.?, t.handler, &.{t.target});
    root_buf[2] = trap_res;
    if (!trap_res.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'ownKeys' on proxy: trap returned non-object" }});
    }

    const len_val = try object.get(rt, trap_res, try object.named(rt, "length"));
    const len_n = try common.toIntegerOrInfinity(rt, len_val);
    const len: usize = if (len_n <= 0) 0 else @intFromFloat(@min(len_n, @as(f64, @floatFromInt(rt.limits.max_stack_slots))));

    var out: std.ArrayList(object.Key) = .empty;
    errdefer out.deinit(rt.gpa);
    var seen: std.AutoHashMapUnmanaged(heap_mod.PropKey, void) = .empty;
    defer seen.deinit(rt.gpa);
    var out_roots: std.ArrayList(Value) = .empty;
    defer out_roots.deinit(rt.gpa);

    const ListRoot = struct {
        list: *const std.ArrayList(Value),
        fn mark(ctx: *anyopaque, h: *heap_mod.Heap) void {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            for (self.list.items) |v| h.markValue(v);
        }
    };
    var list_root: ListRoot = .{ .list = &out_roots };
    try rt.addRoots(.{ .ctx = &list_root, .mark = ListRoot.mark });
    defer rt.removeRoots(&list_root);

    for (0..len) |i| {
        const elem = try object.get(rt, trap_res, .{ .index = @intCast(i) });
        if (!elem.isString() and !elem.isSymbol()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'ownKeys' on proxy: trap returned non-string/symbol key" }});
        }
        const k = try object.key(rt, elem);
        const pk = try object.propKey(rt, k);
        const gop = try seen.getOrPut(rt.gpa, pk);
        if (gop.found_existing) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'ownKeys' on proxy: trap returned duplicate entries" }});
        }
        try out.append(rt.gpa, k);
        try out_roots.append(rt.gpa, common.keyToRootValue(k));
    }

    const extensible_target = try obj_builtins.isExtensibleValue(rt, t.target);
    const target_keys = try ownKeysAllValue(rt, t.target);
    defer rt.gpa.free(target_keys);

    for (target_keys) |tk| {
        const td = try obj_builtins.getOwnPropertyRaw(rt, t.target, tk);
        const is_non_conf = if (td) |d| !d.configurable else false;
        if (is_non_conf and !keyInList(tk, out.items)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'ownKeys' on proxy: trap result did not include non-configurable property" }});
        }
        if (!extensible_target and !keyInList(tk, out.items)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'ownKeys' on proxy: trap result did not include property of non-extensible target" }});
        }
    }
    if (!extensible_target and out.items.len != target_keys.len) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'ownKeys' on proxy: trap returned extra keys but proxy target is non-extensible" }});
    }
    return out.toOwnedSlice(rt.gpa);
}

pub const ProxyKeyFilter = enum { enum_strings, all_strings, enum_all };

pub fn proxyOwnKeysFiltered(rt: *Runtime, px_obj: *Object, filter: ProxyKeyFilter) Error![]object.Key {
    const keys = try proxyOwnKeys(rt, px_obj);
    defer rt.gpa.free(keys);

    const key_vals = try rt.gpa.alloc(Value, 1 + keys.len);
    defer rt.gpa.free(key_vals);
    key_vals[0] = Value.fromObject(px_obj);
    for (keys, key_vals[1..]) |k, *dst| dst.* = common.keyToRootValue(k);
    var roots: rt_mod.ValueRoots = .{ .values = key_vals };
    try roots.register(rt);
    defer roots.unregister(rt);

    var out: std.ArrayList(object.Key) = .empty;
    errdefer out.deinit(rt.gpa);
    for (keys) |k| {
        switch (filter) {
            .enum_strings => {
                if (k == .symbol) continue;
                const desc = (try proxyGetOwnPropertyDescriptor(rt, px_obj, k)) orelse continue;
                if (desc.enumerable) try out.append(rt.gpa, k);
            },
            .all_strings => {
                if (k == .symbol) continue;
                try out.append(rt.gpa, k);
            },
            .enum_all => {
                const desc = (try proxyGetOwnPropertyDescriptor(rt, px_obj, k)) orelse continue;
                if (desc.enumerable) try out.append(rt.gpa, k);
            },
        }
    }
    return out.toOwnedSlice(rt.gpa);
}

pub fn proxyOwnSymbolKeys(rt: *Runtime, px_obj: *Object, include_non_enum: bool) Error![]*heap_mod.Symbol {
    const keys = try proxyOwnKeys(rt, px_obj);
    defer rt.gpa.free(keys);

    const key_vals = try rt.gpa.alloc(Value, 1 + keys.len);
    defer rt.gpa.free(key_vals);
    key_vals[0] = Value.fromObject(px_obj);
    for (keys, key_vals[1..]) |k, *dst| dst.* = common.keyToRootValue(k);
    var roots: rt_mod.ValueRoots = .{ .values = key_vals };
    try roots.register(rt);
    defer roots.unregister(rt);

    var out: std.ArrayList(*heap_mod.Symbol) = .empty;
    errdefer out.deinit(rt.gpa);
    for (keys) |k| {
        if (k != .symbol) continue;
        if (!include_non_enum) {
            const desc = (try proxyGetOwnPropertyDescriptor(rt, px_obj, k)) orelse continue;
            if (!desc.enumerable) continue;
        }
        try out.append(rt.gpa, k.symbol);
    }
    return out.toOwnedSlice(rt.gpa);
}

pub fn callProxy(rt: *Runtime, px_obj: *Object, this_arg: Value, args: []const Value) Error!Value {
    try rt.checkNativeStack();
    if (!px_obj.kind.proxy.is_callable) {
        return rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }});
    }
    var root_buf = [_]Value{ Value.fromObject(px_obj), this_arg, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "apply");
    if (t.trap == null) return rt.callCallable(t.target, this_arg, args);
    root_buf[2] = t.target;
    root_buf[3] = t.handler;

    const r = try builtins.realm(rt);
    const args_arr = try rt.heap.newArray(r.array_prototype);
    root_buf[4] = Value.fromObject(args_arr);
    try rt.heap.appendElements(args_arr, args);
    return rt.callCallable(t.trap.?, t.handler, &.{ t.target, this_arg, Value.fromObject(args_arr) });
}

pub fn callProxyConstruct(rt: *Runtime, px_obj: *Object, args: []const Value, new_target: Value) Error!Value {
    try rt.checkNativeStack();
    if (!px_obj.kind.proxy.is_constructable) {
        return rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }});
    }
    var root_buf = [_]Value{ Value.fromObject(px_obj), new_target, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "construct");
    if (t.trap == null) return constructWithNewTarget(rt, t.target, args, new_target);
    root_buf[2] = t.target;
    root_buf[3] = t.handler;

    const r = try builtins.realm(rt);
    const args_arr = try rt.heap.newArray(r.array_prototype);
    root_buf[4] = Value.fromObject(args_arr);
    try rt.heap.appendElements(args_arr, args);
    const res = try rt.callCallable(t.trap.?, t.handler, &.{ t.target, Value.fromObject(args_arr), new_target });
    if (!res.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'construct' on proxy: trap returned non-object" }});
    }
    return res;
}

pub fn constructWithNewTarget(rt: *Runtime, target_in: Value, args: []const Value, new_target_in: Value) Error!Value {
    var target = target_in;
    var new_target = new_target_in;
    var extra_args: std.ArrayList(Value) = .empty;
    defer extra_args.deinit(rt.gpa);

    if (target.isClosure() and target.asClosure().impl == .bound) {
        const b = target.asClosure().impl.bound;
        if (common.sameValue(new_target, target)) new_target = b.target;
        if (b.bound_args.len > 0) {
            try extra_args.appendSlice(rt.gpa, b.bound_args);
            try extra_args.appendSlice(rt.gpa, args);
        }
        target = b.target;
    }
    const effective_args = if (extra_args.items.len > 0) extra_args.items else args;
    if (!function_error.isConstructor(target)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }});
    }
    if (target.isObject() and target.asObject().kind == .proxy) {
        return callProxyConstruct(rt, target.asObject(), effective_args, new_target);
    }
    if (target.isNative()) {
        if (!common.sameValue(new_target, target)) {
            const p = try object.get(rt, new_target, try object.named(rt, "prototype"));
            const po: ?*Object = if (p.isObject()) p.asObject() else null;
            if (target.asNative() == &builtins.object_global) {
                return Value.fromObject(try rt.heap.newObject(po orelse (try builtins.realm(rt)).object_prototype));
            }
            const res = try builtins.construct(rt, target, effective_args);
            if (po) |proto_obj| if (res.isObject()) rt.heap.storeObjectProto(res.asObject(), proto_obj);
            return res;
        }
        return builtins.construct(rt, target, effective_args);
    }
    return rt.constructClosure(target.asClosure(), effective_args, new_target);
}

fn requireReflectTarget(rt: *Runtime, v: Value, name: []const u8) Error!Value {
    if (!v.isObjectLike()) {
        return rt.throw(.TypeError, &.{ .{ .ascii = "Reflect." }, .{ .ascii = name }, .{ .ascii = " called on non-object" } });
    }
    return v;
}

fn reflectGet(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, common.arg(args, 0), "get");
    const receiver = if (args.len >= 3) args[2] else target;
    var root_buf = [_]Value{ target, receiver };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const k = try object.key(rt, common.arg(args, 1));
    return object.getWithReceiver(rt, target, receiver, k);
}

fn reflectSet(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, common.arg(args, 0), "set");
    const val = common.arg(args, 2);
    const receiver = if (args.len >= 4) args[3] else target;
    var root_buf = [_]Value{ target, val, receiver };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const k = try object.key(rt, common.arg(args, 1));
    return Value.fromBool(try object.setWithReceiver(rt, target, k, val, receiver, false));
}

fn reflectHas(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, common.arg(args, 0), "has");
    var root_buf = [_]Value{target};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const k = try object.key(rt, common.arg(args, 1));
    return Value.fromBool(try object.has(rt, k, target));
}

fn reflectDeleteProperty(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, common.arg(args, 0), "deleteProperty");
    var root_buf = [_]Value{target};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const k = try object.key(rt, common.arg(args, 1));
    return Value.fromBool(try object.delete(rt, target, k));
}

fn reflectOwnKeys(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, common.arg(args, 0), "ownKeys");
    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ target, Value.fromObject(out) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const keys = try ownKeysAllValue(rt, target);
    defer rt.gpa.free(keys);
    const key_vals = try rt.gpa.alloc(Value, keys.len);
    defer rt.gpa.free(key_vals);
    for (keys, key_vals) |k, *dst| dst.* = common.keyToRootValue(k);
    var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
    try key_roots.register(rt);
    defer key_roots.unregister(rt);

    for (keys) |k| {
        try rt.heap.appendElement(out, try common.keyToValue(rt, k));
    }
    return Value.fromObject(out);
}

fn reflectGetOwnPropertyDescriptor(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, common.arg(args, 0), "getOwnPropertyDescriptor");
    var root_buf = [_]Value{target};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const k = try object.key(rt, common.arg(args, 1));
    const p = (try obj_builtins.getOwnPropertyRaw(rt, target, k)) orelse return .undefined;
    return obj_builtins.descriptorToObject(rt, p);
}

fn reflectDefineProperty(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, common.arg(args, 0), "defineProperty");
    var root_buf = [_]Value{ target, common.arg(args, 2) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const k = try object.key(rt, common.arg(args, 1));
    const parsed = try obj_builtins.parsePropertyDescriptor(rt, common.arg(args, 2));
    return Value.fromBool(try obj_builtins.defineOwnPropertyParsed(rt, target, k, parsed, false));
}

fn reflectGetPrototypeOf(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, common.arg(args, 0), "getPrototypeOf");
    return object.getPrototypeOfValue(rt, target);
}

fn reflectSetPrototypeOf(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, common.arg(args, 0), "setPrototypeOf");
    return Value.fromBool(try obj_builtins.setPrototypeOfValue(rt, target, common.arg(args, 1)));
}

fn reflectIsExtensible(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, common.arg(args, 0), "isExtensible");
    return Value.fromBool(try obj_builtins.isExtensibleValue(rt, target));
}

fn reflectPreventExtensions(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, common.arg(args, 0), "preventExtensions");
    return Value.fromBool(try obj_builtins.preventExtensionsValue(rt, target));
}

fn createListFromArrayLike(rt: *Runtime, list_val: Value) Error![]Value {
    if (!list_val.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "CreateListFromArrayLike called on non-object" }});
    }
    if (list_val.isObject() and list_val.asObject().kind == .array) {
        return rt.gpa.dupe(Value, list_val.asObject().kind.array.items);
    }
    var list_root = [_]Value{list_val};
    var lr: rt_mod.ValueRoots = .{ .values = &list_root };
    try lr.register(rt);
    defer lr.unregister(rt);

    const len_val = try object.get(rt, list_val, try object.named(rt, "length"));
    const len_n = try common.toIntegerOrInfinity(rt, len_val);
    const len: usize = if (len_n <= 0) 0 else @intFromFloat(@min(len_n, @as(f64, @floatFromInt(rt.limits.max_stack_slots))));
    const out = try rt.gpa.alloc(Value, len);
    errdefer rt.gpa.free(out);
    @memset(out, .undefined);
    var out_roots: rt_mod.ValueRoots = .{ .values = out };
    try out_roots.register(rt);
    defer out_roots.unregister(rt);

    for (0..len) |i| {
        out[i] = try object.get(rt, list_val, .{ .index = @intCast(i) });
    }
    return out;
}

fn reflectApply(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = common.arg(args, 0);
    if (!target.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Reflect.apply requires a callable target" }});
    }
    const this_arg = common.arg(args, 1);
    var root_buf = [_]Value{ target, this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const arg_list = try createListFromArrayLike(rt, common.arg(args, 2));
    defer rt.gpa.free(arg_list);
    var arg_roots: rt_mod.ValueRoots = .{ .values = arg_list };
    try arg_roots.register(rt);
    defer arg_roots.unregister(rt);
    return rt.callCallable(target, this_arg, arg_list);
}

fn reflectConstruct(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = common.arg(args, 0);
    if (!function_error.isConstructor(target)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Reflect.construct requires a constructor target" }});
    }
    const new_target = if (args.len >= 3) args[2] else target;
    if (!function_error.isConstructor(new_target)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Reflect.construct requires a constructor newTarget" }});
    }
    var root_buf = [_]Value{ target, new_target };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const arg_list = try createListFromArrayLike(rt, common.arg(args, 1));
    defer rt.gpa.free(arg_list);
    var arg_roots: rt_mod.ValueRoots = .{ .values = arg_list };
    try arg_roots.register(rt);
    defer arg_roots.unregister(rt);
    return constructWithNewTarget(rt, target, arg_list, new_target);
}

// ---------------------------------------------------------------- Date (M50, D80)
