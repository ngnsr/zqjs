//! The built-in objects and functions ZQJS implements (DESIGN_DECISIONS D39), and global
//! name lookup.
//!
//! Three kinds of names, for globals and for properties of built-in objects:
//!   implemented   here, with their behaviour (the only ones that produce values)
//!   known         node has them (builtin_names.zig, generated from node) but ZQJS
//!                 doesn't implement them: Unsupported(builtin), naming the member
//!   nonexistent   neither: a global is a ReferenceError, a property `undefined`
//!
//! Implemented in M7:
//!   globals             undefined NaN Infinity print Object Array
//!   Object              keys create getPrototypeOf
//!   Array               isArray
//!   Object.prototype    toString valueOf
//!   Array.prototype     push pop join toString
//!   String.prototype    charCodeAt
//! Calling `Object(…)` or `Array(…)` themselves is Unsupported(builtin).
//!
//! The realm (the built-in objects) is created on first use, so creating a Runtime
//! can't fail. GC roots (D38): every object in Realm.

const std = @import("std");
const Value = @import("value.zig").Value;
const Native = @import("value.zig").Native;
const heap_mod = @import("heap.zig");
const Object = heap_mod.Object;
const rt_mod = @import("runtime.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const ops = @import("ops.zig");
const object = @import("object.zig");
const names = @import("builtin_names.zig");
const json = @import("json.zig");

pub const Realm = struct {
    object_prototype: *Object,
    array_prototype: *Object,
    string_prototype: *Object,
    number_prototype: *Object,
    boolean_prototype: *Object,
    function_prototype: *Object,
    map_prototype: *Object,
    set_prototype: *Object,
    promise_prototype: *Object,
    iterator_prototype: *Object,
    /// Static members of the `Object`, `Array`, `Map`, `Set`, and `Promise` globals.
    object_namespace: *Object,
    array_namespace: *Object,
    map_namespace: *Object,
    set_namespace: *Object,
    promise_namespace: *Object,
    math: *Object,
    json: *Object,

    /// For GC roots (M8) and tests.
    pub fn objects(r: *const Realm) [17]*Object {
        return .{ r.object_prototype, r.array_prototype, r.string_prototype, r.number_prototype, r.boolean_prototype, r.function_prototype, r.map_prototype, r.set_prototype, r.promise_prototype, r.iterator_prototype, r.object_namespace, r.array_namespace, r.map_namespace, r.set_namespace, r.promise_namespace, r.math, r.json };
    }
};

pub fn realm(rt: *Runtime) Error!*const Realm {
    if (rt.realm) |*r| return r;
    const h = &rt.heap;
    const object_prototype = try builtin(h, null, .object_prototype);
    var r: Realm = .{
        .object_prototype = object_prototype,
        .array_prototype = try builtin(h, object_prototype, .array_prototype),
        .string_prototype = try builtin(h, object_prototype, .string_prototype),
        .number_prototype = try builtin(h, object_prototype, .number_prototype),
        .boolean_prototype = try builtin(h, object_prototype, .boolean_prototype),
        .function_prototype = try builtin(h, object_prototype, .function_prototype),
        .map_prototype = try builtin(h, object_prototype, .map_prototype),
        .set_prototype = try builtin(h, object_prototype, .set_prototype),
        .promise_prototype = try builtin(h, object_prototype, .promise_prototype),
        .iterator_prototype = try builtin(h, object_prototype, .iterator_prototype),
        .object_namespace = try builtin(h, null, .object_constructor),
        .array_namespace = try builtin(h, null, .array_constructor),
        .map_namespace = try builtin(h, null, .map_constructor),
        .set_namespace = try builtin(h, null, .set_constructor),
        .promise_namespace = try builtin(h, null, .promise_constructor),
        .math = try builtin(h, object_prototype, .math),
        .json = try builtin(h, object_prototype, .json),
    };
    try method(rt, r.object_prototype, "toString", &object_to_string);
    try method(rt, r.object_prototype, "valueOf", &object_value_of);
    try method(rt, r.array_prototype, "push", &array_push);
    try method(rt, r.array_prototype, "pop", &array_pop);
    try method(rt, r.array_prototype, "slice", &array_slice);
    try method(rt, r.array_prototype, "indexOf", &array_index_of);
    try method(rt, r.array_prototype, "includes", &array_includes);
    try method(rt, r.array_prototype, "join", &array_join);
    try method(rt, r.array_prototype, "toString", &array_to_string);
    try method(rt, r.array_prototype, "keys", &array_keys);
    try method(rt, r.array_prototype, "values", &array_values);
    try method(rt, r.array_prototype, "entries", &array_entries);
    try method(rt, r.array_prototype, "forEach", &array_for_each);
    try method(rt, r.array_prototype, "map", &array_map);
    try method(rt, r.array_prototype, "filter", &array_filter);
    try method(rt, r.array_prototype, "reduce", &array_reduce);
    try method(rt, r.string_prototype, "charAt", &string_char_at);
    try method(rt, r.string_prototype, "charCodeAt", &string_char_code_at);
    try method(rt, r.string_prototype, "slice", &string_slice);
    try method(rt, r.string_prototype, "indexOf", &string_index_of);
    try method(rt, r.string_prototype, "includes", &string_includes);
    try method(rt, r.string_prototype, "toLowerCase", &string_to_lower_case);
    try method(rt, r.string_prototype, "toUpperCase", &string_to_upper_case);
    try method(rt, r.object_namespace, "keys", &object_keys);
    try method(rt, r.object_namespace, "create", &object_create);
    try method(rt, r.object_namespace, "getPrototypeOf", &object_get_prototype_of);
    try method(rt, r.array_namespace, "isArray", &array_is_array);
    try method(rt, r.map_prototype, "get", &map_get);
    try method(rt, r.map_prototype, "set", &map_set);
    try method(rt, r.map_prototype, "has", &map_has);
    try method(rt, r.map_prototype, "delete", &map_delete);
    try method(rt, r.map_prototype, "clear", &map_clear);
    try method(rt, r.map_prototype, "keys", &map_keys);
    try method(rt, r.map_prototype, "values", &map_values);
    try method(rt, r.map_prototype, "entries", &map_entries);
    try method(rt, r.map_prototype, "forEach", &map_for_each);
    try method(rt, r.set_prototype, "add", &set_add);
    try method(rt, r.set_prototype, "has", &set_has);
    try method(rt, r.set_prototype, "delete", &set_delete);
    try method(rt, r.set_prototype, "clear", &set_clear);
    try method(rt, r.set_prototype, "keys", &set_values);
    try method(rt, r.set_prototype, "values", &set_values);
    try method(rt, r.set_prototype, "entries", &set_entries);
    try method(rt, r.set_prototype, "forEach", &set_for_each);
    try method(rt, r.promise_prototype, "then", &promise_then);
    try method(rt, r.promise_prototype, "catch", &promise_catch);
    try method(rt, r.promise_prototype, "finally", &promise_finally);
    try method(rt, r.promise_namespace, "resolve", &promise_resolve_static);
    try method(rt, r.promise_namespace, "reject", &promise_reject_static);
    try method(rt, r.promise_namespace, "all", &promise_all_static);
    try method(rt, r.promise_namespace, "allSettled", &promise_all_settled_static);
    try method(rt, r.promise_namespace, "race", &promise_race_static);
    try method(rt, r.promise_namespace, "any", &promise_any_static);
    try method(rt, r.iterator_prototype, "next", &iterator_next);
    try registerMath(rt, r.math);
    try method(rt, r.json, "parse", &json.parse_native);
    try method(rt, r.json, "stringify", &json.stringify_native);
    _ = &r;
    rt.realm = r;
    return &rt.realm.?;
}

fn builtin(h: *heap_mod.Heap, proto: ?*Object, b: names.Builtin) Error!*Object {
    const o = try h.newObject(proto);
    o.builtin = b;
    return o;
}

fn method(rt: *Runtime, o: *Object, name: []const u8, n: *const Native) Error!void {
    const k = try rt.heap.internAscii(name);
    try rt.heap.defineProperty(o, k, .{ .value = .{ .native = n }, .enumerable = false });
}

fn constant(rt: *Runtime, o: *Object, name: []const u8, v: Value) Error!void {
    const k = try rt.heap.internAscii(name);
    try rt.heap.defineProperty(o, k, .{ .value = v, .enumerable = false });
}

/// The natives ToPrimitive may call (D40); anything else found there is user code.
pub fn isConversion(n: *const Native) bool {
    return n == &object_to_string or n == &object_value_of or n == &array_to_string;
}

// ---------------------------------------------------------------- globals

pub const print: Native = .{ .name = "print", .call = printImpl };
pub const object_global: Native = .{ .name = "Object", .call = notCallable, .namespace = .object };
pub const array_global: Native = .{ .name = "Array", .call = notCallable, .namespace = .array };
pub const map_global: Native = .{ .name = "Map", .call = mapWithoutNew, .construct = mapConstruct, .namespace = .map };
pub const set_global: Native = .{ .name = "Set", .call = setWithoutNew, .construct = setConstruct, .namespace = .set };
pub const promise_global: Native = .{ .name = "Promise", .call = promiseWithoutNew, .construct = promiseConstruct, .namespace = .promise };

/// A global read: implemented, host-registered (M9.1, D53), known to node (Unsupported),
/// or a ReferenceError.
pub fn global(rt: *Runtime, name: []const u8) Error!Value {
    if (std.mem.eql(u8, name, "undefined")) return .undefined;
    if (std.mem.eql(u8, name, "NaN")) return .{ .number = std.math.nan(f64) };
    if (std.mem.eql(u8, name, "Infinity")) return .{ .number = std.math.inf(f64) };
    if (std.mem.eql(u8, name, "print")) return .{ .native = &print };
    if (std.mem.eql(u8, name, "Object")) return .{ .native = &object_global };
    if (std.mem.eql(u8, name, "Array")) return .{ .native = &array_global };
    if (std.mem.eql(u8, name, "Map")) return .{ .native = &map_global };
    if (std.mem.eql(u8, name, "Set")) return .{ .native = &set_global };
    if (std.mem.eql(u8, name, "Promise")) return .{ .native = &promise_global };
    if (std.mem.eql(u8, name, "Math")) return .{ .object = (try realm(rt)).math };
    if (std.mem.eql(u8, name, "JSON")) return .{ .object = (try realm(rt)).json };
    for (rt.host_globals.items) |n| if (std.mem.eql(u8, n.name, name)) return .{ .native = n };
    if (names.has(.global, name)) {
        rt.unsupported_name = try rt.heap.internAscii(name);
        return rt.fail(.builtin);
    }
    return rt.throw(.ReferenceError, &.{ .{ .ascii = name }, .{ .ascii = " is not defined" } });
}

/// Whether `name` is already a built-in or node-known global name (D53: duplicate
/// registration is rejected, including built-in names).
pub fn isBuiltinGlobal(name: []const u8) bool {
    return std.mem.eql(u8, name, "print") or names.has(.global, name);
}

fn notCallable(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    _ = this;
    _ = args;
    return rt.fail(.builtin); // Object(…) / Array(…): the constructors themselves
}

/// Evaluates `new callee(args...)` for built-in constructors (M14).
pub fn construct(rt: *Runtime, callee: Value, args: []const Value) Error!Value {
    return switch (callee) {
        .native => |n| if (n.construct) |c| c(rt, args) else rt.fail(.builtin),
        .closure => rt.fail(.builtin),
        else => rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }}),
    };
}

/// `print(a, b, …)` writes `String(a) + " " + String(b) + … + "\n"`. The node test
/// harness defines the same function, so outputs compare byte for byte.
fn printImpl(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    _ = this;
    for (args, 0..) |value, i| {
        if (i > 0) try rt.out.writeByte(' ');
        var buf: ops.NumberBuf = undefined;
        switch (try ops.toPiece(rt, value, &buf)) {
            .ascii => |s| try rt.out.writeAll(s),
            .utf16 => |units| try ops.writeUtf16(rt.out, units),
        }
    }
    try rt.out.writeByte('\n');
    return .undefined;
}

fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else .undefined;
}

/// A member called on a receiver it doesn't implement (e.g. push on a non-array):
/// node would do something generic that ZQJS doesn't.
fn unsupportedReceiver(rt: *Runtime, name: []const u8) Error {
    rt.unsupported_name = try rt.heap.internAscii(name);
    return rt.fail(.builtin);
}

// ---------------------------------------------------------------- Object.prototype

const object_to_string: Native = .{ .name = "toString", .call = objectToString };
const object_value_of: Native = .{ .name = "valueOf", .call = objectValueOf };

fn objectToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const tag: []const u8 = switch (this) {
        .undefined => "Undefined",
        .null => "Null",
        .boolean => "Boolean",
        .number => "Number",
        .string => "String",
        .native, .closure => "Function",
        .object => |o| switch (o.kind) {
            .array => "Array",
            .map => "Map",
            .set => "Set",
            .iterator => |it| switch (it.kind) {
                .map_entries, .map_keys, .map_values => "Map Iterator",
                .set_values, .set_entries => "Set Iterator",
                .array_values, .array_keys, .array_entries => "Array Iterator",
                .string_chars => "String Iterator",
            },
            .promise => "Promise",
            .ordinary => "Object",
        },
    };
    return .{ .string = try rt.heap.newString(&.{ .{ .ascii = "[object " }, .{ .ascii = tag }, .{ .ascii = "]" } }) };
}

fn objectValueOf(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return switch (this) {
        .object => this,
        else => unsupportedReceiver(rt, "valueOf"), // ToObject: a wrapper object
    };
}

// ---------------------------------------------------------------- Array.prototype

const array_push: Native = .{ .name = "push", .call = arrayPush };
const array_pop: Native = .{ .name = "pop", .call = arrayPop };
const array_slice: Native = .{ .name = "slice", .call = arraySlice };
const array_index_of: Native = .{ .name = "indexOf", .call = arrayIndexOf };
const array_includes: Native = .{ .name = "includes", .call = arrayIncludes };
const array_join: Native = .{ .name = "join", .call = arrayJoin };
const array_to_string: Native = .{ .name = "toString", .call = arrayToString };
const array_keys: Native = .{ .name = "keys", .call = arrayKeys };
const array_values: Native = .{ .name = "values", .call = arrayValues };
const array_entries: Native = .{ .name = "entries", .call = arrayEntries };
const array_for_each: Native = .{ .name = "forEach", .call = arrayForEach };
const array_map: Native = .{ .name = "map", .call = arrayMap };
const array_filter: Native = .{ .name = "filter", .call = arrayFilter };
const array_reduce: Native = .{ .name = "reduce", .call = arrayReduce };

fn requireCallable(rt: *Runtime, v: Value) Error!Value {
    return switch (v) {
        .native, .closure => v,
        else => rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }}),
    };
}

fn toIntegerOrInfinity(rt: *Runtime, v: Value) Error!f64 {
    const n = try ops.toNumber(rt, v);
    if (std.math.isNan(n) or n == 0) return 0;
    return @trunc(n);
}

fn resolveRelativeIndex(n: f64, len: usize) usize {
    const len_f: f64 = @floatFromInt(len);
    const k = if (n < 0) @max(len_f + n, 0) else @min(n, len_f);
    return @intFromFloat(k);
}

fn resolveSearchStart(n: f64, len: usize) ?usize {
    const len_f: f64 = @floatFromInt(len);
    if (n >= len_f) return null;
    if (n >= 0) return @intFromFloat(n);
    const k = len_f + n;
    return if (k < 0) 0 else @intFromFloat(k);
}

fn sameValueZero(a: Value, b: Value) bool {
    if (a == .number and b == .number and std.math.isNan(a.number) and std.math.isNan(b.number)) return true;
    return ops.strictEquals(a, b);
}

fn thisArray(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this == .object and this.object.kind == .array) return this.object;
    return unsupportedReceiver(rt, name);
}

fn arrayPush(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "push");
    try rt.heap.appendElements(a, args);
    return .{ .number = @floatFromInt(a.kind.array.items.len) };
}

fn arrayPop(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const a = try thisArray(rt, this, "pop");
    return rt.heap.popElement(a) orelse .undefined;
}

/// ZQJS arrays are always dense (D13), so `slice()` always returns a dense array;
/// sparse-array hole preservation is not supported because holes are rejected at creation.
fn arraySlice(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "slice");
    const items = a.kind.array.items;
    const start = if (arg(args, 0) == .undefined) 0 else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 0)), items.len);
    const end = if (arg(args, 1) == .undefined) items.len else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 1)), items.len);
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    if (start < end) try rt.heap.appendElements(out, items[start..end]);
    return .{ .object = out };
}

fn arrayIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "indexOf");
    const items = a.kind.array.items;
    if (items.len == 0) return .{ .number = -1 };
    const needle = arg(args, 0);
    const from_n = if (args.len >= 2) try toIntegerOrInfinity(rt, args[1]) else 0;
    const start = resolveSearchStart(from_n, items.len) orelse return .{ .number = -1 };
    for (items[start..], start..) |item, i| {
        if (ops.strictEquals(item, needle)) return .{ .number = @floatFromInt(i) };
    }
    return .{ .number = -1 };
}

fn arrayIncludes(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "includes");
    const items = a.kind.array.items;
    if (items.len == 0) return .{ .boolean = false };
    const needle = arg(args, 0);
    const from_n = if (args.len >= 2) try toIntegerOrInfinity(rt, args[1]) else 0;
    const start = resolveSearchStart(from_n, items.len) orelse return .{ .boolean = false };
    for (items[start..]) |item| {
        if (sameValueZero(item, needle)) return .{ .boolean = true };
    }
    return .{ .boolean = false };
}

fn arrayJoin(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "join");
    const sep = arg(args, 0);
    if (sep == .undefined) return .{ .string = try object.join(rt, a, &.{','}) };
    var buf: ops.NumberBuf = undefined;
    const piece = try ops.toPiece(rt, sep, &buf);
    const s = switch (piece) {
        .utf16 => |u| u,
        .ascii => (try rt.heap.newString(&.{piece})).units,
    };
    return .{ .string = try object.join(rt, a, s) };
}

/// Array.prototype.toString calls `this.join`; a user-replaced join is user code.
fn arrayToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const j = try object.get(rt, this, try object.named(rt, "join"));
    if (j == .native and j.native == &array_join) return arrayJoin(rt, this, &.{});
    if (j == .closure or j == .native) return rt.fail(.user_conversion);
    return objectToString(rt, this, &.{}); // join not callable: the Object.prototype one
}

fn arrayKeys(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisArray(rt, this, "keys");
    return .{ .object = try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .array_keys) };
}

fn arrayValues(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisArray(rt, this, "values");
    return .{ .object = try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .array_values) };
}

fn arrayEntries(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisArray(rt, this, "entries");
    return .{ .object = try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .array_entries) };
}

fn arrayForEach(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "forEach");
    const cb = try requireCallable(rt, arg(args, 0));
    const this_arg = arg(args, 1);
    const len = a.kind.array.items.len;
    var root_buf = [_]Value{ this, cb, this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (0..len) |i| {
        if (i >= a.kind.array.items.len) continue;
        const elem = a.kind.array.items[i];
        _ = try rt.callCallable(cb, this_arg, &.{ elem, .{ .number = @floatFromInt(i) }, this });
    }
    return .undefined;
}

fn arrayMap(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "map");
    const cb = try requireCallable(rt, arg(args, 0));
    const this_arg = arg(args, 1);
    const len = a.kind.array.items.len;
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ this, cb, this_arg, .{ .object = out }, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (0..len) |i| {
        if (i >= a.kind.array.items.len) return rt.fail(.sparse_array);
        const elem = a.kind.array.items[i];
        root_buf[4] = try rt.callCallable(cb, this_arg, &.{ elem, .{ .number = @floatFromInt(i) }, this });
        try rt.heap.appendElement(out, root_buf[4]);
        root_buf[4] = .undefined;
    }
    return .{ .object = out };
}

fn arrayFilter(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "filter");
    const cb = try requireCallable(rt, arg(args, 0));
    const this_arg = arg(args, 1);
    const len = a.kind.array.items.len;
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ this, cb, this_arg, .{ .object = out }, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (0..len) |i| {
        if (i >= a.kind.array.items.len) continue;
        const elem = a.kind.array.items[i];
        root_buf[4] = elem;
        const keep = try rt.callCallable(cb, this_arg, &.{ elem, .{ .number = @floatFromInt(i) }, this });
        if (ops.toBoolean(keep)) try rt.heap.appendElement(out, root_buf[4]);
        root_buf[4] = .undefined;
    }
    return .{ .object = out };
}

fn arrayReduce(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "reduce");
    const cb = try requireCallable(rt, arg(args, 0));
    const len = a.kind.array.items.len;
    var start: usize = 0;
    var acc: Value = undefined;
    if (args.len >= 2) {
        acc = args[1];
    } else {
        if (len == 0) return rt.throw(.TypeError, &.{.{ .ascii = "Reduce of empty array with no initial value" }});
        acc = a.kind.array.items[0];
        start = 1;
    }
    var root_buf = [_]Value{ this, cb, acc };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (start..len) |i| {
        if (i >= a.kind.array.items.len) continue;
        const elem = a.kind.array.items[i];
        root_buf[2] = try rt.callCallable(cb, .undefined, &.{ root_buf[2], elem, .{ .number = @floatFromInt(i) }, this });
    }
    return root_buf[2];
}

// ---------------------------------------------------------------- String.prototype

const string_char_at: Native = .{ .name = "charAt", .call = stringCharAt };
const string_char_code_at: Native = .{ .name = "charCodeAt", .call = stringCharCodeAt };
const string_slice: Native = .{ .name = "slice", .call = stringSlice };
const string_index_of: Native = .{ .name = "indexOf", .call = stringIndexOf };
const string_includes: Native = .{ .name = "includes", .call = stringIncludes };
const string_to_lower_case: Native = .{ .name = "toLowerCase", .call = stringToLowerCase };
const string_to_upper_case: Native = .{ .name = "toUpperCase", .call = stringToUpperCase };

fn thisString(rt: *Runtime, this: Value, name: []const u8) Error!*const heap_mod.String {
    return switch (this) {
        .string => |s| s,
        else => unsupportedReceiver(rt, name),
    };
}

fn toStringUnits(rt: *Runtime, v: Value) Error![]const u16 {
    if (v == .string) return v.string.units;
    var buf: ops.NumberBuf = undefined;
    const piece = try ops.toPiece(rt, v, &buf);
    return switch (piece) {
        .utf16 => |u| u,
        .ascii => (try rt.heap.newString(&.{piece})).units,
    };
}

fn stringCharAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisString(rt, this, "charAt");
    const pos = try toIntegerOrInfinity(rt, arg(args, 0));
    if (pos < 0 or pos >= @as(f64, @floatFromInt(s.units.len))) {
        return .{ .string = try rt.heap.newString(&.{}) };
    }
    const i: usize = @intFromFloat(pos);
    return .{ .string = try rt.heap.newString(&.{.{ .utf16 = s.units[i .. i + 1] }}) };
}

fn stringCharCodeAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisString(rt, this, "charCodeAt");
    const pos = try toIntegerOrInfinity(rt, arg(args, 0));
    if (pos < 0 or pos >= @as(f64, @floatFromInt(s.units.len))) return .{ .number = std.math.nan(f64) };
    return .{ .number = @floatFromInt(s.units[@intFromFloat(pos)]) }; // a UTF-16 code unit
}

fn stringSlice(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisString(rt, this, "slice");
    const len = s.units.len;
    const from = if (arg(args, 0) == .undefined) 0 else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 0)), len);
    const to = if (arg(args, 1) == .undefined) len else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 1)), len);
    if (from >= to) return .{ .string = try rt.heap.newString(&.{}) };
    return .{ .string = try rt.heap.newString(&.{.{ .utf16 = s.units[from..to] }}) };
}

fn stringIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisString(rt, this, "indexOf");
    const search = try toStringUnits(rt, arg(args, 0));
    const pos = try toIntegerOrInfinity(rt, arg(args, 1));
    const len = s.units.len;
    const start: usize = if (pos <= 0) 0 else if (pos >= @as(f64, @floatFromInt(len))) len else @intFromFloat(pos);
    if (search.len == 0) return .{ .number = @floatFromInt(start) };
    if (std.mem.indexOfPos(u16, s.units, start, search)) |idx| return .{ .number = @floatFromInt(idx) };
    return .{ .number = -1 };
}

fn stringIncludes(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisString(rt, this, "includes");
    const search = try toStringUnits(rt, arg(args, 0));
    const pos = try toIntegerOrInfinity(rt, arg(args, 1));
    const len = s.units.len;
    const start: usize = if (pos <= 0) 0 else if (pos >= @as(f64, @floatFromInt(len))) len else @intFromFloat(pos);
    if (search.len == 0) return .{ .boolean = true };
    return .{ .boolean = std.mem.indexOfPos(u16, s.units, start, search) != null };
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
        if (u >= 0x80) return unsupportedReceiver(rt, name);
        out[i] = if (upper)
            if (u >= 'a' and u <= 'z') u - 32 else u
        else if (u >= 'A' and u <= 'Z') u + 32 else u;
    }
    return .{ .string = try rt.heap.newString(&.{.{ .utf16 = out }}) };
}

fn stringToLowerCase(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try thisString(rt, this, "toLowerCase");
    return asciiCase(rt, s, "toLowerCase", false);
}

fn stringToUpperCase(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try thisString(rt, this, "toUpperCase");
    return asciiCase(rt, s, "toUpperCase", true);
}

// ---------------------------------------------------------------- Object, Array

const object_keys: Native = .{ .name = "keys", .call = objectKeys };
const object_create: Native = .{ .name = "create", .call = objectCreate };
const object_get_prototype_of: Native = .{ .name = "getPrototypeOf", .call = objectGetPrototypeOf };
const array_is_array: Native = .{ .name = "isArray", .call = arrayIsArray };

fn objectKeys(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    switch (arg(args, 0)) {
        .undefined, .null => return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }}),
        .boolean, .number => {},
        .native, .closure => return rt.fail(.function_properties),
        .string => |s| for (0..s.units.len) |i| try pushKey(rt, out, .{ .index = @intCast(i) }),
        .object => |o| {
            const keys = try object.ownKeys(rt, o);
            defer rt.gpa.free(keys);
            for (keys) |k| try pushKey(rt, out, k);
        },
    }
    return .{ .object = out };
}

fn pushKey(rt: *Runtime, out: *Object, k: object.Key) Error!void {
    const s = switch (k) {
        .atom => |a| a,
        .index => |i| blk: {
            var buf: [10]u8 = undefined;
            break :blk try rt.heap.ascii(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
        },
    };
    try rt.heap.appendElement(out, .{ .string = s });
}

fn objectCreate(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    if (args.len > 1 and args[1] != .undefined) return unsupportedReceiver(rt, "create"); // property descriptors
    const proto: ?*Object = switch (arg(args, 0)) {
        .object => |o| o,
        .null => null,
        // A function is an object in node; ZQJS functions aren't (yet).
        .native, .closure => return rt.fail(.function_properties),
        else => return rt.throw(.TypeError, &.{.{ .ascii = "Object prototype may only be an Object or null" }}),
    };
    return .{ .object = try rt.heap.newObject(proto) };
}

fn objectGetPrototypeOf(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try realm(rt);
    const p: ?*Object = switch (arg(args, 0)) {
        .undefined, .null => return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }}),
        .boolean => r.boolean_prototype,
        .number => r.number_prototype,
        .string => r.string_prototype,
        .native, .closure => r.function_prototype,
        .object => |o| o.proto,
    };
    return if (p) |o| .{ .object = o } else .null;
}

fn arrayIsArray(_: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = arg(args, 0);
    return .{ .boolean = v == .object and v.object.kind == .array };
}

// ---------------------------------------------------------------- Math (M11.3)

fn registerMath(rt: *Runtime, m: *Object) Error!void {
    try constant(rt, m, "E", .{ .number = std.math.e });
    try constant(rt, m, "LN2", .{ .number = std.math.ln2 });
    try constant(rt, m, "LN10", .{ .number = std.math.ln10 });
    try constant(rt, m, "LOG2E", .{ .number = std.math.log2e });
    try constant(rt, m, "LOG10E", .{ .number = std.math.log10e });
    try constant(rt, m, "PI", .{ .number = std.math.pi });
    try constant(rt, m, "SQRT1_2", .{ .number = std.math.sqrt1_2 });
    try constant(rt, m, "SQRT2", .{ .number = std.math.sqrt2 });

    try method(rt, m, "abs", &math_abs);
    try method(rt, m, "floor", &math_floor);
    try method(rt, m, "ceil", &math_ceil);
    try method(rt, m, "round", &math_round);
    try method(rt, m, "trunc", &math_trunc);
    try method(rt, m, "min", &math_min);
    try method(rt, m, "max", &math_max);
    try method(rt, m, "pow", &math_pow);
    try method(rt, m, "sqrt", &math_sqrt);
    try method(rt, m, "sin", &math_sin);
    try method(rt, m, "cos", &math_cos);
    try method(rt, m, "tan", &math_tan);
    try method(rt, m, "asin", &math_asin);
    try method(rt, m, "acos", &math_acos);
    try method(rt, m, "atan", &math_atan);
    try method(rt, m, "atan2", &math_atan2);
    try method(rt, m, "log", &math_log);
    try method(rt, m, "exp", &math_exp);
    try method(rt, m, "sign", &math_sign);
    try method(rt, m, "clz32", &math_clz32);
    try method(rt, m, "imul", &math_imul);
    try method(rt, m, "fround", &math_fround);
    try method(rt, m, "hypot", &math_hypot);
    try method(rt, m, "random", &math_random);
}

const math_abs: Native = .{ .name = "abs", .call = mathAbs };
const math_floor: Native = .{ .name = "floor", .call = mathFloor };
const math_ceil: Native = .{ .name = "ceil", .call = mathCeil };
const math_round: Native = .{ .name = "round", .call = mathRound };
const math_trunc: Native = .{ .name = "trunc", .call = mathTrunc };
const math_min: Native = .{ .name = "min", .call = mathMin };
const math_max: Native = .{ .name = "max", .call = mathMax };
const math_pow: Native = .{ .name = "pow", .call = mathPow };
const math_sqrt: Native = .{ .name = "sqrt", .call = mathSqrt };
const math_sin: Native = .{ .name = "sin", .call = mathSin };
const math_cos: Native = .{ .name = "cos", .call = mathCos };
const math_tan: Native = .{ .name = "tan", .call = mathTan };
const math_asin: Native = .{ .name = "asin", .call = mathAsin };
const math_acos: Native = .{ .name = "acos", .call = mathAcos };
const math_atan: Native = .{ .name = "atan", .call = mathAtan };
const math_atan2: Native = .{ .name = "atan2", .call = mathAtan2 };
const math_log: Native = .{ .name = "log", .call = mathLog };
const math_exp: Native = .{ .name = "exp", .call = mathExp };
const math_sign: Native = .{ .name = "sign", .call = mathSign };
const math_clz32: Native = .{ .name = "clz32", .call = mathClz32 };
const math_imul: Native = .{ .name = "imul", .call = mathImul };
const math_fround: Native = .{ .name = "fround", .call = mathFround };
const math_hypot: Native = .{ .name = "hypot", .call = mathHypot };
const math_random: Native = .{ .name = "random", .call = mathRandom };

fn mathAbs(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = @abs(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathFloor(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = @floor(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathCeil(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = @ceil(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathTrunc(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = @trunc(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathRound(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const x = try ops.toNumber(rt, arg(args, 0));
    if (!std.math.isFinite(x) or x == 0.0) return .{ .number = x };
    if (x >= -0.5 and x < 0.0) return .{ .number = -0.0 };
    if (@abs(x) >= 4503599627370496.0) return .{ .number = x };
    const f = @floor(x);
    return .{ .number = if (x - f >= 0.5) f + 1.0 else f };
}

fn mathMin(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    var best = std.math.inf(f64);
    var saw_nan = false;
    for (args) |a| {
        const v = try ops.toNumber(rt, a);
        if (std.math.isNan(v)) {
            saw_nan = true;
        } else if (!saw_nan) {
            if (v < best or (v == 0.0 and best == 0.0 and std.math.signbit(v))) best = v;
        }
    }
    return .{ .number = if (saw_nan) std.math.nan(f64) else best };
}

fn mathMax(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    var best = -std.math.inf(f64);
    var saw_nan = false;
    for (args) |a| {
        const v = try ops.toNumber(rt, a);
        if (std.math.isNan(v)) {
            saw_nan = true;
        } else if (!saw_nan) {
            if (v > best or (v == 0.0 and best == 0.0 and !std.math.signbit(v))) best = v;
        }
    }
    return .{ .number = if (saw_nan) std.math.nan(f64) else best };
}

fn mathPow(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const base = try ops.toNumber(rt, arg(args, 0));
    const exp = try ops.toNumber(rt, arg(args, 1));
    return .{ .number = ops.pow(base, exp) };
}

fn mathSqrt(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = std.math.sqrt(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathSin(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = std.math.sin(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathCos(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = std.math.cos(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathTan(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = std.math.tan(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathAsin(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = std.math.asin(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathAcos(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = std.math.acos(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathAtan(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = std.math.atan(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathAtan2(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const y = try ops.toNumber(rt, arg(args, 0));
    const x = try ops.toNumber(rt, arg(args, 1));
    return .{ .number = std.math.atan2(y, x) };
}

fn mathLog(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = @log(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathExp(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return .{ .number = @exp(try ops.toNumber(rt, arg(args, 0))) };
}

fn mathSign(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const x = try ops.toNumber(rt, arg(args, 0));
    if (std.math.isNan(x) or x == 0.0) return .{ .number = x };
    return .{ .number = if (x > 0.0) 1.0 else -1.0 };
}

fn toUint32(n: f64) u32 {
    if (!std.math.isFinite(n) or n == 0.0) return 0;
    const rem = @mod(@trunc(n), 4294967296.0);
    return @intFromFloat(rem);
}

fn mathClz32(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const u = toUint32(try ops.toNumber(rt, arg(args, 0)));
    return .{ .number = @floatFromInt(@clz(u)) };
}

fn mathImul(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const a: i32 = @bitCast(toUint32(try ops.toNumber(rt, arg(args, 0))));
    const b: i32 = @bitCast(toUint32(try ops.toNumber(rt, arg(args, 1))));
    return .{ .number = @floatFromInt(a *% b) };
}

fn mathFround(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const x = try ops.toNumber(rt, arg(args, 0));
    if (!std.math.isFinite(x) or x == 0.0) return .{ .number = x };
    return .{ .number = @as(f64, @floatCast(@as(f32, @floatCast(x)))) };
}

fn mathHypot(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    var max_abs: f64 = 0.0;
    var saw_inf = false;
    var saw_nan = false;
    for (args) |a| {
        const v = try ops.toNumber(rt, a);
        if (std.math.isInf(v)) {
            saw_inf = true;
        } else if (std.math.isNan(v)) {
            saw_nan = true;
        } else {
            const av = @abs(v);
            if (av > max_abs) max_abs = av;
        }
    }
    if (saw_inf) return .{ .number = std.math.inf(f64) };
    if (saw_nan) return .{ .number = std.math.nan(f64) };
    if (max_abs == 0.0) return .{ .number = 0.0 };
    var sum: f64 = 0.0;
    for (args) |a| {
        const v = try ops.toNumber(rt, a);
        const s = v / max_abs;
        sum += s * s;
    }
    return .{ .number = max_abs * std.math.sqrt(sum) };
}

fn mathRandom(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return .{ .number = rt.nextRandom() };
}

// ---------------------------------------------------------------- Map

const map_get: Native = .{ .name = "get", .call = mapGet };
const map_set: Native = .{ .name = "set", .call = mapSet };
const map_has: Native = .{ .name = "has", .call = mapHas };
const map_delete: Native = .{ .name = "delete", .call = mapDelete };
const map_clear: Native = .{ .name = "clear", .call = mapClear };
const map_keys: Native = .{ .name = "keys", .call = mapKeys };
const map_values: Native = .{ .name = "values", .call = mapValues };
const map_entries: Native = .{ .name = "entries", .call = mapEntries };
const map_for_each: Native = .{ .name = "forEach", .call = mapForEach };

fn mapWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor Map requires 'new'" }});
}

fn mapConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    const m = try rt.heap.newMap(r.map_prototype);
    const iterable = arg(args, 0);
    if (iterable == .undefined or iterable == .null) return .{ .object = m };
    const iter = try getIterator(rt, iterable);
    while (try iteratorNextVal(rt, iter)) |entry| {
        if (entry != .object) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Iterator value is not an entry object" }});
        }
        const k = try object.get(rt, entry, .{ .index = 0 });
        const v = try object.get(rt, entry, .{ .index = 1 });
        try rt.heap.mapSet(m, k, v);
    }
    return .{ .object = m };
}

fn thisMap(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this == .object and this.object.kind == .map) return this.object;
    return unsupportedReceiver(rt, name);
}

fn mapGet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "get");
    return heap_mod.Heap.mapGet(m, arg(args, 0)) orelse .undefined;
}

fn mapSet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "set");
    try rt.heap.mapSet(m, arg(args, 0), arg(args, 1));
    return this;
}

fn mapHas(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "has");
    return .{ .boolean = heap_mod.Heap.mapHas(m, arg(args, 0)) };
}

fn mapDelete(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "delete");
    return .{ .boolean = heap_mod.Heap.mapDelete(m, arg(args, 0)) };
}

fn mapClear(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const m = try thisMap(rt, this, "clear");
    heap_mod.Heap.mapClear(m);
    return .undefined;
}

fn mapKeys(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisMap(rt, this, "keys");
    return .{ .object = try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .map_keys) };
}

fn mapValues(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisMap(rt, this, "values");
    return .{ .object = try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .map_values) };
}

fn mapEntries(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisMap(rt, this, "entries");
    return .{ .object = try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .map_entries) };
}

fn mapForEach(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "forEach");
    const cb = try requireCallable(rt, arg(args, 0));
    const this_arg = arg(args, 1);
    var root_buf = [_]Value{ this, cb, this_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var i: usize = 0;
    while (i < m.kind.map.entries.items.len) : (i += 1) {
        const e = m.kind.map.entries.items[i];
        if (!e.alive) continue;
        root_buf[3] = e.key;
        root_buf[4] = e.value;
        _ = try rt.callCallable(cb, this_arg, &.{ e.value, e.key, this });
        root_buf[3] = .undefined;
        root_buf[4] = .undefined;
    }
    return .undefined;
}

// ---------------------------------------------------------------- Set

const set_add: Native = .{ .name = "add", .call = setAdd };
const set_has: Native = .{ .name = "has", .call = setHas };
const set_delete: Native = .{ .name = "delete", .call = setDelete };
const set_clear: Native = .{ .name = "clear", .call = setClear };
const set_values: Native = .{ .name = "values", .call = setValues };
const set_entries: Native = .{ .name = "entries", .call = setEntries };
const set_for_each: Native = .{ .name = "forEach", .call = setForEach };

fn setWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor Set requires 'new'" }});
}

fn setConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    const s = try rt.heap.newSet(r.set_prototype);
    const iterable = arg(args, 0);
    if (iterable == .undefined or iterable == .null) return .{ .object = s };
    const iter = try getIterator(rt, iterable);
    while (try iteratorNextVal(rt, iter)) |v| {
        try rt.heap.setAdd(s, v);
    }
    return .{ .object = s };
}

fn thisSet(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this == .object and this.object.kind == .set) return this.object;
    return unsupportedReceiver(rt, name);
}

fn setAdd(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "add");
    try rt.heap.setAdd(s, arg(args, 0));
    return this;
}

fn setHas(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "has");
    return .{ .boolean = heap_mod.Heap.setHas(s, arg(args, 0)) };
}

fn setDelete(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "delete");
    return .{ .boolean = heap_mod.Heap.setDelete(s, arg(args, 0)) };
}

fn setClear(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try thisSet(rt, this, "clear");
    heap_mod.Heap.setClear(s);
    return .undefined;
}

fn setValues(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisSet(rt, this, "values");
    return .{ .object = try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .set_values) };
}

fn setEntries(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisSet(rt, this, "entries");
    return .{ .object = try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .set_entries) };
}

fn setForEach(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "forEach");
    const cb = try requireCallable(rt, arg(args, 0));
    const this_arg = arg(args, 1);
    var root_buf = [_]Value{ this, cb, this_arg, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var i: usize = 0;
    while (i < s.kind.set.entries.items.len) : (i += 1) {
        const e = s.kind.set.entries.items[i];
        if (!e.alive) continue;
        root_buf[3] = e.key;
        _ = try rt.callCallable(cb, this_arg, &.{ e.key, e.key, this });
        root_buf[3] = .undefined;
    }
    return .undefined;
}

// ---------------------------------------------------------------- Promise (M18)

const promise_resolve_static: Native = .{ .name = "resolve", .call = promiseResolveStatic };
const promise_reject_static: Native = .{ .name = "reject", .call = promiseRejectStatic };
const promise_all_static: Native = .{ .name = "all", .call = promiseAllStatic };
const promise_all_settled_static: Native = .{ .name = "allSettled", .call = promiseAllSettledStatic };
const promise_race_static: Native = .{ .name = "race", .call = promiseRaceStatic };
const promise_any_static: Native = .{ .name = "any", .call = promiseAnyStatic };
const promise_then: Native = .{ .name = "then", .call = promiseThen };
const promise_catch: Native = .{ .name = "catch", .call = promiseCatch };
const promise_finally: Native = .{ .name = "finally", .call = promiseFinally };

fn thisPromise(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this == .object and this.object.kind == .promise) return this.object;
    return unsupportedReceiver(rt, name);
}

fn promiseThen(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const p_obj = try thisPromise(rt, this, "then");
    const raw_f = arg(args, 0);
    const raw_r = arg(args, 1);
    const on_fulfilled: Value = if (raw_f == .native or raw_f == .closure) raw_f else .undefined;
    const on_rejected: Value = if (raw_r == .native or raw_r == .closure) raw_r else .undefined;

    var root_buf = [_]Value{ .{ .object = p_obj }, on_fulfilled, on_rejected, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const r = try realm(rt);
    const child = try rt.heap.newPromise(r.promise_prototype);
    root_buf[3] = .{ .object = child };
    const pr = &p_obj.kind.promise;

    if (pr.state == .pending) {
        try pr.reactions.ensureUnusedCapacity(rt.heap.allocator(), 1);
        pr.reactions.appendAssumeCapacity(.{
            .child = child,
            .on_fulfilled = on_fulfilled,
            .on_rejected = on_rejected,
        });
        rt.heap.barrier(&p_obj.obj, null, .{ .object = child });
        rt.heap.barrier(&p_obj.obj, null, on_fulfilled);
        rt.heap.barrier(&p_obj.obj, null, on_rejected);
    } else {
        const is_rejected = (pr.state == .rejected);
        const cb = if (is_rejected) on_rejected else on_fulfilled;
        const is_adopt = (cb != .native and cb != .closure);
        try rt.microtasks.ensureUnusedCapacity(rt.gpa, 1);
        rt.microtasks.appendAssumeCapacity(.{
            .kind = if (is_adopt) .adopt else .reaction,
            .child = child,
            .cb = cb,
            .arg = pr.result,
            .adopt_rejected = is_rejected,
        });
    }
    return .{ .object = child };
}

fn promiseCatch(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    _ = try thisPromise(rt, this, "catch");
    return promiseThen(rt, this, &.{ .undefined, arg(args, 0) });
}

fn promiseFinally(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const p_obj = try thisPromise(rt, this, "finally");
    const raw_f = arg(args, 0);
    if (raw_f != .native and raw_f != .closure) {
        return promiseThen(rt, this, &.{ raw_f, raw_f });
    }

    var root_buf = [_]Value{ .{ .object = p_obj }, raw_f, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const env = try rt.heap.newArray(null);
    root_buf[2] = .{ .object = env };
    try rt.heap.appendElements(env, &.{raw_f});

    const then_fn = try rt.heap.newNativeClosure(&finallyThenCb, env);
    root_buf[3] = .{ .closure = then_fn };
    const catch_fn = try rt.heap.newNativeClosure(&finallyCatchCb, env);
    root_buf[4] = .{ .closure = catch_fn };

    return promiseThen(rt, .{ .object = p_obj }, &.{ root_buf[3], root_buf[4] });
}

fn finallyThenCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    return finallyRunCb(rt, env, arg(args, 0), false);
}

fn finallyCatchCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    return finallyRunCb(rt, env, arg(args, 0), true);
}

fn finallyRunCb(rt: *Runtime, env: *Object, val: Value, is_catch: bool) Error!Value {
    var root_buf = [_]Value{ .{ .object = env }, val, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const on_finally = env.kind.array.items[0];
    const res = try rt.callCallable(on_finally, .undefined, &.{});
    root_buf[2] = res;
    const p_val = try resolveToPromise(rt, res);
    root_buf[3] = p_val;

    const env2 = try rt.heap.newArray(null);
    root_buf[4] = .{ .object = env2 };
    try rt.heap.appendElements(env2, &.{val});

    const cb_ptr: *const anyopaque = if (is_catch) &finallyThrower else &finallyValueThunk;
    const cb = try rt.heap.newNativeClosure(cb_ptr, env2);
    root_buf[5] = .{ .closure = cb };
    return promiseThen(rt, p_val, &.{root_buf[5]});
}

fn finallyValueThunk(_: *Runtime, env: *Object, _: []const Value) Error!Value {
    return env.kind.array.items[0];
}

fn finallyThrower(rt: *Runtime, env: *Object, _: []const Value) Error!Value {
    return rt.throwValue(env.kind.array.items[0]);
}

fn promiseWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor Promise requires 'new'" }});
}

fn promiseConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const exec = try requireCallable(rt, arg(args, 0));
    const r = try realm(rt);
    const p = try rt.heap.newPromise(r.promise_prototype);
    const res_cap = try rt.heap.newPromiseCapability(p, false);
    const rej_cap = try rt.heap.newPromiseCapability(p, true);
    const p_val: Value = .{ .object = p };
    const res_val: Value = .{ .closure = res_cap };
    const rej_val: Value = .{ .closure = rej_cap };

    var root_buf = [_]Value{ p_val, exec, res_val, rej_val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    _ = rt.callCallable(exec, .undefined, &.{ res_val, rej_val }) catch |e| {
        if (e != error.Thrown) return e;
        const err_val = try rt.catchValue();
        if (!p.kind.promise.already_resolved) {
            try settlePromiseFromJob(rt, p, true, err_val);
        }
    };
    return p_val;
}

fn resolveToPromise(rt: *Runtime, x: Value) Error!Value {
    const r = try realm(rt);
    if (x == .object and x.object.kind == .promise and x.object.proto == r.promise_prototype) {
        return x;
    }
    const p = try rt.heap.newPromise(r.promise_prototype);
    var root_buf = [_]Value{ .{ .object = p }, x };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    try resolvePromiseValue(rt, p, x);
    return .{ .object = p };
}

fn promiseResolveStatic(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return resolveToPromise(rt, arg(args, 0));
}

fn promiseRejectStatic(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const reason = arg(args, 0);
    const r = try realm(rt);
    const p = try rt.heap.newPromise(r.promise_prototype);
    try settlePromiseFromJob(rt, p, true, reason);
    return .{ .object = p };
}

const CombinatorKind = enum { all, all_settled, race, any };

fn promiseAllStatic(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return promiseCombinator(rt, .all, arg(args, 0));
}

fn promiseAllSettledStatic(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return promiseCombinator(rt, .all_settled, arg(args, 0));
}

fn promiseRaceStatic(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return promiseCombinator(rt, .race, arg(args, 0));
}

fn promiseAnyStatic(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return promiseCombinator(rt, .any, arg(args, 0));
}

fn promiseCombinator(rt: *Runtime, comptime kind: CombinatorKind, iterable: Value) Error!Value {
    const r = try realm(rt);
    const p_out = try rt.heap.newPromise(r.promise_prototype);

    var root_buf = [_]Value{
        .{ .object = p_out },
        iterable,
        .undefined, // [2] iter
        .undefined, // [3] results_arr
        .undefined, // [4] state_arr: [p_out, results_arr, remaining]
        .undefined, // [5] res_cap
        .undefined, // [6] rej_cap
        .undefined, // [7] elem
        .undefined, // [8] next_p
        .undefined, // [9] elem_env: [state_arr, index]
        .undefined, // [10] cb_f
        .undefined, // [11] cb_r
    };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const iter = getIterator(rt, iterable) catch |e| {
        if (e != error.Thrown) return e;
        const err_val = try rt.catchValue();
        try settlePromiseFromJob(rt, p_out, true, err_val);
        return .{ .object = p_out };
    };
    root_buf[2] = .{ .object = iter };

    if (kind != .race) {
        const results_arr = try rt.heap.newArray(r.array_prototype);
        root_buf[3] = .{ .object = results_arr };
        const state_arr = try rt.heap.newArray(null);
        root_buf[4] = .{ .object = state_arr };
        try rt.heap.appendElements(state_arr, &.{ .{ .object = p_out }, .{ .object = results_arr }, .{ .number = 0 } });
    }
    if (kind == .race or kind == .any) {
        const res_cap = try rt.heap.newPromiseCapability(p_out, false);
        root_buf[5] = .{ .closure = res_cap };
    }
    if (kind == .all or kind == .race) {
        const rej_cap = try rt.heap.newPromiseCapability(p_out, true);
        root_buf[6] = .{ .closure = rej_cap };
    }

    var count: usize = 0;
    while (true) {
        const maybe_elem = iteratorNextVal(rt, iter) catch |e| {
            if (e != error.Thrown) return e;
            const err_val = try rt.catchValue();
            try settlePromiseFromJob(rt, p_out, true, err_val);
            return .{ .object = p_out };
        };
        const elem = maybe_elem orelse break;
        root_buf[7] = elem;

        const next_p = try resolveToPromise(rt, elem);
        root_buf[8] = next_p;

        if (kind != .race) {
            try rt.heap.appendElements(root_buf[3].object, &.{.undefined});
            const elem_env = try rt.heap.newArray(null);
            root_buf[9] = .{ .object = elem_env };
            try rt.heap.appendElements(elem_env, &.{ root_buf[4], .{ .number = @floatFromInt(count) } });
        }

        const cb_f: Value = switch (kind) {
            .all => .{ .closure = try rt.heap.newNativeClosure(&allFulfillCb, root_buf[9].object) },
            .all_settled => .{ .closure = try rt.heap.newNativeClosure(&allSettledFulfillCb, root_buf[9].object) },
            .race, .any => root_buf[5],
        };
        root_buf[10] = cb_f;

        const cb_r: Value = switch (kind) {
            .all, .race => root_buf[6],
            .all_settled => .{ .closure = try rt.heap.newNativeClosure(&allSettledRejectCb, root_buf[9].object) },
            .any => .{ .closure = try rt.heap.newNativeClosure(&anyRejectCb, root_buf[9].object) },
        };
        root_buf[11] = cb_r;

        _ = try promiseThen(rt, next_p, &.{ cb_f, cb_r });
        count += 1;
    }

    if (count == 0) {
        switch (kind) {
            .all, .all_settled => try settlePromiseFromJob(rt, p_out, false, root_buf[3]),
            .race => {},
            .any => {
                const agg = try makeAggregateError(rt, root_buf[3]);
                root_buf[7] = agg;
                try settlePromiseFromJob(rt, p_out, true, agg);
            },
        }
    } else if (kind != .race) {
        // Set remaining count after iteration so reactions (queued via microtasks) see final count.
        rt.heap.storeElement(root_buf[4].object, 2, .{ .number = @floatFromInt(count) });
    }

    return .{ .object = p_out };
}

fn allFulfillCb(rt: *Runtime, elem_env: *Object, args: []const Value) Error!Value {
    const state_arr = elem_env.kind.array.items[0].object;
    const idx: usize = @intFromFloat(elem_env.kind.array.items[1].number);
    const p_out = state_arr.kind.array.items[0].object;
    if (p_out.kind.promise.already_resolved) return .undefined;

    const results_arr = state_arr.kind.array.items[1].object;
    rt.heap.storeElement(results_arr, idx, arg(args, 0));

    const rem: usize = @intFromFloat(state_arr.kind.array.items[2].number);
    const next_rem = rem - 1;
    rt.heap.storeElement(state_arr, 2, .{ .number = @floatFromInt(next_rem) });
    if (next_rem == 0) {
        try settlePromiseFromJob(rt, p_out, false, .{ .object = results_arr });
    }
    return .undefined;
}

fn allSettledFulfillCb(rt: *Runtime, elem_env: *Object, args: []const Value) Error!Value {
    return allSettledCb(rt, elem_env, arg(args, 0), false);
}

fn allSettledRejectCb(rt: *Runtime, elem_env: *Object, args: []const Value) Error!Value {
    return allSettledCb(rt, elem_env, arg(args, 0), true);
}

fn allSettledCb(rt: *Runtime, elem_env: *Object, val: Value, is_rejected: bool) Error!Value {
    // An iteration fault rejects p_out with `remaining` still 0; late reactions must not underflow it.
    if (elem_env.kind.array.items[0].object.kind.array.items[0].object.kind.promise.already_resolved) return .undefined;
    var root_buf = [_]Value{ .{ .object = elem_env }, val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const r = try realm(rt);
    const obj = try rt.heap.newObject(r.object_prototype);
    root_buf[2] = .{ .object = obj };
    const status_str = try rt.heap.newString(&.{.{ .ascii = if (is_rejected) "rejected" else "fulfilled" }});
    root_buf[3] = .{ .string = status_str };
    try object.define(rt, obj, try object.named(rt, "status"), root_buf[3]);
    try object.define(rt, obj, try object.named(rt, if (is_rejected) "reason" else "value"), val);

    const state_arr = elem_env.kind.array.items[0].object;
    const idx: usize = @intFromFloat(elem_env.kind.array.items[1].number);
    const p_out = state_arr.kind.array.items[0].object;
    const results_arr = state_arr.kind.array.items[1].object;

    rt.heap.storeElement(results_arr, idx, root_buf[2]);
    const rem: usize = @intFromFloat(state_arr.kind.array.items[2].number);
    const next_rem = rem - 1;
    rt.heap.storeElement(state_arr, 2, .{ .number = @floatFromInt(next_rem) });
    if (next_rem == 0) {
        try settlePromiseFromJob(rt, p_out, false, .{ .object = results_arr });
    }
    return .undefined;
}

fn anyRejectCb(rt: *Runtime, elem_env: *Object, args: []const Value) Error!Value {
    const state_arr = elem_env.kind.array.items[0].object;
    const p_out = state_arr.kind.array.items[0].object;
    if (p_out.kind.promise.already_resolved) return .undefined;

    const idx: usize = @intFromFloat(elem_env.kind.array.items[1].number);
    const errors_arr = state_arr.kind.array.items[1].object;
    rt.heap.storeElement(errors_arr, idx, arg(args, 0));

    const rem: usize = @intFromFloat(state_arr.kind.array.items[2].number);
    const next_rem = rem - 1;
    rt.heap.storeElement(state_arr, 2, .{ .number = @floatFromInt(next_rem) });
    if (next_rem == 0) {
        var root_buf = [_]Value{ .{ .object = p_out }, .{ .object = errors_arr }, .undefined };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);

        const agg = try makeAggregateError(rt, .{ .object = errors_arr });
        root_buf[2] = agg;
        try settlePromiseFromJob(rt, p_out, true, agg);
    }
    return .undefined;
}

fn makeAggregateError(rt: *Runtime, errors_arr_val: Value) Error!Value {
    const r = try realm(rt);
    var root_buf = [_]Value{ errors_arr_val, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const err_obj = try rt.heap.newObject(r.object_prototype);
    root_buf[1] = .{ .object = err_obj };
    const name_str = try rt.heap.newString(&.{.{ .ascii = "AggregateError" }});
    root_buf[2] = .{ .string = name_str };
    const msg_str = try rt.heap.newString(&.{.{ .ascii = "All promises were rejected" }});
    root_buf[3] = .{ .string = msg_str };
    try object.define(rt, err_obj, try object.named(rt, "name"), root_buf[2]);
    try object.define(rt, err_obj, try object.named(rt, "message"), root_buf[3]);
    try object.define(rt, err_obj, try object.named(rt, "errors"), errors_arr_val);
    return root_buf[1];
}

pub fn callPromiseCapability(rt: *Runtime, p_obj: *Object, is_reject: bool, args: []const Value) Error!Value {
    if (p_obj.kind.promise.already_resolved) return .undefined;
    const val = arg(args, 0);
    var root_buf = [_]Value{ .{ .object = p_obj }, val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (is_reject) {
        try settlePromiseFromJob(rt, p_obj, true, val);
    } else {
        try resolvePromiseValue(rt, p_obj, val);
    }
    return .undefined;
}

/// Atomic Promise resolution: all allocations and queue reservations succeed
/// before any Promise state or reaction list is mutated.
pub fn resolvePromiseValue(rt: *Runtime, p_obj: *Object, val: Value) Error!void {
    if (val == .object and val.object == p_obj) {
        const r = try realm(rt);
        var err_roots_buf = [_]Value{ .{ .object = p_obj }, .undefined, .undefined, .undefined };
        var err_roots: rt_mod.ValueRoots = .{ .values = &err_roots_buf };
        try err_roots.register(rt);
        defer err_roots.unregister(rt);

        const err_obj = try rt.heap.newObject(r.object_prototype);
        err_roots_buf[1] = .{ .object = err_obj };
        const name_str = try rt.heap.newString(&.{.{ .ascii = "TypeError" }});
        err_roots_buf[2] = .{ .string = name_str };
        const msg_str = try rt.heap.newString(&.{.{ .ascii = "Chaining cycle detected for promise" }});
        err_roots_buf[3] = .{ .string = msg_str };
        try object.define(rt, err_obj, try object.named(rt, "name"), err_roots_buf[2]);
        try object.define(rt, err_obj, try object.named(rt, "message"), err_roots_buf[3]);
        try settlePromiseFromJob(rt, p_obj, true, err_roots_buf[1]);
        return;
    }

    if (val == .object and val.object.kind == .promise) {
        try rt.microtasks.ensureUnusedCapacity(rt.gpa, 1);
        p_obj.kind.promise.already_resolved = true;
        rt.microtasks.appendAssumeCapacity(.{
            .kind = .resolve_promise,
            .child = p_obj,
            .cb = .undefined,
            .arg = val,
        });
        return;
    }

    try settlePromiseFromJob(rt, p_obj, false, val);
}

pub fn adoptPromiseNow(rt: *Runtime, p_obj: *Object, other: *Object) Error!void {
    const other_pr = &other.kind.promise;
    if (other_pr.state == .pending) {
        try other_pr.reactions.ensureUnusedCapacity(rt.heap.allocator(), 1);
        other_pr.reactions.appendAssumeCapacity(.{ .child = p_obj, .on_fulfilled = .undefined, .on_rejected = .undefined });
        rt.heap.barrier(&other.obj, null, .{ .object = p_obj });
    } else {
        try rt.microtasks.ensureUnusedCapacity(rt.gpa, 1);
        rt.microtasks.appendAssumeCapacity(.{
            .kind = .adopt,
            .child = p_obj,
            .cb = .undefined,
            .arg = other_pr.result,
            .adopt_rejected = (other_pr.state == .rejected),
        });
    }
}

/// Atomic Promise settlement: reserves microtask queue capacity before mutating
/// Promise state or moving reactions.
pub fn settlePromiseFromJob(rt: *Runtime, p_obj: *Object, is_rejected: bool, val: Value) Error!void {
    const pr = &p_obj.kind.promise;
    if (pr.state != .pending) return;
    try rt.microtasks.ensureUnusedCapacity(rt.gpa, pr.reactions.items.len);

    pr.already_resolved = true;
    pr.state = if (is_rejected) .rejected else .fulfilled;
    rt.heap.barrier(&p_obj.obj, pr.result, val);
    pr.result = val;

    for (pr.reactions.items) |rx| {
        const cb = if (is_rejected) rx.on_rejected else rx.on_fulfilled;
        const is_adopt = (cb != .native and cb != .closure);
        rt.microtasks.appendAssumeCapacity(.{
            .kind = if (is_adopt) .adopt else .reaction,
            .child = rx.child,
            .cb = cb,
            .arg = val,
            .adopt_rejected = is_rejected,
        });
    }
    pr.reactions.clearRetainingCapacity();
}

// ---------------------------------------------------------------- Iterators (M14.4)

const iterator_next: Native = .{ .name = "next", .call = iteratorNext };

pub fn getIterator(rt: *Runtime, iterable: Value) Error!*Object {
    const r = try realm(rt);
    return switch (iterable) {
        .object => |o| switch (o.kind) {
            .map => rt.heap.newIterator(r.iterator_prototype, iterable, .map_entries),
            .set => rt.heap.newIterator(r.iterator_prototype, iterable, .set_values),
            .array => rt.heap.newIterator(r.iterator_prototype, iterable, .array_values),
            .iterator => o,
            .ordinary, .promise => unsupportedReceiver(rt, "Symbol.iterator"),
        },
        .string => rt.heap.newIterator(r.iterator_prototype, iterable, .string_chars),
        else => rt.throw(.TypeError, &.{.{ .ascii = "value is not iterable" }}),
    };
}

fn makePairArray(rt: *Runtime, a: Value, b: Value) Error!Value {
    const r = try realm(rt);
    const pair = try rt.heap.newArray(r.array_prototype);
    try rt.heap.appendElements(pair, &.{ a, b });
    return .{ .object = pair };
}

pub fn iteratorNextVal(rt: *Runtime, iter: *Object) Error!?Value {
    const it = &iter.kind.iterator;
    if (it.done) return null;
    switch (it.kind) {
        .map_entries, .map_keys, .map_values => {
            const entries = it.target.object.kind.map.entries.items;
            while (it.cursor < entries.len) {
                const i = it.cursor;
                it.cursor += 1;
                const e = entries[i];
                if (!e.alive) continue;
                return switch (it.kind) {
                    .map_entries => try makePairArray(rt, e.key, e.value),
                    .map_keys => e.key,
                    .map_values => e.value,
                    else => unreachable,
                };
            }
        },
        .set_values, .set_entries => {
            const entries = it.target.object.kind.set.entries.items;
            while (it.cursor < entries.len) {
                const i = it.cursor;
                it.cursor += 1;
                const e = entries[i];
                if (!e.alive) continue;
                return switch (it.kind) {
                    .set_values => e.key,
                    .set_entries => try makePairArray(rt, e.key, e.key),
                    else => unreachable,
                };
            }
        },
        .array_values, .array_keys, .array_entries => {
            const items = it.target.object.kind.array.items;
            if (it.cursor < items.len) {
                const i = it.cursor;
                it.cursor += 1;
                const idx_val: Value = .{ .number = @floatFromInt(i) };
                return switch (it.kind) {
                    .array_values => items[i],
                    .array_keys => idx_val,
                    .array_entries => try makePairArray(rt, idx_val, items[i]),
                    else => unreachable,
                };
            }
        },
        .string_chars => {
            const units = it.target.string.units;
            if (it.cursor < units.len) {
                const start = it.cursor;
                const first = units[start];
                const step: usize = if (first >= 0xD800 and first <= 0xDBFF and
                    start + 1 < units.len and
                    units[start + 1] >= 0xDC00 and units[start + 1] <= 0xDFFF) 2 else 1;
                it.cursor += step;
                return .{ .string = try rt.heap.newString(&.{.{ .utf16 = units[start .. start + step] }}) };
            }
        },
    }
    it.done = true;
    it.target = .undefined; // permanently exhausted; allow target collection
    return null;
}

fn iteratorNext(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this != .object or this.object.kind != .iterator) return unsupportedReceiver(rt, "next");
    const r = try realm(rt);
    const next_v = try iteratorNextVal(rt, this.object);
    const out = try rt.heap.newObject(r.object_prototype);
    try object.define(rt, out, try object.named(rt, "value"), next_v orelse .undefined);
    try object.define(rt, out, try object.named(rt, "done"), .{ .boolean = next_v == null });
    return .{ .object = out };
}
