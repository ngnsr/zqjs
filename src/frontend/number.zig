//! Number values of literal text: shared by the parser (source literals) and
//! runtime/ops.zig (`Number("0x1f")`), so both round radix integers the same way.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The value of a number literal the lexer has already validated (DESIGN_DECISIONS D18):
/// decimal or `0x`/`0o`/`0b`, with `_` separators only between digits.
pub fn literalValue(arena: Allocator, text: []const u8) Allocator.Error!f64 {
    if (text.len > 2 and text[0] == '0') {
        const radix: u8 = switch (text[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => 0,
        };
        if (radix != 0) return radixToNumber(text[2..], radix, true);
    }
    if (std.mem.indexOfScalar(u8, text, '_') == null) return std.fmt.parseFloat(f64, text) catch unreachable;
    const digits = try arena.alloc(u8, text.len);
    var n: usize = 0;
    for (text) |c| if (c != '_') {
        digits[n] = c;
        n += 1;
    };
    return std.fmt.parseFloat(f64, digits[0..n]) catch unreachable;
}

/// Correctly rounded value of an unsigned integer in radix 2, 8 or 16 (NaN if empty or
/// a character isn't a digit; `_` is skipped only if `separators`).
/// These radixes map digits to whole bits, so we stream the bits MSB first, keep the
/// first 64 significant ones in `top`, count the rest in `shift` and OR them into
/// `sticky`. Folding `sticky` into the lowest bit of `top` (far below f64's 53-bit
/// precision) makes `@floatFromInt` round exactly as if it had seen every bit.
/// (`std.fmt.parseFloat` truncates hex mantissas longer than 64 bits, so it can't be used.)
pub fn radixToNumber(digits: []const u8, radix: u8, separators: bool) f64 {
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
        if (separators and c == '_') continue;
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

test "literal values" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(@as(f64, 31), try literalValue(a, "0x1F"));
    try t.expectEqual(@as(f64, 15), try literalValue(a, "0o17"));
    try t.expectEqual(@as(f64, 5), try literalValue(a, "0b1_01"));
    try t.expectEqual(@as(f64, 1000.5), try literalValue(a, "1_000.5"));
    try t.expectEqual(@as(f64, 1e10), try literalValue(a, "1e1_0"));
    try t.expectEqual(@as(f64, 0), try literalValue(a, "0"));
    // 2^53 + 1 is a tie and rounds to even (2^53); 2^57 + 17 is past the tie (ulp 32), so up.
    try t.expectEqual(@as(f64, 9007199254740992), try literalValue(a, "0x20000000000001"));
    try t.expectEqual(@as(f64, 144115188075855904), try literalValue(a, "0x200000000000011"));
}
