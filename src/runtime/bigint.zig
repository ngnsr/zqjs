//! Arbitrary-precision integer arithmetic (M47, D77).
//! Pure-Zig implementation with zero external dependencies.
//!
//! Representation invariant (enforced by `Heap.newBigInt`):
//! - `0n` always has `limbs.len == 0` and `negative == false`.
//! - Non-zero values have little-endian `u64` limbs with `limbs[limbs.len - 1] != 0`.

const std = @import("std");
const heap = @import("heap.zig");
const Runtime = @import("runtime.zig").Runtime;
const Error = @import("runtime.zig").Error;
const ops = @import("ops.zig");

pub const BigInt = heap.BigInt;

pub fn bitLength(limbs: []const u64) usize {
    if (limbs.len == 0) return 0;
    return (limbs.len - 1) * 64 + (64 - @clz(limbs[limbs.len - 1]));
}

fn checkBitLimit(rt: *Runtime, bits: usize) Error!void {
    if (bits > rt.limits.max_bigint_bits) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Maximum BigInt size exceeded" }});
    }
}

pub fn zero(rt: *Runtime) Error!*const BigInt {
    return rt.heap.newBigInt(false, &.{});
}

pub fn fromU64(rt: *Runtime, v: u64) Error!*const BigInt {
    if (v == 0) return rt.heap.newBigInt(false, &.{});
    return rt.heap.newBigInt(false, &.{v});
}

pub fn fromI64(rt: *Runtime, v: i64) Error!*const BigInt {
    if (v == 0) return rt.heap.newBigInt(false, &.{});
    if (v > 0) return rt.heap.newBigInt(false, &.{@intCast(v)});
    const mag: u64 = @bitCast(-%v);
    return rt.heap.newBigInt(true, &.{mag});
}

pub fn fromF64Exact(rt: *Runtime, v: f64) Error!*const BigInt {
    if (!std.math.isFinite(v) or @trunc(v) != v) {
        return rt.throw(.RangeError, &.{.{ .ascii = "The number cannot be converted to a BigInt because it is not an integer" }});
    }
    if (v == 0.0) return zero(rt);

    const bits: u64 = @bitCast(v);
    const sign = (bits >> 63) != 0;
    const exp_biased: i32 = @intCast((bits >> 52) & 0x7ff);
    const exp: i32 = exp_biased - 1023;
    const mant: u64 = (bits & ((@as(u64, 1) << 52) - 1)) | (@as(u64, 1) << 52);

    if (exp < 52) {
        const shift_right: u6 = @intCast(52 - exp);
        return rt.heap.newBigInt(sign, &.{mant >> shift_right});
    }

    const shift_left: usize = @intCast(exp - 52);
    const total_bits = 53 + shift_left;
    try checkBitLimit(rt, total_bits);

    var limbs: [17]u64 = @splat(0); // max integer f64 is 1024 bits = 16 limbs (+1 for cross-limb shift)
    const limb_idx = shift_left / 64;
    const bit_off: u6 = @intCast(shift_left % 64);
    limbs[limb_idx] = mant << bit_off;
    if (bit_off > 0) {
        limbs[limb_idx + 1] = mant >> @intCast(64 - @as(u7, bit_off));
    }
    return rt.heap.newBigInt(sign, limbs[0 .. limb_idx + 2]);
}

/// Converts a BigInt to IEEE-754 `f64` using round-half-to-even.
pub fn toF64(b: *const BigInt) f64 {
    if (b.limbs.len == 0) return 0.0;
    const bl = bitLength(b.limbs);
    if (bl > 1024) {
        return if (b.negative) -std.math.inf(f64) else std.math.inf(f64);
    }
    if (bl <= 53) {
        const mag = @as(f64, @floatFromInt(b.limbs[0]));
        return if (b.negative) -mag else mag;
    }

    // Extract top 53 bits starting at bit `bl - 53`.
    const drop = bl - 53;
    const low_limb = drop / 64;
    const low_bit: u6 = @intCast(drop % 64);

    var sig: u64 = b.limbs[low_limb] >> low_bit;
    if (low_bit > 0 and low_limb + 1 < b.limbs.len) {
        sig |= b.limbs[low_limb + 1] << @intCast(64 - @as(u7, low_bit));
    }
    sig &= (@as(u64, 1) << 53) - 1;

    // Round bit is bit `drop - 1`.
    const round_pos = drop - 1;
    const round_limb = round_pos / 64;
    const round_bit_idx: u6 = @intCast(round_pos % 64);
    const round_bit = ((b.limbs[round_limb] >> round_bit_idx) & 1) != 0;

    // Sticky bit is OR of all bits strictly below `round_pos`.
    var sticky = false;
    if (round_bit_idx > 0) {
        const mask = (@as(u64, 1) << round_bit_idx) - 1;
        if ((b.limbs[round_limb] & mask) != 0) sticky = true;
    }
    if (!sticky) {
        for (b.limbs[0..round_limb]) |w| {
            if (w != 0) {
                sticky = true;
                break;
            }
        }
    }

    var exp: i32 = @intCast(bl - 1);
    if (round_bit and (sticky or (sig & 1) != 0)) {
        sig += 1;
        if (sig == (@as(u64, 1) << 53)) {
            sig >>= 1;
            exp += 1;
        }
    }
    if (exp >= 1024) {
        return if (b.negative) -std.math.inf(f64) else std.math.inf(f64);
    }

    const sign_bit: u64 = if (b.negative) @as(u64, 1) << 63 else 0;
    const exp_bits: u64 = @as(u64, @intCast(exp + 1023)) << 52;
    const mant_bits: u64 = sig & ((@as(u64, 1) << 52) - 1);
    return @bitCast(sign_bit | exp_bits | mant_bits);
}

pub fn toU64Wrapping(b: *const BigInt) u64 {
    if (b.limbs.len == 0) return 0;
    const low = b.limbs[0];
    return if (b.negative) -%low else low;
}

pub fn toI64Wrapping(b: *const BigInt) i64 {
    return @bitCast(toU64Wrapping(b));
}

pub fn cmpMag(a: []const u64, b: []const u64) std.math.Order {
    if (a.len != b.len) return if (a.len < b.len) .lt else .gt;
    var i = a.len;
    while (i > 0) {
        i -= 1;
        if (a[i] != b[i]) return if (a[i] < b[i]) .lt else .gt;
    }
    return .eq;
}

pub fn cmp(a: *const BigInt, b: *const BigInt) std.math.Order {
    if (a.limbs.len == 0 and b.limbs.len == 0) return .eq;
    if (a.negative != b.negative) return if (a.negative) .lt else .gt;
    const mag_ord = cmpMag(a.limbs, b.limbs);
    return if (a.negative) switch (mag_ord) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    } else mag_ord;
}

/// Exact mathematical comparison between a BigInt and an `f64`.
/// Returns `null` when `n` is `NaN`.
pub fn cmpNumber(b: *const BigInt, n: f64) ?std.math.Order {
    if (std.math.isNan(n)) return null;
    if (n == std.math.inf(f64)) return .lt;
    if (n == -std.math.inf(f64)) return .gt;
    if (n == 0.0) {
        if (b.limbs.len == 0) return .eq;
        return if (b.negative) .lt else .gt;
    }

    const n_neg = n < 0.0;
    if (b.limbs.len == 0) return if (n_neg) .gt else .lt;
    if (b.negative != n_neg) return if (b.negative) .lt else .gt;

    // Same sign: compare magnitudes, then flip if negative.
    const abs_n = @abs(n);
    const mag_ord: std.math.Order = blk: {
        if (abs_n < 1.0) break :blk .gt; // |b| >= 1 > |n|
        const int_part = @trunc(abs_n);
        const has_frac = abs_n != int_part;
        const bits: u64 = @bitCast(int_part);
        const exp: usize = @intCast(((bits >> 52) & 0x7ff) - 1023);
        const n_bits = exp + 1;
        const b_bits = bitLength(b.limbs);
        if (b_bits < n_bits) break :blk .lt;
        if (b_bits > n_bits) break :blk .gt;

        // Same bit length: reconstruct integer limbs of `int_part` on stack.
        const mant: u64 = (bits & ((@as(u64, 1) << 52) - 1)) | (@as(u64, 1) << 52);
        var n_limbs: [17]u64 = @splat(0);
        var n_len: usize = 1;
        if (exp < 52) {
            n_limbs[0] = mant >> @intCast(52 - exp);
        } else {
            const shift_left = exp - 52;
            const limb_idx = shift_left / 64;
            const bit_off: u6 = @intCast(shift_left % 64);
            n_limbs[limb_idx] = mant << bit_off;
            n_len = limb_idx + 1;
            if (bit_off > 0) {
                const hi = mant >> @intCast(64 - @as(u7, bit_off));
                if (hi != 0) {
                    n_limbs[limb_idx + 1] = hi;
                    n_len = limb_idx + 2;
                }
            }
        }
        const ord = cmpMag(b.limbs, n_limbs[0..n_len]);
        if (ord == .eq and has_frac) break :blk .lt;
        break :blk ord;
    };

    return if (b.negative) switch (mag_ord) {
        .lt => .gt,
        .gt => .lt,
        .eq => .eq,
    } else mag_ord;
}

pub fn neg(rt: *Runtime, a: *const BigInt) Error!*const BigInt {
    if (a.limbs.len == 0) return a;
    return rt.heap.newBigInt(!a.negative, a.limbs);
}

fn addMag(alloc: std.mem.Allocator, a: []const u64, b: []const u64) Error![]u64 {
    const max_len = @max(a.len, b.len);
    var out = try alloc.alloc(u64, max_len + 1);
    var carry: u128 = 0;
    for (0..max_len) |i| {
        const av: u128 = if (i < a.len) a[i] else 0;
        const bv: u128 = if (i < b.len) b[i] else 0;
        const sum = av + bv + carry;
        out[i] = @truncate(sum);
        carry = sum >> 64;
    }
    out[max_len] = @truncate(carry);
    return out;
}

/// Computes `a - b`, assuming `a >= b` in magnitude.
fn subMag(alloc: std.mem.Allocator, a: []const u64, b: []const u64) Error![]u64 {
    var out = try alloc.alloc(u64, a.len);
    var borrow: u128 = 0;
    for (0..a.len) |i| {
        const av: u128 = a[i];
        const bv: u128 = (if (i < b.len) @as(u128, b[i]) else 0) + borrow;
        if (av >= bv) {
            out[i] = @truncate(av - bv);
            borrow = 0;
        } else {
            out[i] = @truncate(((@as(u128, 1) << 64) + av) - bv);
            borrow = 1;
        }
    }
    return out;
}

pub fn add(rt: *Runtime, a: *const BigInt, b: *const BigInt) Error!*const BigInt {
    if (a.limbs.len == 0) return b;
    if (b.limbs.len == 0) return a;

    if (a.negative == b.negative) {
        const limbs = try addMag(rt.gpa, a.limbs, b.limbs);
        defer rt.gpa.free(limbs);
        var len = limbs.len;
        while (len > 0 and limbs[len - 1] == 0) : (len -= 1) {}
        try checkBitLimit(rt, bitLength(limbs[0..len]));
        return rt.heap.newBigInt(a.negative, limbs[0..len]);
    }

    const ord = cmpMag(a.limbs, b.limbs);
    if (ord == .eq) return zero(rt);
    if (ord == .gt) {
        const limbs = try subMag(rt.gpa, a.limbs, b.limbs);
        defer rt.gpa.free(limbs);
        return rt.heap.newBigInt(a.negative, limbs);
    } else {
        const limbs = try subMag(rt.gpa, b.limbs, a.limbs);
        defer rt.gpa.free(limbs);
        return rt.heap.newBigInt(b.negative, limbs);
    }
}

pub fn sub(rt: *Runtime, a: *const BigInt, b: *const BigInt) Error!*const BigInt {
    if (b.limbs.len == 0) return a;
    if (a.limbs.len == 0) return neg(rt, b);

    if (a.negative != b.negative) {
        const limbs = try addMag(rt.gpa, a.limbs, b.limbs);
        defer rt.gpa.free(limbs);
        var len = limbs.len;
        while (len > 0 and limbs[len - 1] == 0) : (len -= 1) {}
        try checkBitLimit(rt, bitLength(limbs[0..len]));
        return rt.heap.newBigInt(a.negative, limbs[0..len]);
    }

    const ord = cmpMag(a.limbs, b.limbs);
    if (ord == .eq) return zero(rt);
    if (ord == .gt) {
        const limbs = try subMag(rt.gpa, a.limbs, b.limbs);
        defer rt.gpa.free(limbs);
        return rt.heap.newBigInt(a.negative, limbs);
    } else {
        const limbs = try subMag(rt.gpa, b.limbs, a.limbs);
        defer rt.gpa.free(limbs);
        return rt.heap.newBigInt(!a.negative, limbs);
    }
}

pub fn addI64(rt: *Runtime, a: *const BigInt, delta: i64) Error!*const BigInt {
    if (delta == 0) return a;
    const b = try fromI64(rt, delta);
    return add(rt, a, b);
}

pub fn mul(rt: *Runtime, a: *const BigInt, b: *const BigInt) Error!*const BigInt {
    if (a.limbs.len == 0 or b.limbs.len == 0) return zero(rt);

    const a_bits = bitLength(a.limbs);
    const b_bits = bitLength(b.limbs);
    // Product has at least (a_bits - 1) + (b_bits - 1) + 1 bits.
    if (a_bits + b_bits - 1 > rt.limits.max_bigint_bits) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Maximum BigInt size exceeded" }});
    }

    var out = try rt.gpa.alloc(u64, a.limbs.len + b.limbs.len);
    defer rt.gpa.free(out);
    @memset(out, 0);

    for (a.limbs, 0..) |av, i| {
        try rt.step();
        var carry: u128 = 0;
        for (b.limbs, 0..) |bv, j| {
            const prod = @as(u128, av) * @as(u128, bv) + @as(u128, out[i + j]) + carry;
            out[i + j] = @truncate(prod);
            carry = prod >> 64;
        }
        out[i + b.limbs.len] = @truncate(carry);
    }

    var len = out.len;
    while (len > 0 and out[len - 1] == 0) : (len -= 1) {}
    try checkBitLimit(rt, bitLength(out[0..len]));
    return rt.heap.newBigInt(a.negative != b.negative, out[0..len]);
}

pub const DivRemResult = struct {
    quot: *const BigInt,
    rem: *const BigInt,
};

/// Truncated division toward zero (JS `/` and `%` semantics).
pub fn divRem(rt: *Runtime, a: *const BigInt, b: *const BigInt) Error!DivRemResult {
    if (b.limbs.len == 0) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Division by zero" }});
    }
    if (a.limbs.len == 0) {
        const z = try zero(rt);
        return .{ .quot = z, .rem = z };
    }

    const ord = cmpMag(a.limbs, b.limbs);
    if (ord == .lt) {
        return .{ .quot = try zero(rt), .rem = a };
    }
    if (ord == .eq) {
        const q = try rt.heap.newBigInt(a.negative != b.negative, &.{1});
        return .{ .quot = q, .rem = try zero(rt) };
    }

    const q_neg = a.negative != b.negative;
    const r_neg = a.negative;

    // Fast path: single-limb divisor.
    if (b.limbs.len == 1) {
        const d = b.limbs[0];
        var q = try rt.gpa.alloc(u64, a.limbs.len);
        defer rt.gpa.free(q);
        var rem: u128 = 0;
        var i = a.limbs.len;
        while (i > 0) {
            i -= 1;
            const cur = (rem << 64) | a.limbs[i];
            q[i] = @truncate(cur / d);
            rem = cur % d;
        }
        const rem_u64: u64 = @truncate(rem);
        const q_big = try rt.heap.newBigInt(q_neg, q);
        const r_big = if (rem_u64 == 0) try zero(rt) else try rt.heap.newBigInt(r_neg, &.{rem_u64});
        return .{ .quot = q_big, .rem = r_big };
    }

    // Knuth Algorithm D for multi-limb divisor (`n >= 2`, `a.limbs.len >= n`).
    const n = b.limbs.len;
    const m = a.limbs.len - n;
    const shift: u6 = @intCast(@clz(b.limbs[n - 1]));

    var u = try rt.gpa.alloc(u64, a.limbs.len + 1);
    defer rt.gpa.free(u);
    var v = try rt.gpa.alloc(u64, n);
    defer rt.gpa.free(v);
    var q = try rt.gpa.alloc(u64, m + 1);
    defer rt.gpa.free(q);
    @memset(q, 0);

    // D1: Normalize u and v so v[n-1] >= 2^63.
    if (shift == 0) {
        @memcpy(u[0..a.limbs.len], a.limbs);
        u[a.limbs.len] = 0;
        @memcpy(v, b.limbs);
    } else {
        const inv_shift: u6 = @intCast(64 - @as(u7, shift));
        var carry: u64 = 0;
        for (a.limbs, 0..) |limb, idx| {
            u[idx] = (limb << shift) | carry;
            carry = limb >> inv_shift;
        }
        u[a.limbs.len] = carry;

        carry = 0;
        for (b.limbs, 0..) |limb, idx| {
            v[idx] = (limb << shift) | carry;
            carry = limb >> inv_shift;
        }
    }

    const vn1: u128 = v[n - 1];
    const vn2: u128 = v[n - 2];
    const base: u128 = @as(u128, 1) << 64;

    // D2..D7: Main loop from j = m down to 0.
    var j_plus_1 = m + 1;
    while (j_plus_1 > 0) {
        j_plus_1 -= 1;
        const j = j_plus_1;
        try rt.step();

        const top: u128 = (@as(u128, u[j + n]) << 64) | u[j + n - 1];
        var qhat: u128 = top / vn1;
        var rhat: u128 = top % vn1;

        while (qhat >= base or qhat * vn2 > (rhat << 64) | u[j + n - 2]) {
            qhat -= 1;
            rhat += vn1;
            if (rhat >= base) break;
        }

        // D4: Multiply and subtract u[j..j+n] -= qhat * v[0..n-1].
        var borrow: u128 = 0;
        for (0..n) |i| {
            const p = qhat * v[i] + borrow;
            const lo: u64 = @truncate(p);
            if (u[j + i] >= lo) {
                u[j + i] -= lo;
                borrow = p >> 64;
            } else {
                u[j + i] = @truncate((base + u[j + i]) - lo);
                borrow = (p >> 64) + 1;
            }
        }
        const underflow = @as(u128, u[j + n]) < borrow;
        u[j + n] = @truncate((@as(u128, u[j + n]) + (if (underflow) base else 0)) - borrow);

        // D5/D6: Add back if we subtracted one too many.
        q[j] = @truncate(qhat);
        if (underflow) {
            q[j] -= 1;
            var carry: u128 = 0;
            for (0..n) |i| {
                const sum = @as(u128, u[j + i]) + v[i] + carry;
                u[j + i] = @truncate(sum);
                carry = sum >> 64;
            }
            u[j + n] +%= @truncate(carry);
        }
    }

    // D8: Unnormalize remainder u[0..n].
    if (shift > 0) {
        const inv_shift: u6 = @intCast(64 - @as(u7, shift));
        for (0..n - 1) |i| {
            u[i] = (u[i] >> shift) | (u[i + 1] << inv_shift);
        }
        u[n - 1] >>= shift;
    }

    const q_big = try rt.heap.newBigInt(q_neg, q);
    const r_big = try rt.heap.newBigInt(r_neg, u[0..n]);
    return .{ .quot = q_big, .rem = r_big };
}

pub fn pow(rt: *Runtime, base: *const BigInt, exp: *const BigInt) Error!*const BigInt {
    if (exp.negative) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Exponent must be positive" }});
    }
    if (exp.limbs.len == 0) return fromU64(rt, 1); // 0n ** 0n === 1n
    if (base.limbs.len == 0) return zero(rt);

    if (base.limbs.len == 1 and base.limbs[0] == 1) {
        const res_neg = base.negative and ((exp.limbs[0] & 1) != 0);
        return rt.heap.newBigInt(res_neg, &.{1});
    }

    // |base| >= 2: result bit length is at least (bitLength(base) - 1) * exp + 1.
    if (exp.limbs.len > 1) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Maximum BigInt size exceeded" }});
    }
    const e_val = exp.limbs[0];
    const base_bits = bitLength(base.limbs);
    if (e_val > rt.limits.max_bigint_bits or (base_bits - 1) * e_val + 1 > rt.limits.max_bigint_bits) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Maximum BigInt size exceeded" }});
    }

    var res = try fromU64(rt, 1);
    var cur = base;
    var e = e_val;
    while (e > 0) {
        try rt.step();
        if ((e & 1) != 0) {
            res = try mul(rt, res, cur);
        }
        e >>= 1;
        if (e > 0) {
            cur = try mul(rt, cur, cur);
        }
    }
    return res;
}

// ---- Two's-complement bitwise operations

pub fn bitNot(rt: *Runtime, a: *const BigInt) Error!*const BigInt {
    // ~x === -(x + 1)
    const plus_one = try addI64(rt, a, 1);
    return neg(rt, plus_one);
}

const BitOp = enum { and_op, or_op, xor_op };

fn bitOp(rt: *Runtime, a: *const BigInt, b: *const BigInt, op: BitOp) Error!*const BigInt {
    const len = @max(a.limbs.len, b.limbs.len);
    if (len == 0) return zero(rt);

    const a_sign_ext: u64 = if (a.negative) std.math.maxInt(u64) else 0;
    const b_sign_ext: u64 = if (b.negative) std.math.maxInt(u64) else 0;
    const res_neg = switch (op) {
        .and_op => a.negative and b.negative,
        .or_op => a.negative or b.negative,
        .xor_op => a.negative != b.negative,
    };

    var out = try rt.gpa.alloc(u64, len + 1);
    defer rt.gpa.free(out);

    var a_carry: u128 = if (a.negative) 1 else 0;
    var b_carry: u128 = if (b.negative) 1 else 0;
    var res_carry: u128 = if (res_neg) 1 else 0;

    for (0..len) |i| {
        const av_tc: u64 = if (a.negative) blk: {
            const raw: u64 = if (i < a.limbs.len) a.limbs[i] else 0;
            const sum = @as(u128, ~raw) + a_carry;
            a_carry = sum >> 64;
            break :blk @truncate(sum);
        } else if (i < a.limbs.len) a.limbs[i] else 0;

        const bv_tc: u64 = if (b.negative) blk: {
            const raw: u64 = if (i < b.limbs.len) b.limbs[i] else 0;
            const sum = @as(u128, ~raw) + b_carry;
            b_carry = sum >> 64;
            break :blk @truncate(sum);
        } else if (i < b.limbs.len) b.limbs[i] else 0;

        const combined: u64 = switch (op) {
            .and_op => av_tc & bv_tc,
            .or_op => av_tc | bv_tc,
            .xor_op => av_tc ^ bv_tc,
        };

        if (res_neg) {
            const sum = @as(u128, ~combined) + res_carry;
            out[i] = @truncate(sum);
            res_carry = sum >> 64;
        } else {
            out[i] = combined;
        }
    }

    if (res_neg) {
        const hi_tc = switch (op) {
            .and_op => a_sign_ext & b_sign_ext,
            .or_op => a_sign_ext | b_sign_ext,
            .xor_op => a_sign_ext ^ b_sign_ext,
        };
        const sum = @as(u128, ~hi_tc) + res_carry;
        out[len] = @truncate(sum);
    } else {
        out[len] = 0;
    }

    return rt.heap.newBigInt(res_neg, out);
}

pub fn bitAnd(rt: *Runtime, a: *const BigInt, b: *const BigInt) Error!*const BigInt {
    return bitOp(rt, a, b, .and_op);
}

pub fn bitOr(rt: *Runtime, a: *const BigInt, b: *const BigInt) Error!*const BigInt {
    return bitOp(rt, a, b, .or_op);
}

pub fn bitXor(rt: *Runtime, a: *const BigInt, b: *const BigInt) Error!*const BigInt {
    return bitOp(rt, a, b, .xor_op);
}

fn shiftLeftAmt(rt: *Runtime, a: *const BigInt, shift: u64) Error!*const BigInt {
    if (a.limbs.len == 0 or shift == 0) return a;
    const bl = bitLength(a.limbs);
    if (shift > rt.limits.max_bigint_bits or bl + shift > rt.limits.max_bigint_bits) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Maximum BigInt size exceeded" }});
    }
    const limb_shift: usize = @intCast(shift / 64);
    const bit_shift: u6 = @intCast(shift % 64);
    const out_len = a.limbs.len + limb_shift + @as(usize, if (bit_shift > 0) 1 else 0);
    var out = try rt.gpa.alloc(u64, out_len);
    defer rt.gpa.free(out);
    @memset(out[0..limb_shift], 0);
    if (bit_shift == 0) {
        @memcpy(out[limb_shift .. limb_shift + a.limbs.len], a.limbs);
    } else {
        const inv_shift: u6 = @intCast(64 - @as(u7, bit_shift));
        var carry: u64 = 0;
        for (a.limbs, 0..) |limb, i| {
            out[limb_shift + i] = (limb << bit_shift) | carry;
            carry = limb >> inv_shift;
        }
        out[limb_shift + a.limbs.len] = carry;
    }
    return rt.heap.newBigInt(a.negative, out);
}

fn shiftRightAmt(rt: *Runtime, a: *const BigInt, shift: u64) Error!*const BigInt {
    if (a.limbs.len == 0 or shift == 0) return a;
    const bl = bitLength(a.limbs);
    if (shift >= bl) {
        return if (a.negative) fromI64(rt, -1) else zero(rt);
    }
    const limb_shift: usize = @intCast(shift / 64);
    const bit_shift: u6 = @intCast(shift % 64);
    const out_len = a.limbs.len - limb_shift;
    var out = try rt.gpa.alloc(u64, out_len + 1);
    defer rt.gpa.free(out);

    // Track whether any shifted-out bit is non-zero (for negative floor rounding).
    var had_rem = false;
    if (a.negative) {
        for (a.limbs[0..limb_shift]) |w| {
            if (w != 0) {
                had_rem = true;
                break;
            }
        }
        if (!had_rem and bit_shift > 0) {
            const mask = (@as(u64, 1) << bit_shift) - 1;
            if ((a.limbs[limb_shift] & mask) != 0) had_rem = true;
        }
    }

    if (bit_shift == 0) {
        @memcpy(out[0..out_len], a.limbs[limb_shift..]);
    } else {
        const inv_shift: u6 = @intCast(64 - @as(u7, bit_shift));
        for (0..out_len - 1) |i| {
            out[i] = (a.limbs[limb_shift + i] >> bit_shift) | (a.limbs[limb_shift + i + 1] << inv_shift);
        }
        out[out_len - 1] = a.limbs[a.limbs.len - 1] >> bit_shift;
    }
    out[out_len] = 0;

    if (had_rem) {
        var carry: u128 = 1;
        for (0..out_len + 1) |i| {
            const sum = @as(u128, out[i]) + carry;
            out[i] = @truncate(sum);
            carry = sum >> 64;
            if (carry == 0) break;
        }
    }
    return rt.heap.newBigInt(a.negative, out);
}

pub fn shl(rt: *Runtime, a: *const BigInt, shift_big: *const BigInt) Error!*const BigInt {
    if (a.limbs.len == 0) return a;
    if (shift_big.limbs.len == 0) return a;
    if (shift_big.limbs.len > 1) {
        if (shift_big.negative) {
            return if (a.negative) fromI64(rt, -1) else zero(rt);
        }
        return rt.throw(.RangeError, &.{.{ .ascii = "Maximum BigInt size exceeded" }});
    }
    const mag = shift_big.limbs[0];
    return if (shift_big.negative) shiftRightAmt(rt, a, mag) else shiftLeftAmt(rt, a, mag);
}

pub fn shr(rt: *Runtime, a: *const BigInt, shift_big: *const BigInt) Error!*const BigInt {
    if (a.limbs.len == 0) return a;
    if (shift_big.limbs.len == 0) return a;
    if (shift_big.limbs.len > 1) {
        if (shift_big.negative) {
            return rt.throw(.RangeError, &.{.{ .ascii = "Maximum BigInt size exceeded" }});
        }
        return if (a.negative) fromI64(rt, -1) else zero(rt);
    }
    const mag = shift_big.limbs[0];
    return if (shift_big.negative) shiftLeftAmt(rt, a, mag) else shiftRightAmt(rt, a, mag);
}

// ---- BigInt.asIntN / BigInt.asUintN

pub fn asUintN(rt: *Runtime, bits: u64, a: *const BigInt) Error!*const BigInt {
    if (bits == 0 or a.limbs.len == 0) return zero(rt);
    if (bits >= rt.limits.max_bigint_bits and !a.negative) {
        return a;
    }
    if (!a.negative) {
        const bl = bitLength(a.limbs);
        if (bl <= bits) return a;
        try checkBitLimit(rt, @intCast(bits));
        const full_limbs: usize = @intCast(bits / 64);
        const rem_bits: u6 = @intCast(bits % 64);
        const out_len = full_limbs + @as(usize, if (rem_bits > 0) 1 else 0);
        var out = try rt.gpa.alloc(u64, out_len);
        defer rt.gpa.free(out);
        @memcpy(out[0..full_limbs], a.limbs[0..full_limbs]);
        if (rem_bits > 0) {
            const mask = (@as(u64, 1) << rem_bits) - 1;
            out[full_limbs] = a.limbs[full_limbs] & mask;
        }
        return rt.heap.newBigInt(false, out);
    }

    // Negative: (2^bits + a) mod 2^bits = two's complement of `a` truncated to `bits`.
    if (bits > rt.limits.max_bigint_bits) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Maximum BigInt size exceeded" }});
    }
    const full_limbs: usize = @intCast(bits / 64);
    const rem_bits: u6 = @intCast(bits % 64);
    const out_len = full_limbs + @as(usize, if (rem_bits > 0) 1 else 0);
    var out = try rt.gpa.alloc(u64, out_len);
    defer rt.gpa.free(out);

    var carry: u128 = 1;
    for (0..out_len) |i| {
        const raw: u64 = if (i < a.limbs.len) a.limbs[i] else 0;
        const sum = @as(u128, ~raw) + carry;
        out[i] = @truncate(sum);
        carry = sum >> 64;
    }
    if (rem_bits > 0) {
        const mask = (@as(u64, 1) << rem_bits) - 1;
        out[full_limbs] &= mask;
    }
    return rt.heap.newBigInt(false, out);
}

pub fn asIntN(rt: *Runtime, bits: u64, a: *const BigInt) Error!*const BigInt {
    if (bits == 0 or a.limbs.len == 0) return zero(rt);
    const u = try asUintN(rt, bits, a);
    if (u.limbs.len == 0) return u;

    // Check sign bit (bit `bits - 1`).
    const sign_pos = bits - 1;
    const sign_limb: usize = @intCast(sign_pos / 64);
    if (sign_limb >= u.limbs.len) return u;
    const sign_bit = (u.limbs[sign_limb] >> @intCast(sign_pos % 64)) & 1;
    if (sign_bit == 0) return u;

    // Negative: result = u - 2^bits = -(2^bits - u).
    const full_limbs: usize = @intCast(bits / 64);
    const rem_bits: u6 = @intCast(bits % 64);
    const out_len = full_limbs + @as(usize, if (rem_bits > 0) 1 else 0);
    var out = try rt.gpa.alloc(u64, out_len);
    defer rt.gpa.free(out);

    var carry: u128 = 1;
    for (0..out_len) |i| {
        const raw: u64 = if (i < u.limbs.len) u.limbs[i] else 0;
        const sum = @as(u128, ~raw) + carry;
        out[i] = @truncate(sum);
        carry = sum >> 64;
    }
    if (rem_bits > 0) {
        const mask = (@as(u64, 1) << rem_bits) - 1;
        out[full_limbs] &= mask;
    }
    return rt.heap.newBigInt(true, out);
}

// ---- Parsing & formatting

fn digitVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'z' => c - 'a' + 10,
        'A'...'Z' => c - 'A' + 10,
        else => null,
    };
}

/// Parses a BigInt literal (already validated by lexer; `_` allowed) or a string
/// passed to `BigInt(str)` (JS whitespace trimmed, optional sign only for decimal, no `_`).
pub fn parse(rt: *Runtime, raw: []const u8, is_literal: bool) Error!*const BigInt {
    return (try tryParse(rt, raw, is_literal)) orelse
        rt.throw(.SyntaxError, &.{.{ .ascii = "Cannot convert string to a BigInt" }});
}

fn chunkCap(radix: u8) usize {
    return switch (radix) {
        2 => 63,
        8 => 21,
        10 => 19,
        16 => 15,
        else => unreachable,
    };
}

/// Like `parse`, but returns `null` instead of throwing `SyntaxError` on invalid syntax.
pub fn tryParse(rt: *Runtime, raw: []const u8, is_literal: bool) Error!?*const BigInt {
    var text = raw;
    var negative = false;
    var radix: u8 = 10;

    if (!is_literal) {
        text = std.mem.trim(u8, text, " \t\r\n\x0b\x0c");
        if (text.len == 0) return try zero(rt);
        if (text[0] == '+' or text[0] == '-') {
            negative = text[0] == '-';
            text = text[1..];
            if (text.len == 0) return null;
            // Node/ES spec: `BigInt("-0x10")` / `BigInt("+0x10")` is SyntaxError.
            if (text.len >= 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X' or text[1] == 'o' or text[1] == 'O' or text[1] == 'b' or text[1] == 'B')) {
                return null;
            }
        }
    }

    if (text.len >= 2 and text[0] == '0') {
        if (text[1] == 'x' or text[1] == 'X') {
            radix = 16;
            text = text[2..];
        } else if (text[1] == 'o' or text[1] == 'O') {
            radix = 8;
            text = text[2..];
        } else if (text[1] == 'b' or text[1] == 'B') {
            radix = 2;
            text = text[2..];
        }
    }
    if (text.len == 0) return null;

    var limbs = std.ArrayList(u64).empty;
    defer limbs.deinit(rt.gpa);

    const chunk_cap = chunkCap(radix);

    var chunk_val: u64 = 0;
    var chunk_mul: u64 = 1;
    var chunk_len: usize = 0;
    var saw_digit = false;

    for (text) |c| {
        if (c == '_') {
            if (!is_literal) return null;
            continue;
        }
        const d = digitVal(c) orelse return null;
        if (d >= radix) return null;
        saw_digit = true;

        chunk_val = chunk_val * radix + d;
        chunk_mul *= radix;
        chunk_len += 1;

        if (chunk_len == chunk_cap) {
            try mulAddLimb(rt, &limbs, chunk_mul, chunk_val);
            try checkBitLimit(rt, bitLength(limbs.items));
            chunk_val = 0;
            chunk_mul = 1;
            chunk_len = 0;
        }
    }

    if (!saw_digit) return null;
    if (chunk_len > 0) {
        try mulAddLimb(rt, &limbs, chunk_mul, chunk_val);
        try checkBitLimit(rt, bitLength(limbs.items));
    }

    return try rt.heap.newBigInt(negative, limbs.items);
}

/// Parses a validated BigInt literal directly onto `h` without a `Runtime` (used by compiler).
pub fn parseLiteralToHeap(h: *heap.Heap, gpa: std.mem.Allocator, max_bits: u32, raw: []const u8) error{ LimitExceeded, OutOfMemory }!*const BigInt {
    var text = raw;
    var radix: u8 = 10;
    if (text.len >= 2 and text[0] == '0') {
        if (text[1] == 'x' or text[1] == 'X') {
            radix = 16;
            text = text[2..];
        } else if (text[1] == 'o' or text[1] == 'O') {
            radix = 8;
            text = text[2..];
        } else if (text[1] == 'b' or text[1] == 'B') {
            radix = 2;
            text = text[2..];
        }
    }

    var limbs = std.ArrayList(u64).empty;
    defer limbs.deinit(gpa);

    const chunk_cap = chunkCap(radix);

    var chunk_val: u64 = 0;
    var chunk_mul: u64 = 1;
    var chunk_len: usize = 0;

    for (text) |c| {
        if (c == '_') continue;
        const d = digitVal(c).?;
        chunk_val = chunk_val * radix + d;
        chunk_mul *= radix;
        chunk_len += 1;

        if (chunk_len == chunk_cap) {
            try mulAddLimbRaw(gpa, &limbs, chunk_mul, chunk_val);
            if (bitLength(limbs.items) > max_bits) return error.LimitExceeded;
            chunk_val = 0;
            chunk_mul = 1;
            chunk_len = 0;
        }
    }

    if (chunk_len > 0) {
        try mulAddLimbRaw(gpa, &limbs, chunk_mul, chunk_val);
        if (bitLength(limbs.items) > max_bits) return error.LimitExceeded;
    }

    return h.newBigInt(false, limbs.items);
}

fn mulAddLimbRaw(gpa: std.mem.Allocator, limbs: *std.ArrayList(u64), mul_val: u64, add_val: u64) error{OutOfMemory}!void {
    var carry: u128 = add_val;
    for (limbs.items) |*l| {
        const prod = @as(u128, l.*) * @as(u128, mul_val) + carry;
        l.* = @truncate(prod);
        carry = prod >> 64;
    }
    if (carry != 0) {
        try limbs.append(gpa, @truncate(carry));
    }
}

fn throwSyntaxParse(rt: *Runtime, raw: []const u8) Error!*const BigInt {
    _ = raw;
    return rt.throw(.SyntaxError, &.{.{ .ascii = "Cannot convert string to a BigInt" }});
}

fn mulAddLimb(rt: *Runtime, limbs: *std.ArrayList(u64), mul_val: u64, add_val: u64) Error!void {
    try rt.step();
    var carry: u128 = add_val;
    for (limbs.items) |*l| {
        const prod = @as(u128, l.*) * @as(u128, mul_val) + carry;
        l.* = @truncate(prod);
        carry = prod >> 64;
    }
    if (carry != 0) {
        try limbs.append(rt.gpa, @truncate(carry));
    }
}

pub fn toString(rt: *Runtime, b: *const BigInt, radix: u8) Error![]u8 {
    if (radix < 2 or radix > 36) {
        return rt.throw(.RangeError, &.{.{ .ascii = "toString() radix argument must be between 2 and 36" }});
    }
    if (b.limbs.len == 0) {
        return rt.gpa.dupe(u8, "0");
    }

    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var rev = std.ArrayList(u8).empty;
    defer rev.deinit(rt.gpa);

    if (radix == 2 or radix == 4 or radix == 8 or radix == 16 or radix == 32) {
        const bits_per_digit: u6 = switch (radix) {
            2 => 1,
            4 => 2,
            8 => 3,
            16 => 4,
            32 => 5,
            else => unreachable,
        };
        const mask: u64 = (@as(u64, 1) << bits_per_digit) - 1;
        var bit_buf: u64 = 0;
        var bit_count: u6 = 0;

        for (b.limbs, 0..) |limb, idx| {
            const is_last = idx + 1 == b.limbs.len;
            var rem_bits: u7 = 64;
            var w = limb;
            if (bit_count > 0) {
                const need: u6 = bits_per_digit - bit_count;
                bit_buf |= (w & ((@as(u64, 1) << need) - 1)) << bit_count;
                try rev.append(rt.gpa, digits[@intCast(bit_buf & mask)]);
                w >>= need;
                rem_bits -= need;
                bit_buf = 0;
                bit_count = 0;
            }
            while (rem_bits >= bits_per_digit) {
                if (is_last and w == 0) break;
                try rev.append(rt.gpa, digits[@intCast(w & mask)]);
                w >>= bits_per_digit;
                rem_bits -= bits_per_digit;
            }
            if (rem_bits > 0 and (!is_last or w != 0)) {
                bit_buf = w;
                bit_count = @intCast(rem_bits);
            }
        }
        if (bit_count > 0 and bit_buf != 0) {
            try rev.append(rt.gpa, digits[@intCast(bit_buf & mask)]);
        }
    } else {
        // Chunked division by largest power of `radix` fitting in `u64`.
        var chunk_base: u64 = 1;
        var chunk_digits: usize = 0;
        while (true) {
            const next = std.math.mul(u64, chunk_base, radix) catch break;
            chunk_base = next;
            chunk_digits += 1;
        }

        var work = try rt.gpa.dupe(u64, b.limbs);
        defer rt.gpa.free(work);
        var len = work.len;

        while (len > 0) {
            try rt.step();
            var rem: u128 = 0;
            var i = len;
            while (i > 0) {
                i -= 1;
                const cur = (rem << 64) | work[i];
                work[i] = @truncate(cur / chunk_base);
                rem = cur % chunk_base;
            }
            while (len > 0 and work[len - 1] == 0) : (len -= 1) {}

            var chunk_val: u64 = @truncate(rem);
            if (len > 0) {
                for (0..chunk_digits) |_| {
                    try rev.append(rt.gpa, digits[@intCast(chunk_val % radix)]);
                    chunk_val /= radix;
                }
            } else {
                while (chunk_val > 0) {
                    try rev.append(rt.gpa, digits[@intCast(chunk_val % radix)]);
                    chunk_val /= radix;
                }
            }
        }
    }

    if (b.negative) try rev.append(rt.gpa, '-');
    std.mem.reverse(u8, rev.items);
    return rev.toOwnedSlice(rt.gpa);
}

// ---- Unit tests

const testing = std.testing;

test "BigInt arithmetic, Knuth D division, toF64, and max_bigint_bits" {
    var out_buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out_buf.deinit();
    var rt = Runtime.init(testing.allocator, .{ .max_bigint_bits = 1024 }, &out_buf.writer);
    defer rt.deinit();

    // Multi-limb Knuth D division: (2^192 + 12345) / (2^128 + 7)
    const a = try parse(&rt, "6277101735386680763835789423207666416102355444464034525241", true);
    const b = try parse(&rt, "340282366920938463463374607431768211463", true);
    const dr = try divRem(&rt, a, b);
    const q_str = try toString(&rt, dr.quot, 10);
    defer rt.gpa.free(q_str);
    const r_str = try toString(&rt, dr.rem, 10);
    defer rt.gpa.free(r_str);

    // Check q * b + r == a
    const qb = try mul(&rt, dr.quot, b);
    const check = try add(&rt, qb, dr.rem);
    try testing.expectEqual(std.math.Order.eq, cmp(check, a));
    try testing.expectEqual(std.math.Order.lt, cmp(dr.rem, b));

    // toF64 round-half-to-even boundaries around 2^53
    const two53 = try parse(&rt, "9007199254740992", true);
    const two53_p1 = try parse(&rt, "9007199254740993", true);
    const two53_p2 = try parse(&rt, "9007199254740994", true);
    const two53_p3 = try parse(&rt, "9007199254740995", true);
    try testing.expectEqual(@as(f64, 9007199254740992.0), toF64(two53));
    try testing.expectEqual(@as(f64, 9007199254740992.0), toF64(two53_p1)); // ties to even
    try testing.expectEqual(@as(f64, 9007199254740994.0), toF64(two53_p2));
    try testing.expectEqual(@as(f64, 9007199254740996.0), toF64(two53_p3)); // ties to even

    // Exact cmpNumber without precision loss
    try testing.expectEqual(std.math.Order.gt, cmpNumber(two53_p1, 9007199254740992.0).?);
    try testing.expect(cmpNumber(two53_p1, std.math.nan(f64)) == null);

    // max_bigint_bits overflow protection
    const one = try fromU64(&rt, 1);
    const big_shift = try fromU64(&rt, 2000);
    try testing.expectError(error.Thrown, shl(&rt, one, big_shift));
}
