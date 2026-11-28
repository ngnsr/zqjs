//! The pending uncaught exception as text: `Uncaught <Name>: <message>`, then the stack
//! frames. One copy for the CLI (run.zig, main.zig), the playground and the embedding API's
//! `Failure` (api.zig). Never allocates and never invokes getters (EMBEDDING.md E8/E10).

const std = @import("std");
const Writer = std.Io.Writer;
const ast = @import("frontend/ast.zig");
const bytecode = @import("bytecode/bytecode.zig");
const heap = @import("runtime/heap.zig");
const Value = @import("runtime/value.zig").Value;
const Runtime = @import("runtime/runtime.zig").Runtime;
const ops = @import("runtime/ops.zig");

/// `Uncaught <Name>: <message>` and the frames, one per line. `brief` (the harness mode):
/// `Uncaught <Name>` only, which is what tests/harness/golden.js prints for node.
pub fn write(rt: *Runtime, w: *Writer, brief: bool) Writer.Error!void {
    try w.writeAll("Uncaught ");
    var sink: WriterSink = .{ .w = w };
    describe(rt, &sink, brief);
    if (sink.failed) return error.WriteFailed;
    try w.writeByte('\n');
    if (brief) return;
    if (frames(rt)) |units| {
        try ops.writeUtf16(w, units);
        try w.writeByte('\n');
    }
}

/// `<Name>: <message>` of the pending exception (only `<Name>` when `brief`), or a thrown
/// non-error value as a string. `sink` has `utf8([]const u8)` and `utf16([]const u16)`.
pub fn describe(rt: *Runtime, sink: anytype, brief: bool) void {
    if (rt.thrown_value) |v| {
        if (errorInfo(v)) |info| {
            switch (info.name) {
                .utf16 => |u| sink.utf16(u),
                .utf8 => |s| sink.utf8(s),
            }
            if (brief) return;
            if (info.message) |m| {
                if (m.len > 0) {
                    sink.utf8(": ");
                    sink.utf16(m);
                }
            }
        } else if (!brief) {
            var buf: ops.NumberBuf = undefined;
            if (ops.toPiece(rt, v, &buf)) |piece| switch (piece) {
                .ascii => |a| sink.utf8(a),
                .utf16 => |u| sink.utf16(u),
            } else |_| sink.utf8("[value]");
        }
    } else if (rt.exception) |ex| {
        sink.utf8(@tagName(ex.name));
        if (brief) return;
        sink.utf8(": ");
        sink.utf16(ex.message.units);
    } else sink.utf8("Error");
}

/// The pending exception's stack frames: the lines after the first of its `stack` string
/// (own data property, else the engine-recorded one), without a trailing newline. Null for
/// a thrown non-Error value or an error without frames.
pub fn frames(rt: *const Runtime) ?[]const u16 {
    const units: []const u16 = if (rt.thrown_value) |v| units: {
        if (!v.isObject() or v.asObject().ordinary_tag != .@"error") return null;
        const obj = v.asObject();
        if (lookupDataProp(obj, "stack")) |sv| break :units if (sv.isString()) sv.asString().units else return null;
        break :units (rt.heap.error_stacks.get(obj) orelse return null).units;
    } else ((rt.exception orelse return null).stack orelse return null).units;
    const nl = std.mem.indexOfScalar(u16, units, '\n') orelse return null;
    if (nl + 1 >= units.len) return null;
    return units[nl + 1 ..];
}

const WriterSink = struct {
    w: *Writer,
    failed: bool = false,

    fn utf8(s: *WriterSink, bytes: []const u8) void {
        if (!s.failed) s.w.writeAll(bytes) catch {
            s.failed = true;
        };
    }

    fn utf16(s: *WriterSink, units: []const u16) void {
        if (!s.failed) ops.writeUtf16(s.w, units) catch {
            s.failed = true;
        };
    }
};

const Name = union(enum) {
    utf16: []const u16,
    utf8: []const u8,
};

const ErrorInfo = struct {
    name: Name,
    message: ?[]const u16,
};

fn asciiEqlUtf16(ascii: []const u8, units: []const u16) bool {
    if (ascii.len != units.len) return false;
    for (ascii, units) |a, u| {
        if (u != a) return false;
    }
    return true;
}

/// Allocation-free, getter-free data-property lookup along the prototype chain.
fn lookupDataProp(obj: *const heap.Object, key_ascii: []const u8) ?Value {
    var cur: ?*const heap.Object = obj;
    var depth: usize = 0;
    while (cur) |o| : ({
        cur = o.proto;
        depth += 1;
    }) {
        if (depth >= 64 or o.kind == .proxy) return null;
        var it = o.props.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (!k.isSymbol() and asciiEqlUtf16(key_ascii, k.asAtom().units)) {
                if (entry.value_ptr.is_accessor) return null;
                return entry.value_ptr.value;
            }
        }
    }
    return null;
}

fn closureName(cl: *const heap.Closure) ?Name {
    if (cl.meta) |m| {
        var it = m.props.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (!k.isSymbol() and asciiEqlUtf16("name", k.asAtom().units)) {
                if (entry.value_ptr.is_accessor) return null;
                const val = entry.value_ptr.value;
                if (val.isString() and val.asString().units.len > 0) return .{ .utf16 = val.asString().units };
                return null;
            }
        }
        if (m.name_deleted) return null;
    }
    return switch (cl.impl) {
        .vm => |vm| blk: {
            const proto: *const bytecode.Proto = @ptrCast(@alignCast(vm.proto));
            const n = if (proto.name.len > 0) proto.name else proto.inferred_name;
            break :blk if (n.len > 0) .{ .utf8 = n } else null;
        },
        .tree => |tr| blk: {
            const func: *const ast.Function = @ptrCast(@alignCast(tr.func));
            const n = if (func.name) |d| d.name else func.inferred_name;
            break :blk if (n.len > 0) .{ .utf8 = n } else null;
        },
        .bound => |b| if (b.name.units.len > 0) .{ .utf16 = b.name.units } else null,
        else => null,
    };
}

fn isObjectName(n: Name) bool {
    return switch (n) {
        .utf8 => |s| std.mem.eql(u8, s, "Object"),
        .utf16 => |u| asciiEqlUtf16("Object", u),
    };
}

/// Extracts error-like `{ name, message }` (or custom constructor name + string `message`,
/// e.g. Test262's `Test262Error`) from a thrown object without allocating or invoking getters.
fn errorInfo(v: Value) ?ErrorInfo {
    if (!v.isObject()) return null;
    const obj = v.asObject();
    const msg_units: ?[]const u16 = if (lookupDataProp(obj, "message")) |mv|
        (if (mv.isString()) mv.asString().units else null)
    else
        null;
    if (lookupDataProp(obj, "name")) |nv| {
        if (nv.isString() and nv.asString().units.len > 0) {
            return .{ .name = .{ .utf16 = nv.asString().units }, .message = msg_units };
        }
    }
    if (msg_units != null) {
        if (lookupDataProp(obj, "constructor")) |cv| {
            if (cv.isClosure()) {
                if (closureName(cv.asClosure())) |cn| {
                    if (!isObjectName(cn)) return .{ .name = cn, .message = msg_units };
                }
            }
        }
    }
    return null;
}
