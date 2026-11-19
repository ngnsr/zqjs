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
const names = @import("builtin_names.zig");

pub const Key = union(enum) {
    index: u32,
    atom: *String,
};

/// The largest array index (2^32 − 2); one more is the largest length.
const max_index = std.math.maxInt(u32) - 1;

// ---------------------------------------------------------------- keys

/// ToPropertyKey.
pub fn key(rt: *Runtime, v: Value) Error!Key {
    switch (v) {
        .number => |n| {
            if (n >= 0 and n <= max_index and @floor(n) == n) return .{ .index = @intFromFloat(n) }; // -0 → 0
            var buf: ops.NumberBuf = undefined;
            return .{ .atom = try rt.heap.internAscii(ops.formatNumber(&buf, n)) };
        },
        .string => |s| return keyUnits(rt, s.units),
        .undefined, .null, .boolean => {
            var buf: ops.NumberBuf = undefined;
            return .{ .atom = try rt.heap.internAscii((try ops.toPiece(rt, v, &buf)).ascii) };
        },
        .object => return key(rt, try toPrimitive(rt, v, .string)),
        .native, .closure => return rt.fail(.function_to_string),
    }
}

/// The key of a string literal (`{ 'a b': … }`).
pub fn keyUnits(rt: *Runtime, units: []const u16) Error!Key {
    const a = try rt.heap.intern(units);
    return if (a.atom.?.index) |i| .{ .index = i } else .{ .atom = a };
}

/// The key named by ASCII source text (`o.name`, `{name: …}`).
pub fn named(rt: *Runtime, text: []const u8) Error!Key {
    const a = try rt.heap.internAscii(text);
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
    };
}

pub fn isNamed(k: Key, text: []const u8) bool {
    const a = switch (k) {
        .atom => |a| a,
        .index => return false,
    };
    if (a.units.len != text.len) return false;
    for (text, a.units) |c, u| if (c != u) return false;
    return true;
}

/// Whether node gives built-in `b` an own property `k` (only ASCII names can match).
fn nodeHas(b: names.Builtin, k: Key) bool {
    const a = switch (k) {
        .atom => |a| a,
        .index => return false,
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
    rt.unsupported_name = try atomOf(rt, k);
    return rt.fail(.builtin);
}

/// A piece naming the key, for error messages.
fn keyPiece(k: Key, buf: *[10]u8) Piece {
    return switch (k) {
        .atom => |a| .{ .utf16 = a.units },
        .index => |i| .{ .ascii = std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable },
    };
}

// ---------------------------------------------------------------- get

/// `base[k]` / `base.k`.
pub fn get(rt: *Runtime, base: Value, k: Key) Error!Value {
    return getWithReceiver(rt, base, base, k);
}

fn getWithReceiver(rt: *Runtime, base: Value, receiver: Value, k: Key) Error!Value {
    heap_mod.checkValue(base);
    switch (base) {
        .undefined, .null => {
            var buf: [10]u8 = undefined;
            return rt.throw(.TypeError, &.{ .{ .ascii = "Cannot read properties of " }, .{ .ascii = @tagName(base) }, .{ .ascii = " (reading '" }, keyPiece(k, &buf), .{ .ascii = "')" } });
        },
        .string => |s| {
            switch (k) {
                .index => |i| if (i < s.units.len) return .{ .string = try rt.heap.newString(&.{.{ .utf16 = s.units[i..][0..1] }}) },
                .atom => if (isNamed(k, "length")) return .{ .number = @floatFromInt(s.units.len) },
            }
            const r = try builtins.realm(rt);
            return getFrom(rt, r.string_prototype, receiver, k);
        },
        .number => return getFrom(rt, (try builtins.realm(rt)).number_prototype, receiver, k),
        .boolean => return getFrom(rt, (try builtins.realm(rt)).boolean_prototype, receiver, k),
        .object => |o| return getFrom(rt, o, receiver, k),
        .native => |n| {
            if (isNamed(k, "name")) return .{ .string = try rt.heap.ascii(n.name) };
            if (isNamed(k, "length")) return .{ .number = @floatFromInt(n.length) };
            if (try builtins.namespaceObject(rt, n)) |ns| {
                if (try ownProp(rt, ns, k)) |p| return resolvePropValue(rt, receiver, p);
                if (nodeHas(ns.builtin.?, k)) return unsupportedBuiltin(rt, k);
            }
            return getFrom(rt, (try builtins.realm(rt)).function_prototype, receiver, k);
        },
        .closure => |c| {
            if (isNamed(k, "name")) return .{ .string = try builtins.closureName(rt, c) };
            if (isNamed(k, "length")) return .{ .number = @floatFromInt(builtins.closureLength(c)) };
            if (isNamed(k, "prototype")) {
                if (c.meta) |m| if (m.prototype) |p| return p;
                if (builtins.hasAutoPrototype(c)) {
                    return .{ .object = try builtins.materializeClosurePrototype(rt, @constCast(c)) };
                }
            }
            if (c.meta) |m| if (m.props.count() > 0) {
                if (m.props.get(try atomOf(rt, k))) |p| return resolvePropValue(rt, receiver, p);
            };
            if (c.meta) |m| if (m.proto) |p| return getWithReceiver(rt, p, receiver, k);
            return getFrom(rt, (try builtins.realm(rt)).function_prototype, receiver, k);
        },
    }
}

pub fn getPrototypeOfValue(rt: *Runtime, v: Value) Error!Value {
    return switch (v) {
        .object => |o| if (o.proto) |p| .{ .object = p } else .null,
        .closure => |c| if (c.meta) |m| (m.proto orelse .{ .object = (try builtins.realm(rt)).function_prototype }) else .{ .object = (try builtins.realm(rt)).function_prototype },
        .native => .{ .object = (try builtins.realm(rt)).function_prototype },
        else => .null,
    };
}

pub fn getSuper(rt: *Runtime, home: Value, receiver: Value, k: Key) Error!Value {
    const proto = try getPrototypeOfValue(rt, home);
    if (proto == .null or proto == .undefined) return .undefined;
    return getWithReceiver(rt, proto, receiver, k);
}

fn resolvePropValue(rt: *Runtime, receiver: Value, p: Property) Error!Value {
    if (!p.is_accessor) return p.value;
    if (p.value == .undefined) return .undefined;
    return rt.callCallable(p.value, receiver, &.{});
}

/// [[Get]] along the prototype chain (cycles can't be built: see Object.proto).
fn getFrom(rt: *Runtime, start: *Object, receiver: Value, k: Key) Error!Value {
    var o: ?*Object = start;
    while (o) |cur| : (o = cur.proto) {
        cur.obj.checkLive(); // stress builds: a collected object or prototype
        if (try ownProp(rt, cur, k)) |p| return resolvePropValue(rt, receiver, p);
        if (cur.builtin) |b| if (nodeHas(b, k)) return unsupportedBuiltin(rt, k);
    }
    return .undefined;
}

fn ownProp(rt: *Runtime, o: *Object, k: Key) Error!?Property {
    switch (o.kind) {
        .array => |elements| switch (k) {
            .index => |i| return if (i < elements.items.len) .{ .value = elements.items[i] } else null,
            .atom => if (isNamed(k, "length")) return .{ .value = .{ .number = @floatFromInt(elements.items.len) }, .enumerable = false, .configurable = false },
        },
        .map, .set => |table| if (isNamed(k, "size")) return .{ .value = .{ .number = @floatFromInt(table.live_count) }, .enumerable = false, .writable = false },
        .regexp => |re| {
            if (isNamed(k, "lastIndex")) return .{ .value = re.last_index, .enumerable = false, .configurable = false };
            if (isNamed(k, "source")) return .{ .value = .{ .string = re.source }, .enumerable = false, .writable = false };
            if (isNamed(k, "flags")) return .{ .value = .{ .string = re.flags }, .enumerable = false, .writable = false };
            if (isNamed(k, "hasIndices")) return .{ .value = .{ .boolean = re.program.flags.has_indices }, .enumerable = false, .writable = false };
            if (isNamed(k, "global")) return .{ .value = .{ .boolean = re.global }, .enumerable = false, .writable = false };
            if (isNamed(k, "ignoreCase")) return .{ .value = .{ .boolean = re.program.flags.ignore_case }, .enumerable = false, .writable = false };
            if (isNamed(k, "multiline")) return .{ .value = .{ .boolean = re.program.flags.multiline }, .enumerable = false, .writable = false };
            if (isNamed(k, "dotAll")) return .{ .value = .{ .boolean = re.program.flags.dot_all }, .enumerable = false, .writable = false };
            if (isNamed(k, "unicode")) return .{ .value = .{ .boolean = re.program.flags.unicode }, .enumerable = false, .writable = false };
            if (isNamed(k, "unicodeSets")) return .{ .value = .{ .boolean = re.program.flags.unicode_sets }, .enumerable = false, .writable = false };
            if (isNamed(k, "sticky")) return .{ .value = .{ .boolean = re.program.flags.sticky }, .enumerable = false, .writable = false };
        },
        .ordinary, .iterator, .promise => {},
    }
    if (o.props.count() == 0) return null; // don't intern index keys just to miss
    return o.props.get(try atomOf(rt, k));
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
        .index => return null,
    };
    return if (o.props.get(a)) |p| p.value else null;
}

// ---------------------------------------------------------------- set, define, delete

const ChainHit = union(enum) {
    none,
    accessor: Property,
    data: struct { is_own: bool, writable: bool },
};

fn sameTarget(a: Value, b: ?Value) bool {
    const bv = b orelse return false;
    return switch (a) {
        .object => |ao| bv == .object and bv.object == ao,
        .closure => |ac| bv == .closure and bv.closure == ac,
        else => false,
    };
}

fn lookupSetChain(rt: *Runtime, start: Value, base: ?Value, k: Key) Error!ChainHit {
    var cur: Value = start;
    while (true) {
        switch (cur) {
            .object => |o| {
                o.obj.checkLive();
                if (try ownProp(rt, o, k)) |p| {
                    if (p.is_accessor) return .{ .accessor = p };
                    return .{ .data = .{ .is_own = sameTarget(cur, base), .writable = p.writable } };
                }
                cur = if (o.proto) |p| .{ .object = p } else return .none;
            },
            .closure => |c| {
                c.obj.checkLive();
                if (isNamed(k, "name") or isNamed(k, "length")) {
                    return .{ .data = .{ .is_own = sameTarget(cur, base), .writable = false } };
                }
                if (c.meta) |m| {
                    if (m.props.count() > 0) {
                        if (m.props.get(try atomOf(rt, k))) |p| {
                            if (p.is_accessor) return .{ .accessor = p };
                            return .{ .data = .{ .is_own = sameTarget(cur, base), .writable = p.writable } };
                        }
                    }
                    if (m.proto) |p| {
                        cur = p;
                        continue;
                    }
                }
                cur = .{ .object = (try builtins.realm(rt)).function_prototype };
            },
            else => return .none,
        }
    }
}

fn invokeSetter(rt: *Runtime, p: Property, receiver: Value, v: Value) Error!void {
    if (p.setter == .undefined) return; // sloppy-mode no-op on getter-only accessor
    _ = try rt.callCallable(p.setter, receiver, &.{v});
}

/// `base[k] = v` with prototype accessor/writable checks (D64).
pub fn set(rt: *Runtime, base: Value, k: Key, v: Value) Error!void {
    switch (base) {
        .undefined, .null => {
            var buf: [10]u8 = undefined;
            return rt.throw(.TypeError, &.{ .{ .ascii = "Cannot set properties of " }, .{ .ascii = @tagName(base) }, .{ .ascii = " (setting '" }, keyPiece(k, &buf), .{ .ascii = "')" } });
        },
        .string, .number, .boolean => return rt.fail(.primitive_write), // sloppy JS ignores these
        .native => {
            if (isNamed(k, "__proto__")) return unsupportedBuiltin(rt, k);
            if (isNamed(k, "name") or isNamed(k, "length")) return;
            return rt.fail(.function_properties);
        },
        .closure => |c| {
            if (isNamed(k, "__proto__")) return unsupportedBuiltin(rt, k);
            if (isNamed(k, "name") or isNamed(k, "length")) return;
            if (isNamed(k, "prototype") and builtins.hasAutoPrototype(c)) {
                try rt.heap.storeClosurePrototype(@constCast(c), v);
                return;
            }
        },
        .object => {
            if (isNamed(k, "__proto__")) return unsupportedBuiltin(rt, k);
        },
    }
    switch (try lookupSetChain(rt, base, base, k)) {
        .accessor => |p| return invokeSetter(rt, p, base, v),
        .data => |d| if (!d.writable) return, // sloppy-mode no-op on non-writable property
        .none => {},
    }
    try setOwnData(rt, base, k, v);
}

pub fn setSuper(rt: *Runtime, home: Value, receiver: Value, k: Key, v: Value) Error!void {
    const proto = try getPrototypeOfValue(rt, home);
    if (proto != .null and proto != .undefined) {
        switch (try lookupSetChain(rt, proto, null, k)) {
            .accessor => |p| return invokeSetter(rt, p, receiver, v),
            .data => |d| if (!d.writable) return,
            .none => {},
        }
    }
    // Check own property on receiver before writing own data property.
    switch (receiver) {
        .object => |o| if (try ownProp(rt, o, k)) |p| {
            if (p.is_accessor) return invokeSetter(rt, p, receiver, v);
            if (!p.writable) return;
        },
        .closure => |c| {
            if (isNamed(k, "name") or isNamed(k, "length")) return;
            if (c.meta) |m| if (m.props.get(try atomOf(rt, k))) |p| {
                if (p.is_accessor) return invokeSetter(rt, p, receiver, v);
                if (!p.writable) return;
            };
        },
        .undefined, .null => {
            var buf: [10]u8 = undefined;
            return rt.throw(.TypeError, &.{ .{ .ascii = "Cannot set properties of " }, .{ .ascii = @tagName(receiver) }, .{ .ascii = " (setting '" }, keyPiece(k, &buf), .{ .ascii = "')" } });
        },
        else => return rt.fail(.primitive_write),
    }
    try setOwnData(rt, receiver, k, v);
}

fn setOwnData(rt: *Runtime, base: Value, k: Key, v: Value) Error!void {
    switch (base) {
        .closure => |c| {
            try rt.heap.storeClosureProperty(@constCast(c), try atomOf(rt, k), v);
        },
        .object => |o| {
            switch (o.kind) {
                .array => |elements| switch (k) {
                    .index => |i| {
                        if (i < elements.items.len) {
                            rt.heap.storeElement(o, i, v);
                        } else if (i == elements.items.len) {
                            try rt.heap.appendElement(o, v);
                        } else return rt.fail(.sparse_array);
                        return;
                    },
                    .atom => if (isNamed(k, "length")) return setLength(rt, o, v),
                },
                .map, .set => if (isNamed(k, "size")) return, // Map/Set size is a read-only getter
                .regexp => {
                    if (isNamed(k, "lastIndex")) {
                        rt.heap.storeRegExpLastIndex(o, v);
                        return;
                    }
                    if (isRegExpGetter(k)) return;
                },
                .ordinary, .iterator, .promise => {},
            }
            try putOwn(rt, o, k, v);
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
    const a = try atomOf(rt, k);
    switch (target) {
        .object => |o| try rt.heap.defineProperty(o, a, .{ .value = v, .enumerable = false }),
        .closure => |c| try rt.heap.defineClosureProperty(@constCast(c), a, .{ .value = v, .enumerable = false }),
        else => unreachable,
    }
}

pub fn defineAccessor(rt: *Runtime, target: Value, k: Key, fn_val: Value, is_setter: bool, enumerable: bool) Error!void {
    const a = try atomOf(rt, k);
    const existing: ?Property = switch (target) {
        .object => |o| o.props.get(a),
        .closure => |c| if (c.meta) |m| m.props.get(a) else null,
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
    switch (target) {
        .object => |o| try rt.heap.defineProperty(o, a, prop),
        .closure => |c| try rt.heap.defineClosureProperty(@constCast(c), a, prop),
        else => unreachable,
    }
}

fn putOwn(rt: *Runtime, o: *Object, k: Key, v: Value) Error!void {
    try rt.heap.storeProperty(o, try atomOf(rt, k), v);
}

fn setLength(rt: *Runtime, arr: *Object, v: Value) Error!void {
    const n = try ops.toNumber(rt, v);
    if (!(n >= 0 and n <= max_index + 1 and @floor(n) == n)) return rt.throw(.RangeError, &.{.{ .ascii = "Invalid array length" }});
    const len: usize = @intFromFloat(n);
    if (len > arr.kind.array.items.len) return rt.fail(.sparse_array);
    rt.heap.shrinkElements(arr, len);
}

/// `delete base[k]`.
pub fn delete(rt: *Runtime, base: Value, k: Key) Error!bool {
    heap_mod.checkValue(base);
    const o = switch (base) {
        .undefined, .null => return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }}),
        .string, .number, .boolean => return rt.fail(.primitive_write),
        .native => return rt.fail(.function_properties),
        .closure => |c| {
            if (isNamed(k, "name") or isNamed(k, "length")) return true;
            if (isNamed(k, "prototype") and builtins.hasAutoPrototype(c)) return false;
            if (c.meta == null or c.meta.?.props.count() == 0) return true;
            const a = try atomOf(rt, k);
            if (c.meta.?.props.get(a)) |p| if (!p.configurable) return false;
            rt.heap.removeClosureProperty(@constCast(c), a);
            return true;
        },
        .object => |o| o,
    };
    switch (o.kind) {
        .array => |elements| switch (k) {
            // Deleting an element leaves a hole; deleting past the end does nothing.
            .index => |i| return if (i < elements.items.len) rt.fail(.sparse_array) else true,
            .atom => if (isNamed(k, "length")) return false, // non-configurable
        },
        .regexp => if (isNamed(k, "lastIndex")) return false, // non-configurable
        .ordinary, .map, .set, .iterator, .promise => {},
    }
    if (o.props.count() == 0) return true;
    const a = try atomOf(rt, k);
    if (o.props.get(a)) |p| if (!p.configurable) return false;
    rt.heap.removeProperty(o, a);
    return true;
}

/// `k in base`.
pub fn has(rt: *Runtime, k: Key, base: Value) Error!bool {
    heap_mod.checkValue(base);
    const start: *Object = switch (base) {
        .object => |o| o,
        .native => |n| {
            if (isNamed(k, "name") or isNamed(k, "length")) return true;
            if (try builtins.namespaceObject(rt, n)) |ns| {
                if (try ownProp(rt, ns, k) != null) return true;
                if (nodeHas(ns.builtin.?, k)) return true;
            }
            return hasInChain(rt, (try builtins.realm(rt)).function_prototype, k);
        },
        .closure => |c| {
            if (isNamed(k, "name") or isNamed(k, "length")) return true;
            if (isNamed(k, "prototype") and builtins.hasAutoPrototype(c)) return true;
            if (c.meta) |m| if (m.props.count() > 0) if (m.props.contains(try atomOf(rt, k))) return true;
            if (c.meta) |m| if (m.proto) |p| return has(rt, k, p);
            return hasInChain(rt, (try builtins.realm(rt)).function_prototype, k);
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
        if (try ownProp(rt, cur, k) != null) return true;
        // node has it there, so the answer is known even if the value isn't.
        if (cur.builtin) |b| if (nodeHas(b, k)) return true;
    }
    return false;
}

/// `lhs instanceof rhs` (M25, M31 D62).
pub fn instanceOf(rt: *Runtime, lhs: Value, rhs: Value) Error!bool {
    heap_mod.checkValue(lhs);
    heap_mod.checkValue(rhs);
    var target = rhs;
    if (!target.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Right-hand side of 'instanceof' is not callable" }});
    }
    var cur: Value = try getPrototypeOfValue(rt, lhs);
    if (lhs != .object and lhs != .closure and lhs != .native) return false;
    while (target == .closure and target.closure.impl == .bound) {
        target = target.closure.impl.bound.target;
    }
    const target_proto: *Object = switch (target) {
        .native => |n| (try builtins.constructorPrototype(rt, n)) orelse
            return rt.throw(.TypeError, &.{.{ .ascii = "Function has non-object prototype 'undefined' in instanceof check" }}),
        .closure => blk: {
            const proto_val = try get(rt, target, try named(rt, "prototype"));
            if (proto_val != .object) {
                return rt.throw(.TypeError, &.{.{ .ascii = "Function has non-object prototype in instanceof check" }});
            }
            break :blk proto_val.object;
        },
        else => unreachable,
    };
    while (cur != .null) : (cur = try getPrototypeOfValue(rt, cur)) {
        if (cur == .object) {
            cur.object.obj.checkLive();
            if (cur.object == target_proto) return true;
        }
    }
    return false;
}

/// Own enumerable keys of a closure in spec order (Object.keys(fn)).
pub fn ownKeysClosure(rt: *Runtime, c: *const heap_mod.Closure) Error![]Key {
    const m = c.meta orelse return &.{};
    if (m.props.count() == 0) return &.{};
    var out: std.ArrayList(Key) = .empty;
    errdefer out.deinit(rt.gpa);
    for (m.props.keys(), m.props.values()) |a, p| {
        if (!p.enumerable) continue;
        if (a.atom.?.index) |i| try out.insert(rt.gpa, indexPosition(out.items, i), .{ .index = i }) else try out.append(rt.gpa, .{ .atom = a });
    }
    return out.toOwnedSlice(rt.gpa);
}

/// Own enumerable keys in spec order: array indices ascending, then the rest in
/// insertion order (Object.keys).
pub fn ownKeys(rt: *Runtime, o: *Object) Error![]Key {
    var out: std.ArrayList(Key) = .empty;
    errdefer out.deinit(rt.gpa);
    switch (o.kind) {
        .array => |elements| for (0..elements.items.len) |i| try out.append(rt.gpa, .{ .index = @intCast(i) }),
        .ordinary, .map, .set, .iterator, .promise, .regexp => {},
    }
    const first_named = out.items.len;
    for (o.props.keys(), o.props.values()) |a, p| {
        if (!p.enumerable) continue;
        if (a.atom.?.index) |i| try out.insert(rt.gpa, first_named + indexPosition(out.items[first_named..], i), .{ .index = i }) else try out.append(rt.gpa, .{ .atom = a });
    }
    return out.toOwnedSlice(rt.gpa);
}

/// Where index `i` goes among the index keys at the front of `keys` (kept ascending).
fn indexPosition(keys: []const Key, i: u32) usize {
    var n: usize = 0;
    for (keys) |k| switch (k) {
        .index => |j| if (j < i) {
            n += 1;
        },
        .atom => break,
    };
    return n;
}

// ---------------------------------------------------------------- conversions

pub const Hint = enum { number, string };

/// ToPrimitive. Only the built-in methods are called (D40).
pub fn toPrimitive(rt: *Runtime, v: Value, hint: Hint) Error!Value {
    if (v != .object) return v;
    const order: [2][]const u8 = if (hint == .string) .{ "toString", "valueOf" } else .{ "valueOf", "toString" };
    for (order) |method| {
        const f = try get(rt, v, try named(rt, method));
        switch (f) {
            .native => |n| {
                if (!builtins.isConversion(n)) return rt.fail(.user_conversion);
                const r = try n.call(rt, v, &.{});
                if (r != .object) return r;
            },
            .closure => return rt.fail(.user_conversion),
            else => {}, // not callable: try the other method
        }
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert object to primitive value" }});
}

/// Array.prototype.join (and toString): elements' ToString, `null`/`undefined` as "".
/// An array already being joined (a cycle) contributes "", as in node.
pub fn join(rt: *Runtime, arr: *Object, sep: []const u16) Error!*String {
    for (rt.joining.items) |a| if (a == arr) return rt.heap.ascii("");
    if (rt.joining.items.len >= rt.limits.max_conversion_depth) return rt.limit(.conversion_depth);
    try rt.joining.append(rt.gpa, arr);
    defer _ = rt.joining.pop();

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);
    // Converting elements can't change the array: conversions never run JS (D40).
    for (arr.kind.array.items, 0..) |e, i| {
        if (i > 0) try append(rt, &out, sep);
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
