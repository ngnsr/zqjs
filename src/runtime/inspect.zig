//! Cycle-safe, depth-bounded, colorized JS value inspector (Node `util.inspect` style, D71).
//! Strictly read-only: never invokes getters or runs JS code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = @import("value.zig").Value;
const Native = @import("value.zig").Native;
const heap = @import("heap.zig");
const Object = heap.Object;
const Closure = heap.Closure;
const PropKey = heap.PropKey;
const Property = heap.Property;
const Runtime = @import("runtime.zig").Runtime;
const ops = @import("ops.zig");
const date = @import("date.zig");
const ast = @import("../frontend/ast.zig");
const Proto = @import("../bytecode/bytecode.zig").Proto;

pub const Options = struct {
    depth: u32 = 4,
    max_items: usize = 100,
    color: bool = false,
    /// node's `showHidden`: also list non-enumerable own properties as `[key]` and an
    /// array's `[length]`. shortcut: a function's and a typed array's hidden properties
    /// are not listed; add them if `%o` output for those must match node.
    show_hidden: bool = false,
};

/// node's `util.inspect` layout defaults (`lib/internal/util/inspect.js`).
const break_length = 80;
const compact = 3;

const Err = Allocator.Error || Writer.Error;

/// One object's entries, each formatted to its own string before the layout is chosen
/// (node's `output`).
const Output = std.ArrayList([]u8);

fn freeOutput(gpa: Allocator, out: *Output) void {
    for (out.items) |s| gpa.free(s);
    out.deinit(gpa);
}

/// Whether `reduce` may group array entries into columns, and how they align.
const Group = enum { none, numbers, mixed };

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

pub fn inspect(rt: *const Runtime, v: Value, w: *Writer, options: Options) Err!void {
    var ctx: Context = .{
        .rt = rt,
        .gpa = rt.gpa,
        .w = w,
        .options = options,
    };
    defer ctx.deinit();

    // Pre-pass: detect cycles / shared references within depth bound to assign <ref *N>.
    try ctx.scanCycles(v, 0);
    try ctx.writeValue(v, 0);
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
    /// node's `indentationLvl`: the column a nested multi-line value's lines start at.
    indent: usize = 0,
    /// node's `currentDepth`: depth of the last object whose entries were formatted.
    current_depth: u32 = 0,

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
            if (!entry.value_ptr.enumerable and !ctx.options.show_hidden) continue;
            if (!entry.value_ptr.is_accessor) {
                try ctx.scanCycles(entry.value_ptr.value, depth + 1);
            }
            prop_count += 1;
        }
    }

    fn writeValue(ctx: *Context, v: Value, depth: u32) Err!void {
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
            .object => |obj| try ctx.writeObject(obj, depth),
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

    fn writeObject(ctx: *Context, obj: *const Object, depth: u32) Err!void {
        if (ctx.isOnActive(obj)) {
            const id = ctx.circular_ids.get(obj) orelse 0;
            try ctx.w.print("{s}[Circular *{d}]{s}", .{ ctx.style(Ansi.cyan), id, ctx.reset() });
            return;
        }

        // node's `base`: it leads either layout, but still counts toward the line length.
        var base_len: usize = 0;
        if (ctx.circular_ids.get(obj)) |id| {
            const args = .{ ctx.style(Ansi.cyan), id, ctx.reset() };
            base_len = std.fmt.count("{s}<ref *{d}>{s}", args);
            try ctx.w.print("{s}<ref *{d}>{s} ", args);
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
                if (ta.buffer.kind.array_buffer.detached or ta.length == 0) {
                    try ctx.w.print("{s}(0) []", .{type_name});
                    return;
                }
                if (depth >= ctx.options.depth) {
                    try ctx.w.print("{s}[{s}]{s}", .{ ctx.style(Ansi.cyan), type_name, ctx.reset() });
                    return;
                }
                ctx.current_depth = depth;
                var out: Output = .empty;
                defer freeOutput(ctx.gpa, &out);
                const n = @min(ta.length, ctx.options.max_items);
                for (0..n) |i| try ctx.collect(&out, writeTypedElement, .{ ta, i });
                if (ta.length > n) try ctx.pushRemaining(&out, ta.length - n);
                var prefix: [48]u8 = undefined;
                const p = std.fmt.bufPrint(&prefix, "{s}({d}) ", .{ type_name, ta.length }) catch unreachable;
                try ctx.reduce(&out, base_len, p, "[]", .numbers, depth);
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
                // node's `formatProxy`: it leaves `currentDepth` alone.
                var out: Output = .empty;
                defer freeOutput(ctx.gpa, &out);
                try ctx.collect(&out, writeIndented, .{ px.target.?, depth + 1 });
                try ctx.collect(&out, writeIndented, .{ px.handler.?, depth + 1 });
                try ctx.reduce(&out, base_len, "Proxy ", "[]", .none, depth + 1);
                return;
            },
            else => {},
        }

        // node prints an empty container before it checks depth; a Promise is never empty.
        const is_array = obj.kind == .array;
        const keys = ctx.countKeys(obj, is_array);
        var prefix: Writer.Allocating = .init(ctx.gpa);
        defer prefix.deinit();
        switch (obj.kind) {
            .array => |arr| if (arr.items.len == 0 and keys == 0 and !ctx.options.show_hidden) {
                try ctx.w.writeAll("[]");
                return;
            },
            .map, .set => |t| {
                try prefix.writer.print("{s}({d}) ", .{ if (obj.kind == .map) "Map" else "Set", t.live_count });
                if (t.live_count == 0 and keys == 0) {
                    try ctx.w.print("{s}{{}}", .{prefix.written()});
                    return;
                }
            },
            .promise => try prefix.writer.writeAll("Promise "),
            else => {
                if (ctx.isErrorObject(obj)) {
                    try ctx.writeErrorObject(obj);
                    return;
                }
                try ctx.writeObjectPrefix(&prefix.writer, obj);
                if (keys == 0) {
                    try ctx.w.print("{s}{{}}", .{prefix.written()});
                    return;
                }
            },
        }

        if (depth >= ctx.options.depth) {
            const name = std.mem.trimEnd(u8, prefix.written(), " ");
            switch (obj.kind) {
                .array => try ctx.w.print("{s}[Array]{s}", .{ ctx.style(Ansi.cyan), ctx.reset() }),
                .map => try ctx.w.print("{s}[Map]{s}", .{ ctx.style(Ansi.cyan), ctx.reset() }),
                .set => try ctx.w.print("{s}[Set]{s}", .{ ctx.style(Ansi.cyan), ctx.reset() }),
                .promise => try ctx.w.print("{s}[Promise]{s}", .{ ctx.style(Ansi.cyan), ctx.reset() }),
                // `[Object: null prototype]` is already bracketed.
                else => if (obj.proto == null)
                    try ctx.w.print("{s}{s}{s}", .{ ctx.style(Ansi.cyan), name, ctx.reset() })
                else
                    try ctx.w.print("{s}[{s}]{s}", .{ ctx.style(Ansi.cyan), if (name.len == 0) "Object" else name, ctx.reset() }),
            }
            return;
        }

        try ctx.active.append(ctx.gpa, obj);
        defer _ = ctx.active.pop();
        ctx.current_depth = depth;

        var out: Output = .empty;
        defer freeOutput(ctx.gpa, &out);
        switch (obj.kind) {
            .array => |arr| {
                try ctx.collectArray(&out, arr.items, depth + 1);
                if (ctx.options.show_hidden) try ctx.pushFmt(&out, "[length]: {s}{d}{s}", .{ ctx.style(Ansi.yellow), arr.items.len, ctx.reset() });
            },
            .map => |m| {
                var shown: usize = 0;
                for (m.entries.items) |entry| {
                    if (!entry.alive) continue;
                    if (shown >= ctx.options.max_items) break;
                    try ctx.collect(&out, writeMapEntry, .{ entry.key, entry.value, depth + 1 });
                    shown += 1;
                }
                if (m.live_count > shown) try ctx.pushRemaining(&out, m.live_count - shown);
            },
            .set => |s| {
                var shown: usize = 0;
                for (s.entries.items) |entry| {
                    if (!entry.alive) continue;
                    if (shown >= ctx.options.max_items) break;
                    try ctx.collect(&out, writeIndented, .{ entry.key, depth + 1 });
                    shown += 1;
                }
                if (s.live_count > shown) try ctx.pushRemaining(&out, s.live_count - shown);
            },
            .promise => |p| switch (p.state) {
                .pending => try ctx.pushFmt(&out, "{s}<pending>{s}", .{ ctx.style(Ansi.cyan), ctx.reset() }),
                .fulfilled => try ctx.collect(&out, writeIndented, .{ p.result, depth + 1 }),
                .rejected => try ctx.collect(&out, writeRejected, .{ p.result, depth + 1 }),
            },
            else => {},
        }
        try ctx.collectKeys(&out, obj, depth + 1, is_array);

        const group: Group = if (!is_array) .none else if (allNumbers(obj.kind.array.items, out.items.len)) .numbers else .mixed;
        try ctx.reduce(&out, base_len, prefix.written(), if (is_array) "[]" else "{}", group, depth);
    }

    /// node's `reduceToSingleString` with `compact: 3`: the entries share one line when
    /// fewer than `compact` levels of objects nest below and they fit in `break_length`;
    /// otherwise each entry, or each row of grouped array entries, gets its own line.
    fn reduce(ctx: *Context, out: *Output, base_len: usize, prefix: []const u8, braces: *const [2]u8, group: Group, depth: u32) Err!void {
        const entries = out.items.len;
        if (group != .none and entries > 6) try ctx.groupArrayElements(out, group == .numbers);
        if (@as(i64, ctx.current_depth) - depth < compact and entries == out.items.len) {
            const start = out.items.len + ctx.indent + utf16Len(prefix) + 1 + base_len + 10;
            if (isBelowBreakLength(out.items, start)) {
                try ctx.w.print("{s}{c} ", .{ prefix, braces[0] });
                for (out.items, 0..) |s, i| {
                    if (i > 0) try ctx.w.writeAll(", ");
                    try ctx.w.writeAll(s);
                }
                try ctx.w.print(" {c}", .{braces[1]});
                return;
            }
        }
        try ctx.w.print("{s}{c}", .{ prefix, braces[0] });
        for (out.items, 0..) |s, i| {
            if (i > 0) try ctx.w.writeByte(',');
            try ctx.w.writeByte('\n');
            try ctx.w.splatByteAll(' ', ctx.indent + 2);
            try ctx.w.writeAll(s);
        }
        try ctx.w.writeByte('\n');
        try ctx.w.splatByteAll(' ', ctx.indent);
        try ctx.w.writeByte(braces[1]);
    }

    /// node's `groupArrayElements`: lays more than six short entries out in aligned
    /// columns, a few per line (numbers right-aligned), as long as that stays roughly square.
    fn groupArrayElements(ctx: *Context, out: *Output, numbers: bool) Err!void {
        const separator_space = 2; // ", " between two entries
        // The `... n more items` entry is not grouped.
        const output_len = if (ctx.options.max_items < out.items.len) out.items.len - 1 else out.items.len;
        const data_len = try ctx.gpa.alloc(usize, output_len);
        defer ctx.gpa.free(data_len);
        var total_len: usize = 0;
        var max_len: usize = 0;
        for (out.items[0..output_len], data_len) |s, *d| {
            d.* = displaySize(s).width;
            total_len += d.* + separator_space;
            max_len = @max(max_len, d.*);
        }
        const actual_max = max_len + separator_space;
        const total: f64 = @floatFromInt(total_len);
        const actual: f64 = @floatFromInt(actual_max);
        // Three entries must fit side by side, and no entry may dwarf the rest.
        if (!(actual_max * 3 + ctx.indent < break_length and (total / actual > 5 or max_len <= 6))) return;

        const average_bias = @sqrt(actual - total / @as(f64, @floatFromInt(out.items.len)));
        const biased_max = @max(actual - 3 - average_bias, 1);
        // Aim for a square, taking a character to be 2.5 times as high as it is wide.
        const square = @round(@sqrt(2.5 * biased_max * @as(f64, @floatFromInt(output_len))) / biased_max);
        const columns = @min(@as(usize, @intFromFloat(square)), (break_length - ctx.indent) / actual_max, compact * 4, 15);
        if (columns <= 1) return;

        var max_line_len: [15]usize = undefined;
        for (max_line_len[0..columns], 0..) |*m, i| {
            var line_max: usize = 0;
            var j = i;
            while (j < output_len) : (j += columns) line_max = @max(line_max, data_len[j]);
            m.* = line_max + separator_space;
        }

        var grouped: Output = .empty;
        errdefer freeOutput(ctx.gpa, &grouped);
        try grouped.ensureTotalCapacity(ctx.gpa, output_len / columns + 2);
        var line: Writer.Allocating = .init(ctx.gpa);
        defer line.deinit();
        var i: usize = 0;
        while (i < output_len) : (i += columns) {
            const end = @min(i + columns, output_len);
            for (i..end) |j| {
                const s = out.items[j];
                const last = j == end - 1;
                // Padding is in `.length` units, so an entry's color codes widen its cell.
                const cell = max_line_len[j - i] + utf16Len(s) - data_len[j] - @as(usize, if (last) separator_space else 0);
                const used = utf16Len(s) + @as(usize, if (last) 0 else separator_space);
                const pad = cell -| used;
                if (numbers) try line.writer.splatByteAll(' ', pad);
                try line.writer.writeAll(s);
                if (!last) {
                    try line.writer.writeAll(", ");
                    if (!numbers) try line.writer.splatByteAll(' ', pad);
                }
            }
            grouped.appendAssumeCapacity(try line.toOwnedSlice());
        }
        if (output_len < out.items.len) {
            grouped.appendAssumeCapacity(out.items[output_len]);
            out.items.len -= 1;
        }
        freeOutput(ctx.gpa, out);
        out.* = grouped;
    }

    /// Formats one entry into its own string: node formats every entry before it picks
    /// a layout, and that choice depends on the entries' lengths.
    fn collect(ctx: *Context, out: *Output, comptime f: anytype, args: anytype) Err!void {
        var aw: Writer.Allocating = .init(ctx.gpa);
        defer aw.deinit();
        const saved = ctx.w;
        ctx.w = &aw.writer;
        defer ctx.w = saved;
        try @call(.auto, f, .{ctx} ++ args);
        try out.ensureUnusedCapacity(ctx.gpa, 1);
        out.appendAssumeCapacity(try aw.toOwnedSlice());
    }

    fn pushFmt(ctx: *Context, out: *Output, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try out.ensureUnusedCapacity(ctx.gpa, 1);
        out.appendAssumeCapacity(try std.fmt.allocPrint(ctx.gpa, fmt, args));
    }

    /// node's `remainingText`.
    fn pushRemaining(ctx: *Context, out: *Output, n: usize) Allocator.Error!void {
        try ctx.pushFmt(out, "... {d} more item{s}", .{ n, if (n == 1) "" else "s" });
    }

    fn pushEmpty(ctx: *Context, out: *Output, n: usize) Allocator.Error!void {
        try ctx.pushFmt(out, "{s}<{d} empty item{s}>{s}", .{ ctx.style(Ansi.dim), n, if (n == 1) "" else "s", ctx.reset() });
    }

    /// node's `formatArray`/`formatSpecialArray`: up to `max_items` entries, a run of holes
    /// being one `<n empty items>` entry (a hole is not a value: never format it).
    fn collectArray(ctx: *Context, out: *Output, items: []const Value, depth: u32) Err!void {
        const max = @min(items.len, ctx.options.max_items);
        var index: usize = 0;
        while (out.items.len < max) {
            var next = index;
            while (next < items.len and items[next].isHole()) next += 1;
            if (next == items.len) break;
            if (next != index) {
                try ctx.pushEmpty(out, next - index);
                index = next;
                if (out.items.len == max) break;
            }
            try ctx.collect(out, writeIndented, .{ items[index], depth });
            index += 1;
        }
        const remaining = items.len - index;
        if (remaining == 0) return;
        if (out.items.len == max) try ctx.pushRemaining(out, remaining) else try ctx.pushEmpty(out, remaining);
    }

    /// Whether node would list `key` among an object's own keys; an array's index keys are
    /// skipped as its elements already show them.
    fn isListedKey(ctx: *const Context, key: PropKey, prop: Property, skip_index: bool) bool {
        if (!prop.enumerable and !ctx.options.show_hidden) return false;
        return !(skip_index and !key.isSymbol() and key.asAtom().atom.?.index != null);
    }

    fn countKeys(ctx: *const Context, obj: *const Object, skip_index: bool) usize {
        var n: usize = 0;
        var it = obj.props.iterator();
        while (it.next()) |e| {
            if (ctx.isListedKey(e.key_ptr.*, e.value_ptr.*, skip_index)) n += 1;
        }
        return n;
    }

    fn collectKeys(ctx: *Context, out: *Output, obj: *const Object, depth: u32, skip_index: bool) Err!void {
        const total = ctx.countKeys(obj, skip_index);
        var shown: usize = 0;
        var it = obj.props.iterator();
        while (it.next()) |e| {
            if (!ctx.isListedKey(e.key_ptr.*, e.value_ptr.*, skip_index)) continue;
            if (shown >= ctx.options.max_items) {
                try ctx.pushRemaining(out, total - shown);
                break;
            }
            try ctx.collect(out, writePropEntry, .{ e.key_ptr.*, e.value_ptr.*, depth });
            shown += 1;
        }
    }

    /// An array element, Set member or Promise result: node formats it two columns in.
    fn writeIndented(ctx: *Context, v: Value, depth: u32) Err!void {
        ctx.indent += 2;
        defer ctx.indent -= 2;
        try ctx.writeValue(v, depth);
    }

    fn writeRejected(ctx: *Context, v: Value, depth: u32) Err!void {
        try ctx.w.print("{s}<rejected>{s} ", .{ ctx.style(Ansi.red), ctx.reset() });
        try ctx.writeIndented(v, depth);
    }

    fn writeMapEntry(ctx: *Context, k: Value, v: Value, depth: u32) Err!void {
        try ctx.writeIndented(k, depth);
        try ctx.w.writeAll(" => ");
        try ctx.writeIndented(v, depth);
    }

    fn writeTypedElement(ctx: *Context, ta: heap.TypedArrayState, i: usize) Err!void {
        const object = @import("object.zig");
        switch (ta.kind) {
            .bigint64 => try ctx.w.print("{s}{d}n{s}", .{ ctx.style(Ansi.yellow), object.readTypedArrayI64(ta, i), ctx.reset() }),
            .biguint64 => try ctx.w.print("{s}{d}n{s}", .{ ctx.style(Ansi.yellow), object.readTypedArrayU64(ta, i), ctx.reset() }),
            else => try ctx.writeValue(object.readTypedArrayNumber(ta, i), 0),
        }
    }

    /// node's `formatProperty`: `key: value`, with a non-enumerable key as `[key]`.
    fn writePropEntry(ctx: *Context, key: PropKey, prop: Property, depth: u32) Err!void {
        if (!prop.enumerable) try ctx.w.writeByte('[');
        try ctx.writePropKey(key);
        if (!prop.enumerable) try ctx.w.writeByte(']');
        try ctx.w.writeAll(": ");
        ctx.indent += 2;
        defer ctx.indent -= 2;
        try ctx.writePropertyValue(prop, depth);
    }

    /// node's `getPrefix` for an ordinary object: `Foo `, `Object [Tag] `, `[Object: null prototype] `.
    fn writeObjectPrefix(ctx: *const Context, w: *Writer, obj: *const Object) Writer.Error!void {
        const tag = ctx.getToStringTag(obj);
        if (obj.proto == null) {
            try w.writeAll("[Object: null prototype] ");
        } else if (ctx.getConstructorName(obj)) |cname| {
            try w.writeAll(cname);
            if (tag) |t| {
                if (!utf16EqlAscii(t.units, cname)) {
                    try w.writeAll(" [");
                    try ops.writeUtf16(w, t.units);
                    try w.writeByte(']');
                }
            }
            try w.writeByte(' ');
        } else if (tag) |t| {
            try w.writeAll("Object [");
            try ops.writeUtf16(w, t.units);
            try w.writeAll("] ");
        }
    }

    fn writePropertyValue(ctx: *Context, prop: Property, depth: u32) Err!void {
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
        try ctx.writeValue(prop.value, depth);
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

/// UTF-16 length of UTF-8 text: node measures with `str.length`.
fn utf16Len(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if ((b & 0xC0) != 0x80) n += 1;
        if (b >= 0xF0) n += 1; // a 4-byte sequence is a surrogate pair
    }
    return n;
}

/// node's `removeColors(s).length` (`len`) and `getStringWidth(s)` (`width`: control
/// characters such as a nested value's newlines take no column).
/// shortcut: a non-ASCII code point is one column; node asks ICU (wide CJK and emoji are
/// two, combining marks zero). Upgrade if grouped arrays of such strings must align.
fn displaySize(s: []const u8) struct { len: usize, width: usize } {
    var len: usize = 0;
    var width: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const b = s[i];
        if (b == 0x1b) { // an ANSI color: strings print ESC escaped, so only `color` adds one
            while (i < s.len and s[i] != 'm') i += 1;
            continue;
        }
        if ((b & 0xC0) == 0x80) continue;
        len += if (b >= 0xF0) 2 else 1;
        if (b >= 0x20) width += 1;
    }
    return .{ .len = len, .width = width };
}

/// node's `isBelowBreakLength`, plus its check that no entry spans lines.
fn isBelowBreakLength(entries: []const []u8, start: usize) bool {
    var total = entries.len + start;
    if (total + entries.len > break_length) return false;
    for (entries) |s| {
        total += displaySize(s).len;
        if (total > break_length) return false;
    }
    for (entries) |s| {
        if (std.mem.indexOfScalar(u8, s, '\n') != null) return false;
    }
    return true;
}

/// Whether node right-aligns grouped array entries: it checks `typeof value[i]` for every
/// entry index, so trailing keys past the elements, and holes, make it left-align.
fn allNumbers(items: []const Value, n: usize) bool {
    if (n > items.len) return false;
    for (items[0..n]) |v| {
        if (!v.isNumber() and !v.isBigInt()) return false;
    }
    return true;
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

// ---------------------------------------------------------------- Unit Tests
// Each expected text is node 26's output for the same source, byte for byte.

fn expectConsole(source: []const u8, expected: []const u8) !void {
    const run = @import("../run.zig");
    const gpa = std.testing.allocator;
    for ([_]run.Engine{ .vm, .treewalk }) |engine| {
        var out: Writer.Allocating = .init(gpa);
        defer out.deinit();
        var err: Writer.Allocating = .init(gpa);
        defer err.deinit();
        const code = try run.runSource(gpa, "inspect_test.js", source, .{}, .{ .mode = .normal, .engine = engine }, &out.writer, &err.writer);
        try std.testing.expectEqualStrings("", err.written());
        try std.testing.expectEqual(@as(u8, 0), code);
        try std.testing.expectEqualStrings(expected, out.written());
    }
}

test "inspect: arrays group into columns like node (numbers, strings, holes, extra keys)" {
    try expectConsole(
        \\console.log([1, 2, 3]);
        \\console.log([1, 2, 3, 4, 5, 6]);
        \\console.log([1, 2, 3, 4, 5, 6, 7]);
        \\console.log(Array.from({ length: 26 }, (_, i) => i * 3));
        \\console.log(Array.from({ length: 30 }, (_, i) => 's' + i));
        \\console.log(Array.from({ length: 120 }, (_, i) => i));
        \\console.log(Array.from({ length: 101 }, (_, i) => i));
        \\console.log([1, 'two', 3, 'four', 5, 'six', 7, 'eight']);
        \\console.log([1, 22, 333, 4444, 55555, 666666, 7777777, 88888888, 999999999, 1]);
        \\console.log([1.5, -2, 300, 4e21, 0.1, 6, 7]);
        \\console.log([[1, 2, [3, 4]], { a: [5, 6] }]);
        \\console.log([{ a: 1, b: 2 }, { a: 3, b: 4 }]);
        \\console.log([['a', 1], ['b', 2], ['c', 3], ['d', 4], ['e', 5], ['f', 6], ['g', 7]]);
        \\console.log({ arr: Array.from({ length: 10 }, (_, i) => ({ id: i })) });
        \\console.log({ nested: [[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]] });
        \\console.log(['x'.repeat(30), 'y'.repeat(30), 'z'.repeat(30)]);
        \\console.log(Array.from({ length: 7 }, () => 'x'.repeat(16)));
        \\console.log(Array.from({ length: 8 }, (_, i) => 10n ** BigInt(i)));
        \\console.log([undefined, null, true, false, NaN, -0, 1n]);
        \\const ap = [1, 2]; ap.extra = 'x'; console.log(ap);
        \\const ap7 = [1, 2, 3, 4, 5, 6, 7]; ap7.k = 1; console.log(ap7);
        \\console.log([1, , 3]);
        \\console.log([, , 1, , , 2, , ]);
        \\console.log(new Array(5));
        \\console.log([1, 2, 3, 4, , 6, 7, 8, , , 11]);
    ,
        \\[ 1, 2, 3 ]
        \\[ 1, 2, 3, 4, 5, 6 ]
        \\[
        \\  1, 2, 3, 4,
        \\  5, 6, 7
        \\]
        \\[
        \\   0,  3,  6,  9, 12, 15, 18, 21,
        \\  24, 27, 30, 33, 36, 39, 42, 45,
        \\  48, 51, 54, 57, 60, 63, 66, 69,
        \\  72, 75
        \\]
        \\[
        \\  's0',  's1',  's2',  's3',  's4',
        \\  's5',  's6',  's7',  's8',  's9',
        \\  's10', 's11', 's12', 's13', 's14',
        \\  's15', 's16', 's17', 's18', 's19',
        \\  's20', 's21', 's22', 's23', 's24',
        \\  's25', 's26', 's27', 's28', 's29'
        \\]
        \\[
        \\   0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11,
        \\  12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
        \\  24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
        \\  36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
        \\  48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59,
        \\  60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71,
        \\  72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83,
        \\  84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95,
        \\  96, 97, 98, 99,
        \\  ... 20 more items
        \\]
        \\[
        \\   0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11,
        \\  12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
        \\  24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,
        \\  36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,
        \\  48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59,
        \\  60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71,
        \\  72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83,
        \\  84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95,
        \\  96, 97, 98, 99,
        \\  ... 1 more item
        \\]
        \\[ 1, 'two', 3, 'four', 5, 'six', 7, 'eight' ]
        \\[
        \\          1,       22,
        \\        333,     4444,
        \\      55555,   666666,
        \\    7777777, 88888888,
        \\  999999999,        1
        \\]
        \\[
        \\    1.5,  -2, 300,
        \\  4e+21, 0.1,   6,
        \\      7
        \\]
        \\[ [ 1, 2, [ 3, 4 ] ], { a: [ 5, 6 ] } ]
        \\[ { a: 1, b: 2 }, { a: 3, b: 4 } ]
        \\[
        \\  [ 'a', 1 ],
        \\  [ 'b', 2 ],
        \\  [ 'c', 3 ],
        \\  [ 'd', 4 ],
        \\  [ 'e', 5 ],
        \\  [ 'f', 6 ],
        \\  [ 'g', 7 ]
        \\]
        \\{
        \\  arr: [
        \\    { id: 0 }, { id: 1 },
        \\    { id: 2 }, { id: 3 },
        \\    { id: 4 }, { id: 5 },
        \\    { id: 6 }, { id: 7 },
        \\    { id: 8 }, { id: 9 }
        \\  ]
        \\}
        \\{
        \\  nested: [
        \\    [
        \\      1, 2, 3, 4,  5,
        \\      6, 7, 8, 9, 10
        \\    ]
        \\  ]
        \\}
        \\[
        \\  'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
        \\  'yyyyyyyyyyyyyyyyyyyyyyyyyyyyyy',
        \\  'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
        \\]
        \\[
        \\  'xxxxxxxxxxxxxxxx',
        \\  'xxxxxxxxxxxxxxxx',
        \\  'xxxxxxxxxxxxxxxx',
        \\  'xxxxxxxxxxxxxxxx',
        \\  'xxxxxxxxxxxxxxxx',
        \\  'xxxxxxxxxxxxxxxx',
        \\  'xxxxxxxxxxxxxxxx'
        \\]
        \\[
        \\        1n,       10n,
        \\      100n,     1000n,
        \\    10000n,   100000n,
        \\  1000000n, 10000000n
        \\]
        \\[ undefined, null, true, false, NaN, -0, 1n ]
        \\[ 1, 2, extra: 'x' ]
        \\[
        \\  1, 2, 3, 4,
        \\  5, 6, 7, k: 1
        \\]
        \\[ 1, <1 empty item>, 3 ]
        \\[ <2 empty items>, 1, <2 empty items>, 2, <1 empty item> ]
        \\[ <5 empty items> ]
        \\[ 1, 2, 3, 4, <1 empty item>, 6, 7, 8, <2 empty items>, 11 ]
        \\
    );
}

test "inspect: objects, class instances and nesting break lines like node (compact 3, breakLength 80)" {
    try expectConsole(
        \\console.log({ a: [1, { b: 2 }] });
        \\console.log({ a: 1, b: 'two', c: [1, 2, 3], d: { e: { f: 1 } } });
        \\class Point { constructor(x, y) { this.x = x; this.y = y; } }
        \\console.log(new Point(1, 2));
        \\console.log([new Point(1, 2), new Point(3, 4)]);
        \\console.log({ origin: new Point(0, 0), pts: [new Point(1, 1)] });
        \\class Empty {}
        \\console.log(new Empty());
        \\console.log({ e: new Empty() });
        \\console.log({ long1: 'aaaaaaaaaaaaaaaaaaaa', long2: 'bbbbbbbbbbbbbbbbbbbb', long3: 'cccccccccccccccccccc', long4: 'dd' });
        \\console.log({ a: { b: { c: {} } } });
        \\console.dir({ a: { b: { c: { d: 1 } } } }, { depth: 5 });
        \\console.dir([[[[1]]]], { depth: 5 });
        \\console.dir({ a: { b: { c: { d: { e: 1 } } } }, x: 1 }, { depth: 10 });
        \\console.dir({ x: 1, a: { b: { c: { d: { e: 1 } } } } }, { depth: 10 });
        \\const cyc = { name: 'c', list: [1, 2] }; cyc.self = cyc; console.log(cyc);
        \\const arr = [1, 2]; arr.push(arr); console.log(arr);
        \\console.log(Object.create(null));
        \\const np = Object.create(null); np.a = 1; console.log(np);
        \\const big = {}; for (let i = 0; i < 30; i++) big['k' + i] = i; console.log(big);
    ,
        \\{ a: [ 1, { b: 2 } ] }
        \\{ a: 1, b: 'two', c: [ 1, 2, 3 ], d: { e: { f: 1 } } }
        \\Point { x: 1, y: 2 }
        \\[ Point { x: 1, y: 2 }, Point { x: 3, y: 4 } ]
        \\{ origin: Point { x: 0, y: 0 }, pts: [ Point { x: 1, y: 1 } ] }
        \\Empty {}
        \\{ e: Empty {} }
        \\{
        \\  long1: 'aaaaaaaaaaaaaaaaaaaa',
        \\  long2: 'bbbbbbbbbbbbbbbbbbbb',
        \\  long3: 'cccccccccccccccccccc',
        \\  long4: 'dd'
        \\}
        \\{ a: { b: { c: {} } } }
        \\{
        \\  a: { b: { c: { d: 1 } } }
        \\}
        \\[
        \\  [ [ [ 1 ] ] ]
        \\]
        \\{
        \\  a: {
        \\    b: { c: { d: { e: 1 } } }
        \\  },
        \\  x: 1
        \\}
        \\{
        \\  x: 1,
        \\  a: {
        \\    b: { c: { d: { e: 1 } } }
        \\  }
        \\}
        \\<ref *1> { name: 'c', list: [ 1, 2 ], self: [Circular *1] }
        \\<ref *1> [ 1, 2, [Circular *1] ]
        \\[Object: null prototype] {}
        \\[Object: null prototype] { a: 1 }
        \\{
        \\  k0: 0,
        \\  k1: 1,
        \\  k2: 2,
        \\  k3: 3,
        \\  k4: 4,
        \\  k5: 5,
        \\  k6: 6,
        \\  k7: 7,
        \\  k8: 8,
        \\  k9: 9,
        \\  k10: 10,
        \\  k11: 11,
        \\  k12: 12,
        \\  k13: 13,
        \\  k14: 14,
        \\  k15: 15,
        \\  k16: 16,
        \\  k17: 17,
        \\  k18: 18,
        \\  k19: 19,
        \\  k20: 20,
        \\  k21: 21,
        \\  k22: 22,
        \\  k23: 23,
        \\  k24: 24,
        \\  k25: 25,
        \\  k26: 26,
        \\  k27: 27,
        \\  k28: 28,
        \\  k29: 29
        \\}
        \\
    );
}

test "inspect: Map, Set, Promise, typed arrays and %o's [length] lay out like node" {
    try expectConsole(
        \\console.log(new Map([['a', { x: 1 }], ['b', [1, 2]]]));
        \\console.log(new Map([[{ k: 1 }, new Set([1, 2])]]));
        \\console.log(new Map(Array.from({ length: 8 }, (_, i) => [i, 'v' + i])));
        \\console.log(new Set([[1, 2], { a: 1 }, 'str']));
        \\console.log(new Set(Array.from({ length: 10 }, (_, i) => i)));
        \\console.log({ m: new Map([[1, 2]]), s: new Set(), e: [], o: {} });
        \\console.log(new Uint8Array(10));
        \\console.log(new Float64Array([1.5, 2.5, 3.5]));
        \\console.log('%o', [1, 2, [3]]);
        \\console.log('%o', { a: [1] });
        \\console.log('%o', [1, 2, 3, 4, 5, 6, 7]);
        \\console.log('%O', [1, [2]]);
        \\console.log({ p: Promise.resolve({ a: 1 }) });
    ,
        \\Map(2) { 'a' => { x: 1 }, 'b' => [ 1, 2 ] }
        \\Map(1) { { k: 1 } => Set(2) { 1, 2 } }
        \\Map(8) {
        \\  0 => 'v0',
        \\  1 => 'v1',
        \\  2 => 'v2',
        \\  3 => 'v3',
        \\  4 => 'v4',
        \\  5 => 'v5',
        \\  6 => 'v6',
        \\  7 => 'v7'
        \\}
        \\Set(3) { [ 1, 2 ], { a: 1 }, 'str' }
        \\Set(10) { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }
        \\{ m: Map(1) { 1 => 2 }, s: Set(0) {}, e: [], o: {} }
        \\Uint8Array(10) [
        \\  0, 0, 0, 0, 0,
        \\  0, 0, 0, 0, 0
        \\]
        \\Float64Array(3) [ 1.5, 2.5, 3.5 ]
        \\[ 1, 2, [ 3, [length]: 1 ], [length]: 3 ]
        \\{ a: [ 1, [length]: 1 ] }
        \\[ 1, 2, 3, 4, 5, 6, 7, [length]: 7 ]
        \\[ 1, [ 2 ] ]
        \\{ p: Promise { { a: 1 } } }
        \\
    );
}
