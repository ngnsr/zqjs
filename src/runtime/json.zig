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
    if (args.len >= 2 and (args[1] == .native or args[1] == .closure)) {
        return rt.fail(.user_conversion);
    }
    return val;
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
    if (args.len >= 2) {
        switch (args[1]) {
            .native, .closure => return rt.fail(.user_conversion),
            .object => |o| if (o.kind == .array) return rt.fail(.builtin),
            else => {},
        }
    }
    if (args.len >= 3 and args[2] != .undefined) return rt.fail(.builtin);

    return (try stringify(rt, val)) orelse Value.undefined;
}

pub fn stringify(rt: *Runtime, val: Value) Error!?Value {
    const to_json_atom = try rt.heap.internAscii("toJSON");
    var s: Stringifier = .{
        .rt = rt,
        .to_json_atom = to_json_atom,
    };
    defer s.out.deinit(rt.gpa);
    defer s.stack.deinit(rt.gpa);

    if (!try s.writeValue(val)) return null;
    const str = try rt.heap.newString(&.{.{ .utf16 = s.out.items }});
    return .{ .string = str };
}

const Stringifier = struct {
    rt: *Runtime,
    to_json_atom: *heap_mod.String,
    out: std.ArrayList(u16) = .empty,
    stack: std.ArrayList(*Object) = .empty,

    fn writeUnit(s: *Stringifier, u: u16) Error!void {
        if (s.out.items.len >= s.rt.limits.max_string_length) return s.rt.limit(.string_length);
        try s.out.append(s.rt.gpa, u);
    }

    fn writeAscii(s: *Stringifier, text: []const u8) Error!void {
        if (s.out.items.len + text.len > s.rt.limits.max_string_length) return s.rt.limit(.string_length);
        try s.out.ensureUnusedCapacity(s.rt.gpa, text.len);
        for (text) |c| s.out.appendAssumeCapacity(c);
    }

    fn writeValue(s: *Stringifier, v: Value) Error!bool {
        heap_mod.checkValue(v);
        switch (v) {
            .undefined, .native, .closure => return false,
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
                try s.checkToJson(o);
                if (o.kind == .array) {
                    try s.writeArray(o);
                } else {
                    try s.writeObject(o);
                }
                return true;
            },
        }
    }

    fn checkToJson(s: *Stringifier, obj: *Object) Error!void {
        var cur: ?*Object = obj;
        while (cur) |c| : (cur = c.proto) {
            c.obj.checkLive();
            if (c.props.get(s.to_json_atom)) |p| {
                if (p.value == .native or p.value == .closure) return s.rt.fail(.user_conversion);
                return;
            }
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

        try s.writeUnit('[');
        const len = arr.kind.array.items.len;
        for (0..len) |i| {
            if (i > 0) try s.writeUnit(',');
            const elem = arr.kind.array.items[i];
            if (!try s.writeValue(elem)) try s.writeAscii("null");
        }
        try s.writeUnit(']');
    }

    fn writeObject(s: *Stringifier, obj: *Object) Error!void {
        try s.pushAncestor(obj);
        defer _ = s.stack.pop();

        const keys = try object.ownKeys(s.rt, obj);
        defer s.rt.gpa.free(keys);

        try s.writeUnit('{');
        var wrote = false;
        for (keys) |k| {
            const val = switch (k) {
                .atom => |a| obj.props.get(a).?.value,
                .index => |i| blk: {
                    var buf: [10]u8 = undefined;
                    const idx_atom = try s.rt.heap.internAscii(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
                    break :blk obj.props.get(idx_atom).?.value;
                },
            };
            // Save position so if property value is omitted (undefined/function), no key/comma is left.
            const mark = s.out.items.len;
            if (wrote) try s.writeUnit(',');
            switch (k) {
                .atom => |a| try s.writeString(a.units),
                .index => |i| {
                    var buf: [10]u8 = undefined;
                    const idx_str = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                    try s.writeUnit('"');
                    try s.writeAscii(idx_str);
                    try s.writeUnit('"');
                },
            }
            try s.writeUnit(':');
            if (try s.writeValue(val)) {
                wrote = true;
            } else {
                s.out.items.len = mark;
            }
        }
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
