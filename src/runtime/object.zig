//! Property semantics shared by both engines (DESIGN_DECISIONS D16, D38): get, set,
//! define, delete and `in` on any value; property keys; conversions of objects to
//! primitives. The engines only decide *when* these run; this file decides what they do.
//!
//! Keys (ToPropertyKey): a canonical array index (0 … 2^32 − 2) is `.index`, everything
//! else an atom. Arrays keep elements densely and refuse anything that would make a
//! hole (Unsupported(sparse_array), D13). Ordinary objects keep every key, index-like or
//! not, in one insertion-ordered map; `ownKeys` lists index keys first, ascending.
//!
//! Built-ins (D39): a lookup that walks into a built-in object and doesn't find the key
//! there, although node has it there, is Unsupported(builtin): ZQJS knows the name but
//! not its value or behaviour. A key node doesn't have either is a plain miss.
//!
//! Conversions (D40): an object becomes a primitive only through the built-in
//! toString/valueOf/join, implemented in Zig. If the method the spec would call has
//! been replaced by a user function, that is Unsupported(user_conversion): no native
//! ever calls back into JS in M7.

const std = @import("std");
const builtin = @import("builtin");
const Value = @import("value.zig").Value;
const heap_mod = @import("heap.zig");
const Object = heap_mod.Object;
const String = heap_mod.String;
const Property = heap_mod.Property;
const Piece = heap_mod.Piece;
const rt_mod = @import("runtime.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const ops = @import("ops.zig");
const builtins = @import("builtins.zig");
const bigint = @import("bigint.zig");
const names = @import("builtin_names.zig");

pub const Key = union(enum) {
    index: u32,
    atom: *String,
    symbol: *heap_mod.Symbol,
};

/// The largest array index (2^32 − 2); one more is the largest length.
const max_index = std.math.maxInt(u32) - 1;

// ---------------------------------------------------------------- keys

/// ToPropertyKey.
pub fn key(rt: *Runtime, v: Value) Error!Key {
    switch (v.unpack()) {
        .number => |n| {
            if (n >= 0 and n <= max_index and @floor(n) == n) return .{ .index = @intFromFloat(n) }; // -0 → 0
            var buf: ops.NumberBuf = undefined;
            return .{ .atom = try rt.heap.internAscii(ops.formatNumber(&buf, n)) };
        },
        .bigint => |b| {
            const s = try bigint.toString(rt, b, 10);
            defer rt.gpa.free(s);
            const a = try rt.heap.internAscii(s);
            return if (a.atom.?.index) |idx| .{ .index = idx } else .{ .atom = a };
        },
        .string => |s| return keyUnits(rt, s.units),
        .symbol => |s| return .{ .symbol = @constCast(s) },
        .undefined, .null, .boolean => {
            var buf: ops.NumberBuf = undefined;
            return .{ .atom = try rt.heap.internAscii((try ops.toPiece(rt, v, &buf)).ascii) };
        },
        .object => return key(rt, try toPrimitive(rt, v, .string)),
        .native, .closure => {
            const prim = try toPrimitive(rt, v, .string);
            if (prim.isFunction()) return rt.fail(.function_to_string);
            return key(rt, prim);
        },
    }
}

/// The key of a string literal (`{ 'a b': … }`).
pub fn keyUnits(rt: *Runtime, units: []const u16) Error!Key {
    const a = try rt.heap.intern(units);
    return if (a.atom.?.index) |i| .{ .index = i } else .{ .atom = a };
}

/// The key named by ASCII source text (`o.name`, `{name: …}`).
pub fn named(rt: *Runtime, text: []const u8) Error!Key {
    const a = try rt.heap.internUtf8(text);
    return namedAtom(a);
}

/// Converts a pre-interned atom into a property `Key` without hashing/lookup.
pub fn namedAtom(a: *String) Key {
    return if (a.atom.?.index) |i| .{ .index = i } else .{ .atom = a };
}

pub fn atomOf(rt: *Runtime, k: Key) Error!*String {
    return switch (k) {
        .atom => |a| a,
        .index => |i| blk: {
            var buf: [10]u8 = undefined;
            break :blk rt.heap.internAscii(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
        },
        .symbol => unreachable,
    };
}

pub fn propKey(rt: *Runtime, k: Key) Error!heap_mod.PropKey {
    return switch (k) {
        .symbol => |s| heap_mod.PropKey.fromSymbol(s),
        .atom => |a| heap_mod.PropKey.fromAtom(a),
        .index => |i| heap_mod.PropKey.fromAtom(try atomOf(rt, .{ .index = i })),
    };
}

pub fn isNamed(k: Key, text: []const u8) bool {
    const a = switch (k) {
        .atom => |a| a,
        .index, .symbol => return false,
    };
    if (a.units.len != text.len) return false;
    for (text, a.units) |c, u| if (c != u) return false;
    return true;
}

/// Whether node gives built-in `b` an own property `k` (only ASCII names can match).
fn nodeHas(b: names.Builtin, k: Key) bool {
    const a = switch (k) {
        .atom => |a| a,
        .index, .symbol => return false,
    };
    var buf: [64]u8 = undefined;
    if (a.units.len > buf.len) return false;
    for (a.units, 0..) |u, i| {
        if (u > 0x7f) return false;
        buf[i] = @intCast(u);
    }
    return names.has(b, buf[0..a.units.len]);
}

/// Unsupported(builtin), recording which member.
fn unsupportedBuiltin(rt: *Runtime, k: Key) Error {
    if (k == .symbol) return rt.fail(.builtin);
    rt.unsupported_name = try atomOf(rt, k);
    return rt.fail(.builtin);
}

/// A piece naming the key, for error messages.
fn keyPiece(k: Key, buf: *[10]u8) Piece {
    return switch (k) {
        .atom => |a| .{ .utf16 = a.units },
        .index => |i| .{ .ascii = std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable },
        .symbol => .{ .ascii = "Symbol" },
    };
}

// ---------------------------------------------------------------- get

/// `base[k]` / `base.k`.
pub fn get(rt: *Runtime, base: Value, k: Key) Error!Value {
    return getWithReceiver(rt, base, base, k);
}

/// ES GetMethod(V, P): returns null for undefined/null, throws TypeError if non-callable.
pub fn getMethod(rt: *Runtime, v: Value, k: Key) Error!?Value {
    const func = try get(rt, v, k);
    if (func.isUndefined() or func.isNull()) return null;
    if (!func.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Property is not a function" }});
    }
    return func;
}

pub fn getWithReceiver(rt: *Runtime, base: Value, receiver: Value, k: Key) Error!Value {
    heap_mod.checkValue(base);
    switch (base.unpack()) {
        .undefined, .null => {
            var buf: [10]u8 = undefined;
            return rt.throw(.TypeError, &.{ .{ .ascii = "Cannot read properties of " }, .{ .ascii = @tagName(base.tag()) }, .{ .ascii = " (reading '" }, keyPiece(k, &buf), .{ .ascii = "')" } });
        },
        .string => |s| {
            switch (k) {
                .index => |i| if (i < s.units.len) return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units[i..][0..1] }})),
                .atom => if (isNamed(k, "length")) return Value.fromNumber(@floatFromInt(s.units.len)),
                .symbol => {},
            }
            const r = try builtins.realm(rt);
            return getFrom(rt, r.string_prototype, receiver, k);
        },
        .symbol => return getFrom(rt, (try builtins.realm(rt)).symbol_prototype, receiver, k),
        .bigint => return getFrom(rt, (try builtins.realm(rt)).bigint_prototype, receiver, k),
        .number => return getFrom(rt, (try builtins.realm(rt)).number_prototype, receiver, k),
        .boolean => return getFrom(rt, (try builtins.realm(rt)).boolean_prototype, receiver, k),
        .object => |o| return getFrom(rt, o, receiver, k),
        .native => |n| {
            if (isNamed(k, "name") and !rt.isNativePropDeleted(n, false)) return Value.fromString(try rt.heap.ascii(n.name));
            if (isNamed(k, "length") and !rt.isNativePropDeleted(n, true)) return Value.fromNumber(@floatFromInt(n.length));
            if (try builtins.namespaceObject(rt, n)) |ns| {
                if (try ownProp(rt, ns, k)) |p| return resolvePropValue(rt, receiver, p);
                if (ns.builtin) |b| if (nodeHas(b, k)) return unsupportedBuiltin(rt, k);
            }
            return getWithReceiver(rt, try builtins.nativeProto(rt, n), receiver, k);
        },
        .closure => |c| {
            if (isNamed(k, "name")) return Value.fromString(try builtins.closureName(rt, c));
            if (isNamed(k, "length")) return Value.fromNumber(@floatFromInt(builtins.closureLength(c)));
            if (isNamed(k, "prototype")) {
                if (c.meta) |m| if (m.prototype) |p| return p;
                if (builtins.hasAutoPrototype(c)) {
                    return Value.fromObject(try builtins.materializeClosurePrototype(rt, @constCast(c)));
                }
            }
            if (c.meta) |m| if (m.props.count() > 0) {
                if (m.props.get(try propKey(rt, k))) |p| return resolvePropValue(rt, receiver, p);
            };
            if (c.meta) |m| if (m.proto) |p| return getWithReceiver(rt, p, receiver, k);
            return getFrom(rt, try builtins.closureDefaultProto(rt, c), receiver, k);
        },
    }
}

pub fn getPrototypeOfValue(rt: *Runtime, v: Value) Error!Value {
    return switch (v.unpack()) {
        .object => |o| if (o.kind == .proxy) builtins.proxyGetPrototypeOf(rt, o) else if (o.proto) |p| Value.fromObject(p) else .null,
        .closure => |c| if (c.meta) |m| (m.proto orelse Value.fromObject(try builtins.closureDefaultProto(rt, c))) else Value.fromObject(try builtins.closureDefaultProto(rt, c)),
        .native => |n| try builtins.nativeProto(rt, n),
        .symbol => Value.fromObject((try builtins.realm(rt)).symbol_prototype),
        .bigint => Value.fromObject((try builtins.realm(rt)).bigint_prototype),
        else => .null,
    };
}

pub fn getSuper(rt: *Runtime, home: Value, receiver: Value, k: Key) Error!Value {
    const proto = try getPrototypeOfValue(rt, home);
    if (proto.isNull() or proto.isUndefined()) return .undefined;
    return getWithReceiver(rt, proto, receiver, k);
}

fn resolvePropValue(rt: *Runtime, receiver: Value, p: Property) Error!Value {
    if (!p.is_accessor) return p.value;
    if (p.value.isUndefined()) return .undefined;
    return rt.callCallable(p.value, receiver, &.{});
}

/// [[Get]] along the prototype chain (cycles can't be built: see Object.proto).
fn getFrom(rt: *Runtime, start: *Object, receiver: Value, k: Key) Error!Value {
    var o: ?*Object = start;
    while (o) |cur| : (o = cur.proto) {
        cur.obj.checkLive(); // stress builds: a collected object or prototype
        if (cur.kind == .proxy) {
            return builtins.proxyGet(rt, cur, k, receiver);
        }
        if (cur.kind == .typed_array) {
            if (canonicalNumericIndex(k)) |n| {
                if (validIntegerIndex(cur.kind.typed_array, n)) |idx| {
                    return readTypedArrayElement(rt, cur.kind.typed_array, idx);
                }
                return .undefined;
            }
        }
        if (try ownProp(rt, cur, k)) |p| return resolvePropValue(rt, receiver, p);
        if (cur.builtin) |b| if (nodeHas(b, k)) return unsupportedBuiltin(rt, k);
    }
    return .undefined;
}

pub fn ownProp(rt: *Runtime, o: *Object, k: Key) Error!?Property {
    switch (o.kind) {
        .array => |elements| switch (k) {
            .index => |i| return if (i < elements.items.len) .{
                .value = elements.items[i],
                .writable = o.array_elements_writable,
                .configurable = o.array_elements_configurable,
            } else null,
            .atom => if (isNamed(k, "length")) return .{
                .value = Value.fromNumber(@floatFromInt(elements.items.len)),
                .enumerable = false,
                .writable = o.array_length_writable,
                .configurable = false,
            },
            .symbol => {},
        },
        .map, .set => |table| if (isNamed(k, "size")) return .{ .value = Value.fromNumber(@floatFromInt(table.live_count)), .enumerable = false, .writable = false },
        .regexp => |re| {
            if (isNamed(k, "lastIndex")) return .{
                .value = re.last_index,
                .enumerable = false,
                .writable = o.regexp_last_index_writable,
                .configurable = false,
            };
            if (isNamed(k, "source")) return .{ .value = Value.fromString(re.source), .enumerable = false, .writable = false };
            if (isNamed(k, "flags")) return .{ .value = Value.fromString(re.flags), .enumerable = false, .writable = false };
            if (isNamed(k, "hasIndices")) return .{ .value = Value.fromBool(re.program.flags.has_indices), .enumerable = false, .writable = false };
            if (isNamed(k, "global")) return .{ .value = Value.fromBool(re.global), .enumerable = false, .writable = false };
            if (isNamed(k, "ignoreCase")) return .{ .value = Value.fromBool(re.program.flags.ignore_case), .enumerable = false, .writable = false };
            if (isNamed(k, "multiline")) return .{ .value = Value.fromBool(re.program.flags.multiline), .enumerable = false, .writable = false };
            if (isNamed(k, "dotAll")) return .{ .value = Value.fromBool(re.program.flags.dot_all), .enumerable = false, .writable = false };
            if (isNamed(k, "unicode")) return .{ .value = Value.fromBool(re.program.flags.unicode), .enumerable = false, .writable = false };
            if (isNamed(k, "unicodeSets")) return .{ .value = Value.fromBool(re.program.flags.unicode_sets), .enumerable = false, .writable = false };
            if (isNamed(k, "sticky")) return .{ .value = Value.fromBool(re.program.flags.sticky), .enumerable = false, .writable = false };
        },
        .module_namespace => |ns| {
            if (k == .atom) {
                for (ns.entries) |e| {
                    if (e.name == k.atom) {
                        const v = e.cell.value orelse return rt.throw(.ReferenceError, &.{
                            .{ .ascii = "Cannot access '" },
                            .{ .utf16 = e.name.units },
                            .{ .ascii = "' before initialization" },
                        });
                        return .{ .value = v, .enumerable = true, .writable = true, .configurable = false };
                    }
                }
            }
        },
        .typed_array => |ta| {
            if (canonicalNumericIndex(k)) |n| {
                if (validIntegerIndex(ta, n)) |idx| {
                    return .{
                        .value = try readTypedArrayElement(rt, ta, idx),
                        .enumerable = true,
                        .writable = true,
                        .configurable = true,
                    };
                }
                return null;
            }
        },
        .primitive_wrapper => |pv| if (pv.isString()) {
            const s = pv.asString();
            switch (k) {
                .index => |i| if (i < s.units.len) return .{
                    .value = Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units[i..][0..1] }})),
                    .enumerable = true,
                    .writable = false,
                    .configurable = false,
                },
                .atom => if (isNamed(k, "length")) return .{
                    .value = Value.fromNumber(@floatFromInt(s.units.len)),
                    .enumerable = false,
                    .writable = false,
                    .configurable = false,
                },
                .symbol => {},
            }
        },
        .ordinary, .iterator, .promise, .generator, .array_buffer, .data_view, .weak_map, .weak_set, .proxy, .date => {},
    }
    if (o.props.count() > 0) {
        if (o.props.get(try propKey(rt, k))) |p| return p;
    }
    if (o.builtin == .global and k == .atom) {
        return builtins.globalOwnProp(rt, k.atom);
    }
    return null;
}

fn isRegExpGetter(k: Key) bool {
    return isNamed(k, "source") or
        isNamed(k, "flags") or
        isNamed(k, "hasIndices") or
        isNamed(k, "global") or
        isNamed(k, "ignoreCase") or
        isNamed(k, "multiline") or
        isNamed(k, "dotAll") or
        isNamed(k, "unicode") or
        isNamed(k, "unicodeSets") or
        isNamed(k, "sticky");
}

/// Own lookup that never allocates (atoms only; for built-in tables).
fn own(o: *Object, k: Key) ?Value {
    const a = switch (k) {
        .atom => |a| a,
        .index, .symbol => return null,
    };
    return if (o.props.get(heap_mod.PropKey.fromAtom(a))) |p| p.value else null;
}

// ---------------------------------------------------------------- set, define, delete

const ChainHit = union(enum) {
    none,
    accessor: Property,
    data: struct { is_own: bool, writable: bool },
    proxy: *Object,
};

fn sameTarget(a: Value, b: ?Value) bool {
    const bv = b orelse return false;
    return switch (a.unpack()) {
        .object => |ao| bv.isObject() and bv.asObject() == ao,
        .closure => |ac| bv.isClosure() and bv.asClosure() == ac,
        else => false,
    };
}

fn lookupSetChain(rt: *Runtime, start: Value, base: ?Value, k: Key) Error!ChainHit {
    var cur: Value = start;
    while (true) {
        switch (cur.unpack()) {
            .object => |o| {
                o.obj.checkLive();
                if (o.kind == .proxy) return .{ .proxy = o };
                if (try ownProp(rt, o, k)) |p| {
                    if (p.is_accessor) return .{ .accessor = p };
                    return .{ .data = .{ .is_own = sameTarget(cur, base), .writable = p.writable } };
                }
                cur = if (o.proto) |p| Value.fromObject(p) else return .none;
            },
            .closure => |c| {
                c.obj.checkLive();
                if (isNamed(k, "name") or isNamed(k, "length")) {
                    return .{ .data = .{ .is_own = sameTarget(cur, base), .writable = false } };
                }
                if (isNamed(k, "prototype") and builtins.hasAutoPrototype(c)) {
                    const writable = if (c.meta) |m| m.prototype_writable else true;
                    return .{ .data = .{ .is_own = sameTarget(cur, base), .writable = writable } };
                }
                if (c.meta) |m| {
                    if (m.props.count() > 0) {
                        if (m.props.get(try propKey(rt, k))) |p| {
                            if (p.is_accessor) return .{ .accessor = p };
                            return .{ .data = .{ .is_own = sameTarget(cur, base), .writable = p.writable } };
                        }
                    }
                    if (m.proto) |p| {
                        cur = p;
                        continue;
                    }
                }
                cur = Value.fromObject(try builtins.closureDefaultProto(rt, c));
            },
            else => return .none,
        }
    }
}

fn invokeSetter(rt: *Runtime, p: Property, receiver: Value, v: Value, strict: bool) Error!bool {
    if (p.setter.isUndefined()) {
        if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot set property which has only a getter" }});
        return false;
    }
    _ = try rt.callCallable(p.setter, receiver, &.{v});
    return true;
}

/// `base[k] = v` with prototype accessor/writable checks (D64).
pub fn set(rt: *Runtime, base: Value, k: Key, v: Value) Error!void {
    _ = try setWithReceiver(rt, base, k, v, base, false);
}

/// Strict-mode `base[k] = v` (throws `TypeError` on non-writable/non-extensible targets).
pub fn setStrict(rt: *Runtime, base: Value, k: Key, v: Value) Error!void {
    _ = try setWithReceiver(rt, base, k, v, base, true);
}

pub fn setWithReceiver(rt: *Runtime, base: Value, k: Key, v: Value, receiver: Value, strict: bool) Error!bool {
    switch (base.unpack()) {
        .undefined, .null => {
            var buf: [10]u8 = undefined;
            return rt.throw(.TypeError, &.{ .{ .ascii = "Cannot set properties of " }, .{ .ascii = @tagName(base.tag()) }, .{ .ascii = " (setting '" }, keyPiece(k, &buf), .{ .ascii = "')" } });
        },
        .string, .number, .boolean, .symbol, .bigint => return if (strict) rt.throw(.TypeError, &.{.{ .ascii = "Cannot create property on primitive" }}) else rt.fail(.primitive_write),
        .native => |n| {
            if (isNamed(k, "__proto__")) return unsupportedBuiltin(rt, k);
            if ((isNamed(k, "name") and !rt.isNativePropDeleted(n, false)) or
                (isNamed(k, "length") and !rt.isNativePropDeleted(n, true)))
            {
                if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property" }});
                return false;
            }
            if (try builtins.namespaceObject(rt, n)) |ns| {
                return setWithReceiver(rt, Value.fromObject(ns), k, v, Value.fromObject(ns), strict);
            }
            return rt.fail(.function_properties);
        },
        .closure => |c| {
            if (isNamed(k, "__proto__")) return unsupportedBuiltin(rt, k);
            if (isNamed(k, "name") or isNamed(k, "length")) {
                if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property" }});
                return false;
            }
            if (isNamed(k, "prototype") and builtins.hasAutoPrototype(c)) {
                if (c.meta) |m| if (!m.prototype_writable) {
                    if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property 'prototype'" }});
                    return false;
                };
                if (sameTarget(base, receiver)) {
                    try rt.heap.storeClosurePrototype(@constCast(c), v);
                    return true;
                }
            }
        },
        .object => |o| {
            if (o.kind == .proxy) {
                const ok = try builtins.proxySet(rt, o, k, v, receiver);
                if (!ok and strict) return rt.throw(.TypeError, &.{.{ .ascii = "'set' on proxy: trap returned falsish" }});
                return ok;
            }
            if (isNamed(k, "__proto__")) return unsupportedBuiltin(rt, k);
            if (o.kind == .typed_array) {
                if (canonicalNumericIndex(k)) |n| {
                    if (o.kind.typed_array.kind.isBigInt()) {
                        const b = try ops.toBigInt(rt, v);
                        if (validIntegerIndex(o.kind.typed_array, n)) |idx| {
                            writeTypedArrayBigInt(o.kind.typed_array, idx, b);
                        }
                    } else {
                        const num = try ops.toNumber(rt, v);
                        if (validIntegerIndex(o.kind.typed_array, n)) |idx| {
                            writeTypedArrayNumber(o.kind.typed_array, idx, num);
                        }
                    }
                    return true;
                }
            }
        },
    }
    switch (try lookupSetChain(rt, base, base, k)) {
        .proxy => |px_obj| {
            const ok = try builtins.proxySet(rt, px_obj, k, v, receiver);
            if (!ok and strict) return rt.throw(.TypeError, &.{.{ .ascii = "'set' on proxy: trap returned falsish" }});
            return ok;
        },
        .accessor => |p| return invokeSetter(rt, p, receiver, v, strict),
        .data => |d| if (!d.writable) {
            if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property" }});
            return false; // sloppy-mode no-op on non-writable property
        },
        .none => {},
    }
    if (!sameTarget(base, receiver)) {
        if (!receiver.isObjectLike()) {
            if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot create property on primitive" }});
            return false;
        }
        return builtins.ordinarySetWithReceiver(rt, receiver, k, v, strict);
    }
    return setOwnData(rt, base, k, v, strict);
}

pub fn setSuper(rt: *Runtime, home: Value, receiver: Value, k: Key, v: Value) Error!void {
    const proto = try getPrototypeOfValue(rt, home);
    if (!proto.isNull() and !proto.isUndefined()) {
        switch (try lookupSetChain(rt, proto, null, k)) {
            .proxy => |px_obj| {
                _ = try builtins.proxySet(rt, px_obj, k, v, receiver);
                return;
            },
            .accessor => |p| {
                _ = try invokeSetter(rt, p, receiver, v, false);
                return;
            },
            .data => |d| if (!d.writable) return,
            .none => {},
        }
    }
    // Check own property on receiver before writing own data property.
    switch (receiver.unpack()) {
        .object => |o| {
            if (o.kind == .proxy) {
                _ = try builtins.ordinarySetWithReceiver(rt, receiver, k, v, false);
                return;
            }
            if (try ownProp(rt, o, k)) |p| {
                if (p.is_accessor) {
                    _ = try invokeSetter(rt, p, receiver, v, false);
                    return;
                }
                if (!p.writable) return;
            }
        },
        .closure => |c| {
            if (isNamed(k, "name") or isNamed(k, "length")) return;
            if (c.meta) |m| if (m.props.get(try propKey(rt, k))) |p| {
                if (p.is_accessor) {
                    _ = try invokeSetter(rt, p, receiver, v, false);
                    return;
                }
                if (!p.writable) return;
            };
        },
        .undefined, .null => {
            var buf: [10]u8 = undefined;
            return rt.throw(.TypeError, &.{ .{ .ascii = "Cannot set properties of " }, .{ .ascii = @tagName(receiver.tag()) }, .{ .ascii = " (setting '" }, keyPiece(k, &buf), .{ .ascii = "')" } });
        },
        else => return rt.fail(.primitive_write),
    }
    _ = try setOwnData(rt, receiver, k, v, false);
}

fn setOwnData(rt: *Runtime, base: Value, k: Key, v: Value, strict: bool) Error!bool {
    switch (base.unpack()) {
        .closure => |c| {
            const pk = try propKey(rt, k);
            if (c.meta) |m| if (!m.extensible and !m.props.contains(pk)) {
                if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot add property, object is not extensible" }});
                return false;
            };
            try rt.heap.storeClosurePropKey(@constCast(c), pk, v);
            return true;
        },
        .object => |o| {
            switch (o.kind) {
                .array => |elements| switch (k) {
                    .index => |i| {
                        if (i < elements.items.len) {
                            if (!o.array_elements_writable) {
                                if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property" }});
                                return false;
                            }
                            rt.heap.storeElement(o, i, v);
                        } else if (i == elements.items.len) {
                            if (!o.extensible or !o.array_length_writable) {
                                if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot add property, object is not extensible" }});
                                return false;
                            }
                            try rt.heap.appendElement(o, v);
                        } else return rt.fail(.sparse_array);
                        return true;
                    },
                    .atom => if (isNamed(k, "length")) return setLength(rt, o, v, strict),
                    .symbol => {},
                },
                .map, .set => if (isNamed(k, "size")) {
                    if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot set property size" }});
                    return false; // Map/Set size is a read-only getter
                },
                .regexp => {
                    if (isNamed(k, "lastIndex")) {
                        if (!o.regexp_last_index_writable) {
                            if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property 'lastIndex'" }});
                            return false;
                        }
                        rt.heap.storeRegExpLastIndex(o, v);
                        return true;
                    }
                    if (isRegExpGetter(k)) {
                        if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property" }});
                        return false;
                    }
                },
                .module_namespace => {
                    if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property of module namespace" }});
                    return false;
                },
                .typed_array => |ta| {
                    if (canonicalNumericIndex(k)) |n| {
                        if (ta.kind.isBigInt()) {
                            const b = try ops.toBigInt(rt, v);
                            if (validIntegerIndex(ta, n)) |idx| writeTypedArrayBigInt(ta, idx, b);
                        } else {
                            const num = try ops.toNumber(rt, v);
                            if (validIntegerIndex(ta, n)) |idx| writeTypedArrayNumber(ta, idx, num);
                        }
                        return true;
                    }
                },
                .ordinary, .iterator, .promise, .generator, .array_buffer, .data_view, .weak_map, .weak_set, .proxy, .date, .primitive_wrapper => {},
            }
            const pk = try propKey(rt, k);
            if (!o.extensible and !o.props.contains(pk)) {
                if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot add property, object is not extensible" }});
                return false;
            }
            try rt.heap.storePropKey(o, pk, v);
            return true;
        },
        else => unreachable,
    }
}

/// CreateDataProperty for literals: like `set` on a fresh ordinary object, but `__proto__`
/// is an ordinary key here (only the non-computed literal form is special; the parser
/// reports that one).
pub fn define(rt: *Runtime, o: *Object, k: Key, v: Value) Error!void {
    try putOwn(rt, o, k, v);
}

pub fn defineNonEnumerable(rt: *Runtime, target: Value, k: Key, v: Value) Error!void {
    const pk = try propKey(rt, k);
    switch (target.unpack()) {
        .object => |o| try rt.heap.definePropKey(o, pk, .{ .value = v, .enumerable = false }),
        .closure => |c| try rt.heap.defineClosurePropKey(@constCast(c), pk, .{ .value = v, .enumerable = false }),
        else => unreachable,
    }
}

pub fn defineAccessor(rt: *Runtime, target: Value, k: Key, fn_val: Value, is_setter: bool, enumerable: bool) Error!void {
    const pk = try propKey(rt, k);
    const existing: ?Property = switch (target.unpack()) {
        .object => |o| o.props.get(pk),
        .closure => |c| if (c.meta) |m| m.props.get(pk) else null,
        else => unreachable,
    };
    const keep_other = existing != null and existing.?.is_accessor;
    const prop: Property = .{
        .is_accessor = true,
        .value = if (is_setter) (if (keep_other) existing.?.value else .undefined) else fn_val,
        .setter = if (is_setter) fn_val else (if (keep_other) existing.?.setter else .undefined),
        .enumerable = enumerable,
        .configurable = true,
        .writable = false,
    };
    switch (target.unpack()) {
        .object => |o| try rt.heap.definePropKey(o, pk, prop),
        .closure => |c| try rt.heap.defineClosurePropKey(@constCast(c), pk, prop),
        else => unreachable,
    }
}

pub fn definePublicField(rt: *Runtime, target: Value, k: Key, v: Value) Error!void {
    const pk = try propKey(rt, k);
    const prop: Property = .{ .value = v, .enumerable = true, .writable = true, .configurable = true };
    switch (target.unpack()) {
        .object => |o| try rt.heap.definePropKey(o, pk, prop),
        .closure => |c| try rt.heap.defineClosurePropKey(@constCast(c), pk, prop),
        else => unreachable,
    }
}

fn privateLookup(target: Value, pk: heap_mod.PrivateKey) ?Property {
    return switch (target.unpack()) {
        .object => |o| if (o.private_props) |pp| pp.get(pk) else null,
        .closure => |c| if (c.meta) |m| m.private_props.get(pk) else null,
        else => null,
    };
}

pub fn definePrivateField(rt: *Runtime, target: Value, brand: *const heap_mod.Closure, name_str: *String, v: Value) Error!void {
    const pk: heap_mod.PrivateKey = .{ .brand = @constCast(brand), .name = name_str };
    if (privateLookup(target, pk) != null) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot initialize private member twice on the same object" }});
    }
    try rt.heap.definePrivateProperty(target, pk, .{ .value = v, .enumerable = false, .writable = true, .configurable = false });
}

pub fn definePrivateMethod(rt: *Runtime, target: Value, brand: *const heap_mod.Closure, name_str: *String, fn_val: Value) Error!void {
    const pk: heap_mod.PrivateKey = .{ .brand = @constCast(brand), .name = name_str };
    if (privateLookup(target, pk) != null) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot initialize private member twice on the same object" }});
    }
    try rt.heap.definePrivateProperty(target, pk, .{ .value = fn_val, .enumerable = false, .writable = false, .configurable = false });
}

pub fn definePrivateAccessor(rt: *Runtime, target: Value, brand: *const heap_mod.Closure, name_str: *String, fn_val: Value, is_setter: bool) Error!void {
    const pk: heap_mod.PrivateKey = .{ .brand = @constCast(brand), .name = name_str };
    const existing = privateLookup(target, pk);
    const keep_other = existing != null and existing.?.is_accessor;
    const prop: Property = .{
        .is_accessor = true,
        .value = if (is_setter) (if (keep_other) existing.?.value else .undefined) else fn_val,
        .setter = if (is_setter) fn_val else (if (keep_other) existing.?.setter else .undefined),
        .enumerable = false,
        .configurable = false,
        .writable = false,
    };
    try rt.heap.definePrivateProperty(target, pk, prop);
}

pub fn getPrivate(rt: *Runtime, base: Value, brand: *const heap_mod.Closure, name_str: *String) Error!Value {
    heap_mod.checkValue(base);
    if (base.isNullish()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot read private member from undefined or null" }});
    }
    const pk: heap_mod.PrivateKey = .{ .brand = @constCast(brand), .name = name_str };
    const p = privateLookup(base, pk) orelse {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot read private member from an object whose class did not declare it" }});
    };
    return resolvePropValue(rt, base, p);
}

pub fn setPrivate(rt: *Runtime, base: Value, brand: *const heap_mod.Closure, name_str: *String, v: Value) Error!void {
    heap_mod.checkValue(base);
    if (base.isNullish()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot write private member to undefined or null" }});
    }
    const pk: heap_mod.PrivateKey = .{ .brand = @constCast(brand), .name = name_str };
    const p = privateLookup(base, pk) orelse {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot write private member to an object whose class did not declare it" }});
    };
    if (p.is_accessor) {
        if (p.setter.isUndefined()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Private property has only a getter" }});
        }
        _ = try rt.callCallable(p.setter, base, &.{v});
        return;
    }
    if (!p.writable) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Private method is not writable" }});
    }
    rt.heap.updatePrivateProperty(base, pk, v);
}

pub fn hasPrivate(rt: *Runtime, base: Value, brand: *const heap_mod.Closure, name_str: *String) Error!bool {
    heap_mod.checkValue(base);
    if (!base.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot use 'in' operator to search for private member in a non-object" }});
    }
    return privateLookup(base, .{ .brand = @constCast(brand), .name = name_str }) != null;
}

fn putOwn(rt: *Runtime, o: *Object, k: Key, v: Value) Error!void {
    try rt.heap.storePropKey(o, try propKey(rt, k), v);
}

fn setLength(rt: *Runtime, arr: *Object, v: Value, strict: bool) Error!bool {
    const n = try ops.toNumber(rt, v);
    if (!(n >= 0 and n <= max_index + 1 and @floor(n) == n)) return rt.throw(.RangeError, &.{.{ .ascii = "Invalid array length" }});
    const len: usize = @intFromFloat(n);
    const cur_len = arr.kind.array.items.len;
    if (!arr.array_length_writable) {
        if (len == cur_len) return true;
        if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property 'length'" }});
        return false;
    }
    if (len > cur_len) return rt.fail(.sparse_array);
    if (!arr.array_elements_configurable and len < cur_len) {
        if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property of non-configurable array" }});
        return false;
    }
    rt.heap.shrinkElements(arr, len);
    return true;
}

/// `delete base[k]`.
pub fn delete(rt: *Runtime, base: Value, k: Key) Error!bool {
    heap_mod.checkValue(base);
    const o = switch (base.unpack()) {
        .undefined, .null => return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }}),
        .string, .number, .boolean, .symbol, .bigint => return rt.fail(.primitive_write),
        .native => |n| {
            if (isNamed(k, "name")) {
                try rt.setNativePropDeleted(n, false, true);
                return true;
            }
            if (isNamed(k, "length")) {
                try rt.setNativePropDeleted(n, true, true);
                return true;
            }
            if (try builtins.namespaceObject(rt, n)) |ns| {
                return delete(rt, Value.fromObject(ns), k);
            }
            return true;
        },
        .closure => |c| {
            if (isNamed(k, "name")) return if (c.meta) |m| m.name_configurable else true;
            if (isNamed(k, "length")) return if (c.meta) |m| m.length_configurable else true;
            if (isNamed(k, "prototype") and builtins.hasAutoPrototype(c)) return false;
            if (c.meta == null or c.meta.?.props.count() == 0) return true;
            const pk = try propKey(rt, k);
            if (c.meta.?.props.get(pk)) |p| if (!p.configurable) return false;
            rt.heap.removeClosurePropKey(@constCast(c), pk);
            return true;
        },
        .object => |o| o,
    };
    switch (o.kind) {
        .array => |elements| switch (k) {
            // Deleting an element leaves a hole; deleting past the end does nothing.
            .index => |i| {
                if (i < elements.items.len) {
                    if (!o.array_elements_configurable) return false;
                    return rt.fail(.sparse_array);
                }
                return true;
            },
            .atom => if (isNamed(k, "length")) return false, // non-configurable
            .symbol => {},
        },
        .regexp => if (isNamed(k, "lastIndex")) return false, // non-configurable
        .module_namespace => return false,
        .typed_array => |ta| {
            if (canonicalNumericIndex(k)) |n| {
                return validIntegerIndex(ta, n) == null;
            }
        },
        .proxy => return builtins.proxyDeleteProperty(rt, o, k),
        .primitive_wrapper => |pv| if (pv.isString()) {
            const s = pv.asString();
            switch (k) {
                .index => |i| if (i < s.units.len) return false,
                .atom => if (isNamed(k, "length")) return false,
                .symbol => {},
            }
        },
        .ordinary, .map, .set, .iterator, .promise, .generator, .array_buffer, .data_view, .weak_map, .weak_set, .date => {},
    }
    if (o.props.count() == 0) return true;
    const pk = try propKey(rt, k);
    if (o.props.get(pk)) |p| if (!p.configurable) return false;
    try rt.heap.removePropKey(o, pk);
    return true;
}

/// Own property check (`Object.hasOwn` / `hasOwnProperty`).
pub fn hasOwn(rt: *Runtime, base: Value, k: Key) Error!bool {
    heap_mod.checkValue(base);
    return switch (base.unpack()) {
        .object => |o| if (o.kind == .proxy) (try builtins.proxyGetOwnPropertyDescriptor(rt, o, k)) != null else (try ownProp(rt, o, k)) != null,
        .closure => |c| {
            if (isNamed(k, "name") or isNamed(k, "length")) return true;
            if (isNamed(k, "prototype") and builtins.hasAutoPrototype(c)) return true;
            if (c.meta) |m| if (m.props.count() > 0) return m.props.contains(try propKey(rt, k));
            return false;
        },
        .native => |n| {
            if (isNamed(k, "name") and !rt.isNativePropDeleted(n, false)) return true;
            if (isNamed(k, "length") and !rt.isNativePropDeleted(n, true)) return true;
            if (try builtins.namespaceObject(rt, n)) |ns| return (try ownProp(rt, ns, k)) != null;
            return false;
        },
        .string => |s| switch (k) {
            .index => |i| i < s.units.len,
            .atom => isNamed(k, "length"),
            .symbol => false,
        },
        .number, .boolean, .symbol, .bigint => false,
        .undefined, .null => rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }}),
    };
}

/// `k in base`.
pub fn has(rt: *Runtime, k: Key, base: Value) Error!bool {
    heap_mod.checkValue(base);
    const start: *Object = switch (base.unpack()) {
        .object => |o| o,
        .native => |n| {
            if (isNamed(k, "name") and !rt.isNativePropDeleted(n, false)) return true;
            if (isNamed(k, "length") and !rt.isNativePropDeleted(n, true)) return true;
            if (try builtins.namespaceObject(rt, n)) |ns| {
                if (try ownProp(rt, ns, k) != null) return true;
                if (ns.builtin) |b| if (nodeHas(b, k)) return true;
            }
            return has(rt, k, try builtins.nativeProto(rt, n));
        },
        .closure => |c| {
            if (isNamed(k, "name") or isNamed(k, "length")) return true;
            if (isNamed(k, "prototype") and builtins.hasAutoPrototype(c)) return true;
            if (c.meta) |m| if (m.props.count() > 0) if (m.props.contains(try propKey(rt, k))) return true;
            if (c.meta) |m| if (m.proto) |p| return has(rt, k, p);
            return hasInChain(rt, try builtins.closureDefaultProto(rt, c), k);
        },
        else => {
            var buf: [10]u8 = undefined;
            return rt.throw(.TypeError, &.{ .{ .ascii = "Cannot use 'in' operator to search for '" }, keyPiece(k, &buf), .{ .ascii = "' in a non-object" } });
        },
    };
    return hasInChain(rt, start, k);
}

fn hasInChain(rt: *Runtime, start: *Object, k: Key) Error!bool {
    var o: ?*Object = start;
    while (o) |cur| : (o = cur.proto) {
        if (cur.kind == .proxy) {
            return builtins.proxyHas(rt, cur, k);
        }
        if (cur.kind == .typed_array) {
            if (canonicalNumericIndex(k)) |n| {
                return validIntegerIndex(cur.kind.typed_array, n) != null;
            }
        }
        if (try ownProp(rt, cur, k) != null) return true;
        // node has it there, so the answer is known even if the value isn't.
        if (cur.builtin) |b| if (nodeHas(b, k)) return true;
    }
    return false;
}

/// `lhs instanceof rhs` (ES InstanceofOperator).
pub fn instanceOf(rt: *Runtime, lhs: Value, rhs: Value) Error!bool {
    heap_mod.checkValue(lhs);
    heap_mod.checkValue(rhs);
    if (!rhs.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Right-hand side of 'instanceof' is not an object" }});
    }
    const r = try builtins.realm(rt);
    var roots_buf = [_]Value{ lhs, rhs };
    var roots = rt_mod.ValueRoots{ .values = &roots_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (try getMethod(rt, rhs, .{ .symbol = r.sym_has_instance })) |handler| {
        if (handler.isNative() and handler.asNative() == &builtins.function_has_instance) {
            return ordinaryHasInstance(rt, rhs, lhs);
        }
        const res = try rt.callCallable(handler, rhs, &.{lhs});
        return ops.toBoolean(res);
    }
    if (!rhs.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Right-hand side of 'instanceof' is not callable" }});
    }
    return ordinaryHasInstance(rt, rhs, lhs);
}

/// ES OrdinaryHasInstance(C, O).
pub fn ordinaryHasInstance(rt: *Runtime, c_val: Value, o_val: Value) Error!bool {
    if (!c_val.isFunction()) return false;
    if (c_val.isClosure() and c_val.asClosure().impl == .bound) {
        return instanceOf(rt, o_val, c_val.asClosure().impl.bound.target);
    }
    if (!o_val.isObjectLike()) return false;
    const target_proto: *Object = switch (c_val.unpack()) {
        .native => |n| (try builtins.constructorPrototype(rt, n)) orelse
            return rt.throw(.TypeError, &.{.{ .ascii = "Function has non-object prototype 'undefined' in instanceof check" }}),
        .closure => blk: {
            var roots_buf = [_]Value{o_val};
            var roots = rt_mod.ValueRoots{ .values = &roots_buf };
            try roots.register(rt);
            defer roots.unregister(rt);
            const proto_val = try get(rt, c_val, try named(rt, "prototype"));
            if (!proto_val.isObject()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "Function has non-object prototype in instanceof check" }});
            }
            break :blk proto_val.asObject();
        },
        else => unreachable,
    };
    var cur: Value = try getPrototypeOfValue(rt, o_val);
    while (!cur.isNull()) : (cur = try getPrototypeOfValue(rt, cur)) {
        if (cur.isObject()) {
            cur.asObject().obj.checkLive();
            if (cur.asObject() == target_proto) return true;
        }
    }
    return false;
}

fn appendPropsKeys(
    rt: *Runtime,
    out: *std.ArrayList(Key),
    prop_keys: []const heap_mod.PropKey,
    prop_vals: []const Property,
    first_named: usize,
    include_symbols: bool,
    include_non_enum: bool,
) Error!void {
    for (prop_keys, prop_vals) |pk, p| {
        if ((!include_non_enum and !p.enumerable) or pk.isSymbol()) continue;
        const a = pk.asAtom();
        if (a.atom.?.index) |i| {
            try out.insert(rt.gpa, first_named + indexPosition(out.items[first_named..], i), .{ .index = i });
        } else {
            try out.append(rt.gpa, .{ .atom = a });
        }
    }
    if (include_symbols) {
        for (prop_keys, prop_vals) |pk, p| {
            if ((!include_non_enum and !p.enumerable) or !pk.isSymbol()) continue;
            try out.append(rt.gpa, .{ .symbol = pk.asSymbol() });
        }
    }
}

fn appendPropStoreKeys(
    rt: *Runtime,
    out: *std.ArrayList(Key),
    props: *const heap_mod.PropStore,
    first_named: usize,
    include_symbols: bool,
    include_non_enum: bool,
) Error!void {
    switch (props.*) {
        .dict => |*d| return appendPropsKeys(rt, out, d.keys(), d.values(), first_named, include_symbols, include_non_enum),
        .shaped => |sh| {
            const leaf = sh.shape orelse return;
            var buf: [heap_mod.MAX_SHAPE_PROPS]*const heap_mod.Shape = undefined;
            const ordered = leaf.collectOrdered(&buf);
            for (ordered) |s| {
                if ((!include_non_enum and !s.attrs.enumerable) or s.key.isSymbol()) continue;
                const a = s.key.asAtom();
                if (a.atom.?.index) |i| {
                    try out.insert(rt.gpa, first_named + indexPosition(out.items[first_named..], i), .{ .index = i });
                } else {
                    try out.append(rt.gpa, .{ .atom = a });
                }
            }
            if (include_symbols) {
                for (ordered) |s| {
                    if ((!include_non_enum and !s.attrs.enumerable) or !s.key.isSymbol()) continue;
                    try out.append(rt.gpa, .{ .symbol = s.key.asSymbol() });
                }
            }
        },
    }
}

fn collectPropStoreSymbolKeys(
    rt: *Runtime,
    props: *const heap_mod.PropStore,
    include_non_enum: bool,
) Error![]*heap_mod.Symbol {
    switch (props.*) {
        .dict => |*d| return collectSymbolKeys(rt, d.keys(), d.values(), include_non_enum),
        .shaped => |sh| {
            const leaf = sh.shape orelse return &.{};
            var buf: [heap_mod.MAX_SHAPE_PROPS]*const heap_mod.Shape = undefined;
            const ordered = leaf.collectOrdered(&buf);
            var out: std.ArrayList(*heap_mod.Symbol) = .empty;
            errdefer out.deinit(rt.gpa);
            for (ordered) |s| {
                if (!s.key.isSymbol()) continue;
                if (!include_non_enum and !s.attrs.enumerable) continue;
                try out.append(rt.gpa, s.key.asSymbol());
            }
            return out.toOwnedSlice(rt.gpa);
        },
    }
}

fn collectSymbolKeys(
    rt: *Runtime,
    prop_keys: []const heap_mod.PropKey,
    prop_vals: []const Property,
    include_non_enum: bool,
) Error![]*heap_mod.Symbol {
    var out: std.ArrayList(*heap_mod.Symbol) = .empty;
    errdefer out.deinit(rt.gpa);
    for (prop_keys, prop_vals) |pk, p| {
        if (!pk.isSymbol()) continue;
        if (!include_non_enum and !p.enumerable) continue;
        try out.append(rt.gpa, pk.asSymbol());
    }
    return out.toOwnedSlice(rt.gpa);
}

/// Own enumerable string/index keys of a closure in spec order (Object.keys(fn)).
pub fn ownKeysClosure(rt: *Runtime, c: *const heap_mod.Closure) Error![]Key {
    const m = c.meta orelse return &.{};
    if (m.props.count() == 0) return &.{};
    var out: std.ArrayList(Key) = .empty;
    errdefer out.deinit(rt.gpa);
    try appendPropsKeys(rt, &out, m.props.keys(), m.props.values(), 0, false, false);
    return out.toOwnedSlice(rt.gpa);
}

/// Own string/index keys of a closure, optionally including non-enumerable `m.props`.
pub fn ownPropertyNamesClosure(rt: *Runtime, c: *const heap_mod.Closure) Error![]Key {
    const m = c.meta orelse return &.{};
    if (m.props.count() == 0) return &.{};
    var out: std.ArrayList(Key) = .empty;
    errdefer out.deinit(rt.gpa);
    try appendPropsKeys(rt, &out, m.props.keys(), m.props.values(), 0, false, true);
    return out.toOwnedSlice(rt.gpa);
}

/// Own enumerable string/index keys in spec order: array indices ascending, then the rest in
/// insertion order (Object.keys).
pub fn ownKeys(rt: *Runtime, o: *Object) Error![]Key {
    if (o.kind == .proxy) return builtins.proxyOwnKeysFiltered(rt, o, .enum_strings);
    var out: std.ArrayList(Key) = .empty;
    errdefer out.deinit(rt.gpa);
    switch (o.kind) {
        .array => |elements| for (0..elements.items.len) |i| try out.append(rt.gpa, .{ .index = @intCast(i) }),
        .typed_array => |ta| if (!ta.buffer.kind.array_buffer.detached) {
            for (0..ta.length) |i| try out.append(rt.gpa, .{ .index = @intCast(i) });
        },
        .module_namespace => |ns| for (ns.entries) |e| try out.append(rt.gpa, .{ .atom = e.name }),
        .primitive_wrapper => |pv| if (pv.isString()) {
            for (0..pv.asString().units.len) |i| try out.append(rt.gpa, .{ .index = @intCast(i) });
        },
        .ordinary, .map, .set, .iterator, .promise, .regexp, .generator, .array_buffer, .data_view, .weak_map, .weak_set, .proxy, .date => {},
    }
    const first_named = out.items.len;
    try appendPropStoreKeys(rt, &out, &o.props, first_named, false, false);
    return out.toOwnedSlice(rt.gpa);
}

/// Own string/index keys including non-enumerable `o.props` (for Object.getOwnPropertyNames / for...in).
pub fn ownPropertyNames(rt: *Runtime, o: *Object) Error![]Key {
    if (o.kind == .proxy) return builtins.proxyOwnKeysFiltered(rt, o, .all_strings);
    var out: std.ArrayList(Key) = .empty;
    errdefer out.deinit(rt.gpa);
    switch (o.kind) {
        .array => |elements| for (0..elements.items.len) |i| try out.append(rt.gpa, .{ .index = @intCast(i) }),
        .typed_array => |ta| if (!ta.buffer.kind.array_buffer.detached) {
            for (0..ta.length) |i| try out.append(rt.gpa, .{ .index = @intCast(i) });
        },
        .module_namespace => |ns| for (ns.entries) |e| try out.append(rt.gpa, .{ .atom = e.name }),
        .primitive_wrapper => |pv| if (pv.isString()) {
            for (0..pv.asString().units.len) |i| try out.append(rt.gpa, .{ .index = @intCast(i) });
        },
        .ordinary, .map, .set, .iterator, .promise, .regexp, .generator, .array_buffer, .data_view, .weak_map, .weak_set, .proxy, .date => {},
    }
    const first_named = out.items.len;
    try appendPropStoreKeys(rt, &out, &o.props, first_named, false, true);
    if (o.kind == .primitive_wrapper and o.kind.primitive_wrapper.isString()) {
        const len_atom = try rt.heap.internAscii("length");
        if (!o.props.contains(heap_mod.PropKey.fromAtom(len_atom))) {
            try out.append(rt.gpa, .{ .atom = len_atom });
        }
    }
    return out.toOwnedSlice(rt.gpa);
}

/// Own enumerable keys including symbols (indices ascending, then strings, then symbols).
pub fn ownAllKeys(rt: *Runtime, o: *Object) Error![]Key {
    if (o.kind == .proxy) return builtins.proxyOwnKeysFiltered(rt, o, .enum_all);
    var out: std.ArrayList(Key) = .empty;
    errdefer out.deinit(rt.gpa);
    switch (o.kind) {
        .array => |elements| for (0..elements.items.len) |i| try out.append(rt.gpa, .{ .index = @intCast(i) }),
        .typed_array => |ta| if (!ta.buffer.kind.array_buffer.detached) {
            for (0..ta.length) |i| try out.append(rt.gpa, .{ .index = @intCast(i) });
        },
        .module_namespace => |ns| for (ns.entries) |e| try out.append(rt.gpa, .{ .atom = e.name }),
        .primitive_wrapper => |pv| if (pv.isString()) {
            for (0..pv.asString().units.len) |i| try out.append(rt.gpa, .{ .index = @intCast(i) });
        },
        .ordinary, .map, .set, .iterator, .promise, .regexp, .generator, .array_buffer, .data_view, .weak_map, .weak_set, .proxy, .date => {},
    }
    const first_named = out.items.len;
    try appendPropStoreKeys(rt, &out, &o.props, first_named, true, false);
    return out.toOwnedSlice(rt.gpa);
}

pub fn ownAllKeysClosure(rt: *Runtime, c: *const heap_mod.Closure) Error![]Key {
    const m = c.meta orelse return &.{};
    if (m.props.count() == 0) return &.{};
    var out: std.ArrayList(Key) = .empty;
    errdefer out.deinit(rt.gpa);
    try appendPropsKeys(rt, &out, m.props.keys(), m.props.values(), 0, true, false);
    return out.toOwnedSlice(rt.gpa);
}

pub fn ownSymbolKeys(rt: *Runtime, o: *Object, include_non_enum: bool) Error![]*heap_mod.Symbol {
    if (o.kind == .proxy) return builtins.proxyOwnSymbolKeys(rt, o, include_non_enum);
    if (o.props.count() == 0) return &.{};
    return collectPropStoreSymbolKeys(rt, &o.props, include_non_enum);
}

pub fn ownSymbolKeysClosure(rt: *Runtime, c: *const heap_mod.Closure, include_non_enum: bool) Error![]*heap_mod.Symbol {
    const m = c.meta orelse return &.{};
    if (m.props.count() == 0) return &.{};
    return collectSymbolKeys(rt, m.props.keys(), m.props.values(), include_non_enum);
}

/// Where index `i` goes among the index keys at the front of `keys` (kept ascending).
fn indexPosition(keys: []const Key, i: u32) usize {
    var n: usize = 0;
    for (keys) |k| switch (k) {
        .index => |j| if (j < i) {
            n += 1;
        },
        .atom, .symbol => break,
    };
    return n;
}

// ---------------------------------------------------------------- conversions

pub const Hint = enum { default, number, string };

/// ES ToPrimitive(input, preferredType).
pub fn toPrimitive(rt: *Runtime, v: Value, hint: Hint) Error!Value {
    if (!v.isObjectLike()) return v;
    const r = try builtins.realm(rt);
    var roots_buf = [_]Value{v};
    var roots = rt_mod.ValueRoots{ .values = &roots_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (try getMethod(rt, v, .{ .symbol = r.sym_to_primitive })) |exotic_to_prim| {
        const hint_str: Value = Value.fromString(try rt.heap.ascii(switch (hint) {
            .default => "default",
            .number => "number",
            .string => "string",
        }));
        const res = try rt.callCallable(exotic_to_prim, v, &.{hint_str});
        if (!res.isObjectLike()) return res;
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert object to primitive value" }});
    }
    return ordinaryToPrimitive(rt, v, if (hint == .string) .string else .number);
}

pub fn ordinaryToPrimitive(rt: *Runtime, v: Value, hint: Hint) Error!Value {
    const order: [2][]const u8 = if (hint == .string) .{ "toString", "valueOf" } else .{ "valueOf", "toString" };
    for (order) |method| {
        const f = get(rt, v, try named(rt, method)) catch |err| {
            // Unoverridden Function.prototype.toString is Unsupported(builtin) in builtin_names.zig;
            // return the function unchanged so callers preserve existing function_to_string semantics.
            if (err == error.Unsupported and v.isFunction() and std.mem.eql(u8, method, "toString")) {
                rt.unsupported = null;
                rt.unsupported_name = null;
                return v;
            }
            return err;
        };
        if (f.isFunction()) {
            const res = try rt.callCallable(f, v, &.{});
            if (!res.isObjectLike()) return res;
        }
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert object to primitive value" }});
}

/// Array.prototype.join (and toString): elements' ToString, `null`/`undefined` as "".
/// An array already being joined (a cycle) contributes "", as in node.
pub fn join(rt: *Runtime, arr: *Object, sep_in: []const u16) Error!*String {
    for (rt.joining.items) |a| if (a == arr) return rt.heap.ascii("");
    if (rt.joining.items.len >= rt.limits.max_conversion_depth) return rt.limit(.conversion_depth);
    try rt.joining.append(rt.gpa, arr);
    defer _ = rt.joining.pop();

    // Copy separator out of GC memory so user conversions on elements can't invalidate it.
    var sep_stack: [64]u16 = undefined;
    const sep_heap = if (sep_in.len > sep_stack.len) try rt.gpa.dupe(u16, sep_in) else null;
    defer if (sep_heap) |s| rt.gpa.free(s);
    const sep: []const u16 = if (sep_heap) |s| s else blk: {
        @memcpy(sep_stack[0..sep_in.len], sep_in);
        break :blk sep_stack[0..sep_in.len];
    };

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);
    const len = arr.kind.array.items.len;
    for (0..len) |i| {
        if (i > 0) try append(rt, &out, sep);
        const e: Value = if (i < arr.kind.array.items.len) arr.kind.array.items[i] else .undefined;
        switch (e) {
            .undefined, .null => {},
            else => {
                var buf: ops.NumberBuf = undefined;
                switch (try ops.toPiece(rt, e, &buf)) {
                    .utf16 => |u| try append(rt, &out, u),
                    .ascii => |a| for (a) |c| try append(rt, &out, &.{c}),
                }
            },
        }
    }
    return rt.heap.newString(&.{.{ .utf16 = out.items }});
}

fn append(rt: *Runtime, out: *std.ArrayList(u16), units: []const u16) Error!void {
    if (out.items.len + units.len > rt.heap.max_string_length) return rt.limit(.string_length);
    try out.appendSlice(rt.gpa, units);
}

// ---------------------------------------------------------------- TypedArray element helpers (M43, D73)

const native_endian: std.builtin.Endian = builtin.cpu.arch.endian();

/// Returns the numeric value if `k` is a CanonicalNumericIndexString, else null.
pub fn canonicalNumericIndex(k: Key) ?f64 {
    switch (k) {
        .index => |i| return @floatFromInt(i),
        .symbol => return null,
        .atom => |a| {
            const u = a.units;
            if (u.len == 0 or u.len > 64) return null;
            if (u.len == 2 and u[0] == '-' and u[1] == '0') return -0.0;
            var ascii_buf: [64]u8 = undefined;
            for (u, 0..) |ch, i| {
                if (ch > 0x7f) return null;
                ascii_buf[i] = @intCast(ch);
            }
            const ascii = ascii_buf[0..u.len];
            if (std.mem.eql(u8, ascii, "NaN")) return std.math.nan(f64);
            if (std.mem.eql(u8, ascii, "Infinity")) return std.math.inf(f64);
            if (std.mem.eql(u8, ascii, "-Infinity")) return -std.math.inf(f64);
            const n = std.fmt.parseFloat(f64, ascii) catch return null;
            var fmt_buf: ops.NumberBuf = undefined;
            const formatted = ops.formatNumber(&fmt_buf, n);
            if (std.mem.eql(u8, formatted, ascii)) return n;
            return null;
        },
    }
}

pub fn validIntegerIndex(ta: heap_mod.TypedArrayState, n: f64) ?usize {
    if (ta.buffer.kind.array_buffer.detached) return null;
    if (std.math.isNan(n) or std.math.isInf(n)) return null;
    if (n == 0.0 and std.math.signbit(n)) return null;
    if (n < 0.0 or @floor(n) != n) return null;
    if (n >= @as(f64, @floatFromInt(ta.length))) return null;
    return @intFromFloat(n);
}

/// Round-half-to-even clamping to [0, 255] for Uint8ClampedArray (ES ToUint8Clamp).
pub fn toUint8Clamp(n: f64) u8 {
    if (std.math.isNan(n) or n <= 0.0) return 0;
    if (n >= 255.0) return 255;
    const f = @floor(n);
    const diff = n - f;
    if (diff < 0.5) return @intFromFloat(f);
    if (diff > 0.5) return @intFromFloat(f + 1.0);
    if (@mod(f, 2.0) == 0.0) return @intFromFloat(f);
    return @intFromFloat(f + 1.0);
}

pub fn readTypedArrayI64(ta: heap_mod.TypedArrayState, idx: usize) i64 {
    const data = ta.buffer.kind.array_buffer.data;
    const off = ta.byte_offset + idx * 8;
    return std.mem.readInt(i64, data[off..][0..8], native_endian);
}

pub fn readTypedArrayU64(ta: heap_mod.TypedArrayState, idx: usize) u64 {
    const data = ta.buffer.kind.array_buffer.data;
    const off = ta.byte_offset + idx * 8;
    return std.mem.readInt(u64, data[off..][0..8], native_endian);
}

pub fn readTypedArrayNumber(ta: heap_mod.TypedArrayState, idx: usize) Value {
    const data = ta.buffer.kind.array_buffer.data;
    const off = ta.byte_offset + idx * ta.kind.bytesPerElement();
    return Value.fromNumber(switch (ta.kind) {
        .int8 => @floatFromInt(@as(i8, @bitCast(data[off]))),
        .uint8, .uint8_clamped => @floatFromInt(data[off]),
        .int16 => @floatFromInt(std.mem.readInt(i16, data[off..][0..2], native_endian)),
        .uint16 => @floatFromInt(std.mem.readInt(u16, data[off..][0..2], native_endian)),
        .int32 => @floatFromInt(std.mem.readInt(i32, data[off..][0..4], native_endian)),
        .uint32 => @floatFromInt(std.mem.readInt(u32, data[off..][0..4], native_endian)),
        .float32 => @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, data[off..][0..4], native_endian)))),
        .float64 => @bitCast(std.mem.readInt(u64, data[off..][0..8], native_endian)),
        .bigint64, .biguint64 => unreachable,
    });
}

pub fn readTypedArrayElement(rt: *Runtime, ta: heap_mod.TypedArrayState, idx: usize) Error!Value {
    return switch (ta.kind) {
        .bigint64 => Value.fromBigInt(try bigint.fromI64(rt, readTypedArrayI64(ta, idx))),
        .biguint64 => Value.fromBigInt(try bigint.fromU64(rt, readTypedArrayU64(ta, idx))),
        else => readTypedArrayNumber(ta, idx),
    };
}

pub fn writeTypedArrayBigInt(ta: heap_mod.TypedArrayState, idx: usize, b: *const heap_mod.BigInt) void {
    const data = ta.buffer.kind.array_buffer.data;
    const off = ta.byte_offset + idx * 8;
    switch (ta.kind) {
        .bigint64 => std.mem.writeInt(i64, data[off..][0..8], bigint.toI64Wrapping(b), native_endian),
        .biguint64 => std.mem.writeInt(u64, data[off..][0..8], bigint.toU64Wrapping(b), native_endian),
        else => unreachable,
    }
}

pub fn writeTypedArrayNumber(ta: heap_mod.TypedArrayState, idx: usize, n: f64) void {
    const data = ta.buffer.kind.array_buffer.data;
    const off = ta.byte_offset + idx * ta.kind.bytesPerElement();
    switch (ta.kind) {
        .int8 => data[off] = @bitCast(@as(i8, @truncate(ops.toInt32(n)))),
        .uint8 => data[off] = @truncate(ops.toUint32(n)),
        .uint8_clamped => data[off] = toUint8Clamp(n),
        .int16 => std.mem.writeInt(i16, data[off..][0..2], @truncate(ops.toInt32(n)), native_endian),
        .uint16 => std.mem.writeInt(u16, data[off..][0..2], @truncate(ops.toUint32(n)), native_endian),
        .int32 => std.mem.writeInt(i32, data[off..][0..4], ops.toInt32(n), native_endian),
        .uint32 => std.mem.writeInt(u32, data[off..][0..4], ops.toUint32(n), native_endian),
        .float32 => {
            const f: f32 = @floatCast(n);
            std.mem.writeInt(u32, data[off..][0..4], @bitCast(f), native_endian);
        },
        .float64 => std.mem.writeInt(u64, data[off..][0..8], @bitCast(n), native_endian),
        .bigint64, .biguint64 => unreachable,
    }
}

pub fn writeTypedArrayElement(rt: *Runtime, ta: heap_mod.TypedArrayState, idx: usize, v: Value) Error!void {
    if (ta.kind.isBigInt()) {
        const b = try ops.toBigInt(rt, v);
        writeTypedArrayBigInt(ta, idx, b);
    } else {
        const n = try ops.toNumber(rt, v);
        writeTypedArrayNumber(ta, idx, n);
    }
}
