//! Garbage collector tests (M8). P0: the store-API invariant (GC_DESIGN I3): after
//! construction, every reference written into a heap object goes through the heap's
//! store functions, so a write barrier has one place to hook into.
//!
//! Zig has no field privacy, so this is enforced by scanning the files that touch heap
//! objects for the raw forms of a store. Reads stay direct. Exempt by design:
//!   - runtime/heap.zig itself (the store API and the constructors live there)
//!   - the VM's own locals and stacks (`vm.slot(...).* =`, `stack[...] =`): they are roots,
//!     not heap objects, and roots are never barriered (GC_DESIGN §7)
//!   - construction: filling an object nobody else can see yet (`newEnv` + `@memcpy` in the
//!     tree-walker's per-iteration copy); no pattern below matches it

const std = @import("std");
const testing = std.testing;

/// The files whose code holds heap objects (DESIGN_DECISIONS D7: only heap.zig allocates).
const scanned = [_][]const u8{
    "src/runtime/object.zig",
    "src/runtime/builtins.zig",
    "src/runtime/ops.zig",
    "src/vm/vm.zig",
    "src/interp/treewalk.zig",
    "src/bytecode/compiler.zig",
};

/// Why `line` is a raw store into a heap object, or null.
fn rawStore(line_in: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, line_in, " \t");
    if (std.mem.startsWith(u8, line, "//")) return null;
    const calls = [_]struct { []const u8, []const u8 }{
        .{ ".props.put(", "property store: use heap.storeProperty/defineProperty" },
        .{ ".props.getOrPut(", "property store: use heap.storeProperty/defineProperty" },
        .{ ".props.orderedRemove(", "property delete: use heap.removeProperty" },
        .{ ".props.swapRemove(", "property delete: use heap.removeProperty" },
        .{ ".kind.array.append", "element store: use heap.appendElement(s)" },
        .{ "elements.append", "element store: use heap.appendElement(s)" },
        .{ ".kind.array.pop(", "element removal: use heap.popElement" },
        .{ "elements.pop(", "element removal: use heap.popElement" },
        .{ "elements.shrink", "element removal: use heap.shrinkElements" },
    };
    for (calls) |c| if (std.mem.indexOf(u8, line, c[0]) != null) return c[1];
    // Indexed writes into an element list, an environment record or a capture list.
    if (std.mem.indexOf(u8, line, "] = ") != null) {
        if (std.mem.indexOf(u8, line, "items[") != null and std.mem.indexOf(u8, line, "stack[") == null)
            return "element store: use heap.storeElement";
        if (std.mem.indexOf(u8, line, ".values[") != null) return "environment store: use heap.storeEnv";
        if (std.mem.indexOf(u8, line, "captures[") != null) return "capture store: only heap.zig constructors";
    }
    // `cell.value = …` and `obj.proto = …`: a field write on an expression, not a struct
    // literal field (`.{ .value = … }`, where `.value` follows a space or brace).
    for ([_]struct { []const u8, []const u8 }{
        .{ ".value = ", "cell store: use heap.storeCell" },
        .{ ".proto = ", "prototype store: only heap.zig constructors" },
    }) |f| {
        var at: usize = 0;
        while (std.mem.indexOfPos(u8, line, at, f[0])) |i| : (at = i + 1) {
            if (i > 0 and (std.ascii.isAlphanumeric(line[i - 1]) or line[i - 1] == '_' or line[i - 1] == ')')) return f[1];
        }
    }
    return null;
}

test "the scanner flags every raw-store form it claims to" {
    for ([_][]const u8{
        "o.props.put(a, k, v);",
        "_ = o.props.getOrPut(a, k);",
        "_ = o.props.orderedRemove(k);",
        "arr.kind.array.append(a, v) catch {};",
        "try elements.appendSlice(a, vs);",
        "_ = elements.pop();",
        "elements.shrinkRetainingCapacity(n);",
        "elements.items[i] = v;",
        "rec.values[i] = v;",
        "c.impl.vm.captures[0] = cell;",
        "c.value = v;",
        "vm.cellAt(i).value = v;",
        "o.proto = p;",
    }) |line| if (rawStore(line) == null) {
        std.debug.print("not flagged: {s}\n", .{line});
        return error.TestUnexpectedResult;
    };
    // And leaves reads, struct literals, roots and comments alone.
    for ([_][]const u8{
        "const v = elements.items[i];",
        "s.* = .{ .value = vm.peek(0) };",
        "vm.stack[base] = result;",
        "return it.envOf(b).values[i];",
        "// c.value = v; in a comment",
        "o.* = .{ .obj = x, .proto = proto };",
    }) |line| if (rawStore(line)) |why| {
        std.debug.print("wrongly flagged ({s}): {s}\n", .{ why, line });
        return error.TestUnexpectedResult;
    };
}

test "every store into a heap object goes through the heap's store API (I3)" {
    const io = testing.io;
    const gpa = testing.allocator;
    var violations: usize = 0;
    for (scanned) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 22));
        defer gpa.free(text);
        // The unit tests at the end of a file build objects by hand; only code is scanned.
        const code = if (std.mem.indexOf(u8, text, "\ntest \"")) |t| text[0..t] else text;
        var lines = std.mem.splitScalar(u8, code, '\n');
        var n: usize = 0;
        while (lines.next()) |line| {
            n += 1;
            if (rawStore(line)) |why| {
                std.debug.print("{s}:{d}: {s}\n    {s}\n", .{ path, n, why, std.mem.trim(u8, line, " \t") });
                violations += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), violations);
}

// ---------------------------------------------------------------- P1: the collector

const zqjs = @import("zqjs");
const heap = zqjs.heap;
const Allocator = std.mem.Allocator;

/// A heap-level root set for unit tests: marks the objects listed.
const TestRoots = struct {
    objs: []const *heap.Obj,
    fn mark(r: TestRoots, h: *heap.Heap) void {
        for (r.objs) |o| h.markObj(o);
    }
};

test "collect frees the unreachable, keeps the reachable, and accounts exactly" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const keep = try h.newObject(null);
    const kept_str = try h.ascii("kept");
    try h.storeProperty(keep, try h.internAscii("k"), .{ .string = kept_str });
    const survivors = h.bytes; // everything so far stays reachable from `keep`
    for (0..100) |i| {
        const g = try h.newArray(keep);
        try h.appendElement(g, .{ .number = @floatFromInt(i) });
        _ = try h.ascii("garbage");
    }
    h.collect(TestRoots{ .objs = &.{&keep.obj} }, TestRoots.mark);
    try testing.expectEqual(survivors, h.bytes); // bytes == the survivors' charges
    try testing.expectEqual(@as(u64, 1), h.stats.collections);
    try testing.expectEqual(@as(u64, 200), h.stats.swept);
    try testing.expectEqual(@as(u64, 3), h.stats.marked); // keep, its key atom, its string
    try testing.expectEqual(h.bytes, h.stats.live_after_last);
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("kept"), keep.props.get(try h.internAscii("k")).?.value.string.units);
}

test "a value reachable only through a chain of every object kind survives" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    // root object → array → VM closure → cell → object → prototype → (key atom, string)
    //                      → tree closure → env → parent env → string
    const root = try h.newObject(null);
    const arr = try h.newArray(null);
    try h.storeProperty(root, try h.internAscii("list"), .{ .object = arr });
    const vm_closure = try h.newVmClosure(@ptrCast(&h), 1);
    const cell = try h.newCell(null);
    vm_closure.impl.vm.captures[0] = cell; // construction
    try h.appendElement(arr, .{ .closure = vm_closure });
    const proto = try h.newObject(null);
    const via_cell = try h.newObject(proto);
    h.storeCell(cell, .{ .object = via_cell });
    const deep_key = try h.internAscii("deep");
    try h.storeProperty(proto, deep_key, .{ .string = try h.ascii("via the prototype") });
    const outer_env = try h.newEnv(null, 0, 1);
    h.storeEnv(outer_env, 0, .{ .string = try h.ascii("via the environment") });
    const inner_env = try h.newEnv(outer_env, 1, 0);
    const tree_closure = try h.newTreeClosure(@ptrCast(&h), inner_env);
    try h.appendElement(arr, .{ .closure = tree_closure });
    const live = h.bytes;
    // Garbage of every kind, some of it pointing *into* the live chain.
    for (0..20) |_| {
        const g = try h.newObject(via_cell);
        try h.storeProperty(g, deep_key, .{ .object = root });
        _ = try h.newCell(.{ .object = g });
        _ = try h.newEnv(outer_env, 2, 3);
        _ = try h.newTreeClosure(@ptrCast(&h), inner_env);
        _ = try h.newVmClosure(@ptrCast(&h), 0);
        _ = try h.ascii("loose string");
        _ = try h.internAscii("loose atom"); // the same atom each time: one object
    }
    h.collect(TestRoots{ .objs = &.{&root.obj} }, TestRoots.mark);
    try testing.expectEqual(live, h.bytes);
    // Walk the chain again: every link and leaf is intact.
    const a2 = root.props.get(try h.internAscii("list")).?.value.object;
    const c2 = a2.kind.array.items[0].closure.impl.vm.captures[0];
    const o2 = c2.value.?.object;
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("via the prototype"), o2.proto.?.props.get(deep_key).?.value.string.units);
    const e2 = a2.kind.array.items[1].closure.impl.tree.env.?.parent.?;
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("via the environment"), e2.values[0].?.string.units);
}

test "collecting allocates nothing: marking, atom cleanup and sweep, with the allocator failing" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const keep = try h.newObject(null);
    for (0..500) |i| {
        var buf: [16]u8 = undefined;
        const k = try h.internAscii(std.fmt.bufPrint(&buf, "k{d}", .{i}) catch unreachable);
        if (i % 2 == 0) try h.storeProperty(keep, k, .{ .number = 1 }); // half the atoms stay live
    }
    const capacity = h.atoms.capacity();
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    h.gpa = failing.allocator(); // any allocation would fail (and be counted)
    h.collect(TestRoots{ .objs = &.{&keep.obj} }, TestRoots.mark);
    h.gpa = testing.allocator;
    try testing.expectEqual(@as(usize, 0), failing.allocations);
    try testing.expectEqual(capacity, h.atoms.capacity()); // the table's storage is reused
    try testing.expectEqual(@as(u32, 250), h.atoms.count());
}

test "weak atoms (D11): kept by their objects, dropped with them, reusable after delete" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const baseline = h.atoms.count();
    const o = try h.newObject(null);
    var buf: [16]u8 = undefined;
    for (0..10_000) |i| try h.storeProperty(o, try h.internAscii(std.fmt.bufPrint(&buf, "k{d}", .{i}) catch unreachable), .{ .number = @floatFromInt(i) });
    for (0..5) |_| h.collect(TestRoots{ .objs = &.{&o.obj} }, TestRoots.mark);
    for (0..10_000) |i| {
        const k = try h.internAscii(std.fmt.bufPrint(&buf, "k{d}", .{i}) catch unreachable);
        try testing.expectEqual(@as(f64, @floatFromInt(i)), o.props.get(k).?.value.number); // same atom as the key
    }
    // delete o[k], collect, reuse k: a fresh atom works as the key.
    h.removeProperty(o, try h.internAscii("k7"));
    h.collect(TestRoots{ .objs = &.{&o.obj} }, TestRoots.mark);
    try h.storeProperty(o, try h.internAscii("k7"), .{ .number = 77 });
    try testing.expectEqual(@as(f64, 77), o.props.get(try h.internAscii("k7")).?.value.number);
    // Drop the object: the table shrinks back to its baseline, and every entry left is a
    // live object (the cleanup ran before the sweep freed anything).
    h.collect(TestRoots{ .objs = &.{} }, TestRoots.mark);
    try testing.expectEqual(baseline, h.atoms.count());
    try testing.expectEqual(@as(?*heap.Obj, null), h.objects);
}

test "after a collection the atom table holds only live atoms (no stale pointers)" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const o = try h.newObject(null);
    var buf: [16]u8 = undefined;
    for (0..300) |i| {
        const k = try h.internAscii(std.fmt.bufPrint(&buf, "a{d}", .{i}) catch unreachable);
        if (i % 3 == 0) try h.storeProperty(o, k, .null);
    }
    h.collect(TestRoots{ .objs = &.{&o.obj} }, TestRoots.mark);
    var it = h.atoms.keyIterator();
    while (it.next()) |k| {
        var live = h.objects;
        while (live) |obj| : (live = obj.next) {
            if (obj == &k.*.obj) break;
        } else return error.TestUnexpectedResult; // an entry that isn't a live object
    }
    try testing.expectEqual(@as(u32, 100), h.atoms.count());
}

test "scheduling: a collection is requested past next_gc, with headroom under the limit" {
    var h = heap.Heap.init(testing.allocator, .{ .max_heap_bytes = 1 << 20 });
    defer h.deinit();
    try testing.expectEqual(@as(usize, 256 * 1024), h.next_gc);
    while (!h.collect_requested) _ = try h.ascii("0123456789");
    try testing.expect(h.bytes > h.next_gc);
    h.collect(TestRoots{ .objs = &.{} }, TestRoots.mark);
    try testing.expect(!h.collect_requested);
    try testing.expectEqual(@as(usize, 0), h.bytes);
    // A small limit: never closer than halfway to it.
    var small = heap.Heap.init(testing.allocator, .{ .max_heap_bytes = 80_000 });
    defer small.deinit();
    try testing.expectEqual(@as(usize, 40_000), small.next_gc);
    // Extremes: no overflow, never beyond the limit, never below the live size.
    for ([_]usize{ 0, 1, 100, 1 << 20, std.math.maxInt(usize) }) |max| {
        var e = heap.Heap.init(testing.allocator, .{ .max_heap_bytes = max });
        defer e.deinit();
        for ([_]usize{ 0, 1, max / 2, max -| 1, max }) |live| {
            const next = e.schedule(live);
            try testing.expect(next >= live and next <= @max(max, live));
        }
    }
}

test "no pathological collection loop: filling the heap with live data collects O(log limit) times" {
    // A test of the *scheduler*; -Dgc-stress bypasses it and collects at every safepoint.
    if (heap.gc_stress) return error.SkipZigTest;
    // Live data grows to the limit (every string is kept): each collection frees nothing,
    // and must not be followed by another one at the very next safepoint.
    const r = try runVm("let keep = []; let n = 0; while (true) { keep.push('item number ' + n++); }", .{ .max_heap_bytes = 1 << 20 }, false);
    defer testing.allocator.free(r.out);
    try testing.expectEqual(@as(?anyerror, error.LimitExceeded), r.err);
    try testing.expect(r.collections > 0 and r.collections <= 30); // the halvings of the room left: ~log2(1 MiB)
}

// ---- the VM collecting

const VmRun = struct { out: []u8, err: ?anyerror, collections: u64, bytes_after: usize };

/// Runs `source` on the VM with a collection at every safepoint (`always`) or only when
/// requested; returns its output, its error and the collector's statistics.
fn runVm(source: []const u8, limits: zqjs.Limits, always: bool) !VmRun {
    const gpa = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var rt = zqjs.Runtime.init(gpa, limits, &out.writer);
    defer rt.deinit();
    rt.heap.collect_always = always or heap.gc_stress; // never fewer collections under -Dgc-stress
    var d: zqjs.Diagnostic = .{};
    const script = try zqjs.parse(arena.allocator(), source, limits, &d);
    const res = try zqjs.resolve(arena.allocator(), script, &d);
    var proto = try zqjs.compile(gpa, &rt.heap, script, res, limits, &d);
    defer proto.deinit(gpa);
    var f: zqjs.verify.Failure = .{};
    _ = try zqjs.verify.verify(gpa, &proto, limits, &f);
    var vm = try zqjs.Vm.init(&rt, &proto);
    var err: ?anyerror = null;
    vm.run() catch |e| {
        err = e;
    };
    try testing.expect(vm.scriptProto() == &proto); // registration is the Proto runSource owns
    vm.deinit();
    try testing.expectEqual(@as(?zqjs.runtime.EngineRoots, null), rt.engine_roots); // unregistered
    return .{ .out = try out.toOwnedSlice(), .err = err, .collections = rt.heap.stats.collections, .bytes_after = rt.heap.bytes };
}

fn expectVmOutput(source: []const u8, expected: []const u8) !void {
    const r = try runVm(source, .{}, true);
    defer testing.allocator.free(r.out);
    testing.expectEqualStrings(expected, r.out) catch |e| {
        std.debug.print("source: {s}\n", .{source});
        return e;
    };
    try testing.expect(r.collections > 0);
}

test "every VM root kind keeps its value alive across collections at every safepoint" {
    const garbage = "function g() { let s = ''; for (let i = 0; i < 20; i++) { s = s + i; let o = { a: [s], b: function () { return s; } }; } return 0; } ";
    // A value only on the operand stack, while g() runs and collects.
    try expectVmOutput(garbage ++ "print('on ' + 'stack', g(), 'x' + 'y');", "on stack 0 xy\n");
    // Locals (plain slots) and cells (captured bindings).
    try expectVmOutput(garbage ++ "let l = 'lo' + 'cal'; g(); let c = 'cap' + 'tured'; const f = function () { return c; }; g(); print(l, f());", "local captured\n");
    // A frame's closure and `this` (the receiver only the frame still holds).
    try expectVmOutput(garbage ++ "print({ v: 'th' + 'is', m() { g(); return this.v; } }.m());", "this\n");
    try expectVmOutput(garbage ++ "print(function () { g(); return 'ran'; }());", "ran\n");
    // Proto constants, including a nested function's.
    try expectVmOutput(garbage ++ "function h() { g(); return 'nested constant'; } g(); print('top constant', h());", "top constant nested constant\n");
    // The realm (built-in prototypes and their methods) and objects reached only through it.
    try expectVmOutput(garbage ++ "g(); let a = []; a.push(g(), 'p'); g(); print(a.join('-'), Object.keys({ z: 1 }));", "0-p z\n");
}

test "the exception message and the unsupported name are roots" {
    const gpa = testing.allocator;
    for ([_]struct { []const u8, []const u8 }{
        .{ "let o = {}; o.a.b;", "Cannot read properties of undefined (reading 'b')" },
        .{ "Math.PI;", "Math" },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var discard: std.Io.Writer.Discarding = .init(&.{});
        var rt = zqjs.Runtime.init(gpa, .{}, &discard.writer);
        defer rt.deinit();
        var d: zqjs.Diagnostic = .{};
        const script = try zqjs.parse(arena.allocator(), case[0], .{}, &d);
        const res = try zqjs.resolve(arena.allocator(), script, &d);
        var proto = try zqjs.compile(gpa, &rt.heap, script, res, .{}, &d);
        defer proto.deinit(gpa);
        var vm = try zqjs.Vm.init(&rt, &proto);
        _ = vm.run() catch {};
        vm.deinit();
        // The VM failed, then was torn down: its registration must be gone, or the
        // collections below would scan freed stacks.
        try testing.expectEqual(@as(?zqjs.runtime.EngineRoots, null), rt.engine_roots);
        for (0..3) |_| rt.collect(); // no engine left: only the runtime's own roots
        const text = if (rt.exception) |e| e.message.units else rt.unsupported_name.?.units;
        var want: [64]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(&want, case[1]);
        try testing.expectEqualSlices(u16, want[0..n], text);
    }
}

test "garbage under a small limit: the VM runs to its step budget, not the heap limit" {
    const r = try runVm(
        \\let n = 0;
        \\while (true) {
        \\  let s = 'garbage ' + n;
        \\  let o = { s, list: [s, s + '!'], f: function () { return s; } };
        \\  n = n + o.list.length;
        \\}
    , .{ .max_heap_bytes = 128 << 10, .max_steps = 50_000 }, false); // allocates ~4× the limit
    defer testing.allocator.free(r.out);
    try testing.expectEqual(@as(?anyerror, error.LimitExceeded), r.err);
    try testing.expect(r.collections > 0);
}

test "every diff program matches node on the VM with a collection at every safepoint" {
    const io = testing.io;
    const gpa = testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/diff", .{ .iterate = true });
    defer dir.close(io);
    var count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".js")) continue;
        count += 1;
        const source = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        defer gpa.free(source);
        const out_name = try std.fmt.allocPrint(gpa, "{s}.out", .{entry.name[0 .. entry.name.len - 3]});
        defer gpa.free(out_name);
        const expected = try dir.readFileAlloc(io, out_name, gpa, .limited(1 << 20));
        defer gpa.free(expected);
        var got: std.Io.Writer.Allocating = .init(gpa);
        defer got.deinit();
        var discard: std.Io.Writer.Discarding = .init(&.{});
        _ = try zqjs.runSource(gpa, entry.name, source, .{ .max_steps = 50_000_000 }, .{ .mode = .harness, .engine = .vm, .collect_always = true }, &got.writer, &discard.writer);
        if (!std.mem.eql(u8, got.written(), expected)) {
            std.debug.print("\n== {s} on the VM, collecting at every safepoint\n-- expected (node)\n{s}-- got\n{s}", .{ entry.name, expected, got.written() });
            failures += 1;
        }
    }
    try testing.expect(count > 50);
    try testing.expectEqual(@as(usize, 0), failures);
}

// ---------------------------------------------------------------- P2: the tree-walker

/// Runs `source` on `engine` through runSource (harness mode), collecting at every
/// safepoint, and returns what it printed.
fn runCollecting(source: []const u8, engine: zqjs.Engine, limits: zqjs.Limits) ![]u8 {
    var got: std.Io.Writer.Allocating = .init(testing.allocator);
    defer got.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try zqjs.runSource(testing.allocator, "t", source, limits, .{ .mode = .harness, .engine = engine, .collect_always = true }, &got.writer, &discard.writer);
    return got.toOwnedSlice();
}

test "every shadow-stack site: a value held only there survives collections in the sub-evaluation" {
    // In each program, `g()` allocates and returns while the tree-walker holds the value of
    // the site in a Zig local; with a collection at every safepoint, a missing `hold` frees
    // it. Expected outputs are node's. Both engines run each one.
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "binary operator: left operand held while the right one runs", "function g() { let s = ''; for (let i = 0; i < 5; i++) { s = s + i; let o = { a: [s] }; } return 0; } print(('le' + 'ft') + g(), g() + ('ri' + 'ght'));", "left0 0right\n" },
        .{ "x op= e: old value", "function g() { let o = { a: [1] }; return 0; } let x = 'old' + 1; x += g(); print(x);", "old10\n" },
        .{ "o[k] = e: base and evaluated key", "function g() { let o = { a: [1] }; return 'k'; } let o = {}; o['ba' + 'se'] = 1; let b = { v: 'base' }; ({ q: b })['q'][g()] = 'set'; print(b.k);", "set\n" },
        .{ "o[k] op= e: base, key atom and old value", "function g() { let o = { a: [1] }; return 'v'; } let t = { v: 10 }; t[g()] += 5 + g().length; print(t.v);", "16\n" },
        .{ "o[k]++ / ++o[k] / delete o[k]: base", "function g() { let o = { a: [1] }; return 'v'; } let t = { v: 1 }; print(t[g()]++, ++t[g()], t.v, delete t[g()], 'v' in t);", "1 3 3 true false\n" },
        .{ "array literal under construction", "function g() { let o = { a: [1] }; return 'x' + 1; } let a = [g(), g(), [g(), [g()]]]; print(a, a.length);", "x1,x1,x1,x1 3\n" },
        .{ "object literal under construction and its key atoms", "function g() { let o = { a: [1] }; return 'x' + 1; } let o = { [g()]: g(), b: [g()], [g() + 'k']: g() }; print(Object.keys(o), o.x1, o.b, o.x1k);", "x1,b,x1k x1 x1 x1\n" },
        .{ "call: callee and each argument, natives too", "function g() { let o = { a: [1] }; return 'arg' + 1; } function f(a, b, c) { g(); return a + b + c; } print(f(g(), g(), g()), [1, 2].join(g()));", "arg1arg1arg1 1arg12\n" },
        .{ "method call: receiver and this", "function g() { let o = { a: [1] }; return 0; } let r = { v: 'recv' + 1, m(x) { g(); return this.v + x; } }; print(r.m(g()), ({ v: 'tmp', m() { g(); return this.v; } }).m());", "recv10 tmp\n" },
        .{ "recursion: values held in every frame", "function g() { let o = { a: [1] }; return 0; } function deep(n) { let s = 'level' + n; if (n === 0) return s; let r = deep(n - 1); g(); return s + ',' + r; } print(deep(15));", "level15,level14,level13,level12,level11,level10,level9,level8,level7,level6,level5,level4,level3,level2,level1,level0\n" },
        .{ "closures created and called around collections", "function mk(n) { let s = 'cl' + n; return function () { return s; }; } function g() { let o = { a: [1] }; return 0; } let fs = [mk(1), mk(2)]; g(); print(fs[0]() + fs[1](), mk(3)() + g());", "cl1cl2 cl30\n" },
        .{ "temporary return values", "function g() { let o = { a: [1] }; return 'ret' + 1; } function f() { return g() + g(); } function h() { return f() + '/' + f(); } print(h(), h().length);", "ret1ret1/ret1ret1 17\n" },
        .{ "per-iteration bindings and immediately-called closures", "function g() { let o = { a: [1] }; return 0; } let acc = ''; for (let i = 0; i < 4; i++) { let k = 'it' + i; acc = acc + (function () { g(); return k; })(); } print(acc);", "it0it1it2it3\n" },
    };
    for (cases) |c| for ([_]zqjs.Engine{ .treewalk, .vm }) |engine| {
        const got = try runCollecting(c[1], engine, .{});
        defer testing.allocator.free(got);
        testing.expectEqualStrings(c[2], got) catch |e| {
            std.debug.print("site: {s} ({s})\n", .{ c[0], @tagName(engine) });
            return e;
        };
    };
}

test "every diff program matches node on the tree-walker with a collection at every safepoint" {
    const io = testing.io;
    const gpa = testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/diff", .{ .iterate = true });
    defer dir.close(io);
    var count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".js")) continue;
        count += 1;
        const source = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        defer gpa.free(source);
        const out_name = try std.fmt.allocPrint(gpa, "{s}.out", .{entry.name[0 .. entry.name.len - 3]});
        defer gpa.free(out_name);
        const expected = try dir.readFileAlloc(io, out_name, gpa, .limited(1 << 20));
        defer gpa.free(expected);
        const got = try runCollecting(source, .treewalk, .{ .max_steps = 50_000_000 });
        defer gpa.free(got);
        if (!std.mem.eql(u8, got, expected)) {
            std.debug.print("\n== {s} on the tree-walker, collecting at every safepoint\n-- expected (node)\n{s}-- got\n{s}", .{ entry.name, expected, got });
            failures += 1;
        }
    }
    try testing.expect(count > 50);
    try testing.expectEqual(@as(usize, 0), failures);
}

test "exceptions and limits mid-evaluation leave the shadow stack balanced and the heap sound" {
    // Each program fails deep inside held values (a nested call's argument list, a literal
    // under construction, a method's receiver); the run must end cleanly (the debug
    // assertion in exec checks the balance on every exit), on both engines.
    for ([_][]const u8{
        "function f(a, b) { return a + b; } print(f('x' + 1, [1, { k: 'y' + 2 }, nope]));",
        "let o = { a: 'x' + 1, b: [1, 2, { c: (function () { return missing; })() }] };",
        "let r = { v: 'r' + 1, m(x) { return this.v + x.y.z; } }; print(r.m({ y: null }));",
        "function d(n) { let s = 'd' + n; if (n === 0) return s + undefined.x; return s + d(n - 1); } d(30);",
        "let a = []; while (true) { a.push({ s: 'grow' + a.length, l: [a.length] }); }",
    }) |src| for ([_]zqjs.Engine{ .treewalk, .vm }) |engine| {
        // A small limit: collecting at every step costs one heap walk per step, so a heap
        // that grows to the limit costs (steps × heap); 64 KiB keeps that to milliseconds.
        const got = try runCollecting(src, engine, .{ .max_heap_bytes = 64 << 10 });
        defer testing.allocator.free(got);
        try testing.expect(std.mem.indexOf(u8, got, "Uncaught") != null or std.mem.indexOf(u8, got, "LimitExceeded") != null);
    };
}

fn runOnceCollecting(allocator: Allocator, source: []const u8, engine: zqjs.Engine) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = zqjs.runSource(allocator, "t", source, .{ .max_steps = 100_000 }, .{ .mode = .harness, .engine = engine, .collect_always = true }, &out.writer, &discard.writer) catch |e| switch (e) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
}

test "allocation failing at every point, with a collection at every safepoint" {
    // Error paths unwind through held values and registered roots: no leak, no stale root.
    for ([_][]const u8{
        "let o = { a: ['x' + 1, { b: 'y' + 2 }], m(k) { return this.a[k]; } }; print(o.m(0), [o.m(1)].join());",
        "function c(n) { let s = 'c' + n; return function () { return s + n; }; } let fs = [c(1), c(2)]; print(fs[0]() + fs[1]());",
    }) |src| for ([_]zqjs.Engine{ .treewalk, .vm }) |engine|
        try testing.checkAllAllocationFailures(testing.allocator, runOnceCollecting, .{ src, engine });
}

test "garbage under a small limit: the tree-walker runs to its step budget too" {
    for ([_]zqjs.Engine{ .treewalk, .vm }) |engine| {
        var got: std.Io.Writer.Allocating = .init(testing.allocator);
        defer got.deinit();
        var discard: std.Io.Writer.Discarding = .init(&.{});
        const source =
            \\let n = 0;
            \\while (true) {
            \\  let s = 'garbage ' + n;
            \\  let o = { s, list: [s, s + '!'], f: function () { return s; } };
            \\  n = n + o.list.length;
            \\}
        ;
        // The run allocates several times the 128 KiB limit, so reaching the step budget at
        // all means garbage was reclaimed. Kept small: in Debug every allocation goes through
        // std.testing.allocator, which records a stack trace for each one.
        _ = try zqjs.runSource(testing.allocator, "t", source, .{ .max_heap_bytes = 128 << 10, .max_steps = 50_000 }, .{ .mode = .harness, .engine = engine }, &got.writer, &discard.writer);
        try testing.expectEqualStrings("t: LimitExceeded(steps)\n", got.written());
    }
}

// ---------------------------------------------------------------- P3: stress infrastructure

test "the heap verifier passes after real collections and catches each kind of corruption" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const keep = try h.newObject(null);
    try h.storeProperty(keep, try h.internAscii("s"), .{ .string = try h.ascii("live") });
    const arr = try h.newArray(keep);
    try h.appendElement(arr, .{ .object = keep });
    try h.storeProperty(keep, try h.internAscii("a"), .{ .object = arr });
    for (0..50) |_| _ = try h.newObject(keep); // garbage
    h.collect(TestRoots{ .objs = &.{&keep.obj} }, TestRoots.mark);
    try h.verify(); // exact accounting, no dangling edge, clean atom table, empty gray list

    // Accounting: one byte off is caught.
    h.bytes += 1;
    try testing.expectError(error.AccountingMismatch, h.verify());
    h.bytes -= 1;
    // A gray list left non-empty.
    h.gray = &keep.obj;
    try testing.expectError(error.GrayListNotEmpty, h.verify());
    h.gray = null;
    // An edge from a live object to a collected one (a hand-made tombstone).
    var dead: heap.Object = .{ .obj = .{ .kind = .dead, .next = null }, .proto = null };
    keep.props.getPtr(try h.internAscii("a")).?.value = .{ .object = &dead };
    try testing.expectError(error.EdgeToCollectedObject, h.verify());
    keep.props.getPtr(try h.internAscii("a")).?.value = .{ .object = arr };
    // A non-atom in the atom table.
    const plain = try h.ascii("not an atom");
    try h.atoms.putNoClobber(h.allocator(), plain, {});
    try testing.expectError(error.AtomTableHoldsNonAtom, h.verify());
    _ = h.atoms.remove(plain);
    try h.verify();
}

test "stress builds: collected objects become tombstones that say what and which they were" {
    if (!heap.gc_stress) return error.SkipZigTest; // tombstones exist only under -Dgc-stress
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit(); // frees the tombstones too (testing.allocator checks for leaks)
    const a = try h.newObject(null);
    const s = try h.ascii("doomed");
    const b = try h.newArray(null);
    try testing.expect(a.obj.debug.id < s.obj.debug.id and s.obj.debug.id < b.obj.debug.id);
    const id = s.obj.debug.id;
    h.collect(TestRoots{ .objs = &.{&a.obj} }, TestRoots.mark);
    try testing.expectEqual(heap.Obj.Kind.object, a.obj.kind); // kept
    try testing.expectEqual(heap.Obj.Kind.dead, s.obj.kind); // collected: a tombstone
    try testing.expectEqual(heap.Obj.Kind.string, s.obj.debug.was);
    try testing.expectEqual(id, s.obj.debug.id);
    try testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("<collected>"), s.units); // poisoned, not freed memory
    try testing.expectEqual(heap.Obj.Kind.object, b.obj.debug.was); // an array is an object
    try testing.expect(b.kind == .ordinary and b.props.count() == 0); // storage released, nothing left to read
    try h.verify();
}

test "under -Dgc-stress every run collects at every safepoint, whatever the options say" {
    // Guards the mode against being weakened by accident: an option default of `false`
    // once silently turned it off for everything going through runSource.
    if (!heap.gc_stress) return error.SkipZigTest;
    const r = try runVm("let a = 1; let b = 2; print(a + b);", .{}, false);
    defer testing.allocator.free(r.out);
    try testing.expect(r.collections >= 8); // one per instruction, at least
}
