//! `structuredClone(value, options?)` (M51, D81).
//!
//! Cycle-safe deep clone with `options.transfer` ArrayBuffer detachment,
//! `DataCloneError` on non-cloneable values, `Limits.max_nesting_depth` /
//! `Limits.max_heap_bytes`, and full GC rooting via `EngineRoots`.

const std = @import("std");
const heap_mod = @import("heap.zig");
const rt_mod = @import("runtime.zig");
const value_mod = @import("value.zig");
const object = @import("object.zig");
const builtins = @import("builtins.zig");

const Heap = heap_mod.Heap;
const Object = heap_mod.Object;
const PropKey = heap_mod.PropKey;
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const Value = value_mod.Value;

const CloneContext = struct {
    rt: *Runtime,
    visited: std.AutoHashMapUnmanaged(*Object, *Object) = .empty,
    transfer_set: std.AutoArrayHashMapUnmanaged(*Object, void) = .empty,
    in_flight: std.ArrayList(Value) = .empty,
    pending_keys: std.ArrayList([]const object.Key) = .empty,
    depth: u16 = 0,

    fn deinit(self: *CloneContext) void {
        self.visited.deinit(self.rt.gpa);
        self.transfer_set.deinit(self.rt.gpa);
        self.in_flight.deinit(self.rt.gpa);
        self.pending_keys.deinit(self.rt.gpa);
    }

    fn mark(ctx: *anyopaque, h: *Heap) void {
        const self: *CloneContext = @ptrCast(@alignCast(ctx));
        var v_it = self.visited.iterator();
        while (v_it.next()) |entry| {
            h.markObj(&entry.key_ptr.*.*.obj);
            h.markObj(&entry.value_ptr.*.*.obj);
        }
        for (self.transfer_set.keys()) |ab| {
            h.markObj(&ab.obj);
        }
        for (self.in_flight.items) |v| {
            h.markValue(v);
        }
        for (self.pending_keys.items) |slice| {
            for (slice) |k| {
                if (k == .atom) h.markObj(&@constCast(k.atom).obj);
            }
        }
    }

    fn pushRoot(self: *CloneContext, v: Value) Error!usize {
        const mark_len = self.in_flight.items.len;
        try self.in_flight.append(self.rt.gpa, v);
        return mark_len;
    }

    fn popRoots(self: *CloneContext, saved_len: usize) void {
        self.in_flight.shrinkRetainingCapacity(saved_len);
    }
};

pub fn throwDataCloneError(rt: *Runtime, msg: []const u8) Error {
    const r = try builtins.realm(rt);
    var root_buf = [_]Value{ .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const err_obj = try rt.heap.newObject(r.error_prototype);
    err_obj.ordinary_tag = .@"error";
    root_buf[0] = Value.fromObject(err_obj);

    const name_str = try rt.heap.internAscii("DataCloneError");
    root_buf[1] = Value.fromString(name_str);
    try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("name"), .{ .value = root_buf[1], .enumerable = false });

    const msg_str = try rt.heap.ascii(msg);
    root_buf[1] = Value.fromString(msg_str);
    try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("message"), .{ .value = root_buf[1], .enumerable = false });

    return rt.throwValue(root_buf[0]);
}

pub fn structuredCloneImpl(rt: *Runtime, args: []const Value) Error!Value {
    const val: Value = if (args.len > 0) args[0] else .undefined;
    const opts: Value = if (args.len > 1) args[1] else .undefined;

    var ctx: CloneContext = .{ .rt = rt };
    defer ctx.deinit();

    try rt.addRoots(.{ .ctx = &ctx, .mark = CloneContext.mark });
    defer rt.removeRoots(&ctx);

    _ = try ctx.pushRoot(val);
    _ = try ctx.pushRoot(opts);

    if (!opts.isUndefined() and !opts.isNull()) {
        if (!opts.isObject()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "structuredClone options must be an object" }});
        }
        const transfer_key = try object.named(rt, "transfer");
        const transfer_val = try object.get(rt, opts, transfer_key);
        if (!transfer_val.isUndefined() and !transfer_val.isNull()) {
            try collectTransferList(&ctx, transfer_val);
        }
    }

    const cloned = try cloneValue(&ctx, val);
    const saved = try ctx.pushRoot(cloned);
    defer ctx.popRoots(saved);

    // Validate all transfer buffers are still live before mutating any of them
    // (a user getter during cloning could have detached one via nested structuredClone).
    for (ctx.transfer_set.keys()) |src_ab| {
        if (src_ab.kind.array_buffer.detached) {
            return throwDataCloneError(rt, "ArrayBuffer in transfer list is already detached");
        }
    }

    // Finalize zero-copy ownership transfer and detach originals.
    for (ctx.transfer_set.keys()) |src_ab| {
        if (ctx.visited.get(src_ab)) |dst_ab| {
            dst_ab.kind.array_buffer.data = src_ab.kind.array_buffer.data;
            rt.heap.detachArrayBuffer(src_ab, false);
        } else {
            rt.heap.detachArrayBuffer(src_ab, true);
        }
    }

    return cloned;
}

fn collectTransferList(ctx: *CloneContext, transfer_val: Value) Error!void {
    const rt = ctx.rt;
    const iter = try builtins.getIterator(rt, transfer_val);
    const saved = try ctx.pushRoot(Value.fromObject(iter));
    defer ctx.popRoots(saved);

    while (try builtins.iteratorNextVal(rt, iter)) |entry| {
        const entry_saved = try ctx.pushRoot(entry);
        defer ctx.popRoots(entry_saved);

        if (!entry.isObject() or entry.asObject().kind != .array_buffer) {
            builtins.iteratorClose(rt, iter, true) catch {};
            return throwDataCloneError(rt, "Value in transfer list is not an ArrayBuffer");
        }
        const ab = entry.asObject();
        if (ab.kind.array_buffer.detached) {
            builtins.iteratorClose(rt, iter, true) catch {};
            return throwDataCloneError(rt, "Cannot transfer a detached ArrayBuffer");
        }
        const gop = try ctx.transfer_set.getOrPut(rt.gpa, ab);
        if (gop.found_existing) {
            builtins.iteratorClose(rt, iter, true) catch {};
            return throwDataCloneError(rt, "Duplicate ArrayBuffer in transfer list");
        }
    }
}

fn cloneValue(ctx: *CloneContext, val: Value) Error!Value {
    const rt = ctx.rt;
    return switch (val.unpack()) {
        .undefined, .null, .boolean, .number, .string, .bigint => val,
        .symbol => throwDataCloneError(rt, "Symbol could not be cloned"),
        .closure, .native => throwDataCloneError(rt, "Function could not be cloned"),
        .object => |o| Value.fromObject(try cloneObject(ctx, o)),
    };
}

fn cloneObject(ctx: *CloneContext, src: *Object) Error!*Object {
    const rt = ctx.rt;
    if (ctx.visited.get(src)) |existing| return existing;

    if (ctx.depth >= rt.limits.max_nesting_depth) return rt.limit(.nesting_depth);
    ctx.depth += 1;
    defer ctx.depth -= 1;

    const saved = try ctx.pushRoot(Value.fromObject(src));
    defer ctx.popRoots(saved);

    return switch (src.kind) {
        .ordinary => if (src.ordinary_tag == .@"error") try cloneError(ctx, src) else try cloneOrdinary(ctx, src),
        .mapped_arguments => try cloneOrdinary(ctx, src),
        .array => try cloneArray(ctx, src),
        .map => try cloneMap(ctx, src),
        .set => try cloneSet(ctx, src),
        .date => try cloneDate(ctx, src),
        .primitive_wrapper => |pv| blk: {
            const r = try builtins.realm(rt);
            const dst = switch (pv.unpack()) {
                .boolean => try rt.heap.newPrimitiveWrapper(r.boolean_prototype, pv),
                .number => try rt.heap.newPrimitiveWrapper(r.number_prototype, pv),
                .bigint => try rt.heap.newPrimitiveWrapper(r.bigint_prototype, pv),
                .string => |s| try rt.heap.newPrimitiveWrapper(r.string_prototype, Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units }}))),
                else => return throwDataCloneError(rt, "Symbol object could not be cloned"),
            };
            try ctx.visited.put(rt.gpa, src, dst);
            break :blk dst;
        },
        .regexp => try cloneRegExp(ctx, src),
        .array_buffer => try cloneArrayBuffer(ctx, src),
        .typed_array => try cloneTypedArray(ctx, src),
        .data_view => try cloneDataView(ctx, src),
        .proxy => throwDataCloneError(rt, "Proxy could not be cloned"),
        .weak_map => throwDataCloneError(rt, "WeakMap could not be cloned"),
        .weak_set => throwDataCloneError(rt, "WeakSet could not be cloned"),
        .generator => throwDataCloneError(rt, "Generator could not be cloned"),
        .module_namespace => throwDataCloneError(rt, "Module namespace could not be cloned"),
        .promise => throwDataCloneError(rt, "Promise could not be cloned"),
        .iterator => throwDataCloneError(rt, "Iterator could not be cloned"),
    };
}

fn cloneOrdinary(ctx: *CloneContext, src: *Object) Error!*Object {
    const rt = ctx.rt;
    const r = try builtins.realm(rt);
    const dst = try rt.heap.newObject(r.object_prototype);
    try ctx.visited.put(rt.gpa, src, dst);

    const keys = try object.ownKeys(rt, src);
    defer rt.gpa.free(keys);
    try ctx.pending_keys.append(rt.gpa, keys);
    defer _ = ctx.pending_keys.pop();

    for (keys) |k| {
        const prop_val = try object.get(rt, Value.fromObject(src), k);
        const s1 = try ctx.pushRoot(prop_val);
        defer ctx.popRoots(s1);
        const cloned_val = try cloneValue(ctx, prop_val);
        const s2 = try ctx.pushRoot(cloned_val);
        defer ctx.popRoots(s2);
        try object.define(rt, dst, k, cloned_val);
    }
    return dst;
}

fn cloneArray(ctx: *CloneContext, src: *Object) Error!*Object {
    const rt = ctx.rt;
    const r = try builtins.realm(rt);
    const dst = try rt.heap.newArray(r.array_prototype);
    try ctx.visited.put(rt.gpa, src, dst);

    // Snapshot original length; iterate by index so getter mutations can't invalidate slices.
    const orig_len = src.kind.array.items.len;
    for (0..orig_len) |i| {
        const elem: Value = if (i < src.kind.array.items.len) src.kind.array.items[i] else .undefined;
        const s1 = try ctx.pushRoot(elem);
        defer ctx.popRoots(s1);
        const cloned_elem = try cloneValue(ctx, elem);
        const s2 = try ctx.pushRoot(cloned_elem);
        defer ctx.popRoots(s2);
        try rt.heap.appendElement(dst, cloned_elem);
    }

    // Clone any own enumerable non-index string properties attached to the array.
    const keys = try object.ownKeys(rt, src);
    defer rt.gpa.free(keys);
    try ctx.pending_keys.append(rt.gpa, keys);
    defer _ = ctx.pending_keys.pop();

    for (keys) |k| {
        if (k == .index and k.index < orig_len) continue;
        const prop_val = try object.get(rt, Value.fromObject(src), k);
        const s1 = try ctx.pushRoot(prop_val);
        defer ctx.popRoots(s1);
        const cloned_val = try cloneValue(ctx, prop_val);
        const s2 = try ctx.pushRoot(cloned_val);
        defer ctx.popRoots(s2);
        try object.define(rt, dst, k, cloned_val);
    }
    return dst;
}

fn cloneDate(ctx: *CloneContext, src: *Object) Error!*Object {
    const rt = ctx.rt;
    const r = try builtins.realm(rt);
    const dst = try rt.heap.newDate(r.date_prototype, src.kind.date);
    try ctx.visited.put(rt.gpa, src, dst);
    return dst;
}

fn cloneRegExp(ctx: *CloneContext, src: *Object) Error!*Object {
    const rt = ctx.rt;
    const r = try builtins.realm(rt);
    const re = src.kind.regexp;
    var cloned_prog = re.program.clone(rt.heap.allocator()) catch |e| return rt.heap.failed(e);
    errdefer cloned_prog.deinit(rt.heap.allocator());
    const dst = try rt.heap.newRegExp(r.regexp_prototype, cloned_prog, re.source, re.flags, re.global);
    try ctx.visited.put(rt.gpa, src, dst);
    return dst;
}

fn cloneMap(ctx: *CloneContext, src: *Object) Error!*Object {
    const rt = ctx.rt;
    const r = try builtins.realm(rt);
    const dst = try rt.heap.newMap(r.map_prototype);
    try ctx.visited.put(rt.gpa, src, dst);

    var i: usize = 0;
    while (i < src.kind.map.entries.items.len) : (i += 1) {
        const entry = src.kind.map.entries.items[i];
        if (!entry.alive) continue;
        const s1 = try ctx.pushRoot(entry.key);
        defer ctx.popRoots(s1);
        _ = try ctx.pushRoot(entry.value);

        const ck = try cloneValue(ctx, entry.key);
        _ = try ctx.pushRoot(ck);
        const cv = try cloneValue(ctx, entry.value);
        _ = try ctx.pushRoot(cv);
        try rt.heap.mapSet(dst, ck, cv);
    }
    return dst;
}

fn cloneSet(ctx: *CloneContext, src: *Object) Error!*Object {
    const rt = ctx.rt;
    const r = try builtins.realm(rt);
    const dst = try rt.heap.newSet(r.set_prototype);
    try ctx.visited.put(rt.gpa, src, dst);

    var i: usize = 0;
    while (i < src.kind.set.entries.items.len) : (i += 1) {
        const entry = src.kind.set.entries.items[i];
        if (!entry.alive) continue;
        const s1 = try ctx.pushRoot(entry.key);
        defer ctx.popRoots(s1);

        const cv = try cloneValue(ctx, entry.key);
        _ = try ctx.pushRoot(cv);
        try rt.heap.setAdd(dst, cv);
    }
    return dst;
}

fn cloneArrayBuffer(ctx: *CloneContext, src: *Object) Error!*Object {
    const rt = ctx.rt;
    if (ctx.visited.get(src)) |existing| return existing;
    const ab = src.kind.array_buffer;
    if (ab.detached) return throwDataCloneError(rt, "Cannot clone a detached ArrayBuffer");

    const vr = try builtins.viewsRealm(rt);
    const dst = if (ctx.transfer_set.contains(src))
        // Allocate empty shell; backing slice moves zero-copy after cloning succeeds.
        try rt.heap.newArrayBuffer(vr.array_buffer_prototype, 0)
    else blk: {
        const copy = try rt.heap.newArrayBuffer(vr.array_buffer_prototype, ab.data.len);
        if (ab.data.len > 0) @memcpy(copy.kind.array_buffer.data, ab.data);
        break :blk copy;
    };
    try ctx.visited.put(rt.gpa, src, dst);
    return dst;
}

fn cloneTypedArray(ctx: *CloneContext, src: *Object) Error!*Object {
    const rt = ctx.rt;
    const ta = src.kind.typed_array;
    if (ta.buffer.kind.array_buffer.detached) {
        return throwDataCloneError(rt, "Cannot clone a TypedArray backed by a detached ArrayBuffer");
    }
    const cloned_ab = try cloneArrayBuffer(ctx, ta.buffer);
    const s1 = try ctx.pushRoot(Value.fromObject(cloned_ab));
    defer ctx.popRoots(s1);

    const vr = try builtins.viewsRealm(rt);
    const dst = try rt.heap.newTypedArray(
        vr.typed_array_prototypes[@backingInt(ta.kind)],
        cloned_ab,
        ta.kind,
        ta.byte_offset,
        ta.length,
    );
    try ctx.visited.put(rt.gpa, src, dst);
    return dst;
}

fn cloneDataView(ctx: *CloneContext, src: *Object) Error!*Object {
    const rt = ctx.rt;
    const dv = src.kind.data_view;
    if (dv.buffer.kind.array_buffer.detached) {
        return throwDataCloneError(rt, "Cannot clone a DataView backed by a detached ArrayBuffer");
    }
    const cloned_ab = try cloneArrayBuffer(ctx, dv.buffer);
    const s1 = try ctx.pushRoot(Value.fromObject(cloned_ab));
    defer ctx.popRoots(s1);

    const vr = try builtins.viewsRealm(rt);
    const dst = try rt.heap.newDataView(
        vr.data_view_prototype,
        cloned_ab,
        dv.byte_offset,
        dv.byte_length,
    );
    try ctx.visited.put(rt.gpa, src, dst);
    return dst;
}

fn cloneError(ctx: *CloneContext, src: *Object) Error!*Object {
    const rt = ctx.rt;
    const r = try builtins.realm(rt);
    var proto = r.error_prototype;
    var cur = src.proto;
    while (cur) |p| : (cur = p.proto) {
        if (p == r.type_error_prototype or
            p == r.range_error_prototype or
            p == r.syntax_error_prototype or
            p == r.reference_error_prototype or
            p == r.eval_error_prototype or
            p == r.uri_error_prototype or
            p == r.aggregate_error_prototype or
            p == r.error_prototype)
        {
            proto = p;
            break;
        }
    }

    const dst = try rt.heap.newObject(proto);
    dst.ordinary_tag = .@"error";
    try ctx.visited.put(rt.gpa, src, dst);

    const name_atom = try rt.heap.internAscii("name");
    if (src.props.get(PropKey.fromAtom(name_atom))) |_| {
        const name_val = try object.get(rt, Value.fromObject(src), .{ .atom = name_atom });
        if (!name_val.isUndefined()) {
            const s1 = try ctx.pushRoot(name_val);
            defer ctx.popRoots(s1);
            const name_str = try builtins.toStringObj(rt, name_val);
            const s2 = try ctx.pushRoot(Value.fromString(name_str));
            defer ctx.popRoots(s2);
            try rt.heap.defineProperty(dst, name_atom, .{ .value = Value.fromString(name_str), .enumerable = false });
        }
    }

    const msg_atom = try rt.heap.internAscii("message");
    if (src.props.get(PropKey.fromAtom(msg_atom))) |_| {
        const msg_val = try object.get(rt, Value.fromObject(src), .{ .atom = msg_atom });
        if (!msg_val.isUndefined()) {
            const s1 = try ctx.pushRoot(msg_val);
            defer ctx.popRoots(s1);
            const msg_str = try builtins.toStringObj(rt, msg_val);
            const s2 = try ctx.pushRoot(Value.fromString(msg_str));
            defer ctx.popRoots(s2);
            try rt.heap.defineProperty(dst, msg_atom, .{ .value = Value.fromString(msg_str), .enumerable = false });
        }
    }

    const cause_atom = try rt.heap.internAscii("cause");
    if (src.props.get(PropKey.fromAtom(cause_atom))) |_| {
        const cause_val = try object.get(rt, Value.fromObject(src), .{ .atom = cause_atom });
        const s1 = try ctx.pushRoot(cause_val);
        defer ctx.popRoots(s1);
        const cloned_cause = try cloneValue(ctx, cause_val);
        const s2 = try ctx.pushRoot(cloned_cause);
        defer ctx.popRoots(s2);
        try rt.heap.defineProperty(dst, cause_atom, .{ .value = cloned_cause, .enumerable = false });
    }

    if (proto == r.aggregate_error_prototype) {
        const errors_atom = try rt.heap.internAscii("errors");
        if (src.props.get(PropKey.fromAtom(errors_atom))) |_| {
            const errors_val = try object.get(rt, Value.fromObject(src), .{ .atom = errors_atom });
            const s1 = try ctx.pushRoot(errors_val);
            defer ctx.popRoots(s1);
            const cloned_errors = try cloneValue(ctx, errors_val);
            const s2 = try ctx.pushRoot(cloned_errors);
            defer ctx.popRoots(s2);
            try rt.heap.defineProperty(dst, errors_atom, .{ .value = cloned_errors, .enumerable = false });
        }
    }

    return dst;
}
