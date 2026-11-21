//! JavaScript semantics of values: conversions and operators (DESIGN_DECISIONS D16).
//! The tree-walker uses these now and the VM will use them unchanged. This is the
//! ONLY place that converts between numbers and strings; the CLI, the heap and
//! `print` all go through `formatNumber` / `toPiece`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../frontend/ast.zig");
const number = @import("../frontend/number.zig");
const heap = @import("heap.zig");
const Piece = heap.Piece;
const Value = @import("value.zig").Value;
const rt_mod = @import("runtime.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const object = @import("object.zig");
const bigint = @import("bigint.zig");

// ------------------------------------------------------------ ToBoolean

pub inline fn toBoolean(v: Value) bool {
    if (v.isNumber()) {
        const n = v.asNumber();
        return !(n == 0 or std.math.isNan(n));
    }
    return switch (v.unpack()) {
        .undefined, .null => false,
        .boolean => |b| b,
        .number => unreachable,
        .bigint => |b| b.limbs.len != 0,
        .string => |s| s.units.len != 0,
        .symbol, .native, .closure, .object => true,
    };
}

// ------------------------------------------------------------ ToNumber

pub fn toNumber(rt: *Runtime, v: Value) Error!f64 {
    if (v.isNumber()) return v.asNumber();
    const gpa = rt.gpa;
    return switch (v.unpack()) {
        .undefined => std.math.nan(f64),
        .null => 0,
        .boolean => |b| if (b) 1 else 0,
        .number => |n| n,
        .bigint => rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert a BigInt value to a number" }}),
        .string => |s| stringToNumber(gpa, s.units),
        .symbol => rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert a Symbol value to a number" }}),
        .native, .closure, .object => {
            const prim = try object.toPrimitive(rt, v, .number);
            if (prim.isFunction()) return std.math.nan(f64);
            return toNumber(rt, prim);
        },
    };
}

/// JS StringToNumber: trims JS whitespace; "" → 0; decimal literals with an optional
/// sign, `Infinity`, and unsigned 0x/0o/0b integers; anything else → NaN.
/// Numeric separators are *not* allowed here (`+"1_000"` is NaN).
pub fn stringToNumber(gpa: Allocator, units_in: []const u16) Allocator.Error!f64 {
    var units = units_in;
    while (units.len > 0 and isJsWhitespace(units[0])) units = units[1..];
    while (units.len > 0 and isJsWhitespace(units[units.len - 1])) units = units[0 .. units.len - 1];
    if (units.len == 0) return 0;
    for (units) |u| if (u > 0x7F) return std.math.nan(f64);

    // A temporary ASCII copy for parseFloat; freed before returning.
    const s = try gpa.alloc(u8, units.len);
    defer gpa.free(s);
    for (units, s) |u, *c| c.* = @intCast(u);

    const nan = std.math.nan(f64);
    if (std.mem.eql(u8, s, "Infinity") or std.mem.eql(u8, s, "+Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, s, "-Infinity")) return -std.math.inf(f64);
    if (s.len >= 2 and s[0] == '0') {
        const radix: u8 = switch (s[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => 0,
        };
        if (radix != 0) return number.radixToNumber(s[2..], radix, false);
    }
    const negative = s[0] == '-';
    const body = if (s[0] == '-' or s[0] == '+') s[1..] else s;
    if (!isDecimalLiteral(body)) return nan;
    // Validated above, so parseFloat sees only JS decimal syntax (it would also accept
    // `inf`, `1_0` or `0x10`, see DESIGN_DECISIONS D18).
    const v = std.fmt.parseFloat(f64, body) catch unreachable;
    return if (negative) -v else v;
}

/// `digits [. digits] [e [+-] digits]` or `. digits [exponent]`, at least one digit.
fn isDecimalLiteral(s: []const u8) bool {
    var i: usize = 0;
    var mantissa_digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) mantissa_digits += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) mantissa_digits += 1;
    }
    if (mantissa_digits == 0) return false;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        const exp_start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == exp_start) return false;
    }
    return i == s.len;
}

fn isJsWhitespace(u: u16) bool {
    return switch (u) {
        0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

// ------------------------------------------------------------ Number → String

pub const NumberBuf = [32]u8;

/// JS Number::toString(10). Zig's `{e}` gives the shortest round-trip digits; JS then
/// chooses the layout from the decimal exponent n (value = 0.d1d2…dk × 10^n):
///   k ≤ n ≤ 21    digits followed by n−k zeros           123, 1e+21 is the first exception
///   0 < n ≤ 21    digits with a point after n of them     1.5
///   −6 < n ≤ 0    "0." then −n zeros then digits          0.000001
///   otherwise     d.ddd e±(n−1)                           1e-7, 1.5e+300
pub fn formatNumber(buf: *NumberBuf, x: f64) []const u8 {
    if (std.math.isNan(x)) return "NaN";
    if (x == 0) return "0"; // both +0 and -0
    if (std.math.isInf(x)) return if (x > 0) "Infinity" else "-Infinity";

    var sci_buf: [32]u8 = undefined;
    const sci = std.fmt.bufPrint(&sci_buf, "{e}", .{@abs(x)}) catch unreachable;
    const e_at = std.mem.indexOfScalar(u8, sci, 'e').?;
    var digits_buf: [20]u8 = undefined;
    var k: usize = 0;
    for (sci[0..e_at]) |c| if (c != '.') {
        digits_buf[k] = c;
        k += 1;
    };
    const digits = digits_buf[0..k];
    const n: i32 = (std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch unreachable) + 1;
    const ki: i32 = @intCast(k);

    var w: std.Io.Writer = .fixed(buf);
    if (x < 0) w.writeByte('-') catch unreachable;
    if (ki <= n and n <= 21) {
        w.writeAll(digits) catch unreachable;
        w.splatByteAll('0', @intCast(n - ki)) catch unreachable;
    } else if (0 < n and n <= 21) {
        const p: usize = @intCast(n);
        w.print("{s}.{s}", .{ digits[0..p], digits[p..] }) catch unreachable;
    } else if (-6 < n and n <= 0) {
        w.writeAll("0.") catch unreachable;
        w.splatByteAll('0', @intCast(-n)) catch unreachable;
        w.writeAll(digits) catch unreachable;
    } else {
        w.writeByte(digits[0]) catch unreachable;
        if (k > 1) w.print(".{s}", .{digits[1..]}) catch unreachable;
        const e = n - 1;
        w.print("e{c}{d}", .{ @as(u8, if (e >= 0) '+' else '-'), @abs(e) }) catch unreachable;
    }
    return w.buffered();
}

/// ToString for building strings: the value as a piece of text. `buf` backs number
/// text and must outlive the returned piece.
pub fn toPiece(rt: *Runtime, v: Value, buf: *NumberBuf) Error!Piece {
    heap.checkValue(v); // stress builds: printing or converting a collected value
    return switch (v.unpack()) {
        .undefined => .{ .ascii = "undefined" },
        .null => .{ .ascii = "null" },
        .boolean => |b| .{ .ascii = if (b) "true" else "false" },
        .number => |n| .{ .ascii = formatNumber(buf, n) },
        .bigint => |b| blk: {
            const s = try bigint.toString(rt, b, 10);
            defer rt.gpa.free(s);
            const hstr = try rt.heap.ascii(s);
            break :blk .{ .utf16 = hstr.units };
        },
        .string => |s| .{ .utf16 = s.units },
        .symbol => rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert a Symbol value to a string" }}),
        .native, .closure, .object => {
            const prim = try object.toPrimitive(rt, v, .string);
            if (prim.isFunction()) return rt.fail(.function_to_string);
            return toPiece(rt, prim, buf);
        },
    };
}

pub fn toStringValue(rt: *Runtime, v: Value) Error!Value {
    if (v.isString()) return v;
    var buf: NumberBuf = undefined;
    const piece = try toPiece(rt, v, &buf);
    return Value.fromString(try rt.heap.newString(&.{piece}));
}

/// Writes UTF-16 as UTF-8. A lone surrogate becomes U+FFFD, as node does on output.
pub fn writeUtf16(w: *std.Io.Writer, units: []const u16) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < units.len) : (i += 1) {
        const u = units[i];
        var cp: u21 = u;
        if (u >= 0xD800 and u <= 0xDBFF and i + 1 < units.len and units[i + 1] >= 0xDC00 and units[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((@as(u21, u) - 0xD800) << 10) + (units[i + 1] - 0xDC00);
            i += 1;
        } else if (u >= 0xD800 and u <= 0xDFFF) {
            cp = 0xFFFD;
        }
        var enc: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &enc) catch unreachable;
        try w.writeAll(enc[0..len]);
    }
}

// ------------------------------------------------------------ operators

/// Number::exponentiate. Differs from C `pow` in two places: `1 ** NaN` and
/// `(±1) ** ±Infinity` are NaN in JS (C gives 1).
pub fn pow(base: f64, exponent: f64) f64 {
    if (std.math.isNan(exponent)) return std.math.nan(f64);
    if (exponent == 0) return 1;
    if (std.math.isNan(base)) return std.math.nan(f64);
    if (@abs(base) == 1 and std.math.isInf(exponent)) return std.math.nan(f64);
    return @import("pow.zig").pow(base, exponent);
}

/// JS `%`: the result has the sign of the dividend; same as C fmod / Zig @rem.
pub fn remainder(a: f64, b: f64) f64 {
    if (b == 0 or std.math.isNan(a) or std.math.isNan(b) or std.math.isInf(a)) return std.math.nan(f64);
    if (std.math.isInf(b)) return a;
    return @rem(a, b);
}

/// IsLessThan for primitives (`binary` converts objects first, in source order): two
/// strings compare by UTF-16 code unit; otherwise both sides become numbers. null
/// means "undefined" in the spec (a NaN was involved).
pub fn lessThan(rt: *Runtime, a: Value, b: Value) Error!?bool {
    if (a.isString() and b.isString()) return std.mem.order(u16, a.asString().units, b.asString().units) == .lt;
    if (a.isBigInt() or b.isBigInt()) {
        if (a.isBigInt() and b.isBigInt()) {
            return bigint.cmp(a.asBigInt(), b.asBigInt()) == .lt;
        }
        if (a.isBigInt() and b.isString()) {
            const rhs = (try stringToBigIntOpt(rt, b.asString().units)) orelse return null;
            return bigint.cmp(a.asBigInt(), rhs) == .lt;
        }
        if (a.isString() and b.isBigInt()) {
            const lhs = (try stringToBigIntOpt(rt, a.asString().units)) orelse return null;
            return bigint.cmp(lhs, b.asBigInt()) == .lt;
        }
        if (a.isBigInt()) {
            const y = try toNumber(rt, b);
            const ord = bigint.cmpNumber(a.asBigInt(), y) orelse return null;
            return ord == .lt;
        } else {
            const x = try toNumber(rt, a);
            const ord = bigint.cmpNumber(b.asBigInt(), x) orelse return null;
            return ord == .gt;
        }
    }
    // ToPrimitive turns a function into its source text, so against a string (or another
    // function) JS compares that text as a string: `print > 'a'` is true. ZQJS has no
    // source text to compare. Against anything else the text becomes NaN, as below.
    const textual = struct {
        fn f(v: Value) bool {
            return v.isString() or v.isFunction();
        }
    }.f;
    if ((a.isFunction() and textual(b)) or (b.isFunction() and textual(a))) return rt.fail(.function_to_string);
    const x = try toNumber(rt, a);
    const y = try toNumber(rt, b);
    if (std.math.isNan(x) or std.math.isNan(y)) return null;
    return x < y;
}

pub fn stringToBigIntOpt(rt: *Runtime, units_in: []const u16) Error!?*const heap.BigInt {
    var units = units_in;
    while (units.len > 0 and isJsWhitespace(units[0])) units = units[1..];
    while (units.len > 0 and isJsWhitespace(units[units.len - 1])) units = units[0 .. units.len - 1];
    if (units.len == 0) return try bigint.zero(rt);
    var ascii = try rt.gpa.alloc(u8, units.len);
    defer rt.gpa.free(ascii);
    for (units, 0..) |u, i| {
        if (u > 0x7f) return null;
        ascii[i] = @intCast(u);
    }
    return bigint.tryParse(rt, ascii, false);
}

pub fn toNumeric(rt: *Runtime, v_in: Value) Error!Value {
    const v = if (v_in.isObjectLike()) try object.toPrimitive(rt, v_in, .number) else v_in;
    if (v.isBigInt() or v.isNumber()) return v;
    return Value.fromNumber(try toNumber(rt, v));
}

/// ES ToBigInt(argument): throws TypeError on Number/Undefined/Null/Symbol,
/// SyntaxError on invalid String, converts Boolean to 0n/1n.
pub fn toBigInt(rt: *Runtime, v_in: Value) Error!*const heap.BigInt {
    const v = if (v_in.isObjectLike()) try object.toPrimitive(rt, v_in, .number) else v_in;
    return switch (v.unpack()) {
        .bigint => |b| b,
        .boolean => |b| bigint.fromU64(rt, if (b) 1 else 0),
        .string => |s| (try stringToBigIntOpt(rt, s.units)) orelse
            rt.throw(.SyntaxError, &.{.{ .ascii = "Cannot convert string to a BigInt" }}),
        .undefined, .null, .number, .symbol => rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert value to a BigInt" }}),
        .native, .closure, .object => unreachable,
    };
}

pub fn strictEquals(a: Value, b: Value) bool {
    if (a.isNumber() and b.isNumber()) return a.asNumber() == b.asNumber(); // NaN !== NaN, 0 === -0
    if (a.bits == b.bits) return !a.isNumber();
    if (a.isString() and b.isString()) return std.mem.eql(u16, a.asString().units, b.asString().units);
    if (a.isBigInt() and b.isBigInt()) return bigint.cmp(a.asBigInt(), b.asBigInt()) == .eq;
    return false;
}

/// All binary operators except `&&`/`||` (which short-circuit, so they are control
/// flow in the evaluator). Both operands have already been evaluated, left first.
pub fn binary(rt: *Runtime, op: ast.BinaryOp, a_in: Value, b_in: Value) Error!Value {
    var roots_buf = [_]Value{ a_in, b_in };
    var roots = rt_mod.ValueRoots{ .values = &roots_buf };
    const may_call = a_in.isObjectLike() or b_in.isObjectLike();
    if (may_call) try roots.register(rt);
    defer if (may_call) roots.unregister(rt);

    // `+` converts with `.default`; relational operators convert with `.number`, left then right.
    const a = switch (op) {
        .add => if (a_in.isObjectLike()) try object.toPrimitive(rt, a_in, .default) else a_in,
        .lt, .gt, .le, .ge => if (a_in.isObjectLike()) try object.toPrimitive(rt, a_in, .number) else a_in,
        else => a_in,
    };
    if (may_call) roots_buf[0] = a;
    const b = switch (op) {
        .add => if (b_in.isObjectLike()) try object.toPrimitive(rt, b_in, .default) else b_in,
        .lt, .gt, .le, .ge => if (b_in.isObjectLike()) try object.toPrimitive(rt, b_in, .number) else b_in,
        else => b_in,
    };
    if (may_call) roots_buf[1] = b;
    return switch (op) {
        .add => {
            if (a.isString() or b.isString()) {
                var buf_a: NumberBuf = undefined;
                var buf_b: NumberBuf = undefined;
                const pa = try toPiece(rt, a, &buf_a);
                const pb = try toPiece(rt, b, &buf_b);
                return Value.fromString(try rt.heap.newString(&.{ pa, pb }));
            }
            const na = try toNumeric(rt, a);
            const nb = try toNumeric(rt, b);
            if (na.isBigInt() and nb.isBigInt()) {
                return Value.fromBigInt(try bigint.add(rt, na.asBigInt(), nb.asBigInt()));
            }
            if (na.isBigInt() or nb.isBigInt()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "Cannot mix BigInt and other types, use explicit conversions" }});
            }
            return Value.fromNumber(na.asNumber() + nb.asNumber());
        },
        .sub, .mul, .div, .mod, .pow, .shl, .shr, .ushr, .bit_and, .bit_xor, .bit_or => {
            const na = try toNumeric(rt, a);
            const nb = try toNumeric(rt, b);
            if (na.isBigInt() and nb.isBigInt()) {
                const x = na.asBigInt();
                const y = nb.asBigInt();
                return switch (op) {
                    .sub => Value.fromBigInt(try bigint.sub(rt, x, y)),
                    .mul => Value.fromBigInt(try bigint.mul(rt, x, y)),
                    .div => Value.fromBigInt((try bigint.divRem(rt, x, y)).quot),
                    .mod => Value.fromBigInt((try bigint.divRem(rt, x, y)).rem),
                    .pow => Value.fromBigInt(try bigint.pow(rt, x, y)),
                    .shl => Value.fromBigInt(try bigint.shl(rt, x, y)),
                    .shr => Value.fromBigInt(try bigint.shr(rt, x, y)),
                    .ushr => rt.throw(.TypeError, &.{.{ .ascii = "BigInts have no unsigned right shift, use >> instead" }}),
                    .bit_and => Value.fromBigInt(try bigint.bitAnd(rt, x, y)),
                    .bit_xor => Value.fromBigInt(try bigint.bitXor(rt, x, y)),
                    .bit_or => Value.fromBigInt(try bigint.bitOr(rt, x, y)),
                    else => unreachable,
                };
            }
            if (na.isBigInt() or nb.isBigInt()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "Cannot mix BigInt and other types, use explicit conversions" }});
            }
            const x = na.asNumber();
            const y = nb.asNumber();
            return Value.fromNumber(switch (op) {
                .sub => x - y,
                .mul => x * y,
                .div => x / y,
                .mod => remainder(x, y),
                .pow => pow(x, y),
                .shl => bitShl(x, y),
                .shr => bitShr(x, y),
                .ushr => bitUshr(x, y),
                .bit_and => bitAnd(x, y),
                .bit_xor => bitXor(x, y),
                .bit_or => bitOr(x, y),
                else => unreachable,
            });
        },
        .in => Value.fromBool(try object.has(rt, try object.key(rt, a), b)),
        .instanceof => Value.fromBool(try object.instanceOf(rt, a, b)),
        .lt => Value.fromBool((try lessThan(rt, a, b)) orelse false),
        .gt => Value.fromBool((try lessThan(rt, b, a)) orelse false),
        .le => Value.fromBool(if (try lessThan(rt, b, a)) |r| !r else false),
        .ge => Value.fromBool(if (try lessThan(rt, a, b)) |r| !r else false),
        .strict_eq => Value.fromBool(strictEquals(a, b)),
        .strict_ne => Value.fromBool(!strictEquals(a, b)),
        .logical_and, .logical_or, .nullish, .comma => unreachable,
    };
}

/// JS `typeof`: returns the type tag string for any value.
pub fn typeOf(rt: *Runtime, v: Value) Error!Value {
    const s: []const u8 = switch (v.unpack()) {
        .undefined => "undefined",
        .null => "object",
        .boolean => "boolean",
        .number => "number",
        .bigint => "bigint",
        .string => "string",
        .symbol => "symbol",
        .native, .closure => "function",
        .object => |o| if (o.kind == .proxy and o.kind.proxy.is_callable) "function" else "object",
    };
    return Value.fromString(try rt.heap.ascii(s));
}

// ------------------------------------------------------------ Bitwise / ToInt32 / ToUint32

pub fn toUint32(n: f64) u32 {
    if (!std.math.isFinite(n) or n == 0.0) return 0;
    const rem = @mod(@trunc(n), 4294967296.0);
    return @intFromFloat(rem);
}

pub fn toInt32(n: f64) i32 {
    return @bitCast(toUint32(n));
}

pub fn bitNot(n: f64) f64 {
    return @floatFromInt(~toInt32(n));
}

pub fn bitAnd(a: f64, b: f64) f64 {
    return @floatFromInt(toInt32(a) & toInt32(b));
}

pub fn bitXor(a: f64, b: f64) f64 {
    return @floatFromInt(toInt32(a) ^ toInt32(b));
}

pub fn bitOr(a: f64, b: f64) f64 {
    return @floatFromInt(toInt32(a) | toInt32(b));
}

pub fn bitShl(a: f64, b: f64) f64 {
    const shift: u5 = @truncate(toUint32(b));
    return @floatFromInt(toInt32(a) << shift);
}

pub fn bitShr(a: f64, b: f64) f64 {
    const shift: u5 = @truncate(toUint32(b));
    return @floatFromInt(toInt32(a) >> shift);
}

pub fn bitUshr(a: f64, b: f64) f64 {
    const shift: u5 = @truncate(toUint32(b));
    return @floatFromInt(toUint32(a) >> shift);
}

// ------------------------------------------------------------ tests (golden tables in tests/ops)

const testing = std.testing;

test "formatNumber: layout boundaries" {
    var buf: NumberBuf = undefined;
    const cases = [_]struct { f64, []const u8 }{
        .{ 0, "0" },                        .{ -0.0, "0" },        .{ 1e21, "1e+21" },
        .{ 1e20, "100000000000000000000" }, .{ 1e-6, "0.000001" }, .{ 1e-7, "1e-7" },
        .{ -1.5, "-1.5" },                  .{ 5e-324, "5e-324" }, .{ 123.456, "123.456" },
    };
    for (cases) |c| try testing.expectEqualStrings(c[1], formatNumber(&buf, c[0]));
}

test "-0 survives arithmetic and is distinguished where JS distinguishes it" {
    try testing.expect(std.math.signbit(-@as(f64, 0)));
    try testing.expect(std.math.signbit(remainder(-0.0, 5)));
    try testing.expect(std.math.signbit(@as(f64, 0) * -1));
    try testing.expect(!std.math.signbit(@as(f64, -0.0) + 0));
    try testing.expect(strictEquals(Value.fromNumber(-0.0), Value.fromNumber(0)));
    try testing.expectEqual(-std.math.inf(f64), 1 / @as(f64, -0.0));
    try testing.expect(std.math.signbit(try stringToNumber(testing.allocator, &.{ '-', '0' })));
}
