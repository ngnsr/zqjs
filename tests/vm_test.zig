//! The VM's `step()` contract (DESIGN_DECISIONS D35), driven directly: one instruction
//! per call, budget charged first, precise faults, nothing executes after halt or a
//! fault, cleanup of partially initialised state, and the `--trace` format.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zqjs = @import("zqjs_internal");
const support = @import("support.zig");
const Op = zqjs.bytecode.Op;

/// A compiled, verified script plus the runtime it runs in.
const Setup = struct {
    arena: std.heap.ArenaAllocator,
    discard: std.Io.Writer.Discarding,
    rt: zqjs.Runtime,
    proto: zqjs.bytecode.Proto,

    /// Heap-allocated so `rt.out` can point into it.
    fn create(source: []const u8, limits: zqjs.Limits) !*Setup {
        const gpa = testing.allocator;
        const s = try gpa.create(Setup);
        errdefer gpa.destroy(s);
        s.arena = .init(gpa);
        errdefer s.arena.deinit();
        s.discard = .init(&.{});
        s.rt = .init(gpa, limits, &s.discard.writer);
        errdefer s.rt.deinit();
        var d: zqjs.Diagnostic = .{};
        const script = try zqjs.parse(s.arena.allocator(), source, limits, &d);
        const res = try zqjs.resolve(s.arena.allocator(), script, &d);
        s.proto = try zqjs.compile(gpa, &s.rt.heap, script, res, limits, &d);
        var f: zqjs.verify.Failure = .{};
        _ = try zqjs.verify.verify(gpa, &s.proto, limits, &f);
        return s;
    }

    fn destroy(s: *Setup) void {
        s.proto.deinit(testing.allocator);
        s.rt.deinit();
        s.arena.deinit();
        testing.allocator.destroy(s);
    }

    fn opAt(s: *const Setup, pc: u32) Op {
        return @fromBackingInt(s.proto.code[pc]);
    }
};

test "watchdog: this binary fails, instead of hanging, if a test gets stuck" {
    support.watchdog(@src().file);
}

test "step executes one instruction at a time; after halt nothing runs" {
    const s = try Setup.create("let x = 1;", .{});
    defer s.destroy();
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();
    // clear_local, push_const, init_local, halt
    for (0..3) |i| {
        try testing.expectEqual(zqjs.Vm.State.running, try vm.step());
        try testing.expectEqual(@as(u64, i + 1), s.rt.steps);
    }
    try testing.expectEqual(zqjs.Vm.State.halted, try vm.step());
    try testing.expectEqual(@as(u64, 4), s.rt.steps);
    try testing.expectEqual(zqjs.Vm.State.halted, try vm.step());
    try testing.expectEqual(@as(u64, 4), s.rt.steps); // nothing executed, nothing charged
    try testing.expectEqual(zqjs.Value{ .number = 1 }, vm.locals[0].value.?);
}

test "an empty script has max_stack 0 and halts" {
    const s = try Setup.create("", .{});
    defer s.destroy();
    try testing.expectEqual(@as(u32, 0), s.proto.max_stack);
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();
    try vm.run();
    try testing.expect(vm.halted);
}

/// Runs until the first error and returns it.
fn runToFault(vm: *zqjs.Vm) anyerror {
    while (true) _ = vm.step() catch |e| return e;
}

test "a throwing instruction is precise: pc and stack as before it, then the VM stays faulted" {
    const s = try Setup.create("let a = 1; print(a, nope);", .{});
    defer s.destroy();
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();
    try testing.expectEqual(error.Thrown, runToFault(&vm));
    try testing.expectEqual(Op.get_global, s.opAt(vm.pc)); // `nope`, not the next instruction
    try testing.expectEqual(@as(usize, 2), vm.operands().len); // [print, 1]: nothing pushed
    try testing.expectEqual(zqjs.Value{ .number = 1 }, vm.operands()[1]);
    try testing.expectEqual(zqjs.ErrorName.ReferenceError, s.rt.exception.?.name);
    const steps = s.rt.steps;
    try testing.expectError(error.Thrown, vm.step());
    try testing.expectEqual(steps, s.rt.steps); // faulted: nothing executed
}

test "a native that fails leaves a valid pre-call stack" {
    const s = try Setup.create("print(1, print);", .{});
    defer s.destroy();
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();
    try testing.expectEqual(error.Unsupported, runToFault(&vm));
    try testing.expectEqual(Op.call, s.opAt(vm.pc));
    try testing.expectEqual(@as(usize, 3), vm.operands().len); // [print, 1, print]: callee and args intact
}

test "operator errors leave both operands on the stack" {
    const s = try Setup.create("let s = 'ab'; s + s;", .{ .max_string_length = 3 });
    defer s.destroy();
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();
    try testing.expectEqual(error.LimitExceeded, runToFault(&vm));
    try testing.expectEqual(Op.add, s.opAt(vm.pc));
    try testing.expectEqual(@as(usize, 2), vm.operands().len);
}

test "the budget is charged before an instruction runs" {
    const s = try Setup.create("1; 2;", .{ .max_steps = 2 });
    defer s.destroy();
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();
    _ = try vm.step(); // push_const 1
    _ = try vm.step(); // pop
    const pc = vm.pc;
    try testing.expectError(error.LimitExceeded, vm.step());
    try testing.expectEqual(pc, vm.pc); // push_const 2 did not run
    try testing.expectEqual(@as(usize, 0), vm.operands().len);
    try testing.expectEqual(zqjs.Limit.steps, s.rt.limitHit().?);
    try testing.expectEqual(@as(u64, 2), s.rt.steps); // never above the limit
}

test "an unlimited budget cannot overflow the counter" {
    const s = try Setup.create("1;", .{});
    defer s.destroy();
    s.rt.steps = std.math.maxInt(u64) - 1; // max_steps defaults to maxInt(u64)
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();
    _ = try vm.step();
    try testing.expectError(error.LimitExceeded, vm.step());
}

test "Vm.init cleans up when its second allocation fails" {
    const s = try Setup.create("let x = 1;", .{}); // 1 slot, max_stack 1: two allocations
    defer s.destroy();
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const gpa = s.rt.gpa;
    s.rt.gpa = failing.allocator();
    defer s.rt.gpa = gpa;
    try testing.expectError(error.OutOfMemory, zqjs.Vm.init(&s.rt, &s.proto));
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes); // the slots were freed
}

test "--trace prints each instruction and the operand stack before it runs" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var trace: std.Io.Writer.Allocating = .init(testing.allocator);
    defer trace.deinit();
    var discard: std.Io.Writer.Discarding = .init(&.{});
    _ = try zqjs.runSource(testing.allocator, "t", "let x = 1; print(x + 2, 'a');", .{}, .{ .trace = &trace.writer }, &out.writer, &discard.writer);
    try testing.expectEqualStrings("3 a\n", out.written());
    try testing.expectEqualStrings(
        \\      0  clear_local    s0                               |
        \\      5  push_const     k0            ; 1                |
        \\     10  init_local     s0                               | 1
        \\     15  get_global     n0            ; print            |
        \\     20  get_local      s0 n1         ; x                | <native print>
        \\     29  push_const     k1            ; 2                | <native print>, 1
        \\     34  add                                             | <native print>, 1, 2
        \\     35  push_const     k2            ; "a"              | <native print>, 3
        \\     40  call           2                                | <native print>, 3, "a"
        \\     45  pop                                             | undefined
        \\     46  halt                                            |
        \\
    , trace.written());
}

test "a fault inside a callee is precise and leaves the frames intact" {
    const s = try Setup.create("function f() { return nope; } print(1, f());", .{});
    defer s.destroy();
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();
    try testing.expectEqual(error.Thrown, runToFault(&vm));
    try testing.expectEqual(@as(usize, 2), vm.frames.items.len); // still inside f
    try testing.expectEqual(Op.get_global, @as(Op, @fromBackingInt(vm.proto().code[vm.pc])));
    // The caller's operands sit below the callee's: [print, 1, f], untouched.
    try testing.expectEqual(@as(usize, 3), vm.operands().len);
    try testing.expectEqual(zqjs.Value{ .number = 1 }, vm.operands()[1]);
    try testing.expect(vm.operands()[2] == .closure);
}

test "a call that fails during setup leaves the caller unchanged: limit" {
    const s = try Setup.create("function f(n) { return f(n + 1); } f(0);", .{ .max_call_depth = 3 });
    defer s.destroy();
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();
    try testing.expectEqual(error.LimitExceeded, runToFault(&vm));
    try testing.expectEqual(zqjs.Limit.call_depth, s.rt.limitHit().?);
    try testing.expectEqual(@as(usize, 3), vm.frames.items.len); // the 4th frame was never pushed
    try testing.expectEqual(Op.call, @as(Op, @fromBackingInt(vm.proto().code[vm.pc])));
    const top = vm.frames.items[2];
    try testing.expectEqual(top.stack_base + 2, @as(u32, @intCast(vm.operands().len))); // [f, n + 1] still there
    try testing.expectEqual(top.locals_base + top.proto.slot_count, vm.locals_len);
}

test "a call that fails during setup leaves the caller unchanged: out of memory" {
    const s = try Setup.create("function f(a) { let b = a; return b; } print(f(1));", .{});
    defer s.destroy();
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();
    // Run up to the call of f; the script's stacks are exactly its own size, so entering
    // f must grow them, and that allocation fails.
    while (@as(Op, @fromBackingInt(vm.proto().code[vm.pc])) != .call or vm.operands().len != 3) _ = try vm.step();
    const before = .{ vm.pc, vm.sp, vm.locals_len, vm.frames.items.len, vm.reserved };
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const gpa = s.rt.gpa;
    s.rt.gpa = failing.allocator();
    try testing.expectError(error.OutOfMemory, vm.step());
    s.rt.gpa = gpa;
    try testing.expectEqual(before, .{ vm.pc, vm.sp, vm.locals_len, vm.frames.items.len, vm.reserved });
    try testing.expect(vm.operands()[1] == .closure); // [print, f, 1]
}

test "return restores the caller's pc, frame and operand depth" {
    const s = try Setup.create("function f(a, b) { let c = a + b; return c; } print(10, f(1, 2));", .{});
    defer s.destroy();
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();
    while (@as(Op, @fromBackingInt(vm.proto().code[vm.pc])) != .call or vm.frames.items.len != 1 or vm.operands().len != 5) _ = try vm.step();
    const pc = vm.pc;
    _ = try vm.step(); // enter f
    try testing.expectEqual(@as(usize, 2), vm.frames.items.len);
    try testing.expectEqual(@as(u32, 0), vm.pc);
    while (vm.frames.items.len == 2) _ = try vm.step(); // until f returns
    try testing.expectEqual(pc + zqjs.bytecode.Op.call.size(), vm.pc);
    try testing.expectEqual(@as(usize, 3), vm.operands().len); // [print, 10, 3]
    try testing.expectEqual(zqjs.Value{ .number = 3 }, vm.operands()[2]);
    try testing.expectEqual(s.proto.slot_count, vm.locals_len);
}

// ---- D49: defensive checks return `error.Internal` and poison the runtime

test "a defensive-check failure returns Internal and poisons the runtime (D49)" {
    const s = try Setup.create("let x = 1;", .{});
    defer s.destroy();
    // Corrupt the verified code by hand, as a compiler or verifier bug would: an opcode
    // the verifier never lets through. `code` is gpa-allocated; the const slice only
    // protects the reader.
    @constCast(s.proto.code)[0] = 0xFF;
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();
    try testing.expectError(error.Internal, vm.step());
    try testing.expect(vm.fault != null);
    try testing.expect(s.rt.poisoned);
    try testing.expectEqualStrings("invalid opcode", s.rt.internal_reason.?);
    try testing.expectEqual(@as(u64, 0), s.rt.steps); // nothing was charged
    // Faulted like every error: further steps return the same error, execute nothing.
    try testing.expectError(error.Internal, vm.step());
    try testing.expectEqual(@as(u64, 0), s.rt.steps);
    // The first reason is kept: a later check may only follow from the first.
    @constCast(s.proto.code)[1] = 0xFF;
    try testing.expectError(error.Internal, vm.step());
    try testing.expectEqualStrings("invalid opcode", s.rt.internal_reason.?);
}

test "other defensive checks also return Internal, with their own reason (D49)" {
    // `push_const` with a constant index the verifier would have rejected.
    const s = try Setup.create("let x = 1; let y = \"s\";", .{});
    defer s.destroy();
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();
    // Find the push_const that loads "s" and point it past the constants.
    while (@as(Op, @fromBackingInt(vm.proto().code[vm.pc])) != .push_const) _ = try vm.step();
    @constCast(vm.proto().code)[vm.pc + 1] = 0xFF; // little-endian operand, low byte
    try testing.expectError(error.Internal, vm.step());
    try testing.expect(s.rt.poisoned);
    try testing.expectEqualStrings("constant index out of range", s.rt.internal_reason.?);
}

// ---- The shared execution context (M9.1, D51): the budget and the logical call depth
// a chain shares. Driven directly, before the nested VM lifecycle (P3) is layered on.

/// Steps `vm` until it halts or faults, returning the error if any.
fn runUntilStop(vm: *zqjs.Vm) ?zqjs.runtime.Error {
    while (true) {
        const state = vm.step() catch |e| return e;
        if (state == .halted) return null;
    }
}

test "chain: one cumulative budget, shared and latched (D51, Q8)" {
    const s = try Setup.create("let i = 0; while (i < 10) i++;", .{ .max_steps = 5 });
    defer s.destroy();
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();

    const cx = &s.rt.exec_ctx;
    s.rt.beginChain(0, 5);
    vm.chain = cx;
    try testing.expectEqual(@as(u64, 0), s.rt.steps);

    // The 6th instruction exhausts the budget: exactly 5 charged, never more (E4), and
    // the exhaustion latched in the context (Q8).
    try testing.expectEqual(error.LimitExceeded, runUntilStop(&vm).?);
    try testing.expectEqual(@as(u64, 5), s.rt.steps);
    try testing.expectEqual(zqjs.runtime.Error.LimitExceeded, cx.budget_fault.?);
    try testing.expectEqual(zqjs.Limit.steps, s.rt.limitHit().?);
    // Faulted like every error: further steps consume nothing and keep the latch.
    try testing.expectEqual(error.LimitExceeded, runUntilStop(&vm).?);
    try testing.expectEqual(@as(u64, 5), s.rt.steps);

    // The chain ends with the count saved back for the caller (E4).
    try testing.expectEqual(@as(u64, 5), s.rt.endChain());
    vm.chain = null;

    // A new chain starts fresh: adopted count, no latch (a native cannot carry a
    // previous chain's fault into the next one).
    s.rt.beginChain(2, 100);
    try testing.expectEqual(@as(u64, 2), s.rt.steps);
    try testing.expect(cx.budget_fault == null);
    try testing.expectEqual(@as(u64, 2), s.rt.endChain());
}

test "chain: the logical call depth counts the chain's frames as one number (D51)" {
    // max_call_depth = 3: the script frame plus two live calls fill it; the third call
    // faults on the chain's shared counter, not a per-VM one.
    const s = try Setup.create("function f(n) { if (n > 0) return f(n - 1); return n; } f(9);", .{ .max_call_depth = 3 });
    defer s.destroy();
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    errdefer vm.deinit();

    const cx = &s.rt.exec_ctx;
    s.rt.beginChain(0, std.math.maxInt(u64));
    defer _ = s.rt.endChain();
    vm.chain = cx;
    // The frames already live when the chain begins count from the start (the
    // embedding API's resume sets this from the suspended VM's frames).
    cx.call_depth = @intCast(vm.frames.items.len);

    while (true) {
        const state = vm.step() catch |e| {
            try testing.expectEqual(error.LimitExceeded, e);
            break;
        };
        if (state == .halted) break;
        // At every step boundary the chain's depth is exactly the live frames.
        try testing.expectEqual(vm.frames.items.len, cx.call_depth);
    }
    // Faulted: three live frames (script + f(9) + f(8)), depth and frames in step.
    try testing.expectEqual(@as(u32, 3), cx.call_depth);
    try testing.expectEqual(@as(u32, 3), vm.frames.items.len);
    try testing.expectEqual(zqjs.Limit.call_depth, s.rt.limitHit().?);
    try testing.expectEqual(@as(u32, 3), cx.call_depth);

    // Teardown mid-chain unwinds exactly the frames still live: the chain's depth is
    // back to what it was before the VM ran.
    vm.deinit();
    try testing.expectEqual(@as(u32, 0), cx.call_depth);
}

test "chain: depth returns to its starting count after a full run (D51)" {
    const s = try Setup.create("function f(n) { if (n > 0) return f(n - 1); return n; } f(3);", .{});
    defer s.destroy();
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();

    const cx = &s.rt.exec_ctx;
    s.rt.beginChain(0, std.math.maxInt(u64));
    defer _ = s.rt.endChain();
    vm.chain = cx;
    cx.call_depth = @intCast(vm.frames.items.len);
    try testing.expect(runUntilStop(&vm) == null); // completes: no limit
    // Every call's charge was unwound by its return; the script frame remains.
    try testing.expectEqual(vm.frames.items.len, cx.call_depth);
    try testing.expectEqual(@as(u32, 1), cx.call_depth);
}

test "chain: engine records stack with proof and teardown discipline (D52)" {
    const s = try Setup.create("let x = 1;", .{});
    defer s.destroy();
    const cx = &s.rt.exec_ctx;
    s.rt.beginChain(0, std.math.maxInt(u64));
    defer _ = s.rt.endChain();

    // At depth 0 no native is in flight: no sanctioned engine descent is possible.
    try testing.expect(cx.topRecord() == null);

    // Native dispatch pushes the record as the engine entry; nested dispatch stacks
    // above it (native -> JS -> native).
    var r1: zqjs.runtime.NativeRecord = .{};
    var r2: zqjs.runtime.NativeRecord = .{};
    try cx.pushRecord(s.rt.gpa, &r1);
    try cx.pushRecord(s.rt.gpa, &r2);
    try testing.expect(cx.topRecord() == &r2); // the innermost callback owns the top
    try testing.expect(r1.live and r2.live);

    // Teardown consumes the innermost record and pops exactly its entry.
    cx.popRecord(&r2);
    try testing.expect(!r2.live and r1.live);
    try testing.expect(cx.topRecord() == &r1);
    cx.popRecord(&r1);
    try testing.expect(!r1.live);
    try testing.expect(cx.topRecord() == null);
}

// ---- The nested-call VM (M9.1, D51, model B): a closure run as frame 0 of a fresh VM
// over the shared heap and realm. This is the machinery `rt.call` and native dispatch
// (P4) share; the public round-trip tests complete in P4, when the host can first
// obtain a function token (a native's dup — no test-only public API before that).

/// The script's first closure value, after a run created it (the declaration's slot).
fn firstClosure(vm: *zqjs.Vm) !*const zqjs.heap.Closure {
    for (vm.locals[0..vm.locals_len]) |s| switch (s) {
        .value => |v| if (v) |x| if (x == .closure) return x.closure,
        .cell => {},
    };
    return error.TestUnexpectedResult;
}

fn runCall(source: []const u8, this: ?zqjs.Value, args: []const zqjs.Value) !zqjs.Value {
    const script = try Setup.create(source, .{});
    defer script.destroy();
    var vm = try zqjs.Vm.init(&script.rt, &script.proto);
    defer vm.deinit();
    try testing.expect(runUntilStop(&vm) == null);
    const c = try firstClosure(&vm);

    // A fresh chain with the nested VM registered and depth-charged, exactly as the
    // embedding API's rt.call does it (D51).
    const cx = &script.rt.exec_ctx;
    script.rt.beginChain(0, std.math.maxInt(u64));
    defer _ = script.rt.endChain();
    var cvm = try zqjs.Vm.initCall(&script.rt, c, this, args);
    defer cvm.deinit(); // unwinds the frames a fault left live
    cvm.chain = cx;
    cx.call_depth += 1; // frame 0 is live
    try cx.vms.append(script.rt.gpa, cvm.roots());
    defer cx.removeVm(&cvm);

    const e = runUntilStop(&cvm);
    if (e) |err| return err;
    return cvm.nested_result.?;
}

test "nested call: runs a closure with arguments and returns its value" {
    const v = try runCall("function f(x) { return x * 2; } f(1);", null, &.{.{ .number = 21 }});
    try testing.expectEqual(@as(f64, 42), v.number);
}

test "nested call: arity variants bind like a call does (D41)" {
    // Missing parameters are undefined.
    const missing = try runCall("function f(x) { return x; } f(1);", null, &.{});
    try testing.expect(missing == .undefined);
    // Extra arguments are ignored.
    const extra = try runCall("function f() { return 7; } f(1);", null, &.{ .{ .number = 1 }, .{ .number = 2 } });
    try testing.expectEqual(@as(f64, 7), extra.number);
}

test "nested call: `this` binds by the VM's sloppy rule (D41)" {
    // No receiver: `this` is unset (undefined).
    const none = try runCall("function f() { return this === undefined; } f();", null, &.{});
    try testing.expectEqual(true, none.boolean);
    // A primitive receiver is not boxed: `this` stays unset (D41).
    const prim = try runCall("function f() { return this === undefined; } f();", .{ .number = 42 }, &.{});
    try testing.expectEqual(true, prim.boolean);
}

test "nested call: a script exception is a Thrown fault with the exception set" {
    const script = try Setup.create("function f() { let a = null; a(); } f();", .{});
    defer script.destroy();
    var vm = try zqjs.Vm.init(&script.rt, &script.proto);
    defer vm.deinit();
    try testing.expect(runUntilStop(&vm) == null);
    const c = try firstClosure(&vm);

    const cx = &script.rt.exec_ctx;
    script.rt.beginChain(0, std.math.maxInt(u64));
    defer _ = script.rt.endChain();
    var cvm = try zqjs.Vm.initCall(&script.rt, c, null, &.{});
    defer cvm.deinit();
    cvm.chain = cx;
    cx.call_depth += 1;
    try cx.vms.append(script.rt.gpa, cvm.roots());
    defer cx.removeVm(&cvm);

    try testing.expectEqual(error.Thrown, runUntilStop(&cvm).?);
    try testing.expectEqual(zqjs.runtime.ErrorName.TypeError, script.rt.exception.?.name);
}

test "nested call: the chain's budget bounds it and latches (D51, Q8)" {
    const s = try Setup.create("", .{});
    defer s.destroy();
    const script = try Setup.create("function f() { let i = 0; while (true) i++; } f();", .{});
    defer script.destroy();
    var vm = try zqjs.Vm.init(&script.rt, &script.proto);
    defer vm.deinit();
    try testing.expect(runUntilStop(&vm) == null);
    const c = try firstClosure(&vm);

    const cx = &script.rt.exec_ctx;
    script.rt.beginChain(0, 100);
    var cvm = try zqjs.Vm.initCall(&script.rt, c, null, &.{});
    defer cvm.deinit();
    cvm.chain = cx;
    cx.call_depth += 1;
    try cx.vms.append(script.rt.gpa, cvm.roots());
    defer cx.removeVm(&cvm);

    try testing.expectEqual(error.LimitExceeded, runUntilStop(&cvm).?);
    // The shared counter never exceeded the cumulative max, and the latch is set.
    try testing.expectEqual(@as(u64, 100), script.rt.steps);
    try testing.expectEqual(zqjs.runtime.Error.LimitExceeded, cx.budget_fault.?);
    try testing.expectEqual(zqjs.Limit.steps, script.rt.limitHit().?);
}

test "nested call: the chain's depth counts its recursion as one number (D51)" {
    const script = try Setup.create("function f(n) { if (n > 0) return f(n - 1); return n; } f(9);", .{ .max_call_depth = 5 });
    defer script.destroy();
    var vm = try zqjs.Vm.init(&script.rt, &script.proto);
    defer vm.deinit();
    try testing.expect(runUntilStop(&vm) == null);
    const c = try firstClosure(&vm);

    const cx = &script.rt.exec_ctx;
    script.rt.beginChain(0, std.math.maxInt(u64));
    defer _ = script.rt.endChain();
    var cvm = try zqjs.Vm.initCall(&script.rt, c, null, &.{.{ .number = 1e9 }});
    errdefer cvm.deinit();
    cvm.chain = cx;
    cx.call_depth += 1;
    try cx.vms.append(script.rt.gpa, cvm.roots());

    // Recursion faults on the chain's shared counter: 5 frames live at once.
    try testing.expectEqual(error.LimitExceeded, runUntilStop(&cvm).?);
    try testing.expectEqual(@as(u32, 5), cx.call_depth);
    try testing.expectEqual(@as(u32, 5), cvm.frames.items.len);
    try testing.expectEqual(zqjs.Limit.call_depth, script.rt.limitHit().?);
    // Teardown mid-recursion unwinds the charge exactly.
    cvm.deinit();
    try testing.expectEqual(@as(u32, 0), cx.call_depth);
}

test "nested call: a collection between steps keeps the suspended VM's state (R2 groundwork)" {
    const script = try Setup.create(
        "function f(n) { if (n <= 0) return 'done'; return f(n - 1) + '!'; } f(5);",
        .{},
    );
    defer script.destroy();
    var vm = try zqjs.Vm.init(&script.rt, &script.proto);
    defer vm.deinit();
    try testing.expect(runUntilStop(&vm) == null);
    const c = try firstClosure(&vm);

    const cx = &script.rt.exec_ctx;
    script.rt.beginChain(0, std.math.maxInt(u64));
    defer _ = script.rt.endChain();
    var cvm = try zqjs.Vm.initCall(&script.rt, c, null, &.{.{ .number = 8 }});
    defer cvm.deinit();
    cvm.chain = cx;
    cx.call_depth += 1;
    try cx.vms.append(script.rt.gpa, cvm.roots());
    defer cx.removeVm(&cvm);

    // Suspend mid-recursion and collect: the collector traces the chain's registered
    // VM, so every live frame, stack value and cell survives (GC_DESIGN §4, D51 #4).
    for (0..3) |_| _ = try cvm.step();
    script.rt.collect();
    // Resume to completion: recursion continues over the moved/collected state.
    try testing.expect(runUntilStop(&cvm) == null);
    const r = cvm.nested_result.?;
    try testing.expect(r == .string);
    try testing.expectEqual(@as(usize, 9), r.string.units.len); // "!!!!!!!!!"
}
