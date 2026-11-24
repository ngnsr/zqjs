//! JavaScript values (DESIGN_DECISIONS D5, M55 D85): 8-byte NaN-boxed representation.
//!
//! IEEE-754 doubles occupy all bit patterns `< TAG_BASE` (`0xFFF8_0000_0000_0000`), with
//! NaN values canonicalized to positive quiet NaN (`0x7FF8_0000_0000_0000`). Negative
//! quiet-NaN space (`0xFFF8..0xFFFF`) carries a 3-bit tag in bits 48..50 and a 48-bit
//! payload (immediates or canonical 48-bit pointers) in bits 0..47.

const std = @import("std");
const heap = @import("heap.zig");
const Runtime = @import("runtime.zig").Runtime;
const Error = @import("runtime.zig").Error;

pub const Value = packed struct(u64) {
    bits: u64,

    // ---- bit layout constants
    pub const TAG_BASE: u64 = 0xFFF8_0000_0000_0000;
    pub const TAG_MASK: u64 = 0xFFFF_0000_0000_0000;
    pub const PAYLOAD_MASK: u64 = 0x0000_FFFF_FFFF_FFFF;

    const CANON_NAN_BITS: u64 = 0x7FF8_0000_0000_0000;
    const TAG_IMM: u64 = 0xFFF8_0000_0000_0000;
    const TAG_OBJECT: u64 = 0xFFF9_0000_0000_0000;
    const TAG_STRING: u64 = 0xFFFA_0000_0000_0000;
    const TAG_CLOSURE: u64 = 0xFFFB_0000_0000_0000;
    const TAG_SYMBOL: u64 = 0xFFFC_0000_0000_0000;
    const TAG_BIGINT: u64 = 0xFFFD_0000_0000_0000;
    const TAG_NATIVE: u64 = 0xFFFE_0000_0000_0000;
    /// Internal sentinel tag for `Vm.Slot` cell pointers (never a JS Value).
    pub const TAG_CELL: u64 = 0xFFFF_0000_0000_0000;

    const UNDEFINED_BITS: u64 = TAG_IMM | 0;
    const NULL_BITS: u64 = TAG_IMM | 1;
    const FALSE_BITS: u64 = TAG_IMM | 2;
    const TRUE_BITS: u64 = TAG_IMM | 3;
    /// Internal sentinel for uninitialized/TDZ slots (never a JS Value).
    pub const UNINIT_BITS: u64 = TAG_IMM | 4;
    /// Internal sentinel for sparse array holes (never exposed to JS).
    pub const HOLE_BITS: u64 = TAG_IMM | 5;
    /// Internal sentinel for missing `this` in `Vm.Frame` (never a JS Value).
    pub const NO_THIS_BITS: u64 = TAG_IMM | 6;

    pub const @"undefined": Value = .{ .bits = UNDEFINED_BITS };
    pub const @"null": Value = .{ .bits = NULL_BITS };
    pub const undefined_val: Value = @"undefined";
    pub const null_val: Value = @"null";
    pub const false_val: Value = .{ .bits = FALSE_BITS };
    pub const true_val: Value = .{ .bits = TRUE_BITS };
    pub const hole: Value = .{ .bits = HOLE_BITS };

    pub const Tag = enum(u8) {
        undefined,
        null,
        boolean,
        number,
        bigint,
        string,
        symbol,
        native,
        closure,
        object,
    };

    pub const Unpacked = union(Tag) {
        undefined,
        null,
        boolean: bool,
        number: f64,
        bigint: *const heap.BigInt,
        string: *const heap.String,
        symbol: *const heap.Symbol,
        native: *const Native,
        closure: *const heap.Closure,
        object: *heap.Object,
    };

    // ---- constructors
    pub inline fn fromBool(b: bool) Value {
        return .{ .bits = FALSE_BITS | @as(u64, @intFromBool(b)) };
    }

    pub inline fn fromNumber(n: f64) Value {
        if (std.math.isNan(n)) return .{ .bits = CANON_NAN_BITS };
        return .{ .bits = @bitCast(n) };
    }

    inline fn fromPtr(comptime tag_bits: u64, ptr: anytype) Value {
        const addr: u64 = @intFromPtr(ptr);
        std.debug.assert((addr & ~PAYLOAD_MASK) == 0);
        return .{ .bits = tag_bits | addr };
    }

    inline fn asPtr(v: Value, comptime T: type, comptime tag_bits: u64) T {
        std.debug.assert((v.bits & TAG_MASK) == tag_bits);
        return @ptrFromInt(@as(usize, @truncate(v.bits & PAYLOAD_MASK)));
    }

    pub inline fn fromObject(o: *heap.Object) Value {
        return fromPtr(TAG_OBJECT, o);
    }

    pub inline fn fromString(s: *const heap.String) Value {
        return fromPtr(TAG_STRING, s);
    }

    pub inline fn fromClosure(c: *const heap.Closure) Value {
        return fromPtr(TAG_CLOSURE, c);
    }

    pub inline fn fromSymbol(s: *const heap.Symbol) Value {
        return fromPtr(TAG_SYMBOL, s);
    }

    pub inline fn fromBigInt(b: *const heap.BigInt) Value {
        return fromPtr(TAG_BIGINT, b);
    }

    pub inline fn fromNative(n: *const Native) Value {
        return fromPtr(TAG_NATIVE, n);
    }

    // ---- fast predicates
    pub inline fn isUndefined(v: Value) bool {
        return v.bits == UNDEFINED_BITS;
    }

    pub inline fn isHole(v: Value) bool {
        return v.bits == HOLE_BITS;
    }

    pub inline fn unwrapHole(v: Value) Value {
        return if (v.bits == HOLE_BITS) .undefined else v;
    }

    pub inline fn isNull(v: Value) bool {
        return v.bits == NULL_BITS;
    }

    pub inline fn isNullish(v: Value) bool {
        return (v.bits & ~@as(u64, 1)) == UNDEFINED_BITS;
    }

    pub inline fn isBool(v: Value) bool {
        return (v.bits & ~@as(u64, 1)) == FALSE_BITS;
    }

    pub inline fn isNumber(v: Value) bool {
        return v.bits < TAG_BASE;
    }

    pub inline fn isObject(v: Value) bool {
        return (v.bits & TAG_MASK) == TAG_OBJECT;
    }

    pub inline fn isString(v: Value) bool {
        return (v.bits & TAG_MASK) == TAG_STRING;
    }

    pub inline fn isClosure(v: Value) bool {
        return (v.bits & TAG_MASK) == TAG_CLOSURE;
    }

    pub inline fn isSymbol(v: Value) bool {
        return (v.bits & TAG_MASK) == TAG_SYMBOL;
    }

    pub inline fn isBigInt(v: Value) bool {
        return (v.bits & TAG_MASK) == TAG_BIGINT;
    }

    pub inline fn isNative(v: Value) bool {
        return (v.bits & TAG_MASK) == TAG_NATIVE;
    }

    /// True for GC-managed heap objects (`object`, `string`, `closure`, `symbol`, `bigint`).
    pub inline fn isHeapObj(v: Value) bool {
        return v.bits >= TAG_OBJECT and v.bits < TAG_NATIVE;
    }

    pub inline fn asHeapObj(v: Value) *heap.Obj {
        std.debug.assert(v.isHeapObj());
        return @ptrFromInt(@as(usize, @truncate(v.bits & PAYLOAD_MASK)));
    }

    // ---- fast extractors
    pub inline fn asBool(v: Value) bool {
        std.debug.assert(v.isBool());
        return (v.bits & 1) != 0;
    }

    pub inline fn asNumber(v: Value) f64 {
        std.debug.assert(v.isNumber());
        return @bitCast(v.bits);
    }

    pub inline fn asObject(v: Value) *heap.Object {
        return v.asPtr(*heap.Object, TAG_OBJECT);
    }

    pub inline fn asString(v: Value) *const heap.String {
        return v.asPtr(*const heap.String, TAG_STRING);
    }

    pub inline fn asClosure(v: Value) *const heap.Closure {
        return v.asPtr(*const heap.Closure, TAG_CLOSURE);
    }

    pub inline fn asSymbol(v: Value) *const heap.Symbol {
        return v.asPtr(*const heap.Symbol, TAG_SYMBOL);
    }

    pub inline fn asBigInt(v: Value) *const heap.BigInt {
        return v.asPtr(*const heap.BigInt, TAG_BIGINT);
    }

    pub inline fn asNative(v: Value) *const Native {
        return v.asPtr(*const Native, TAG_NATIVE);
    }

    pub inline fn tag(v: Value) Tag {
        if (v.bits < TAG_BASE) return .number;
        return switch (v.bits & TAG_MASK) {
            TAG_IMM => switch (v.bits) {
                UNDEFINED_BITS => .undefined,
                NULL_BITS => .null,
                FALSE_BITS, TRUE_BITS => .boolean,
                else => unreachable,
            },
            TAG_OBJECT => .object,
            TAG_STRING => .string,
            TAG_CLOSURE => .closure,
            TAG_SYMBOL => .symbol,
            TAG_BIGINT => .bigint,
            TAG_NATIVE => .native,
            else => unreachable,
        };
    }

    pub inline fn unpack(v: Value) Unpacked {
        if (v.bits < TAG_BASE) return .{ .number = @bitCast(v.bits) };
        return switch (v.bits & TAG_MASK) {
            TAG_IMM => switch (v.bits) {
                UNDEFINED_BITS => .undefined,
                NULL_BITS => .null,
                FALSE_BITS => .{ .boolean = false },
                TRUE_BITS => .{ .boolean = true },
                else => unreachable,
            },
            TAG_OBJECT => .{ .object = v.asObject() },
            TAG_STRING => .{ .string = v.asString() },
            TAG_CLOSURE => .{ .closure = v.asClosure() },
            TAG_SYMBOL => .{ .symbol = v.asSymbol() },
            TAG_BIGINT => .{ .bigint = v.asBigInt() },
            TAG_NATIVE => .{ .native = v.asNative() },
            else => unreachable,
        };
    }

    pub inline fn isFunction(v: Value) bool {
        return v.isNative() or v.isClosure() or (v.isObject() and v.asObject().kind == .proxy and v.asObject().kind.proxy.is_callable);
    }

    pub inline fn isObjectLike(v: Value) bool {
        return v.isObject() or v.isClosure() or v.isNative();
    }
};

comptime {
    std.debug.assert(@sizeOf(Value) == 8);
}

/// A host native's internal callback (M9.1, D53): implemented in `src/api.zig`, which
/// mints the temporary argument tokens, pushes the native-call record, calls the host's
/// `NativeFn`, and copies the result out before releasing the tokens (D50).
pub const HostCallFn = fn (rt: *Runtime, ctx: ?*anyopaque, this: ?Value, args: []const Value) Error!Value;

pub const Native = struct {
    name: []const u8,
    length: u16 = 0,
    /// `this` is the call's receiver (`.undefined` for a plain call); `args` is a temporary
    /// slice owned by the caller, valid only during the call. A built-in native never calls
    /// back into JS (M7: conversions that would need to are Unsupported, D40).
    call: *const fn (rt: *Runtime, this: Value, args: []const Value) Error!Value,
    /// Set for host-registered globals (`defineGlobalFunction`, M9.1 D53): called instead
    /// of `call`, with `ctx` borrowed from the host until `Runtime.destroy`.
    host: ?struct {
        call: *const HostCallFn,
        ctx: ?*anyopaque,
    } = null,
    /// For built-in constructors (`Map`, `Set`): called by `new` instead of `call`.
    construct: ?*const fn (rt: *Runtime, args: []const Value) Error!Value = null,
    /// For the namespace globals (`Object`, `Array`, ..., `Error`, ...): where their static members live.
    namespace: ?enum {
        object,
        array,
        string,
        number,
        boolean,
        bigint,
        function,
        map,
        set,
        weak_map,
        weak_set,
        iterator,
        proxy,
        promise,
        @"error",
        type_error,
        range_error,
        syntax_error,
        reference_error,
        eval_error,
        uri_error,
        aggregate_error,
        regexp,
        date,
        symbol,
        array_buffer,
        data_view,
        typed_array,
        int8_array,
        uint8_array,
        uint8_clamped_array,
        int16_array,
        uint16_array,
        int32_array,
        uint32_array,
        float32_array,
        float64_array,
        bigint64_array,
        biguint64_array,
    } = null,
};

test "M55: 8-byte NaN-boxed Value preserves -0, NaN canonicalization, infinities, subnormals, and tags" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Value));

    // Immediates
    try std.testing.expect(Value.undefined_val.isUndefined());
    try std.testing.expect(Value.undefined_val.isNullish());
    try std.testing.expect(Value.null_val.isNull());
    try std.testing.expect(Value.null_val.isNullish());
    try std.testing.expect(Value.fromBool(true).isBool() and Value.fromBool(true).asBool());
    try std.testing.expect(Value.fromBool(false).isBool() and !Value.fromBool(false).asBool());

    // Numbers: +0, -0, ±Inf, subnormals, max/min
    const neg_zero = Value.fromNumber(-0.0);
    try std.testing.expect(neg_zero.isNumber());
    try std.testing.expect(std.math.signbit(neg_zero.asNumber()));
    const pos_zero = Value.fromNumber(0.0);
    try std.testing.expect(!std.math.signbit(pos_zero.asNumber()));
    try std.testing.expect(Value.fromNumber(std.math.inf(f64)).isNumber());
    try std.testing.expect(Value.fromNumber(-std.math.inf(f64)).isNumber());
    try std.testing.expectEqual(-std.math.inf(f64), Value.fromNumber(-std.math.inf(f64)).asNumber());
    try std.testing.expectEqual(std.math.floatTrueMin(f64), Value.fromNumber(std.math.floatTrueMin(f64)).asNumber());

    // Negative / custom payload NaNs canonicalize and never collide with tagged values
    const neg_nan: f64 = @bitCast(@as(u64, 0xFFFF_DEAD_BEEF_CAFE));
    const boxed_nan = Value.fromNumber(neg_nan);
    try std.testing.expect(boxed_nan.isNumber());
    try std.testing.expect(std.math.isNan(boxed_nan.asNumber()));
    try std.testing.expect(!boxed_nan.isObject());
    try std.testing.expect(!boxed_nan.isHeapObj());
    try std.testing.expectEqual(Value.fromNumber(std.math.nan(f64)).bits, boxed_nan.bits);
}
