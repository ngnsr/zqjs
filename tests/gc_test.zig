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

test "watchdog: this binary fails, instead of hanging, if a test gets stuck" {
    support.watchdog(@src().file);
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
const support = @import("support.zig");
const heap = zqjs.heap;
const Allocator = std.mem.Allocator;

/// A heap-level root set for unit tests: marks the objects listed.
const TestRoots = struct {
    objs: []const *heap.Obj,
    fn mark(r: TestRoots, h: *heap.Heap) void {
        for (r.objs) |o| h.markObj(o);
    }
};

/// A major (full) collection: what M8's `collect` always was. The tests of full-heap
/// properties (exact reachability, weak atoms) use it; minor collections have their own.
fn collectMajor(h: *heap.Heap, roots: []const *heap.Obj) void {
    h.major_requested = true;
    h.collect(TestRoots{ .objs = roots }, TestRoots.mark);
}

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
    collectMajor(&h, &.{&root.obj}); // a minor one would keep the loose atom (promoted)
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
    h.collect(TestRoots{ .objs = &.{&keep.obj} }, TestRoots.mark); // minor
    try testing.expectEqual(@as(u32, 500), h.atoms.count()); // a minor one never frees an atom
    collectMajor(&h, &.{&keep.obj});
    h.gpa = testing.allocator;
    try testing.expectEqual(@as(u64, 1), h.stats.minor);
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
    for (0..5) |_| collectMajor(&h, &.{&o.obj});
    for (0..10_000) |i| {
        const k = try h.internAscii(std.fmt.bufPrint(&buf, "k{d}", .{i}) catch unreachable);
        try testing.expectEqual(@as(f64, @floatFromInt(i)), o.props.get(k).?.value.number); // same atom as the key
    }
    // delete o[k], collect, reuse k: a fresh atom works as the key.
    h.removeProperty(o, try h.internAscii("k7"));
    collectMajor(&h, &.{&o.obj});
    try h.storeProperty(o, try h.internAscii("k7"), .{ .number = 77 });
    try testing.expectEqual(@as(f64, 77), o.props.get(try h.internAscii("k7")).?.value.number);
    // Drop the object: the table shrinks back to its baseline, and every entry left is a
    // live object (the cleanup ran before the sweep freed anything).
    collectMajor(&h, &.{});
    try testing.expectEqual(baseline, h.atoms.count());
    try testing.expectEqual(@as(?*heap.Obj, null), h.young);
    try testing.expectEqual(@as(?*heap.Obj, null), h.old);
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
    collectMajor(&h, &.{&o.obj});
    var it = h.atoms.keyIterator();
    while (it.next()) |k| {
        var live = h.old; // after any collection, every survivor is old
        while (live) |obj| : (live = obj.next) {
            if (obj == &k.*.obj) break;
        } else return error.TestUnexpectedResult; // an entry that isn't a live object
    }
    try testing.expectEqual(@as(u32, 100), h.atoms.count());
}

test "scheduling: a collection is requested past next_gc, with headroom under the limit" {
    var h = heap.Heap.init(testing.allocator, .{ .max_heap_bytes = 1 << 20 });
    defer h.deinit();
    // M8.1: a minor collection after a nursery's worth (256 KiB), but never closer than
    // halfway to the limit; a major one once the heap left after a collection reaches
    // `schedule` of the last major's survivors.
    try testing.expectEqual(@as(usize, 256 * 1024), h.next_gc);
    try testing.expectEqual(@as(usize, 256 * 1024), h.next_major);
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

const ProgramAllocator = support.ProgramAllocator;
const endProgram = support.endProgram;

const VmRun = struct { out: []u8, err: ?anyerror, collections: u64, bytes_after: usize };

/// Runs `source` on the VM with a collection at every safepoint (`always`) or only when
/// requested; returns its output, its error and the collector's statistics.
fn runVm(source: []const u8, limits: zqjs.Limits, always: bool) !VmRun {
    var dbg: ProgramAllocator = .init;
    defer endProgram(&dbg);
    const gpa = dbg.allocator();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(testing.allocator); // returned: the caller frees it
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
    var dbg: ProgramAllocator = .init;
    defer endProgram(&dbg);
    _ = try zqjs.runSource(dbg.allocator(), "t", source, limits, .{ .mode = .harness, .engine = engine, .collect_always = true }, &got.writer, &discard.writer);
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
        // all means garbage was reclaimed. (On the non-tracing allocator: on
        // std.testing.allocator, a stack trace per allocation made this the slowest test.)
        var dbg: ProgramAllocator = .init;
        defer endProgram(&dbg);
        _ = try zqjs.runSource(dbg.allocator(), "t", source, .{ .max_heap_bytes = 128 << 10, .max_steps = 50_000 }, .{ .mode = .harness, .engine = engine }, &got.writer, &discard.writer);
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

// ---------------------------------------------------------------- P4: acceptance

const EngineStats = struct { atoms: u32, collections: u64, peak: usize, live: usize, err: ?anyerror, majors: u64 = 0, limit: ?zqjs.Limit = null };

/// Runs `source` on `engine` (normal scheduling, unless stress) and returns the heap's state.
fn runStats(source: []const u8, engine: zqjs.Engine, limits: zqjs.Limits) !EngineStats {
    var dbg: ProgramAllocator = .init;
    defer endProgram(&dbg);
    const gpa = dbg.allocator();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var rt = zqjs.Runtime.init(gpa, limits, &discard.writer);
    defer rt.deinit();
    var d: zqjs.Diagnostic = .{};
    const script = try zqjs.parse(arena.allocator(), source, limits, &d);
    const res = try zqjs.resolve(arena.allocator(), script, &d);
    var err: ?anyerror = null;
    switch (engine) {
        .treewalk => zqjs.interpret(&rt, script, res) catch |e| {
            err = e;
        },
        .vm => {
            var proto = try zqjs.compile(gpa, &rt.heap, script, res, limits, &d);
            defer proto.deinit(gpa);
            var vm = try zqjs.Vm.init(&rt, &proto);
            defer vm.deinit();
            vm.run() catch |e| {
                err = e;
            };
        },
    }
    const majors = rt.heap.stats.collections - rt.heap.stats.minor; // during the run
    rt.heap.major_requested = true; // the run is over: only the runtime's own roots remain,
    rt.collect(); // and only a major collection frees old objects and atoms
    return .{ .atoms = rt.heap.atoms.count(), .collections = rt.heap.stats.collections, .peak = rt.heap.peak, .live = rt.heap.bytes, .err = err, .majors = majors, .limit = rt.limitHit() };
}

test "weak atoms are reclaimed in real programs, on both engines" {
    // 20 000 distinct keys, each on an object dropped at once: without weak atoms the table
    // would end with 20 000 entries; with them, only the realm's names survive.
    const source = "for (let i = 0; i < 20000; i++) { let o = {}; o['key' + i] = i; o.fixed = o['key' + i]; }";
    for ([_]zqjs.Engine{ .treewalk, .vm }) |engine| {
        const r = try runStats(source, engine, .{});
        try testing.expectEqual(@as(?anyerror, null), r.err);
        try testing.expect(r.collections > 0);
        testing.expect(r.atoms < 50) catch |e| {
            std.debug.print("{s}: {d} atoms left\n", .{ @tagName(engine), r.atoms });
            return e;
        };
    }
}

test "both engines reclaim garbage and keep reachable objects in one program" {
    // Garbage of every kind next to a growing live structure that is checked at the end.
    const source =
        \\let live = [];
        \\for (let i = 0; i < 3000; i++) {
        \\  let tmp = { s: 'garbage ' + i, f: function () { return tmp; }, l: [i, i] };
        \\  if (i % 100 === 0) live.push({ i, s: 'kept ' + i, f: function () { return i; } });
        \\}
        \\let sum = 0;
        \\for (let j = 0; j < live.length; j++) sum = sum + live[j].f() + live[j].s.length;
        \\if (sum !== 43758) undefinedCheck; // node: 43758
    ;
    for ([_]zqjs.Engine{ .treewalk, .vm }) |engine| {
        const r = try runStats(source, engine, .{ .max_heap_bytes = 256 << 10 });
        try testing.expectEqual(@as(?anyerror, null), r.err); // the check at the end passed
        try testing.expect(r.collections > 0);
        try testing.expect(r.peak <= 256 << 10);
    }
}

test "statistics are exact: collections, bytes freed, peak and live" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const keep = try h.newObject(null);
    var freed: u64 = 0;
    var highest: usize = h.bytes;
    for (0..3) |round| {
        for (0..40 * (round + 1)) |_| {
            _ = try h.ascii("garbage string");
            highest = @max(highest, h.bytes);
        }
        const before = h.bytes;
        h.collect(TestRoots{ .objs = &.{&keep.obj} }, TestRoots.mark);
        freed += before - h.bytes;
        try testing.expectEqual(@as(u64, round + 1), h.stats.collections);
        try testing.expectEqual(freed, h.stats.bytes_freed);
        try testing.expectEqual(h.bytes, h.stats.live_after_last);
        try h.verify();
    }
    try testing.expectEqual(highest, h.peak);
    // `keep` survives once: then it's old, and minor collections don't trace old objects.
    try testing.expectEqual(@as(u64, 1), h.stats.marked);
    try testing.expectEqual(@as(u64, 3), h.stats.minor);
    try testing.expectEqual(@as(u64, 40 + 80 + 120), h.stats.swept); // every garbage string
}

// ---------------------------------------------------------------- M8.1 P1: generations

fn utf16(comptime text: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

/// An array of `n` references to one string (each slot is a child, as in a real array of
/// objects), promoted by a collection.
fn oldArray(h: *heap.Heap, n: usize) !*heap.Object {
    const arr = try h.newArray(null);
    const filler = try h.ascii("old");
    for (0..n) |_| try h.appendElement(arr, .{ .string = filler });
    try collectMinor(h, &.{&arr.obj});
    try testing.expect(arr.obj.old);
    return arr;
}

/// A minor collection, whatever the schedule says (a card test that silently got a
/// major one would pass without scanning any card). Asserts it was minor.
fn collectMinor(h: *heap.Heap, roots: []const *heap.Obj) !void {
    const saved = h.next_major;
    const minors = h.stats.minor;
    h.next_major = std.math.maxInt(usize);
    h.collect(TestRoots{ .objs = roots }, TestRoots.mark);
    h.next_major = saved;
    try testing.expectEqual(minors + 1, h.stats.minor);
}

fn rememberedLength(h: *const heap.Heap) usize {
    var n: usize = 0;
    var it = h.remembered;
    while (it) |obj| : (it = obj.gray_next) n += 1;
    return n;
}

test "cards: a young store at a card boundary is found, and only its card is scanned" {
    const card = zqjs.limits.card_elements;
    const indices = [_]usize{ 0, card - 1, card, 2 * card - 1, 2 * card, 4 * card - 1 };
    for (indices) |i| {
        var h = heap.Heap.init(testing.allocator, .{});
        defer h.deinit();
        const arr = try oldArray(&h, 4 * card);
        const young = try h.ascii("young");
        h.storeElement(arr, i, .{ .string = young });
        try h.verify();
        const before = h.stats.remembered_children;
        try collectMinor(&h, &.{&arr.obj}); // minor: the root is old
        try testing.expectEqual(@as(u64, card), h.stats.remembered_children - before); // one card, no other
        try testing.expect(young.obj.old);
        try testing.expectEqualSlices(u16, utf16("young"), arr.kind.array.items[i].string.units);
        try h.verifyCollected();
    }
    // All six at once: four distinct cards.
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const arr = try oldArray(&h, 4 * card);
    for (indices) |i| h.storeElement(arr, i, .{ .string = try h.ascii("young") });
    const before = h.stats.remembered_children;
    try collectMinor(&h, &.{&arr.obj});
    try testing.expectEqual(@as(u64, 4 * card), h.stats.remembered_children - before);
    for (indices) |i| try testing.expectEqualSlices(u16, utf16("young"), arr.kind.array.items[i].string.units);
    try h.verifyCollected();
}

test "cards: an array remembered before its first bitmap gets an all-dirty one (the hole)" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const arr = try oldArray(&h, 390); // capacity 398: no bitmap yet
    try testing.expect(h.cards.get(arr) == null);
    const young = try h.ascii("young");
    h.storeElement(arr, 3, .{ .string = young }); // remembered as a whole
    for (0..200) |i| try h.appendElement(arr, .{ .number = @floatFromInt(i) }); // first bitmap
    try testing.expect(h.cards.get(arr) != null);
    try h.verify(); // I-gen2: index 3's card is dirty
    try collectMinor(&h, &.{&arr.obj});
    try testing.expect(young.obj.old);
    try testing.expectEqualSlices(u16, utf16("young"), arr.kind.array.items[3].string.units);
    try h.verifyCollected();
}

test "cards: the bitmap grows with the array, keeping dirty bits and adding clean ones" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const arr = try oldArray(&h, 1000);
    try testing.expectEqual(@as(usize, 1), h.cards.get(arr).?.len);
    const young = try h.ascii("young");
    h.storeElement(arr, 0, .{ .string = young });
    for (0..40_000) |i| try h.appendElement(arr, .{ .number = @floatFromInt(i) }); // several resizes
    const words = h.cards.get(arr).?;
    try testing.expectEqual(@as(usize, 2), words.len); // 64 cards of 512 per word
    try testing.expectEqual(@as(u64, 1), words[0]);
    try testing.expectEqual(@as(u64, 0), words[1]);
    try h.verify();
    try collectMinor(&h, &.{&arr.obj});
    try testing.expect(young.obj.old);
    try h.verifyCollected();
}

test "cards: pop and shrink after a young store leave nothing stale" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const arr = try oldArray(&h, 1024);
    h.storeElement(arr, 600, .{ .string = try h.ascii("dropped") });
    h.storeElement(arr, 1023, .{ .string = try h.ascii("popped") });
    _ = h.popElement(arr);
    h.shrinkElements(arr, 100); // the dirty cards are now past the length
    const swept = h.stats.swept;
    try collectMinor(&h, &.{&arr.obj});
    try testing.expectEqual(swept + 2, h.stats.swept); // both strings are garbage now
    try h.verifyCollected(); // and every card is clean
}

test "cards: a carded array's bitmap goes with it, in a minor and in a major collection" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    // The side table keeps its bucket storage once it has any (as the atom table does), so
    // measure from after a first carded array has come and gone.
    const first = try h.newArray(null);
    for (0..2000) |i| try h.appendElement(first, .{ .number = @floatFromInt(i) });
    try collectMinor(&h, &.{});
    const base = h.bytes;
    // Young and carded, then garbage: freed by a minor collection.
    const young = try h.newArray(null);
    for (0..2000) |i| try h.appendElement(young, .{ .number = @floatFromInt(i) });
    try testing.expectEqual(@as(u32, 1), h.cards.count());
    try collectMinor(&h, &.{});
    try testing.expectEqual(@as(u32, 0), h.cards.count());
    try testing.expectEqual(base, h.bytes); // the bitmap's bytes given back too
    try h.verifyCollected();
    // Old, carded, dirty and remembered, then garbage: freed by a major collection.
    const old = try oldArray(&h, 2000);
    h.storeElement(old, 1500, .{ .string = try h.ascii("young") });
    try testing.expectEqual(@as(u32, 1), h.cards.count());
    collectMajor(&h, &.{});
    try testing.expectEqual(@as(u32, 0), h.cards.count());
    try testing.expectEqual(@as(?*heap.Obj, null), h.remembered);
    try testing.expectEqual(base, h.bytes);
    try h.verifyCollected();
}

fn growRememberedArray(gpa: Allocator) !void {
    var h = heap.Heap.init(gpa, .{});
    defer h.deinit();
    const arr = try oldArray(&h, 390);
    h.storeElement(arr, 3, .{ .string = try h.ascii("young") });
    // Whatever allocation fails, the heap is left consistent: bitmap and elements agree.
    errdefer h.verify() catch |e| std.debug.panic("heap unsound after a failed append: {s}", .{@errorName(e)});
    for (0..300) |i| try h.appendElement(arr, .{ .number = @floatFromInt(i) });
    try collectMinor(&h, &.{&arr.obj});
    try testing.expectEqualSlices(u16, utf16("young"), arr.kind.array.items[3].string.units);
    try h.verifyCollected();
}

test "cards: allocation failing at every point of a bitmap's creation and growth" {
    try testing.checkAllAllocationFailures(testing.allocator, growRememberedArray, .{});
}

test "minor collections never free an atom; promotion keeps nothing else alive; a major one frees it" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const baseline = h.atoms.count();
    const garbage = try h.newObject(null);
    const key = try h.internAscii("dynamic key 1");
    try h.storeProperty(garbage, key, .{ .object = try h.newObject(null) });
    const swept = h.stats.swept;
    try collectMinor(&h, &.{}); // minor
    try testing.expectEqual(@as(u64, 1), h.stats.minor);
    try testing.expect(key.obj.old); // promoted: the table still holds it
    try testing.expectEqual(swept + 2, h.stats.swept); // the object and its value: freed
    try testing.expectEqual(key, try h.internAscii("dynamic key 1")); // the same atom
    try h.verifyCollected();
    collectMajor(&h, &.{});
    try testing.expectEqual(baseline, h.atoms.count()); // only a major collection drops it
    try h.verifyCollected();
}

test "remembered set: an owner is listed once however often it stores, and cleared by the next collection" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const o = try h.newObject(null);
    try collectMinor(&h, &.{&o.obj});
    const key = try h.internAscii("k");
    for (0..3) |_| try h.storeProperty(o, key, .{ .string = try h.ascii("young") });
    try testing.expectEqual(@as(usize, 1), rememberedLength(&h));
    try h.verify();
    try collectMinor(&h, &.{&o.obj});
    try testing.expectEqual(@as(usize, 0), rememberedLength(&h));
    try testing.expect(!o.obj.remembered);
    try h.verifyCollected();
    // A young reference stored, then overwritten: the owner is still remembered, but the
    // scan reads its current contents, so the young string is freed.
    try h.storeProperty(o, key, .{ .string = try h.ascii("overwritten") });
    try h.storeProperty(o, key, .{ .number = 1 });
    try testing.expect(o.obj.remembered);
    const swept = h.stats.swept;
    try collectMinor(&h, &.{&o.obj});
    try testing.expectEqual(swept + 1, h.stats.swept);
    try h.verifyCollected();
}

test "major collection: remembered owners and dirty cards are reset, survivors all old" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const arr = try oldArray(&h, 1024);
    const o = try h.newObject(null);
    try collectMinor(&h, &.{ &arr.obj, &o.obj });
    h.storeElement(arr, 700, .{ .string = try h.ascii("in a card") });
    try h.storeProperty(o, try h.internAscii("young key"), .{ .string = try h.ascii("young value") });
    _ = try h.internAscii("dead atom");
    try testing.expectEqual(@as(usize, 2), rememberedLength(&h));
    collectMajor(&h, &.{ &arr.obj, &o.obj });
    try h.verifyCollected(); // nothing young, remembered or dirty; the atom table is sound
    try testing.expectEqualSlices(u16, utf16("in a card"), arr.kind.array.items[700].string.units);
    try testing.expect(arr.kind.array.items[700].string.obj.old);
}

// ---- the broken builds: `zig build gc-mutants` runs these against each heap.Mutation,
// and each must see the verifier catch its mutant. In normal builds they pass trivially.

/// `result` must be `caught` in the build with mutation `m`, and fine otherwise.
/// (In another mutant's build the scenario may break differently: it is skipped there.)
/// The first line of each mutation test: in another mutant's build its setup may already
/// break (that mutant's own test is the one meant to catch it), so it doesn't run there.
fn onlyIn(comptime m: heap.Mutation) !void {
    if (heap.mutation != .none and heap.mutation != m) return error.SkipZigTest;
}

fn expectCaught(comptime m: heap.Mutation, caught: heap.Heap.VerifyError, result: heap.Heap.VerifyError!void) !void {
    if (heap.mutation == m) return testing.expectError(caught, result);
    if (heap.mutation != .none) return error.SkipZigTest;
    return result;
}

test "mutation: an element store without its barrier fails I-gen2" {
    try onlyIn(.no_element_barrier);
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const arr = try oldArray(&h, 10);
    h.storeElement(arr, 0, .{ .string = try h.ascii("young") });
    try expectCaught(.no_element_barrier, error.UnrememberedOldToYoungEdge, h.verify());
}

test "mutation: a young element store that doesn't dirty its card fails I-gen2" {
    try onlyIn(.no_card_set);
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const arr = try oldArray(&h, 1024);
    h.storeElement(arr, 700, .{ .string = try h.ascii("young") });
    try expectCaught(.no_card_set, error.CleanCardOverYoungElement, h.verify());
}

test "mutation: a remembered bit left set after the scan fails I-gen4" {
    try onlyIn(.keep_remembered_bit);
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    h.verify_always = false; // the test verifies itself, instead of a panic in collect
    const o = try h.newObject(null);
    try collectMinor(&h, &.{&o.obj});
    try h.storeProperty(o, try h.internAscii("k"), .{ .string = try h.ascii("young") });
    try collectMinor(&h, &.{&o.obj});
    try expectCaught(.keep_remembered_bit, error.RememberedListCorrupt, h.verifyCollected());
}

test "mutation: a clean first bitmap for a remembered array fails I-gen2 (the hole)" {
    try onlyIn(.clean_first_bitmap);
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const arr = try oldArray(&h, 390);
    h.storeElement(arr, 3, .{ .string = try h.ascii("young") });
    for (0..200) |i| try h.appendElement(arr, .{ .number = @floatFromInt(i) });
    try expectCaught(.clean_first_bitmap, error.CleanCardOverYoungElement, h.verify());
}

test "mutation: a minor collection that frees atoms leaves the table dangling" {
    try onlyIn(.minor_frees_atoms);
    // Only tombstones make the dangling entry safe to look at.
    if (heap.mutation == .minor_frees_atoms and !heap.gc_stress) return error.SkipZigTest;
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    h.verify_always = false;
    _ = try h.internAscii("dynamic key");
    try collectMinor(&h, &.{});
    try expectCaught(.minor_frees_atoms, error.AtomTableHoldsCollectedObject, h.verifyCollected());
}

test "dead dynamic keys drive major collections: atoms can't pile up past the heap limit" {
    // Minor collections promote every atom (they never free one), so 60 000 distinct keys
    // on objects that die young become old garbage. They count in the heap like any
    // promotion, so major collections come and free them: the run fits in 1 MiB. (Each
    // key costs ~110 bytes as an atom: kept, they would need ~6.5 MiB.)
    const source = "for (let i = 0; i < 60000; i++) { let o = {}; o['dynamic key ' + i] = i; }";
    for ([_]zqjs.Engine{ .vm, .treewalk }) |engine| {
        const r = try runStats(source, engine, .{ .max_heap_bytes = 1 << 20 });
        try testing.expectEqual(@as(?anyerror, null), r.err);
        try testing.expect(r.majors > 0);
        try testing.expect(r.peak <= 1 << 20);
        try testing.expect(r.atoms < 50); // and the final major one leaves only the realm's
    }
}

// ---------------------------------------------------------------- M8.1 P2b: property cards

fn keyName(buf: []u8, i: usize) []const u8 {
    return std.fmt.bufPrint(buf, "k{d}", .{i}) catch unreachable;
}

/// An object with `n` properties k0…k(n-1), all holding one string, promoted.
fn oldDict(h: *heap.Heap, n: usize) !*heap.Object {
    const o = try h.newObject(null);
    const filler = try h.ascii("old");
    var buf: [16]u8 = undefined;
    for (0..n) |i| try h.storeProperty(o, try h.internAscii(keyName(&buf, i)), .{ .string = filler });
    try collectMinor(h, &.{&o.obj});
    try testing.expect(o.obj.old);
    return o;
}

/// Interns keys k`from`…k(`to`-1) and promotes them (a minor collection promotes every
/// atom), so inserting them later stores nothing young: then only the rule under test can
/// dirty a card. (New keys are young atoms, and the card one of them dirties can hide a
/// missing rule: the hole tests passed without the hole fix until they used this.)
fn oldKeys(h: *heap.Heap, root: *heap.Object, from: usize, to: usize) !void {
    var buf: [16]u8 = undefined;
    for (from..to) |i| _ = try h.internAscii(keyName(&buf, i));
    try collectMinor(h, &.{&root.obj});
}

fn valueAt(o: *heap.Object, i: usize) []const u16 {
    return o.props.values()[i].value.string.units;
}

test "property cards: a young value under an existing key at a card boundary dirties only its card" {
    var dbg: ProgramAllocator = .init;
    defer endProgram(&dbg);
    const card = zqjs.limits.card_elements;
    const indices = [_]usize{ 0, card - 1, card, 2 * card - 1, 2 * card, 4 * card - 1 };
    var buf: [16]u8 = undefined;
    for (indices) |i| {
        var h = heap.Heap.init(dbg.allocator(), .{});
        defer h.deinit();
        const o = try oldDict(&h, 4 * card);
        try h.storeProperty(o, try h.internAscii(keyName(&buf, i)), .{ .string = try h.ascii("young") }); // an update
        try h.verify();
        const before = h.stats.remembered_children;
        try collectMinor(&h, &.{&o.obj});
        try testing.expectEqual(@as(u64, 2 * card), h.stats.remembered_children - before); // one card: keys and values
        try testing.expectEqualSlices(u16, utf16("young"), valueAt(o, i));
        try h.verifyCollected();
    }
    var h = heap.Heap.init(dbg.allocator(), .{});
    defer h.deinit();
    const o = try oldDict(&h, 4 * card);
    for (indices) |i| try h.storeProperty(o, try h.internAscii(keyName(&buf, i)), .{ .string = try h.ascii("young") });
    const before = h.stats.remembered_children;
    try collectMinor(&h, &.{&o.obj});
    try testing.expectEqual(@as(u64, 4 * 2 * card), h.stats.remembered_children - before); // four distinct cards
    for (indices) |i| try testing.expectEqualSlices(u16, utf16("young"), valueAt(o, i));
    try h.verifyCollected();
}

test "property cards: a new young key with an old value dirties the card it is appended to" {
    const card = zqjs.limits.card_elements;
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const o = try oldDict(&h, 4 * card - 1);
    const old_value = o.props.values()[0].value;
    try h.storeProperty(o, try h.internAscii("a fresh key"), old_value); // entry 4·card − 1
    try testing.expect(o.obj.remembered);
    try h.verify();
    const before = h.stats.remembered_children;
    try collectMinor(&h, &.{&o.obj});
    try testing.expectEqual(@as(u64, 2 * card), h.stats.remembered_children - before); // the last card only
    try h.verifyCollected();
}

test "property cards: deletes at the start, middle and end shift young entries across cards safely" {
    const card = zqjs.limits.card_elements;
    var buf: [16]u8 = undefined;
    for ([_]usize{ 0, card + card / 2, 4 * card - 1 }) |removed| {
        var h = heap.Heap.init(testing.allocator, .{});
        defer h.deinit();
        const o = try oldDict(&h, 4 * card);
        // Young values at the first two entries of card 2 and in card 3: a delete before
        // them moves 2·card down into card 1, and the others down one place.
        const young = [_]usize{ 2 * card, 2 * card + 1, 3 * card };
        for (young) |i| try h.storeProperty(o, try h.internAscii(keyName(&buf, i)), .{ .string = try h.ascii("young") });
        h.removeProperty(o, try h.internAscii(keyName(&buf, removed)));
        try h.verify(); // PC8: every young entry, wherever it moved, is under a dirty card
        try collectMinor(&h, &.{&o.obj});
        for (young) |i| {
            const k = try h.internAscii(keyName(&buf, i));
            try testing.expectEqualSlices(u16, utf16("young"), o.props.get(k).?.value.string.units);
        }
        try h.verifyCollected();
    }
}

test "property cards: a table remembered before its first bitmap gets an all-dirty one (the hole)" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const o = try oldDict(&h, 400);
    try testing.expect(h.prop_cards.get(o) == null);
    var buf: [16]u8 = undefined;
    try oldKeys(&h, o, 400, 600);
    try h.storeProperty(o, try h.internAscii(keyName(&buf, 3)), .{ .string = try h.ascii("young") }); // remembered whole
    for (400..600) |i| try h.storeProperty(o, try h.internAscii(keyName(&buf, i)), .null); // first bitmap at 512
    try testing.expect(h.prop_cards.get(o) != null);
    try h.verify();
    try collectMinor(&h, &.{&o.obj});
    try testing.expectEqualSlices(u16, utf16("young"), valueAt(o, 3));
    try h.verifyCollected();
}

test "property cards: the bitmap grows over many reallocations; indices stay valid" {
    var dbg: ProgramAllocator = .init;
    defer endProgram(&dbg);
    var h = heap.Heap.init(dbg.allocator(), .{});
    defer h.deinit();
    const o = try oldDict(&h, 1000);
    var buf: [16]u8 = undefined;
    // Old keys for the entries to come (a minor collection promotes every atom), so only
    // the young value below dirties anything.
    for (1000..40_000) |i| _ = try h.internAscii(keyName(&buf, i));
    try collectMinor(&h, &.{&o.obj});
    try h.storeProperty(o, try h.internAscii(keyName(&buf, 0)), .{ .string = try h.ascii("young") });
    for (1000..40_000) |i| try h.storeProperty(o, try h.internAscii(keyName(&buf, i)), .null); // buffer moves many times
    const words = h.prop_cards.get(o).?;
    try testing.expectEqual(@as(usize, 2), words.len);
    try testing.expectEqual(@as(u64, 1), words[0]);
    try testing.expectEqual(@as(u64, 0), words[1]);
    try h.verify();
    try collectMinor(&h, &.{&o.obj});
    try testing.expectEqualSlices(u16, utf16("young"), valueAt(o, 0));
    try h.verifyCollected();
}

test "property cards: allocation failing at every point of a bitmap's creation" {
    // The table is built on a working allocator; then each allocation of the inserts that
    // take it past 512 entries (the bitmap, the table's growth, new atoms) fails in turn,
    // and the heap must stay sound, the young value reachable. (checkAllAllocationFailures
    // would rebuild the whole table once per allocation: ~1000 reruns, 89 s.)
    var dbg: ProgramAllocator = .init;
    defer endProgram(&dbg);
    var buf: [16]u8 = undefined;
    var nth: usize = 0;
    while (true) : (nth += 1) {
        var failing = testing.FailingAllocator.init(dbg.allocator(), .{});
        var h = heap.Heap.init(failing.allocator(), .{});
        defer h.deinit();
        const o = try oldDict(&h, 500);
        try h.storeProperty(o, try h.internAscii(keyName(&buf, 3)), .{ .string = try h.ascii("young") });
        failing.fail_index = failing.alloc_index + nth;
        const inserted: anyerror!void = for (500..530) |i| {
            const k = h.internAscii(keyName(&buf, i)) catch |e| break e;
            h.storeProperty(o, k, .null) catch |e| break e;
        };
        inserted catch |e| try testing.expectEqual(error.OutOfMemory, e);
        try h.verify(); // bitmap and table consistent whatever failed
        failing.fail_index = std.math.maxInt(usize);
        try collectMinor(&h, &.{&o.obj});
        try testing.expectEqualSlices(u16, utf16("young"), valueAt(o, 3));
        try h.verifyCollected();
        if (!failing.has_induced_failure) break; // every allocation of the inserts has failed once
    }
    try testing.expect(nth > 3);
}

test "property cards: a table's bitmap goes with it, in a minor and in a major collection" {
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    var buf: [16]u8 = undefined;
    // Warm the side table (its buckets stay), and the atoms k0…k599 (minors promote them).
    const first = try h.newObject(null);
    for (0..600) |i| try h.storeProperty(first, try h.internAscii(keyName(&buf, i)), .null);
    try collectMinor(&h, &.{});
    const base = h.bytes;
    const young = try h.newObject(null);
    for (0..600) |i| try h.storeProperty(young, try h.internAscii(keyName(&buf, i)), .null);
    try testing.expectEqual(@as(u32, 1), h.prop_cards.count());
    try collectMinor(&h, &.{});
    try testing.expectEqual(@as(u32, 0), h.prop_cards.count());
    try testing.expectEqual(base, h.bytes);
    try h.verifyCollected();
    const old = try h.newObject(null);
    for (0..600) |i| try h.storeProperty(old, try h.internAscii(keyName(&buf, i)), .null);
    try collectMinor(&h, &.{&old.obj});
    try h.storeProperty(old, try h.internAscii(keyName(&buf, 550)), .{ .string = try h.ascii("young") });
    collectMajor(&h, &.{});
    try testing.expectEqual(@as(u32, 0), h.prop_cards.count());
    try h.verifyCollected();
}

test "mutation: a young property store that doesn't dirty its card fails PC1" {
    try onlyIn(.no_prop_card_set);
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const o = try oldDict(&h, 1024);
    var buf: [16]u8 = undefined;
    try h.storeProperty(o, try h.internAscii(keyName(&buf, 700)), .{ .string = try h.ascii("young") });
    try expectCaught(.no_prop_card_set, error.CleanCardOverYoungProperty, h.verify());
}

test "mutation: a delete that doesn't dirty the shifted cards fails PC1" {
    try onlyIn(.no_dirty_on_remove);
    const card = zqjs.limits.card_elements;
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const o = try oldDict(&h, 4 * card);
    var buf: [16]u8 = undefined;
    try h.storeProperty(o, try h.internAscii(keyName(&buf, 2 * card)), .{ .string = try h.ascii("young") });
    h.removeProperty(o, try h.internAscii(keyName(&buf, 0))); // moves it to 2·card − 1: card 1
    try expectCaught(.no_dirty_on_remove, error.CleanCardOverYoungProperty, h.verify());
}

test "mutation: a clean first property bitmap for a remembered table fails PC1 (the hole)" {
    try onlyIn(.clean_first_prop_bitmap);
    var h = heap.Heap.init(testing.allocator, .{});
    defer h.deinit();
    const o = try oldDict(&h, 400);
    var buf: [16]u8 = undefined;
    try oldKeys(&h, o, 400, 600);
    try h.storeProperty(o, try h.internAscii(keyName(&buf, 3)), .{ .string = try h.ascii("young") });
    for (400..600) |i| try h.storeProperty(o, try h.internAscii(keyName(&buf, i)), .null);
    try expectCaught(.clean_first_prop_bitmap, error.CleanCardOverYoungProperty, h.verify());
}

// ---------------------------------------------------------------- M8.1 AS5: adaptive scheduling

test "scheduling (AS5) T1: for every f, growth stays within its share of the room, without overflow" {
    for ([_]usize{ 256 << 10, 1 << 20, 64 << 20, std.math.maxInt(usize) }) |limit| {
        for ([_]u8{ 1, 2, 4 }) |f| {
            var h = heap.Heap.init(testing.allocator, .{ .max_heap_bytes = limit });
            defer h.deinit();
            h.growth = f;
            const share: usize = if (f > 1) 4 else 2; // the quarter-room cap
            for ([_]usize{ 0, 1, limit / 8, limit / 2, limit -| 1, limit }) |live| {
                const next = h.schedule(live);
                try testing.expect(next >= live);
                try testing.expect(next <= limit);
                try testing.expect(next - live <= (limit - live) / share);
            }
        }
    }
}

test "scheduling (AS5): f doubles to 4 while majors free little, holds in between, resets after one that frees half" {
    var dbg: ProgramAllocator = .init;
    defer endProgram(&dbg);
    var h = heap.Heap.init(dbg.allocator(), .{});
    defer h.deinit();
    const keep = try h.newArray(null);
    for (0..2000) |_| try h.appendElement(keep, .{ .string = try h.ascii("live data, kept") });
    try testing.expectEqual(@as(u8, 1), h.growth);
    for ([_]u8{ 2, 4, 4 }) |want| { // nothing to free: < 10% each time, capped at 4
        collectMajor(&h, &.{&keep.obj});
        try testing.expectEqual(want, h.growth);
    }
    h.shrinkElements(keep, 1400); // ~25% of the heap becomes garbage: between 10% and 50%
    collectMajor(&h, &.{&keep.obj});
    try testing.expectEqual(@as(u8, 4), h.growth);
    h.shrinkElements(keep, 300); // most of it: ≥ 50%
    collectMajor(&h, &.{&keep.obj});
    try testing.expectEqual(@as(u8, 1), h.growth);
}

/// T2's mutator: roots[0..ring_len] are a ring of objects that live through a collection and
/// then die old; the next two slots hold the latest surviving bursts (so reachable data stays
/// bounded: kept for good, bursts would fill the heap until even small allocations fail,
/// legitimately); the rest are kept for good. A safepoint collects when one was requested,
/// as an engine does, and checks the trigger it leaves behind.
const BurstSim = struct {
    h: *heap.Heap,
    roots: std.ArrayList(*heap.Obj) = .empty,
    filler: []const u8,
    const ring_len = 8;

    fn safepoint(sim: *BurstSim) !void {
        const h = sim.h;
        if (h.collect_requested) h.collect(TestRoots{ .objs = sim.roots.items }, TestRoots.mark);
        try testing.expect(h.bytes <= h.max_bytes); // HL1
        const b = h.stats.live_after_last;
        try testing.expect(h.next_gc <= b + (h.max_bytes - b) / 2); // the room HL2 rests on
    }

    /// One garbage allocation, one ring replacement, a safepoint.
    fn churn(sim: *BurstSim, i: usize) !void {
        _ = try sim.h.ascii("short-lived garbage");
        sim.roots.items[i % ring_len] = &(try sim.h.ascii("dies old, after a collection")).obj;
        try sim.safepoint();
    }

    /// A string whose charge is at most `bytes` (null if even an empty one costs more).
    fn burst(sim: *BurstSim, bytes: usize) !?*heap.String {
        const fixed = @sizeOf(heap.String) + 2 * heap.per_allocation_overhead;
        if (bytes < fixed) return null;
        const units = @min((bytes - fixed) / 2, sim.filler.len);
        return try sim.h.newString(&.{.{ .ascii = sim.filler[0..units] }});
    }
};

test "scheduling (AS5) T2: bursts at the HL2 bound always fit, surviving or not, for every f; HL3 failures are exact" {
    const limit = 1 << 20;
    const filler = try testing.allocator.alloc(u8, limit / 2);
    defer testing.allocator.free(filler);
    @memset(filler, 'x');
    for ([_]?u8{ 1, 2, 4, null }) |pinned| { // null: adaptive
        var dbg: ProgramAllocator = .init;
        defer endProgram(&dbg);
        var h = heap.Heap.init(dbg.allocator(), .{ .max_heap_bytes = limit });
        defer h.deinit();
        if (pinned) |f| {
            h.growth = f;
            h.adapt_growth = false;
        }
        var sim: BurstSim = .{ .h = &h, .filler = filler };
        defer sim.roots.deinit(testing.allocator);
        const placeholder = try h.ascii("ring slot");
        for (0..BurstSim.ring_len + 2) |_| try sim.roots.append(testing.allocator, &placeholder.obj);
        // Phase A: reachable data to ~40% of the limit, with churn and old garbage.
        var i: usize = 0;
        while (h.stats.live_after_last < limit * 2 / 5) : (i += 1) {
            try sim.churn(i);
            try sim.roots.append(testing.allocator, &(try h.newString(&.{.{ .ascii = filler[0..500] }})).obj);
        }
        // Phase B (HL2): right after a safepoint, at a different point between collections
        // each time, a burst of exactly (L − B)/2. Every other one survives (into one of two
        // slots, so it lives through collections and later dies old).
        var bursts: usize = 0;
        for (0..400) |n| {
            for (0..n % 7) |k| try sim.churn(i + k);
            i += 7;
            const b = h.stats.live_after_last;
            const big = (try sim.burst((limit - b) / 2)) orelse break; // the room is used up by kept bursts
            if (n % 2 == 0) sim.roots.items[BurstSim.ring_len + (n / 2) % 2] = &big.obj;
            bursts += 1;
            try sim.safepoint();
        }
        try testing.expect(bursts > 20);
        // Phase C (HL3): once a major collection has made R exact, a burst of L − R + 1
        // can't fit under any schedule. It fails cleanly, and the heap stays usable.
        collectMajor(&h, sim.roots.items);
        const reachable = h.bytes;
        try testing.expectError(error.LimitExceeded, sim.burst(limit - reachable + 1 + @sizeOf(heap.String) + 2 * heap.per_allocation_overhead));
        try testing.expectEqual(zqjs.Limit.heap_bytes, h.limit_hit.?);
        try h.verify();
        try testing.expect((try sim.burst((limit - h.stats.live_after_last) / 2)) != null);
    }
}

test "scheduling (AS5) T3: programs with bursts that fit complete; surviving bursts past the limit fail as LimitExceeded" {
    // (a) A ~100 KB join every iteration, half of them kept, among churn and old garbage at
    // shifting phases: within (L − B)/2 throughout, so it must finish.
    const fits =
        \\let part = ''; for (let j = 0; j < 500; j++) part = part + 'x';
        \\let parts = []; for (let i = 0; i < 100; i++) parts.push(part);
        \\let kept = [null, null];
        \\let ring = []; for (let i = 0; i < 64; i++) ring.push({ i: i });
        \\let total = 0;
        \\for (let n = 0; n < 200; n++) {
        \\  ring[n % 64] = { n: n, s: 'g' + n };
        \\  for (let k = 0; k < n % 7; k++) { let t = { k: k, s: 't' + k }; }
        \\  let big = parts.join('');
        \\  if (n % 2 === 0) kept[(n / 2) % 2] = big;
        \\  total = total + big.length;
        \\}
        \\if (total !== 10000000) undefinedCheck;
    ;
    // (b) Every doubling is kept: reachable data outgrows the limit.
    const outgrows = "let keep = []; let s = 'xxxxxxxxxxxxxxxx'; while (true) { s = s + s; keep.push(s); }";
    const limit = 1 << 20;
    for ([_]zqjs.Engine{ .vm, .treewalk }) |engine| {
        const a = try runStats(fits, engine, .{ .max_heap_bytes = limit });
        try testing.expectEqual(@as(?anyerror, null), a.err);
        const b = try runStats(outgrows, engine, .{ .max_heap_bytes = limit });
        try testing.expectEqual(@as(?anyerror, error.LimitExceeded), b.err);
        try testing.expectEqual(@as(?zqjs.Limit, .heap_bytes), b.limit);
        // It failed with the heap full of live data (after the run nothing is reachable, so
        // the peak is the measure): every doubling was kept, and HL2 says a burst no larger
        // than half the free room can't fail.
        try testing.expect(b.peak > limit / 4);
        try testing.expect(b.majors > 0);
    }
}
