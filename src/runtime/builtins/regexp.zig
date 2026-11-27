//! RegExp and RegExp.prototype built-ins.

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
const Feature = @import("../../frontend/diag.zig").Feature;
const builtins = @import("../builtins.zig");
const common = @import("common.zig");

pub fn register(rt: *Runtime, r: *const builtins.Realm) Error!void {
    try common.immutableConstant(rt, r.regexp_namespace, "prototype", Value.fromObject(r.regexp_prototype));
    try common.constant(rt, r.regexp_prototype, "constructor", Value.fromNative(&builtins.regexp_global));
    try common.method(rt, r.regexp_namespace, "escape", &regexp_escape);
    try common.method(rt, r.regexp_prototype, "exec", &regexp_exec);
    try common.method(rt, r.regexp_prototype, "test", &regexp_test);
    try common.method(rt, r.regexp_prototype, "toString", &regexp_to_string);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "source"), Value.fromNative(&regexp_source_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "flags"), Value.fromNative(&regexp_flags_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "hasIndices"), Value.fromNative(&regexp_has_indices_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "global"), Value.fromNative(&regexp_global_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "ignoreCase"), Value.fromNative(&regexp_ignore_case_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "multiline"), Value.fromNative(&regexp_multiline_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "dotAll"), Value.fromNative(&regexp_dot_all_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "unicode"), Value.fromNative(&regexp_unicode_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "unicodeSets"), Value.fromNative(&regexp_unicode_sets_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "sticky"), Value.fromNative(&regexp_sticky_getter), false, false);
    try rt.heap.definePropKey(r.regexp_prototype, heap_mod.PropKey.fromSymbol(r.sym_match), .{
        .value = Value.fromNative(&regexp_sym_match),
        .enumerable = false,
    });
    try rt.heap.definePropKey(r.regexp_prototype, heap_mod.PropKey.fromSymbol(r.sym_replace), .{
        .value = Value.fromNative(&regexp_sym_replace),
        .enumerable = false,
    });
    try rt.heap.definePropKey(r.regexp_prototype, heap_mod.PropKey.fromSymbol(r.sym_search), .{
        .value = Value.fromNative(&regexp_sym_search),
        .enumerable = false,
    });
    try rt.heap.definePropKey(r.regexp_prototype, heap_mod.PropKey.fromSymbol(r.sym_split), .{
        .value = Value.fromNative(&regexp_sym_split),
        .enumerable = false,
    });
    try rt.heap.definePropKey(r.regexp_prototype, heap_mod.PropKey.fromSymbol(r.sym_match_all), .{
        .value = Value.fromNative(&regexp_sym_match_all),
        .enumerable = false,
    });
    try object.defineAccessor(rt, Value.fromObject(r.regexp_namespace), .{ .symbol = r.sym_species }, Value.fromNative(&common.species_getter), false, false);
}

const regexp_exec: Native = .{ .name = "exec", .length = 1, .call = regexpExec };

const regexp_test: Native = .{ .name = "test", .length = 1, .call = regexpTest };

const regexp_to_string: Native = .{ .name = "toString", .call = regexpToString };

fn thisRegExp(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .regexp) return this.asObject();
    return common.unsupportedReceiver(rt, name);
}

fn failRuntimeRegExp(rt: *Runtime, err: regex.CompileError, rx_diag: regex.Diagnostic) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SyntaxError => rt.throw(.SyntaxError, &.{.{ .ascii = rx_diag.message }}),
        error.TooComplex => rt.limit(rx_diag.limit),
        error.Unsupported => {
            const feat = if (rx_diag.feature) |f_name|
                std.meta.stringToEnum(Feature, f_name) orelse .syntax
            else
                .syntax;
            return rt.fail(feat);
        },
    };
}

pub fn createRegExp(rt: *Runtime, pattern_units: []const u16, flags_units: []const u16) Error!Value {
    var rx_diag: regex.Diagnostic = .{};
    const parsed_flags = regex.parseFlagsUtf16(flags_units, &rx_diag) catch |err| {
        return failRuntimeRegExp(rt, err, rx_diag);
    };
    var prog = regex.compileWithDepth(
        rt.heap.allocator(),
        pattern_units,
        parsed_flags.flags,
        rt.limits.max_nesting_depth,
        &rx_diag,
    ) catch |err| {
        if (err == error.OutOfMemory) return rt.heap.failed(error.OutOfMemory);
        return failRuntimeRegExp(rt, err, rx_diag);
    };
    var prog_owned = true;
    errdefer if (prog_owned) prog.deinit(rt.heap.allocator());

    const escaped = try regex.escapePattern(rt.gpa, pattern_units);
    defer rt.gpa.free(escaped);

    const r = try builtins.realm(rt);
    var root_buf = [_]Value{ .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const src_str = try rt.heap.newString(&.{.{ .utf16 = escaped }});
    root_buf[0] = Value.fromString(src_str);
    const flags_str = try rt.heap.ascii(parsed_flags.canonical());
    root_buf[1] = Value.fromString(flags_str);
    const obj = try rt.heap.newRegExp(r.regexp_prototype, prog, src_str, flags_str, parsed_flags.global);
    prog_owned = false;
    return Value.fromObject(obj);
}

pub fn newRegExpFromStrings(rt: *Runtime, pattern: *const heap_mod.String, flags: *const heap_mod.String) Error!Value {
    return createRegExp(rt, pattern.units, flags.units);
}

pub fn newRegExpFromLiteral(rt: *Runtime, pattern_units: []const u16, flags_ascii: []const u8) Error!Value {
    var flags_u16: [8]u16 = undefined;
    for (flags_ascii, 0..) |b, i| flags_u16[i] = b;
    return createRegExp(rt, pattern_units, flags_u16[0..flags_ascii.len]);
}

pub fn isRegExp(rt: *Runtime, v: Value) Error!bool {
    if (!v.isObjectLike()) return false;
    var root_buf = [_]Value{v};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const r = try builtins.realm(rt);
    const matcher = try object.get(rt, v, .{ .symbol = r.sym_match });
    if (!matcher.isUndefined()) return ops.toBoolean(matcher);
    return v.isObject() and v.asObject().kind == .regexp;
}

pub fn regexpBuild(rt: *Runtime, args: []const Value, is_new: bool) Error!Value {
    const p_arg = common.arg(args, 0);
    const f_arg = common.arg(args, 1);

    var root_buf = [_]Value{ p_arg, f_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const pattern_is_rx = try isRegExp(rt, p_arg);
    if (!is_new and pattern_is_rx and f_arg.isUndefined()) {
        const ctor = try object.get(rt, p_arg, try object.named(rt, "constructor"));
        if (ctor.isNative() and ctor.asNative() == &builtins.regexp_global) {
            return p_arg;
        }
    }

    if (p_arg.isObject() and p_arg.asObject().kind == .regexp) {
        const re = p_arg.asObject().kind.regexp;
        if (f_arg.isUndefined()) {
            const r = try builtins.realm(rt);
            var cloned_prog = re.program.clone(rt.heap.allocator()) catch |e| return rt.heap.failed(e);
            errdefer cloned_prog.deinit(rt.heap.allocator());
            const obj = try rt.heap.newRegExp(r.regexp_prototype, cloned_prog, re.source, re.flags, re.global);
            return Value.fromObject(obj);
        }
        const flags_str = try common.toStringObj(rt, f_arg);
        root_buf[2] = Value.fromString(flags_str);
        return createRegExp(rt, re.source.units, flags_str.units);
    }

    if (pattern_is_rx) {
        const pv = try object.get(rt, p_arg, try object.named(rt, "source"));
        root_buf[2] = pv;
        const fv = if (f_arg.isUndefined())
            try object.get(rt, p_arg, try object.named(rt, "flags"))
        else
            f_arg;
        root_buf[3] = fv;
        const pat_units: []const u16 = if (pv.isUndefined()) &.{} else blk: {
            const ps = try common.toStringObj(rt, pv);
            root_buf[2] = Value.fromString(ps);
            break :blk ps.units;
        };
        const flag_units: []const u16 = if (fv.isUndefined()) &.{} else blk: {
            const fs = try common.toStringObj(rt, fv);
            root_buf[3] = Value.fromString(fs);
            break :blk fs.units;
        };
        return createRegExp(rt, pat_units, flag_units);
    }

    const pat_units: []const u16 = if (p_arg.isUndefined()) &.{} else blk: {
        const ps = try common.toStringObj(rt, p_arg);
        root_buf[2] = Value.fromString(ps);
        break :blk ps.units;
    };
    const flag_units: []const u16 = if (f_arg.isUndefined()) &.{} else blk: {
        const fs = try common.toStringObj(rt, f_arg);
        root_buf[3] = Value.fromString(fs);
        break :blk fs.units;
    };
    return createRegExp(rt, pat_units, flag_units);
}

pub fn regexpCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return regexpBuild(rt, args, false);
}

pub fn regexpConstruct(rt: *Runtime, args: []const Value) Error!Value {
    return regexpBuild(rt, args, true);
}

pub fn runRegExpMatcher(
    rt: *Runtime,
    prog: *const regex.Program,
    input: []const u16,
    start: u32,
    captures: []?regex.Range,
) Error!bool {
    const initial_left: u64 = rt.max_steps -| rt.steps;
    var steps_left: u64 = initial_left;
    const matched = regex.exec(rt.heap.allocator(), prog, input, start, &steps_left, captures) catch |err| {
        const used = initial_left - steps_left;
        rt.steps += used;
        if (rt.exec_ctx.active) rt.exec_ctx.used = rt.steps;
        return switch (err) {
            error.StepLimit => {
                try rt.step();
                unreachable;
            },
            error.OutOfMemory => rt.heap.failed(error.OutOfMemory),
        };
    };
    const used = initial_left - steps_left;
    rt.steps += used;
    if (rt.exec_ctx.active) rt.exec_ctx.used = rt.steps;
    return matched;
}

const STACK_CAPTURES_LEN: usize = 16;

fn regexpExecIntoRooted(
    rt: *Runtime,
    rx_obj: *Object,
    s: *const heap_mod.String,
    captures: []?regex.Range,
) Error!bool {
    const re = rx_obj.kind.regexp;
    const global_or_sticky = re.global or re.program.flags.sticky;
    if (!global_or_sticky and re.last_index.isNumber()) {
        return runRegExpMatcher(rt, &re.program, s.units, 0, captures);
    }

    var last_idx = try common.toLength(rt, rx_obj.kind.regexp.last_index);
    if (!global_or_sticky) {
        last_idx = 0;
    }
    if (last_idx > @as(f64, @floatFromInt(s.units.len))) {
        if (global_or_sticky) try object.setStrict(rt, Value.fromObject(rx_obj), try object.named(rt, "lastIndex"), Value.fromNumber(0));
        return false;
    }
    const start: u32 = @intFromFloat(last_idx);
    const matched = try runRegExpMatcher(rt, &re.program, s.units, start, captures);
    if (!matched) {
        if (global_or_sticky) try object.setStrict(rt, Value.fromObject(rx_obj), try object.named(rt, "lastIndex"), Value.fromNumber(0));
        return false;
    }
    if (global_or_sticky) {
        try object.setStrict(rt, Value.fromObject(rx_obj), try object.named(rt, "lastIndex"), Value.fromNumber(@floatFromInt(captures[0].?.end)));
    }
    return true;
}

/// Runs ECMAScript `RegExpBuiltinExec` into caller-allocated `captures` (`len == capture_count + 1`),
/// updating `rx_obj.lastIndex` when `global` or `sticky` is set.
pub fn regexpExecInto(
    rt: *Runtime,
    rx_obj: *Object,
    s: *const heap_mod.String,
    captures: []?regex.Range,
) Error!bool {
    const re = rx_obj.kind.regexp;
    const global_or_sticky = re.global or re.program.flags.sticky;
    // Fast path: non-global/non-sticky with numeric lastIndex cannot invoke JS or trigger GC.
    if (!global_or_sticky and re.last_index.isNumber()) {
        return runRegExpMatcher(rt, &re.program, s.units, 0, captures);
    }

    var root_buf = [_]Value{ Value.fromObject(rx_obj), Value.fromString(s) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    return regexpExecIntoRooted(rt, rx_obj, s, captures);
}

pub fn advanceStringIndex(units: []const u16, idx: usize, is_unicode: bool) usize {
    if (!is_unicode or idx + 1 >= units.len) return idx + 1;
    const first = units[idx];
    const second = units[idx + 1];
    if (first >= 0xD800 and first <= 0xDBFF and second >= 0xDC00 and second <= 0xDFFF) {
        return idx + 2;
    }
    return idx + 1;
}

pub fn buildMatchGroupsObject(
    rt: *Runtime,
    named_groups: []const regex.NamedGroup,
    s_units: []const u16,
    captures: []const ?regex.Range,
) Error!*Object {
    const groups_obj = try rt.heap.newObject(null);
    var root_buf = [_]Value{ Value.fromObject(groups_obj), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (named_groups) |ng| {
        const key_atom = try rt.heap.intern(ng.name);
        const val: Value = if (captures[ng.capture_index]) |rng| blk: {
            const sub = try rt.heap.newString(&.{.{ .utf16 = s_units[rng.start..rng.end] }});
            root_buf[1] = Value.fromString(sub);
            break :blk root_buf[1];
        } else .undefined;
        try object.define(rt, groups_obj, object.namedAtom(key_atom), val);
        root_buf[1] = .undefined;
    }
    return groups_obj;
}

fn makeIndexPair(rt: *Runtime, r: *const builtins.Realm, rng: regex.Range) Error!Value {
    const pair = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{Value.fromObject(pair)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    try rt.heap.appendElement(pair, Value.fromNumber(@floatFromInt(rng.start)));
    try rt.heap.appendElement(pair, Value.fromNumber(@floatFromInt(rng.end)));
    return Value.fromObject(pair);
}

fn buildMatchIndicesArray(
    rt: *Runtime,
    r: *const builtins.Realm,
    named_groups: []const regex.NamedGroup,
    captures: []const ?regex.Range,
) Error!*Object {
    const indices_arr = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ Value.fromObject(indices_arr), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (captures) |maybe_rng| {
        if (maybe_rng) |rng| {
            root_buf[1] = try makeIndexPair(rt, r, rng);
            try rt.heap.appendElement(indices_arr, root_buf[1]);
            root_buf[1] = .undefined;
        } else {
            try rt.heap.appendElement(indices_arr, .undefined);
        }
    }

    if (named_groups.len > 0) {
        const idx_groups = try rt.heap.newObject(null);
        root_buf[2] = Value.fromObject(idx_groups);
        for (named_groups) |ng| {
            const key_atom = try rt.heap.intern(ng.name);
            const val: Value = if (captures[ng.capture_index]) |rng| blk: {
                root_buf[1] = try makeIndexPair(rt, r, rng);
                break :blk root_buf[1];
            } else .undefined;
            try object.define(rt, idx_groups, object.namedAtom(key_atom), val);
            root_buf[1] = .undefined;
        }
        try object.define(rt, indices_arr, try object.named(rt, "groups"), root_buf[2]);
    } else {
        try object.define(rt, indices_arr, try object.named(rt, "groups"), .undefined);
    }
    return indices_arr;
}

fn regexpExecImpl(rt: *Runtime, rx_obj: *Object, s: *const heap_mod.String) Error!Value {
    var root_buf = [_]Value{ Value.fromObject(rx_obj), Value.fromString(s), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const prog = &rx_obj.kind.regexp.program;
    const cap_len = @as(usize, prog.capture_count) + 1;
    var stack_caps: [STACK_CAPTURES_LEN]?regex.Range = undefined;
    const captures = if (cap_len <= stack_caps.len)
        stack_caps[0..cap_len]
    else
        try rt.gpa.alloc(?regex.Range, cap_len);
    defer if (cap_len > stack_caps.len) rt.gpa.free(captures);

    if (!try regexpExecIntoRooted(rt, rx_obj, s, captures)) return .null;

    const r = try builtins.realm(rt);
    const arr = try rt.heap.newArray(r.array_prototype);
    root_buf[2] = Value.fromObject(arr);

    for (captures) |maybe_range| {
        if (maybe_range) |rng| {
            const sub = try rt.heap.newString(&.{.{ .utf16 = s.units[rng.start..rng.end] }});
            root_buf[3] = Value.fromString(sub);
            try rt.heap.appendElement(arr, root_buf[3]);
            root_buf[3] = .undefined;
        } else {
            try rt.heap.appendElement(arr, .undefined);
        }
    }
    try object.define(rt, arr, try object.named(rt, "index"), Value.fromNumber(@floatFromInt(captures[0].?.start)));
    try object.define(rt, arr, try object.named(rt, "input"), Value.fromString(s));

    const groups_val: Value = if (prog.named_groups.len > 0) blk: {
        const g = try buildMatchGroupsObject(rt, prog.named_groups, s.units, captures);
        root_buf[3] = Value.fromObject(g);
        break :blk root_buf[3];
    } else .undefined;
    try object.define(rt, arr, try object.named(rt, "groups"), groups_val);
    root_buf[3] = .undefined;

    if (prog.flags.has_indices) {
        const indices_arr = try buildMatchIndicesArray(rt, r, prog.named_groups, captures);
        root_buf[3] = Value.fromObject(indices_arr);
        try object.define(rt, arr, try object.named(rt, "indices"), root_buf[3]);
        root_buf[3] = .undefined;
    }
    return Value.fromObject(arr);
}

fn regexpExec(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().kind != .regexp) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype.exec called on incompatible receiver" }});
    }
    const rx_obj = this.asObject();
    const arg0 = common.arg(args, 0);
    if (arg0.isString()) {
        return regexpExecImpl(rt, rx_obj, arg0.asString());
    }
    var root_buf = [_]Value{ Value.fromObject(rx_obj), arg0 };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try common.toStringObj(rt, root_buf[1]);
    return regexpExecImpl(rt, rx_obj, s);
}

fn regexpTest(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().kind != .regexp) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype.test called on incompatible receiver" }});
    }
    const rx_obj = this.asObject();
    const arg0 = common.arg(args, 0);
    const re = rx_obj.kind.regexp;
    const global_or_sticky = re.global or re.program.flags.sticky;
    const cap_len = @as(usize, re.program.capture_count) + 1;

    var stack_caps: [STACK_CAPTURES_LEN]?regex.Range = undefined;

    // Zero-root, zero-allocation fast path: non-global/non-sticky regex with numeric
    // lastIndex and string input cannot invoke JS or trigger GC inside runRegExpMatcher.
    if (!global_or_sticky and re.last_index.isNumber() and arg0.isString()) {
        const captures = if (cap_len <= stack_caps.len)
            stack_caps[0..cap_len]
        else
            try rt.gpa.alloc(?regex.Range, cap_len);
        defer if (cap_len > stack_caps.len) rt.gpa.free(captures);
        return Value.fromBool(try runRegExpMatcher(rt, &re.program, arg0.asString().units, 0, captures));
    }

    var root_buf = [_]Value{ Value.fromObject(rx_obj), arg0, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try common.toStringObj(rt, root_buf[1]);
    root_buf[2] = Value.fromString(s);

    const captures = if (cap_len <= stack_caps.len)
        stack_caps[0..cap_len]
    else
        try rt.gpa.alloc(?regex.Range, cap_len);
    defer if (cap_len > stack_caps.len) rt.gpa.free(captures);

    return Value.fromBool(try regexpExecIntoRooted(rt, rx_obj, s, captures));
}

const regexp_source_getter: Native = .{ .name = "get source", .call = regexpSourceGetter };

const regexp_flags_getter: Native = .{ .name = "get flags", .call = regexpFlagsGetter };

const regexp_has_indices_getter: Native = .{ .name = "get hasIndices", .call = regexpHasIndicesGetter };

const regexp_global_getter: Native = .{ .name = "get global", .call = regexpGlobalGetter };

const regexp_ignore_case_getter: Native = .{ .name = "get ignoreCase", .call = regexpIgnoreCaseGetter };

const regexp_multiline_getter: Native = .{ .name = "get multiline", .call = regexpMultilineGetter };

const regexp_dot_all_getter: Native = .{ .name = "get dotAll", .call = regexpDotAllGetter };

const regexp_unicode_getter: Native = .{ .name = "get unicode", .call = regexpUnicodeGetter };

const regexp_unicode_sets_getter: Native = .{ .name = "get unicodeSets", .call = regexpUnicodeSetsGetter };

const regexp_sticky_getter: Native = .{ .name = "get sticky", .call = regexpStickyGetter };

fn regexpSourceGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype.source getter called on non-object" }});
    }
    const o = this.asObject();
    if (o.kind == .regexp) return Value.fromString(o.kind.regexp.source);
    if (o == (try builtins.realm(rt)).regexp_prototype) return Value.fromString(try rt.heap.ascii("(?:)"));
    return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype.source getter called on incompatible receiver" }});
}

fn regexpFlagsGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() and !this.isClosure() and !this.isNative()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype.flags getter called on non-object" }});
    }
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const spec = [_]struct { name: []const u8, ch: u8 }{
        .{ .name = "hasIndices", .ch = 'd' },
        .{ .name = "global", .ch = 'g' },
        .{ .name = "ignoreCase", .ch = 'i' },
        .{ .name = "multiline", .ch = 'm' },
        .{ .name = "dotAll", .ch = 's' },
        .{ .name = "unicode", .ch = 'u' },
        .{ .name = "unicodeSets", .ch = 'v' },
        .{ .name = "sticky", .ch = 'y' },
    };
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    for (spec) |entry| {
        const v = try object.get(rt, this, try object.named(rt, entry.name));
        if (ops.toBoolean(v)) {
            buf[len] = entry.ch;
            len += 1;
        }
    }
    return Value.fromString(try rt.heap.ascii(buf[0..len]));
}

fn regexpFlagGetter(
    rt: *Runtime,
    this: Value,
    comptime field: enum { has_indices, global, ignore_case, multiline, dot_all, unicode, unicode_sets, sticky },
) Error!Value {
    if (!this.isObject()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype flag getter called on non-object" }});
    }
    const o = this.asObject();
    if (o.kind == .regexp) {
        const re = o.kind.regexp;
        return Value.fromBool(switch (field) {
            .has_indices => re.program.flags.has_indices,
            .global => re.global,
            .ignore_case => re.program.flags.ignore_case,
            .multiline => re.program.flags.multiline,
            .dot_all => re.program.flags.dot_all,
            .unicode => re.program.flags.unicode,
            .unicode_sets => re.program.flags.unicode_sets,
            .sticky => re.program.flags.sticky,
        });
    }
    if (o == (try builtins.realm(rt)).regexp_prototype) return .undefined;
    return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype flag getter called on incompatible receiver" }});
}

fn regexpHasIndicesGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .has_indices);
}

fn regexpGlobalGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .global);
}

fn regexpIgnoreCaseGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .ignore_case);
}

fn regexpMultilineGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .multiline);
}

fn regexpDotAllGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .dot_all);
}

fn regexpUnicodeGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .unicode);
}

fn regexpUnicodeSetsGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .unicode_sets);
}

fn regexpStickyGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .sticky);
}

fn regexpToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() and !this.isClosure() and !this.isNative()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype.toString requires that 'this' be an Object" }});
    }
    var root_buf = [_]Value{ this, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const pattern = try common.toStringObj(rt, try object.get(rt, this, try object.named(rt, "source")));
    root_buf[1] = Value.fromString(pattern);
    const flags = try common.toStringObj(rt, try object.get(rt, this, try object.named(rt, "flags")));
    root_buf[2] = Value.fromString(flags);
    return Value.fromString(try rt.heap.newString(&.{
        .{ .ascii = "/" },
        .{ .utf16 = pattern.units },
        .{ .ascii = "/" },
        .{ .utf16 = flags.units },
    }));
}

const regexp_escape: Native = .{ .name = "escape", .length = 1, .call = regexpEscape };

fn appendHexEscape(rt: *Runtime, out: *std.ArrayList(u16), cp: u16) Error!void {
    const hex = "0123456789abcdef";
    if (cp < 0x100) {
        try common.appendUnits(rt, out, &.{ '\\', 'x', hex[(cp >> 4) & 0xF], hex[cp & 0xF] });
    } else {
        try common.appendUnits(rt, out, &.{ '\\', 'u', hex[(cp >> 12) & 0xF], hex[(cp >> 8) & 0xF], hex[(cp >> 4) & 0xF], hex[cp & 0xF] });
    }
}

fn regexpEscape(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = common.arg(args, 0);
    if (!v.isString()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.escape requires a string argument" }});
    }
    const units = v.asString().units;
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);

    var i: usize = 0;
    while (i < units.len) {
        const u = units[i];
        // Valid surrogate pair passes through verbatim
        if (u >= 0xD800 and u <= 0xDBFF and i + 1 < units.len) {
            const lo_u = units[i + 1];
            if (lo_u >= 0xDC00 and lo_u <= 0xDFFF) {
                try common.appendUnits(rt, &out, units[i .. i + 2]);
                i += 2;
                continue;
            }
        }
        // Lone surrogate -> \uHHHH
        if (u >= 0xD800 and u <= 0xDFFF) {
            try appendHexEscape(rt, &out, u);
            i += 1;
            continue;
        }
        // Leading ASCII letter or digit -> \xHH
        if (i == 0 and ((u >= '0' and u <= '9') or (u >= 'A' and u <= 'Z') or (u >= 'a' and u <= 'z'))) {
            try appendHexEscape(rt, &out, u);
            i += 1;
            continue;
        }
        switch (u) {
            '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => {
                try common.appendUnits(rt, &out, &.{ '\\', u });
            },
            0x09 => try common.appendUnits(rt, &out, &.{ '\\', 't' }),
            0x0A => try common.appendUnits(rt, &out, &.{ '\\', 'n' }),
            0x0B => try common.appendUnits(rt, &out, &.{ '\\', 'v' }),
            0x0C => try common.appendUnits(rt, &out, &.{ '\\', 'f' }),
            0x0D => try common.appendUnits(rt, &out, &.{ '\\', 'r' }),
            ',', '-', '=', '<', '>', '#', '&', '!', '%', ':', ';', '@', '~', '\'', '`', '"', ' ' => {
                try appendHexEscape(rt, &out, u);
            },
            else => {
                if (common.isJsWhitespace(u)) {
                    try appendHexEscape(rt, &out, u);
                } else {
                    try common.appendUnits(rt, &out, &.{u});
                }
            },
        }
        i += 1;
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

const regexp_sym_match: Native = .{ .name = "[Symbol.match]", .length = 1, .call = regexpSymMatch };

const regexp_sym_replace: Native = .{ .name = "[Symbol.replace]", .length = 2, .call = regexpSymReplace };

const regexp_sym_search: Native = .{ .name = "[Symbol.search]", .length = 1, .call = regexpSymSearch };

const regexp_sym_split: Native = .{ .name = "[Symbol.split]", .length = 2, .call = regexpSymSplit };

const regexp_sym_match_all: Native = .{ .name = "[Symbol.matchAll]", .length = 1, .call = regexpSymMatchAll };

pub fn regExpExecGeneric(rt: *Runtime, rx: Value, s_val: Value) Error!Value {
    var root_buf = [_]Value{ rx, s_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const exec_fn = try object.get(rt, rx, try object.named(rt, "exec"));
    root_buf[2] = exec_fn;
    if (exec_fn.isFunction()) {
        const res = try rt.callCallable(exec_fn, rx, &.{s_val});
        if (!res.isObjectLike() and !res.isNull()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "RegExp exec method returned something other than an Object or null" }});
        }
        return res;
    }
    if (rx.isObject() and rx.asObject().kind == .regexp) {
        return regexpExecImpl(rt, rx.asObject(), s_val.asString());
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "RegExp exec called on incompatible receiver" }});
}

fn regexpSymMatch(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype[Symbol.match] called on non-object" }});
    }
    var root_buf = [_]Value{ this, common.arg(args, 0), .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try common.toStringObj(rt, root_buf[1]);
    const s_val = Value.fromString(s);
    root_buf[2] = s_val;

    const flags_val = try object.get(rt, this, try object.named(rt, "flags"));
    const flags_s = try common.toStringObj(rt, flags_val);
    root_buf[3] = Value.fromString(flags_s);
    const is_global = std.mem.indexOfScalar(u16, flags_s.units, 'g') != null;

    if (!is_global) {
        return regExpExecGeneric(rt, this, s_val);
    }

    const full_unicode = std.mem.indexOfScalar(u16, flags_s.units, 'u') != null or
        std.mem.indexOfScalar(u16, flags_s.units, 'v') != null;
    try object.setStrict(rt, this, try object.named(rt, "lastIndex"), Value.fromNumber(0));

    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    root_buf[4] = Value.fromObject(out);

    while (true) {
        const res = try regExpExecGeneric(rt, this, s_val);
        if (res.isNull()) {
            if (out.kind.array.items.len == 0) return .null;
            return Value.fromObject(out);
        }
        root_buf[5] = res;
        const m0 = try object.get(rt, res, .{ .index = 0 });
        const m_str = try common.toStringObj(rt, m0);
        root_buf[5] = Value.fromString(m_str);
        try rt.heap.appendElement(out, root_buf[5]);
        if (m_str.units.len == 0) {
            const li_val = try object.get(rt, this, try object.named(rt, "lastIndex"));
            const this_idx = try common.toLength(rt, li_val);
            const next_idx = advanceStringIndex(s.units, @intFromFloat(this_idx), full_unicode);
            try object.setStrict(rt, this, try object.named(rt, "lastIndex"), Value.fromNumber(@floatFromInt(next_idx)));
        }
        root_buf[5] = .undefined;
    }
}

fn expandGenericReplacement(
    rt: *Runtime,
    out: *std.ArrayList(u16),
    matched_units: []const u16,
    s_units: []const u16,
    pos: usize,
    captures: []const Value,
    named_captures: Value,
    repl_units: []const u16,
) Error!void {
    const tail_pos = @min(pos + matched_units.len, s_units.len);
    const m = captures.len;
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
                    try common.appendUnits(rt, out, matched_units);
                    i += 2;
                    continue;
                },
                '`' => {
                    try common.appendUnits(rt, out, s_units[0..@min(pos, s_units.len)]);
                    i += 2;
                    continue;
                },
                '\'' => {
                    try common.appendUnits(rt, out, s_units[tail_pos..]);
                    i += 2;
                    continue;
                },
                '0'...'9' => {
                    const d1: usize = next - '0';
                    if (i + 2 < repl_units.len and repl_units[i + 2] >= '0' and repl_units[i + 2] <= '9') {
                        const d2: usize = repl_units[i + 2] - '0';
                        const two = d1 * 10 + d2;
                        if (two >= 1 and two <= m) {
                            const cv = captures[two - 1];
                            if (cv.isString()) try common.appendUnits(rt, out, cv.asString().units);
                            i += 3;
                            continue;
                        }
                    }
                    if (d1 >= 1 and d1 <= m) {
                        const cv = captures[d1 - 1];
                        if (cv.isString()) try common.appendUnits(rt, out, cv.asString().units);
                        i += 2;
                        continue;
                    }
                },
                '<' => {
                    if (!named_captures.isUndefined()) {
                        if (std.mem.indexOfScalarPos(u16, repl_units, i + 2, '>')) |gt| {
                            const gname = repl_units[i + 2 .. gt];
                            const k = try object.keyUnits(rt, gname);
                            const cv = try object.get(rt, named_captures, k);
                            if (!cv.isUndefined()) {
                                const cs = try common.toStringObj(rt, cv);
                                try common.appendUnits(rt, out, cs.units);
                            }
                            i = gt + 1;
                            continue;
                        }
                    }
                },
                else => {},
            }
        }
        try common.appendUnits(rt, out, repl_units[i .. i + 1]);
        i += 1;
    }
}

fn regexpSymReplace(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype[Symbol.replace] called on non-object" }});
    }
    var root_buf = [_]Value{ this, common.arg(args, 0), common.arg(args, 1), .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try common.toStringObj(rt, root_buf[1]);
    const s_val = Value.fromString(s);
    root_buf[3] = s_val;
    const repl_arg = root_buf[2];
    const functional = repl_arg.isFunction();
    const repl_str: ?*const heap_mod.String = if (!functional) blk: {
        const rs = try common.toStringObj(rt, repl_arg);
        root_buf[4] = Value.fromString(rs);
        break :blk rs;
    } else null;

    const flags_val = try object.get(rt, this, try object.named(rt, "flags"));
    const flags_s = try common.toStringObj(rt, flags_val);
    root_buf[5] = Value.fromString(flags_s);
    const is_global = std.mem.indexOfScalar(u16, flags_s.units, 'g') != null;
    const full_unicode = std.mem.indexOfScalar(u16, flags_s.units, 'u') != null or
        std.mem.indexOfScalar(u16, flags_s.units, 'v') != null;

    if (is_global) {
        try object.setStrict(rt, this, try object.named(rt, "lastIndex"), Value.fromNumber(0));
    }

    const r = try builtins.realm(rt);
    const results = try rt.heap.newArray(r.array_prototype);
    root_buf[6] = Value.fromObject(results);

    while (true) {
        const res = try regExpExecGeneric(rt, this, s_val);
        if (res.isNull()) break;
        try rt.heap.appendElement(results, res);
        if (!is_global) break;
        const m0 = try object.get(rt, res, .{ .index = 0 });
        const m_str = try common.toStringObj(rt, m0);
        if (m_str.units.len == 0) {
            const li_val = try object.get(rt, this, try object.named(rt, "lastIndex"));
            const this_idx = try common.toLength(rt, li_val);
            const next_idx = advanceStringIndex(s.units, @intFromFloat(this_idx), full_unicode);
            try object.setStrict(rt, this, try object.named(rt, "lastIndex"), Value.fromNumber(@floatFromInt(next_idx)));
        }
    }

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);
    var next_src_pos: usize = 0;

    for (results.kind.array.items) |res| {
        const res_len_f = try common.toLength(rt, try object.get(rt, res, try object.named(rt, "length")));
        const n_captures: usize = if (res_len_f > 1.0) @intFromFloat(res_len_f - 1.0) else 0;
        const matched = try common.toStringObj(rt, try object.get(rt, res, .{ .index = 0 }));
        const pos_raw = try common.toIntegerOrInfinity(rt, try object.get(rt, res, try object.named(rt, "index")));
        const pos: usize = @intFromFloat(@min(@max(pos_raw, 0.0), @as(f64, @floatFromInt(s.units.len))));

        const cap_vals = try rt.gpa.alloc(Value, n_captures);
        defer rt.gpa.free(cap_vals);
        @memset(cap_vals, .undefined);
        var cap_roots: rt_mod.ValueRoots = .{ .values = cap_vals };
        try cap_roots.register(rt);
        defer cap_roots.unregister(rt);

        var cap_i: usize = 0;
        while (cap_i < n_captures) : (cap_i += 1) {
            const cv = try object.get(rt, res, .{ .index = @intCast(cap_i + 1) });
            if (!cv.isUndefined()) {
                cap_vals[cap_i] = Value.fromString(try common.toStringObj(rt, cv));
            }
        }
        const named_captures = try object.get(rt, res, try object.named(rt, "groups"));
        var extra_roots_buf = [_]Value{ Value.fromString(matched), named_captures, .undefined };
        var extra_roots: rt_mod.ValueRoots = .{ .values = &extra_roots_buf };
        try extra_roots.register(rt);
        defer extra_roots.unregister(rt);

        var replacement_s: *const heap_mod.String = undefined;
        var use_expanded = false;
        if (functional) {
            const has_named = !named_captures.isUndefined();
            const argc = 1 + n_captures + 2 + @as(usize, if (has_named) 1 else 0);
            const cb_args = try rt.gpa.alloc(Value, argc);
            defer rt.gpa.free(cb_args);
            cb_args[0] = Value.fromString(matched);
            @memcpy(cb_args[1 .. 1 + n_captures], cap_vals);
            cb_args[1 + n_captures] = Value.fromNumber(@floatFromInt(pos));
            cb_args[2 + n_captures] = s_val;
            if (has_named) cb_args[3 + n_captures] = named_captures;
            const call_res = try rt.callCallable(repl_arg, .undefined, cb_args);
            replacement_s = try common.toStringObj(rt, call_res);
            extra_roots_buf[2] = Value.fromString(replacement_s);
        } else {
            if (!named_captures.isUndefined()) {
                extra_roots_buf[1] = try common.toObjectReceiver(rt, named_captures);
            }
            use_expanded = true;
        }
        if (pos >= next_src_pos) {
            try common.appendUnits(rt, &out, s.units[next_src_pos..pos]);
            if (use_expanded) {
                try expandGenericReplacement(rt, &out, matched.units, s.units, pos, cap_vals, extra_roots_buf[1], repl_str.?.units);
            } else {
                try common.appendUnits(rt, &out, replacement_s.units);
            }
            next_src_pos = @min(pos + matched.units.len, s.units.len);
        }
    }
    if (next_src_pos < s.units.len) {
        try common.appendUnits(rt, &out, s.units[next_src_pos..]);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn regexpSymSearch(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype[Symbol.search] called on non-object" }});
    }
    var root_buf = [_]Value{ this, common.arg(args, 0), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try common.toStringObj(rt, root_buf[1]);
    const s_val = Value.fromString(s);
    root_buf[2] = s_val;

    const li_key = try object.named(rt, "lastIndex");
    const prev_li = try object.get(rt, this, li_key);
    root_buf[3] = prev_li;
    if (!common.sameValue(prev_li, Value.fromNumber(0))) {
        try object.setStrict(rt, this, li_key, Value.fromNumber(0));
    }
    const res = try regExpExecGeneric(rt, this, s_val);
    root_buf[4] = res;
    const cur_li = try object.get(rt, this, li_key);
    if (!common.sameValue(cur_li, prev_li)) {
        try object.setStrict(rt, this, li_key, prev_li);
    }
    if (res.isNull()) return Value.fromNumber(-1);
    return object.get(rt, res, try object.named(rt, "index"));
}

fn regexpSymSplit(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype[Symbol.split] called on non-object" }});
    }
    var root_buf = [_]Value{ this, common.arg(args, 0), common.arg(args, 1), .undefined, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try common.toStringObj(rt, root_buf[1]);
    const s_val = Value.fromString(s);
    root_buf[3] = s_val;

    const ctor = try common.speciesConstructor(rt, this, Value.fromNative(&builtins.regexp_global));
    root_buf[4] = ctor;

    const flags_val = try object.get(rt, this, try object.named(rt, "flags"));
    const flags_s = try common.toStringObj(rt, flags_val);
    root_buf[5] = Value.fromString(flags_s);

    const unicode_matching = std.mem.indexOfScalar(u16, flags_s.units, 'u') != null or
        std.mem.indexOfScalar(u16, flags_s.units, 'v') != null;
    const new_flags: Value = if (std.mem.indexOfScalar(u16, flags_s.units, 'y') != null)
        Value.fromString(flags_s)
    else
        Value.fromString(try rt.heap.newString(&.{ .{ .utf16 = flags_s.units }, .{ .ascii = "y" } }));
    root_buf[5] = new_flags;

    const splitter = try common.constructValue(rt, ctor, &.{ this, new_flags });
    root_buf[6] = splitter;

    const r = try builtins.realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    root_buf[7] = Value.fromObject(out);

    const lim: u32 = if (root_buf[2].isUndefined()) std.math.maxInt(u32) else ops.toUint32(try ops.toNumber(rt, root_buf[2]));
    if (lim == 0) return Value.fromObject(out);

    const size = s.units.len;
    if (size == 0) {
        const z = try regExpExecGeneric(rt, splitter, s_val);
        if (!z.isNull()) return Value.fromObject(out);
        try rt.heap.appendElement(out, s_val);
        return Value.fromObject(out);
    }

    const li_key = try object.named(rt, "lastIndex");
    var p: usize = 0;
    var q: usize = 0;
    while (q < size) {
        try object.setStrict(rt, splitter, li_key, Value.fromNumber(@floatFromInt(q)));
        const z = try regExpExecGeneric(rt, splitter, s_val);
        if (z.isNull()) {
            q = advanceStringIndex(s.units, q, unicode_matching);
            continue;
        }
        var z_roots_buf = [_]Value{ z, .undefined };
        var z_roots: rt_mod.ValueRoots = .{ .values = &z_roots_buf };
        try z_roots.register(rt);
        defer z_roots.unregister(rt);

        const e_f = try common.toLength(rt, try object.get(rt, splitter, li_key));
        const e: usize = @min(@as(usize, @intFromFloat(e_f)), size);
        if (e == p) {
            q = advanceStringIndex(s.units, q, unicode_matching);
            continue;
        }
        const sub = try rt.heap.newString(&.{.{ .utf16 = s.units[p..q] }});
        z_roots_buf[1] = Value.fromString(sub);
        try rt.heap.appendElement(out, z_roots_buf[1]);
        if (out.kind.array.items.len == lim) return Value.fromObject(out);
        p = e;
        const z_len_f = try common.toLength(rt, try object.get(rt, z, try object.named(rt, "length")));
        const n_caps: usize = if (z_len_f > 1.0) @intFromFloat(z_len_f - 1.0) else 0;
        var i: usize = 1;
        while (i <= n_caps) : (i += 1) {
            const cap = try object.get(rt, z, .{ .index = @intCast(i) });
            z_roots_buf[1] = cap;
            try rt.heap.appendElement(out, cap);
            if (out.kind.array.items.len == lim) return Value.fromObject(out);
        }
        q = p;
    }
    const tail = try rt.heap.newString(&.{.{ .utf16 = s.units[p..size] }});
    try rt.heap.appendElement(out, Value.fromString(tail));
    return Value.fromObject(out);
}

fn regexpSymMatchAll(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype[Symbol.matchAll] called on non-object" }});
    }
    var root_buf = [_]Value{ this, common.arg(args, 0), .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try common.toStringObj(rt, root_buf[1]);
    root_buf[2] = Value.fromString(s);

    const ctor = try common.speciesConstructor(rt, this, Value.fromNative(&builtins.regexp_global));
    root_buf[3] = ctor;

    const flags_val = try object.get(rt, this, try object.named(rt, "flags"));
    const flags_s = try common.toStringObj(rt, flags_val);
    root_buf[4] = Value.fromString(flags_s);

    const matcher = try common.constructValue(rt, ctor, &.{ this, Value.fromString(flags_s) });
    root_buf[5] = matcher;

    const li_key = try object.named(rt, "lastIndex");
    const last_idx = try common.toLength(rt, try object.get(rt, this, li_key));
    try object.setStrict(rt, matcher, li_key, Value.fromNumber(last_idx));

    const is_global = std.mem.indexOfScalar(u16, flags_s.units, 'g') != null;
    const is_unicode = std.mem.indexOfScalar(u16, flags_s.units, 'u') != null or
        std.mem.indexOfScalar(u16, flags_s.units, 'v') != null;
    const r = try builtins.realm(rt);
    return Value.fromObject(try rt.heap.newMatchAllIterator(r.regexp_string_iterator_prototype, matcher, s, is_global, is_unicode));
}
