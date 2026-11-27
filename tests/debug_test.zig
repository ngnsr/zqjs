//! Integration tests for M11: Bytecode Inspector & Debugger (`src/debug/`).
//! Covers breakpoints, stepping modes, call stack/frame/locals/operand inspection,
//! cycle-safe bounded heap browser, and manual minor/major GC + heap verification
//! while paused mid-execution (safe under `-Dgc-stress -Dstack-stress`).

const std = @import("std");
const testing = std.testing;
const zqjs = @import("zqjs_internal");
const support = @import("support.zig");
const Op = zqjs.bytecode.Op;
const Proto = zqjs.bytecode.Proto;
const Debugger = zqjs.debug.Debugger;
const dbg = zqjs.debug.debugger;
const insp = zqjs.debug.inspector;

/// A compiled, verified script plus its Runtime and VM.
const Harness = struct {
    arena: std.heap.ArenaAllocator,
    out: std.Io.Writer.Allocating,
    rt: zqjs.Runtime,
    proto: Proto,

    fn create(source: []const u8, limits: zqjs.Limits) !*Harness {
        const gpa = testing.allocator;
        const h = try gpa.create(Harness);
        errdefer gpa.destroy(h);
        h.arena = .init(gpa);
        errdefer h.arena.deinit();
        h.out = .init(gpa);
        errdefer h.out.deinit();
        h.rt = .init(gpa, limits, &h.out.writer);
        errdefer h.rt.deinit();
        var d: zqjs.Diagnostic = .{};
        const script = try zqjs.parse(h.arena.allocator(), source, limits, &d);
        const res = try zqjs.resolve(h.arena.allocator(), script, &d);
        h.proto = try zqjs.compile(gpa, &h.rt.heap, script, res, limits, &d);
        var f: zqjs.verify.Failure = .{};
        _ = try zqjs.verify.verify(gpa, &h.proto, limits, &f);
        return h;
    }

    fn destroy(h: *Harness) void {
        h.proto.deinit(testing.allocator);
        h.rt.deinit();
        h.out.deinit();
        h.arena.deinit();
        testing.allocator.destroy(h);
    }

    fn output(h: *Harness) []const u8 {
        return h.out.written();
    }
};

/// Finds the first PC in `proto` whose opcode equals `target`.
fn findFirstOp(proto: *const Proto, target: Op) ?u32 {
    var pc: usize = 0;
    while (pc < proto.code.len) {
        const op: Op = @fromBackingInt(@intCast(proto.code[pc]));
        if (op == target) return @intCast(pc);
        pc += op.size();
    }
    return null;
}

test "watchdog: debug_test does not hang" {
    support.watchdog(@src().file);
}

test "breakpoints: set, hit, hit_count, clear, enable/disable, validation, and nested closures" {
    const src =
        \\function outer(n) {
        \\  let acc = 0;
        \\  function inner(x) {
        \\    return x * 2;
        \\  }
        \\  for (let i = 1; i <= n; i++) {
        \\    acc += inner(i);
        \\  }
        \\  return acc;
        \\}
        \\print(outer(3));
    ;
    const h = try Harness.create(src, .{});
    defer h.destroy();
    var vm = try zqjs.Vm.init(&h.rt, &h.proto);
    defer vm.deinit();
    var d = Debugger.init(testing.allocator, &vm);
    defer d.deinit();

    // Proto discovery.
    const protos = try d.listProtos(testing.allocator);
    defer testing.allocator.free(protos);
    try testing.expectEqual(@as(usize, 3), protos.len);
    try testing.expect(protos[0].is_script);
    try testing.expectEqualStrings("<script>", protos[0].name);
    try testing.expectEqualStrings("outer", protos[1].name);
    try testing.expectEqualStrings("inner", protos[2].name);

    // Invalid PC and invalid proto ID are rejected.
    try testing.expectError(error.InvalidPc, d.setBreakpoint(&h.proto, 99999));
    try testing.expectError(error.InvalidProto, d.setBreakpointByProtoId(99, 0));
    try testing.expectError(error.InvalidProto, d.setFunctionBreakpoint("doesNotExist"));

    // Entry breakpoint at script pc=0 plus function breakpoints on outer and inner.
    const bp_entry = try d.setBreakpointByProtoId(0, 0);
    const bp_outer = try d.setFunctionBreakpoint("outer");
    const bp_inner = try d.setFunctionBreakpoint("inner");

    // Deduplication: setting at the same location returns the existing ID.
    try testing.expectEqual(bp_inner, try d.setBreakpoint(protos[2].proto, 0));
    try testing.expectEqual(@as(usize, 3), d.listBreakpoints().len);

    // First continue stops immediately at entry breakpoint (pc = 0) before running it.
    try testing.expectEqual(dbg.StopReason{ .breakpoint = bp_entry }, try d.continueUntilBreakpoint());
    try testing.expectEqual(@as(u64, 0), h.rt.steps);
    try testing.expectEqual(@as(u64, 1), d.getBreakpoint(bp_entry).?.hit_count);

    // Continue hits `outer` once.
    try testing.expectEqual(dbg.StopReason{ .breakpoint = bp_outer }, try d.continueUntilBreakpoint());
    try testing.expectEqualStrings("outer", d.currentFrameView().?.function_name);
    try testing.expectEqual(@as(u64, 1), d.getBreakpoint(bp_outer).?.hit_count);

    // Continue hits `inner` 3 times (i = 1, 2, 3), then disable and clear.
    for (1..4) |expected_hits| {
        try testing.expectEqual(dbg.StopReason{ .breakpoint = bp_inner }, try d.continueUntilBreakpoint());
        try testing.expectEqualStrings("inner", d.currentFrameView().?.function_name);
        try testing.expectEqual(@as(u64, expected_hits), d.getBreakpoint(bp_inner).?.hit_count);
        if (expected_hits == 2) {
            // Clear `outer` breakpoint mid-run and verify list shrinks.
            try testing.expect(d.clearBreakpoint(bp_outer));
            try testing.expect(!d.clearBreakpoint(bp_outer));
            try testing.expectEqual(@as(usize, 2), d.listBreakpoints().len);
        }
    }

    // Disable remaining breakpoints and run to completion.
    try testing.expect(d.setBreakpointEnabled(bp_inner, false));
    try testing.expectEqual(dbg.StopReason.halted, try d.continueUntilBreakpoint());
    try testing.expectEqualStrings("12\n", h.output());
}

test "stepping modes: stepInstruction, stepInto, stepOver, stepOut" {
    const src =
        \\function leaf(v) {
        \\  let doubled = v * 2;
        \\  return doubled + 1;
        \\}
        \\function mid(a) {
        \\  let x = leaf(a);
        \\  let y = leaf(x);
        \\  return y;
        \\}
        \\print(mid(5));
    ;
    const h = try Harness.create(src, .{});
    defer h.destroy();
    var vm = try zqjs.Vm.init(&h.rt, &h.proto);
    defer vm.deinit();
    var d = Debugger.init(testing.allocator, &vm);
    defer d.deinit();

    // 1. stepInstruction executes exactly one op.
    const steps0 = h.rt.steps;
    try testing.expectEqual(dbg.StopReason.step, try d.stepInstruction());
    try testing.expectEqual(steps0 + 1, h.rt.steps);

    // 2. Break on first `call` inside `mid` so we can test stepInto vs stepOver vs stepOut.
    const mid_proto = d.findProtoByName("mid").?;
    const first_call_pc = findFirstOp(mid_proto, .call).?;
    const bp_mid_call = try d.setBreakpoint(mid_proto, first_call_pc);

    try testing.expectEqual(dbg.StopReason{ .breakpoint = bp_mid_call }, try d.continueUntilBreakpoint());
    try testing.expectEqual(@as(usize, 2), d.frameCount());
    try testing.expectEqualStrings("mid", d.currentFrameView().?.function_name);
    try testing.expectEqual(Op.call, d.currentFrameView().?.current_op.?);

    // 3. stepInto on `call` enters `leaf` at depth 3, pc 0.
    try testing.expectEqual(dbg.StopReason.step, try d.stepInto());
    try testing.expectEqual(@as(usize, 3), d.frameCount());
    try testing.expectEqualStrings("leaf", d.currentFrameView().?.function_name);
    try testing.expectEqual(@as(u32, 0), d.currentFrameView().?.pc);

    // 4. stepOut returns from `leaf` back to `mid` (depth 2).
    try testing.expectEqual(dbg.StopReason.step, try d.stepOut());
    try testing.expectEqual(@as(usize, 2), d.frameCount());
    try testing.expectEqualStrings("mid", d.currentFrameView().?.function_name);
    // Return value of leaf(5) = 11 is now on top of mid's operand stack.
    const mid_ops = d.currentFrameView().?.operands;
    try testing.expect(mid_ops.len >= 1);
    try testing.expectEqual(zqjs.Value.fromNumber(11), mid_ops[mid_ops.len - 1]);

    // 5. Advance to the second `call` in `mid` and use stepOver to skip entering `leaf`.
    while (d.currentFrameView().?.current_op.? != .call) {
        try testing.expectEqual(dbg.StopReason.step, try d.stepInstruction());
    }
    const call2_pc = d.currentFrameView().?.pc;
    try testing.expectEqual(dbg.StopReason.step, try d.stepOver());
    try testing.expectEqual(@as(usize, 2), d.frameCount());
    try testing.expectEqualStrings("mid", d.currentFrameView().?.function_name);
    try testing.expect(d.currentFrameView().?.pc > call2_pc);
    // Return value of leaf(11) = 23 is on top of mid's operand stack.
    const mid_ops2 = d.currentFrameView().?.operands;
    try testing.expect(mid_ops2.len >= 1);
    try testing.expectEqual(zqjs.Value.fromNumber(23), mid_ops2[mid_ops2.len - 1]);

    // 6. stepOut of `mid` returns to `<script>`, then continue to halt.
    try testing.expectEqual(dbg.StopReason.step, try d.stepOut());
    try testing.expectEqual(@as(usize, 1), d.frameCount());
    try testing.expectEqualStrings("<script>", d.currentFrameView().?.function_name);

    try testing.expectEqual(dbg.StopReason.halted, try d.continueUntilBreakpoint());
    // Repeated step after halt returns .halted and charges 0 steps.
    const final_steps = h.rt.steps;
    try testing.expectEqual(dbg.StopReason.halted, try d.stepInstruction());
    try testing.expectEqual(final_steps, h.rt.steps);
    try testing.expectEqualStrings("23\n", h.output());
}

test "stepOver stops if a breakpoint is hit inside the callee" {
    const src =
        \\function helper(n) { return n + 10; }
        \\let r = helper(7);
        \\print(r);
    ;
    const h = try Harness.create(src, .{});
    defer h.destroy();
    var vm = try zqjs.Vm.init(&h.rt, &h.proto);
    defer vm.deinit();
    var d = Debugger.init(testing.allocator, &vm);
    defer d.deinit();

    const script_call_pc = findFirstOp(&h.proto, .call).?;
    _ = try d.setBreakpoint(&h.proto, script_call_pc);
    const bp_helper = try d.setFunctionBreakpoint("helper");

    _ = try d.continueUntilBreakpoint();
    try testing.expectEqual(Op.call, d.currentFrameView().?.current_op.?);
    try testing.expectEqual(dbg.StopReason{ .breakpoint = bp_helper }, try d.stepOver());
    try testing.expectEqualStrings("helper", d.currentFrameView().?.function_name);

    try testing.expectEqual(dbg.StopReason.halted, try d.continueUntilBreakpoint());
    try testing.expectEqualStrings("17\n", h.output());
}

test "stack, frame, locals, params, captures, and operand inspection during recursion & closures" {
    const src =
        \\function makeAdder(base) {
        \\  let secret = base * 10;
        \\  function fact(n) {
        \\    if (n <= 1) return secret + 1;
        \\    return n * fact(n - 1);
        \\  }
        \\  return fact;
        \\}
        \\const f = makeAdder(4);
        \\print(f(3));
    ;
    const h = try Harness.create(src, .{});
    defer h.destroy();
    var vm = try zqjs.Vm.init(&h.rt, &h.proto);
    defer vm.deinit();
    var d = Debugger.init(testing.allocator, &vm);
    defer d.deinit();

    const bp_fact = try d.setFunctionBreakpoint("fact");

    // Hit fact(3), then fact(2), then fact(1).
    try testing.expectEqual(dbg.StopReason{ .breakpoint = bp_fact }, try d.continueUntilBreakpoint());
    try testing.expectEqual(dbg.StopReason{ .breakpoint = bp_fact }, try d.continueUntilBreakpoint());
    try testing.expectEqual(dbg.StopReason{ .breakpoint = bp_fact }, try d.continueUntilBreakpoint());
    try testing.expectEqual(@as(u64, 3), d.getBreakpoint(bp_fact).?.hit_count);

    // Stack trace should be: fact(1) -> fact(2) -> fact(3) -> <script>.
    var trace = try d.captureStackTrace(testing.allocator);
    defer trace.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), trace.frames.len);

    // Top frame is fact(1), capturing `secret = 40` (and `fact` itself if captured).
    try testing.expectEqualStrings("fact", trace.frames[0].function_name);
    try testing.expect(trace.frames[0].is_top);
    try testing.expect(trace.frames[0].current_op != null);
    try testing.expect(trace.frames[0].disasm_line.len > 0);
    try testing.expectEqual(@as(usize, 1), trace.frames[0].params.len);
    try testing.expectEqual(zqjs.Value.fromNumber(1), trace.frames[0].params[0].value.?);

    // Verify captured `secret == 40` is visible in `captures`.
    var saw_secret = false;
    for (trace.frames[0].captures) |cap| {
        if (cap.value) |v| {
            if (v.isNumber() and v.asNumber() == 40) saw_secret = true;
        }
    }
    try testing.expect(saw_secret);

    // Caller frames: fact(2), fact(3), <script>.
    try testing.expectEqualStrings("fact", trace.frames[1].function_name);
    try testing.expectEqual(zqjs.Value.fromNumber(2), trace.frames[1].params[0].value.?);
    try testing.expectEqualStrings("fact", trace.frames[2].function_name);
    try testing.expectEqual(zqjs.Value.fromNumber(3), trace.frames[2].params[0].value.?);
    try testing.expectEqualStrings("<script>", trace.frames[3].function_name);

    // Caller frames have pending operands (`n` waiting for `*` after recursive call returns).
    try testing.expect(trace.frames[1].operands.len >= 1);
    try testing.expect(trace.frames[2].operands.len >= 1);

    // Disassembly helper writes the same line as the snapshot.
    var disasm_buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer disasm_buf.deinit();
    try d.disassembleFrame(d.frameCount() - 1, &disasm_buf.writer);
    try testing.expectEqualStrings(trace.frames[0].disasm_line, disasm_buf.written());

    d.clearAllBreakpoints();
    try testing.expectEqual(dbg.StopReason.halted, try d.continueUntilBreakpoint());
    // fact(3) = 3 * (2 * (40 + 1)) = 246
    try testing.expectEqualStrings("246\n", h.output());
}

test "heap browser: cyclic objects, arrays, closures, maps, sets, getters, and bounded depth" {
    const src =
        \\let getterCalled = 0;
        \\function inspectMe(obj, arr, fn, map, set, deep) {
        \\  return getterCalled;
        \\}
        \\let obj = { a: 1, b: "hello world long string" };
        \\obj.self = obj;
        \\Object.defineProperty(obj, "boom", {
        \\  enumerable: true,
        \\  get() { getterCalled++; return 999; }
        \\});
        \\let arr = [10, 20, 30, 40, 50];
        \\arr.push(arr);
        \\let captured = 42;
        \\let fn = function myClosure(x) { return x + captured; };
        \\let map = new Map();
        \\map.set("k1", 100);
        \\map.set("self", map);
        \\let set = new Set([1, 2, 3]);
        \\set.add(set);
        \\let deep = { l1: { l2: { l3: { l4: { l5: 7 } } } } };
        \\print(inspectMe(obj, arr, fn, map, set, deep));
    ;
    const h = try Harness.create(src, .{});
    defer h.destroy();
    var vm = try zqjs.Vm.init(&h.rt, &h.proto);
    defer vm.deinit();
    var d = Debugger.init(testing.allocator, &vm);
    defer d.deinit();

    _ = try d.setFunctionBreakpoint("inspectMe");
    _ = try d.continueUntilBreakpoint();

    var snap = (try d.captureFrame(testing.allocator, d.frameCount() - 1)).?;
    defer snap.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), snap.params.len);

    const obj_val = snap.params[0].value.?;
    const arr_val = snap.params[1].value.?;
    const fn_val = snap.params[2].value.?;
    const map_val = snap.params[3].value.?;
    const set_val = snap.params[4].value.?;
    const deep_val = snap.params[5].value.?;

    // 1. Cyclic object + string truncation + accessor never invoked.
    var obj_info = try d.inspectValue(testing.allocator, obj_val, .{
        .max_depth = 3,
        .max_items = 16,
        .max_string_len = 5,
    });
    defer obj_info.deinit(testing.allocator);
    try testing.expectEqual(insp.ObjectKind.ordinary, obj_info.object.kind);
    var saw_circular = false;
    var saw_truncated_str = false;
    var saw_accessor = false;
    for (obj_info.object.properties) |prop| {
        if (std.mem.eql(u8, prop.key, "self")) {
            try testing.expect(prop.value.? == .circular);
            saw_circular = true;
        } else if (std.mem.eql(u8, prop.key, "b")) {
            try testing.expect(prop.value.?.string.truncated);
            try testing.expectEqualStrings("hello", prop.value.?.string.text);
            saw_truncated_str = true;
        } else if (std.mem.eql(u8, prop.key, "boom")) {
            try testing.expect(prop.is_accessor);
            try testing.expect(prop.value == null);
            saw_accessor = true;
        }
    }
    try testing.expect(saw_circular and saw_truncated_str and saw_accessor);

    // 2. Cyclic array with max_items cap.
    var arr_info = try d.inspectValue(testing.allocator, arr_val, .{ .max_depth = 3, .max_items = 3 });
    defer arr_info.deinit(testing.allocator);
    try testing.expectEqual(insp.ObjectKind.array, arr_info.object.kind);
    try testing.expectEqual(@as(usize, 6), arr_info.object.array_len);
    try testing.expectEqual(@as(usize, 3), arr_info.object.elements.len);
    try testing.expect(arr_info.object.truncated_elements);

    // Full array inspection sees the circular self-reference at index 5.
    var arr_full = try d.inspectValue(testing.allocator, arr_val, .{ .max_depth = 3, .max_items = 10 });
    defer arr_full.deinit(testing.allocator);
    try testing.expect(arr_full.object.elements[5] == .circular);

    // 3. Closure name, param_count, capture_count, and captured value.
    var fn_info = try d.inspectValue(testing.allocator, fn_val, .{ .max_depth = 3, .max_items = 10 });
    defer fn_info.deinit(testing.allocator);
    try testing.expectEqualStrings("myClosure", fn_info.closure.name);
    try testing.expectEqual(@as(u32, 1), fn_info.closure.param_count);
    try testing.expectEqual(@as(usize, 1), fn_info.closure.capture_count);
    try testing.expectEqual(@as(usize, 1), fn_info.closure.captures.len);
    try testing.expectEqual(@as(f64, 42), fn_info.closure.captures[0].value.?.number);

    // 4. Cyclic Map and cyclic Set.
    var map_info = try d.inspectValue(testing.allocator, map_val, .{ .max_depth = 3, .max_items = 10 });
    defer map_info.deinit(testing.allocator);
    try testing.expectEqual(insp.ObjectKind.map, map_info.object.kind);
    try testing.expectEqual(@as(usize, 2), map_info.object.map_len);
    try testing.expect(map_info.object.map_entries[1].value == .circular);

    var set_info = try d.inspectValue(testing.allocator, set_val, .{ .max_depth = 3, .max_items = 10 });
    defer set_info.deinit(testing.allocator);
    try testing.expectEqual(insp.ObjectKind.set, set_info.object.kind);
    try testing.expectEqual(@as(usize, 4), set_info.object.set_len);
    try testing.expect(set_info.object.set_entries[3] == .circular);

    // 5. Bounded depth stops cleanly with `.depth_limit`.
    var deep_info = try d.inspectValue(testing.allocator, deep_val, .{ .max_depth = 2, .max_items = 10 });
    defer deep_info.deinit(testing.allocator);
    const l1 = deep_info.object.properties[0].value.?;
    const l2 = l1.object.properties[0].value.?;
    try testing.expect(l2 == .depth_limit);

    // 6. formatValue produces bounded, cycle-safe text for cyclic structures & closures.
    var fmt_buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer fmt_buf.deinit();
    try d.formatValue(obj_val, &fmt_buf.writer, .{ .max_depth = 3, .max_items = 16 });
    try testing.expect(std.mem.indexOf(u8, fmt_buf.written(), "[Circular]") != null);
    try testing.expect(std.mem.indexOf(u8, fmt_buf.written(), "[Getter/Setter]") != null);

    fmt_buf.clearRetainingCapacity();
    try d.formatValue(fn_val, &fmt_buf.writer, .{});
    try testing.expectEqualStrings("[Closure: myClosure (captures: 1)]", fmt_buf.written());

    // 7. Heap stats snapshot & formatting.
    const stats = d.heapStats();
    try testing.expectEqual(stats.total_bytes, stats.nursery_bytes + stats.old_bytes + stats.buffer_bytes);
    try testing.expectEqual(stats.live_objects, stats.young_objects + stats.old_objects);
    try testing.expectEqual(stats.live_objects, stats.counts_by_kind.total());
    try testing.expect(stats.counts_by_kind.object >= 5);
    try testing.expect(stats.counts_by_kind.closure >= 1);
    try testing.expect(stats.atom_count > 0);

    var stats_buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stats_buf.deinit();
    try insp.formatHeapStats(stats, &stats_buf.writer);
    try testing.expect(std.mem.indexOf(u8, stats_buf.written(), "nursery=") != null);
    try testing.expect(std.mem.indexOf(u8, stats_buf.written(), "atoms:") != null);

    // Finish execution and prove the getter was never invoked by inspection!
    d.clearAllBreakpoints();
    try testing.expectEqual(dbg.StopReason.halted, try d.continueUntilBreakpoint());
    try testing.expectEqualStrings("0\n", h.output());
}

test "manual minor/major GC and heap verification while paused mid-execution" {
    const src =
        \\function checkpoint(tag, keepArr, keepClosure) {
        \\  return keepArr.length + keepClosure(tag);
        \\}
        \\function work() {
        \\  let captured = 100;
        \\  let adder = (x) => x + captured;
        \\  let keep = [1, 2, 3, 4];
        \\  // Allocate short-lived garbage before pausing.
        \\  for (let i = 0; i < 40; i++) {
        \\    let tmp = { idx: i, s: "garbage_" + i, list: [i, i + 1] };
        \\    if (tmp.idx < 0) keep.push(tmp);
        \\  }
        \\  let a = checkpoint(5, keep, adder);
        \\  // Allocate more garbage before a second pause.
        \\  for (let i = 0; i < 40; i++) {
        \\    let tmp = { idx: i, s: "more_garbage_" + i };
        \\    if (tmp.idx < 0) keep.push(tmp);
        \\  }
        \\  let b = checkpoint(7, keep, adder);
        \\  return a + b;
        \\}
        \\print(work());
    ;
    const h = try Harness.create(src, .{});
    defer h.destroy();
    var vm = try zqjs.Vm.init(&h.rt, &h.proto);
    defer vm.deinit();
    var d = Debugger.init(testing.allocator, &vm);
    defer d.deinit();

    const bp = try d.setFunctionBreakpoint("checkpoint");

    // Pause #1: verify heap, trigger minor GC with verification, confirm live state survives.
    try testing.expectEqual(dbg.StopReason{ .breakpoint = bp }, try d.continueUntilBreakpoint());
    try d.verifyHeap();

    const before_minor = d.heapStats();
    const minor_report = try d.triggerMinorGc(true);
    const after_minor = d.heapStats();
    try testing.expectEqual(dbg.GcKind.minor, minor_report.kind);
    try testing.expect(minor_report.verified);
    try testing.expectEqual(before_minor.minor_gc_count + 1, after_minor.minor_gc_count);
    try testing.expectEqual(@as(usize, 0), after_minor.young_objects);
    try testing.expectEqual(@as(usize, 0), after_minor.nursery_bytes);

    // Pause #2: trigger major GC with verification, confirm major count increments.
    try testing.expectEqual(dbg.StopReason{ .breakpoint = bp }, try d.continueUntilBreakpoint());
    const before_major = d.heapStats();
    const major_report = try d.triggerMajorGc(true);
    const after_major = d.heapStats();
    try testing.expectEqual(dbg.GcKind.major, major_report.kind);
    try testing.expect(major_report.verified);
    try testing.expectEqual(before_major.major_gc_count + 1, after_major.major_gc_count);
    try testing.expectEqual(@as(usize, 0), after_major.young_objects);

    // Resume to completion and verify all rooted values survived both manual collections.
    d.clearAllBreakpoints();
    try testing.expectEqual(dbg.StopReason.halted, try d.continueUntilBreakpoint());
    // a = 4 + (5 + 100) = 109; b = 4 + (7 + 100) = 111; a + b = 220
    try testing.expectEqualStrings("220\n", h.output());
}

test "runSource --trace installs closure_caller for builtin-to-JS callbacks" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var err_w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer err_w.deinit();
    var trace_w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer trace_w.deinit();

    const code = try zqjs.runSource(
        testing.allocator,
        "trace_cb.js",
        "print([1, 2, 3].map(x => x * 2).join(','));",
        .{},
        .{ .mode = .normal, .engine = .vm, .trace = &trace_w.writer },
        &out.writer,
        &err_w.writer,
    );
    try testing.expectEqual(@as(u8, 0), code);
    try testing.expectEqualStrings("", err_w.written());
    try testing.expectEqualStrings("2,4,6\n", out.written());
    try testing.expect(trace_w.written().len > 0);
}
