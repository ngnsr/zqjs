//! Number, BigInt, Boolean, Symbol, Math, Date, and global numeric/URI built-ins.

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
const date = @import("../date.zig");
const builtins = @import("../builtins.zig");
const common = @import("common.zig");
const function_error = @import("function_error.zig");

pub fn register(rt: *Runtime, r: *const builtins.Realm) Error!void {
    try common.method(rt, r.number_namespace, "isInteger", &number_is_integer);
    try common.method(rt, r.number_namespace, "isFinite", &number_is_finite);
    try common.method(rt, r.number_namespace, "isNaN", &number_is_nan);
    try common.method(rt, r.number_namespace, "isSafeInteger", &number_is_safe_integer);
    try common.immutableConstant(rt, r.number_namespace, "MAX_SAFE_INTEGER", Value.fromNumber(9007199254740991.0));
    try common.immutableConstant(rt, r.number_namespace, "MIN_SAFE_INTEGER", Value.fromNumber(-9007199254740991.0));
    try common.immutableConstant(rt, r.number_namespace, "EPSILON", Value.fromNumber(std.math.floatEps(f64)));
    try common.immutableConstant(rt, r.number_namespace, "MAX_VALUE", Value.fromNumber(std.math.floatMax(f64)));
    try common.immutableConstant(rt, r.number_namespace, "MIN_VALUE", Value.fromNumber(std.math.floatTrueMin(f64)));
    try common.immutableConstant(rt, r.number_namespace, "POSITIVE_INFINITY", Value.fromNumber(std.math.inf(f64)));
    try common.immutableConstant(rt, r.number_namespace, "NEGATIVE_INFINITY", Value.fromNumber(-std.math.inf(f64)));
    try common.immutableConstant(rt, r.number_namespace, "NaN", Value.fromNumber(std.math.nan(f64)));
    try registerMath(rt, r.math);
    try common.immutableConstant(rt, r.date_namespace, "prototype", Value.fromObject(r.date_prototype));
    try common.method(rt, r.date_namespace, "now", &date_now);
    try common.method(rt, r.date_namespace, "UTC", &date_utc);
    try common.method(rt, r.date_namespace, "parse", &date_parse);
    try common.constant(rt, r.date_prototype, "constructor", Value.fromNative(&builtins.date_global));
    try common.method(rt, r.date_prototype, "getTime", &date_get_time);
    try common.method(rt, r.date_prototype, "valueOf", &date_value_of);
    try common.method(rt, r.date_prototype, "getTimezoneOffset", &date_get_timezone_offset);
    try common.method(rt, r.date_prototype, "setTime", &date_set_time);
    try common.method(rt, r.date_prototype, "getUTCFullYear", &date_get_utc_full_year);
    try common.method(rt, r.date_prototype, "getUTCMonth", &date_get_utc_month);
    try common.method(rt, r.date_prototype, "getUTCDate", &date_get_utc_date);
    try common.method(rt, r.date_prototype, "getUTCDay", &date_get_utc_day);
    try common.method(rt, r.date_prototype, "getUTCHours", &date_get_utc_hours);
    try common.method(rt, r.date_prototype, "getUTCMinutes", &date_get_utc_minutes);
    try common.method(rt, r.date_prototype, "getUTCSeconds", &date_get_utc_seconds);
    try common.method(rt, r.date_prototype, "getUTCMilliseconds", &date_get_utc_milliseconds);
    try common.method(rt, r.date_prototype, "setUTCFullYear", &date_set_utc_full_year);
    try common.method(rt, r.date_prototype, "setUTCMonth", &date_set_utc_month);
    try common.method(rt, r.date_prototype, "setUTCDate", &date_set_utc_date);
    try common.method(rt, r.date_prototype, "setUTCHours", &date_set_utc_hours);
    try common.method(rt, r.date_prototype, "setUTCMinutes", &date_set_utc_minutes);
    try common.method(rt, r.date_prototype, "setUTCSeconds", &date_set_utc_seconds);
    try common.method(rt, r.date_prototype, "setUTCMilliseconds", &date_set_utc_milliseconds);
    try common.method(rt, r.date_prototype, "getFullYear", &date_get_full_year);
    try common.method(rt, r.date_prototype, "getMonth", &date_get_month);
    try common.method(rt, r.date_prototype, "getDate", &date_get_date);
    try common.method(rt, r.date_prototype, "getDay", &date_get_day);
    try common.method(rt, r.date_prototype, "getHours", &date_get_hours);
    try common.method(rt, r.date_prototype, "getMinutes", &date_get_minutes);
    try common.method(rt, r.date_prototype, "getSeconds", &date_get_seconds);
    try common.method(rt, r.date_prototype, "getMilliseconds", &date_get_milliseconds);
    try common.method(rt, r.date_prototype, "setFullYear", &date_set_full_year);
    try common.method(rt, r.date_prototype, "setMonth", &date_set_month);
    try common.method(rt, r.date_prototype, "setDate", &date_set_date);
    try common.method(rt, r.date_prototype, "setHours", &date_set_hours);
    try common.method(rt, r.date_prototype, "setMinutes", &date_set_minutes);
    try common.method(rt, r.date_prototype, "setSeconds", &date_set_seconds);
    try common.method(rt, r.date_prototype, "setMilliseconds", &date_set_milliseconds);
    try common.method(rt, r.date_prototype, "toISOString", &date_to_iso_string);
    try common.method(rt, r.date_prototype, "toUTCString", &date_to_utc_string);
    try common.method(rt, r.date_prototype, "toString", &date_to_string);
    try common.method(rt, r.date_prototype, "toDateString", &date_to_date_string);
    try common.method(rt, r.date_prototype, "toTimeString", &date_to_time_string);
    try common.method(rt, r.date_prototype, "toLocaleString", &date_to_locale_string);
    try common.method(rt, r.date_prototype, "toLocaleDateString", &date_to_locale_date_string);
    try common.method(rt, r.date_prototype, "toLocaleTimeString", &date_to_locale_time_string);
    try common.method(rt, r.date_prototype, "toJSON", &date_to_json);
    try rt.heap.definePropKey(r.date_prototype, heap_mod.PropKey.fromSymbol(r.sym_to_primitive), .{
        .value = Value.fromNative(&date_to_primitive),
        .enumerable = false,
        .writable = false,
        .configurable = true,
    });
    try common.immutableConstant(rt, r.number_namespace, "prototype", Value.fromObject(r.number_prototype));
    try common.constant(rt, r.number_prototype, "constructor", Value.fromNative(&builtins.number_global));
    try common.method(rt, r.number_prototype, "toString", &number_to_string);
    try common.method(rt, r.number_prototype, "toFixed", &number_to_fixed);
    try common.method(rt, r.number_prototype, "toExponential", &number_to_exponential);
    try common.method(rt, r.number_prototype, "toPrecision", &number_to_precision);
    try common.method(rt, r.number_prototype, "toLocaleString", &number_to_locale_string);
    try common.method(rt, r.number_prototype, "valueOf", &number_value_of);
    try common.immutableConstant(rt, r.boolean_namespace, "prototype", Value.fromObject(r.boolean_prototype));
    try common.constant(rt, r.boolean_prototype, "constructor", Value.fromNative(&builtins.boolean_global));
    try common.method(rt, r.boolean_prototype, "toString", &boolean_to_string);
    try common.method(rt, r.boolean_prototype, "valueOf", &boolean_value_of);
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("prototype"), .{
        .value = Value.fromObject(r.symbol_prototype),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("iterator"), .{
        .value = Value.fromSymbol(r.sym_iterator),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("asyncIterator"), .{
        .value = Value.fromSymbol(r.sym_async_iterator),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("toPrimitive"), .{
        .value = Value.fromSymbol(r.sym_to_primitive),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("toStringTag"), .{
        .value = Value.fromSymbol(r.sym_to_string_tag),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("hasInstance"), .{
        .value = Value.fromSymbol(r.sym_has_instance),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("species"), .{
        .value = Value.fromSymbol(r.sym_species),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("match"), .{
        .value = Value.fromSymbol(r.sym_match),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("replace"), .{
        .value = Value.fromSymbol(r.sym_replace),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("search"), .{
        .value = Value.fromSymbol(r.sym_search),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("split"), .{
        .value = Value.fromSymbol(r.sym_split),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("matchAll"), .{
        .value = Value.fromSymbol(r.sym_match_all),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("isConcatSpreadable"), .{
        .value = Value.fromSymbol(r.sym_is_concat_spreadable),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try common.defineToStringTag(rt, r.symbol_prototype, r.sym_to_string_tag, "Symbol");
    try rt.heap.definePropKey(r.symbol_prototype, heap_mod.PropKey.fromSymbol(r.sym_to_primitive), .{
        .value = Value.fromNative(&symbol_to_primitive),
        .enumerable = false,
        .writable = false,
        .configurable = true,
    });
    try common.defineToStringTag(rt, r.math, r.sym_to_string_tag, "Math");
    try common.method(rt, r.symbol_namespace, "for", &symbol_for);
    try common.method(rt, r.symbol_namespace, "keyFor", &symbol_key_for);
    try common.constant(rt, r.symbol_prototype, "constructor", Value.fromNative(&builtins.symbol_global));
    try common.method(rt, r.symbol_prototype, "toString", &symbol_to_string);
    try common.method(rt, r.symbol_prototype, "valueOf", &symbol_value_of);
    try object.defineAccessor(rt, Value.fromObject(r.symbol_prototype), try object.named(rt, "description"), Value.fromNative(&symbol_description_getter), false, false);
    try rt.heap.defineProperty(r.bigint_namespace, try rt.heap.internAscii("prototype"), .{
        .value = Value.fromObject(r.bigint_prototype),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try common.method(rt, r.bigint_namespace, "asIntN", &bigint_as_int_n);
    try common.method(rt, r.bigint_namespace, "asUintN", &bigint_as_uint_n);
    try common.constant(rt, r.bigint_prototype, "constructor", Value.fromNative(&builtins.bigint_global));
    try common.method(rt, r.bigint_prototype, "toString", &bigint_to_string);
    try common.method(rt, r.bigint_prototype, "valueOf", &bigint_value_of);
    try common.defineToStringTag(rt, r.bigint_prototype, r.sym_to_string_tag, "BigInt");
}

const boolean_to_string: Native = .{ .name = "toString", .length = 0, .call = booleanToString };

const boolean_value_of: Native = .{ .name = "valueOf", .length = 0, .call = booleanValueOf };

pub fn booleanCall(_: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(ops.toBoolean(common.arg(args, 0)));
}

pub fn booleanConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const b = Value.fromBool(ops.toBoolean(common.arg(args, 0)));
    const r = try builtins.realm(rt);
    return Value.fromObject(try rt.heap.newPrimitiveWrapper(r.boolean_prototype, b));
}

fn thisBoolean(rt: *Runtime, this: Value) Error!bool {
    if (this.isBool()) return this.asBool();
    if (this.isObject()) {
        const o = this.asObject();
        if (o.kind == .primitive_wrapper and o.kind.primitive_wrapper.isBool()) return o.kind.primitive_wrapper.asBool();
        if (o.builtin == .boolean_prototype) return false;
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "Boolean.prototype method requires a Boolean receiver" }});
}

fn booleanToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const b = try thisBoolean(rt, this);
    return Value.fromString(try rt.heap.ascii(if (b) "true" else "false"));
}

fn booleanValueOf(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return Value.fromBool(try thisBoolean(rt, this));
}

// ---------------------------------------------------------------- Symbol (M36, D66)

const symbol_for: Native = .{ .name = "for", .length = 1, .call = symbolFor };

const symbol_key_for: Native = .{ .name = "keyFor", .length = 1, .call = symbolKeyFor };

const symbol_to_string: Native = .{ .name = "toString", .call = symbolToString };

const symbol_value_of: Native = .{ .name = "valueOf", .call = symbolValueOf };

const symbol_description_getter: Native = .{ .name = "get description", .call = symbolDescriptionGetter };

const symbol_to_primitive: Native = .{ .name = "[Symbol.toPrimitive]", .length = 1, .call = symbolToPrimitive };

pub fn symbolDescriptiveString(rt: *Runtime, sym: *const heap_mod.Symbol) Error!*const heap_mod.String {
    return if (sym.description) |d|
        rt.heap.newString(&.{ .{ .ascii = "Symbol(" }, .{ .utf16 = d.units }, .{ .ascii = ")" } })
    else
        rt.heap.ascii("Symbol()");
}

pub fn symbolCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const desc: ?*const heap_mod.String = if (args.len == 0 or args[0].isUndefined())
        null
    else
        try common.toStringObj(rt, args[0]);
    return Value.fromSymbol(try rt.heap.newSymbol(desc, false));
}

fn symbolFor(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const key_str = try common.toStringObj(rt, common.arg(args, 0));
    if (rt.global_symbols.get(key_str)) |sym| {
        return Value.fromSymbol(sym);
    }
    var root_buf = [_]Value{Value.fromString(key_str)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const sym = try rt.heap.newSymbol(key_str, true);
    try rt.global_symbols.putNoClobber(rt.gpa, key_str, sym);
    return Value.fromSymbol(sym);
}

fn symbolKeyFor(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = common.arg(args, 0);
    if (!v.isSymbol()) return rt.throw(.TypeError, &.{.{ .ascii = "Symbol.keyFor requires a symbol argument" }});
    const sym = v.asSymbol();
    return if (sym.is_global) Value.fromString(sym.description.?) else .undefined;
}

fn thisSymbol(rt: *Runtime, this: Value, name: []const u8) Error!*const heap_mod.Symbol {
    return switch (this.unpack()) {
        .symbol => |s| s,
        .object => |o| if (o.kind == .primitive_wrapper and o.kind.primitive_wrapper.isSymbol())
            o.kind.primitive_wrapper.asSymbol()
        else
            rt.throw(.TypeError, &.{ .{ .ascii = "Symbol.prototype." }, .{ .ascii = name }, .{ .ascii = " requires that 'this' be a Symbol" } }),
        else => rt.throw(.TypeError, &.{ .{ .ascii = "Symbol.prototype." }, .{ .ascii = name }, .{ .ascii = " requires that 'this' be a Symbol" } }),
    };
}

fn symbolToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const sym = try thisSymbol(rt, this, "toString");
    return Value.fromString(try symbolDescriptiveString(rt, sym));
}

fn symbolValueOf(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return Value.fromSymbol(try thisSymbol(rt, this, "valueOf"));
}

fn symbolToPrimitive(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return Value.fromSymbol(try thisSymbol(rt, this, "[Symbol.toPrimitive]"));
}

fn symbolDescriptionGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const sym = try thisSymbol(rt, this, "description");
    return if (sym.description) |d| Value.fromString(d) else .undefined;
}

const number_is_integer: Native = .{ .name = "isInteger", .length = 1, .call = numberIsInteger };

const number_is_finite: Native = .{ .name = "isFinite", .length = 1, .call = numberIsFinite };

const number_is_nan: Native = .{ .name = "isNaN", .length = 1, .call = numberIsNaN };

const number_is_safe_integer: Native = .{ .name = "isSafeInteger", .length = 1, .call = numberIsSafeInteger };

pub fn numberCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    if (args.len == 0) return Value.fromNumber(0);
    const prim = if (args[0].isObjectLike()) try object.toPrimitive(rt, args[0], .number) else args[0];
    if (prim.isBigInt()) return Value.fromNumber(bigint.toF64(prim.asBigInt()));
    return Value.fromNumber(try ops.toNumber(rt, prim));
}

pub fn numberConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const n_val = try numberCall(rt, .undefined, args);
    const r = try builtins.realm(rt);
    return Value.fromObject(try rt.heap.newPrimitiveWrapper(r.number_prototype, n_val));
}

pub fn bigintCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const v_in = common.arg(args, 0);
    const prim = if (v_in.isObjectLike()) try object.toPrimitive(rt, v_in, .number) else v_in;
    return switch (prim.unpack()) {
        .bigint => prim,
        .number => |n| Value.fromBigInt(try bigint.fromF64Exact(rt, n)),
        .boolean => |b| Value.fromBigInt(try bigint.fromU64(rt, if (b) 1 else 0)),
        .string => |s| Value.fromBigInt((try ops.stringToBigIntOpt(rt, s.units)) orelse
            return rt.throw(.SyntaxError, &.{.{ .ascii = "Cannot convert string to a BigInt" }})),
        .undefined, .null, .symbol => rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert value to a BigInt" }}),
        .native, .closure, .object => unreachable,
    };
}

fn toBigIntWidth(rt: *Runtime, v: Value) Error!u64 {
    const n = try ops.toNumber(rt, v);
    if (std.math.isNan(n) or n == 0.0) return 0;
    const t = @trunc(n);
    if (!std.math.isFinite(t) or t < 0.0 or t > 9007199254740991.0) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Invalid BigInt bit width" }});
    }
    return @intFromFloat(t);
}

fn bigintAsIntN(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const bits = try toBigIntWidth(rt, common.arg(args, 0));
    const b = try ops.toBigInt(rt, common.arg(args, 1));
    return Value.fromBigInt(try bigint.asIntN(rt, bits, b));
}

fn bigintAsUintN(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const bits = try toBigIntWidth(rt, common.arg(args, 0));
    const b = try ops.toBigInt(rt, common.arg(args, 1));
    return Value.fromBigInt(try bigint.asUintN(rt, bits, b));
}

fn thisBigInt(rt: *Runtime, this: Value) Error!*const heap_mod.BigInt {
    if (this.isBigInt()) return this.asBigInt();
    if (this.isObject()) {
        const o = this.asObject();
        if (o.kind == .primitive_wrapper and o.kind.primitive_wrapper.isBigInt()) return o.kind.primitive_wrapper.asBigInt();
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "BigInt.prototype method called on non-BigInt" }});
}

fn bigintToString(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const b = try thisBigInt(rt, this);
    var radix: u8 = 10;
    if (args.len > 0 and !args[0].isUndefined()) {
        const r_num = try common.toIntegerOrInfinity(rt, args[0]);
        if (r_num < 2.0 or r_num > 36.0) {
            return rt.throw(.RangeError, &.{.{ .ascii = "toString() radix argument must be between 2 and 36" }});
        }
        radix = @intFromFloat(r_num);
    }
    const s = try bigint.toString(rt, b, radix);
    defer rt.gpa.free(s);
    return Value.fromString(try rt.heap.ascii(s));
}

fn bigintValueOf(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return Value.fromBigInt(try thisBigInt(rt, this));
}

const bigint_as_int_n: Native = .{ .name = "asIntN", .length = 2, .call = bigintAsIntN };

const bigint_as_uint_n: Native = .{ .name = "asUintN", .length = 2, .call = bigintAsUintN };

const bigint_to_string: Native = .{ .name = "toString", .length = 0, .call = bigintToString };

const bigint_value_of: Native = .{ .name = "valueOf", .length = 0, .call = bigintValueOf };

const number_to_string: Native = .{ .name = "toString", .length = 1, .call = numberToString };

const number_to_fixed: Native = .{ .name = "toFixed", .length = 1, .call = numberToFixed };

const number_to_exponential: Native = .{ .name = "toExponential", .length = 1, .call = numberToExponential };

const number_to_precision: Native = .{ .name = "toPrecision", .length = 1, .call = numberToPrecision };

const number_to_locale_string: Native = .{ .name = "toLocaleString", .length = 0, .call = numberToLocaleString };

const number_value_of: Native = .{ .name = "valueOf", .length = 0, .call = numberValueOf };

fn thisNumber(rt: *Runtime, this: Value) Error!f64 {
    if (this.isNumber()) return this.asNumber();
    if (this.isObject()) {
        const o = this.asObject();
        if (o.kind == .primitive_wrapper and o.kind.primitive_wrapper.isNumber()) return o.kind.primitive_wrapper.asNumber();
        if (o.builtin == .number_prototype) return 0.0;
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "Number.prototype method requires a Number receiver" }});
}

fn numberValueOf(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return Value.fromNumber(try thisNumber(rt, this));
}

fn numberToString(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const n = try thisNumber(rt, this);
    if (args.len > 0 and !args[0].isUndefined()) {
        const r_num = try common.toIntegerOrInfinity(rt, args[0]);
        if (r_num < 2.0 or r_num > 36.0) {
            return rt.throw(.RangeError, &.{.{ .ascii = "toString() radix argument must be between 2 and 36" }});
        }
        const radix: u8 = @intFromFloat(r_num);
        if (radix != 10) {
            if (std.math.isNan(n)) return Value.fromString(try rt.heap.ascii("NaN"));
            if (n == 0.0) return Value.fromString(try rt.heap.ascii("0"));
            if (!std.math.isFinite(n)) return Value.fromString(try rt.heap.ascii(if (n < 0) "-Infinity" else "Infinity"));
            if (@trunc(n) == n and @abs(n) <= 9007199254740991.0) {
                const neg = n < 0;
                const abs_i: u64 = @intFromFloat(@abs(n));
                var out_buf: [70]u8 = undefined;
                var idx: usize = out_buf.len;
                var v = abs_i;
                const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
                while (v > 0) {
                    idx -= 1;
                    out_buf[idx] = digits[v % radix];
                    v /= radix;
                }
                if (neg) {
                    idx -= 1;
                    out_buf[idx] = '-';
                }
                return Value.fromString(try rt.heap.ascii(out_buf[idx..]));
            }
        }
    }
    return Value.fromString(try common.toStringObj(rt, Value.fromNumber(n)));
}

fn numberToLocaleString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const n = try thisNumber(rt, this);
    return Value.fromString(try common.toStringObj(rt, Value.fromNumber(n)));
}

const ExactDecimal = struct {
    /// Exact significant decimal digits ('0'..'9'), digits[0] != '0'.
    /// Max exact decimal digits of any finite IEEE-754 f64 is 767 (< 2^53 * 5^1074).
    digits: [800]u8 = undefined,
    len: usize = 0,
    /// Decimal exponent such that value = (digits[0] . digits[1..len]) * 10^exp.
    exp: i32 = 0,

    fn fromPositiveFinite(ax: f64) ExactDecimal {
        std.debug.assert(ax > 0.0 and std.math.isFinite(ax));
        const bits: u64 = @bitCast(ax);
        const exp_bits: u11 = @truncate(bits >> 52);
        const frac_bits: u52 = @truncate(bits);

        var sig: u64 = undefined;
        var bin_exp: i32 = undefined;
        if (exp_bits == 0) {
            sig = frac_bits;
            bin_exp = -1074;
        } else {
            sig = (@as(u64, 1) << 52) | frac_bits;
            bin_exp = @as(i32, exp_bits) - 1075;
        }

        const tz: u6 = @intCast(@ctz(sig));
        sig >>= tz;
        bin_exp += @as(i32, tz);

        // Base 10^9 limbs (little-endian). Max 86 limbs for 767 digits.
        const base: u64 = 1_000_000_000;
        var limbs: [90]u32 = undefined;
        var nlimbs: usize = 0;
        var tmp = sig;
        while (tmp > 0) {
            limbs[nlimbs] = @intCast(tmp % base);
            nlimbs += 1;
            tmp /= base;
        }

        if (bin_exp > 0) {
            var rem: u32 = @intCast(bin_exp);
            while (rem > 0) {
                const shift: u5 = @intCast(@min(rem, 29));
                const mul: u64 = @as(u64, 1) << shift;
                var carry: u64 = 0;
                for (0..nlimbs) |i| {
                    const prod = @as(u64, limbs[i]) * mul + carry;
                    limbs[i] = @intCast(prod % base);
                    carry = prod / base;
                }
                while (carry > 0) {
                    limbs[nlimbs] = @intCast(carry % base);
                    nlimbs += 1;
                    carry /= base;
                }
                rem -= shift;
            }
        } else if (bin_exp < 0) {
            const pow5_table = [_]u32{
                1,
                5,
                25,
                125,
                625,
                3125,
                15625,
                78125,
                390625,
                1953125,
                9765625,
                48828125,
                244140625,
                1220703125,
            };
            var rem: u32 = @intCast(-bin_exp);
            while (rem > 0) {
                const step: u32 = @min(rem, 13);
                const mul: u64 = pow5_table[step];
                var carry: u64 = 0;
                for (0..nlimbs) |i| {
                    const prod = @as(u64, limbs[i]) * mul + carry;
                    limbs[i] = @intCast(prod % base);
                    carry = prod / base;
                }
                while (carry > 0) {
                    limbs[nlimbs] = @intCast(carry % base);
                    nlimbs += 1;
                    carry /= base;
                }
                rem -= step;
            }
        }

        var res: ExactDecimal = .{};
        const top = limbs[nlimbs - 1];
        var top_buf: [10]u8 = undefined;
        const top_str = std.fmt.bufPrint(&top_buf, "{d}", .{top}) catch unreachable;
        @memcpy(res.digits[0..top_str.len], top_str);
        var pos: usize = top_str.len;

        var idx = nlimbs - 1;
        while (idx > 0) {
            idx -= 1;
            var v = limbs[idx];
            var j: usize = 9;
            while (j > 0) {
                j -= 1;
                res.digits[pos + j] = @intCast('0' + (v % 10));
                v /= 10;
            }
            pos += 9;
        }

        res.exp = @as(i32, @intCast(pos - 1)) + @min(bin_exp, 0);
        res.len = pos;
        return res;
    }

    /// Rounds the exact positive decimal to `keep` (>= 1) significant digits,
    /// breaking exact half-way ties upward (ECMAScript's "pick the larger n").
    fn roundSignificant(self: *ExactDecimal, keep: usize) void {
        std.debug.assert(keep >= 1 and keep <= self.digits.len);
        if (keep >= self.len) {
            @memset(self.digits[self.len..keep], '0');
            self.len = keep;
            return;
        }
        const round_up = self.digits[keep] >= '5';
        self.len = keep;
        if (!round_up) return;
        var i: usize = keep;
        while (i > 0) {
            i -= 1;
            if (self.digits[i] < '9') {
                self.digits[i] += 1;
                return;
            }
            self.digits[i] = '0';
        }
        self.digits[0] = '1';
        self.exp += 1;
    }
};

fn formatExpSuffix(out: []u8, exp: i32) usize {
    out[0] = 'e';
    if (exp >= 0) {
        out[1] = '+';
        const es = std.fmt.bufPrint(out[2..], "{d}", .{exp}) catch unreachable;
        return 2 + es.len;
    }
    const es = std.fmt.bufPrint(out[1..], "{d}", .{exp}) catch unreachable;
    return 1 + es.len;
}

fn formatJsExp(out: []u8, raw: []const u8) []const u8 {
    // Normalize Zig scientific output `...eN` -> `...e+N` (JS always emits an explicit sign).
    const e_pos = std.mem.indexOfScalar(u8, raw, 'e') orelse {
        @memcpy(out[0..raw.len], raw);
        return out[0..raw.len];
    };
    @memcpy(out[0 .. e_pos + 1], raw[0 .. e_pos + 1]);
    const pos: usize = e_pos + 1;
    if (pos < raw.len and raw[pos] != '+' and raw[pos] != '-') {
        out[pos] = '+';
        @memcpy(out[pos + 1 .. pos + 1 + (raw.len - pos)], raw[pos..]);
        return out[0 .. raw.len + 1];
    }
    @memcpy(out[pos..raw.len], raw[pos..]);
    return out[0..raw.len];
}

fn numberToFixed(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const x_raw = try thisNumber(rt, this);
    const f_f = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
    if (!std.math.isFinite(f_f) or f_f < 0.0 or f_f > 100.0) {
        return rt.throw(.RangeError, &.{.{ .ascii = "toFixed() digits argument must be between 0 and 100" }});
    }
    if (!std.math.isFinite(x_raw) or @abs(x_raw) >= 1e21) {
        return Value.fromString(try common.toStringObj(rt, Value.fromNumber(x_raw)));
    }
    const f: usize = @intFromFloat(f_f);
    var out: [256]u8 = undefined;
    var oi: usize = 0;

    if (x_raw == 0.0) {
        out[oi] = '0';
        oi += 1;
        if (f > 0) {
            out[oi] = '.';
            oi += 1;
            @memset(out[oi..][0..f], '0');
            oi += f;
        }
        return Value.fromString(try rt.heap.ascii(out[0..oi]));
    }

    if (x_raw < 0.0) {
        out[oi] = '-';
        oi += 1;
    }
    var dec = ExactDecimal.fromPositiveFinite(@abs(x_raw));
    const keep_i32: i32 = dec.exp + 1 + @as(i32, @intCast(f));
    if (keep_i32 <= 0) {
        const round_up = (keep_i32 == 0 and dec.digits[0] >= '5');
        if (f == 0) {
            out[oi] = if (round_up) '1' else '0';
            oi += 1;
        } else {
            out[oi] = '0';
            out[oi + 1] = '.';
            oi += 2;
            @memset(out[oi..][0..f], '0');
            if (round_up) out[oi + f - 1] = '1';
            oi += f;
        }
        return Value.fromString(try rt.heap.ascii(out[0..oi]));
    }

    dec.roundSignificant(@intCast(keep_i32));
    if (dec.exp >= 0) {
        const int_digits: usize = @intCast(dec.exp + 1);
        const total_digits = int_digits + f;
        if (dec.len < total_digits) {
            @memset(dec.digits[dec.len..total_digits], '0');
            dec.len = total_digits;
        }
        @memcpy(out[oi..][0..int_digits], dec.digits[0..int_digits]);
        oi += int_digits;
        if (f > 0) {
            out[oi] = '.';
            oi += 1;
            @memcpy(out[oi..][0..f], dec.digits[int_digits..][0..f]);
            oi += f;
        }
    } else {
        // 0 < value < 1 after rounding, so f > 0.
        out[oi] = '0';
        out[oi + 1] = '.';
        oi += 2;
        const zeros: usize = @intCast(-dec.exp - 1);
        @memset(out[oi..][0..zeros], '0');
        oi += zeros;
        const sig_frac = f - zeros;
        @memcpy(out[oi..][0..sig_frac], dec.digits[0..sig_frac]);
        oi += sig_frac;
    }
    return Value.fromString(try rt.heap.ascii(out[0..oi]));
}

fn numberToExponential(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const x_raw = try thisNumber(rt, this);
    const f_arg = common.arg(args, 0);
    const f_f = try common.toIntegerOrInfinity(rt, f_arg);
    if (!std.math.isFinite(x_raw)) {
        return Value.fromString(try common.toStringObj(rt, Value.fromNumber(x_raw)));
    }
    if (!f_arg.isUndefined() and (f_f < 0.0 or f_f > 100.0)) {
        return rt.throw(.RangeError, &.{.{ .ascii = "toExponential() argument must be between 0 and 100" }});
    }
    if (f_arg.isUndefined()) {
        const x = if (x_raw == 0.0) 0.0 else x_raw;
        var raw_buf: [256]u8 = undefined;
        const raw = std.fmt.float.render(&raw_buf, x, .{ .mode = .scientific, .precision = null }) catch unreachable;
        var out_buf: [256]u8 = undefined;
        return Value.fromString(try rt.heap.ascii(formatJsExp(&out_buf, raw)));
    }

    const f: usize = @intFromFloat(f_f);
    var out: [256]u8 = undefined;
    var oi: usize = 0;

    if (x_raw == 0.0) {
        out[oi] = '0';
        oi += 1;
        if (f > 0) {
            out[oi] = '.';
            oi += 1;
            @memset(out[oi..][0..f], '0');
            oi += f;
        }
        @memcpy(out[oi..][0..3], "e+0");
        oi += 3;
        return Value.fromString(try rt.heap.ascii(out[0..oi]));
    }

    if (x_raw < 0.0) {
        out[oi] = '-';
        oi += 1;
    }
    var dec = ExactDecimal.fromPositiveFinite(@abs(x_raw));
    dec.roundSignificant(f + 1);
    out[oi] = dec.digits[0];
    oi += 1;
    if (f > 0) {
        out[oi] = '.';
        oi += 1;
        @memcpy(out[oi..][0..f], dec.digits[1..][0..f]);
        oi += f;
    }
    oi += formatExpSuffix(out[oi..], dec.exp);
    return Value.fromString(try rt.heap.ascii(out[0..oi]));
}

fn numberToPrecision(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const x_raw = try thisNumber(rt, this);
    const p_arg = common.arg(args, 0);
    if (p_arg.isUndefined()) {
        return Value.fromString(try common.toStringObj(rt, Value.fromNumber(x_raw)));
    }
    const p_f = try common.toIntegerOrInfinity(rt, p_arg);
    if (!std.math.isFinite(x_raw)) {
        return Value.fromString(try common.toStringObj(rt, Value.fromNumber(x_raw)));
    }
    if (p_f < 1.0 or p_f > 100.0) {
        return rt.throw(.RangeError, &.{.{ .ascii = "toPrecision() argument must be between 1 and 100" }});
    }
    const p: usize = @intFromFloat(p_f);
    var out: [256]u8 = undefined;
    var oi: usize = 0;

    if (x_raw == 0.0) {
        out[oi] = '0';
        oi += 1;
        if (p > 1) {
            out[oi] = '.';
            oi += 1;
            @memset(out[oi..][0 .. p - 1], '0');
            oi += p - 1;
        }
        return Value.fromString(try rt.heap.ascii(out[0..oi]));
    }

    if (x_raw < 0.0) {
        out[oi] = '-';
        oi += 1;
    }
    var dec = ExactDecimal.fromPositiveFinite(@abs(x_raw));
    dec.roundSignificant(p);
    const exp = dec.exp;

    if (exp < -6 or exp >= @as(i32, @intCast(p))) {
        out[oi] = dec.digits[0];
        oi += 1;
        if (p > 1) {
            out[oi] = '.';
            oi += 1;
            @memcpy(out[oi..][0 .. p - 1], dec.digits[1..p]);
            oi += p - 1;
        }
        oi += formatExpSuffix(out[oi..], exp);
    } else if (exp == @as(i32, @intCast(p)) - 1) {
        @memcpy(out[oi..][0..p], dec.digits[0..p]);
        oi += p;
    } else if (exp >= 0) {
        const int_digits: usize = @intCast(exp + 1);
        @memcpy(out[oi..][0..int_digits], dec.digits[0..int_digits]);
        oi += int_digits;
        out[oi] = '.';
        oi += 1;
        @memcpy(out[oi..][0 .. p - int_digits], dec.digits[int_digits..p]);
        oi += p - int_digits;
    } else {
        out[oi] = '0';
        out[oi + 1] = '.';
        oi += 2;
        const zeros: usize = @intCast(-exp - 1);
        @memset(out[oi..][0..zeros], '0');
        oi += zeros;
        @memcpy(out[oi..][0..p], dec.digits[0..p]);
        oi += p;
    }
    return Value.fromString(try rt.heap.ascii(out[0..oi]));
}

fn numberIsNaN(_: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = common.arg(args, 0);
    return Value.fromBool(v.isNumber() and std.math.isNan(v.asNumber()));
}

fn numberIsFinite(_: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = common.arg(args, 0);
    return Value.fromBool(v.isNumber() and std.math.isFinite(v.asNumber()));
}

fn numberIsInteger(_: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = common.arg(args, 0);
    if (!v.isNumber()) return Value.fromBool(false);
    const n = v.asNumber();
    return Value.fromBool(std.math.isFinite(n) and @trunc(n) == n);
}

fn numberIsSafeInteger(_: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = common.arg(args, 0);
    if (!v.isNumber()) return Value.fromBool(false);
    const n = v.asNumber();
    return Value.fromBool(std.math.isFinite(n) and @trunc(n) == n and @abs(n) <= 9007199254740991.0);
}

pub fn globalIsNaN(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(std.math.isNan(try ops.toNumber(rt, common.arg(args, 0))));
}

pub fn globalIsFinite(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(std.math.isFinite(try ops.toNumber(rt, common.arg(args, 0))));
}

fn isUriUnescaped(u: u16, keep_reserved: bool) bool {
    if (u >= 128) return false;
    const c: u8 = @intCast(u);
    switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '!', '~', '*', '\'', '(', ')' => return true,
        ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '#' => return keep_reserved,
        else => return false,
    }
}

fn isUriReserved(b: u8) bool {
    return switch (b) {
        ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '#' => true,
        else => false,
    };
}

fn uriHexVal(u: u16) ?u8 {
    return switch (u) {
        '0'...'9' => @intCast(u - '0'),
        'a'...'f' => @intCast(u - 'a' + 10),
        'A'...'F' => @intCast(u - 'A' + 10),
        else => null,
    };
}

fn encodeUriImpl(rt: *Runtime, args: []const Value, keep_reserved: bool) Error!Value {
    const s = try common.toStringObj(rt, common.arg(args, 0));
    const units = s.units;
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);

    const hex = "0123456789ABCDEF";
    var k: usize = 0;
    while (k < units.len) {
        const c = units[k];
        if (isUriUnescaped(c, keep_reserved)) {
            if (out.items.len >= rt.limits.max_string_length) return rt.limit(.string_length);
            try out.append(rt.gpa, c);
            k += 1;
            continue;
        }
        if (c >= 0xDC00 and c <= 0xDFFF) {
            return function_error.throwURIError(rt);
        }
        var cp: u21 = c;
        if (c >= 0xD800 and c <= 0xDBFF) {
            if (k + 1 >= units.len) return function_error.throwURIError(rt);
            const c2 = units[k + 1];
            if (c2 < 0xDC00 or c2 > 0xDFFF) return function_error.throwURIError(rt);
            cp = 0x10000 + ((@as(u21, c - 0xD800) << 10) | @as(u21, c2 - 0xDC00));
            k += 2;
        } else {
            k += 1;
        }
        var utf8_buf: [4]u8 = undefined;
        const n: usize = std.unicode.utf8Encode(cp, &utf8_buf) catch unreachable;
        if (out.items.len + n * 3 > rt.limits.max_string_length) return rt.limit(.string_length);
        try out.ensureUnusedCapacity(rt.gpa, n * 3);
        for (utf8_buf[0..n]) |b| {
            out.appendAssumeCapacity('%');
            out.appendAssumeCapacity(hex[b >> 4]);
            out.appendAssumeCapacity(hex[b & 0xF]);
        }
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn decodeUriImpl(rt: *Runtime, args: []const Value, keep_reserved: bool) Error!Value {
    const s = try common.toStringObj(rt, common.arg(args, 0));
    const units = s.units;
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);

    var k: usize = 0;
    while (k < units.len) {
        const c = units[k];
        if (c != '%') {
            if (out.items.len >= rt.limits.max_string_length) return rt.limit(.string_length);
            try out.append(rt.gpa, c);
            k += 1;
            continue;
        }
        const start = k;
        if (k + 2 >= units.len) return function_error.throwURIError(rt);
        const h1 = uriHexVal(units[k + 1]) orelse return function_error.throwURIError(rt);
        const h2 = uriHexVal(units[k + 2]) orelse return function_error.throwURIError(rt);
        const b0 = (h1 << 4) | h2;
        k += 3;
        if (b0 < 0x80) {
            if (keep_reserved and isUriReserved(b0)) {
                if (out.items.len + 3 > rt.limits.max_string_length) return rt.limit(.string_length);
                try out.appendSlice(rt.gpa, units[start .. start + 3]);
            } else {
                if (out.items.len >= rt.limits.max_string_length) return rt.limit(.string_length);
                try out.append(rt.gpa, b0);
            }
            continue;
        }
        const n: usize = switch (b0) {
            0xC2...0xDF => 2,
            0xE0...0xEF => 3,
            0xF0...0xF4 => 4,
            else => return function_error.throwURIError(rt),
        };
        var octets: [4]u8 = undefined;
        octets[0] = b0;
        for (1..n) |j| {
            if (k + 2 >= units.len or units[k] != '%') {
                return function_error.throwURIError(rt);
            }
            const ch1 = uriHexVal(units[k + 1]) orelse return function_error.throwURIError(rt);
            const ch2 = uriHexVal(units[k + 2]) orelse return function_error.throwURIError(rt);
            const bj = (ch1 << 4) | ch2;
            if (bj < 0x80 or bj > 0xBF) return function_error.throwURIError(rt);
            octets[j] = bj;
            k += 3;
        }
        const cp = std.unicode.utf8Decode(octets[0..n]) catch return function_error.throwURIError(rt);
        if (cp < 0x10000) {
            if (out.items.len >= rt.limits.max_string_length) return rt.limit(.string_length);
            try out.append(rt.gpa, @intCast(cp));
        } else {
            if (out.items.len + 2 > rt.limits.max_string_length) return rt.limit(.string_length);
            const v = cp - 0x10000;
            try out.append(rt.gpa, @intCast(0xD800 + (v >> 10)));
            try out.append(rt.gpa, @intCast(0xDC00 + (v & 0x3FF)));
        }
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

pub fn globalEncodeURI(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return encodeUriImpl(rt, args, true);
}

pub fn globalDecodeURI(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return decodeUriImpl(rt, args, true);
}

pub fn globalEncodeURIComponent(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return encodeUriImpl(rt, args, false);
}

pub fn globalDecodeURIComponent(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return decodeUriImpl(rt, args, false);
}

pub fn parseFloatImpl(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const s = try common.toStringObj(rt, common.arg(args, 0));
    var units = s.units;
    var start: usize = 0;
    while (start < units.len and common.isJsWhitespace(units[start])) start += 1;
    units = units[start..];
    if (units.len == 0) return Value.fromNumber(std.math.nan(f64));

    var negative = false;
    var i: usize = 0;
    if (units[0] == '-') {
        negative = true;
        i = 1;
    } else if (units[0] == '+') {
        i = 1;
    }
    const body = units[i..];
    const inf_lit = "Infinity";
    if (body.len >= inf_lit.len) {
        var is_inf = true;
        for (inf_lit, 0..) |c, j| {
            if (body[j] != c) {
                is_inf = false;
                break;
            }
        }
        if (is_inf) return Value.fromNumber(if (negative) -std.math.inf(f64) else std.math.inf(f64));
    }

    var p: usize = 0;
    var digits: usize = 0;
    while (p < body.len and body[p] >= '0' and body[p] <= '9') : (p += 1) digits += 1;
    if (p < body.len and body[p] == '.') {
        p += 1;
        while (p < body.len and body[p] >= '0' and body[p] <= '9') : (p += 1) digits += 1;
    }
    if (digits == 0) return Value.fromNumber(std.math.nan(f64));

    if (p < body.len and (body[p] == 'e' or body[p] == 'E')) {
        var ep = p + 1;
        if (ep < body.len and (body[ep] == '+' or body[ep] == '-')) ep += 1;
        const exp_digits_start = ep;
        while (ep < body.len and body[ep] >= '0' and body[ep] <= '9') ep += 1;
        if (ep > exp_digits_start) p = ep;
    }

    var stack_buf: [128]u8 = undefined;
    const heap_buf: []u8 = if (p > stack_buf.len) try rt.gpa.alloc(u8, p) else &.{};
    defer if (heap_buf.len > 0) rt.gpa.free(heap_buf);
    const ascii_buf = if (p > stack_buf.len) heap_buf else stack_buf[0..p];
    for (body[0..p], ascii_buf) |u, *c| c.* = @intCast(u);

    const v = std.fmt.parseFloat(f64, ascii_buf) catch unreachable;
    return Value.fromNumber(if (negative) -v else v);
}

fn digitVal(c: u8, radix: u8) ?u8 {
    const v: u8 = switch (c) {
        '0'...'9' => c - '0',
        'a'...'z' => c - 'a' + 10,
        'A'...'Z' => c - 'A' + 10,
        else => return null,
    };
    return if (v < radix) v else null;
}

pub fn parseIntImpl(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const s = try common.toStringObj(rt, common.arg(args, 0));
    var root_buf = [_]Value{Value.fromString(s)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var r: i32 = @bitCast(ops.toUint32(try ops.toNumber(rt, common.arg(args, 1))));
    var units = s.units;
    var start: usize = 0;
    while (start < units.len and common.isJsWhitespace(units[start])) start += 1;
    units = units[start..];

    var negative = false;
    if (units.len > 0) {
        if (units[0] == '-') {
            negative = true;
            units = units[1..];
        } else if (units[0] == '+') {
            units = units[1..];
        }
    }

    var strip_prefix = true;
    if (r != 0) {
        if (r < 2 or r > 36) return Value.fromNumber(std.math.nan(f64));
        if (r != 16) strip_prefix = false;
    } else {
        r = 10;
    }

    if (strip_prefix and units.len >= 2 and units[0] == '0' and (units[1] == 'x' or units[1] == 'X')) {
        units = units[2..];
        r = 16;
    }

    const radix: u8 = @intCast(r);
    const radix_f: f64 = @floatFromInt(radix);
    var count: usize = 0;
    var acc: f64 = 0;
    for (units) |u| {
        if (u > 0x7F) break;
        const d = digitVal(@intCast(u), radix) orelse break;
        acc = acc * radix_f + @as(f64, @floatFromInt(d));
        count += 1;
    }
    if (count == 0) return Value.fromNumber(std.math.nan(f64));
    return Value.fromNumber(if (negative) -acc else acc);
}

// ---------------------------------------------------------------- Math (M11.3)

fn registerMath(rt: *Runtime, m: *Object) Error!void {
    try common.immutableConstant(rt, m, "E", Value.fromNumber(std.math.e));
    try common.immutableConstant(rt, m, "LN2", Value.fromNumber(std.math.ln2));
    try common.immutableConstant(rt, m, "LN10", Value.fromNumber(std.math.ln10));
    try common.immutableConstant(rt, m, "LOG2E", Value.fromNumber(std.math.log2e));
    try common.immutableConstant(rt, m, "LOG10E", Value.fromNumber(std.math.log10e));
    try common.immutableConstant(rt, m, "PI", Value.fromNumber(std.math.pi));
    try common.immutableConstant(rt, m, "SQRT1_2", Value.fromNumber(std.math.sqrt1_2));
    try common.immutableConstant(rt, m, "SQRT2", Value.fromNumber(std.math.sqrt2));

    try common.method(rt, m, "abs", &math_abs);
    try common.method(rt, m, "floor", &math_floor);
    try common.method(rt, m, "ceil", &math_ceil);
    try common.method(rt, m, "round", &math_round);
    try common.method(rt, m, "trunc", &math_trunc);
    try common.method(rt, m, "min", &math_min);
    try common.method(rt, m, "max", &math_max);
    try common.method(rt, m, "pow", &math_pow);
    try common.method(rt, m, "sqrt", &math_sqrt);
    try common.method(rt, m, "sin", &math_sin);
    try common.method(rt, m, "cos", &math_cos);
    try common.method(rt, m, "tan", &math_tan);
    try common.method(rt, m, "asin", &math_asin);
    try common.method(rt, m, "acos", &math_acos);
    try common.method(rt, m, "atan", &math_atan);
    try common.method(rt, m, "atan2", &math_atan2);
    try common.method(rt, m, "log", &math_log);
    try common.method(rt, m, "exp", &math_exp);
    try common.method(rt, m, "sign", &math_sign);
    try common.method(rt, m, "clz32", &math_clz32);
    try common.method(rt, m, "imul", &math_imul);
    try common.method(rt, m, "fround", &math_fround);
    try common.method(rt, m, "hypot", &math_hypot);
    try common.method(rt, m, "random", &math_random);
}

const math_abs: Native = .{ .name = "abs", .length = 1, .call = mathAbs };

const math_floor: Native = .{ .name = "floor", .length = 1, .call = mathFloor };

const math_ceil: Native = .{ .name = "ceil", .length = 1, .call = mathCeil };

const math_round: Native = .{ .name = "round", .length = 1, .call = mathRound };

const math_trunc: Native = .{ .name = "trunc", .length = 1, .call = mathTrunc };

const math_min: Native = .{ .name = "min", .length = 2, .call = mathMin };

const math_max: Native = .{ .name = "max", .length = 2, .call = mathMax };

const math_pow: Native = .{ .name = "pow", .length = 2, .call = mathPow };

const math_sqrt: Native = .{ .name = "sqrt", .length = 1, .call = mathSqrt };

const math_sin: Native = .{ .name = "sin", .length = 1, .call = mathSin };

const math_cos: Native = .{ .name = "cos", .length = 1, .call = mathCos };

const math_tan: Native = .{ .name = "tan", .length = 1, .call = mathTan };

const math_asin: Native = .{ .name = "asin", .length = 1, .call = mathAsin };

const math_acos: Native = .{ .name = "acos", .length = 1, .call = mathAcos };

const math_atan: Native = .{ .name = "atan", .length = 1, .call = mathAtan };

const math_atan2: Native = .{ .name = "atan2", .length = 2, .call = mathAtan2 };

const math_log: Native = .{ .name = "log", .length = 1, .call = mathLog };

const math_exp: Native = .{ .name = "exp", .length = 1, .call = mathExp };

const math_sign: Native = .{ .name = "sign", .length = 1, .call = mathSign };

const math_clz32: Native = .{ .name = "clz32", .length = 1, .call = mathClz32 };

const math_imul: Native = .{ .name = "imul", .length = 2, .call = mathImul };

const math_fround: Native = .{ .name = "fround", .length = 1, .call = mathFround };

const math_hypot: Native = .{ .name = "hypot", .length = 2, .call = mathHypot };

const math_random: Native = .{ .name = "random", .call = mathRandom };

fn mathAbs(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(@abs(try ops.toNumber(rt, common.arg(args, 0))));
}

fn mathFloor(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(@floor(try ops.toNumber(rt, common.arg(args, 0))));
}

fn mathCeil(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(@ceil(try ops.toNumber(rt, common.arg(args, 0))));
}

fn mathTrunc(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(@trunc(try ops.toNumber(rt, common.arg(args, 0))));
}

fn mathRound(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const x = try ops.toNumber(rt, common.arg(args, 0));
    if (!std.math.isFinite(x) or x == 0.0) return Value.fromNumber(x);
    if (x >= -0.5 and x < 0.0) return Value.fromNumber(-0.0);
    if (@abs(x) >= 4503599627370496.0) return Value.fromNumber(x);
    const f = @floor(x);
    return Value.fromNumber(if (x - f >= 0.5) f + 1.0 else f);
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
    return Value.fromNumber(if (saw_nan) std.math.nan(f64) else best);
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
    return Value.fromNumber(if (saw_nan) std.math.nan(f64) else best);
}

fn mathPow(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const base = try ops.toNumber(rt, common.arg(args, 0));
    const exp = try ops.toNumber(rt, common.arg(args, 1));
    return Value.fromNumber(ops.pow(base, exp));
}

fn mathSqrt(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(std.math.sqrt(try ops.toNumber(rt, common.arg(args, 0))));
}

fn mathSin(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(std.math.sin(try ops.toNumber(rt, common.arg(args, 0))));
}

fn mathCos(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(std.math.cos(try ops.toNumber(rt, common.arg(args, 0))));
}

fn mathTan(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(std.math.tan(try ops.toNumber(rt, common.arg(args, 0))));
}

fn mathAsin(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(std.math.asin(try ops.toNumber(rt, common.arg(args, 0))));
}

fn mathAcos(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(std.math.acos(try ops.toNumber(rt, common.arg(args, 0))));
}

fn mathAtan(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(std.math.atan(try ops.toNumber(rt, common.arg(args, 0))));
}

fn mathAtan2(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const y = try ops.toNumber(rt, common.arg(args, 0));
    const x = try ops.toNumber(rt, common.arg(args, 1));
    return Value.fromNumber(std.math.atan2(y, x));
}

fn mathLog(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(@log(try ops.toNumber(rt, common.arg(args, 0))));
}

fn mathExp(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(@exp(try ops.toNumber(rt, common.arg(args, 0))));
}

fn mathSign(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const x = try ops.toNumber(rt, common.arg(args, 0));
    if (std.math.isNan(x) or x == 0.0) return Value.fromNumber(x);
    return Value.fromNumber(if (x > 0.0) 1.0 else -1.0);
}

fn mathClz32(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const u = ops.toUint32(try ops.toNumber(rt, common.arg(args, 0)));
    return Value.fromNumber(@floatFromInt(@clz(u)));
}

fn mathImul(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const a: i32 = @bitCast(ops.toUint32(try ops.toNumber(rt, common.arg(args, 0))));
    const b: i32 = @bitCast(ops.toUint32(try ops.toNumber(rt, common.arg(args, 1))));
    return Value.fromNumber(@floatFromInt(a *% b));
}

fn mathFround(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const x = try ops.toNumber(rt, common.arg(args, 0));
    if (!std.math.isFinite(x) or x == 0.0) return Value.fromNumber(x);
    return Value.fromNumber(@as(f64, @floatCast(@as(f32, @floatCast(x)))));
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
    if (saw_inf) return Value.fromNumber(std.math.inf(f64));
    if (saw_nan) return Value.fromNumber(std.math.nan(f64));
    if (max_abs == 0.0) return Value.fromNumber(0.0);
    var sum: f64 = 0.0;
    for (args) |a| {
        const v = try ops.toNumber(rt, a);
        const s = v / max_abs;
        sum += s * s;
    }
    return Value.fromNumber(max_abs * std.math.sqrt(sum));
}

fn mathRandom(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return Value.fromNumber(rt.nextRandom());
}

// ---------------------------------------------------------------- Map

const date_now: Native = .{ .name = "now", .length = 0, .call = dateNow };

const date_utc: Native = .{ .name = "UTC", .length = 7, .call = dateUtc };

const date_parse: Native = .{ .name = "parse", .length = 1, .call = dateParse };

const date_get_time: Native = .{ .name = "getTime", .length = 0, .call = dateGetTime };

const date_value_of: Native = .{ .name = "valueOf", .length = 0, .call = dateGetTime };

const date_get_timezone_offset: Native = .{ .name = "getTimezoneOffset", .length = 0, .call = dateGetTimezoneOffset };

const date_set_time: Native = .{ .name = "setTime", .length = 1, .call = dateSetTime };

const date_get_utc_full_year: Native = .{ .name = "getUTCFullYear", .length = 0, .call = dateGetUtcFullYear };

const date_get_utc_month: Native = .{ .name = "getUTCMonth", .length = 0, .call = dateGetUtcMonth };

const date_get_utc_date: Native = .{ .name = "getUTCDate", .length = 0, .call = dateGetUtcDate };

const date_get_utc_day: Native = .{ .name = "getUTCDay", .length = 0, .call = dateGetUtcDay };

const date_get_utc_hours: Native = .{ .name = "getUTCHours", .length = 0, .call = dateGetUtcHours };

const date_get_utc_minutes: Native = .{ .name = "getUTCMinutes", .length = 0, .call = dateGetUtcMinutes };

const date_get_utc_seconds: Native = .{ .name = "getUTCSeconds", .length = 0, .call = dateGetUtcSeconds };

const date_get_utc_milliseconds: Native = .{ .name = "getUTCMilliseconds", .length = 0, .call = dateGetUtcMilliseconds };

const date_set_utc_full_year: Native = .{ .name = "setUTCFullYear", .length = 3, .call = dateSetUtcFullYear };

const date_set_utc_month: Native = .{ .name = "setUTCMonth", .length = 2, .call = dateSetUtcMonth };

const date_set_utc_date: Native = .{ .name = "setUTCDate", .length = 1, .call = dateSetUtcDate };

const date_set_utc_hours: Native = .{ .name = "setUTCHours", .length = 4, .call = dateSetUtcHours };

const date_set_utc_minutes: Native = .{ .name = "setUTCMinutes", .length = 3, .call = dateSetUtcMinutes };

const date_set_utc_seconds: Native = .{ .name = "setUTCSeconds", .length = 2, .call = dateSetUtcSeconds };

const date_set_utc_milliseconds: Native = .{ .name = "setUTCMilliseconds", .length = 1, .call = dateSetUtcMilliseconds };

const date_get_full_year: Native = .{ .name = "getFullYear", .length = 0, .call = dateGetFullYear };

const date_get_month: Native = .{ .name = "getMonth", .length = 0, .call = dateGetMonth };

const date_get_date: Native = .{ .name = "getDate", .length = 0, .call = dateGetDate };

const date_get_day: Native = .{ .name = "getDay", .length = 0, .call = dateGetDay };

const date_get_hours: Native = .{ .name = "getHours", .length = 0, .call = dateGetHours };

const date_get_minutes: Native = .{ .name = "getMinutes", .length = 0, .call = dateGetMinutes };

const date_get_seconds: Native = .{ .name = "getSeconds", .length = 0, .call = dateGetSeconds };

const date_get_milliseconds: Native = .{ .name = "getMilliseconds", .length = 0, .call = dateGetMilliseconds };

const date_set_full_year: Native = .{ .name = "setFullYear", .length = 3, .call = dateSetFullYear };

const date_set_month: Native = .{ .name = "setMonth", .length = 2, .call = dateSetMonth };

const date_set_date: Native = .{ .name = "setDate", .length = 1, .call = dateSetDate };

const date_set_hours: Native = .{ .name = "setHours", .length = 4, .call = dateSetHours };

const date_set_minutes: Native = .{ .name = "setMinutes", .length = 3, .call = dateSetMinutes };

const date_set_seconds: Native = .{ .name = "setSeconds", .length = 2, .call = dateSetSeconds };

const date_set_milliseconds: Native = .{ .name = "setMilliseconds", .length = 1, .call = dateSetMilliseconds };

const date_to_iso_string: Native = .{ .name = "toISOString", .length = 0, .call = dateToIsoString };

const date_to_utc_string: Native = .{ .name = "toUTCString", .length = 0, .call = dateToUtcString };

const date_to_string: Native = .{ .name = "toString", .length = 0, .call = dateToString };

const date_to_date_string: Native = .{ .name = "toDateString", .length = 0, .call = dateToDateString };

const date_to_time_string: Native = .{ .name = "toTimeString", .length = 0, .call = dateToTimeString };

const date_to_locale_string: Native = .{ .name = "toLocaleString", .length = 0, .call = dateToString };

const date_to_locale_date_string: Native = .{ .name = "toLocaleDateString", .length = 0, .call = dateToDateString };

const date_to_locale_time_string: Native = .{ .name = "toLocaleTimeString", .length = 0, .call = dateToTimeString };

const date_to_json: Native = .{ .name = "toJSON", .length = 1, .call = dateToJson };

const date_to_primitive: Native = .{ .name = "[Symbol.toPrimitive]", .length = 1, .call = dateToPrimitive };

fn adjustTwoDigitYear(y: f64) f64 {
    if (!std.math.isFinite(y)) return y;
    const yi = @trunc(y);
    if (yi >= 0.0 and yi <= 99.0) return 1900.0 + yi;
    return y;
}

fn parseDateStringValue(s: *const heap_mod.String) f64 {
    if (s.units.len > 256) return std.math.nan(f64);
    var buf: [256]u8 = undefined;
    for (s.units, 0..) |u, i| {
        if (u > 0x7f) return std.math.nan(f64);
        buf[i] = @intCast(u);
    }
    return date.parse(buf[0..s.units.len]);
}

fn evalDateArgs(rt: *Runtime, args: []const Value, is_utc: bool) Error!f64 {
    const y_raw = try ops.toNumber(rt, common.arg(args, 0));
    const m = if (args.len > 1) try ops.toNumber(rt, args[1]) else 0.0;
    const dt = if (args.len > 2) try ops.toNumber(rt, args[2]) else 1.0;
    const h = if (args.len > 3) try ops.toNumber(rt, args[3]) else 0.0;
    const min = if (args.len > 4) try ops.toNumber(rt, args[4]) else 0.0;
    const s = if (args.len > 5) try ops.toNumber(rt, args[5]) else 0.0;
    const ms = if (args.len > 6) try ops.toNumber(rt, args[6]) else 0.0;
    const yr = adjustTwoDigitYear(y_raw);
    const final_date = date.makeDate(date.makeDay(yr, m, dt), date.makeTime(h, min, s, ms));
    return date.timeClip(if (is_utc) final_date else date.utcFromLocal(final_date));
}

pub fn dateCall(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    var buf: [128]u8 = undefined;
    return Value.fromString(try rt.heap.ascii(date.formatToString(&buf, rt.nowMs())));
}

pub fn dateConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const tv: f64 = if (args.len == 0)
        rt.nowMs()
    else if (args.len == 1) blk: {
        const v = args[0];
        if (v.isObject() and v.asObject().kind == .date) {
            break :blk date.timeClip(v.asObject().kind.date);
        }
        const pv = try object.toPrimitive(rt, v, .default);
        if (pv.isString()) {
            break :blk parseDateStringValue(pv.asString());
        }
        break :blk date.timeClip(try ops.toNumber(rt, pv));
    } else try evalDateArgs(rt, args, false);

    const r = try builtins.realm(rt);
    return Value.fromObject(try rt.heap.newDate(r.date_prototype, tv));
}

fn dateNow(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return Value.fromNumber(rt.nowMs());
}

fn dateUtc(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(try evalDateArgs(rt, args, true));
}

fn dateParse(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const s = try ops.toStringValue(rt, common.arg(args, 0));
    return Value.fromNumber(parseDateStringValue(s.asString()));
}

fn requireDate(rt: *Runtime, this: Value) Error!*Object {
    if (!this.isObject() or this.asObject().kind != .date) {
        return rt.throw(.TypeError, &.{.{ .ascii = "this is not a Date object" }});
    }
    return this.asObject();
}

fn dateGetTime(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    return Value.fromNumber(o.kind.date);
}

fn dateGetTimezoneOffset(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    return Value.fromNumber(date.timezoneOffsetMinutes(o.kind.date));
}

fn dateSetTime(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    const v = date.timeClip(try ops.toNumber(rt, common.arg(args, 0)));
    o.kind.date = v;
    return Value.fromNumber(v);
}

const DateField = enum { year, month, day, weekday, hour, minute, second, ms };

fn dateGetField(rt: *Runtime, this: Value, is_utc: bool, field: DateField) Error!Value {
    const o = try requireDate(rt, this);
    const t = o.kind.date;
    if (!std.math.isFinite(t)) return Value.fromNumber(std.math.nan(f64));
    const t_eff = if (is_utc) t else date.localTime(t);
    const d = date.decompose(t_eff) orelse return Value.fromNumber(std.math.nan(f64));
    return Value.fromNumber(switch (field) {
        .year => @floatFromInt(d.year),
        .month => @floatFromInt(d.month),
        .day => @floatFromInt(d.day),
        .weekday => @floatFromInt(d.weekday),
        .hour => @floatFromInt(d.hour),
        .minute => @floatFromInt(d.minute),
        .second => @floatFromInt(d.second),
        .ms => @floatFromInt(d.ms),
    });
}

fn dateGetUtcFullYear(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .year);
}

fn dateGetUtcMonth(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .month);
}

fn dateGetUtcDate(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .day);
}

fn dateGetUtcDay(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .weekday);
}

fn dateGetUtcHours(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .hour);
}

fn dateGetUtcMinutes(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .minute);
}

fn dateGetUtcSeconds(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .second);
}

fn dateGetUtcMilliseconds(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .ms);
}

fn dateGetFullYear(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .year);
}

fn dateGetMonth(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .month);
}

fn dateGetDate(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .day);
}

fn dateGetDay(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .weekday);
}

fn dateGetHours(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .hour);
}

fn dateGetMinutes(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .minute);
}

fn dateGetSeconds(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .second);
}

fn dateGetMilliseconds(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .ms);
}

fn dateSetTimeFields(rt: *Runtime, this: Value, args: []const Value, is_utc: bool, start_idx: usize) Error!Value {
    const o = try requireDate(rt, this);
    const t_raw = o.kind.date;
    const max_count = 4 - start_idx;
    var vals: [4]f64 = .{ 0, 0, 0, 0 };
    const n_args = @min(args.len, max_count);
    for (0..@max(n_args, 1)) |i| {
        vals[start_idx + i] = try ops.toNumber(rt, common.arg(args, i));
    }
    if (!std.math.isFinite(t_raw)) return Value.fromNumber(std.math.nan(f64));
    const t = if (is_utc) t_raw else date.localTime(t_raw);
    const d = date.decompose(t) orelse return Value.fromNumber(std.math.nan(f64));
    const cur: [4]f64 = .{
        @floatFromInt(d.hour),
        @floatFromInt(d.minute),
        @floatFromInt(d.second),
        @floatFromInt(d.ms),
    };
    const h = if (start_idx <= 0 and 0 - start_idx < @max(n_args, 1)) vals[0] else cur[0];
    const m = if (start_idx <= 1 and 1 - start_idx < @max(n_args, 1)) vals[1] else cur[1];
    const s = if (start_idx <= 2 and 2 - start_idx < @max(n_args, 1)) vals[2] else cur[2];
    const ms = if (start_idx <= 3 and 3 - start_idx < @max(n_args, 1)) vals[3] else cur[3];
    const day_f = @floor(t / date.ms_per_day);
    const new_local = date.makeDate(day_f, date.makeTime(h, m, s, ms));
    const u = date.timeClip(if (is_utc) new_local else date.utcFromLocal(new_local));
    o.kind.date = u;
    return Value.fromNumber(u);
}

fn dateSetDateFields(rt: *Runtime, this: Value, args: []const Value, is_utc: bool, start_idx: usize) Error!Value {
    const o = try requireDate(rt, this);
    const t_raw = o.kind.date;
    const max_count = 3 - start_idx;
    var vals: [3]f64 = .{ 0, 0, 0 };
    const n_args = @min(args.len, max_count);
    for (0..@max(n_args, 1)) |i| {
        vals[start_idx + i] = try ops.toNumber(rt, common.arg(args, i));
    }
    const t = if (!std.math.isFinite(t_raw)) blk: {
        // Only setFullYear / setUTCFullYear (start_idx == 0) treats NaN as +0.0 per ES spec.
        if (start_idx != 0) return Value.fromNumber(std.math.nan(f64));
        break :blk 0.0;
    } else if (is_utc) t_raw else date.localTime(t_raw);
    const d = date.decompose(t) orelse return Value.fromNumber(std.math.nan(f64));
    const cur: [3]f64 = .{
        @floatFromInt(d.year),
        @floatFromInt(d.month),
        @floatFromInt(d.day),
    };
    const yr = if (start_idx <= 0 and 0 - start_idx < @max(n_args, 1)) vals[0] else cur[0];
    const mo = if (start_idx <= 1 and 1 - start_idx < @max(n_args, 1)) vals[1] else cur[1];
    const dt = if (start_idx <= 2 and 2 - start_idx < @max(n_args, 1)) vals[2] else cur[2];
    const tod = @as(f64, @floatFromInt(d.hour)) * date.ms_per_hour +
        @as(f64, @floatFromInt(d.minute)) * date.ms_per_minute +
        @as(f64, @floatFromInt(d.second)) * date.ms_per_second +
        @as(f64, @floatFromInt(d.ms));
    const new_local = date.makeDate(date.makeDay(yr, mo, dt), tod);
    const u = date.timeClip(if (is_utc) new_local else date.utcFromLocal(new_local));
    o.kind.date = u;
    return Value.fromNumber(u);
}

fn dateSetUtcFullYear(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetDateFields(rt, this, args, true, 0);
}

fn dateSetUtcMonth(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetDateFields(rt, this, args, true, 1);
}

fn dateSetUtcDate(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetDateFields(rt, this, args, true, 2);
}

fn dateSetUtcHours(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, true, 0);
}

fn dateSetUtcMinutes(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, true, 1);
}

fn dateSetUtcSeconds(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, true, 2);
}

fn dateSetUtcMilliseconds(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, true, 3);
}

fn dateSetFullYear(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetDateFields(rt, this, args, false, 0);
}

fn dateSetMonth(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetDateFields(rt, this, args, false, 1);
}

fn dateSetDate(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetDateFields(rt, this, args, false, 2);
}

fn dateSetHours(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, false, 0);
}

fn dateSetMinutes(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, false, 1);
}

fn dateSetSeconds(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, false, 2);
}

fn dateSetMilliseconds(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, false, 3);
}

fn dateToIsoString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    if (!std.math.isFinite(o.kind.date)) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Invalid time value" }});
    }
    var buf: [64]u8 = undefined;
    return Value.fromString(try rt.heap.ascii(date.formatISO(&buf, o.kind.date)));
}

fn dateToUtcString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    var buf: [64]u8 = undefined;
    return Value.fromString(try rt.heap.ascii(date.formatUTC(&buf, o.kind.date)));
}

fn dateToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    var buf: [128]u8 = undefined;
    return Value.fromString(try rt.heap.ascii(date.formatToString(&buf, o.kind.date)));
}

fn dateToDateString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    var buf: [64]u8 = undefined;
    return Value.fromString(try rt.heap.ascii(date.formatDateString(&buf, o.kind.date)));
}

fn dateToTimeString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    var buf: [96]u8 = undefined;
    return Value.fromString(try rt.heap.ascii(date.formatTimeString(&buf, o.kind.date)));
}

fn dateToJson(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const tv = try object.toPrimitive(rt, this, .number);
    if (tv.isNumber() and !std.math.isFinite(tv.asNumber())) return .null;
    const iso = try object.get(rt, this, try object.named(rt, "toISOString"));
    if (!iso.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "toISOString is not a function" }});
    }
    return rt.callCallable(iso, this, &.{});
}

fn dateToPrimitive(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Date.prototype[Symbol.toPrimitive] called on non-object" }});
    }
    const hint_val = common.arg(args, 0);
    if (!hint_val.isString()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Invalid hint" }});
    }
    const hint_units = hint_val.asString().units;
    if (common.eqlAscii(hint_units, "string") or common.eqlAscii(hint_units, "default")) {
        return object.ordinaryToPrimitive(rt, this, .string);
    }
    if (common.eqlAscii(hint_units, "number")) {
        return object.ordinaryToPrimitive(rt, this, .number);
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "Invalid hint" }});
}
