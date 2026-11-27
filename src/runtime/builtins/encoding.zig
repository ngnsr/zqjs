//! Zero-I/O WHATWG Encoding & Base64 globals:
//! `btoa`, `atob`, `TextEncoder`, and `TextDecoder`.

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
const builtins = @import("../builtins.zig");
const common = @import("common.zig");

const b64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

const b64_decode_table: [128]u8 = blk: {
    var t: [128]u8 = @splat(0xFF);
    for (b64_alphabet, 0..) |ch, i| {
        t[ch] = @intCast(i);
    }
    break :blk t;
};

/// Packed WHATWG UTF-8 decoder state stored losslessly as a 32-bit integer inside
/// `Realm.text_decoders` (`WeakMap`) so `heap.Object` size stays unchanged.
const DecoderState = packed struct(u32) {
    fatal: bool = false,
    ignore_bom: bool = false,
    bom_seen: bool = false,
    bytes_needed: u2 = 0,
    bytes_seen: u2 = 0,
    /// 0 => 0x80, 1 => 0xA0 (0xE0 lead), 2 => 0x90 (0xF0 lead)
    lower_mode: u2 = 0,
    /// 0 => 0xBF, 1 => 0x9F (0xED lead), 2 => 0x8F (0xF4 lead)
    upper_mode: u2 = 0,
    code_point: u21 = 0,

    fn lowerBound(self: DecoderState) u8 {
        return switch (self.lower_mode) {
            0 => 0x80,
            1 => 0xA0,
            2 => 0x90,
            else => 0x80,
        };
    }

    fn upperBound(self: DecoderState) u8 {
        return switch (self.upper_mode) {
            0 => 0xBF,
            1 => 0x9F,
            2 => 0x8F,
            else => 0xBF,
        };
    }

    fn resetSequence(self: *DecoderState) void {
        self.bytes_needed = 0;
        self.bytes_seen = 0;
        self.lower_mode = 0;
        self.upper_mode = 0;
        self.code_point = 0;
    }

    fn resetStream(self: *DecoderState) void {
        self.resetSequence();
        self.bom_seen = false;
    }

    fn toValue(self: DecoderState) Value {
        const raw: u32 = @bitCast(self);
        return Value.fromNumber(@floatFromInt(raw));
    }

    fn fromValue(v: Value) DecoderState {
        const raw: u32 = @intFromFloat(v.asNumber());
        return @bitCast(raw);
    }
};

fn isAsciiWhitespace(u: u16) bool {
    return u == 0x09 or u == 0x0A or u == 0x0C or u == 0x0D or u == 0x20;
}

fn throwInvalidCharacterError(rt: *Runtime, msg: []const u8) Error {
    const r = try builtins.realm(rt);
    var root_buf = [_]Value{ .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const err_obj = try rt.heap.newObject(r.error_prototype);
    err_obj.ordinary_tag = .@"error";
    root_buf[0] = Value.fromObject(err_obj);

    const name_str = try rt.heap.internAscii("InvalidCharacterError");
    root_buf[1] = Value.fromString(name_str);
    try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("name"), .{ .value = root_buf[1], .enumerable = false });

    const msg_str = try rt.heap.ascii(msg);
    root_buf[1] = Value.fromString(msg_str);
    try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("message"), .{ .value = root_buf[1], .enumerable = false });

    try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("code"), .{ .value = Value.fromNumber(5), .enumerable = false });

    return rt.throwValue(root_buf[0]);
}

fn defineEnumerableMethod(rt: *Runtime, o: *Object, name: []const u8, n: *const Native) Error!void {
    const k = try rt.heap.internAscii(name);
    try rt.heap.defineProperty(o, k, .{
        .value = Value.fromNative(n),
        .enumerable = true,
        .writable = true,
        .configurable = true,
    });
}

fn allocateUint8Array(rt: *Runtime, len: usize) Error!*Object {
    const vr = try builtins.viewsRealm(rt);
    const ab = try rt.heap.newArrayBuffer(vr.array_buffer_prototype, len);
    var root_buf = [_]Value{Value.fromObject(ab)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    return rt.heap.newTypedArray(
        vr.typed_array_prototypes[@backingInt(heap_mod.TypedArrayKind.uint8)],
        ab,
        .uint8,
        0,
        len,
    );
}

// ---------------------------------------------------------------- registration

pub fn register(rt: *Runtime, r: *const builtins.Realm) Error!void {
    // TextEncoder
    try rt.heap.defineProperty(r.text_encoder_namespace, try rt.heap.internAscii("prototype"), .{
        .value = Value.fromObject(r.text_encoder_prototype),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try common.constant(rt, r.text_encoder_prototype, "constructor", Value.fromNative(&builtins.text_encoder_global));
    try object.defineAccessor(rt, Value.fromObject(r.text_encoder_prototype), try object.named(rt, "encoding"), Value.fromNative(&te_encoding_getter), false, true);
    try defineEnumerableMethod(rt, r.text_encoder_prototype, "encode", &te_encode);
    try defineEnumerableMethod(rt, r.text_encoder_prototype, "encodeInto", &te_encode_into);
    try common.defineToStringTag(rt, r.text_encoder_prototype, r.sym_to_string_tag, "TextEncoder");

    // TextDecoder
    try rt.heap.defineProperty(r.text_decoder_namespace, try rt.heap.internAscii("prototype"), .{
        .value = Value.fromObject(r.text_decoder_prototype),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try common.constant(rt, r.text_decoder_prototype, "constructor", Value.fromNative(&builtins.text_decoder_global));
    try object.defineAccessor(rt, Value.fromObject(r.text_decoder_prototype), try object.named(rt, "encoding"), Value.fromNative(&td_encoding_getter), false, true);
    try object.defineAccessor(rt, Value.fromObject(r.text_decoder_prototype), try object.named(rt, "fatal"), Value.fromNative(&td_fatal_getter), false, true);
    try object.defineAccessor(rt, Value.fromObject(r.text_decoder_prototype), try object.named(rt, "ignoreBOM"), Value.fromNative(&td_ignore_bom_getter), false, true);
    try defineEnumerableMethod(rt, r.text_decoder_prototype, "decode", &td_decode);
    try common.defineToStringTag(rt, r.text_decoder_prototype, r.sym_to_string_tag, "TextDecoder");
}

// ---------------------------------------------------------------- btoa / atob

pub fn btoaImpl(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    if (args.len == 0) {
        return rt.throw(.TypeError, &.{.{ .ascii = "btoa requires at least 1 argument" }});
    }
    const str = try common.toStringObj(rt, args[0]);
    var root_buf = [_]Value{Value.fromString(str)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const units = str.units;
    for (units) |u| {
        if (u > 0xFF) {
            return throwInvalidCharacterError(rt, "The string to be encoded contains characters outside of the Latin1 range.");
        }
    }
    if (units.len == 0) {
        return Value.fromString(try rt.heap.ascii(""));
    }

    const groups = std.math.divCeil(usize, units.len, 3) catch return rt.heap.exceeded(.string_length);
    const out_len = std.math.mul(usize, groups, 4) catch return rt.heap.exceeded(.string_length);
    if (out_len > rt.heap.max_string_length) {
        return rt.heap.exceeded(.string_length);
    }

    const out = try rt.gpa.alloc(u8, out_len);
    defer rt.gpa.free(out);

    var i: usize = 0;
    var o: usize = 0;
    while (i + 3 <= units.len) : (i += 3) {
        const b0: u8 = @intCast(units[i]);
        const b1: u8 = @intCast(units[i + 1]);
        const b2: u8 = @intCast(units[i + 2]);
        out[o] = b64_alphabet[b0 >> 2];
        out[o + 1] = b64_alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[o + 2] = b64_alphabet[((b1 & 0x0F) << 2) | (b2 >> 6)];
        out[o + 3] = b64_alphabet[b2 & 0x3F];
        o += 4;
    }
    const rem = units.len - i;
    if (rem == 1) {
        const b0: u8 = @intCast(units[i]);
        out[o] = b64_alphabet[b0 >> 2];
        out[o + 1] = b64_alphabet[(b0 & 0x03) << 4];
        out[o + 2] = '=';
        out[o + 3] = '=';
    } else if (rem == 2) {
        const b0: u8 = @intCast(units[i]);
        const b1: u8 = @intCast(units[i + 1]);
        out[o] = b64_alphabet[b0 >> 2];
        out[o + 1] = b64_alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[o + 2] = b64_alphabet[(b1 & 0x0F) << 2];
        out[o + 3] = '=';
    }

    return Value.fromString(try rt.heap.newString(&.{.{ .ascii = out }}));
}

pub fn atobImpl(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    if (args.len == 0) {
        return rt.throw(.TypeError, &.{.{ .ascii = "atob requires at least 1 argument" }});
    }
    const str = try common.toStringObj(rt, args[0]);
    var root_buf = [_]Value{Value.fromString(str)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var clean: std.ArrayList(u8) = .empty;
    defer clean.deinit(rt.gpa);

    for (str.units) |u| {
        if (isAsciiWhitespace(u)) continue;
        if (u > 0x7F) {
            return throwInvalidCharacterError(rt, "The string to be decoded is not correctly encoded.");
        }
        try clean.append(rt.gpa, @intCast(u));
    }

    var len = clean.items.len;
    if (len % 4 == 0) {
        if (len >= 1 and clean.items[len - 1] == '=') {
            len -= 1;
            if (len >= 1 and clean.items[len - 1] == '=') {
                len -= 1;
            }
        }
    }
    if (len % 4 == 1) {
        return throwInvalidCharacterError(rt, "The string to be decoded is not correctly encoded.");
    }

    const src = clean.items[0..len];
    for (src) |ch| {
        if (b64_decode_table[ch] == 0xFF) {
            return throwInvalidCharacterError(rt, "The string to be decoded is not correctly encoded.");
        }
    }

    if (len == 0) {
        return Value.fromString(try rt.heap.ascii(""));
    }

    const groups = len / 4;
    const rem = len % 4;
    const extra: usize = if (rem == 2) 1 else if (rem == 3) 2 else 0;
    const out_len = groups * 3 + extra;
    if (out_len > rt.heap.max_string_length) {
        return rt.heap.exceeded(.string_length);
    }

    const out = try rt.gpa.alloc(u16, out_len);
    defer rt.gpa.free(out);

    var i: usize = 0;
    var o: usize = 0;
    while (i + 4 <= len) : (i += 4) {
        const v0 = b64_decode_table[src[i]];
        const v1 = b64_decode_table[src[i + 1]];
        const v2 = b64_decode_table[src[i + 2]];
        const v3 = b64_decode_table[src[i + 3]];
        out[o] = (@as(u16, v0) << 2) | (v1 >> 4);
        out[o + 1] = ((@as(u16, v1) & 0x0F) << 4) | (v2 >> 2);
        out[o + 2] = ((@as(u16, v2) & 0x03) << 6) | v3;
        o += 3;
    }
    if (rem == 2) {
        const v0 = b64_decode_table[src[i]];
        const v1 = b64_decode_table[src[i + 1]];
        out[o] = (@as(u16, v0) << 2) | (v1 >> 4);
    } else if (rem == 3) {
        const v0 = b64_decode_table[src[i]];
        const v1 = b64_decode_table[src[i + 1]];
        const v2 = b64_decode_table[src[i + 2]];
        out[o] = (@as(u16, v0) << 2) | (v1 >> 4);
        out[o + 1] = ((@as(u16, v1) & 0x0F) << 4) | (v2 >> 2);
    }

    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out }}));
}

// ---------------------------------------------------------------- TextEncoder

pub fn textEncoderWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor TextEncoder requires 'new'" }});
}

pub fn textEncoderConstruct(rt: *Runtime, _: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const obj = try rt.heap.newObject(r.text_encoder_prototype);
    var root_buf = [_]Value{Value.fromObject(obj)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    try rt.heap.weakSetAdd(r.text_encoders, .{ .obj = &obj.obj });
    return root_buf[0];
}

fn requireTextEncoder(rt: *Runtime, this: Value, name: []const u8) Error!void {
    const r = try builtins.realm(rt);
    if (this.isObject() and heap_mod.Heap.weakSetHas(r.text_encoders, .{ .obj = &this.asObject().obj })) {
        return;
    }
    return rt.throw(.TypeError, &.{
        .{ .ascii = "Method TextEncoder.prototype." },
        .{ .ascii = name },
        .{ .ascii = " called on incompatible receiver" },
    });
}

const te_encoding_getter: Native = .{ .name = "get encoding", .length = 0, .call = teEncodingGetter };
const te_encode: Native = .{ .name = "encode", .length = 0, .call = teEncode };
const te_encode_into: Native = .{ .name = "encodeInto", .length = 2, .call = teEncodeInto };

fn teEncodingGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    try requireTextEncoder(rt, this, "encoding");
    return Value.fromString(try rt.heap.ascii("utf-8"));
}

const EncodedScalar = struct {
    utf16_step: usize,
    utf8_len: u3,
    bytes: [4]u8,
};

fn encodeUtf16Unit(units: []const u16, idx: usize) EncodedScalar {
    const u = units[idx];
    if (u < 0x80) {
        return .{ .utf16_step = 1, .utf8_len = 1, .bytes = .{ @intCast(u), 0, 0, 0 } };
    }
    if (u < 0x800) {
        return .{
            .utf16_step = 1,
            .utf8_len = 2,
            .bytes = .{
                @intCast(0xC0 | (u >> 6)),
                @intCast(0x80 | (u & 0x3F)),
                0,
                0,
            },
        };
    }
    if (u >= 0xD800 and u <= 0xDBFF) {
        if (idx + 1 < units.len) {
            const lo = units[idx + 1];
            if (lo >= 0xDC00 and lo <= 0xDFFF) {
                const cp: u21 = 0x10000 + ((@as(u21, u - 0xD800) << 10) | @as(u21, lo - 0xDC00));
                return .{
                    .utf16_step = 2,
                    .utf8_len = 4,
                    .bytes = .{
                        @intCast(0xF0 | (cp >> 18)),
                        @intCast(0x80 | ((cp >> 12) & 0x3F)),
                        @intCast(0x80 | ((cp >> 6) & 0x3F)),
                        @intCast(0x80 | (cp & 0x3F)),
                    },
                };
            }
        }
        // Lone high surrogate -> U+FFFD
        return .{ .utf16_step = 1, .utf8_len = 3, .bytes = .{ 0xEF, 0xBF, 0xBD, 0 } };
    }
    if (u >= 0xDC00 and u <= 0xDFFF) {
        // Lone low surrogate -> U+FFFD
        return .{ .utf16_step = 1, .utf8_len = 3, .bytes = .{ 0xEF, 0xBF, 0xBD, 0 } };
    }
    return .{
        .utf16_step = 1,
        .utf8_len = 3,
        .bytes = .{
            @intCast(0xE0 | (u >> 12)),
            @intCast(0x80 | ((u >> 6) & 0x3F)),
            @intCast(0x80 | (u & 0x3F)),
            0,
        },
    };
}

fn teEncode(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    try requireTextEncoder(rt, this, "encode");
    const input = common.arg(args, 0);
    if (input.isUndefined()) {
        return Value.fromObject(try allocateUint8Array(rt, 0));
    }
    const str = try common.toStringObj(rt, input);
    var root_buf = [_]Value{Value.fromString(str)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const units = str.units;
    var byte_len: usize = 0;
    var i: usize = 0;
    while (i < units.len) {
        const enc = encodeUtf16Unit(units, i);
        byte_len += enc.utf8_len;
        i += enc.utf16_step;
    }

    const ta = try allocateUint8Array(rt, byte_len);
    const dst = ta.kind.typed_array.buffer.kind.array_buffer.data;
    var pos: usize = 0;
    i = 0;
    while (i < units.len) {
        const enc = encodeUtf16Unit(units, i);
        @memcpy(dst[pos .. pos + enc.utf8_len], enc.bytes[0..enc.utf8_len]);
        pos += enc.utf8_len;
        i += enc.utf16_step;
    }
    return Value.fromObject(ta);
}

fn teEncodeInto(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    try requireTextEncoder(rt, this, "encodeInto");
    if (args.len < 2) {
        return rt.throw(.TypeError, &.{.{ .ascii = "TextEncoder.prototype.encodeInto requires 2 arguments" }});
    }
    var root_buf = [_]Value{ args[1], .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const src_str = try common.toStringObj(rt, args[0]);
    root_buf[1] = Value.fromString(src_str);

    const dst_val = root_buf[0];
    if (!dst_val.isObject() or dst_val.asObject().kind != .typed_array or dst_val.asObject().kind.typed_array.kind != .uint8) {
        return rt.throw(.TypeError, &.{.{ .ascii = "The \"destination\" argument must be an instance of Uint8Array" }});
    }
    const ta = dst_val.asObject().kind.typed_array;
    const ab = ta.buffer.kind.array_buffer;
    if (ab.detached) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Destination Uint8Array buffer is detached" }});
    }

    const dst = ab.data[ta.byte_offset .. ta.byte_offset + ta.length];
    const units = src_str.units;
    var read: usize = 0;
    var written: usize = 0;
    while (read < units.len) {
        const enc = encodeUtf16Unit(units, read);
        if (written + enc.utf8_len > dst.len) break;
        @memcpy(dst[written .. written + enc.utf8_len], enc.bytes[0..enc.utf8_len]);
        written += enc.utf8_len;
        read += enc.utf16_step;
    }

    const r = try builtins.realm(rt);
    const res = try rt.heap.newObject(r.object_prototype);
    root_buf[2] = Value.fromObject(res);
    try rt.heap.defineProperty(res, try rt.heap.internAscii("read"), .{ .value = Value.fromNumber(@floatFromInt(read)) });
    try rt.heap.defineProperty(res, try rt.heap.internAscii("written"), .{ .value = Value.fromNumber(@floatFromInt(written)) });
    return root_buf[2];
}

// ---------------------------------------------------------------- TextDecoder

fn isUtf8Label(units: []const u16) bool {
    var start: usize = 0;
    var end: usize = units.len;
    while (start < end and isAsciiWhitespace(units[start])) : (start += 1) {}
    while (end > start and isAsciiWhitespace(units[end - 1])) : (end -= 1) {}
    const trimmed = units[start..end];
    if (trimmed.len == 0 or trimmed.len > 24) return false;

    var buf: [24]u8 = undefined;
    for (trimmed, 0..) |u, i| {
        if (u > 0x7F) return false;
        const c: u8 = @intCast(u);
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    const norm = buf[0..trimmed.len];
    return std.mem.eql(u8, norm, "utf-8") or
        std.mem.eql(u8, norm, "utf8") or
        std.mem.eql(u8, norm, "unicode-1-1-utf-8") or
        std.mem.eql(u8, norm, "unicode11utf8") or
        std.mem.eql(u8, norm, "unicode20utf8") or
        std.mem.eql(u8, norm, "x-unicode20utf8");
}

pub fn textDecoderWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor TextDecoder requires 'new'" }});
}

pub fn textDecoderConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const label_arg = common.arg(args, 0);
    const opts_arg = common.arg(args, 1);

    var root_buf = [_]Value{ opts_arg, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (!label_arg.isUndefined()) {
        const label_str = try common.toStringObj(rt, label_arg);
        if (!isUtf8Label(label_str.units)) {
            return rt.throw(.RangeError, &.{.{ .ascii = "The encoding label provided is not supported." }});
        }
    }

    var state: DecoderState = .{};
    if (!opts_arg.isUndefined() and !opts_arg.isNull()) {
        if (!opts_arg.isObjectLike()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "The \"options\" argument must be an object" }});
        }
        const fatal_val = try object.get(rt, root_buf[0], try object.named(rt, "fatal"));
        state.fatal = ops.toBoolean(fatal_val);
        const ignore_bom_val = try object.get(rt, root_buf[0], try object.named(rt, "ignoreBOM"));
        state.ignore_bom = ops.toBoolean(ignore_bom_val);
    }

    const r = try builtins.realm(rt);
    const obj = try rt.heap.newObject(r.text_decoder_prototype);
    root_buf[1] = Value.fromObject(obj);
    try rt.heap.weakMapSet(r.text_decoders, .{ .obj = &obj.obj }, state.toValue());
    return root_buf[1];
}

fn requireTextDecoder(rt: *Runtime, this: Value, name: []const u8) Error!struct { obj: *Object, state: DecoderState } {
    const r = try builtins.realm(rt);
    if (this.isObject()) {
        const o = this.asObject();
        if (heap_mod.Heap.weakMapGet(r.text_decoders, .{ .obj = &o.obj })) |state_val| {
            return .{ .obj = o, .state = DecoderState.fromValue(state_val) };
        }
    }
    return rt.throw(.TypeError, &.{
        .{ .ascii = "Method TextDecoder.prototype." },
        .{ .ascii = name },
        .{ .ascii = " called on incompatible receiver" },
    });
}

const td_encoding_getter: Native = .{ .name = "get encoding", .length = 0, .call = tdEncodingGetter };
const td_fatal_getter: Native = .{ .name = "get fatal", .length = 0, .call = tdFatalGetter };
const td_ignore_bom_getter: Native = .{ .name = "get ignoreBOM", .length = 0, .call = tdIgnoreBomGetter };
const td_decode: Native = .{ .name = "decode", .length = 0, .call = tdDecode };

fn tdEncodingGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try requireTextDecoder(rt, this, "encoding");
    return Value.fromString(try rt.heap.ascii("utf-8"));
}

fn tdFatalGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const td = try requireTextDecoder(rt, this, "fatal");
    return Value.fromBool(td.state.fatal);
}

fn tdIgnoreBomGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const td = try requireTextDecoder(rt, this, "ignoreBOM");
    return Value.fromBool(td.state.ignore_bom);
}

fn appendCodePoint(rt: *Runtime, out: *std.ArrayList(u16), state: *DecoderState, cp: u21) Error!void {
    if (!state.ignore_bom and !state.bom_seen) {
        state.bom_seen = true;
        if (cp == 0xFEFF) return;
    }
    if (cp <= 0xFFFF) {
        if (out.items.len + 1 > rt.heap.max_string_length) {
            return rt.heap.exceeded(.string_length);
        }
        try out.append(rt.gpa, @intCast(cp));
    } else {
        if (out.items.len + 2 > rt.heap.max_string_length) {
            return rt.heap.exceeded(.string_length);
        }
        const adj = cp - 0x10000;
        try out.append(rt.gpa, @intCast(0xD800 + (adj >> 10)));
        try out.append(rt.gpa, @intCast(0xDC00 + (adj & 0x3FF)));
    }
}

fn tdDecode(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const td = try requireTextDecoder(rt, this, "decode");
    const input = common.arg(args, 0);
    const opts = common.arg(args, 1);

    if (!input.isUndefined()) {
        if (!input.isObject()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "The \"input\" argument must be an instance of ArrayBuffer or ArrayBufferView" }});
        }
        switch (input.asObject().kind) {
            .array_buffer, .typed_array, .data_view => {},
            else => return rt.throw(.TypeError, &.{.{ .ascii = "The \"input\" argument must be an instance of ArrayBuffer or ArrayBufferView" }}),
        }
    }

    var root_buf = [_]Value{ this, input, opts };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var stream = false;
    if (!opts.isUndefined() and !opts.isNull()) {
        if (!opts.isObjectLike()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "The \"options\" argument must be an object" }});
        }
        const stream_val = try object.get(rt, root_buf[2], try object.named(rt, "stream"));
        stream = ops.toBoolean(stream_val);
    }

    // Re-read state after options getter in case a re-entrant decode() ran.
    const r = try builtins.realm(rt);
    var state = DecoderState.fromValue(heap_mod.Heap.weakMapGet(r.text_decoders, .{ .obj = &td.obj.obj }).?);

    // Extract byte slice after reading options (so getter-induced detach is caught).
    const bytes: []const u8 = if (input.isUndefined())
        &[_]u8{}
    else switch (input.asObject().kind) {
        .array_buffer => |ab| blk: {
            if (ab.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot decode a detached ArrayBuffer" }});
            break :blk ab.data;
        },
        .typed_array => |ta| blk: {
            const ab = ta.buffer.kind.array_buffer;
            if (ab.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot decode a detached ArrayBuffer" }});
            const byte_len = ta.length * ta.kind.bytesPerElement();
            break :blk ab.data[ta.byte_offset .. ta.byte_offset + byte_len];
        },
        .data_view => |dv| blk: {
            const ab = dv.buffer.kind.array_buffer;
            if (ab.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot decode a detached ArrayBuffer" }});
            break :blk ab.data[dv.byte_offset .. dv.byte_offset + dv.byte_length];
        },
        else => unreachable,
    };

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);

    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (state.bytes_needed == 0) {
            i += 1;
            if (b <= 0x7F) {
                try appendCodePoint(rt, &out, &state, b);
            } else if (b >= 0xC2 and b <= 0xDF) {
                state.bytes_needed = 1;
                state.bytes_seen = 0;
                state.lower_mode = 0;
                state.upper_mode = 0;
                state.code_point = b & 0x1F;
            } else if (b >= 0xE0 and b <= 0xEF) {
                state.bytes_needed = 2;
                state.bytes_seen = 0;
                state.lower_mode = if (b == 0xE0) 1 else 0;
                state.upper_mode = if (b == 0xED) 1 else 0;
                state.code_point = b & 0x0F;
            } else if (b >= 0xF0 and b <= 0xF4) {
                state.bytes_needed = 3;
                state.bytes_seen = 0;
                state.lower_mode = if (b == 0xF0) 2 else 0;
                state.upper_mode = if (b == 0xF4) 2 else 0;
                state.code_point = b & 0x07;
            } else {
                if (state.fatal) {
                    if (!stream) state.resetStream();
                    try rt.heap.weakMapSet(r.text_decoders, .{ .obj = &td.obj.obj }, state.toValue());
                    return rt.throw(.TypeError, &.{.{ .ascii = "The encoded data was not valid for encoding utf-8" }});
                }
                try appendCodePoint(rt, &out, &state, 0xFFFD);
            }
        } else {
            if (b < state.lowerBound() or b > state.upperBound()) {
                state.resetSequence();
                if (state.fatal) {
                    if (!stream) state.resetStream();
                    try rt.heap.weakMapSet(r.text_decoders, .{ .obj = &td.obj.obj }, state.toValue());
                    return rt.throw(.TypeError, &.{.{ .ascii = "The encoded data was not valid for encoding utf-8" }});
                }
                try appendCodePoint(rt, &out, &state, 0xFFFD);
                // Re-process `b` in the initial state per WHATWG maximal-subpart rule.
            } else {
                i += 1;
                state.lower_mode = 0;
                state.upper_mode = 0;
                state.code_point = (state.code_point << 6) | @as(u21, b & 0x3F);
                state.bytes_seen += 1;
                if (state.bytes_seen == state.bytes_needed) {
                    const cp = state.code_point;
                    state.resetSequence();
                    try appendCodePoint(rt, &out, &state, cp);
                }
            }
        }
    }

    if (!stream) {
        if (state.bytes_needed != 0) {
            if (state.fatal) {
                state.resetStream();
                try rt.heap.weakMapSet(r.text_decoders, .{ .obj = &td.obj.obj }, state.toValue());
                return rt.throw(.TypeError, &.{.{ .ascii = "The encoded data was not valid for encoding utf-8" }});
            }
            try appendCodePoint(rt, &out, &state, 0xFFFD);
        }
        state.resetStream();
    }

    try rt.heap.weakMapSet(r.text_decoders, .{ .obj = &td.obj.obj }, state.toValue());
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}
