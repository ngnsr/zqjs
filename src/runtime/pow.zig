//! Double-precision x^y: a port of musl's pow (ARM optimized-routines, 2018), as
//! bundled with Zig 0.17.1 at lib/libc/musl/src/math/pow.c.
//! Copyright (c) 2018, Arm Limited. SPDX-License-Identifier: MIT
//!
//! Why not std.math.pow: it is ported from Go's math.Pow, which builds the result from
//! frexp and repeated squaring; errors accumulate (up to ~80 ulp in our node tests).
//!
//! Method: x^y = exp(y * log(x)), with log(x) computed to ~68 bits (a double `hi` plus
//! a correction `lo`) and exp taking that extra precision as an input "tail", so the
//! only significant rounding is the final one. Documented worst case: 0.54 ulp.
//!
//!   log:  x = 2^k * z, z near 1; log(x) = k*ln2 + log(c) + log1p(z/c - 1), where c is
//!         a table point near z (128 entries) and log1p is a degree-8 polynomial.
//!   exp:  x = k*ln2/N + r, |r| <= ln2/2N; exp(x) = 2^(k/N) * exp(r), with 2^(k/N)
//!         from a 128-entry table and exp(r) from a degree-5 polynomial.
//!
//! This port uses musl's *non-FMA* code path everywhere, so results are identical on
//! every CPU (the FMA path is 0.02 ulp more accurate but would depend on hardware).
//! C's unsigned wraparound is spelled out with Zig's wrapping operators (-% +% *%).
//!
//! JS semantics differ from C pow in two places (`1 ** NaN` and `(±1) ** ±Infinity`
//! are NaN in JS, 1 in C); ops.pow handles those before calling `pow` here.

const std = @import("std");
const data = @import("pow_data.zig");

inline fn bits(x: f64) u64 {
    return @bitCast(x);
}

inline fn double(b: u64) f64 {
    return @bitCast(b);
}

/// Top 12 bits of a double: sign and exponent.
inline fn top12(x: f64) u32 {
    return @intCast(bits(x) >> 52);
}

const log_n = 1 << data.log_table_bits;
const exp_n = 1 << data.exp_table_bits;
const off: u64 = 0x3fe6955500000000;

/// log(x) as hi + tail, where tail carries ~15 extra bits. `ix` is the bit pattern of
/// x, normalised for subnormals (the exponent may borrow from the sign bit).
fn logInline(ix: u64, tail: *f64) f64 {
    // x = 2^k z, with z in [off, 2*off) and exact. The range is split into N
    // subintervals; the ith contains z, and c is near its centre.
    const tmp = ix -% off;
    const i: usize = @intCast((tmp >> (52 - data.log_table_bits)) % log_n);
    const k: i64 = @as(i64, @bitCast(tmp)) >> 52; // arithmetic shift
    const iz = ix -% (tmp & (@as(u64, 0xfff) << 52));
    const z = double(iz);
    const kd: f64 = @floatFromInt(k);

    // log(x) = k*Ln2 + log(c) + log1p(z/c - 1).
    const entry = data.log_tab[i];
    const invc = entry.invc;
    const logc = entry.logc;
    const logctail = entry.logctail;

    // r = z/c - 1 is exact. Split z so that rhi, rlo and rhi*rhi are exact.
    const zhi = double((iz +% (@as(u64, 1) << 31)) & 0xffffffff00000000);
    const zlo = z - zhi;
    const rhi = zhi * invc - 1.0;
    const rlo = zlo * invc;
    const r = rhi + rlo;

    // k*Ln2 + log(c) + r.
    const t1 = kd * data.ln2hi + logc;
    const t2 = t1 + r;
    const lo1 = kd * data.ln2lo + logctail;
    const lo2 = t1 - t2 + r;

    // + A[0]*r*r, keeping the rounding error of each step.
    const A = data.log_poly;
    const ar = A[0] * r; // A[0] = -0.5
    const ar2 = r * ar;
    const ar3 = r * ar2;
    const arhi = A[0] * rhi;
    const arhi2 = rhi * arhi;
    const hi = t2 + arhi2;
    const lo3 = rlo * (ar + arhi);
    const lo4 = t2 - hi + arhi2;

    // p = log1p(r) - r - A[0]*r*r.
    const p = ar3 * (A[1] + r * A[2] + ar2 * (A[3] + r * A[4] + ar2 * (A[5] + r * A[6])));
    const lo = lo1 + lo2 + lo3 + lo4 + p;
    const y = hi + lo;
    tail.* = hi - y + lo;
    return y;
}

/// The result scale*(1 + tmp) when it may overflow or underflow. `sbits` is the bit
/// pattern of scale, whose exponent may have wrapped into the sign bit; `ki` is the
/// reduction's k (its sign tells overflow from underflow).
fn specialCase(tmp: f64, sbits_in: u64, ki: u64) f64 {
    var sbits = sbits_in;
    if (ki & 0x80000000 == 0) {
        // k > 0: the exponent of scale might have overflowed by <= 460.
        sbits -%= @as(u64, 1009) << 52;
        const scale = double(sbits);
        return 0x1p1009 * (scale + scale * tmp);
    }
    // k < 0: take care in the subnormal range.
    sbits +%= @as(u64, 1022) << 52;
    const scale = double(sbits); // signed scale
    var y = scale + scale * tmp;
    if (@abs(y) < 1.0) {
        // Round y to the right precision before scaling into the subnormal range,
        // to avoid double rounding.
        const one: f64 = if (y < 0.0) -1.0 else 1.0;
        var lo = scale - y + scale * tmp;
        const hi = one + y;
        lo = one - hi + y + lo;
        y = (hi + lo) - one;
        if (y == 0.0) y = double(sbits & 0x8000000000000000); // sign of zero
    }
    return 0x1p-1022 * y;
}

const sign_bias: u64 = 0x800 << data.exp_table_bits;

/// sign * exp(x + xtail), where |xtail| < 2^-8/N and |xtail| <= |x|.
fn expInline(x: f64, xtail: f64, bias: u64) f64 {
    var abstop = top12(x) & 0x7ff;
    if (abstop -% top12(0x1p-54) >= top12(512.0) -% top12(0x1p-54)) {
        if (abstop -% top12(0x1p-54) >= 0x80000000) {
            // Tiny x: exp(x) rounds to 1 (avoids spurious underflow).
            const one = 1.0 + x;
            return if (bias != 0) -one else one;
        }
        if (abstop >= top12(1024.0)) {
            // inf and nan were handled by the caller.
            const huge: f64 = if (bits(x) >> 63 != 0) 0.0 else std.math.inf(f64);
            return if (bias != 0) -huge else huge;
        }
        abstop = 0; // large x: handled by specialCase below
    }

    // exp(x) = 2^(k/N) * exp(r), x = ln2/N*k + r, r in [-ln2/2N, ln2/2N].
    const z = data.invln2N * x;
    // Round z to an integer with the shift trick: kd's low bits hold k.
    var kd = z + data.shift;
    const ki = bits(kd);
    kd -= data.shift;
    var r = x + kd * data.negln2hiN + kd * data.negln2loN;
    r += xtail;
    // 2^(k/N) ~= scale * (1 + tail).
    const idx: usize = @intCast(2 * (ki % exp_n));
    const top = (ki +% bias) << (52 - data.exp_table_bits);
    const tail = double(data.exp_tab[idx]);
    const sbits = data.exp_tab[idx + 1] +% top; // valid scale only when -1023*N < k < 1024*N
    // exp(x) = 2^(k/N) * exp(r) ~= scale + scale * (tail + exp(r) - 1).
    const C = data.exp_poly;
    const r2 = r * r;
    const tmp = tail + r + r2 * (C[0] + r * C[1]) + r2 * r2 * (C[2] + r * C[3]);
    if (abstop == 0) return specialCase(tmp, sbits, ki);
    const scale = double(sbits);
    return scale + scale * tmp;
}

/// For the bit pattern of a non-zero finite double: 0 if not an integer,
/// 1 if an odd integer, 2 if an even integer.
fn checkInt(iy: u64) u2 {
    const e: u32 = @intCast(iy >> 52 & 0x7ff);
    if (e < 0x3ff) return 0;
    if (e > 0x3ff + 52) return 2;
    const shift: u6 = @intCast(0x3ff + 52 - e);
    if (iy & ((@as(u64, 1) << shift) - 1) != 0) return 0;
    if (iy & (@as(u64, 1) << shift) != 0) return 1;
    return 2;
}

/// True for the bit pattern of 0, infinity or NaN (of either sign).
fn zeroInfNan(i: u64) bool {
    return (i *% 2) -% 1 >= (bits(std.math.inf(f64)) *% 2) -% 1;
}

/// C pow semantics (IEEE 754 / C99 Annex F), with at most 0.54 ulp error.
pub fn pow(x: f64, y: f64) f64 {
    var bias: u64 = 0;
    var ix = bits(x);
    const iy = bits(y);
    var topx = top12(x);
    const topy = top12(y);
    const inf_bits = bits(std.math.inf(f64));
    const one_bits = bits(@as(f64, 1.0));

    // Special cases: x subnormal, zero, inf or nan, or negative;
    // or |y| < 2^-65, |y| >= 2^63, or y nan.
    if (topx -% 0x001 >= 0x7ff - 0x001 or (topy & 0x7ff) -% 0x3be >= 0x43e - 0x3be) {
        if (zeroInfNan(iy)) {
            if (iy *% 2 == 0) return 1.0;
            if (ix == one_bits) return 1.0;
            if (ix *% 2 > inf_bits *% 2 or iy *% 2 > inf_bits *% 2) return x + y; // nan
            if (ix *% 2 == one_bits *% 2) return 1.0;
            if ((ix *% 2 < one_bits *% 2) == (iy >> 63 == 0)) return 0.0; // |x|<1 && y==inf or |x|>1 && y==-inf
            return y * y;
        }
        if (zeroInfNan(ix)) {
            var x2 = x * x;
            if (ix >> 63 != 0 and checkInt(iy) == 1) x2 = -x2;
            return if (iy >> 63 != 0) 1 / x2 else x2;
        }
        // Here x and y are non-zero finite.
        if (ix >> 63 != 0) {
            // Finite x < 0.
            const yint = checkInt(iy);
            if (yint == 0) return std.math.nan(f64);
            if (yint == 1) bias = sign_bias;
            ix &= 0x7fffffffffffffff;
            topx &= 0x7ff;
        }
        if ((topy & 0x7ff) -% 0x3be >= 0x43e - 0x3be) {
            // bias == 0 here because y is not odd.
            if (ix == one_bits) return 1.0;
            if ((topy & 0x7ff) < 0x3be) {
                // |y| < 2^-65: x^y ~= 1 + y*log(x).
                return if (ix > one_bits) 1.0 + y else 1.0 - y;
            }
            const overflow = (ix > one_bits) == (topy < 0x800);
            return if (overflow) std.math.inf(f64) else 0.0;
        }
        if (topx == 0) {
            // Normalise subnormal x so its exponent becomes negative.
            ix = bits(x * 0x1p52);
            ix &= 0x7fffffffffffffff;
            ix -%= @as(u64, 52) << 52;
        }
    }

    var lo: f64 = undefined;
    const hi = logInline(ix, &lo);
    // y * (hi + lo), split so the products are exact.
    const yhi = double(iy & (~@as(u64, 0) << 27));
    const ylo = y - yhi;
    const lhi = double(bits(hi) & (~@as(u64, 0) << 27));
    const llo = hi - lhi + lo;
    const ehi = yhi * lhi;
    const elo = ylo * lhi + y * llo; // |elo| < |ehi| * 2^-25
    return expInline(ehi, elo, bias);
}

test "C pow special cases" {
    const inf = std.math.inf(f64);
    try std.testing.expectEqual(@as(f64, 1), pow(std.math.nan(f64), 0));
    try std.testing.expectEqual(@as(f64, 1), pow(1, std.math.nan(f64))); // C says 1; JS wrapper says NaN
    try std.testing.expect(std.math.isNan(pow(-8, 1.0 / 3.0)));
    try std.testing.expectEqual(-inf, pow(-0.0, -3));
    try std.testing.expectEqual(inf, pow(-0.0, -2));
    try std.testing.expect(std.math.signbit(pow(-0.0, 3)));
    try std.testing.expectEqual(@as(f64, 1024), pow(2, 10));
    try std.testing.expectEqual(@as(f64, 0.5), pow(4, -0.5));
    try std.testing.expectEqual(inf, pow(10, 400));
    try std.testing.expectEqual(@as(f64, 0), pow(10, -400));
    try std.testing.expectEqual(@as(f64, 5e-324), pow(2, -1074)); // smallest subnormal
}
