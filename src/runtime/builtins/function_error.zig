//! Function, class initialization, and Error built-ins.

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
const ast = @import("../../frontend/ast.zig");
const bytecode = @import("../../bytecode/bytecode.zig");
const builtins = @import("../builtins.zig");
const common = @import("common.zig");
const iterator = @import("iterator.zig");
const obj_builtins = @import("object.zig");

pub fn register(rt: *Runtime, r: *const builtins.Realm) Error!void {
    try initErrorProto(rt, r.error_prototype, r.error_namespace, "Error", &builtins.error_global);
    try common.method(rt, r.error_namespace, "isError", &error_is_error);
    try common.method(rt, r.error_namespace, "captureStackTrace", &error_capture_stack_trace);
    try rt.heap.defineProperty(r.error_namespace, try rt.heap.internAscii("stackTraceLimit"), .{
        .value = Value.fromNumber(10),
        .enumerable = false,
        .writable = true,
        .configurable = true,
    });
    try common.method(rt, r.error_prototype, "toString", &error_to_string);
    try initErrorProto(rt, r.type_error_prototype, r.type_error_namespace, "TypeError", &builtins.type_error_global);
    try initErrorProto(rt, r.range_error_prototype, r.range_error_namespace, "RangeError", &builtins.range_error_global);
    try initErrorProto(rt, r.syntax_error_prototype, r.syntax_error_namespace, "SyntaxError", &builtins.syntax_error_global);
    try initErrorProto(rt, r.reference_error_prototype, r.reference_error_namespace, "ReferenceError", &builtins.reference_error_global);
    try initErrorProto(rt, r.eval_error_prototype, r.eval_error_namespace, "EvalError", &builtins.eval_error_global);
    try initErrorProto(rt, r.uri_error_prototype, r.uri_error_namespace, "URIError", &builtins.uri_error_global);
    try initErrorProto(rt, r.aggregate_error_prototype, r.aggregate_error_namespace, "AggregateError", &builtins.aggregate_error_global);
    try common.immutableConstant(rt, r.function_namespace, "prototype", Value.fromObject(r.function_prototype));
    try common.constant(rt, r.function_prototype, "constructor", Value.fromNative(&builtins.function_global));
    try rt.heap.defineProperty(r.function_prototype, try rt.heap.internAscii("length"), .{
        .value = Value.fromNumber(0),
        .enumerable = false,
        .writable = false,
        .configurable = true,
    });
    try rt.heap.defineProperty(r.function_prototype, try rt.heap.internAscii("name"), .{
        .value = Value.fromString(try rt.heap.ascii("")),
        .enumerable = false,
        .writable = false,
        .configurable = true,
    });
    try common.method(rt, r.function_prototype, "call", &function_call);
    try common.method(rt, r.function_prototype, "apply", &function_apply);
    try common.method(rt, r.function_prototype, "bind", &function_bind);
    try rt.heap.definePropKey(r.function_prototype, heap_mod.PropKey.fromSymbol(r.sym_has_instance), .{
        .value = Value.fromNative(&builtins.function_has_instance),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    const tte = try createThrowTypeError(rt, r);
    const tte_val = Value.fromClosure(tte);
    try rt.heap.defineProperty(r.function_prototype, try rt.heap.internAscii("caller"), .{
        .is_accessor = true,
        .value = tte_val,
        .setter = tte_val,
        .enumerable = false,
        .configurable = true,
        .writable = false,
    });
    try rt.heap.defineProperty(r.function_prototype, try rt.heap.internAscii("arguments"), .{
        .is_accessor = true,
        .value = tte_val,
        .setter = tte_val,
        .enumerable = false,
        .configurable = true,
        .writable = false,
    });
}

fn throwTypeErrorFn(rt: *Runtime, _: *Object, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "'caller', 'callee', and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them" }});
}

pub fn createThrowTypeError(rt: *Runtime, r: *const builtins.Realm) Error!*heap_mod.Closure {
    var root_buf = [_]Value{.undefined};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const env = try rt.heap.newObject(null);
    root_buf[0] = Value.fromObject(env);
    const tte = try rt.heap.newNativeClosure(@ptrCast(&throwTypeErrorFn), env);
    root_buf[0] = Value.fromClosure(tte);
    const m = try rt.heap.ensureClosureMeta(tte);
    m.extensible = false;
    m.name_configurable = false;
    m.length_configurable = false;
    try rt.heap.storeClosureProto(tte, Value.fromObject(r.function_prototype));
    return tte;
}

pub fn hasAutoPrototype(c: *const heap_mod.Closure) bool {
    return switch (c.impl) {
        .vm => |v| blk: {
            const p: *const bytecode.Proto = @ptrCast(@alignCast(v.proto));
            break :blk p.is_generator or (!p.is_arrow and !p.is_async and !p.is_method);
        },
        .tree => |t| blk: {
            const f: *const ast.Function = @ptrCast(@alignCast(t.func));
            break :blk f.is_generator or (!f.is_arrow and !f.is_async and !f.is_method);
        },
        .promise_cap, .native_closure, .bound => false,
    };
}

pub fn isGeneratorFunction(c: *const heap_mod.Closure) bool {
    return switch (c.impl) {
        .vm => |v| @as(*const bytecode.Proto, @ptrCast(@alignCast(v.proto))).is_generator,
        .tree => |t| @as(*const ast.Function, @ptrCast(@alignCast(t.func))).is_generator,
        .promise_cap, .native_closure, .bound => false,
    };
}

pub const FunctionKind = enum { normal, generator, async_function, async_generator };

pub fn functionKind(c: *const heap_mod.Closure) FunctionKind {
    const is_async: bool, const is_gen: bool = switch (c.impl) {
        .vm => |v| blk: {
            const p: *const bytecode.Proto = @ptrCast(@alignCast(v.proto));
            break :blk .{ p.is_async_generator or (p.is_async and !p.is_generator), p.is_generator };
        },
        .tree => |t| blk: {
            const f: *const ast.Function = @ptrCast(@alignCast(t.func));
            break :blk .{ f.is_async, f.is_generator };
        },
        .promise_cap, .native_closure, .bound => .{ false, false },
    };
    if (is_gen) return if (is_async) .async_generator else .generator;
    return if (is_async) .async_function else .normal;
}

/// A closure's `[[Prototype]]` when `ClosureMeta.proto` doesn't set one (D68):
/// %GeneratorFunction.prototype%, %AsyncGeneratorFunction.prototype%,
/// %AsyncFunction.prototype% or %Function.prototype% by its kind.
pub fn closureDefaultProto(rt: *Runtime, c: *const heap_mod.Closure) Error!*Object {
    const r = try builtins.realm(rt);
    return switch (functionKind(c)) {
        .normal => r.function_prototype,
        .generator => r.generator_function_prototype,
        .async_function => r.async_function_prototype,
        .async_generator => r.async_generator_function_prototype,
    };
}

pub fn isConstructor(v: Value) bool {
    return switch (v.unpack()) {
        .native => |n| n.construct != null or (n.namespace != null and n.namespace.? != .symbol),
        .closure => |c| switch (c.impl) {
            .vm, .tree => hasAutoPrototype(c) and !isGeneratorFunction(c),
            .bound => |b| isConstructor(b.target),
            .promise_cap, .native_closure => false,
        },
        .object => |o| o.kind == .proxy and o.kind.proxy.is_constructable,
        else => false,
    };
}

pub fn closureName(rt: *Runtime, c: *const heap_mod.Closure) Error!*const heap_mod.String {
    const raw: []const u8 = switch (c.impl) {
        .vm => |v| blk: {
            const p: *const bytecode.Proto = @ptrCast(@alignCast(v.proto));
            break :blk if (p.name.len > 0) p.name else p.inferred_name;
        },
        .tree => |t| blk: {
            const f: *const ast.Function = @ptrCast(@alignCast(t.func));
            break :blk if (f.name) |n| n.name else f.inferred_name;
        },
        .bound => |b| return b.name,
        .promise_cap, .native_closure => "",
    };
    return rt.heap.ascii(raw);
}

pub fn closureLength(c: *const heap_mod.Closure) u16 {
    return switch (c.impl) {
        .vm => |v| @as(*const bytecode.Proto, @ptrCast(@alignCast(v.proto))).length,
        .tree => |t| @as(*const ast.Function, @ptrCast(@alignCast(t.func))).length,
        .bound => |b| b.length,
        .promise_cap => 1,
        .native_closure => 0,
    };
}

pub fn isClassConstructor(v: Value) bool {
    if (v != .closure) return false;
    return switch (v.closure.impl) {
        .vm => |vm_impl| @as(*const bytecode.Proto, @ptrCast(@alignCast(vm_impl.proto))).is_class_constructor,
        .tree => |tr| @as(*const ast.Function, @ptrCast(@alignCast(tr.func))).is_class_constructor,
        .bound, .promise_cap, .native_closure => false,
    };
}

pub fn setupClass(rt: *Runtime, ctor_val: Value, has_super: bool, super_val: Value) Error!*Object {
    var root_buf = [_]Value{ ctor_val, super_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const ctor = @constCast(ctor_val.asClosure());
    const r = try builtins.realm(rt);
    const super_proto: ?*Object = if (!has_super)
        r.object_prototype
    else if (super_val.isNull())
        null
    else blk: {
        if (!isConstructor(super_val)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Class extends value is not a constructor or null" }});
        }
        const sp = try object.get(rt, super_val, try object.named(rt, "prototype"));
        if (!sp.isNull() and !sp.isObject()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Class extends value has non-object prototype" }});
        }
        try rt.heap.storeClosureProto(ctor, super_val);
        if (sp.isNull()) break :blk null;
        break :blk sp.asObject();
    };

    const proto_obj = try rt.heap.newObject(super_proto);
    root_buf[2] = Value.fromObject(proto_obj);
    const ctor_key = try rt.heap.internAscii("constructor");
    try rt.heap.defineProperty(proto_obj, ctor_key, .{ .value = ctor_val, .enumerable = false });
    try rt.heap.storeClosurePrototype(ctor, Value.fromObject(proto_obj));
    (try rt.heap.ensureClosureMeta(ctor)).prototype_writable = false;
    try rt.heap.storeClosureHomeObject(ctor, Value.fromObject(proto_obj));
    try rt.heap.storeClosureBrand(ctor, ctor_val);
    return proto_obj;
}

pub fn runInstanceInits(rt: *Runtime, ctor: *heap_mod.Closure, this_val: Value) Error!void {
    const m = ctor.meta orelse return;
    if (m.instance_inits.len == 0) return;
    var root_buf = [_]Value{ Value.fromClosure(ctor), this_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (0..m.instance_inits.len) |i| {
        const entry = ctor.meta.?.instance_inits[i];
        switch (entry.kind) {
            .private_method => try object.definePrivateMethod(rt, this_val, ctor, entry.name.?, entry.func),
            .private_getter => try object.definePrivateAccessor(rt, this_val, ctor, entry.name.?, entry.func, false),
            .private_setter => try object.definePrivateAccessor(rt, this_val, ctor, entry.name.?, entry.func, true),
            .public_field => {
                const is_anon = (entry.key_idx & 0x8000_0000) != 0;
                const key_idx = entry.key_idx & 0x7fff_ffff;
                const key_val = ctor.meta.?.field_keys[key_idx];
                const val: Value = if (entry.func.isUndefined()) .undefined else try rt.callCallable(entry.func, this_val, &.{});
                root_buf[2] = val;
                const k = try object.key(rt, key_val);
                if (is_anon) try setFunctionNameIfUnset(rt, val, k);
                try object.definePublicField(rt, this_val, k, val);
                root_buf[2] = .undefined;
            },
            .private_field => {
                const val: Value = if (entry.func.isUndefined()) .undefined else try rt.callCallable(entry.func, this_val, &.{});
                root_buf[2] = val;
                try object.definePrivateField(rt, this_val, ctor, entry.name.?, val);
                root_buf[2] = .undefined;
            },
        }
    }
}

pub fn setFunctionName(rt: *Runtime, fn_val: Value, k: object.Key, prefix: ?[]const u8) Error!void {
    if (!fn_val.isClosure()) return;
    var root_buf = [_]Value{ fn_val, common.keyToRootValue(k) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var base_str: *const heap_mod.String = switch (k) {
        .atom => |a| a,
        .index => |i| try object.atomOf(rt, .{ .index = i }),
        .symbol => |sym| if (sym.description) |desc|
            try rt.heap.newString(&.{ .{ .ascii = "[" }, .{ .utf16 = desc.units }, .{ .ascii = "]" } })
        else
            try rt.heap.ascii(""),
    };
    if (prefix) |pfx| {
        base_str = try rt.heap.newString(&.{ .{ .ascii = pfx }, .{ .utf16 = base_str.units } });
    }
    const name_pk = heap_mod.PropKey.fromAtom(try rt.heap.internAscii("name"));
    try rt.heap.defineClosurePropKey(@constCast(fn_val.asClosure()), name_pk, .{
        .value = Value.fromString(base_str),
        .enumerable = false,
        .writable = false,
        .configurable = true,
    });
}

pub fn setFunctionNameIfUnset(rt: *Runtime, val: Value, k: object.Key) Error!void {
    if (!val.isClosure()) return;
    const c = val.asClosure();
    const name_pk = heap_mod.PropKey.fromAtom(try rt.heap.internAscii("name"));
    if (c.meta) |m| {
        if (m.props.contains(name_pk) or m.name_deleted) return;
    }
    try setFunctionName(rt, val, k, null);
}

fn hasStaticInferredName(c: *const heap_mod.Closure) bool {
    return switch (c.impl) {
        .vm => |v| @as(*const bytecode.Proto, @ptrCast(@alignCast(v.proto))).inferred_name.len > 0,
        .tree => |t| @as(*const ast.Function, @ptrCast(@alignCast(t.func))).inferred_name.len > 0,
        else => true,
    };
}

pub fn defineClassMethod(rt: *Runtime, target: Value, k: object.Key, method_val: Value) Error!void {
    var root_buf = [_]Value{ target, method_val, common.keyToRootValue(k) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    try rt.heap.storeClosureHomeObject(@constCast(method_val.asClosure()), target);
    if (k != .atom or !hasStaticInferredName(method_val.asClosure())) {
        try setFunctionName(rt, method_val, k, null);
    }
    _ = try obj_builtins.defineOwnPropertyParsed(rt, target, k, .{
        .has_val = true,
        .val = method_val,
        .has_writ = true,
        .writ_val = true,
        .has_enum = true,
        .enum_val = false,
        .has_conf = true,
        .conf_val = true,
    }, true);
}

pub fn defineClassAccessor(rt: *Runtime, target: Value, k: object.Key, fn_val: Value, is_setter: bool) Error!void {
    var root_buf = [_]Value{ target, fn_val, common.keyToRootValue(k) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    try rt.heap.storeClosureHomeObject(@constCast(fn_val.asClosure()), target);
    try setFunctionName(rt, fn_val, k, if (is_setter) "set " else "get ");
    _ = try obj_builtins.defineOwnPropertyParsed(rt, target, k, .{
        .has_get = !is_setter,
        .get_val = if (!is_setter) fn_val else .undefined,
        .has_set = is_setter,
        .set_val = if (is_setter) fn_val else .undefined,
        .has_enum = true,
        .enum_val = false,
        .has_conf = true,
        .conf_val = true,
    }, true);
}

pub fn materializeClosurePrototype(rt: *Runtime, c: *heap_mod.Closure) Error!*Object {
    const r = try builtins.realm(rt);
    if (isGeneratorFunction(c)) { // inherits %(Async)GeneratorPrototype%, no `constructor` (D67, D68)
        const gen_proto = try rt.heap.newObject(if (functionKind(c) == .async_generator) r.async_generator_prototype else r.generator_prototype);
        try rt.heap.storeClosurePrototype(c, Value.fromObject(gen_proto));
        return gen_proto;
    }
    const proto_obj = try rt.heap.newObject(r.object_prototype);
    const ctor_key = try rt.heap.internAscii("constructor");
    try rt.heap.defineProperty(proto_obj, ctor_key, .{ .value = Value.fromClosure(c), .enumerable = false });
    try rt.heap.storeClosurePrototype(c, Value.fromObject(proto_obj));
    return proto_obj;
}

const function_call: Native = .{ .name = "call", .length = 1, .call = functionCall };

const function_apply: Native = .{ .name = "apply", .length = 2, .call = functionApply };

const function_bind: Native = .{ .name = "bind", .length = 1, .call = functionBind };

pub fn functionHasInstance(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return Value.fromBool(try object.ordinaryHasInstance(rt, this, common.arg(args, 0)));
}

fn functionCall(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "Function.prototype.call called on non-function" }});
    const this_arg = common.arg(args, 0);
    const call_args = if (args.len > 1) args[1..] else &[_]Value{};
    return rt.callCallable(this, this_arg, call_args);
}

fn functionApply(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "Function.prototype.apply called on non-function" }});
    const this_arg = common.arg(args, 0);
    const arg_array = common.arg(args, 1);
    if (arg_array.isUndefined() or arg_array.isNull()) {
        return rt.callCallable(this, this_arg, &.{});
    }
    if (!arg_array.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "CreateListFromArrayLike called on non-object" }});
    }
    var root_buf = [_]Value{ this, this_arg, arg_array };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (arg_array.isObject() and arg_array.asObject().kind == .array) {
        const items = arg_array.asObject().kind.array.items;
        var has_hole = false;
        for (items) |v| {
            if (v.isHole()) {
                has_hole = true;
                break;
            }
        }
        if (!has_hole) {
            const copy = try rt.gpa.dupe(Value, items);
            defer rt.gpa.free(copy);
            var copy_roots: rt_mod.ValueRoots = .{ .values = copy };
            try copy_roots.register(rt);
            defer copy_roots.unregister(rt);
            return rt.callCallable(this, this_arg, copy);
        }
    }
    const len_val = try object.get(rt, arg_array, try object.named(rt, "length"));
    const len_n = try common.toIntegerOrInfinity(rt, len_val);
    const len: usize = if (len_n <= 0) 0 else @intFromFloat(@min(len_n, @as(f64, @floatFromInt(rt.limits.max_stack_slots))));
    const list = try rt.gpa.alloc(Value, len);
    defer rt.gpa.free(list);
    @memset(list, .undefined);
    var list_roots: rt_mod.ValueRoots = .{ .values = list };
    try list_roots.register(rt);
    defer list_roots.unregister(rt);
    for (0..len) |i| {
        list[i] = try object.get(rt, arg_array, try common.indexKey(rt, i));
    }
    return rt.callCallable(this, this_arg, list);
}

fn functionBind(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "Bind must be called on a function" }});
    const this_arg = common.arg(args, 0);
    const new_bound_args = if (args.len > 1) args[1..] else &[_]Value{};

    var root_buf = [_]Value{ this, this_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var target: Value = this;
    var effective_this: Value = this_arg;
    var prev_args: []const Value = &.{};
    if (this.isClosure() and this.asClosure().impl == .bound) {
        const prev = this.asClosure().impl.bound;
        target = prev.target;
        effective_this = prev.bound_this;
        prev_args = prev.bound_args;
    }

    var bound_len_f: f64 = 0;
    const len_k = try object.named(rt, "length");
    if (try object.hasOwn(rt, this, len_k)) {
        const target_len = try object.get(rt, this, len_k);
        if (target_len.isNumber()) {
            const tl = target_len.asNumber();
            if (tl == std.math.inf(f64)) {
                bound_len_f = std.math.inf(f64);
            } else if (tl != -std.math.inf(f64)) {
                const as_int = try common.toIntegerOrInfinity(rt, target_len);
                const arg_count: f64 = @floatFromInt(new_bound_args.len);
                bound_len_f = @max(as_int - arg_count, 0.0);
            }
        }
    }

    const name_k = try object.named(rt, "name");
    const target_name_val = try object.get(rt, this, name_k);
    root_buf[2] = target_name_val;
    const name_str = if (target_name_val.isString())
        try rt.heap.newString(&.{ .{ .ascii = "bound " }, .{ .utf16 = target_name_val.asString().units } })
    else
        try rt.heap.ascii("bound ");
    root_buf[2] = Value.fromString(name_str);

    const combined = try rt.gpa.alloc(Value, prev_args.len + new_bound_args.len);
    defer rt.gpa.free(combined);
    @memcpy(combined[0..prev_args.len], prev_args);
    @memcpy(combined[prev_args.len..], new_bound_args);

    const small_len: u16 = if (bound_len_f <= 65535.0) @intFromFloat(bound_len_f) else 0;
    const bound_c = try rt.heap.newBoundClosure(target, effective_this, combined, name_str, small_len);
    root_buf[3] = Value.fromClosure(bound_c);
    if (bound_len_f > 65535.0) {
        try rt.heap.defineClosurePropKey(bound_c, try object.propKey(rt, len_k), .{
            .value = Value.fromNumber(bound_len_f),
            .writable = false,
            .enumerable = false,
            .configurable = true,
        });
    }
    const proto_val = try object.getPrototypeOfValue(rt, this);
    const r = try builtins.realm(rt);
    if (!(proto_val.isObject() and proto_val.asObject() == r.function_prototype)) {
        try rt.heap.storeClosureProto(bound_c, proto_val);
    }
    return Value.fromClosure(bound_c);
}

/// `print(a, b, …)` writes `String(a) + " " + String(b) + … + "\n"`. The node test
/// harness defines the same function, so outputs compare byte for byte.
const error_is_error: Native = .{ .name = "isError", .length = 1, .call = errorIsError };

const error_capture_stack_trace: Native = .{ .name = "captureStackTrace", .length = 2, .call = errorCaptureStackTrace };

fn errorCaptureStackTrace(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = common.arg(args, 0);
    if (!target.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Error.captureStackTrace target must be an object" }});
    }
    if (target.isObject()) {
        const stack_val = Value.fromString(try rt.heap.ascii("Error"));
        try object.define(rt, target.asObject(), try object.named(rt, "stack"), stack_val);
    }
    return .undefined;
}

fn errorIsError(_: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = common.arg(args, 0);
    return Value.fromBool(v.isObject() and v.asObject().ordinary_tag == .@"error");
}

const error_to_string: Native = .{ .name = "toString", .call = errorToString };

fn initErrorProto(rt: *Runtime, proto: *Object, ns: *Object, name_ascii: []const u8, ctor: *const Native) Error!void {
    try common.immutableConstant(rt, ns, "prototype", Value.fromObject(proto));
    try common.constant(rt, proto, "constructor", Value.fromNative(ctor));
    try common.constant(rt, proto, "name", Value.fromString(try rt.heap.ascii(name_ascii)));
    try common.constant(rt, proto, "message", Value.fromString(try rt.heap.ascii("")));
}

fn errorToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Error.prototype.toString requires that 'this' be an Object" }});
    }
    var root_buf = [_]Value{ this, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const name_val = try object.get(rt, this, try object.named(rt, "name"));
    const name_str = if (name_val.isUndefined()) try rt.heap.ascii("Error") else try common.toStringObj(rt, name_val);
    root_buf[1] = Value.fromString(name_str);

    const msg_val = try object.get(rt, this, try object.named(rt, "message"));
    const msg_str = if (msg_val.isUndefined()) try rt.heap.ascii("") else try common.toStringObj(rt, msg_val);
    root_buf[2] = Value.fromString(msg_str);

    if (name_str.units.len == 0) return Value.fromString(msg_str);
    if (msg_str.units.len == 0) return Value.fromString(name_str);
    return Value.fromString(try rt.heap.newString(&.{ .{ .utf16 = name_str.units }, .{ .ascii = ": " }, .{ .utf16 = msg_str.units } }));
}

pub fn buildError(rt: *Runtime, proto: *Object, msg_arg: Value, opts_arg: Value) Error!*Object {
    var root_buf = [_]Value{ msg_arg, opts_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const err_obj = try rt.heap.newObject(proto);
    err_obj.ordinary_tag = .@"error";
    root_buf[2] = Value.fromObject(err_obj);

    if (!msg_arg.isUndefined()) {
        const msg_str = try common.toStringObj(rt, msg_arg);
        root_buf[3] = Value.fromString(msg_str);
        try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("message"), .{ .value = root_buf[3], .enumerable = false });
    }
    if (opts_arg.isObject()) {
        const cause_key = try object.named(rt, "cause");
        if (try object.has(rt, cause_key, opts_arg)) {
            const cause_val = try object.get(rt, opts_arg, cause_key);
            root_buf[3] = cause_val;
            try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("cause"), .{ .value = cause_val, .enumerable = false });
        }
    }
    return err_obj;
}

pub fn makeEngineError(rt: *Runtime, name: rt_mod.ErrorName, msg: *const heap_mod.String) Error!Value {
    const r = try builtins.realm(rt);
    const proto = switch (name) {
        .ReferenceError => r.reference_error_prototype,
        .TypeError => r.type_error_prototype,
        .RangeError => r.range_error_prototype,
        .SyntaxError => r.syntax_error_prototype,
    };
    var root_buf = [_]Value{ Value.fromString(msg), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const err_obj = try rt.heap.newObject(proto);
    err_obj.ordinary_tag = .@"error";
    root_buf[1] = Value.fromObject(err_obj);
    try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("message"), .{ .value = root_buf[0], .enumerable = false });
    return root_buf[1];
}

pub fn throwURIError(rt: *Runtime) Error {
    const r = try builtins.realm(rt);
    const err_obj = try buildError(rt, r.uri_error_prototype, Value.fromString(try rt.heap.ascii("URI malformed")), .undefined);
    return rt.throwValue(Value.fromObject(err_obj));
}

pub fn errorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return errorConstruct(rt, args);
}

pub fn errorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    return Value.fromObject(try buildError(rt, r.error_prototype, common.arg(args, 0), common.arg(args, 1)));
}

pub fn typeErrorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return typeErrorConstruct(rt, args);
}

pub fn typeErrorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    return Value.fromObject(try buildError(rt, r.type_error_prototype, common.arg(args, 0), common.arg(args, 1)));
}

pub fn rangeErrorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return rangeErrorConstruct(rt, args);
}

pub fn rangeErrorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    return Value.fromObject(try buildError(rt, r.range_error_prototype, common.arg(args, 0), common.arg(args, 1)));
}

pub fn syntaxErrorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return syntaxErrorConstruct(rt, args);
}

pub fn syntaxErrorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    return Value.fromObject(try buildError(rt, r.syntax_error_prototype, common.arg(args, 0), common.arg(args, 1)));
}

pub fn referenceErrorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return referenceErrorConstruct(rt, args);
}

pub fn referenceErrorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    return Value.fromObject(try buildError(rt, r.reference_error_prototype, common.arg(args, 0), common.arg(args, 1)));
}

pub fn evalErrorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return evalErrorConstruct(rt, args);
}

pub fn evalErrorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    return Value.fromObject(try buildError(rt, r.eval_error_prototype, common.arg(args, 0), common.arg(args, 1)));
}

pub fn uriErrorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return uriErrorConstruct(rt, args);
}

pub fn uriErrorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    return Value.fromObject(try buildError(rt, r.uri_error_prototype, common.arg(args, 0), common.arg(args, 1)));
}

pub fn aggregateErrorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return aggregateErrorConstruct(rt, args);
}

pub fn aggregateErrorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const errors_arg = common.arg(args, 0);
    const msg_arg = common.arg(args, 1);
    const opts_arg = common.arg(args, 2);

    var root_buf = [_]Value{ errors_arg, msg_arg, opts_arg, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const err_obj = try buildError(rt, r.aggregate_error_prototype, msg_arg, opts_arg);
    root_buf[3] = Value.fromObject(err_obj);

    const errors_arr = try rt.heap.newArray(r.array_prototype);
    root_buf[4] = Value.fromObject(errors_arr);

    const iter = try iterator.getIterator(rt, errors_arg);
    root_buf[5] = Value.fromObject(iter);

    while (try iterator.iteratorNextVal(rt, iter)) |elem| {
        root_buf[6] = elem;
        try rt.heap.appendElement(errors_arr, elem);
        root_buf[6] = .undefined;
    }

    try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("errors"), .{ .value = root_buf[4], .enumerable = false });
    return root_buf[3];
}

// ---------------------------------------------------------------- RegExp (M30, D61)
