//! String, String.prototype, and tagged template object built-ins.

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
const regex = @import("../../regex.zig");
const builtins = @import("../builtins.zig");
const common = @import("common.zig");
const number_math = @import("number_math.zig");
const regexp = @import("regexp.zig");

pub fn register(rt: *Runtime, r: *const builtins.Realm) Error!void {
    try common.method(rt, r.string_prototype, "charAt", &string_char_at);
    try common.method(rt, r.string_prototype, "charCodeAt", &string_char_code_at);
    try common.method(rt, r.string_prototype, "slice", &string_slice);
    try common.method(rt, r.string_prototype, "indexOf", &string_index_of);
    try common.method(rt, r.string_prototype, "includes", &string_includes);
    try common.method(rt, r.string_prototype, "toLowerCase", &string_to_lower_case);
    try common.method(rt, r.string_prototype, "toUpperCase", &string_to_upper_case);
    try common.method(rt, r.string_prototype, "toLocaleLowerCase", &string_to_locale_lower_case);
    try common.method(rt, r.string_prototype, "toLocaleUpperCase", &string_to_locale_upper_case);
    try common.method(rt, r.string_prototype, "concat", &string_concat);
    try common.method(rt, r.string_prototype, "split", &string_split);
    try common.method(rt, r.string_prototype, "trim", &string_trim);
    try common.method(rt, r.string_prototype, "trimStart", &string_trim_start);
    try common.method(rt, r.string_prototype, "trimEnd", &string_trim_end);
    try common.method(rt, r.string_prototype, "startsWith", &string_starts_with);
    try common.method(rt, r.string_prototype, "endsWith", &string_ends_with);
    try common.method(rt, r.string_prototype, "repeat", &string_repeat);
    try common.method(rt, r.string_prototype, "padStart", &string_pad_start);
    try common.method(rt, r.string_prototype, "padEnd", &string_pad_end);
    try common.method(rt, r.string_prototype, "substring", &string_substring);
    try common.method(rt, r.string_prototype, "lastIndexOf", &string_last_index_of);
    try common.method(rt, r.string_prototype, "at", &string_at);
    try common.method(rt, r.string_prototype, "replace", &string_replace);
    try common.method(rt, r.string_prototype, "replaceAll", &string_replace_all);
    try common.method(rt, r.string_prototype, "match", &string_match);
    try common.method(rt, r.string_prototype, "matchAll", &string_match_all);
    try common.method(rt, r.string_prototype, "search", &string_search);
    try common.method(rt, r.string_prototype, "codePointAt", &string_code_point_at);
    try common.method(rt, r.string_namespace, "fromCharCode", &string_from_char_code);
    try common.method(rt, r.string_namespace, "fromCodePoint", &string_from_code_point);
    try common.method(rt, r.string_namespace, "raw", &string_raw);
    try common.symbolMethod(rt, r.string_prototype, r.sym_iterator, &string_iterator);
    try common.immutableConstant(rt, r.string_namespace, "prototype", Value.fromObject(r.string_prototype));
    try common.constant(rt, r.string_prototype, "constructor", Value.fromNative(&builtins.string_global));
    try common.method(rt, r.string_prototype, "toString", &string_to_string);
    try common.method(rt, r.string_prototype, "valueOf", &string_value_of);
}

const string_char_at: Native = .{ .name = "charAt", .length = 1, .call = stringCharAt };

const string_char_code_at: Native = .{ .name = "charCodeAt", .length = 1, .call = stringCharCodeAt };

const string_code_point_at: Native = .{ .name = "codePointAt", .length = 1, .call = stringCodePointAt };

const string_from_char_code: Native = .{ .name = "fromCharCode", .length = 1, .call = stringFromCharCode };

const string_from_code_point: Native = .{ .name = "fromCodePoint", .length = 1, .call = stringFromCodePoint };

const string_raw: Native = .{ .name = "raw", .length = 1, .call = stringRaw };

const string_slice: Native = .{ .name = "slice", .length = 2, .call = stringSlice };

const string_index_of: Native = .{ .name = "indexOf", .length = 1, .call = stringIndexOf };

const string_includes: Native = .{ .name = "includes", .length = 1, .call = stringIncludes };

const string_to_lower_case: Native = .{ .name = "toLowerCase", .call = stringToLowerCase };

const string_to_upper_case: Native = .{ .name = "toUpperCase", .call = stringToUpperCase };

const string_to_locale_lower_case: Native = .{ .name = "toLocaleLowerCase", .call = stringToLocaleLowerCase };

const string_to_locale_upper_case: Native = .{ .name = "toLocaleUpperCase", .call = stringToLocaleUpperCase };

const string_concat: Native = .{ .name = "concat", .length = 1, .call = stringConcat };

const string_split: Native = .{ .name = "split", .length = 2, .call = stringSplit };

const string_trim: Native = .{ .name = "trim", .call = stringTrim };

const string_trim_start: Native = .{ .name = "trimStart", .call = stringTrimStart };

const string_trim_end: Native = .{ .name = "trimEnd", .call = stringTrimEnd };

const string_starts_with: Native = .{ .name = "startsWith", .length = 1, .call = stringStartsWith };

const string_ends_with: Native = .{ .name = "endsWith", .length = 1, .call = stringEndsWith };

const string_repeat: Native = .{ .name = "repeat", .length = 1, .call = stringRepeat };

const string_pad_start: Native = .{ .name = "padStart", .length = 1, .call = stringPadStart };

const string_pad_end: Native = .{ .name = "padEnd", .length = 1, .call = stringPadEnd };

const string_substring: Native = .{ .name = "substring", .length = 2, .call = stringSubstring };

const string_last_index_of: Native = .{ .name = "lastIndexOf", .length = 1, .call = stringLastIndexOf };

const string_at: Native = .{ .name = "at", .length = 1, .call = stringAt };

const string_replace: Native = .{ .name = "replace", .length = 2, .call = stringReplace };

const string_replace_all: Native = .{ .name = "replaceAll", .length = 2, .call = stringReplaceAll };

const string_match: Native = .{ .name = "match", .length = 1, .call = stringMatch };

const string_match_all: Native = .{ .name = "matchAll", .length = 1, .call = stringMatchAll };

const string_search: Native = .{ .name = "search", .length = 1, .call = stringSearch };

const string_to_string: Native = .{ .name = "toString", .length = 0, .call = stringToString };

const string_value_of: Native = .{ .name = "valueOf", .length = 0, .call = stringValueOf };

const string_iterator: Native = .{ .name = "[Symbol.iterator]", .call = stringIterator };

fn thisString(rt: *Runtime, this: Value, name: []const u8) Error!*const heap_mod.String {
    return switch (this.unpack()) {
        .string => |s| s,
        .object => |o| if (o.kind == .primitive_wrapper and o.kind.primitive_wrapper.isString()) o.kind.primitive_wrapper.asString() else common.unsupportedReceiver(rt, name),
        else => common.unsupportedReceiver(rt, name),
    };
}

fn requireStringCoercible(rt: *Runtime, this: Value) Error!*const heap_mod.String {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype method called on null or undefined" }});
    }
    return common.toStringObj(rt, this);
}

fn thisStringExact(rt: *Runtime, this: Value) Error!*const heap_mod.String {
    if (this.isString()) return this.asString();
    if (this.isObject()) {
        const o = this.asObject();
        if (o.kind == .primitive_wrapper and o.kind.primitive_wrapper.isString()) return o.kind.primitive_wrapper.asString();
        if (o.builtin == .string_prototype) return rt.heap.newString(&.{});
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype method requires a String receiver" }});
}

fn stringCharAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisString(rt, this, "charAt");
    const pos = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
    if (pos < 0 or pos >= @as(f64, @floatFromInt(s.units.len))) {
        return Value.fromString(try rt.heap.newString(&.{}));
    }
    const i: usize = @intFromFloat(pos);
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units[i .. i + 1] }}));
}

fn stringCharCodeAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{Value.fromString(s)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const pos = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
    if (pos < 0 or pos >= @as(f64, @floatFromInt(s.units.len))) return Value.fromNumber(std.math.nan(f64));
    return Value.fromNumber(@floatFromInt(s.units[@intFromFloat(pos)])); // a UTF-16 code unit
}

fn stringCodePointAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{Value.fromString(s)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const pos = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
    if (pos < 0 or pos >= @as(f64, @floatFromInt(s.units.len))) return .undefined;
    const i: usize = @intFromFloat(pos);
    const first = s.units[i];
    if (first >= 0xD800 and first <= 0xDBFF and i + 1 < s.units.len) {
        const second = s.units[i + 1];
        if (second >= 0xDC00 and second <= 0xDFFF) {
            const cp: u32 = 0x10000 + ((@as(u32, first - 0xD800) << 10) | @as(u32, second - 0xDC00));
            return Value.fromNumber(@floatFromInt(cp));
        }
    }
    return Value.fromNumber(@floatFromInt(first));
}

fn stringFromCharCode(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    if (args.len > rt.limits.max_string_length) return rt.limit(.string_length);
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(rt.gpa);
    try buf.ensureTotalCapacity(rt.gpa, args.len);
    for (args) |a| {
        const n = try ops.toNumber(rt, a);
        const u: u16 = @truncate(@as(u32, @bitCast(ops.toInt32(n))));
        buf.appendAssumeCapacity(u);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = buf.items }}));
}

fn stringFromCodePoint(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(rt.gpa);
    for (args) |a| {
        const n = try ops.toNumber(rt, a);
        if (!std.math.isFinite(n) or @trunc(n) != n or n < 0 or n > 0x10FFFF) {
            return rt.throw(.RangeError, &.{.{ .ascii = "Invalid code point" }});
        }
        const cp: u21 = @intFromFloat(n);
        if (cp <= 0xFFFF) {
            if (buf.items.len >= rt.limits.max_string_length) return rt.limit(.string_length);
            try buf.append(rt.gpa, @intCast(cp));
        } else {
            if (buf.items.len + 2 > rt.limits.max_string_length) return rt.limit(.string_length);
            const v = cp - 0x10000;
            try buf.append(rt.gpa, @intCast(0xD800 + (v >> 10)));
            try buf.append(rt.gpa, @intCast(0xDC00 + (v & 0x3FF)));
        }
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = buf.items }}));
}

fn stringRaw(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const tmpl = common.arg(args, 0);
    if (tmpl.isUndefined() or tmpl.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const raw = try object.get(rt, tmpl, try object.named(rt, "raw"));
    if (raw.isUndefined() or raw.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    var root_buf = [_]Value{ raw, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_val = try object.get(rt, raw, try object.named(rt, "length"));
    const literal_segments = try common.toLength(rt, len_val);
    if (literal_segments <= 0) return Value.fromString(try rt.heap.newString(&.{}));

    const max_len = rt.heap.max_string_length;
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);

    var next_index: f64 = 0;
    while (next_index < literal_segments) : (next_index += 1) {
        const key: object.Key = if (next_index <= @as(f64, @floatFromInt(std.math.maxInt(u32))))
            .{ .index = @intFromFloat(next_index) }
        else
            try object.key(rt, Value.fromNumber(next_index));
        const seg_val = try object.get(rt, raw, key);
        const seg = try common.toStringObj(rt, seg_val);
        root_buf[1] = Value.fromString(seg);
        try common.appendUnits(rt, &out, seg.units);
        if (next_index + 1 == literal_segments) break;
        const sub_idx_f = next_index + 1;
        if (sub_idx_f < @as(f64, @floatFromInt(args.len))) {
            const sub_idx: usize = @intFromFloat(sub_idx_f);
            const sub = try common.toStringObj(rt, args[sub_idx]);
            root_buf[1] = Value.fromString(sub);
            try common.appendUnits(rt, &out, sub.units);
        }
        if (out.items.len > max_len) return rt.limit(.string_length);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn stringSlice(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisString(rt, this, "slice");
    const len = s.units.len;
    const from = if (common.arg(args, 0).isUndefined()) 0 else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 0)), len);
    const to = if (common.arg(args, 1).isUndefined()) len else common.resolveRelativeIndex(try common.toIntegerOrInfinity(rt, common.arg(args, 1)), len);
    if (from >= to) return Value.fromString(try rt.heap.newString(&.{}));
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units[from..to] }}));
}

fn stringIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{ Value.fromString(s), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const search_obj = try common.toStringObj(rt, common.arg(args, 0));
    root_buf[1] = Value.fromString(search_obj);
    const pos = try common.toIntegerOrInfinity(rt, common.arg(args, 1));
    const len = s.units.len;
    const start: usize = if (pos <= 0) 0 else if (pos >= @as(f64, @floatFromInt(len))) len else @intFromFloat(pos);
    if (search_obj.units.len == 0) return Value.fromNumber(@floatFromInt(start));
    if (std.mem.indexOfPos(u16, s.units, start, search_obj.units)) |idx| return Value.fromNumber(@floatFromInt(idx));
    return Value.fromNumber(-1);
}

fn stringIncludes(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{ Value.fromString(s), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const search_arg = common.arg(args, 0);
    if (try regexp.isRegExp(rt, search_arg)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "First argument to String.prototype.includes must not be a regular expression" }});
    }
    const search_obj = try common.toStringObj(rt, search_arg);
    root_buf[1] = Value.fromString(search_obj);
    const pos = try common.toIntegerOrInfinity(rt, common.arg(args, 1));
    const len = s.units.len;
    const start: usize = if (pos <= 0) 0 else if (pos >= @as(f64, @floatFromInt(len))) len else @intFromFloat(pos);
    if (search_obj.units.len == 0) return Value.fromBool(true);
    return Value.fromBool(std.mem.indexOfPos(u16, s.units, start, search_obj.units) != null);
}

/// Compatibility restriction: JavaScript case conversion is Unicode-aware, whereas
/// ZQJS currently implements ASCII-only case conversion and reports `Unsupported(builtin)`
/// for non-ASCII code units (`>= 0x80`) rather than silently diverging from JS.
fn asciiCase(rt: *Runtime, s: *const heap_mod.String, name: []const u8, comptime upper: bool) Error!Value {
    var stack_buf: [256]u16 = undefined;
    const heap_buf: []u16 = if (s.units.len > stack_buf.len) try rt.gpa.alloc(u16, s.units.len) else &.{};
    defer if (heap_buf.len > 0) rt.gpa.free(heap_buf);
    const out = if (s.units.len > stack_buf.len) heap_buf else stack_buf[0..s.units.len];
    for (s.units, 0..) |u, i| {
        if (u >= 0x80) return common.unsupportedReceiver(rt, name);
        out[i] = if (upper)
            if (u >= 'a' and u <= 'z') u - 32 else u
        else if (u >= 'A' and u <= 'Z') u + 32 else u;
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out }}));
}

fn stringToLowerCase(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    return asciiCase(rt, s, "toLowerCase", false);
}

fn stringToUpperCase(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    return asciiCase(rt, s, "toUpperCase", true);
}

fn stringToLocaleLowerCase(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    return asciiCase(rt, s, "toLocaleLowerCase", false);
}

fn stringToLocaleUpperCase(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    return asciiCase(rt, s, "toLocaleUpperCase", true);
}

fn stringConcat(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    if (args.len == 0) return Value.fromString(s);
    var root_buf = [_]Value{ Value.fromString(s), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);
    try common.appendUnits(rt, &out, s.units);
    for (args) |a| {
        const part = try common.toStringObj(rt, a);
        root_buf[1] = Value.fromString(part);
        try common.appendUnits(rt, &out, part.units);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn stringAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{Value.fromString(s)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len = s.units.len;
    const rel = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
    const k = if (rel >= 0) rel else @as(f64, @floatFromInt(len)) + rel;
    if (k < 0 or k >= @as(f64, @floatFromInt(len))) return .undefined;
    const i: usize = @intFromFloat(k);
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units[i .. i + 1] }}));
}

fn stringSubstring(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{Value.fromString(s)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f: f64 = @floatFromInt(s.units.len);
    const int_start = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
    const int_end = if (common.arg(args, 1).isUndefined()) len_f else try common.toIntegerOrInfinity(rt, common.arg(args, 1));
    const final_start = @min(@max(int_start, 0), len_f);
    const final_end = @min(@max(int_end, 0), len_f);
    const from: usize = @intFromFloat(@min(final_start, final_end));
    const to: usize = @intFromFloat(@max(final_start, final_end));
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units[from..to] }}));
}

fn stringLastIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{ Value.fromString(s), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const search_obj = try common.toStringObj(rt, common.arg(args, 0));
    root_buf[1] = Value.fromString(search_obj);
    const num_pos = if (args.len < 2) std.math.nan(f64) else try ops.toNumber(rt, args[1]);
    const pos = if (std.math.isNan(num_pos)) std.math.inf(f64) else if (num_pos == 0) 0 else @trunc(num_pos);
    const start: usize = @intFromFloat(@min(@max(pos, 0), @as(f64, @floatFromInt(s.units.len))));
    if (search_obj.units.len == 0) return Value.fromNumber(@floatFromInt(start));
    if (search_obj.units.len > s.units.len) return Value.fromNumber(-1);
    var k: usize = @min(start, s.units.len - search_obj.units.len);
    while (true) : (k -= 1) {
        if (std.mem.eql(u16, s.units[k .. k + search_obj.units.len], search_obj.units)) return Value.fromNumber(@floatFromInt(k));
        if (k == 0) break;
    }
    return Value.fromNumber(-1);
}

fn stringStartsWith(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{ Value.fromString(s), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const search_arg = common.arg(args, 0);
    if (try regexp.isRegExp(rt, search_arg)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "First argument to String.prototype.startsWith must not be a regular expression" }});
    }
    const search_obj = try common.toStringObj(rt, search_arg);
    root_buf[1] = Value.fromString(search_obj);
    const pos = try common.toIntegerOrInfinity(rt, common.arg(args, 1));
    const start: usize = @intFromFloat(@min(@max(pos, 0), @as(f64, @floatFromInt(s.units.len))));
    if (search_obj.units.len == 0) return Value.fromBool(true);
    if (s.units.len - start < search_obj.units.len) return Value.fromBool(false);
    return Value.fromBool(std.mem.eql(u16, s.units[start .. start + search_obj.units.len], search_obj.units));
}

fn stringEndsWith(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{ Value.fromString(s), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const search_arg = common.arg(args, 0);
    if (try regexp.isRegExp(rt, search_arg)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "First argument to String.prototype.endsWith must not be a regular expression" }});
    }
    const search_obj = try common.toStringObj(rt, search_arg);
    root_buf[1] = Value.fromString(search_obj);
    const len_f: f64 = @floatFromInt(s.units.len);
    const pos = if (common.arg(args, 1).isUndefined()) len_f else try common.toIntegerOrInfinity(rt, common.arg(args, 1));
    const end: usize = @intFromFloat(@min(@max(pos, 0), len_f));
    if (search_obj.units.len > end) return Value.fromBool(false);
    return Value.fromBool(std.mem.eql(u16, s.units[end - search_obj.units.len .. end], search_obj.units));
}

fn stringTrimImpl(rt: *Runtime, this: Value, _: []const u8, trim_start: bool, trim_end: bool) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var start: usize = 0;
    var end: usize = s.units.len;
    if (trim_start) while (start < end and common.isJsWhitespace(s.units[start])) {
        start += 1;
    };
    if (trim_end) while (end > start and common.isJsWhitespace(s.units[end - 1])) {
        end -= 1;
    };
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units[start..end] }}));
}

fn stringTrim(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return stringTrimImpl(rt, this, "trim", true, true);
}

fn stringTrimStart(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return stringTrimImpl(rt, this, "trimStart", true, false);
}

fn stringTrimEnd(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return stringTrimImpl(rt, this, "trimEnd", false, true);
}

fn stringRepeat(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{Value.fromString(s)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const n = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
    if (n < 0 or n == std.math.inf(f64)) return rt.throw(.RangeError, &.{.{ .ascii = "Invalid count value" }});
    if (n == 0 or s.units.len == 0) return Value.fromString(try rt.heap.newString(&.{}));
    const max_len = rt.heap.max_string_length;
    if (n > @as(f64, @floatFromInt(max_len))) return rt.limit(.string_length);
    const count: usize = @intFromFloat(n);
    const total = std.math.mul(usize, s.units.len, count) catch return rt.limit(.string_length);
    if (total > max_len) return rt.limit(.string_length);

    const buf = try rt.gpa.alloc(u16, total);
    defer rt.gpa.free(buf);
    for (0..count) |i| {
        @memcpy(buf[i * s.units.len ..][0..s.units.len], s.units);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = buf }}));
}

fn stringPadImpl(rt: *Runtime, this: Value, args: []const Value, _: []const u8, comptime is_start: bool) Error!Value {
    const s = try requireStringCoercible(rt, this);
    const s_val = Value.fromString(s);
    var root_buf = [_]Value{ s_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const max_len_f = try common.toIntegerOrInfinity(rt, common.arg(args, 0));
    if (max_len_f <= @as(f64, @floatFromInt(s.units.len))) return s_val;
    const filler: []const u16 = if (common.arg(args, 1).isUndefined())
        &.{' '}
    else blk: {
        const f_obj = try common.toStringObj(rt, common.arg(args, 1));
        root_buf[1] = Value.fromString(f_obj);
        break :blk f_obj.units;
    };
    if (filler.len == 0) return s_val;
    const max_str = rt.heap.max_string_length;
    if (max_len_f > @as(f64, @floatFromInt(max_str))) return rt.limit(.string_length);
    const target_len: usize = @intFromFloat(max_len_f);
    const pad_len = target_len - s.units.len;

    const pad_buf = try rt.gpa.alloc(u16, pad_len);
    defer rt.gpa.free(pad_buf);
    var filled: usize = 0;
    while (filled < pad_len) {
        const chunk = @min(filler.len, pad_len - filled);
        @memcpy(pad_buf[filled..][0..chunk], filler[0..chunk]);
        filled += chunk;
    }
    const pad_piece: heap_mod.Piece = .{ .utf16 = pad_buf };
    const orig_piece: heap_mod.Piece = .{ .utf16 = s.units };
    return Value.fromString(try rt.heap.newString(if (is_start) &.{ pad_piece, orig_piece } else &.{ orig_piece, pad_piece }));
}

fn stringPadStart(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return stringPadImpl(rt, this, args, "padStart", true);
}

fn stringPadEnd(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return stringPadImpl(rt, this, args, "padEnd", false);
}

fn stringSplit(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.split called on null or undefined" }});
    }
    const sep_arg = common.arg(args, 0);
    if (sep_arg.isObjectLike()) {
        const r = try builtins.realm(rt);
        if (try object.getMethod(rt, sep_arg, .{ .symbol = r.sym_split })) |splitter| {
            return rt.callCallable(splitter, sep_arg, &.{ this, common.arg(args, 1) });
        }
    }
    const s = try common.toStringObj(rt, this);
    const s_val = Value.fromString(s);
    var root_buf = [_]Value{ s_val, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const lim: u32 = if (common.arg(args, 1).isUndefined()) std.math.maxInt(u32) else ops.toUint32(try ops.toNumber(rt, common.arg(args, 1)));
    const r = try builtins.realm(rt);

    if (sep_arg.isUndefined()) {
        const out = try rt.heap.newArray(r.array_prototype);
        if (lim == 0) return Value.fromObject(out);
        root_buf[2] = Value.fromObject(out);
        try rt.heap.appendElement(out, s_val);
        return Value.fromObject(out);
    }

    const sep = try common.toStringObj(rt, sep_arg);
    root_buf[1] = Value.fromString(sep);

    const out = try rt.heap.newArray(r.array_prototype);
    root_buf[2] = Value.fromObject(out);
    if (lim == 0) return Value.fromObject(out);

    if (sep.units.len == 0) {
        const count = @min(s.units.len, lim);
        for (0..count) |i| {
            const ch = try rt.heap.newString(&.{.{ .utf16 = s.units[i .. i + 1] }});
            root_buf[3] = Value.fromString(ch);
            try rt.heap.appendElement(out, root_buf[3]);
            root_buf[3] = .undefined;
        }
        return Value.fromObject(out);
    }

    if (s.units.len == 0) {
        try rt.heap.appendElement(out, s_val);
        return Value.fromObject(out);
    }

    var pos: usize = 0;
    while (std.mem.indexOfPos(u16, s.units, pos, sep.units)) |idx| {
        const part = try rt.heap.newString(&.{.{ .utf16 = s.units[pos..idx] }});
        root_buf[3] = Value.fromString(part);
        try rt.heap.appendElement(out, root_buf[3]);
        root_buf[3] = .undefined;
        if (out.kind.array.items.len == lim) return Value.fromObject(out);
        pos = idx + sep.units.len;
    }
    const tail = try rt.heap.newString(&.{.{ .utf16 = s.units[pos..] }});
    root_buf[3] = Value.fromString(tail);
    try rt.heap.appendElement(out, root_buf[3]);
    return Value.fromObject(out);
}

fn expandReplacement(
    rt: *Runtime,
    out: *std.ArrayList(u16),
    s_units: []const u16,
    pos: usize,
    match_len: usize,
    repl_units: []const u16,
) Error!void {
    var i: usize = 0;
    while (i < repl_units.len) {
        if (repl_units[i] == '$' and i + 1 < repl_units.len) {
            switch (repl_units[i + 1]) {
                '$' => {
                    try common.appendUnits(rt, out, &.{'$'});
                    i += 2;
                    continue;
                },
                '&' => {
                    try common.appendUnits(rt, out, s_units[pos .. pos + match_len]);
                    i += 2;
                    continue;
                },
                '`' => {
                    try common.appendUnits(rt, out, s_units[0..pos]);
                    i += 2;
                    continue;
                },
                '\'' => {
                    try common.appendUnits(rt, out, s_units[pos + match_len ..]);
                    i += 2;
                    continue;
                },
                else => {},
            }
        }
        try common.appendUnits(rt, out, repl_units[i .. i + 1]);
        i += 1;
    }
}

fn stringReplaceImpl(rt: *Runtime, this: Value, args: []const Value, _: []const u8, comptime is_all: bool) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.replace called on null or undefined" }});
    }
    const search_arg = common.arg(args, 0);
    if (search_arg.isObjectLike()) {
        if (is_all and try regexp.isRegExp(rt, search_arg)) {
            const flags_val = try object.get(rt, search_arg, try object.named(rt, "flags"));
            if (flags_val.isUndefined() or flags_val.isNull()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.replaceAll called with a non-global RegExp argument" }});
            }
            const flags_s = try common.toStringObj(rt, flags_val);
            if (std.mem.indexOfScalar(u16, flags_s.units, 'g') == null) {
                return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.replaceAll called with a non-global RegExp argument" }});
            }
        }
        const r = try builtins.realm(rt);
        if (try object.getMethod(rt, search_arg, .{ .symbol = r.sym_replace })) |replacer| {
            return rt.callCallable(replacer, search_arg, &.{ this, common.arg(args, 1) });
        }
    }
    const s = try common.toStringObj(rt, this);
    const s_val = Value.fromString(s);
    var root_buf = [_]Value{ s_val, .undefined, common.arg(args, 1), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const search = try common.toStringObj(rt, search_arg);
    root_buf[1] = Value.fromString(search);
    const repl_arg = common.arg(args, 1);
    const is_func = repl_arg.isNative() or repl_arg.isClosure();

    const repl_str: ?*const heap_mod.String = if (!is_func) blk: {
        const rs = try common.toStringObj(rt, repl_arg);
        root_buf[3] = Value.fromString(rs);
        break :blk rs;
    } else null;

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);

    if (!is_all) {
        const pos = if (search.units.len == 0) 0 else std.mem.indexOf(u16, s.units, search.units) orelse return s_val;
        try common.appendUnits(rt, &out, s.units[0..pos]);
        if (is_func) {
            const matched = try rt.heap.newString(&.{.{ .utf16 = s.units[pos .. pos + search.units.len] }});
            root_buf[4] = Value.fromString(matched);
            const res = try rt.callCallable(repl_arg, .undefined, &.{ Value.fromString(matched), Value.fromNumber(@floatFromInt(pos)), s_val });
            const rs = try common.toStringObj(rt, res);
            root_buf[4] = Value.fromString(rs);
            try common.appendUnits(rt, &out, rs.units);
        } else {
            try expandReplacement(rt, &out, s.units, pos, search.units.len, repl_str.?.units);
        }
        try common.appendUnits(rt, &out, s.units[pos + search.units.len ..]);
        return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
    }

    if (search.units.len == 0) {
        const empty_s: ?*const heap_mod.String = if (is_func) blk: {
            const es = try rt.heap.newString(&.{});
            root_buf[3] = Value.fromString(es);
            break :blk es;
        } else null;
        for (0..s.units.len + 1) |pos| {
            if (pos > 0) try common.appendUnits(rt, &out, s.units[pos - 1 .. pos]);
            if (is_func) {
                const res = try rt.callCallable(repl_arg, .undefined, &.{ Value.fromString(empty_s.?), Value.fromNumber(@floatFromInt(pos)), s_val });
                const rs = try common.toStringObj(rt, res);
                root_buf[4] = Value.fromString(rs);
                try common.appendUnits(rt, &out, rs.units);
            } else {
                try expandReplacement(rt, &out, s.units, pos, 0, repl_str.?.units);
            }
        }
        return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
    }

    var pos: usize = 0;
    while (std.mem.indexOfPos(u16, s.units, pos, search.units)) |idx| {
        try common.appendUnits(rt, &out, s.units[pos..idx]);
        if (is_func) {
            const matched = try rt.heap.newString(&.{.{ .utf16 = s.units[idx .. idx + search.units.len] }});
            root_buf[4] = Value.fromString(matched);
            const res = try rt.callCallable(repl_arg, .undefined, &.{ Value.fromString(matched), Value.fromNumber(@floatFromInt(idx)), s_val });
            const rs = try common.toStringObj(rt, res);
            root_buf[4] = Value.fromString(rs);
            try common.appendUnits(rt, &out, rs.units);
        } else {
            try expandReplacement(rt, &out, s.units, idx, search.units.len, repl_str.?.units);
        }
        pos = idx + search.units.len;
    }
    try common.appendUnits(rt, &out, s.units[pos..]);
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn stringReplace(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return stringReplaceImpl(rt, this, args, "replace", false);
}

fn stringReplaceAll(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return stringReplaceImpl(rt, this, args, "replaceAll", true);
}

// ---------------------------------------------------------------- Object, Array

pub fn stringCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    if (args.len == 0) return Value.fromString(try rt.heap.newString(&.{}));
    if (args[0].isSymbol()) return Value.fromString(try number_math.symbolDescriptiveString(rt, args[0].asSymbol()));
    return Value.fromString(try common.toStringObj(rt, args[0]));
}

pub fn stringConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const s = if (args.len == 0) try rt.heap.newString(&.{}) else try common.toStringObj(rt, args[0]);
    var root_buf = [_]Value{Value.fromString(s)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const r = try builtins.realm(rt);
    return Value.fromObject(try rt.heap.newPrimitiveWrapper(r.string_prototype, root_buf[0]));
}

fn stringToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return Value.fromString(try thisStringExact(rt, this));
}

fn stringValueOf(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return Value.fromString(try thisStringExact(rt, this));
}

fn coerceToRegExp(rt: *Runtime, v: Value) Error!*Object {
    if (v.isObject() and v.asObject().kind == .regexp) return v.asObject();
    const created = try regexp.regexpBuild(rt, &.{v}, true);
    return created.asObject();
}

fn stringMatch(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.match called on null or undefined" }});
    }
    const rx_arg = common.arg(args, 0);
    const r = try builtins.realm(rt);
    if (rx_arg.isObjectLike()) {
        if (try object.getMethod(rt, rx_arg, .{ .symbol = r.sym_match })) |matcher| {
            return rt.callCallable(matcher, rx_arg, &.{this});
        }
    }
    const s = try common.toStringObj(rt, this);
    var root_buf = [_]Value{ Value.fromString(s), rx_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const rx_obj = try coerceToRegExp(rt, root_buf[1]);
    root_buf[2] = Value.fromObject(rx_obj);
    const matcher = try object.get(rt, root_buf[2], .{ .symbol = r.sym_match });
    root_buf[3] = matcher;
    return rt.callCallable(matcher, root_buf[2], &.{root_buf[0]});
}

fn stringMatchAll(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.matchAll called on null or undefined" }});
    }
    const rx_arg = common.arg(args, 0);
    const r = try builtins.realm(rt);
    if (rx_arg.isObjectLike()) {
        if (try regexp.isRegExp(rt, rx_arg)) {
            const flags_val = try object.get(rt, rx_arg, try object.named(rt, "flags"));
            if (flags_val.isUndefined() or flags_val.isNull()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.matchAll called with a non-global RegExp argument" }});
            }
            const flags_s = try common.toStringObj(rt, flags_val);
            if (std.mem.indexOfScalar(u16, flags_s.units, 'g') == null) {
                return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.matchAll called with a non-global RegExp argument" }});
            }
        }
        if (try object.getMethod(rt, rx_arg, .{ .symbol = r.sym_match_all })) |matcher| {
            return rt.callCallable(matcher, rx_arg, &.{this});
        }
    }
    var root_buf = [_]Value{ this, rx_arg, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try common.toStringObj(rt, this);
    root_buf[2] = Value.fromString(s);

    const g_str: Value = Value.fromString(try rt.heap.ascii("g"));
    const created = try regexp.regexpBuild(rt, &.{ rx_arg, g_str }, true);
    root_buf[3] = created;

    const matcher = try object.get(rt, created, .{ .symbol = r.sym_match_all });
    root_buf[4] = matcher;
    return rt.callCallable(matcher, created, &.{root_buf[2]});
}

fn stringSearch(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.search called on null or undefined" }});
    }
    const rx_arg = common.arg(args, 0);
    const r = try builtins.realm(rt);
    if (rx_arg.isObjectLike()) {
        if (try object.getMethod(rt, rx_arg, .{ .symbol = r.sym_search })) |searcher| {
            return rt.callCallable(searcher, rx_arg, &.{this});
        }
    }
    const s = try common.toStringObj(rt, this);
    var root_buf = [_]Value{ Value.fromString(s), rx_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const rx_obj = try coerceToRegExp(rt, root_buf[1]);
    root_buf[2] = Value.fromObject(rx_obj);
    const searcher = try object.get(rt, root_buf[2], .{ .symbol = r.sym_search });
    root_buf[3] = searcher;
    return rt.callCallable(searcher, root_buf[2], &.{root_buf[0]});
}

fn expandRegExpReplacement(
    rt: *Runtime,
    out: *std.ArrayList(u16),
    s_units: []const u16,
    captures: []const ?regex.Range,
    named_groups: []const regex.NamedGroup,
    repl_units: []const u16,
) Error!void {
    const full = captures[0].?;
    const m = captures.len - 1;
    var i: usize = 0;
    while (i < repl_units.len) {
        if (repl_units[i] == '$' and i + 1 < repl_units.len) {
            const next = repl_units[i + 1];
            switch (next) {
                '$' => {
                    try common.appendUnits(rt, out, &.{'$'});
                    i += 2;
                    continue;
                },
                '&' => {
                    try common.appendUnits(rt, out, s_units[full.start..full.end]);
                    i += 2;
                    continue;
                },
                '`' => {
                    try common.appendUnits(rt, out, s_units[0..full.start]);
                    i += 2;
                    continue;
                },
                '\'' => {
                    try common.appendUnits(rt, out, s_units[full.end..]);
                    i += 2;
                    continue;
                },
                '<' => {
                    if (named_groups.len > 0) {
                        if (std.mem.indexOfScalarPos(u16, repl_units, i + 2, '>')) |close_idx| {
                            const gname = repl_units[i + 2 .. close_idx];
                            for (named_groups) |ng| {
                                if (std.mem.eql(u16, ng.name, gname)) {
                                    if (captures[ng.capture_index]) |rng| {
                                        try common.appendUnits(rt, out, s_units[rng.start..rng.end]);
                                    }
                                    break;
                                }
                            }
                            i = close_idx + 1;
                            continue;
                        }
                    }
                },
                '0'...'9' => {
                    const d1: usize = next - '0';
                    if (i + 2 < repl_units.len and repl_units[i + 2] >= '0' and repl_units[i + 2] <= '9') {
                        const d2: usize = repl_units[i + 2] - '0';
                        const nn = d1 * 10 + d2;
                        if (nn >= 1 and nn <= m) {
                            if (captures[nn]) |rng| try common.appendUnits(rt, out, s_units[rng.start..rng.end]);
                            i += 3;
                            continue;
                        }
                    }
                    if (d1 >= 1 and d1 <= m) {
                        if (captures[d1]) |rng| try common.appendUnits(rt, out, s_units[rng.start..rng.end]);
                        i += 2;
                        continue;
                    }
                },
                else => {},
            }
        }
        try common.appendUnits(rt, out, repl_units[i .. i + 1]);
        i += 1;
    }
}

fn stringReplaceRegExp(
    rt: *Runtime,
    this: Value,
    s: *const heap_mod.String,
    rx_obj: *Object,
    repl_arg: Value,
) Error!Value {
    const is_func = repl_arg.isNative() or repl_arg.isClosure();
    var root_buf = [_]Value{ this, Value.fromObject(rx_obj), repl_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const repl_str: ?*const heap_mod.String = if (!is_func) blk: {
        const rs = try common.toStringObj(rt, repl_arg);
        root_buf[3] = Value.fromString(rs);
        break :blk rs;
    } else null;

    const named_groups = rx_obj.kind.regexp.program.named_groups;
    const is_unicode = rx_obj.kind.regexp.program.flags.isUnicodeMode();
    const is_global = rx_obj.kind.regexp.global;
    if (is_global) {
        rt.heap.storeRegExpLastIndex(rx_obj, Value.fromNumber(0));
    }

    const cap_len = @as(usize, rx_obj.kind.regexp.program.capture_count) + 1;
    var all_matches: std.ArrayList([]?regex.Range) = .empty;
    defer {
        for (all_matches.items) |m_slice| rt.gpa.free(m_slice);
        all_matches.deinit(rt.gpa);
    }

    while (true) {
        const caps = try rt.gpa.alloc(?regex.Range, cap_len);
        errdefer rt.gpa.free(caps);
        if (!try regexp.regexpExecInto(rt, rx_obj, s, caps)) {
            rt.gpa.free(caps);
            break;
        }
        try all_matches.append(rt.gpa, caps);
        if (!is_global) break;
        const rng = caps[0].?;
        if (rng.start == rng.end) {
            const this_idx = try common.toLength(rt, rx_obj.kind.regexp.last_index);
            const next_idx = regexp.advanceStringIndex(s.units, @intFromFloat(this_idx), is_unicode);
            rt.heap.storeRegExpLastIndex(rx_obj, Value.fromNumber(@floatFromInt(next_idx)));
        }
    }

    if (all_matches.items.len == 0) return this;

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);

    const has_named = named_groups.len > 0;
    const cb_arg_count = cap_len + 2 + @as(usize, if (has_named) 1 else 0);
    const cb_args: []Value = if (is_func) try rt.gpa.alloc(Value, cb_arg_count) else &.{};
    defer if (is_func) rt.gpa.free(cb_args);
    @memset(cb_args, .undefined);
    var cb_roots: rt_mod.ValueRoots = .{ .values = cb_args };
    if (is_func) try cb_roots.register(rt);
    defer if (is_func) cb_roots.unregister(rt);

    var next_src_pos: usize = 0;
    for (all_matches.items) |caps| {
        const full = caps[0].?;
        if (full.start < next_src_pos) continue;
        try common.appendUnits(rt, &out, s.units[next_src_pos..full.start]);
        if (is_func) {
            @memset(cb_args, .undefined);
            for (caps, 0..) |maybe_rng, idx| {
                if (maybe_rng) |r| {
                    cb_args[idx] = Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units[r.start..r.end] }}));
                } else {
                    cb_args[idx] = .undefined;
                }
            }
            cb_args[cap_len] = Value.fromNumber(@floatFromInt(full.start));
            cb_args[cap_len + 1] = this;
            if (has_named) {
                cb_args[cap_len + 2] = Value.fromObject(try regexp.buildMatchGroupsObject(rt, named_groups, s.units, caps));
            }
            const res = try rt.callCallable(repl_arg, .undefined, cb_args);
            root_buf[4] = res;
            const rs = try common.toStringObj(rt, res);
            root_buf[4] = Value.fromString(rs);
            try common.appendUnits(rt, &out, rs.units);
        } else {
            try expandRegExpReplacement(rt, &out, s.units, caps, named_groups, repl_str.?.units);
        }
        next_src_pos = full.end;
    }
    try common.appendUnits(rt, &out, s.units[next_src_pos..]);
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn stringSplitRegExp(
    rt: *Runtime,
    this: Value,
    s: *const heap_mod.String,
    rx_obj: *Object,
    limit_arg: Value,
) Error!Value {
    var root_buf = [_]Value{ this, Value.fromObject(rx_obj), limit_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const lim: u32 = if (limit_arg.isUndefined()) std.math.maxInt(u32) else ops.toUint32(try ops.toNumber(rt, limit_arg));
    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    root_buf[3] = Value.fromObject(out);
    if (lim == 0) return Value.fromObject(out);

    var p_split = rx_obj.kind.regexp.program;
    p_split.flags.sticky = false;
    const cap_len = @as(usize, p_split.capture_count) + 1;
    const captures = try rt.gpa.alloc(?regex.Range, cap_len);
    defer rt.gpa.free(captures);

    if (s.units.len == 0) {
        if (!try regexp.runRegExpMatcher(rt, &p_split, s.units, 0, captures)) {
            try rt.heap.appendElement(out, this);
        }
        return Value.fromObject(out);
    }

    const is_unicode = p_split.flags.isUnicodeMode();
    const size: u32 = @intCast(s.units.len);
    var p: u32 = 0;
    var q: u32 = 0;
    while (q < size) {
        if (!try regexp.runRegExpMatcher(rt, &p_split, s.units, q, captures)) break;
        const full = captures[0].?;
        if (full.end == p) {
            q = @intCast(regexp.advanceStringIndex(s.units, q, is_unicode));
            continue;
        }
        const seg = try rt.heap.newString(&.{.{ .utf16 = s.units[p..full.start] }});
        root_buf[4] = Value.fromString(seg);
        try rt.heap.appendElement(out, root_buf[4]);
        root_buf[4] = .undefined;
        if (out.kind.array.items.len == lim) return Value.fromObject(out);

        for (captures[1..]) |maybe_cap| {
            if (maybe_cap) |rng| {
                const cap_str = try rt.heap.newString(&.{.{ .utf16 = s.units[rng.start..rng.end] }});
                root_buf[4] = Value.fromString(cap_str);
                try rt.heap.appendElement(out, root_buf[4]);
                root_buf[4] = .undefined;
            } else {
                try rt.heap.appendElement(out, .undefined);
            }
            if (out.kind.array.items.len == lim) return Value.fromObject(out);
        }
        p = full.end;
        q = p;
    }

    const tail = try rt.heap.newString(&.{.{ .utf16 = s.units[p..] }});
    root_buf[4] = Value.fromString(tail);
    try rt.heap.appendElement(out, root_buf[4]);
    return Value.fromObject(out);
}

fn stringIterator(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try thisString(rt, this, "[Symbol.iterator]");
    return Value.fromObject(try rt.heap.newIterator((try builtins.realm(rt)).iterator_prototype, Value.fromString(s), .string_chars));
}

pub fn getTemplateObjectFromConsts(
    rt: *Runtime,
    key: usize,
    cooked: []const u32,
    raw: []const u32,
    consts: []const Value,
) Error!Value {
    if (rt.template_cache.get(key)) |cached| return Value.fromObject(cached);
    const r = try builtins.realm(rt);
    const arr = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ Value.fromObject(arr), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const raw_arr = try rt.heap.newArray(r.array_prototype);
    root_buf[1] = Value.fromObject(raw_arr);

    for (cooked) |k| {
        const v: Value = if (k == std.math.maxInt(u32)) .undefined else consts[k];
        try rt.heap.appendElement(arr, v);
    }
    for (raw) |k| {
        try rt.heap.appendElement(raw_arr, consts[k]);
    }
    try object.define(rt, arr, try object.named(rt, "raw"), root_buf[1]);
    try rt.template_cache.put(rt.gpa, key, arr);
    return Value.fromObject(arr);
}

pub fn getTemplateObjectFromUnits(
    rt: *Runtime,
    key: usize,
    cooked: []const ?[]const u16,
    raw: []const []const u16,
) Error!Value {
    if (rt.template_cache.get(key)) |cached| return Value.fromObject(cached);
    const r = try builtins.realm(rt);
    const arr = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ Value.fromObject(arr), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const raw_arr = try rt.heap.newArray(r.array_prototype);
    root_buf[1] = Value.fromObject(raw_arr);

    for (cooked) |maybe_u| {
        if (maybe_u) |u| {
            const s = try rt.heap.newString(&.{.{ .utf16 = u }});
            root_buf[2] = Value.fromString(s);
            try rt.heap.appendElement(arr, root_buf[2]);
            root_buf[2] = .undefined;
        } else {
            try rt.heap.appendElement(arr, .undefined);
        }
    }
    for (raw) |u| {
        const s = try rt.heap.newString(&.{.{ .utf16 = u }});
        root_buf[2] = Value.fromString(s);
        try rt.heap.appendElement(raw_arr, root_buf[2]);
        root_buf[2] = .undefined;
    }
    try object.define(rt, arr, try object.named(rt, "raw"), root_buf[1]);
    try rt.template_cache.put(rt.gpa, key, arr);
    return Value.fromObject(arr);
}

// ---------------------------------------------------------------- ArrayBuffer, TypedArray & DataView (M43, D73)
