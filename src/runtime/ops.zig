//! JavaScript semantics of values: conversions and operators (DESIGN_DECISIONS D16).
//! The tree-walker uses these now and the VM will use them unchanged. This is the
//! ONLY place that converts between numbers and strings; the CLI, the heap and
//! `print` all go through `formatNumber` / `toPiece`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../frontend/ast.zig");
const heap = @import("heap.zig");
const Piece = heap.Piece;
const Value = @import("value.zig").Value;
const rt_mod = @import("runtime.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const object = @import("object.zig");

// ------------------------------------------------------------ ToBoolean

pub fn toBoolean(v: Value) bool {
    return switch (v) {
        .undefined, .null => false,
        .boolean => |b| b,
        .number => |n| !(n == 0 or std.math.isNan(n)), // 0, -0 and NaN are falsy
        .string => |s| s.units.len != 0,
        .native, .closure, .object => true,
    };
}

// ------------------------------------------------------------ ToNumber

pub fn toNumber(rt: *Runtime, v: Value) Error!f64 {
    const gpa = rt.gpa;
    return switch (v) {
        .undefined => std.math.nan(f64),
        .null => 0,
        .boolean => |b| if (b) 1 else 0,
        .number => |n| n,
        .string => |s| stringToNumber(gpa, s.units),
        // ToPrimitive gives the source text, which is never a numeric string.
        .native, .closure => std.math.nan(f64),
        .object => toNumber(rt, try object.toPrimitive(rt, v, .number)),
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
        if (radix != 0) return radixToNumber(s[2..], radix);
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

/// Correctly rounded value of an unsigned integer in radix 2, 8 or 16.
/// These radixes map digits to whole bits, so we stream the bits MSB first, keep the
/// first 64 significant ones in `top`, count the rest in `shift` and OR them into
/// `sticky`. Folding `sticky` into the lowest bit of `top` (far below f64's 53-bit
/// precision) makes `@floatFromInt` round exactly as if it had seen every bit.
/// (`std.fmt.parseFloat` truncates hex mantissas longer than 64 bits, so it can't be used.)
fn radixToNumber(digits: []const u8, radix: u8) f64 {
    if (digits.len == 0) return std.math.nan(f64);
    const bits_per_digit: u3 = switch (radix) {
        2 => 1,
        8 => 3,
        16 => 4,
        else => unreachable,
    };
    var top: u64 = 0;
    var top_bits: u7 = 0; // significant bits stored in `top`
    var shift: usize = 0; // significant bits beyond the first 64
    var sticky = false;
    for (digits) |c| {
        const d = std.fmt.charToDigit(c, radix) catch return std.math.nan(f64);
        var b: u3 = bits_per_digit;
        while (b > 0) {
            b -= 1;
            const bit: u1 = @intCast((d >> b) & 1);
            if (top_bits == 0 and bit == 0) continue; // leading zeros
            if (top_bits < 64) {
                top = (top << 1) | bit;
                top_bits += 1;
            } else {
                shift += 1;
                sticky = sticky or bit == 1;
            }
        }
    }
    if (sticky) top |= 1;
    const value: f64 = @floatFromInt(top);
    if (shift > 2048) return if (top == 0) 0 else std.math.inf(f64);
    return std.math.ldexp(value, @intCast(shift));
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
    return switch (v) {
        .undefined => .{ .ascii = "undefined" },
        .null => .{ .ascii = "null" },
        .boolean => |b| .{ .ascii = if (b) "true" else "false" },
        .number => |n| .{ .ascii = formatNumber(buf, n) },
        .string => |s| .{ .utf16 = s.units },
        // Node prints the function's source text; ZQJS has none to show (yet).
        .native, .closure => rt.fail(.function_to_string),
        .object => toPiece(rt, try object.toPrimitive(rt, v, .string), buf),
    };
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
    if (a == .string and b == .string) return std.mem.order(u16, a.string.units, b.string.units) == .lt;
    // ToPrimitive turns a function into its source text, so against a string (or another
    // function) JS compares that text as a string: `print > 'a'` is true. ZQJS has no
    // source text to compare. Against anything else the text becomes NaN, as below.
    const textual = struct {
        fn f(v: Value) bool {
            return v == .string or v.isFunction();
        }
    }.f;
    if ((a.isFunction() and textual(b)) or (b.isFunction() and textual(a))) return rt.fail(.function_to_string);
    const x = try toNumber(rt, a);
    const y = try toNumber(rt, b);
    if (std.math.isNan(x) or std.math.isNan(y)) return null;
    return x < y;
}

pub fn strictEquals(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .undefined, .null => true,
        .boolean => |x| x == b.boolean,
        .number => |x| x == b.number, // NaN !== NaN, 0 === -0
        .string => |x| std.mem.eql(u16, x.units, b.string.units),
        .native => |x| x == b.native,
        .closure => |x| x == b.closure, // identity
        .object => |x| x == b.object,
    };
}

/// All binary operators except `&&`/`||` (which short-circuit, so they are control
/// flow in the evaluator). Both operands have already been evaluated, left first.
pub fn binary(rt: *Runtime, op: ast.BinaryOp, a_in: Value, b_in: Value) Error!Value {
    // `+` and the relational operators convert objects first, left then right (ToPrimitive
    // with the default/number hint); the arithmetic ones convert through toNumber.
    const converts = switch (op) {
        .add, .lt, .gt, .le, .ge => true,
        else => false,
    };
    // (Tested here rather than inside toPrimitive: the common case stays call-free.)
    const a = if (converts and a_in == .object) try object.toPrimitive(rt, a_in, .number) else a_in;
    const b = if (converts and b_in == .object) try object.toPrimitive(rt, b_in, .number) else b_in;
    return switch (op) {
        .add => {
            if (a == .string or b == .string) {
                var buf_a: NumberBuf = undefined;
                var buf_b: NumberBuf = undefined;
                const pa = try toPiece(rt, a, &buf_a);
                const pb = try toPiece(rt, b, &buf_b);
                return .{ .string = try rt.heap.newString(&.{ pa, pb }) };
            }
            return .{ .number = try toNumber(rt, a) + try toNumber(rt, b) };
        },
        .sub => .{ .number = try toNumber(rt, a) - try toNumber(rt, b) },
        .mul => .{ .number = try toNumber(rt, a) * try toNumber(rt, b) },
        .div => .{ .number = try toNumber(rt, a) / try toNumber(rt, b) },
        .mod => .{ .number = remainder(try toNumber(rt, a), try toNumber(rt, b)) },
        .pow => .{ .number = pow(try toNumber(rt, a), try toNumber(rt, b)) },
        .in => .{ .boolean = try object.has(rt, try object.key(rt, a), b) },
        .lt => .{ .boolean = (try lessThan(rt, a, b)) orelse false },
        .gt => .{ .boolean = (try lessThan(rt, b, a)) orelse false },
        .le => .{ .boolean = if (try lessThan(rt, b, a)) |r| !r else false },
        .ge => .{ .boolean = if (try lessThan(rt, a, b)) |r| !r else false },
        .strict_eq => .{ .boolean = strictEquals(a, b) },
        .strict_ne => .{ .boolean = !strictEquals(a, b) },
        .logical_and, .logical_or => unreachable,
    };
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
    try testing.expect(strictEquals(.{ .number = -0.0 }, .{ .number = 0 }));
    try testing.expectEqual(-std.math.inf(f64), 1 / @as(f64, -0.0));
    try testing.expect(std.math.signbit(try stringToNumber(testing.allocator, &.{ '-', '0' })));
}
