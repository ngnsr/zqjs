//! The built-in objects and functions ZQJS implements (DESIGN_DECISIONS D39), and global
//! name lookup.
//!
//! Three kinds of names, for globals and for properties of built-in objects:
//!   implemented   here, with their behaviour (the only ones that produce values)
//!   known         node has them (builtin_names.zig, generated from node) but ZQJS
//!                 doesn't implement them: Unsupported(builtin), naming the member
//!   nonexistent   neither: a global is a ReferenceError, a property `undefined`
//!
//! Implemented in M7:
//!   globals             undefined NaN Infinity print Object Array
//!   Object              keys create getPrototypeOf
//!   Array               isArray
//!   Object.prototype    toString valueOf
//!   Array.prototype     push pop join toString
//!   String.prototype    charCodeAt
//! Calling `Object(…)` or `Array(…)` themselves is Unsupported(builtin).
//!
//! The realm (the built-in objects) is created on first use, so creating a Runtime
//! can't fail. GC roots (D38): every object in Realm.

const std = @import("std");
const Value = @import("value.zig").Value;
const Native = @import("value.zig").Native;
const heap_mod = @import("heap.zig");
const Object = heap_mod.Object;
const rt_mod = @import("runtime.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const ops = @import("ops.zig");
const object = @import("object.zig");
const names = @import("builtin_names.zig");

pub const Realm = struct {
    object_prototype: *Object,
    array_prototype: *Object,
    string_prototype: *Object,
    number_prototype: *Object,
    boolean_prototype: *Object,
    function_prototype: *Object,
    /// Static members of the `Object` and `Array` globals.
    object_namespace: *Object,
    array_namespace: *Object,
    math: *Object,

    /// For GC roots (M8) and tests.
    pub fn objects(r: *const Realm) [9]*Object {
        return .{ r.object_prototype, r.array_prototype, r.string_prototype, r.number_prototype, r.boolean_prototype, r.function_prototype, r.object_namespace, r.array_namespace, r.math };
    }
};

pub fn realm(rt: *Runtime) Error!*const Realm {
    if (rt.realm) |*r| return r;
    const h = &rt.heap;
    const object_prototype = try builtin(h, null, .object_prototype);
    var r: Realm = .{
        .object_prototype = object_prototype,
        .array_prototype = try builtin(h, object_prototype, .array_prototype),
        .string_prototype = try builtin(h, object_prototype, .string_prototype),
        .number_prototype = try builtin(h, object_prototype, .number_prototype),
        .boolean_prototype = try builtin(h, object_prototype, .boolean_prototype),
        .function_prototype = try builtin(h, object_prototype, .function_prototype),
        .object_namespace = try builtin(h, null, .object_constructor),
        .array_namespace = try builtin(h, null, .array_constructor),
        .math = try builtin(h, object_prototype, .math),
    };
    try method(rt, r.object_prototype, "toString", &object_to_string);
    try method(rt, r.object_prototype, "valueOf", &object_value_of);
    try method(rt, r.array_prototype, "push", &array_push);
    try method(rt, r.array_prototype, "pop", &array_pop);
    try method(rt, r.array_prototype, "join", &array_join);
    try method(rt, r.array_prototype, "toString", &array_to_string);
    try method(rt, r.string_prototype, "charCodeAt", &string_char_code_at);
    try method(rt, r.object_namespace, "keys", &object_keys);
    try method(rt, r.object_namespace, "create", &object_create);
    try method(rt, r.object_namespace, "getPrototypeOf", &object_get_prototype_of);
    try method(rt, r.array_namespace, "isArray", &array_is_array);
    try registerMath(rt, r.math);
    _ = &r;
    rt.realm = r;
    return &rt.realm.?;
}

fn builtin(h: *heap_mod.Heap, proto: ?*Object, b: names.Builtin) Error!*Object {
    const o = try h.newObject(proto);
    o.builtin = b;
    return o;
}

fn method(rt: *Runtime, o: *Object, name: []const u8, n: *const Native) Error!void {
    const k = try rt.heap.internAscii(name);
    try rt.heap.defineProperty(o, k, .{ .value = .{ .native = n }, .enumerable = false });
}

fn constant(rt: *Runtime, o: *Object, name: []const u8, v: Value) Error!void {
    const k = try rt.heap.internAscii(name);
    try rt.heap.defineProperty(o, k, .{ .value = v, .enumerable = false });
}

/// The natives ToPrimitive may call (D40); anything else found there is user code.
pub fn isConversion(n: *const Native) bool {
    return n == &object_to_string or n == &object_value_of or n == &array_to_string;
}

// ---------------------------------------------------------------- globals

pub const print: Native = .{ .name = "print", .call = printImpl };
pub const object_global: Native = .{ .name = "Object", .call = notCallable, .namespace = .object };
pub const array_global: Native = .{ .name = "Array", .call = notCallable, .namespace = .array };

/// A global read: implemented, host-registered (M9.1, D53), known to node (Unsupported),
/// or a ReferenceError.
pub fn global(rt: *Runtime, name: []const u8) Error!Value {
    if (std.mem.eql(u8, name, "undefined")) return .undefined;
    if (std.mem.eql(u8, name, "NaN")) return .{ .number = std.math.nan(f64) };
    if (std.mem.eql(u8, name, "Infinity")) return .{ .number = std.math.inf(f64) };
    if (std.mem.eql(u8, name, "print")) return .{ .native = &print };
    if (std.mem.eql(u8, name, "Object")) return .{ .native = &object_global };
    if (std.mem.eql(u8, name, "Array")) return .{ .native = &array_global };
    if (std.mem.eql(u8, name, "Math")) return .{ .object = (try realm(rt)).math };
    for (rt.host_globals.items) |n| if (std.mem.eql(u8, n.name, name)) return .{ .native = n };
    if (names.has(.global, name)) {
        rt.unsupported_name = try rt.heap.internAscii(name);
        return rt.fail(.builtin);
    }
    return rt.throw(.ReferenceError, &.{ .{ .ascii = name }, .{ .ascii = " is not defined" } });
}

/// Whether `name` is already a built-in or node-known global name (D53: duplicate
/// registration is rejected, including built-in names).
pub fn isBuiltinGlobal(name: []const u8) bool {
    return std.mem.eql(u8, name, "print") or names.has(.global, name);
}

fn notCallable(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    _ = this;
    _ = args;
    return rt.fail(.builtin); // Object(…) / Array(…): the constructors themselves
}

/// `print(a, b, …)` writes `String(a) + " " + String(b) + … + "\n"`. The node test
/// harness defines the same function, so outputs compare byte for byte.
fn printImpl(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    _ = this;
    for (args, 0..) |value, i| {
        if (i > 0) try rt.out.writeByte(' ');
        var buf: ops.NumberBuf = undefined;
        switch (try ops.toPiece(rt, value, &buf)) {
            .ascii => |s| try rt.out.writeAll(s),
            .utf16 => |units| try ops.writeUtf16(rt.out, units),
        }
    }
    try rt.out.writeByte('\n');
    return .undefined;
}

fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else .undefined;
}

/// A member called on a receiver it doesn't implement (e.g. push on a non-array):
/// node would do something generic that ZQJS doesn't.
fn unsupportedReceiver(rt: *Runtime, name: []const u8) Error {
    rt.unsupported_name = try rt.heap.internAscii(name);
    return rt.fail(.builtin);
}

// ---------------------------------------------------------------- Object.prototype

const object_to_string: Native = .{ .name = "toString", .call = objectToString };
const object_value_of: Native = .{ .name = "valueOf", .call = objectValueOf };

fn objectToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const tag: []const u8 = switch (this) {
        .undefined => "Undefined",
        .null => "Null",
        .boolean => "Boolean",
        .number => "Number",
        .string => "String",
        .native, .closure => "Function",
        .object => |o| if (o.kind == .array) "Array" else "Object",
    };
    return .{ .string = try rt.heap.newString(&.{ .{ .ascii = "[object " }, .{ .ascii = tag }, .{ .ascii = "]" } }) };
}

fn objectValueOf(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return switch (this) {
        .object => this,
        else => unsupportedReceiver(rt, "valueOf"), // ToObject: a wrapper object
    };
}

// ---------------------------------------------------------------- Array.prototype

const array_push: Native = .{ .name = "push", .call = arrayPush };
const array_pop: Native = .{ .name = "pop", .call = arrayPop };
const array_join: Native = .{ .name = "join", .call = arrayJoin };
const array_to_string: Native = .{ .name = "toString", .call = arrayToString };

fn thisArray(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this == .object and this.object.kind == .array) return this.object;
    return unsupportedReceiver(rt, name);
}

fn arrayPush(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "push");
    try rt.heap.appendElements(a, args);
    return .{ .number = @floatFromInt(a.kind.array.items.len) };
}

fn arrayPop(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const a = try thisArray(rt, this, "pop");
    return rt.heap.popElement(a) orelse .undefined;
}

fn arrayJoin(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "join");
    const sep = arg(args, 0);
    if (sep == .undefined) return .{ .string = try object.join(rt, a, &.{','}) };
    var buf: ops.NumberBuf = undefined;
    const piece = try ops.toPiece(rt, sep, &buf);
    const s = switch (piece) {
        .utf16 => |u| u,
        .ascii => (try rt.heap.newString(&.{piece})).units,
    };
    return .{ .string = try object.join(rt, a, s) };
}

/// Array.prototype.toString calls `this.join`; a user-replaced join is user code.
fn arrayToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const j = try object.get(rt, this, try object.named(rt, "join"));
    if (j == .native and j.native == &array_join) return arrayJoin(rt, this, &.{});
    if (j == .closure or j == .native) return rt.fail(.user_conversion);
    return objectToString(rt, this, &.{}); // join not callable: the Object.prototype one
}

// ---------------------------------------------------------------- String.prototype

const string_char_code_at: Native = .{ .name = "charCodeAt", .call = stringCharCodeAt };

fn stringCharCodeAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = switch (this) {
        .string => |s| s,
        else => return unsupportedReceiver(rt, "charCodeAt"),
    };
    const n = try ops.toNumber(rt, arg(args, 0));
    const pos = if (std.math.isNan(n)) 0 else @trunc(n); // ToIntegerOrInfinity
    if (pos < 0 or pos >= @as(f64, @floatFromInt(s.units.len))) return .{ .number = std.math.nan(f64) };
    return .{ .number = @floatFromInt(s.units[@intFromFloat(pos)]) }; // a UTF-16 code unit
}

// ---------------------------------------------------------------- Object, Array

const object_keys: Native = .{ .name = "keys", .call = objectKeys };
const object_create: Native = .{ .name = "create", .call = objectCreate };
const object_get_prototype_of: Native = .{ .name = "getPrototypeOf", .call = objectGetPrototypeOf };
const array_is_array: Native = .{ .name = "isArray", .call = arrayIsArray };

fn objectKeys(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    switch (arg(args, 0)) {
        .undefined, .null => return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }}),
        .boolean, .number => {},
        .native, .closure => return rt.fail(.function_properties),
        .string => |s| for (0..s.units.len) |i| try pushKey(rt, out, .{ .index = @intCast(i) }),
        .object => |o| {
            const keys = try object.ownKeys(rt, o);
            defer rt.gpa.free(keys);
            for (keys) |k| try pushKey(rt, out, k);
        },
    }
    return .{ .object = out };
}

fn pushKey(rt: *Runtime, out: *Object, k: object.Key) Error!void {
    const s = switch (k) {
        .atom => |a| a,
        .index => |i| blk: {
            var buf: [10]u8 = undefined;
            break :blk try rt.heap.ascii(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
        },
    };
    try rt.heap.appendElement(out, .{ .string = s });
}

fn objectCreate(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    if (args.len > 1 and args[1] != .undefined) return unsupportedReceiver(rt, "create"); // property descriptors
    const proto: ?*Object = switch (arg(args, 0)) {
        .object => |o| o,
        .null => null,
        // A function is an object in node; ZQJS functions aren't (yet).
        .native, .closure => return rt.fail(.function_properties),
        else => return rt.throw(.TypeError, &.{.{ .ascii = "Object prototype may only be an Object or null" }}),
    };
    return .{ .object = try rt.heap.newObject(proto) };
}

fn objectGetPrototypeOf(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try realm(rt);
    const p: ?*Object = switch (arg(args, 0)) {
        .undefined, .null => return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }}),
        .boolean => r.boolean_prototype,
        .number => r.number_prototype,
        .string => r.string_prototype,
        .native, .closure => r.function_prototype,
        .object => |o| o.proto,
    };
    return if (p) |o| .{ .object = o } else .null;
}

fn arrayIsArray(_: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = arg(args, 0);
    return .{ .boolean = v == .object and v.object.kind == .array };
}

// ---------------------------------------------------------------- Math (M11.3)

fn registerMath(rt: *Runtime, m: *Object) Error!void {
    try constant(rt, m, "E", .{ .number = std.math.e });
    try constant(rt, m, "LN2", .{ .number = std.math.ln2 });
    try constant(rt, m, "LN10", .{ .number = std.math.ln10 });
    try constant(rt, m, "LOG2E", .{ .number = std.math.log2e });
    try constant(rt, m, "LOG10E", .{ .number = std.math.log10e });
    try constant(rt, m, "PI", .{ .number = std.math.pi });
    try constant(rt, m, "SQRT1_2", .{ .number = std.math.sqrt1_2 });
    try constant(rt, m, "SQRT2", .{ .number = std.math.sqrt2 });

    try method(rt, m, "abs", &math_abs);
    try method(rt, m, "floor", &math_floor);
    try method(rt, m, "ceil", &math_ceil);
    try method(rt, m, "round", &math_round);
    try method(rt, m, "trunc", &math_trunc);
    try method(rt, m, "min", &math_min);
    try method(rt, m, "max", &math_max);
    try method(rt, m, "pow", &math_pow);
    try method(rt, m, "sqrt", &math_sqrt);
    try method(rt, m, "sin", &math_sin);
    try method(rt, m, "cos", &math_cos);
    try method(rt, m, "tan", &math_tan);
    try method(rt, m, "asin", &math_asin);
    try method(rt, m, "acos", &math_acos);
    try method(rt, m, "atan", &math_atan);
    try method(rt, m, "atan2", &math_atan2);
    try method(rt, m, "log", &math_log);
    try method(rt, m, "exp", &math_exp);
    try method(rt, m, "sign", &math_sign);
    try method(rt, m, "clz32", &math_clz32);
    try method(rt, m, "imul", &math_imul);
    try method(rt, m, "fround", &math_fround);
    try method(rt, m, "hypot", &math_hypot);
    try method(rt, m, "random", &math_random);
}

const math_abs: Native = .{ .name = "abs", .call = mathAbs };
const math_floor: Native = .{ .name = "floor", .call = mathFloor };
const math_ceil: Native = .{ .name = "ceil", .call = mathCeil };
const math_round: Native = .{ .name = "round", .call = mathRound };
const math_trunc: Native = .{ .name = "trunc", .call = mathTrunc };
const math_min: Native = .{ .name = "min", .call = mathMin };
const math_max: Native = .{ .name = "max", .call = mathMax };
const math_pow: Native = .{ .name = "pow", .call = mathPow };
const math_sqrt: Native = .{ .name = "sqrt", .call = mathSqrt };
const math_sin: Native = .{ .name = "sin", .call = mathSin };
const math_cos: Native = .{ .name = "cos", .call = mathCos };
const math_tan: Native = .{ .name = "tan", .call = mathTan };
const math_asin: Native = .{ .name = "asin", .call = mathAsin };
const math_acos: Native = .{ .name = "acos", .call = mathAcos };
const math_atan: Native = .{ .name = "atan", .call = mathAtan };
const math_atan2: Native = .{ .name = "atan2", .call = mathAtan2 };
const math_log: Native = .{ .name = "log", .call = mathLog };
const math_exp: Native = .{ .name = "exp", .call = mathExp };
const math_sign: Native = .{ .name = "sign", .call = mathSign };
const math_clz32: Native = .{ .name = "clz32", .call = mathClz32 };
const math_imul: Native = .{ .name = "imul", .call = mathImul };
const math_fround: Native = .{ .name = "fround", .call = mathFround };
const math_hypot: Native = .{ .name = "hypot", .call = mathHypot };
const math_random: Native = .{ .name = "random", .call = mathRandom };

fn mathAbs(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = @abs(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathFloor(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = @floor(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathCeil(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = @ceil(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathTrunc(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = @trunc(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathRound(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const x = try ops.toNumber(rt, arg(args, 0));
    if (!std.math.isFinite(x) or x == 0.0) return .{ .number = x };
    if (x >= -0.5 and x < 0.0) return .{ .number = -0.0 };
    if (@abs(x) >= 4503599627370496.0) return .{ .number = x };
    const f = @floor(x);
    return .{ .number = if (x - f >= 0.5) f + 1.0 else f };
}

fn mathMin(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    var best = std.math.inf(f64);
    var saw_nan = false;
    for (args) |a| {
        const v = try ops.toNumber(rt, a);
        if (std.math.isNan(v)) {
            saw_nan = true;
        } else if (!saw_nan) {
            if (v < best or (v == 0.0 and best == 0.0 and std.math.signbit(v))) best = v;
        }
    }
    return .{ .number = if (saw_nan) std.math.nan(f64) else best };
}

fn mathMax(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    var best = -std.math.inf(f64);
    var saw_nan = false;
    for (args) |a| {
        const v = try ops.toNumber(rt, a);
        if (std.math.isNan(v)) {
            saw_nan = true;
        } else if (!saw_nan) {
            if (v > best or (v == 0.0 and best == 0.0 and !std.math.signbit(v))) best = v;
        }
    }
    return .{ .number = if (saw_nan) std.math.nan(f64) else best };
}

fn mathPow(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const base = try ops.toNumber(rt, arg(args, 0));
    const exp = try ops.toNumber(rt, arg(args, 1));
    return .{ .number = ops.pow(base, exp) };
}

fn mathSqrt(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = std.math.sqrt(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathSin(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = std.math.sin(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathCos(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = std.math.cos(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathTan(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = std.math.tan(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathAsin(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = std.math.asin(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathAcos(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = std.math.acos(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathAtan(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = std.math.atan(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathAtan2(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const y = try ops.toNumber(rt, arg(args, 0));
    const x = try ops.toNumber(rt, arg(args, 1));
    return .{ .number = std.math.atan2(y, x) };
}

fn mathLog(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = @log(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathExp(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = @exp(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathSign(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const x = try ops.toNumber(rt, arg(args, 0));
    if (std.math.isNan(x) or x == 0.0) return .{ .number = x };
    return .{ .number = if (x > 0.0) 1.0 else -1.0 };
}

fn toUint32(n: f64) u32 {
    if (!std.math.isFinite(n) or n == 0.0) return 0;
    const rem = @mod(@trunc(n), 4294967296.0);
    return @intFromFloat(rem);
}

fn mathClz32(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const u = toUint32(try ops.toNumber(rt, arg(args, 0)));
    return .{ .number = @floatFromInt(@clz(u)) };
}

fn mathImul(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const a: i32 = @bitCast(toUint32(try ops.toNumber(rt, arg(args, 0))));
    const b: i32 = @bitCast(toUint32(try ops.toNumber(rt, arg(args, 1))));
    return .{ .number = @floatFromInt(a *% b) };
}

fn mathFround(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const x = try ops.toNumber(rt, arg(args, 0));
    if (!std.math.isFinite(x) or x == 0.0) return .{ .number = x };
    return .{ .number = @as(f64, @floatCast(@as(f32, @floatCast(x)))) };
}

fn mathHypot(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    var max_abs: f64 = 0.0;
    var saw_inf = false;
    var saw_nan = false;
    for (args) |a| {
        const v = try ops.toNumber(rt, a);
        if (std.math.isInf(v)) {
            saw_inf = true;
        } else if (std.math.isNan(v)) {
            saw_nan = true;
        } else {
            const av = @abs(v);
            if (av > max_abs) max_abs = av;
        }
    }
    if (saw_inf) return .{ .number = std.math.inf(f64) };
    if (saw_nan) return .{ .number = std.math.nan(f64) };
    if (max_abs == 0.0) return .{ .number = 0.0 };
    var sum: f64 = 0.0;
    for (args) |a| {
        const v = try ops.toNumber(rt, a);
        const s = v / max_abs;
        sum += s * s;
    }
    return .{ .number = max_abs * std.math.sqrt(sum) };
}

fn mathRandom(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return .{ .number = rt.nextRandom() };
}
