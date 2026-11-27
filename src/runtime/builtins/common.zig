//! Shared coercion, descriptor, and registration helpers for built-ins.

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
const names = @import("../builtin_names.zig");
const builtins = @import("../builtins.zig");
const function_error = @import("function_error.zig");
const obj_builtins = @import("object.zig");
const proxy_reflect = @import("proxy_reflect.zig");

pub fn builtin(h: *heap_mod.Heap, proto: ?*Object, b: names.Builtin) Error!*Object {
    const o = try h.newObject(proto);
    o.builtin = b;
    return o;
}

pub fn method(rt: *Runtime, o: *Object, name: []const u8, n: *const Native) Error!void {
    const k = try rt.heap.internAscii(name);
    try rt.heap.defineProperty(o, k, .{ .value = Value.fromNative(n), .enumerable = false });
}

pub fn symbolMethod(rt: *Runtime, o: *Object, sym: *heap_mod.Symbol, n: *const Native) Error!void {
    try rt.heap.definePropKey(o, heap_mod.PropKey.fromSymbol(sym), .{ .value = Value.fromNative(n), .enumerable = false });
}

pub fn defineToStringTag(rt: *Runtime, o: *Object, sym: *heap_mod.Symbol, tag: []const u8) Error!void {
    try rt.heap.definePropKey(o, heap_mod.PropKey.fromSymbol(sym), .{
        .value = Value.fromString(try rt.heap.ascii(tag)),
        .enumerable = false,
        .writable = false,
        .configurable = true,
    });
}

pub fn link(rt: *Runtime, o: *Object, name: []const u8, target: *Object) Error!void {
    const k = try rt.heap.internAscii(name);
    try rt.heap.defineProperty(o, k, .{ .value = Value.fromObject(target), .enumerable = false, .writable = false });
}

pub fn constant(rt: *Runtime, o: *Object, name: []const u8, v: Value) Error!void {
    const k = try rt.heap.internAscii(name);
    try rt.heap.defineProperty(o, k, .{ .value = v, .enumerable = false });
}

pub fn immutableConstant(rt: *Runtime, o: *Object, name: []const u8, v: Value) Error!void {
    const k = try rt.heap.internAscii(name);
    try rt.heap.defineProperty(o, k, .{ .value = v, .enumerable = false, .writable = false, .configurable = false });
}

pub const species_getter: Native = .{ .name = "get [Symbol.species]", .call = speciesGetter };

pub fn speciesGetter(_: *Runtime, this: Value, _: []const Value) Error!Value {
    return this;
}

pub fn constructValue(rt: *Runtime, ctor: Value, args: []const Value) Error!Value {
    return switch (ctor.unpack()) {
        .closure => |c| rt.constructClosure(c, args, ctor),
        .native => builtins.construct(rt, ctor, args),
        .object => |o| if (o.kind == .proxy) proxy_reflect.callProxyConstruct(rt, o, args, ctor) else rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }}),
        else => rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }}),
    };
}

pub fn speciesConstructor(rt: *Runtime, o_val: Value, default_ctor: Value) Error!Value {
    var root_buf = [_]Value{ o_val, default_ctor, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const ctor = try object.get(rt, o_val, try object.named(rt, "constructor"));
    if (ctor.isUndefined()) return default_ctor;
    if (!ctor.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Species constructor is not an object" }});
    }
    root_buf[2] = ctor;
    const r = try builtins.realm(rt);
    const s = try object.get(rt, ctor, .{ .symbol = r.sym_species });
    if (s.isUndefined() or s.isNull()) return default_ctor;
    if (!function_error.isConstructor(s)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Species is not a constructor" }});
    }
    return s;
}

const array = @import("array.zig");

pub fn arraySpeciesCreate(rt: *Runtime, original: Value, len: usize) Error!Value {
    const r = try builtins.realm(rt);
    if (!try array.isArray(rt, original)) {
        return Value.fromObject(try rt.heap.newArray(r.array_prototype));
    }
    var root_buf = [_]Value{ original, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const ctor = try object.get(rt, original, try object.named(rt, "constructor"));
    if (ctor.isUndefined()) {
        return Value.fromObject(try rt.heap.newArray(r.array_prototype));
    }
    if (!ctor.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Array constructor is not an object" }});
    }
    root_buf[1] = ctor;
    const s = try object.get(rt, ctor, .{ .symbol = r.sym_species });
    if (s.isUndefined() or s.isNull() or (s.isNative() and s.asNative() == &builtins.array_global)) {
        return Value.fromObject(try rt.heap.newArray(r.array_prototype));
    }
    if (!function_error.isConstructor(s)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Array species is not a constructor" }});
    }
    return constructValue(rt, s, &.{Value.fromNumber(@floatFromInt(len))});
}

pub fn indexKey(rt: *Runtime, idx: usize) Error!object.Key {
    if (idx < std.math.maxInt(u32)) return .{ .index = @intCast(idx) };
    var buf: [20]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch unreachable;
    return object.namedAtom(try rt.heap.internAscii(s));
}

pub fn arrayAppendOrDefine(rt: *Runtime, out: Value, idx: usize, val: Value) Error!void {
    if (out.isObject() and out.asObject().kind == .array and !out.asObject().has_index_overrides and out.asObject().array_elements_writable and out.asObject().array_elements_configurable) {
        const arr = out.asObject();
        const cur = arr.kind.array.items.len;
        if (idx < cur and (arr.extensible or !arr.kind.array.items[idx].isHole())) {
            rt.heap.storeElement(arr, idx, val);
            return;
        }
        if (arr.extensible and arr.array_length_writable) {
            if (idx == cur) {
                try rt.heap.appendElement(arr, val);
                return;
            }
            if (idx < heap_mod.Heap.MAX_DENSE_ARRAY_LEN) {
                try rt.heap.growElementsWithHoles(arr, idx);
                try rt.heap.appendElement(arr, val);
                return;
            }
        }
    }
    var root_buf = [_]Value{ out, val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const k = try indexKey(rt, idx);
    _ = try obj_builtins.defineOwnPropertyParsed(rt, out, k, .{
        .has_val = true,
        .val = val,
        .has_writ = true,
        .writ_val = true,
        .has_enum = true,
        .enum_val = true,
        .has_conf = true,
        .conf_val = true,
    }, true);
}

pub fn notCallable(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    _ = this;
    _ = args;
    return rt.fail(.builtin); // Object(…) / Array(…): the constructors themselves
}

/// Evaluates `new callee(args...)` for built-in constructors (M14).
pub fn printImpl(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    _ = this;
    for (args, 0..) |value, i| {
        if (i > 0) try rt.out.writeByte(' ');
        if (value.isSymbol()) {
            try rt.out.writeAll("Symbol(");
            if (value.asSymbol().description) |d| try ops.writeUtf16(rt.out, d.units);
            try rt.out.writeByte(')');
            continue;
        }
        var buf: ops.NumberBuf = undefined;
        switch (try ops.toPiece(rt, value, &buf)) {
            .ascii => |s| try rt.out.writeAll(s),
            .utf16 => |units| try ops.writeUtf16(rt.out, units),
        }
    }
    try rt.out.writeByte('\n');
    return .undefined;
}

pub fn consoleAssertImpl(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    _ = this;
    if (args.len > 0 and ops.toBoolean(args[0])) return .undefined;
    if (args.len <= 1) {
        try rt.out.writeAll("Assertion failed\n");
        return .undefined;
    }
    try rt.out.writeAll("Assertion failed: ");
    return printImpl(rt, .undefined, args[1..]);
}

pub fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else .undefined;
}

/// A member called on a receiver it doesn't implement (e.g. push on a non-array):
/// node would do something generic that ZQJS doesn't.
pub fn unsupportedReceiver(rt: *Runtime, name: []const u8) Error {
    rt.unsupported_name = try rt.heap.internAscii(name);
    return rt.fail(.builtin);
}

// ---------------------------------------------------------------- Object.prototype

/// Allocates an ES unmapped `arguments` object (CreateUnmappedArgumentsObject).
pub fn requireCallable(rt: *Runtime, v: Value) Error!Value {
    return switch (v.unpack()) {
        .native, .closure => v,
        else => rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }}),
    };
}

pub fn toIntegerOrInfinity(rt: *Runtime, v: Value) Error!f64 {
    const n = try ops.toNumber(rt, v);
    if (std.math.isNan(n) or n == 0) return 0;
    return @trunc(n);
}

pub fn resolveRelativeIndex(n: f64, len: usize) usize {
    const len_f: f64 = @floatFromInt(len);
    const k = if (n < 0) @max(len_f + n, 0) else @min(n, len_f);
    return @intFromFloat(k);
}

pub fn resolveSearchStart(n: f64, len: usize) ?usize {
    const len_f: f64 = @floatFromInt(len);
    if (n >= len_f) return null;
    if (n >= 0) return @intFromFloat(n);
    const k = len_f + n;
    return if (k < 0) 0 else @intFromFloat(k);
}

pub fn sameValueZero(a: Value, b: Value) bool {
    if (a.isNumber() and b.isNumber() and std.math.isNan(a.asNumber()) and std.math.isNan(b.asNumber())) return true;
    return ops.strictEquals(a, b);
}

pub fn toObjectReceiver(rt: *Runtime, this: Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    return if (this.isObjectLike()) this else obj_builtins.objectConstruct(rt, &.{this});
}

/// ZQJS arrays are always dense (D13), so `slice()` always returns a dense array;
/// sparse-array hole preservation is not supported because holes are rejected at creation.
pub fn toStringObj(rt: *Runtime, v: Value) Error!*const heap_mod.String {
    if (v.isString()) return v.asString();
    var buf: ops.NumberBuf = undefined;
    const piece = try ops.toPiece(rt, v, &buf);
    return rt.heap.newString(&.{piece});
}

pub fn toStringUnits(rt: *Runtime, v: Value) Error![]const u16 {
    return (try toStringObj(rt, v)).units;
}

pub fn isJsWhitespace(u: u16) bool {
    return switch (u) {
        0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

pub fn appendUnits(rt: *Runtime, out: *std.ArrayList(u16), units: []const u16) Error!void {
    const max_len = rt.heap.max_string_length;
    if (units.len > max_len or out.items.len > max_len - units.len) return rt.limit(.string_length);
    try out.appendSlice(rt.gpa, units);
}

pub fn sameValue(a: Value, b: Value) bool {
    if (a.isNumber() and b.isNumber()) {
        if (std.math.isNan(a.asNumber()) and std.math.isNan(b.asNumber())) return true;
        return @as(u64, @bitCast(a.asNumber())) == @as(u64, @bitCast(b.asNumber()));
    }
    return sameValueZero(a, b);
}

pub fn keyToRootValue(k: object.Key) Value {
    return switch (k) {
        .atom => |a| Value.fromString(a),
        .symbol => |s| Value.fromSymbol(s),
        .index => .undefined,
    };
}

pub fn keyToString(rt: *Runtime, k: object.Key) Error!*heap_mod.String {
    return switch (k) {
        .atom => |a| a,
        .index => |i| blk: {
            var buf: [10]u8 = undefined;
            break :blk try rt.heap.ascii(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
        },
        .symbol => unreachable,
    };
}

pub fn toLength(rt: *Runtime, v: Value) Error!f64 {
    const len = try toIntegerOrInfinity(rt, v);
    if (len <= 0) return 0;
    return @min(len, 9007199254740991.0);
}

pub fn keyToValue(rt: *Runtime, k: object.Key) Error!Value {
    return switch (k) {
        .atom => |a| Value.fromString(a),
        .symbol => |s| Value.fromSymbol(s),
        .index => |i| Value.fromString(try keyToString(rt, .{ .index = i })),
    };
}

pub fn eqlAscii(units: []const u16, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |u, a| {
        if (u != a) return false;
    }
    return true;
}
