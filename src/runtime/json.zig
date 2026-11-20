//! JSON.parse (M15.1) and JSON.stringify (M15.2).

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
const builtins = @import("builtins.zig");

pub const parse_native: Native = .{ .name = "parse", .call = jsonParse };
pub const stringify_native: Native = .{ .name = "stringify", .call = jsonStringify };

fn jsonParse(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const text = if (args.len > 0) args[0] else Value.undefined;
    const units = try toStringUnits(rt, text);
    const val = try parse(rt, units);
    if (args.len >= 2 and args[1].isFunction()) {
        const reviver = args[1];
        const r = try builtins.realm(rt);
        const root = try rt.heap.newObject(r.object_prototype);
        const empty_str = try rt.heap.internAscii("");
        var root_buf = [_]Value{ .{ .object = root }, reviver, val, .{ .string = empty_str } };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);

        try object.define(rt, root, object.namedAtom(empty_str), val);
        return internalizeJSONProperty(rt, root, object.namedAtom(empty_str), .{ .string = empty_str }, reviver, 0);
    }
    return val;
}

const KeySliceRoot = struct {
    keys: []const object.Key,

    fn mark(ctx: *anyopaque, h: *heap_mod.Heap) void {
        const self: *KeySliceRoot = @ptrCast(@alignCast(ctx));
        for (self.keys) |k| switch (k) {
            .atom => |a| h.markObj(&a.obj),
            .symbol => |sym| h.markObj(&sym.obj),
            .index => {},
        };
    }
};

fn internalizeJSONProperty(
    rt: *Runtime,
    holder: *Object,
    key: object.Key,
    name_val: Value,
    reviver: Value,
    depth: u16,
) Error!Value {
    if (depth >= rt.limits.max_nesting_depth) return rt.limit(.nesting_depth);
    const val = try object.get(rt, .{ .object = holder }, key);
    var root_buf = [_]Value{ .{ .object = holder }, name_val, reviver, val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (val == .object) {
        const val_obj = val.object;
        if (val_obj.kind == .array) {
            const len = val_obj.kind.array.items.len;
            for (0..len) |i| {
                var idx_buf: [20]u8 = undefined;
                const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
                const prop_str = try rt.heap.ascii(idx_str);
                const prop_val: Value = .{ .string = prop_str };
                root_buf[4] = prop_val;
                const elem_key = object.Key{ .index = @intCast(i) };
                const new_elem = try internalizeJSONProperty(rt, val_obj, elem_key, prop_val, reviver, depth + 1);
                root_buf[5] = new_elem;
                if (new_elem == .undefined) {
                    _ = try object.delete(rt, .{ .object = val_obj }, elem_key);
                } else {
                    try object.set(rt, .{ .object = val_obj }, elem_key, new_elem);
                }
                root_buf[4] = .undefined;
                root_buf[5] = .undefined;
            }
        } else {
            const keys = try object.ownKeys(rt, val_obj);
            defer rt.gpa.free(keys);
            var key_root: KeySliceRoot = .{ .keys = keys };
            try rt.addRoots(.{ .ctx = &key_root, .mark = KeySliceRoot.mark });
            defer rt.removeRoots(&key_root);

            for (keys) |k| {
                if (k == .symbol) continue;
                if (try object.ownProp(rt, val_obj, k)) |p| {
                    if (!p.enumerable) continue;
                } else continue;
                const prop_str = switch (k) {
                    .atom => |a| a,
                    .index => |i| blk: {
                        var idx_buf: [20]u8 = undefined;
                        const idx_str = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
                        break :blk try rt.heap.ascii(idx_str);
                    },
                    .symbol => unreachable,
                };
                const prop_val: Value = .{ .string = prop_str };
                root_buf[4] = prop_val;
                const new_elem = try internalizeJSONProperty(rt, val_obj, k, prop_val, reviver, depth + 1);
                root_buf[5] = new_elem;
                if (new_elem == .undefined) {
                    _ = try object.delete(rt, .{ .object = val_obj }, k);
                } else {
                    try object.define(rt, val_obj, k, new_elem);
                }
                root_buf[4] = .undefined;
                root_buf[5] = .undefined;
            }
        }
    }

    return rt.callCallable(reviver, .{ .object = holder }, &.{ name_val, val });
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

pub fn parse(rt: *Runtime, units: []const u16) Error!Value {
    const r = try builtins.realm(rt);
    var p: Parser = .{
        .rt = rt,
        .realm = r,
        .units = units,
    };
    defer p.str_buf.deinit(rt.gpa);

    const val = try p.parseValue();
    p.skipWhitespace();
    if (p.pos < p.units.len) return p.syntaxError("Unexpected non-whitespace character after JSON");
    return val;
}

const Parser = struct {
    rt: *Runtime,
    realm: *const builtins.Realm,
    units: []const u16,
    pos: usize = 0,
    depth: u16 = 0,
    str_buf: std.ArrayList(u16) = .empty,

    fn syntaxError(p: *Parser, msg: []const u8) Error {
        return p.rt.throw(.SyntaxError, &.{.{ .ascii = msg }});
    }

    fn skipWhitespace(p: *Parser) void {
        while (p.pos < p.units.len) {
            switch (p.units[p.pos]) {
                0x20, 0x09, 0x0A, 0x0D => p.pos += 1,
                else => return,
            }
        }
    }

    fn parseValue(p: *Parser) Error!Value {
        p.skipWhitespace();
        if (p.pos >= p.units.len) return p.syntaxError("Unexpected end of JSON input");
        return switch (p.units[p.pos]) {
            '{' => p.parseObject(),
            '[' => p.parseArray(),
            '"' => .{ .string = try p.parseString() },
            't' => p.parseLiteral("true", .{ .boolean = true }),
            'f' => p.parseLiteral("false", .{ .boolean = false }),
            'n' => p.parseLiteral("null", .null),
            '-', '0'...'9' => p.parseNumber(),
            else => p.syntaxError("Unexpected token in JSON"),
        };
    }

    fn parseObject(p: *Parser) Error!Value {
        if (p.depth >= p.rt.limits.max_nesting_depth) return p.rt.limit(.nesting_depth);
        p.depth += 1;
        defer p.depth -= 1;

        p.pos += 1; // '{'
        const obj = try p.rt.heap.newObject(p.realm.object_prototype);
        p.skipWhitespace();
        if (p.pos < p.units.len and p.units[p.pos] == '}') {
            p.pos += 1;
            return .{ .object = obj };
        }

        while (true) {
            p.skipWhitespace();
            if (p.pos >= p.units.len or p.units[p.pos] != '"') {
                return p.syntaxError("Expected property name in JSON");
            }
            const key_units = try p.parseStringUnits();
            const key = try object.keyUnits(p.rt, key_units);
            p.skipWhitespace();
            if (p.pos >= p.units.len or p.units[p.pos] != ':') {
                return p.syntaxError("Expected ':' after property name in JSON");
            }
            p.pos += 1;
            const val = try p.parseValue();
            try object.define(p.rt, obj, key, val);
            p.skipWhitespace();
            if (p.pos >= p.units.len) return p.syntaxError("Unexpected end of JSON input");
            switch (p.units[p.pos]) {
                ',' => p.pos += 1,
                '}' => {
                    p.pos += 1;
                    return .{ .object = obj };
                },
                else => return p.syntaxError("Expected ',' or '}' in JSON object"),
            }
        }
    }

    fn parseArray(p: *Parser) Error!Value {
        if (p.depth >= p.rt.limits.max_nesting_depth) return p.rt.limit(.nesting_depth);
        p.depth += 1;
        defer p.depth -= 1;

        p.pos += 1; // '['
        const arr = try p.rt.heap.newArray(p.realm.array_prototype);
        p.skipWhitespace();
        if (p.pos < p.units.len and p.units[p.pos] == ']') {
            p.pos += 1;
            return .{ .object = arr };
        }

        while (true) {
            const val = try p.parseValue();
            try p.rt.heap.appendElement(arr, val);
            p.skipWhitespace();
            if (p.pos >= p.units.len) return p.syntaxError("Unexpected end of JSON input");
            switch (p.units[p.pos]) {
                ',' => p.pos += 1,
                ']' => {
                    p.pos += 1;
                    return .{ .object = arr };
                },
                else => return p.syntaxError("Expected ',' or ']' in JSON array"),
            }
        }
    }

    fn parseString(p: *Parser) Error!*heap_mod.String {
        const units = try p.parseStringUnits();
        return p.rt.heap.newString(&.{.{ .utf16 = units }});
    }

    fn parseStringUnits(p: *Parser) Error![]const u16 {
        p.pos += 1; // opening '"'
        p.str_buf.clearRetainingCapacity();

        while (p.pos < p.units.len) {
            const u = p.units[p.pos];
            if (u == '"') {
                p.pos += 1;
                return p.str_buf.items;
            }
            if (u < 0x20) return p.syntaxError("Unescaped control character in JSON string");
            if (p.str_buf.items.len >= p.rt.limits.max_string_length) return p.rt.limit(.string_length);
            if (u == '\\') {
                p.pos += 1;
                if (p.pos >= p.units.len) return p.syntaxError("Unterminated string in JSON");
                const esc = p.units[p.pos];
                p.pos += 1;
                const ch: u16 = switch (esc) {
                    '"', '\\', '/' => esc,
                    'b' => 0x08,
                    'f' => 0x0C,
                    'n' => 0x0A,
                    'r' => 0x0D,
                    't' => 0x09,
                    'u' => try p.parseHex4(),
                    else => return p.syntaxError("Bad escaped character in JSON"),
                };
                try p.str_buf.append(p.rt.gpa, ch);
            } else {
                p.pos += 1;
                try p.str_buf.append(p.rt.gpa, u);
            }
        }
        return p.syntaxError("Unterminated string in JSON");
    }

    fn parseHex4(p: *Parser) Error!u16 {
        if (p.pos + 4 > p.units.len) return p.syntaxError("Bad Unicode escape in JSON");
        var out: u16 = 0;
        for (p.units[p.pos .. p.pos + 4]) |u| {
            const d: u16 = switch (u) {
                '0'...'9' => u - '0',
                'a'...'f' => u - 'a' + 10,
                'A'...'F' => u - 'A' + 10,
                else => return p.syntaxError("Bad Unicode escape in JSON"),
            };
            out = (out << 4) | d;
        }
        p.pos += 4;
        return out;
    }

    fn parseLiteral(p: *Parser, lit: []const u8, val: Value) Error!Value {
        if (p.pos + lit.len > p.units.len) return p.syntaxError("Unexpected end of JSON input");
        for (lit, 0..) |c, i| {
            if (p.units[p.pos + i] != c) return p.syntaxError("Unexpected token in JSON");
        }
        p.pos += lit.len;
        return val;
    }

    fn parseNumber(p: *Parser) Error!Value {
        const start = p.pos;
        if (p.units[p.pos] == '-') {
            p.pos += 1;
            if (p.pos >= p.units.len) return p.syntaxError("Invalid number in JSON");
        }
        if (p.units[p.pos] == '0') {
            p.pos += 1;
            if (p.pos < p.units.len and isDigit(p.units[p.pos])) {
                return p.syntaxError("Unexpected number in JSON");
            }
        } else if (p.units[p.pos] >= '1' and p.units[p.pos] <= '9') {
            p.pos += 1;
            while (p.pos < p.units.len and isDigit(p.units[p.pos])) p.pos += 1;
        } else {
            return p.syntaxError("Invalid number in JSON");
        }

        if (p.pos < p.units.len and p.units[p.pos] == '.') {
            p.pos += 1;
            if (p.pos >= p.units.len or !isDigit(p.units[p.pos])) {
                return p.syntaxError("Invalid number in JSON");
            }
            while (p.pos < p.units.len and isDigit(p.units[p.pos])) p.pos += 1;
        }

        if (p.pos < p.units.len and (p.units[p.pos] == 'e' or p.units[p.pos] == 'E')) {
            p.pos += 1;
            if (p.pos < p.units.len and (p.units[p.pos] == '+' or p.units[p.pos] == '-')) p.pos += 1;
            if (p.pos >= p.units.len or !isDigit(p.units[p.pos])) {
                return p.syntaxError("Invalid number in JSON");
            }
            while (p.pos < p.units.len and isDigit(p.units[p.pos])) p.pos += 1;
        }

        const slice = p.units[start..p.pos];
        var stack_buf: [128]u8 = undefined;
        const heap_buf = if (slice.len > stack_buf.len) try p.rt.gpa.alloc(u8, slice.len) else null;
        defer if (heap_buf) |b| p.rt.gpa.free(b);
        const ascii = if (heap_buf) |b| b else stack_buf[0..slice.len];
        for (slice, 0..) |u, i| ascii[i] = @intCast(u);

        const n = std.fmt.parseFloat(f64, ascii) catch return p.syntaxError("Invalid number in JSON");
        return .{ .number = n };
    }

    fn isDigit(u: u16) bool {
        return u >= '0' and u <= '9';
    }
};

// ------------------------------------------------------------ JSON.stringify (M15.2)

fn jsonStringify(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const val = if (args.len > 0) args[0] else Value.undefined;
    var replacer_fn: ?Value = null;
    var prop_list: std.ArrayList(*const heap_mod.String) = .empty;
    defer prop_list.deinit(rt.gpa);

    var root_buf = [_]Value{ val, if (args.len >= 2) args[1] else .undefined, if (args.len >= 3) args[2] else .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (args.len >= 2) {
        if (args[1].isFunction()) {
            replacer_fn = args[1];
        } else if (args[1] == .object and args[1].object.kind == .array) {
            for (args[1].object.kind.array.items) |item| {
                const cand: *const heap_mod.String = switch (item) {
                    .string => |s| s,
                    .number => |n| blk: {
                        var buf: ops.NumberBuf = undefined;
                        break :blk try rt.heap.ascii(ops.formatNumber(&buf, n));
                    },
                    else => continue,
                };
                var dup = false;
                for (prop_list.items) |existing| {
                    if (std.mem.eql(u16, existing.units, cand.units)) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) try prop_list.append(rt.gpa, cand);
            }
        }
    }

    var gap_buf: [10]u16 = undefined;
    var gap_len: usize = 0;
    if (args.len >= 3) {
        switch (args[2]) {
            .number => |n| {
                if (!std.math.isNan(n)) {
                    const clamped = if (std.math.isInf(n))
                        (if (n > 0) @as(f64, 10.0) else @as(f64, 0.0))
                    else
                        @min(10.0, @max(0.0, @trunc(n)));
                    gap_len = @intFromFloat(clamped);
                    @memset(gap_buf[0..gap_len], ' ');
                }
            },
            .string => |str| {
                gap_len = @min(10, str.units.len);
                @memcpy(gap_buf[0..gap_len], str.units[0..gap_len]);
            },
            else => {},
        }
    }

    const use_prop_list = args.len >= 2 and args[1] == .object and args[1].object.kind == .array;
    return (try stringifyWithOptions(rt, val, replacer_fn, if (use_prop_list) prop_list.items else null, gap_buf[0..gap_len])) orelse Value.undefined;
}

pub fn stringify(rt: *Runtime, val: Value) Error!?Value {
    return stringifyWithOptions(rt, val, null, null, &.{});
}

fn stringifyWithOptions(
    rt: *Runtime,
    val: Value,
    replacer_fn: ?Value,
    property_list: ?[]const *const heap_mod.String,
    gap: []const u16,
) Error!?Value {
    const to_json_atom = try rt.heap.internAscii("toJSON");
    var s: Stringifier = .{
        .rt = rt,
        .to_json_atom = to_json_atom,
        .replacer_fn = replacer_fn,
        .property_list = property_list,
        .gap = gap,
    };
    defer s.out.deinit(rt.gpa);
    defer s.stack.deinit(rt.gpa);

    try rt.addRoots(.{ .ctx = &s, .mark = Stringifier.mark });
    defer rt.removeRoots(&s);

    const r = try builtins.realm(rt);
    const holder = try rt.heap.newObject(r.object_prototype);
    const empty_str = try rt.heap.internAscii("");
    const empty_key: Value = .{ .string = empty_str };

    var val_roots_buf = [_]Value{ val, .{ .object = holder }, empty_key };
    var val_roots = rt_mod.ValueRoots{ .values = &val_roots_buf };
    try val_roots.register(rt);
    defer val_roots.unregister(rt);

    try object.define(rt, holder, object.namedAtom(empty_str), val);
    if (!try s.writeValue(.{ .object = holder }, val, empty_key)) return null;
    const str = try rt.heap.newString(&.{.{ .utf16 = s.out.items }});
    return .{ .string = str };
}

const Stringifier = struct {
    const KeyNode = struct {
        keys: []const object.Key,
        prev: ?*KeyNode,
    };

    rt: *Runtime,
    to_json_atom: *heap_mod.String,
    replacer_fn: ?Value = null,
    property_list: ?[]const *const heap_mod.String = null,
    gap: []const u16 = &.{},
    out: std.ArrayList(u16) = .empty,
    stack: std.ArrayList(*Object) = .empty,
    key_nodes: ?*KeyNode = null,

    fn mark(ctx: *anyopaque, h: *heap_mod.Heap) void {
        const s: *Stringifier = @ptrCast(@alignCast(ctx));
        h.markObj(@constCast(&s.to_json_atom.obj));
        if (s.replacer_fn) |rf| h.markValue(rf);
        if (s.property_list) |pl| {
            for (pl) |str| h.markObj(@constCast(&str.obj));
        }
        for (s.stack.items) |o| h.markObj(&o.obj);
        var kn = s.key_nodes;
        while (kn) |node| : (kn = node.prev) {
            for (node.keys) |k| switch (k) {
                .atom => |a| h.markObj(&a.obj),
                .symbol => |sym| h.markObj(&sym.obj),
                .index => {},
            };
        }
    }

    fn writeIndent(s: *Stringifier, level: usize) Error!void {
        try s.writeUnit('\n');
        for (0..level) |_| {
            if (s.out.items.len + s.gap.len > s.rt.limits.max_string_length) return s.rt.limit(.string_length);
            try s.out.ensureUnusedCapacity(s.rt.gpa, s.gap.len);
            for (s.gap) |u| s.out.appendAssumeCapacity(u);
        }
    }

    fn writeUnit(s: *Stringifier, u: u16) Error!void {
        if (s.out.items.len >= s.rt.limits.max_string_length) return s.rt.limit(.string_length);
        try s.out.append(s.rt.gpa, u);
    }

    fn writeAscii(s: *Stringifier, text: []const u8) Error!void {
        if (s.out.items.len + text.len > s.rt.limits.max_string_length) return s.rt.limit(.string_length);
        try s.out.ensureUnusedCapacity(s.rt.gpa, text.len);
        for (text) |c| s.out.appendAssumeCapacity(c);
    }

    fn writeValue(s: *Stringifier, holder_val: Value, v_in: Value, key_val: Value) Error!bool {
        heap_mod.checkValue(v_in);
        var v = v_in;
        var roots_buf = [_]Value{ holder_val, v, key_val };
        var roots = rt_mod.ValueRoots{ .values = &roots_buf };
        const may_call = v.isObjectLike() or s.replacer_fn != null;
        if (may_call) try roots.register(s.rt);
        defer if (may_call) roots.unregister(s.rt);

        if (v.isObjectLike()) {
            const to_json = try object.get(s.rt, v, object.namedAtom(s.to_json_atom));
            if (to_json.isFunction()) {
                v = try s.rt.callCallable(to_json, v, &.{key_val});
                roots_buf[1] = v;
            }
        }
        if (s.replacer_fn) |rf| {
            v = try s.rt.callCallable(rf, holder_val, &.{ key_val, v });
            roots_buf[1] = v;
        }

        switch (v) {
            .undefined, .native, .closure, .symbol => return false,
            .null => {
                try s.writeAscii("null");
                return true;
            },
            .boolean => |b| {
                try s.writeAscii(if (b) "true" else "false");
                return true;
            },
            .number => |n| {
                if (std.math.isNan(n) or std.math.isInf(n)) {
                    try s.writeAscii("null");
                } else {
                    var buf: ops.NumberBuf = undefined;
                    try s.writeAscii(ops.formatNumber(&buf, n));
                }
                return true;
            },
            .string => |str| {
                try s.writeString(str.units);
                return true;
            },
            .object => |o| {
                if (o.kind == .array) {
                    try s.writeArray(o);
                } else {
                    try s.writeObject(o);
                }
                return true;
            },
        }
    }

    fn pushAncestor(s: *Stringifier, o: *Object) Error!void {
        for (s.stack.items) |anc| {
            if (anc == o) return s.rt.throw(.TypeError, &.{.{ .ascii = "Converting circular structure to JSON" }});
        }
        if (s.stack.items.len >= s.rt.limits.max_nesting_depth) return s.rt.limit(.nesting_depth);
        try s.stack.append(s.rt.gpa, o);
    }

    fn writeArray(s: *Stringifier, arr: *Object) Error!void {
        try s.pushAncestor(arr);
        defer _ = s.stack.pop();

        const len = arr.kind.array.items.len;
        if (len == 0) {
            try s.writeAscii("[]");
            return;
        }

        var roots_buf = [_]Value{ .{ .object = arr }, .undefined };
        var roots = rt_mod.ValueRoots{ .values = &roots_buf };
        try roots.register(s.rt);
        defer roots.unregister(s.rt);

        const step_indent = s.stack.items.len;
        try s.writeUnit('[');
        for (0..len) |i| {
            if (i > 0) try s.writeUnit(',');
            if (s.gap.len > 0) try s.writeIndent(step_indent);
            const elem: Value = if (i < arr.kind.array.items.len) arr.kind.array.items[i] else .undefined;
            var buf: [20]u8 = undefined;
            const idx_str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            const key_val: Value = .{ .string = try s.rt.heap.ascii(idx_str) };
            roots_buf[1] = key_val;
            if (!try s.writeValue(.{ .object = arr }, elem, key_val)) try s.writeAscii("null");
        }
        if (s.gap.len > 0) try s.writeIndent(step_indent - 1);
        try s.writeUnit(']');
    }

    fn writeObject(s: *Stringifier, obj: *Object) Error!void {
        try s.pushAncestor(obj);
        defer _ = s.stack.pop();

        var roots_buf = [_]Value{ .{ .object = obj }, .undefined };
        var roots = rt_mod.ValueRoots{ .values = &roots_buf };
        try roots.register(s.rt);
        defer roots.unregister(s.rt);

        const step_indent = s.stack.items.len;
        try s.writeUnit('{');
        var wrote = false;

        if (s.property_list) |pl| {
            for (pl) |prop_str| {
                const key_val: Value = .{ .string = prop_str };
                roots_buf[1] = key_val;
                const k = try object.keyUnits(s.rt, prop_str.units);
                const val = try object.get(s.rt, .{ .object = obj }, k);
                const mark_pos = s.out.items.len;
                if (wrote) try s.writeUnit(',');
                if (s.gap.len > 0) try s.writeIndent(step_indent);
                try s.writeString(prop_str.units);
                try s.writeUnit(':');
                if (s.gap.len > 0) try s.writeUnit(' ');
                if (try s.writeValue(.{ .object = obj }, val, key_val)) {
                    wrote = true;
                } else {
                    s.out.items.len = mark_pos;
                }
            }
        } else {
            const keys = try object.ownKeys(s.rt, obj);
            defer s.rt.gpa.free(keys);
            var key_node = KeyNode{ .keys = keys, .prev = s.key_nodes };
            s.key_nodes = &key_node;
            defer s.key_nodes = key_node.prev;

            for (keys) |k| {
                if (k == .symbol) continue;
                if (try object.ownProp(s.rt, obj, k)) |p| {
                    if (!p.enumerable) continue;
                } else continue;
                const key_val: Value = switch (k) {
                    .atom => |a| .{ .string = a },
                    .index => |i| blk: {
                        var buf: [10]u8 = undefined;
                        const idx_str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                        break :blk .{ .string = try s.rt.heap.ascii(idx_str) };
                    },
                    .symbol => unreachable,
                };
                roots_buf[1] = key_val;
                const val = try object.get(s.rt, .{ .object = obj }, k);
                // Save position so if property value is omitted (undefined/function), no key/comma is left.
                const mark_pos = s.out.items.len;
                if (wrote) try s.writeUnit(',');
                if (s.gap.len > 0) try s.writeIndent(step_indent);
                switch (k) {
                    .atom => |a| try s.writeString(a.units),
                    .index => |i| {
                        var buf: [10]u8 = undefined;
                        const idx_str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                        try s.writeUnit('"');
                        try s.writeAscii(idx_str);
                        try s.writeUnit('"');
                    },
                    .symbol => unreachable,
                }
                try s.writeUnit(':');
                if (s.gap.len > 0) try s.writeUnit(' ');
                if (try s.writeValue(.{ .object = obj }, val, key_val)) {
                    wrote = true;
                } else {
                    s.out.items.len = mark_pos;
                }
            }
        }
        if (wrote and s.gap.len > 0) try s.writeIndent(step_indent - 1);
        try s.writeUnit('}');
    }

    fn writeString(s: *Stringifier, units: []const u16) Error!void {
        try s.writeUnit('"');
        var i: usize = 0;
        while (i < units.len) : (i += 1) {
            const u = units[i];
            switch (u) {
                '"' => try s.writeAscii("\\\""),
                '\\' => try s.writeAscii("\\\\"),
                0x08 => try s.writeAscii("\\b"),
                0x0C => try s.writeAscii("\\f"),
                0x0A => try s.writeAscii("\\n"),
                0x0D => try s.writeAscii("\\r"),
                0x09 => try s.writeAscii("\\t"),
                0x00...0x07, 0x0B, 0x0E...0x1F => try s.writeUnicodeEscape(u),
                0xD800...0xDBFF => {
                    if (i + 1 < units.len and units[i + 1] >= 0xDC00 and units[i + 1] <= 0xDFFF) {
                        try s.writeUnit(u);
                        try s.writeUnit(units[i + 1]);
                        i += 1;
                    } else {
                        try s.writeUnicodeEscape(u);
                    }
                },
                0xDC00...0xDFFF => try s.writeUnicodeEscape(u),
                else => try s.writeUnit(u),
            }
        }
        try s.writeUnit('"');
    }

    fn writeUnicodeEscape(s: *Stringifier, u: u16) Error!void {
        const hex = "0123456789abcdef";
        try s.writeAscii(&.{
            '\\',
            'u',
            hex[(u >> 12) & 0xF],
            hex[(u >> 8) & 0xF],
            hex[(u >> 4) & 0xF],
            hex[u & 0xF],
        });
    }
};
