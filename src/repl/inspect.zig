//! Cycle-safe, depth-bounded, colorized JS value inspector (Node `util.inspect` style, D71).
//! Strictly read-only: never invokes getters or runs JS code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = @import("../runtime/value.zig").Value;
const Native = @import("../runtime/value.zig").Native;
const heap = @import("../runtime/heap.zig");
const Object = heap.Object;
const Closure = heap.Closure;
const PropKey = heap.PropKey;
const Property = heap.Property;
const Runtime = @import("../runtime/runtime.zig").Runtime;
const ops = @import("../runtime/ops.zig");
const date = @import("../runtime/date.zig");
const ast = @import("../frontend/ast.zig");
const Proto = @import("../bytecode/bytecode.zig").Proto;

pub const Options = struct {
    depth: u32 = 4,
    max_items: usize = 100,
    color: bool = false,
};

const Ansi = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[90m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const cyan = "\x1b[36m";
    const magenta = "\x1b[35m";
};

pub fn inspect(rt: *const Runtime, v: Value, w: *Writer, options: Options) (Allocator.Error || Writer.Error)!void {
    var ctx: Context = .{
        .rt = rt,
        .gpa = rt.gpa,
        .w = w,
        .options = options,
    };
    defer ctx.deinit();

    // Pre-pass: detect cycles / shared references within depth bound to assign <ref *N>.
    try ctx.scanCycles(v, 0);
    try ctx.writeValue(v, 0, 0);
}

const Context = struct {
    rt: *const Runtime,
    gpa: Allocator,
    w: *Writer,
    options: Options,
    /// Objects currently on the active recursion stack.
    active: std.ArrayList(*const Object) = .empty,
    /// Objects that appear in a cycle, mapped to their 1-based ref id.
    circular_ids: std.AutoHashMapUnmanaged(*const Object, u32) = .empty,
    next_ref_id: u32 = 1,

    fn deinit(ctx: *Context) void {
        ctx.active.deinit(ctx.gpa);
        ctx.circular_ids.deinit(ctx.gpa);
    }

    fn style(ctx: *const Context, code: []const u8) []const u8 {
        return if (ctx.options.color) code else "";
    }

    fn reset(ctx: *const Context) []const u8 {
        return if (ctx.options.color) Ansi.reset else "";
    }

    fn isOnActive(ctx: *const Context, obj: *const Object) bool {
        for (ctx.active.items) |p| {
            if (p == obj) return true;
        }
        return false;
    }

    fn scanCycles(ctx: *Context, v: Value, depth: u32) Allocator.Error!void {
        if (!v.isObject()) return;
        const obj = v.asObject();
        if (ctx.isOnActive(obj)) {
            if (!ctx.circular_ids.contains(obj)) {
                try ctx.circular_ids.put(ctx.gpa, obj, ctx.next_ref_id);
                ctx.next_ref_id += 1;
            }
            return;
        }
        if (depth > ctx.options.depth) return;

        try ctx.active.append(ctx.gpa, obj);
        defer _ = ctx.active.pop();

        switch (obj.kind) {
            .array => |arr| {
                const n = @min(arr.items.len, ctx.options.max_items);
                for (arr.items[0..n]) |elem| try ctx.scanCycles(elem, depth + 1);
            },
            .map => |m| {
                var count: usize = 0;
                for (m.entries.items) |entry| {
                    if (!entry.alive) continue;
                    if (count >= ctx.options.max_items) break;
                    try ctx.scanCycles(entry.key, depth + 1);
                    try ctx.scanCycles(entry.value, depth + 1);
                    count += 1;
                }
            },
            .set => |s| {
                var count: usize = 0;
                for (s.entries.items) |entry| {
                    if (!entry.alive) continue;
                    if (count >= ctx.options.max_items) break;
                    try ctx.scanCycles(entry.key, depth + 1);
                    count += 1;
                }
            },
            .promise => |p| {
                if (p.state != .pending) try ctx.scanCycles(p.result, depth + 1);
            },
            .weak_map, .weak_set => {},
            .proxy => |px| {
                if (px.target) |t| try ctx.scanCycles(t, depth + 1);
                if (px.handler) |hv| try ctx.scanCycles(hv, depth + 1);
            },
            else => {},
        }

        var it = obj.props.iterator();
        var prop_count: usize = 0;
        while (it.next()) |entry| {
            if (prop_count >= ctx.options.max_items) break;
            if (!entry.value_ptr.enumerable) continue;
            if (!entry.value_ptr.is_accessor) {
                try ctx.scanCycles(entry.value_ptr.value, depth + 1);
            }
            prop_count += 1;
        }
    }

    fn writeValue(ctx: *Context, v: Value, depth: u32, indent: usize) (Allocator.Error || Writer.Error)!void {
        switch (v.unpack()) {
            .undefined => try ctx.w.print("{s}undefined{s}", .{ ctx.style(Ansi.dim), ctx.reset() }),
            .null => try ctx.w.print("{s}null{s}", .{ ctx.style(Ansi.bold), ctx.reset() }),
            .boolean => |b| try ctx.w.print("{s}{s}{s}", .{ ctx.style(Ansi.yellow), if (b) "true" else "false", ctx.reset() }),
            .number => |n| {
                try ctx.w.writeAll(ctx.style(Ansi.yellow));
                if (n == 0 and std.math.signbit(n)) {
                    try ctx.w.writeAll("-0");
                } else {
                    var buf: ops.NumberBuf = undefined;
                    try ctx.w.writeAll(ops.formatNumber(&buf, n));
                }
                try ctx.w.writeAll(ctx.reset());
            },
            .bigint => |b| {
                try ctx.w.writeAll(ctx.style(Ansi.yellow));
                if (b.limbs.len == 0) {
                    try ctx.w.writeAll("0n");
                } else {
                    try writeBigIntRaw(ctx.w, b);
                    try ctx.w.writeByte('n');
                }
                try ctx.w.writeAll(ctx.reset());
            },
            .string => |s| {
                try ctx.w.writeAll(ctx.style(Ansi.green));
                try writeQuotedString(ctx.w, s.units);
                try ctx.w.writeAll(ctx.reset());
            },
            .symbol => |sym| {
                try ctx.w.writeAll(ctx.style(Ansi.green));
                try ctx.w.writeAll("Symbol(");
                if (sym.description) |desc| try ops.writeUtf16(ctx.w, desc.units);
                try ctx.w.writeAll(")");
                try ctx.w.writeAll(ctx.reset());
            },
            .native => |n| try ctx.writeNative(n),
            .closure => |c| try ctx.writeClosure(c),
            .object => |obj| try ctx.writeObject(obj, depth, indent),
        }
    }

    fn writeNative(ctx: *const Context, n: *const Native) Writer.Error!void {
        try ctx.w.writeAll(ctx.style(Ansi.cyan));
        if (n.name.len > 0) {
            try ctx.w.print("[Function: {s}]", .{n.name});
        } else {
            try ctx.w.writeAll("[Function (anonymous)]");
        }
        try ctx.w.writeAll(ctx.reset());
    }

    fn writeClosure(ctx: *const Context, c: *const Closure) Writer.Error!void {
        try ctx.w.writeAll(ctx.style(Ansi.cyan));
        switch (c.impl) {
            .vm => |vm_cl| {
                const p: *const Proto = @ptrCast(@alignCast(vm_cl.proto));
                const name = if (p.name.len > 0) p.name else p.inferred_name;
                if (p.is_class_constructor) {
                    if (name.len > 0) try ctx.w.print("[class {s}]", .{name}) else try ctx.w.writeAll("[class (anonymous)]");
                } else {
                    const kind_str = if (p.is_async_generator)
                        "AsyncGeneratorFunction"
                    else if (p.is_generator)
                        "GeneratorFunction"
                    else if (p.is_async)
                        "AsyncFunction"
                    else
                        "Function";
                    if (name.len > 0) {
                        try ctx.w.print("[{s}: {s}]", .{ kind_str, name });
                    } else {
                        try ctx.w.print("[{s} (anonymous)]", .{kind_str});
                    }
                }
            },
            .tree => |t| {
                const f: *const ast.Function = @ptrCast(@alignCast(t.func));
                const name: []const u8 = if (f.name) |n| n.name else f.inferred_name;
                if (f.is_class_constructor) {
                    if (name.len > 0) try ctx.w.print("[class {s}]", .{name}) else try ctx.w.writeAll("[class (anonymous)]");
                } else {
                    const kind_str = if (f.is_async and f.is_generator)
                        "AsyncGeneratorFunction"
                    else if (f.is_async)
                        "AsyncFunction"
                    else if (f.is_generator)
                        "GeneratorFunction"
                    else
                        "Function";
                    if (name.len > 0) {
                        try ctx.w.print("[{s}: {s}]", .{ kind_str, name });
                    } else {
                        try ctx.w.print("[{s} (anonymous)]", .{kind_str});
                    }
                }
            },
            .bound => |b| {
                try ctx.w.writeAll("[Function: bound ");
                try ops.writeUtf16(ctx.w, b.name.units);
                try ctx.w.writeByte(']');
            },
            .promise_cap, .native_closure => try ctx.w.writeAll("[Function (native)]"),
        }
        try ctx.w.writeAll(ctx.reset());
    }

    fn writeObject(ctx: *Context, obj: *const Object, depth: u32, indent: usize) (Allocator.Error || Writer.Error)!void {
        if (ctx.isOnActive(obj)) {
            const id = ctx.circular_ids.get(obj) orelse 0;
            try ctx.w.print("{s}[Circular *{d}]{s}", .{ ctx.style(Ansi.cyan), id, ctx.reset() });
            return;
        }

        if (ctx.circular_ids.get(obj)) |id| {
            try ctx.w.print("{s}<ref *{d}>{s} ", .{ ctx.style(Ansi.cyan), id, ctx.reset() });
        }

        // Special built-in kinds first.
        switch (obj.kind) {
            .date => |tv| {
                if (std.math.isFinite(tv)) {
                    var buf: [64]u8 = undefined;
                    try ctx.w.print("{s}{s}{s}", .{ ctx.style(Ansi.magenta), date.formatISO(&buf, tv), ctx.reset() });
                } else {
                    try ctx.w.print("{s}Invalid Date{s}", .{ ctx.style(Ansi.magenta), ctx.reset() });
                }
                return;
            },
            .regexp => |re| {
                try ctx.w.writeAll(ctx.style(Ansi.red));
                try ctx.w.writeByte('/');
                try ops.writeUtf16(ctx.w, re.source.units);
                try ctx.w.writeByte('/');
                try ops.writeUtf16(ctx.w, re.flags.units);
                try ctx.w.writeAll(ctx.reset());
                return;
            },
            .promise => |p| {
                try ctx.w.writeAll("Promise { ");
                switch (p.state) {
                    .pending => try ctx.w.print("{s}<pending>{s}", .{ ctx.style(Ansi.cyan), ctx.reset() }),
                    .fulfilled => {
                        if (depth >= ctx.options.depth) {
                            try ctx.w.print("{s}[Object]{s}", .{ ctx.style(Ansi.cyan), ctx.reset() });
                        } else {
                            try ctx.active.append(ctx.gpa, obj);
                            defer _ = ctx.active.pop();
                            try ctx.writeValue(p.result, depth + 1, indent);
                        }
                    },
                    .rejected => {
                        try ctx.w.print("{s}<rejected>{s} ", .{ ctx.style(Ansi.red), ctx.reset() });
                        if (depth >= ctx.options.depth) {
                            try ctx.w.print("{s}[Object]{s}", .{ ctx.style(Ansi.cyan), ctx.reset() });
                        } else {
                            try ctx.active.append(ctx.gpa, obj);
                            defer _ = ctx.active.pop();
                            try ctx.writeValue(p.result, depth + 1, indent);
                        }
                    },
                }
                try ctx.w.writeAll(" }");
                return;
            },
            .generator => |g| {
                if (g.is_async) {
                    try ctx.w.writeAll("Object [AsyncGenerator] {}");
                } else {
                    try ctx.w.writeAll("Object [Generator] {}");
                }
                return;
            },
            .array_buffer => |ab| {
                if (ab.detached) {
                    try ctx.w.print("ArrayBuffer {{ {s}(detached){s} }}", .{ ctx.style(Ansi.cyan), ctx.reset() });
                } else {
                    try ctx.w.print("ArrayBuffer {{ byteLength: {s}{d}{s} }}", .{ ctx.style(Ansi.yellow), ab.data.len, ctx.reset() });
                }
                return;
            },
            .data_view => |dv| {
                if (dv.buffer.kind.array_buffer.detached) {
                    try ctx.w.print("DataView {{ {s}(detached){s} }}", .{ ctx.style(Ansi.cyan), ctx.reset() });
                } else {
                    try ctx.w.print("DataView {{ byteLength: {s}{d}{s}, byteOffset: {s}{d}{s} }}", .{
                        ctx.style(Ansi.yellow), dv.byte_length, ctx.reset(),
                        ctx.style(Ansi.yellow), dv.byte_offset, ctx.reset(),
                    });
                }
                return;
            },
            .typed_array => |ta| {
                const type_name = ta.kind.name();
                if (ta.buffer.kind.array_buffer.detached) {
                    try ctx.w.print("{s}(0) []", .{type_name});
                    return;
                }
                if (ta.length == 0) {
                    try ctx.w.print("{s}(0) []", .{type_name});
                    return;
                }
                try ctx.w.print("{s}({d}) [ ", .{ type_name, ta.length });
                const n = @min(ta.length, ctx.options.max_items);
                for (0..n) |i| {
                    if (i > 0) try ctx.w.writeAll(", ");
                    if (ta.kind == .bigint64) {
                        const v = @import("../runtime/object.zig").readTypedArrayI64(ta, i);
                        try ctx.w.writeAll(ctx.style(Ansi.yellow));
                        try ctx.w.print("{d}n", .{v});
                        try ctx.w.writeAll(ctx.reset());
                    } else if (ta.kind == .biguint64) {
                        const v = @import("../runtime/object.zig").readTypedArrayU64(ta, i);
                        try ctx.w.writeAll(ctx.style(Ansi.yellow));
                        try ctx.w.print("{d}n", .{v});
                        try ctx.w.writeAll(ctx.reset());
                    } else {
                        const elem = @import("../runtime/object.zig").readTypedArrayNumber(ta, i);
                        try ctx.writeValue(elem, depth + 1, indent);
                    }
                }
                if (ta.length > n) try ctx.w.print(", ... {d} more items", .{ta.length - n});
                try ctx.w.writeAll(" ]");
                return;
            },
            .weak_map => {
                try ctx.w.print("WeakMap {{ {s}<items unknown>{s} }}", .{ ctx.style(Ansi.cyan), ctx.reset() });
                return;
            },
            .weak_set => {
                try ctx.w.print("WeakSet {{ {s}<items unknown>{s} }}", .{ ctx.style(Ansi.cyan), ctx.reset() });
                return;
            },
            .proxy => |px| {
                if (px.target == null or px.handler == null) {
                    try ctx.w.print("Proxy [ {s}<revoked>{s} ]", .{ ctx.style(Ansi.dim), ctx.reset() });
                    return;
                }
                if (depth >= ctx.options.depth) {
                    try ctx.w.print("{s}[Proxy]{s}", .{ ctx.style(Ansi.cyan), ctx.reset() });
                    return;
                }
                try ctx.active.append(ctx.gpa, obj);
                defer _ = ctx.active.pop();
                try ctx.w.writeAll("Proxy [ ");
                try ctx.writeValue(px.target.?, depth + 1, indent);
                try ctx.w.writeAll(", ");
                try ctx.writeValue(px.handler.?, depth + 1, indent);
                try ctx.w.writeAll(" ]");
                return;
            },
            else => {},
        }

        if (depth >= ctx.options.depth) {
            const label = switch (obj.kind) {
                .array => "[Array]",
                .map => "[Map]",
                .set => "[Set]",
                .weak_map => "[WeakMap]",
                .weak_set => "[WeakSet]",
                else => "[Object]",
            };
            try ctx.w.print("{s}{s}{s}", .{ ctx.style(Ansi.cyan), label, ctx.reset() });
            return;
        }

        try ctx.active.append(ctx.gpa, obj);
        defer _ = ctx.active.pop();

        switch (obj.kind) {
            .array => |arr| try ctx.writeArray(arr.items, obj, depth, indent),
            .map => |m| try ctx.writeMap(m, depth, indent),
            .set => |s| try ctx.writeSet(s, depth, indent),
            else => {
                if (ctx.isErrorObject(obj)) {
                    try ctx.writeErrorObject(obj);
                    return;
                }
                try ctx.writeOrdinaryObject(obj, depth, indent);
            },
        }
    }

    fn writeArray(ctx: *Context, items: []const Value, obj: *const Object, depth: u32, indent: usize) (Allocator.Error || Writer.Error)!void {
        _ = obj;
        if (items.len == 0) {
            try ctx.w.writeAll("[]");
            return;
        }
        const n = @min(items.len, ctx.options.max_items);
        var inline_mode = items.len <= 8;
        if (inline_mode) {
            for (items[0..n]) |item| {
                if (item.isObject()) {
                    inline_mode = false;
                    break;
                }
            }
        }

        if (inline_mode) {
            try ctx.w.writeAll("[ ");
            for (items[0..n], 0..) |item, i| {
                if (i > 0) try ctx.w.writeAll(", ");
                try ctx.writeValue(item, depth + 1, indent);
            }
            if (items.len > n) {
                try ctx.w.print(", {s}... {d} more items{s}", .{ ctx.style(Ansi.dim), items.len - n, ctx.reset() });
            }
            try ctx.w.writeAll(" ]");
        } else {
            try ctx.w.writeAll("[\n");
            for (items[0..n], 0..) |item, i| {
                try ctx.w.splatByteAll(' ', indent + 2);
                try ctx.writeValue(item, depth + 1, indent + 2);
                if (i + 1 < n or items.len > n) try ctx.w.writeByte(',');
                try ctx.w.writeByte('\n');
            }
            if (items.len > n) {
                try ctx.w.splatByteAll(' ', indent + 2);
                try ctx.w.print("{s}... {d} more items{s}\n", .{ ctx.style(Ansi.dim), items.len - n, ctx.reset() });
            }
            try ctx.w.splatByteAll(' ', indent);
            try ctx.w.writeByte(']');
        }
    }

    fn writeMap(ctx: *Context, m: heap.OrderedTable, depth: u32, indent: usize) (Allocator.Error || Writer.Error)!void {
        try ctx.w.print("Map({d}) {{", .{m.live_count});
        if (m.live_count == 0) {
            try ctx.w.writeByte('}');
            return;
        }
        try ctx.w.writeByte(' ');
        var count: usize = 0;
        for (m.entries.items) |entry| {
            if (!entry.alive) continue;
            if (count >= ctx.options.max_items) {
                try ctx.w.print(", {s}... {d} more items{s}", .{ ctx.style(Ansi.dim), m.live_count - count, ctx.reset() });
                break;
            }
            if (count > 0) try ctx.w.writeAll(", ");
            try ctx.writeValue(entry.key, depth + 1, indent);
            try ctx.w.writeAll(" => ");
            try ctx.writeValue(entry.value, depth + 1, indent);
            count += 1;
        }
        try ctx.w.writeAll(" }");
    }

    fn writeSet(ctx: *Context, s: heap.OrderedTable, depth: u32, indent: usize) (Allocator.Error || Writer.Error)!void {
        try ctx.w.print("Set({d}) {{", .{s.live_count});
        if (s.live_count == 0) {
            try ctx.w.writeByte('}');
            return;
        }
        try ctx.w.writeByte(' ');
        var count: usize = 0;
        for (s.entries.items) |entry| {
            if (!entry.alive) continue;
            if (count >= ctx.options.max_items) {
                try ctx.w.print(", {s}... {d} more items{s}", .{ ctx.style(Ansi.dim), s.live_count - count, ctx.reset() });
                break;
            }
            if (count > 0) try ctx.w.writeAll(", ");
            try ctx.writeValue(entry.key, depth + 1, indent);
            count += 1;
        }
        try ctx.w.writeAll(" }");
    }

    fn writeOrdinaryObject(ctx: *Context, obj: *const Object, depth: u32, indent: usize) (Allocator.Error || Writer.Error)!void {
        const tag = ctx.getToStringTag(obj);
        if (obj.proto == null) {
            try ctx.w.writeAll("[Object: null prototype] ");
        } else if (ctx.getConstructorName(obj)) |cname| {
            try ctx.w.writeAll(cname);
            if (tag) |t| {
                if (!utf16EqlAscii(t.units, cname)) {
                    try ctx.w.writeAll(" [");
                    try ops.writeUtf16(ctx.w, t.units);
                    try ctx.w.writeByte(']');
                }
            }
            try ctx.w.writeByte(' ');
        } else if (tag) |t| {
            try ctx.w.writeAll("Object [");
            try ops.writeUtf16(ctx.w, t.units);
            try ctx.w.writeAll("] ");
        }

        // Count enumerable own properties.
        var enum_count: usize = 0;
        var it_count = obj.props.iterator();
        while (it_count.next()) |e| {
            if (e.value_ptr.enumerable) enum_count += 1;
        }

        if (enum_count == 0) {
            try ctx.w.writeAll("{}");
            return;
        }

        const multiline = enum_count > 4 or indent > 0;
        try ctx.w.writeAll(if (multiline) "{\n" else "{ ");
        var it = obj.props.iterator();
        var shown: usize = 0;
        while (it.next()) |entry| {
            if (!entry.value_ptr.enumerable) continue;
            if (shown >= ctx.options.max_items) {
                if (multiline) try ctx.w.splatByteAll(' ', indent + 2) else try ctx.w.writeAll(", ");
                try ctx.w.print("{s}... {d} more items{s}", .{ ctx.style(Ansi.dim), enum_count - shown, ctx.reset() });
                if (multiline) try ctx.w.writeByte('\n');
                break;
            }
            if (multiline) {
                try ctx.w.splatByteAll(' ', indent + 2);
            } else if (shown > 0) {
                try ctx.w.writeAll(", ");
            }
            try ctx.writePropKey(entry.key_ptr.*);
            try ctx.w.writeAll(": ");
            try ctx.writePropertyValue(entry.value_ptr.*, depth, if (multiline) indent + 2 else indent);
            if (multiline) {
                if (shown + 1 < enum_count) try ctx.w.writeByte(',');
                try ctx.w.writeByte('\n');
            }
            shown += 1;
        }
        if (multiline) {
            try ctx.w.splatByteAll(' ', indent);
            try ctx.w.writeByte('}');
        } else {
            try ctx.w.writeAll(" }");
        }
    }

    fn writePropertyValue(ctx: *Context, prop: Property, depth: u32, indent: usize) (Allocator.Error || Writer.Error)!void {
        if (prop.is_accessor) {
            const has_get = !prop.value.isUndefined();
            const has_set = !prop.setter.isUndefined();
            try ctx.w.writeAll(ctx.style(Ansi.cyan));
            if (has_get and has_set) {
                try ctx.w.writeAll("[Getter/Setter]");
            } else if (has_get) {
                try ctx.w.writeAll("[Getter]");
            } else if (has_set) {
                try ctx.w.writeAll("[Setter]");
            } else {
                try ctx.w.writeAll("[Accessor]");
            }
            try ctx.w.writeAll(ctx.reset());
            return;
        }
        try ctx.writeValue(prop.value, depth + 1, indent);
    }

    fn writePropKey(ctx: *const Context, key: PropKey) Writer.Error!void {
        if (key.isSymbol()) {
            const sym = key.asSymbol();
            try ctx.w.writeAll(ctx.style(Ansi.green));
            try ctx.w.writeAll("[Symbol(");
            if (sym.description) |desc| try ops.writeUtf16(ctx.w, desc.units);
            try ctx.w.writeAll(")]");
            try ctx.w.writeAll(ctx.reset());
            return;
        }
        const s = key.asAtom();
        if (isPlainIdentifier(s.units)) {
            try ops.writeUtf16(ctx.w, s.units);
        } else {
            try ctx.w.writeAll(ctx.style(Ansi.green));
            try writeQuotedString(ctx.w, s.units);
            try ctx.w.writeAll(ctx.reset());
        }
    }

    fn getConstructorName(ctx: *const Context, obj: *const Object) ?[]const u8 {
        const proto = obj.proto orelse return null;
        if (ctx.rt.realm) |r| {
            if (proto == r.object_prototype) return null;
        }
        var it = proto.props.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.isSymbol()) continue;
            if (utf16EqlAscii(entry.key_ptr.asAtom().units, "constructor")) {
                if (entry.value_ptr.is_accessor) return null;
                switch (entry.value_ptr.value.unpack()) {
                    .closure => |c| switch (c.impl) {
                        .vm => |vm_cl| {
                            const p: *const Proto = @ptrCast(@alignCast(vm_cl.proto));
                            const name = if (p.name.len > 0) p.name else p.inferred_name;
                            return if (name.len > 0 and !std.mem.eql(u8, name, "Object")) name else null;
                        },
                        .tree => |t| {
                            const f: *const ast.Function = @ptrCast(@alignCast(t.func));
                            const name: []const u8 = if (f.name) |n| n.name else f.inferred_name;
                            return if (name.len > 0 and !std.mem.eql(u8, name, "Object")) name else null;
                        },
                        else => return null,
                    },
                    .native => |n| return if (n.name.len > 0 and !std.mem.eql(u8, n.name, "Object")) n.name else null,
                    else => return null,
                }
            }
        }
        return null;
    }

    fn getToStringTag(ctx: *const Context, obj: *const Object) ?*const heap.String {
        const r = ctx.rt.realm orelse return null;
        const sym_key = PropKey.fromSymbol(r.sym_to_string_tag);
        var cur: ?*const Object = obj;
        var steps: usize = 0;
        while (cur) |o| : (steps += 1) {
            if (steps > 64) break;
            if (o.props.get(sym_key)) |prop| {
                if (!prop.is_accessor and prop.value.isString() and prop.value.asString().units.len > 0) {
                    return prop.value.asString();
                }
                return null;
            }
            cur = o.proto;
        }
        return null;
    }

    fn isErrorObject(ctx: *const Context, obj: *const Object) bool {
        const r = ctx.rt.realm orelse return false;
        var cur: ?*const Object = obj;
        var steps: usize = 0;
        while (cur) |o| : (steps += 1) {
            if (steps > 64) break;
            if (o == r.error_prototype) return true;
            cur = o.proto;
        }
        return false;
    }

    fn writeErrorObject(ctx: *const Context, obj: *const Object) Writer.Error!void {
        const name_val = getReadOnlyPropAscii(obj, "name");
        const msg_val = getReadOnlyPropAscii(obj, "message");
        if (name_val) |nv| {
            if (nv.isString()) {
                try ops.writeUtf16(ctx.w, nv.asString().units);
            } else {
                try ctx.w.writeAll("Error");
            }
        } else {
            try ctx.w.writeAll("Error");
        }
        if (msg_val) |mv| {
            if (mv.isString() and mv.asString().units.len > 0) {
                try ctx.w.writeAll(": ");
                try ops.writeUtf16(ctx.w, mv.asString().units);
            }
        }
    }
};

fn getReadOnlyPropAscii(obj: *const Object, key_ascii: []const u8) ?Value {
    var cur: ?*const Object = obj;
    var steps: usize = 0;
    while (cur) |o| : (steps += 1) {
        if (steps > 64) break;
        var it = o.props.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.isSymbol()) continue;
            if (utf16EqlAscii(entry.key_ptr.asAtom().units, key_ascii)) {
                if (entry.value_ptr.is_accessor) return null;
                return entry.value_ptr.value;
            }
        }
        cur = o.proto;
    }
    return null;
}

fn utf16EqlAscii(units: []const u16, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |u, a| {
        if (u != a) return false;
    }
    return true;
}

fn isPlainIdentifier(units: []const u16) bool {
    if (units.len == 0) return false;
    for (units, 0..) |u, i| {
        if (u > 127) return false;
        const c: u8 = @intCast(u);
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$' or (i > 0 and c >= '0' and c <= '9');
        if (!ok) return false;
    }
    return true;
}

fn writeBigIntRaw(w: *Writer, b: *const heap.BigInt) Writer.Error!void {
    if (b.negative) try w.writeByte('-');
    if (b.limbs.len == 1) {
        try w.print("{d}", .{b.limbs[0]});
        return;
    }
    const alloc = std.heap.page_allocator;
    var work = alloc.dupe(u64, b.limbs) catch {
        try w.writeAll("<BigInt>");
        return;
    };
    defer alloc.free(work);
    var chunks = std.ArrayList(u64).empty;
    defer chunks.deinit(alloc);

    const base: u64 = 10_000_000_000_000_000_000; // 10^19
    var len = work.len;
    while (len > 0) {
        var rem: u128 = 0;
        var i = len;
        while (i > 0) {
            i -= 1;
            const cur = (rem << 64) | work[i];
            work[i] = @truncate(cur / base);
            rem = cur % base;
        }
        while (len > 0 and work[len - 1] == 0) : (len -= 1) {}
        chunks.append(alloc, @truncate(rem)) catch {
            try w.writeAll("<BigInt>");
            return;
        };
    }
    var i = chunks.items.len;
    if (i > 0) {
        i -= 1;
        try w.print("{d}", .{chunks.items[i]});
        while (i > 0) {
            i -= 1;
            try w.print("{d:0>19}", .{chunks.items[i]});
        }
    }
}

fn writeQuotedString(w: *Writer, units: []const u16) Writer.Error!void {
    try w.writeByte('\'');
    for (units) |u| {
        switch (u) {
            '\'' => try w.writeAll("\\'"),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (u < 0x20) {
                    try w.print("\\x{x:0>2}", .{u});
                } else {
                    try ops.writeUtf16(w, &.{u});
                }
            },
        }
    }
    try w.writeByte('\'');
}
