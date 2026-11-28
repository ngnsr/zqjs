//! WHATWG Console built-in (`console.*`) and `util.format`-style formatting.

const std = @import("std");
const Value = @import("../value.zig").Value;
const Native = @import("../value.zig").Native;
const heap_mod = @import("../heap.zig");
const Object = heap_mod.Object;
const rt_mod = @import("../runtime.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const ops = @import("../ops.zig");
const inspect = @import("../inspect.zig");
const object = @import("../object.zig");
const json = @import("../json.zig");
const builtins = @import("../builtins.zig");
const common = @import("common.zig");
const number_math = @import("number_math.zig");

pub const console_log: Native = .{ .name = "log", .call = consoleLog };
pub const console_info: Native = .{ .name = "info", .call = consoleLog };
pub const console_debug: Native = .{ .name = "debug", .call = consoleLog };
pub const console_warn: Native = .{ .name = "warn", .call = consoleLog };
pub const console_error: Native = .{ .name = "error", .call = consoleLog };
pub const console_assert: Native = .{ .name = "assert", .call = consoleAssert };
pub const console_count: Native = .{ .name = "count", .call = consoleCount };
pub const console_count_reset: Native = .{ .name = "countReset", .call = consoleCountReset };
pub const console_time: Native = .{ .name = "time", .call = consoleTime };
pub const console_time_end: Native = .{ .name = "timeEnd", .call = consoleTimeEnd };
pub const console_time_log: Native = .{ .name = "timeLog", .call = consoleTimeLog };
pub const console_group: Native = .{ .name = "group", .call = consoleGroup };
pub const console_group_collapsed: Native = .{ .name = "groupCollapsed", .call = consoleGroup };
pub const console_group_end: Native = .{ .name = "groupEnd", .call = consoleGroupEnd };
pub const console_dir: Native = .{ .name = "dir", .call = consoleDir };
pub const console_table: Native = .{ .name = "table", .call = consoleTable };
pub const console_trace: Native = .{ .name = "trace", .call = consoleTrace };

pub fn register(rt: *Runtime, r: *const builtins.Realm) Error!void {
    // WHATWG Console namespace: methods are enumerable/writable/configurable own properties,
    // in node's key order.
    for ([_]struct { []const u8, *const Native }{
        .{ "log", &console_log },
        .{ "info", &console_info },
        .{ "debug", &console_debug },
        .{ "warn", &console_warn },
        .{ "error", &console_error },
        .{ "dir", &console_dir },
        .{ "time", &console_time },
        .{ "timeEnd", &console_time_end },
        .{ "timeLog", &console_time_log },
        .{ "trace", &console_trace },
        .{ "assert", &console_assert },
        .{ "count", &console_count },
        .{ "countReset", &console_count_reset },
        .{ "group", &console_group },
        .{ "groupEnd", &console_group_end },
        .{ "table", &console_table },
        .{ "groupCollapsed", &console_group_collapsed },
    }) |entry| {
        const k = try rt.heap.internAscii(entry[0]);
        try rt.heap.defineProperty(r.console, k, .{ .value = Value.fromNative(entry[1]) });
    }
    try common.defineToStringTag(rt, r.console, r.sym_to_string_tag, "console");
}

fn writeIndented(rt: *Runtime, depth: u32, bytes: []const u8) Error!void {
    if (depth == 0) {
        try rt.out.writeAll(bytes);
        return;
    }
    var i: usize = 0;
    while (i < bytes.len) {
        for (0..depth) |_| try rt.out.writeAll("  ");
        if (std.mem.indexOfScalarPos(u8, bytes, i, '\n')) |nl| {
            try rt.out.writeAll(bytes[i .. nl + 1]);
            i = nl + 1;
        } else {
            try rt.out.writeAll(bytes[i..]);
            break;
        }
    }
}

fn flushLine(rt: *Runtime, buf: *std.Io.Writer.Allocating) Error!void {
    const r = try builtins.realm(rt);
    try buf.writer.writeByte('\n');
    try writeIndented(rt, r.console_group_depth, buf.written());
}

fn formatArgPlain(rt: *Runtime, w: *std.Io.Writer, v: Value) Error!void {
    if (v.isString()) {
        try ops.writeUtf16(w, v.asString().units);
    } else {
        try inspect.inspect(rt, v, w, .{ .color = false });
    }
}

fn formatSpecifier(rt: *Runtime, w: *std.Io.Writer, spec: u16, v: Value) Error!void {
    var nbuf: ops.NumberBuf = undefined;
    switch (spec) {
        's' => {
            if (v.isSymbol()) {
                try w.writeAll("Symbol(");
                if (v.asSymbol().description) |d| try ops.writeUtf16(w, d.units);
                try w.writeByte(')');
            } else if (v.isBigInt()) {
                switch (try ops.toPiece(rt, v, &nbuf)) {
                    .ascii => |s| try w.writeAll(s),
                    .utf16 => |u| try ops.writeUtf16(w, u),
                }
                try w.writeByte('n');
            } else if (v.isNumber()) {
                try writeNumber(rt, w, v.asNumber());
            } else if (v.isObject() and !try hasUserToString(rt, v)) {
                // node inspects an object without its own toString, one level deep.
                try inspect.inspect(rt, v, w, .{ .depth = 1, .color = false });
            } else {
                try ops.writeUtf16(w, (try common.toStringObj(rt, v)).units);
            }
        },
        'd' => {
            if (v.isSymbol()) {
                try w.writeAll("NaN");
            } else if (v.isBigInt()) {
                switch (try ops.toPiece(rt, v, &nbuf)) {
                    .ascii => |s| try w.writeAll(s),
                    .utf16 => |u| try ops.writeUtf16(w, u),
                }
                try w.writeByte('n');
            } else {
                try writeNumber(rt, w, try ops.toNumber(rt, v));
            }
        },
        'i' => {
            if (v.isSymbol()) {
                try w.writeAll("NaN");
            } else if (v.isBigInt()) {
                switch (try ops.toPiece(rt, v, &nbuf)) {
                    .ascii => |s| try w.writeAll(s),
                    .utf16 => |u| try ops.writeUtf16(w, u),
                }
                try w.writeByte('n');
            } else {
                const parsed = try number_math.parseIntImpl(rt, .undefined, &.{v});
                switch (try ops.toPiece(rt, parsed, &nbuf)) {
                    .ascii => |s| try w.writeAll(s),
                    .utf16 => |u| try ops.writeUtf16(w, u),
                }
            }
        },
        'f' => {
            if (v.isSymbol()) {
                try w.writeAll("NaN");
            } else if (v.isBigInt()) {
                switch (try ops.toPiece(rt, v, &nbuf)) {
                    .ascii => |s| try w.writeAll(s),
                    .utf16 => |u| try ops.writeUtf16(w, u),
                }
            } else {
                const parsed = try number_math.parseFloatImpl(rt, .undefined, &.{v});
                switch (try ops.toPiece(rt, parsed, &nbuf)) {
                    .ascii => |s| try w.writeAll(s),
                    .utf16 => |u| try ops.writeUtf16(w, u),
                }
            }
        },
        // shortcut: %o prints like %O; node's also shows hidden properties ([length]). Add a
        // showHidden option to inspect if a script depends on it.
        'o', 'O' => try inspect.inspect(rt, v, w, .{ .color = false }),
        'j' => {
            const res = json.stringify(rt, v) catch |e| switch (e) {
                error.Thrown => {
                    rt.exception = null;
                    try w.writeAll("[Circular]");
                    return;
                },
                else => return e,
            };
            if (res) |sv| {
                try ops.writeUtf16(w, sv.asString().units);
            } else {
                try w.writeAll("undefined");
            }
        },
        'c' => {},
        else => unreachable,
    }
}

/// A number as node's format prints it: like String(n), except that -0 stays "-0".
fn writeNumber(rt: *Runtime, w: *std.Io.Writer, n: f64) Error!void {
    if (n == 0 and std.math.signbit(n)) return w.writeAll("-0");
    var nbuf: ops.NumberBuf = undefined;
    switch (try ops.toPiece(rt, Value.fromNumber(n), &nbuf)) {
        .ascii => |s| try w.writeAll(s),
        .utf16 => |u| try ops.writeUtf16(w, u),
    }
}

/// Whether `%s` should call the object's own `toString` (a user function found on its
/// chain) rather than inspect it, as node's `hasBuiltInToString` decides.
/// shortcut: ignores Symbol.toPrimitive and proxies; extend if a script needs them.
fn hasUserToString(rt: *Runtime, v: Value) Error!bool {
    const ts = try object.get(rt, v, try object.named(rt, "toString"));
    return ts.isClosure() and (ts.asClosure().impl == .vm or ts.asClosure().impl == .tree);
}

fn formatArgs(rt: *Runtime, w: *std.Io.Writer, args: []const Value) Error!void {
    if (args.len == 0) return;
    if (args.len == 1) {
        try formatArgPlain(rt, w, args[0]);
        return;
    }
    var arg_idx: usize = 0;
    if (args[0].isString()) {
        const units = args[0].asString().units;
        arg_idx = 1;
        var i: usize = 0;
        var seg_start: usize = 0;
        while (i < units.len) {
            if (units[i] == '%' and i + 1 < units.len) {
                const spec = units[i + 1];
                const is_known = switch (spec) {
                    's', 'd', 'i', 'f', 'o', 'O', 'j', 'c' => arg_idx < args.len,
                    '%' => true,
                    else => false,
                };
                if (is_known) {
                    if (i > seg_start) try ops.writeUtf16(w, units[seg_start..i]);
                    if (spec == '%') {
                        try w.writeByte('%');
                    } else {
                        try formatSpecifier(rt, w, spec, args[arg_idx]);
                        arg_idx += 1;
                    }
                    i += 2;
                    seg_start = i;
                    continue;
                }
            }
            i += 1;
        }
        if (seg_start < units.len) try ops.writeUtf16(w, units[seg_start..]);
    }
    while (arg_idx < args.len) : (arg_idx += 1) {
        if (arg_idx > 0) try w.writeByte(' ');
        try formatArgPlain(rt, w, args[arg_idx]);
    }
}

fn consoleLog(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    var buf: std.Io.Writer.Allocating = .init(rt.gpa);
    defer buf.deinit();
    try formatArgs(rt, &buf.writer, args);
    try flushLine(rt, &buf);
    return .undefined;
}

fn consoleAssert(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    if (args.len > 0 and ops.toBoolean(args[0])) return .undefined;
    var buf: std.Io.Writer.Allocating = .init(rt.gpa);
    defer buf.deinit();
    if (args.len <= 1) {
        try buf.writer.writeAll("Assertion failed");
    } else {
        try buf.writer.writeAll("Assertion failed: ");
        try formatArgs(rt, &buf.writer, args[1..]);
    }
    try flushLine(rt, &buf);
    return .undefined;
}

fn consoleLabel(rt: *Runtime, args: []const Value) Error!*const heap_mod.String {
    const raw = common.arg(args, 0);
    if (raw.isUndefined()) return rt.heap.internAscii("default");
    return common.toStringObj(rt, raw);
}

fn consoleCount(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const label = try consoleLabel(rt, args);
    const key = Value.fromString(label);
    var root_buf = [_]Value{key};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next: f64 = if (heap_mod.Heap.mapGet(r.console_counts, key)) |cur| cur.asNumber() + 1.0 else 1.0;
    try rt.heap.mapSet(r.console_counts, key, Value.fromNumber(next));

    var buf: std.Io.Writer.Allocating = .init(rt.gpa);
    defer buf.deinit();
    try ops.writeUtf16(&buf.writer, label.units);
    try buf.writer.print(": {d}", .{@as(u64, @intFromFloat(next))});
    try flushLine(rt, &buf);
    return .undefined;
}

fn consoleCountReset(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const label = try consoleLabel(rt, args);
    _ = heap_mod.Heap.mapDelete(r.console_counts, Value.fromString(label));
    return .undefined;
}

fn consoleTime(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const label = try consoleLabel(rt, args);
    const key = Value.fromString(label);
    var root_buf = [_]Value{key};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (heap_mod.Heap.mapGet(r.console_timers, key) == null) {
        try rt.heap.mapSet(r.console_timers, key, Value.fromNumber(rt.nowMs()));
    }
    return .undefined;
}

fn consoleTimeEnd(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const label = try consoleLabel(rt, args);
    const key = Value.fromString(label);
    const start_val = heap_mod.Heap.mapGet(r.console_timers, key) orelse return .undefined;
    const elapsed = rt.nowMs() - start_val.asNumber();
    _ = heap_mod.Heap.mapDelete(r.console_timers, key);

    var buf: std.Io.Writer.Allocating = .init(rt.gpa);
    defer buf.deinit();
    try ops.writeUtf16(&buf.writer, label.units);
    try buf.writer.print(": {d:.3}ms", .{elapsed});
    try flushLine(rt, &buf);
    return .undefined;
}

fn consoleTimeLog(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try builtins.realm(rt);
    const label = try consoleLabel(rt, args);
    const key = Value.fromString(label);
    const start_val = heap_mod.Heap.mapGet(r.console_timers, key) orelse return .undefined;
    const elapsed = rt.nowMs() - start_val.asNumber();

    var buf: std.Io.Writer.Allocating = .init(rt.gpa);
    defer buf.deinit();
    try ops.writeUtf16(&buf.writer, label.units);
    try buf.writer.print(": {d:.3}ms", .{elapsed});
    if (args.len > 1) {
        try buf.writer.writeByte(' ');
        try formatArgs(rt, &buf.writer, args[1..]);
    }
    try flushLine(rt, &buf);
    return .undefined;
}

fn consoleGroup(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    _ = try builtins.realm(rt);
    if (args.len > 0) {
        var buf: std.Io.Writer.Allocating = .init(rt.gpa);
        defer buf.deinit();
        try formatArgs(rt, &buf.writer, args);
        try flushLine(rt, &buf);
    }
    (&rt.realm.?).console_group_depth +|= 1;
    return .undefined;
}

fn consoleGroupEnd(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    _ = try builtins.realm(rt);
    const r = &rt.realm.?;
    if (r.console_group_depth > 0) r.console_group_depth -= 1;
    return .undefined;
}

fn consoleDir(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    var depth: u32 = 2;
    if (args.len >= 2 and args[1].isObjectLike()) {
        const d_val = try object.get(rt, args[1], try object.named(rt, "depth"));
        if (d_val.isNull()) {
            depth = std.math.maxInt(u32);
        } else if (d_val.isNumber()) {
            const d = d_val.asNumber();
            if (std.math.isPositiveInf(d)) {
                depth = std.math.maxInt(u32);
            } else if (!std.math.isNan(d) and d >= 0) {
                depth = @intFromFloat(@min(d, @as(f64, @floatFromInt(std.math.maxInt(u32)))));
            }
        }
    }
    var buf: std.Io.Writer.Allocating = .init(rt.gpa);
    defer buf.deinit();
    try inspect.inspect(rt, common.arg(args, 0), &buf.writer, .{ .depth = depth +| 1, .color = false });
    try flushLine(rt, &buf);
    return .undefined;
}

fn consoleTrace(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    var buf: std.Io.Writer.Allocating = .init(rt.gpa);
    defer buf.deinit();
    if (args.len == 0) {
        try buf.writer.writeAll("Trace");
    } else {
        try buf.writer.writeAll("Trace: ");
        try formatArgs(rt, &buf.writer, args);
    }
    var frames = try rt.captureStack(rt.gpa, 64);
    defer frames.deinit(rt.gpa);
    for (frames.items) |f| {
        try buf.writer.writeAll("\n    at ");
        const src = if (f.source_name.len > 0) f.source_name else "<anonymous>";
        if (f.func_name.len > 0) {
            try buf.writer.writeAll(f.func_name);
            if (f.line > 0) {
                try buf.writer.print(" ({s}:{d}:{d})", .{ src, f.line, f.col });
            } else {
                try buf.writer.writeAll(" (<anonymous>)");
            }
        } else if (f.line > 0) {
            try buf.writer.print("{s}:{d}:{d}", .{ src, f.line, f.col });
        } else {
            try buf.writer.writeAll("<anonymous>");
        }
    }
    try flushLine(rt, &buf);
    return .undefined;
}

fn utf8DisplayWidth(s: []const u8) usize {
    var w: usize = 0;
    for (s) |b| {
        if ((b & 0xC0) != 0x80) w += 1;
    }
    return w;
}

fn writeTableCell(rt: *Runtime, v: Value, out: *[]u8) Error!void {
    var buf: std.Io.Writer.Allocating = .init(rt.gpa);
    errdefer buf.deinit();
    try inspect.inspect(rt, v, &buf.writer, .{ .depth = 2, .color = false });
    const slice = try buf.toOwnedSlice();
    for (slice) |*b| {
        if (b.* == '\n') b.* = ' ';
    }
    out.* = slice;
}

fn consoleTable(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const data = common.arg(args, 0);
    if (!data.isObject()) {
        return consoleLog(rt, .undefined, args);
    }
    const obj = data.asObject();

    var root_buf = [_]Value{ data, common.arg(args, 1), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const row_keys = try object.ownKeys(rt, obj);
    defer rt.gpa.free(row_keys);

    var col_names: std.ArrayList([]u8) = .empty;
    defer {
        for (col_names.items) |c| rt.gpa.free(c);
        col_names.deinit(rt.gpa);
    }

    var filter_cols = false;
    const cols_arg = common.arg(args, 1);
    if (cols_arg.isObject() and cols_arg.asObject().kind == .array) {
        filter_cols = true;
        for (cols_arg.asObject().kind.array.items) |elem| {
            if (elem.isHole()) continue;
            const s = try common.toStringObj(rt, elem);
            var w: std.Io.Writer.Allocating = .init(rt.gpa);
            errdefer w.deinit();
            try ops.writeUtf16(&w.writer, s.units);
            const name_bytes = try w.toOwnedSlice();
            var dup = false;
            for (col_names.items) |existing| {
                if (std.mem.eql(u8, existing, name_bytes)) {
                    dup = true;
                    break;
                }
            }
            if (dup) {
                rt.gpa.free(name_bytes);
            } else {
                try col_names.append(rt.gpa, name_bytes);
            }
        }
    }

    var row_labels: std.ArrayList([]u8) = .empty;
    defer {
        for (row_labels.items) |l| rt.gpa.free(l);
        row_labels.deinit(rt.gpa);
    }
    var row_vals: std.ArrayList(Value) = .empty;
    defer row_vals.deinit(rt.gpa);
    var row_roots: rt_mod.ValueRoots = .{ .values = row_vals.items };
    try row_roots.register(rt);
    defer row_roots.unregister(rt);

    var has_primitive_row = false;
    for (row_keys) |rk| {
        const ks = try common.keyToString(rt, rk);
        var kw: std.Io.Writer.Allocating = .init(rt.gpa);
        errdefer kw.deinit();
        try ops.writeUtf16(&kw.writer, ks.units);
        try row_labels.append(rt.gpa, try kw.toOwnedSlice());

        const rv = try object.get(rt, data, rk);
        try row_vals.append(rt.gpa, rv);
        row_roots.values = row_vals.items;

        if (!filter_cols) {
            if (rv.isObject()) {
                const sub_keys = try object.ownKeys(rt, rv.asObject());
                defer rt.gpa.free(sub_keys);
                for (sub_keys) |sk| {
                    const sks = try common.keyToString(rt, sk);
                    var skw: std.Io.Writer.Allocating = .init(rt.gpa);
                    errdefer skw.deinit();
                    try ops.writeUtf16(&skw.writer, sks.units);
                    const cname = try skw.toOwnedSlice();
                    var dup = false;
                    for (col_names.items) |existing| {
                        if (std.mem.eql(u8, existing, cname)) {
                            dup = true;
                            break;
                        }
                    }
                    if (dup) {
                        rt.gpa.free(cname);
                    } else {
                        try col_names.append(rt.gpa, cname);
                    }
                }
            } else {
                has_primitive_row = true;
            }
        }
    }

    if (!filter_cols and has_primitive_row) {
        const val_col = try rt.gpa.dupe(u8, "Values");
        errdefer rt.gpa.free(val_col);
        var dup = false;
        for (col_names.items) |existing| {
            if (std.mem.eql(u8, existing, val_col)) {
                dup = true;
                break;
            }
        }
        if (dup) {
            rt.gpa.free(val_col);
        } else {
            try col_names.append(rt.gpa, val_col);
        }
    }

    const n_cols = 1 + col_names.items.len;
    const widths = try rt.gpa.alloc(usize, n_cols);
    defer rt.gpa.free(widths);
    widths[0] = "(index)".len;
    for (col_names.items, 0..) |cname, ci| {
        widths[1 + ci] = utf8DisplayWidth(cname);
    }

    const cells = try rt.gpa.alloc([]u8, row_vals.items.len * col_names.items.len);
    for (cells) |*c| c.* = &.{};
    defer {
        for (cells) |c| {
            if (c.len > 0) rt.gpa.free(c);
        }
        rt.gpa.free(cells);
    }

    for (row_vals.items, 0..) |rv, ri| {
        const lw = utf8DisplayWidth(row_labels.items[ri]);
        if (lw > widths[0]) widths[0] = lw;
        for (col_names.items, 0..) |cname, ci| {
            var cell_bytes: []u8 = &.{};
            if (!rv.isObject()) {
                if (std.mem.eql(u8, cname, "Values")) {
                    try writeTableCell(rt, rv, &cell_bytes);
                }
            } else {
                const ck = object.namedAtom(try rt.heap.internUtf8(cname));
                if (try object.has(rt, ck, rv)) {
                    const cv = try object.get(rt, rv, ck);
                    root_buf[2] = cv;
                    try writeTableCell(rt, cv, &cell_bytes);
                    root_buf[2] = .undefined;
                }
            }
            cells[ri * col_names.items.len + ci] = cell_bytes;
            const cw = utf8DisplayWidth(cell_bytes);
            if (cw > widths[1 + ci]) widths[1 + ci] = cw;
        }
    }

    var out: std.Io.Writer.Allocating = .init(rt.gpa);
    defer out.deinit();

    // Top border
    try writeTableBorder(&out.writer, widths, "┌", "┬", "┐");
    // Header row
    try out.writer.writeAll("│ (index)");
    for (0..widths[0] - "(index)".len + 1) |_| try out.writer.writeByte(' ');
    for (col_names.items, 0..) |cname, ci| {
        try out.writer.writeAll("│ ");
        try out.writer.writeAll(cname);
        for (0..widths[1 + ci] - utf8DisplayWidth(cname) + 1) |_| try out.writer.writeByte(' ');
    }
    try out.writer.writeAll("│\n");
    // Mid border
    try writeTableBorder(&out.writer, widths, "├", "┼", "┤");
    // Data rows
    for (row_labels.items, 0..) |label, ri| {
        try out.writer.writeAll("│ ");
        try out.writer.writeAll(label);
        for (0..widths[0] - utf8DisplayWidth(label) + 1) |_| try out.writer.writeByte(' ');
        for (0..col_names.items.len) |ci| {
            const cell = cells[ri * col_names.items.len + ci];
            try out.writer.writeAll("│ ");
            try out.writer.writeAll(cell);
            for (0..widths[1 + ci] - utf8DisplayWidth(cell) + 1) |_| try out.writer.writeByte(' ');
        }
        try out.writer.writeAll("│\n");
    }
    // Bottom border
    try writeTableBorder(&out.writer, widths, "└", "┴", "┘");

    const r = try builtins.realm(rt);
    try writeIndented(rt, r.console_group_depth, out.written());
    return .undefined;
}

fn writeTableBorder(w: *std.Io.Writer, widths: []const usize, left: []const u8, mid: []const u8, right: []const u8) !void {
    try w.writeAll(left);
    for (widths, 0..) |width, i| {
        if (i > 0) try w.writeAll(mid);
        for (0..width + 2) |_| try w.writeAll("─");
    }
    try w.writeAll(right);
    try w.writeByte('\n');
}

// ---------------------------------------------------------------- Unit Tests

fn runConsoleTestSource(source: []const u8) !std.Io.Writer.Allocating {
    const run = @import("../../run.zig");
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    const code = try run.runSource(gpa, "console_test.js", source, .{}, .{ .mode = .normal, .engine = .vm }, &out.writer, &err.writer);
    try std.testing.expectEqual(@as(u8, 0), code);
    return out;
}

test "console substitutions, count, group, dir, table, assert" {
    var out = try runConsoleTestSource(
        \\console.log("%s %d %i %f %o %O %j %c %%", "hi", "42.9", "42.9", "42.9", { a: 1 }, { a: 1 }, { a: 1 }, "color:red", "extra");
        \\console.log("%d %i %f", 10n, Symbol("s"), undefined);
        \\const circ = {};
        \\circ.self = circ;
        \\console.log("%j", circ);
        \\console.log("%s %d", "only1");
        \\console.log("%%");
        \\console.log("%%", 1);
        \\console.log(123, "%s");
        \\console.log("%s %d %s %i", -0, -0, [1, 2], "0x10");
        \\console.log([1, , 2], [, ,]);
        \\console.count();
        \\console.count();
        \\console.count("a");
        \\console.countReset("a");
        \\console.count("a");
        \\console.group("g1");
        \\console.log("in g1\nline2");
        \\console.groupCollapsed("g2");
        \\console.log("in g2");
        \\console.assert(false, "bad %s", "val");
        \\console.groupEnd();
        \\console.groupEnd();
        \\console.groupEnd();
        \\console.log("after");
        \\console.dir({ a: { b: { c: { d: 1 } } } });
        \\console.dir({ a: { b: { c: 1 } } }, { depth: 1 });
        \\console.dir({ a: { b: { c: 1 } } }, { depth: null });
        \\console.table([{ a: 1, b: "x" }, { a: 2, c: true }]);
        \\console.table([{ a: 1, b: "x" }, { a: 2, c: true }], ["a", "c"]);
        \\console.table(["a", "b"]);
        \\console.table("not a table");
    );
    defer out.deinit();
    const expected =
        \\hi 42.9 42 42.9 { a: 1 } { a: 1 } {"a":1}  % extra
        \\10n NaN NaN
        \\[Circular]
        \\only1 %d
        \\%%
        \\% 1
        \\123 %s
        \\-0 -0 [ 1, 2 ] 16
        \\[ 1, <1 empty item>, 2 ] [ <2 empty items> ]
        \\default: 1
        \\default: 2
        \\a: 1
        \\a: 1
        \\g1
        \\  in g1
        \\  line2
        \\  g2
        \\    in g2
        \\    Assertion failed: bad val
        \\after
        \\{ a: { b: { c: [Object] } } }
        \\{ a: { b: [Object] } }
        \\{ a: { b: { c: 1 } } }
        \\┌─────────┬───┬─────┬──────┐
        \\│ (index) │ a │ b   │ c    │
        \\├─────────┼───┼─────┼──────┤
        \\│ 0       │ 1 │ 'x' │      │
        \\│ 1       │ 2 │     │ true │
        \\└─────────┴───┴─────┴──────┘
        \\┌─────────┬───┬──────┐
        \\│ (index) │ a │ c    │
        \\├─────────┼───┼──────┤
        \\│ 0       │ 1 │      │
        \\│ 1       │ 2 │ true │
        \\└─────────┴───┴──────┘
        \\┌─────────┬────────┐
        \\│ (index) │ Values │
        \\├─────────┼────────┤
        \\│ 0       │ 'a'    │
        \\│ 1       │ 'b'    │
        \\└─────────┴────────┘
        \\not a table
        \\
    ;
    try std.testing.expectEqualStrings(expected, out.written());
}

test "console.time, timeLog, timeEnd format" {
    var out = try runConsoleTestSource(
        \\console.time("op");
        \\console.timeLog("op", "step %d", 1);
        \\console.timeEnd("op");
        \\console.timeEnd("missing");
    );
    defer out.deinit();
    const text = out.written();
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    const line1 = lines.next().?;
    const line2 = lines.next().?;
    try std.testing.expect(lines.next() == null);
    try std.testing.expect(std.mem.startsWith(u8, line1, "op: "));
    try std.testing.expect(std.mem.endsWith(u8, line1, "ms step 1"));
    try std.testing.expect(std.mem.startsWith(u8, line2, "op: "));
    try std.testing.expect(std.mem.endsWith(u8, line2, "ms"));
}

test "console.trace format and group indentation" {
    var out = try runConsoleTestSource(
        \\function inner() { console.trace("at %s", "inner"); }
        \\console.group("grp");
        \\inner();
        \\console.groupEnd();
    );
    defer out.deinit();
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "grp\n  Trace: at inner\n      at inner (console_test.js:") != null);
}

test "console unsupported property reports Unsupported(builtin)" {
    const run = @import("../../run.zig");
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(gpa);
    defer err.deinit();
    const code = try run.runSource(gpa, "console_unsup.js", "console.profile();", .{}, .{ .mode = .normal, .engine = .vm }, &out.writer, &err.writer);
    try std.testing.expect(code != 0);
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "Unsupported") != null);
}
