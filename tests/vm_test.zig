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
    try testing.expectEqual(zqjs.Value.fromNumber(1), vm.locals[0].asValue());
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
    try testing.expectEqual(zqjs.Value.fromNumber(1), vm.operands()[1]);
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
    const s = try Setup.create("'ab' + 'cd';", .{ .max_string_length = 3 });
    defer s.destroy();
    var vm = try zqjs.Vm.init(&s.rt, &s.proto);
    defer vm.deinit();
    try testing.expectEqual(error.LimitExceeded, runToFault(&vm));
    try testing.expectEqual(Op.add, s.opAt(vm.pc));
    try testing.expectEqual(@as(usize, 2), vm.operands().len);

    const s2 = try Setup.create("let s = 'ab'; s + s;", .{ .max_string_length = 3 });
    defer s2.destroy();
    var vm2 = try zqjs.Vm.init(&s2.rt, &s2.proto);
    defer vm2.deinit();
    try testing.expectEqual(error.LimitExceeded, runToFault(&vm2));
    try testing.expectEqual(Op.add_local, s2.opAt(vm2.pc));
    try testing.expectEqual(@as(usize, 1), vm2.operands().len);
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
        \\     29  add_const      k1            ; 2                | <native print>, 1
        \\     34  push_const     k2            ; "a"              | <native print>, 3
        \\     39  call           2                                | <native print>, 3, "a"
        \\     44  pop                                             | undefined
        \\     45  halt                                            |
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
    try testing.expectEqual(zqjs.Value.fromNumber(1), vm.operands()[1]);
    try testing.expect(vm.operands()[2].isClosure());
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
    try testing.expect(vm.operands()[1].isClosure()); // [print, f, 1]
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
    try testing.expectEqual(zqjs.Value.fromNumber(3), vm.operands()[2]);
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
    for (vm.locals[0..vm.locals_len]) |s| {
        if (s.isUninit()) continue;
        if (s.isCell()) {
            if (s.asCell().value) |x| if (x.isClosure()) return x.asClosure();
        } else {
            const x = s.asValue();
            if (x.isClosure()) return x.asClosure();
        }
    }
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
    const v = try runCall("function f(x) { return x * 2; } f(1);", null, &.{zqjs.Value.fromNumber(21)});
    try testing.expectEqual(@as(f64, 42), v.asNumber());
}

test "nested call: arity variants bind like a call does (D41)" {
    // Missing parameters are undefined.
    const missing = try runCall("function f(x) { return x; } f(1);", null, &.{});
    try testing.expect(missing.isUndefined());
    // Extra arguments are ignored.
    const extra = try runCall("function f() { return 7; } f(1);", null, &.{ zqjs.Value.fromNumber(1), zqjs.Value.fromNumber(2) });
    try testing.expectEqual(@as(f64, 7), extra.asNumber());
}

test "nested call: `this` binds by the VM's sloppy rule (D41)" {
    // No receiver: `this` is unset (Unsupported.sloppy_this).
    try testing.expectError(error.Unsupported, runCall("function f() { return this; } 0;", null, &.{}));
    // An explicit value passed to initCall is bound as `this`.
    const prim = try runCall("function f() { return this; } 0;", zqjs.Value.fromNumber(42), &.{});
    try testing.expectEqual(@as(f64, 42), prim.asNumber());
    // An object receiver binds `this` to that object.
    const script = try Setup.create("let o = { a: 7 }; function f() { return this.a; } 0;", .{});
    defer script.destroy();
    var vm = try zqjs.Vm.init(&script.rt, &script.proto);
    defer vm.deinit();
    try testing.expect(runUntilStop(&vm) == null);
    const obj = vm.locals[0].asValue();
    const c = try firstClosure(&vm);

    const cx = &script.rt.exec_ctx;
    script.rt.beginChain(0, std.math.maxInt(u64));
    defer _ = script.rt.endChain();
    var cvm = try zqjs.Vm.initCall(&script.rt, c, obj, &.{});
    defer cvm.deinit();
    cvm.chain = cx;
    cx.call_depth += 1;
    try cx.vms.append(script.rt.gpa, cvm.roots());
    defer cx.removeVm(&cvm);

    try testing.expect(runUntilStop(&cvm) == null);
    try testing.expectEqual(@as(f64, 7), cvm.nested_result.?.asNumber());
}

test "nested call: a script exception is a Thrown fault with the exception set" {
    const script = try Setup.create("function f() { let a = null; a(); } 0;", .{});
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
    const script = try Setup.create("function f() { let i = 0; while (true) i++; } 0;", .{});
    defer script.destroy();
    var vm = try zqjs.Vm.init(&script.rt, &script.proto);
    defer vm.deinit();
    try testing.expect(runUntilStop(&vm) == null);
    const c = try firstClosure(&vm);

    const cx = &script.rt.exec_ctx;
    script.rt.beginChain(0, 100);
    defer _ = script.rt.endChain();
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
    const script = try Setup.create("function f(n) { if (n > 0) return f(n - 1); return n; } 0;", .{ .max_call_depth = 5 });
    defer script.destroy();
    var vm = try zqjs.Vm.init(&script.rt, &script.proto);
    defer vm.deinit();
    try testing.expect(runUntilStop(&vm) == null);
    const c = try firstClosure(&vm);

    const cx = &script.rt.exec_ctx;
    script.rt.beginChain(0, std.math.maxInt(u64));
    defer _ = script.rt.endChain();
    var cvm = try zqjs.Vm.initCall(&script.rt, c, null, &.{zqjs.Value.fromNumber(1e9)});
    errdefer cvm.deinit();
    cvm.chain = cx;
    cx.call_depth += 1;
    try cx.vms.append(script.rt.gpa, cvm.roots());
    defer cx.removeVm(&cvm);

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
        "function f(n) { if (n <= 0) return 'done'; return f(n - 1) + '!'; } 0;",
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
    var cvm = try zqjs.Vm.initCall(&script.rt, c, null, &.{zqjs.Value.fromNumber(8)});
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
    try testing.expect(r.isString());
    try testing.expectEqual(@as(usize, 12), r.asString().units.len); // "done!!!!!!!!"
}

const api = @import("zqjs");

test "nested call: suspended outer VM stays rooted and intact while nested VM reallocates stacks and collects (D51, R2)" {
    const script = try Setup.create(
        \\function outer(n) {
        \\  let tag = 'outer-' + n;
        \\  if (n > 0) return tag + ':' + outer(n - 1);
        \\  return tag;
        \\}
        \\function inner(k) {
        \\  let s = 'in-' + k;
        \\  if (k > 0) return s + ',' + inner(k - 1);
        \\  return s;
        \\}
        \\print(outer(3));
    ,
        .{},
    );
    defer script.destroy();
    var outer_vm = try zqjs.Vm.init(&script.rt, &script.proto);
    defer outer_vm.deinit();

    // Register outer_vm as a root set and step it until it is mid-recursion inside `outer`.
    try script.rt.addRoots(outer_vm.roots());
    defer script.rt.removeRoots(&outer_vm);

    const cx = &script.rt.exec_ctx;
    script.rt.beginChain(0, std.math.maxInt(u64));
    outer_vm.chain = cx;
    cx.call_depth = @intCast(outer_vm.frames.items.len);

    while (outer_vm.frames.items.len < 3) _ = try outer_vm.step();
    const outer_steps = script.rt.endChain();
    outer_vm.chain = null;

    // Grab `inner` closure from outer_vm's top-level locals.
    const inner_c = outer_vm.locals[1].asCell().value.?.asClosure();
    const outer_stack_ptr = outer_vm.stack.ptr;
    const outer_locals_ptr = outer_vm.locals.ptr;

    // Run a nested VM for `inner(12)` while `outer_vm` is suspended mid-recursion.
    script.rt.beginChain(0, std.math.maxInt(u64));
    {
        defer _ = script.rt.endChain();
        var cvm = try zqjs.Vm.initCall(&script.rt, inner_c, null, &.{zqjs.Value.fromNumber(12)});
        defer cvm.deinit();
        cvm.chain = cx;
        cx.call_depth += 1;
        try cx.vms.append(script.rt.gpa, cvm.roots());
        defer cx.removeVm(&cvm);

        const init_stack_ptr = cvm.stack.ptr;
        const init_locals_ptr = cvm.locals.ptr;
        var reallocated_stack = false;
        var reallocated_locals = false;

        while (true) {
            const st = try cvm.step();
            if (cvm.stack.ptr != init_stack_ptr) reallocated_stack = true;
            if (cvm.locals.ptr != init_locals_ptr) reallocated_locals = true;
            // Collect garbage while both VMs have live frames and strings on their stacks.
            if (cvm.frames.items.len == 6) script.rt.collect();
            if (st == .halted) break;
        }
        // Confirm the nested VM actually reallocated its stacks while outer_vm was suspended.
        try testing.expect(reallocated_stack);
        try testing.expect(reallocated_locals);
        try testing.expect(cvm.nested_result.?.isString());
    }
    try testing.expect(!cx.active);
    try testing.expectEqual(@as(usize, 0), cx.vms.items.len);

    // Outer VM's stacks were untouched; collect again and resume outer_vm to completion.
    try testing.expectEqual(outer_stack_ptr, outer_vm.stack.ptr);
    try testing.expectEqual(outer_locals_ptr, outer_vm.locals.ptr);
    script.rt.collect();

    script.rt.beginChain(outer_steps, std.math.maxInt(u64));
    defer _ = script.rt.endChain();
    outer_vm.chain = cx;
    cx.call_depth = @intCast(outer_vm.frames.items.len);
    try testing.expect(runUntilStop(&outer_vm) == null);
}

test "chain edge cases: nested call does not reset budget, latched budget fault survives native returning normally or throwing, endChain restores state (D51)" {
    const script = try Setup.create(
        \\function work(n) {
        \\  let s = 0;
        \\  for (let i = 0; i < n; i++) s = s + i;
        \\  return s;
        \\}
        \\function loop() {
        \\  while (true) {}
        \\}
        \\0;
    ,
        .{},
    );
    defer script.destroy();
    var setup_vm = try zqjs.Vm.init(&script.rt, &script.proto);
    defer setup_vm.deinit();
    try testing.expect(runUntilStop(&setup_vm) == null);
    const work_c = setup_vm.locals[0].asValue().asClosure();
    const loop_c = setup_vm.locals[1].asValue().asClosure();

    // 1. Nested calls share one cumulative budget and never reset it.
    const cx = &script.rt.exec_ctx;
    script.rt.beginChain(5, 500);
    {
        var cvm1 = try zqjs.Vm.initCall(&script.rt, work_c, null, &.{zqjs.Value.fromNumber(3)});
        defer cvm1.deinit();
        cvm1.chain = cx;
        cx.call_depth += 1;
        try cx.vms.append(script.rt.gpa, cvm1.roots());
        defer cx.removeVm(&cvm1);
        try testing.expect(runUntilStop(&cvm1) == null);
        const after_first = script.rt.steps;
        try testing.expect(after_first > 5);

        // Second nested call in the same chain continues from `after_first`, not 0.
        var cvm2 = try zqjs.Vm.initCall(&script.rt, work_c, null, &.{zqjs.Value.fromNumber(3)});
        defer cvm2.deinit();
        cvm2.chain = cx;
        cx.call_depth += 1;
        try cx.vms.append(script.rt.gpa, cvm2.roots());
        defer cx.removeVm(&cvm2);
        try testing.expect(runUntilStop(&cvm2) == null);
        try testing.expectEqual(after_first + (after_first - 5), script.rt.steps);
    }
    _ = script.rt.endChain();
    try testing.expect(!cx.active);
    try testing.expect(cx.budget_fault == null);
    try testing.expectEqual(@as(u32, 0), cx.call_depth);

    // 2. A latched budget failure inside a native callback survives the native returning
    // normally OR throwing a JS exception, faulting the caller VM at the native boundary.
    const Ctx = struct {
        var loop_closure: *const zqjs.heap.Closure = undefined;
        var mode: enum { return_normal, throw_error } = .return_normal;

        fn hostNative(rt: *zqjs.Runtime, _: zqjs.Value, _: []const zqjs.Value) zqjs.runtime.Error!zqjs.Value {
            const ecx = &rt.exec_ctx;
            var cvm = try zqjs.Vm.initCall(rt, loop_closure, null, &.{});
            defer cvm.deinit();
            cvm.chain = ecx;
            ecx.call_depth += 1;
            try ecx.vms.append(rt.gpa, cvm.roots());
            defer ecx.removeVm(&cvm);

            // Exhaust the chain's budget inside the nested VM.
            const err = runUntilStop(&cvm);
            std.debug.assert(err.? == error.LimitExceeded);
            std.debug.assert(ecx.budget_fault.? == error.LimitExceeded);

            // The native ignores the budget exhaustion and either returns normally or throws.
            return switch (mode) {
                .return_normal => zqjs.Value.fromNumber(999),
                .throw_error => rt.throw(.TypeError, &.{.{ .ascii = "native throw after budget fault" }}),
            };
        }
    };
    Ctx.loop_closure = loop_c;

    // Call `hostNative` from an outer VM by replacing the `nf` function slot before `nf(1)`.
    const call_script = try Setup.create(
        \\function loop() { while (true) {} }
        \\function nf(x) { return x; }
        \\nf(1);
    ,
        .{},
    );
    defer call_script.destroy();

    for ([_]@TypeOf(Ctx.mode){ .return_normal, .throw_error }) |m| {
        Ctx.mode = m;
        var outer = try zqjs.Vm.init(&call_script.rt, &call_script.proto);
        defer outer.deinit();

        call_script.rt.beginChain(0, 25);
        outer.chain = &call_script.rt.exec_ctx;
        call_script.rt.exec_ctx.call_depth = @intCast(outer.frames.items.len);

        // Step until both function declarations (`loop` and `nf`) are initialized in locals.
        while (outer.locals[0].isUninit() or outer.locals[1].isUninit()) _ = try outer.step();
        Ctx.loop_closure = outer.locals[0].asValue().asClosure();
        outer.locals[1] = .fromValue(zqjs.Value.fromNative(&.{ .name = "hostNative", .call = Ctx.hostNative }));

        // Regardless of whether the native returned 999 or threw TypeError, the outer VM
        // faults with the latched LimitExceeded(steps) and leaves its stack pre-call (D35).
        try testing.expectEqual(error.LimitExceeded, runUntilStop(&outer).?);
        try testing.expectEqual(zqjs.Limit.steps, call_script.rt.limitHit().?);
        try testing.expectEqual(@as(u64, 25), call_script.rt.steps);
        try testing.expectEqual(@as(usize, 2), outer.operands().len); // [nf, 1] untouched

        outer.chain = null;
        try testing.expectEqual(@as(u64, 25), call_script.rt.endChain());
        // endChain() restored the context completely.
        try testing.expect(!call_script.rt.exec_ctx.active);
        try testing.expect(call_script.rt.exec_ctx.budget_fault == null);
        try testing.expectEqual(@as(u32, 0), call_script.rt.exec_ctx.call_depth);
        try testing.expectEqual(@as(usize, 0), call_script.rt.exec_ctx.vms.items.len);
        try testing.expectEqual(@as(usize, 0), call_script.rt.exec_ctx.records.items.len);
    }
}

test "public Runtime.call: poisoned runtime returns Internal, closure round-trip while suspended, and error cleanup (D49, D51)" {
    // 1. Poisoned runtime -> error.Internal on Runtime.call and handle mint/dup.
    {
        const rt = try api.Runtime.create(testing.allocator, .{});
        defer rt.destroy();
        const h = try rt.newNumber(7);
        defer h.release();

        // Poison the internal runtime via the handle's owner pointer (simulating a prior D49 bug).
        const irt: *zqjs.Runtime = @ptrCast(@alignCast(h.owner));
        irt.bug("simulated internal failure") catch {};
        try testing.expect(irt.poisoned);

        var failure: api.Failure = .{};
        try testing.expectError(error.Internal, rt.call(h, null, &.{}, &failure));
        try testing.expectEqual(api.Failure.Kind.internal, failure.kind);
        try testing.expectEqualStrings("internal error", failure.message());

        try testing.expectError(error.Internal, rt.newNumber(1));
        try testing.expectError(error.Internal, rt.newBoolean(true));
        try testing.expectError(error.Internal, rt.newStringUtf16(&.{'a'}));
        try testing.expectError(error.Internal, h.dup());

        // Read-only / cleanup operations remain usable while poisoned (E7).
        try testing.expectEqual(@as(?f64, 7), h.number());
        rt.collectGarbage();
        _ = rt.memory();
    }

    // 2. Public Runtime.call on a closure and a built-in native while an Execution is suspended,
    // plus error cleanup across Thrown, LimitExceeded(steps), LimitExceeded(call_depth), and Unsupported.
    {
        var out_buf: [128]u8 = undefined;
        var out: std.Io.Writer = .fixed(&out_buf);
        const rt = try api.Runtime.create(testing.allocator, .{
            .limits = .{ .max_steps = 500, .max_call_depth = 8 },
            .output = &out,
        });
        defer rt.destroy();

        const src =
            \\function sum(n) { if (n <= 0) return 0; return n + sum(n - 1); }
            \\function failThrow() { let a = null; return a(); }
            \\function failUnsupported() { return this; }
            \\let res = sum(4);
            \\print(res);
        ;
        const p = try rt.compile("closures.js", src, null);
        defer p.destroy();
        const ex = try rt.start(p);
        defer ex.destroy();

        // Step `ex` so the function declarations are initialized in its frame 0 locals,
        // and leave `ex` suspended mid-run.
        try testing.expectEqual(api.Status.suspended, try ex.@"resume"(8, null));

        const arg = try rt.newNumber(5);
        defer arg.release();
        const irt: *zqjs.Runtime = @ptrCast(@alignCast(arg.owner));
        const ex_vm: *zqjs.Vm = @ptrCast(@alignCast(irt.extra_roots.items[1].ctx));

        const sum_tok = try zqjs.handles.Table.mint(irt, zqjs.Value.fromClosure(ex_vm.locals[0].asCell().value.?.asClosure()));
        const sum_h: api.Handle = .{ .owner = sum_tok.owner, .slot = sum_tok.slot, .generation = sum_tok.generation };
        defer sum_h.release();
        const throw_tok = try zqjs.handles.Table.mint(irt, zqjs.Value.fromClosure(ex_vm.locals[1].asValue().asClosure()));
        const throw_h: api.Handle = .{ .owner = throw_tok.owner, .slot = throw_tok.slot, .generation = throw_tok.generation };
        defer throw_h.release();
        const unsup_tok = try zqjs.handles.Table.mint(irt, zqjs.Value.fromClosure(ex_vm.locals[2].asValue().asClosure()));
        const unsup_h: api.Handle = .{ .owner = unsup_tok.owner, .slot = unsup_tok.slot, .generation = unsup_tok.generation };
        defer unsup_h.release();

        // Normal closure call through public Runtime.call while `ex` is suspended:
        const sum_res = try rt.call(sum_h, null, &.{arg}, null);
        defer sum_res.release();
        try testing.expectEqual(@as(?f64, 15), sum_res.number());

        // Thrown fault through Runtime.call restores context:
        var failure: api.Failure = .{};
        try testing.expectError(error.Thrown, rt.call(throw_h, null, &.{}, &failure));
        try testing.expectEqual(api.Failure.Kind.thrown, failure.kind);
        try testing.expect(!irt.exec_ctx.active);
        try testing.expectEqual(@as(u32, 0), irt.exec_ctx.call_depth);
        try testing.expectEqual(@as(usize, 0), irt.exec_ctx.vms.items.len);

        // Unsupported fault through Runtime.call restores context:
        try testing.expectError(error.Unsupported, rt.call(unsup_h, null, &.{}, &failure));
        try testing.expectEqual(api.Failure.Kind.unsupported, failure.kind);
        try testing.expect(!irt.exec_ctx.active);

        // LimitExceeded(call_depth) mid-recursion through Runtime.call unwinds all frames:
        const deep_arg = try rt.newNumber(20);
        defer deep_arg.release();
        try testing.expectError(error.LimitExceeded, rt.call(sum_h, null, &.{deep_arg}, &failure));
        try testing.expectEqual(api.Failure.Kind.limit, failure.kind);
        try testing.expectEqual(@as(?api.Limit, .call_depth), failure.limit);
        try testing.expect(!irt.exec_ctx.active);
        try testing.expectEqual(@as(u32, 0), irt.exec_ctx.call_depth);
        try testing.expectEqual(@as(usize, 0), irt.exec_ctx.vms.items.len);

        // Resume the suspended outer execution to completion.
        rt.collectGarbage();
        try testing.expectEqual(api.Status.finished, try ex.@"resume"(500, null));
        try testing.expectEqualStrings("10\n", out.buffered());
    }
}

fn checkClosureCallAllocFailOnce(allocator: std.mem.Allocator) !void {
    const rt = api.Runtime.create(allocator, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer rt.destroy();

    const p = rt.compile("f.js", "function f(x) { return 'val:' + (x + 1); } 0;", null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TestUnexpectedResult,
    };
    defer p.destroy();

    const ex = rt.start(p) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TestUnexpectedResult,
    };
    defer ex.destroy();

    _ = ex.@"resume"(10, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TestUnexpectedResult,
    };

    const arg = rt.newNumber(41) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TestUnexpectedResult,
    };
    defer arg.release();

    const irt: *zqjs.Runtime = @ptrCast(@alignCast(arg.owner));
    const ex_vm: *zqjs.Vm = @ptrCast(@alignCast(irt.extra_roots.items[1].ctx));
    const fn_tok = zqjs.handles.Table.mint(irt, zqjs.Value.fromClosure(ex_vm.locals[0].asValue().asClosure())) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.TestUnexpectedResult,
    };
    const fn_h: api.Handle = .{ .owner = fn_tok.owner, .slot = fn_tok.slot, .generation = fn_tok.generation };
    defer fn_h.release();

    var failure: api.Failure = .{};
    const res = rt.call(fn_h, null, &.{arg}, &failure) catch |e| switch (e) {
        error.OutOfMemory => {
            try testing.expect(!irt.exec_ctx.active);
            try testing.expectEqual(@as(u32, 0), irt.exec_ctx.call_depth);
            try testing.expectEqual(@as(usize, 0), irt.exec_ctx.vms.items.len);
            return error.OutOfMemory;
        },
        else => return error.TestUnexpectedResult,
    };
    defer res.release();
    try testing.expect(!irt.exec_ctx.active);
    try testing.expectEqual(@as(u32, 0), irt.exec_ctx.call_depth);
    try testing.expectEqual(@as(usize, 0), irt.exec_ctx.vms.items.len);
    var sbuf: [8]u16 = undefined;
    try testing.expectEqual(@as(?usize, 6), res.string(&sbuf));
}

test "public Runtime.call: checkAllAllocationFailures over closure call and root registration (E6, D51)" {
    try testing.checkAllAllocationFailures(testing.allocator, checkClosureCallAllocFailOnce, .{});
}

test "handles: slot at maxInt(u64) generation retires on release instead of wrapping (D50)" {
    const rt = try api.Runtime.create(testing.allocator, .{ .limits = .{ .max_handles = 2 } });
    defer rt.destroy();

    const h1 = try rt.newNumber(10);
    const irt: *zqjs.Runtime = @ptrCast(@alignCast(h1.owner));
    // Fast-forward slot 0's generation to maxInt(u64) and release the matching token.
    irt.handles.slots.items[h1.slot].generation = std.math.maxInt(u64);
    const retired_h: api.Handle = .{
        .owner = h1.owner,
        .slot = h1.slot,
        .generation = std.math.maxInt(u64),
    };
    retired_h.release();

    // Slot 0 is dead and was retired rather than returned to `free_slot_head`, so
    // minting a new handle allocates slot 1 instead of wrapping slot 0's generation.
    try testing.expect(!irt.handles.slots.items[0].live);
    try testing.expectEqual(std.math.maxInt(u32), irt.handles.free_slot_head);

    const h2 = try rt.newNumber(20);
    defer h2.release();
    try testing.expectEqual(@as(u32, 1), h2.slot);
    try testing.expectEqual(@as(?f64, 20), h2.number());

    // With slot 0 permanently retired and slot 1 live, max_handles = 2 is full.
    try testing.expectError(error.LimitExceeded, rt.newNumber(30));
}

test "M10.2c: integer remainder fast path matches JS semantics for signs, -0, NaN, Inf, fractions, MAX_SAFE_INTEGER, and mixed types" {
    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const rt = try api.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    const src =
        \\function isNegZero(x) { return x === 0 && (1 / x) === -Infinity; }
        \\print(7 % 3, -7 % 3, 7 % -3, -7 % -3);
        \\print(isNegZero(4 % 2), isNegZero(4 % -2), isNegZero(-4 % 2), isNegZero(-4 % -2));
        \\print(isNegZero(-0 % 5), isNegZero(-0 % -5), isNegZero(0 % -5));
        \\print(5 % 0, 5 % -0, NaN % 2, 2 % NaN, Infinity % 2, 2 % Infinity, 2 % -Infinity);
        \\print(5.5 % 2, -5.5 % 2, 5 % 1.5);
        \\print(9007199254740991 % 10, 9007199254740992 % 3, -9007199254740991 % -10, isNegZero(-9007199254740991 % -1));
        \\print('7' % 3, '-7' % 3, true % 2, false % 2, null % 3, undefined % 3, [] % 3, ({}) % 3);
    ;
    const prog = try rt.compile("mod_edges.js", src, null);
    defer prog.destroy();
    try rt.run(prog, null);

    const expected =
        "1 -1 1 -1\n" ++
        "false false true true\n" ++
        "true true false\n" ++
        "NaN NaN NaN NaN NaN 2 2\n" ++
        "1.5 -1.5 0.5\n" ++
        "1 2 -1 true\n" ++
        "1 -1 1 0 0 NaN 0 NaN\n";
    try testing.expectEqualStrings(expected, out.buffered());
}

test "M10.4b: Proto.name_atoms stay rooted across major GC (parent + nested), reuse on recompile, and sweep after destroy" {
    const rt = try api.Runtime.create(testing.allocator, .{});
    defer rt.destroy();

    // Obtain internal runtime via a temporary handle to inspect weak `h.atoms` directly.
    const probe = try rt.newBoolean(false);
    const irt: *zqjs.Runtime = @ptrCast(@alignCast(probe.owner));
    probe.release();

    const base_atoms = irt.heap.atoms.count();
    const base_bytes = rt.memory().bytes;

    // 1. Pre-existing atom before compile; failed compile reuses it and rolls back new atoms.
    const kept_atom = try irt.heap.internAscii("preExistingAtom");
    const pre_fail_atoms = irt.heap.atoms.count();
    const pre_fail_bytes = rt.memory().bytes;
    var diag: api.Diagnostic = .{};
    try testing.expectError(error.Source, rt.compile("bad.js", "let o = { preExistingAtom: 1, brandNewFailAtom: ; };", &diag));
    try testing.expectEqual(pre_fail_atoms, irt.heap.atoms.count());
    try testing.expectEqual(pre_fail_bytes, rt.memory().bytes);
    try testing.expect(irt.heap.atoms.contains(kept_atom));

    // Sweep the unrooted `kept_atom` before measuring `p1`'s Proto-rooted atoms.
    rt.collectGarbage();
    try testing.expectEqual(base_atoms, irt.heap.atoms.count());

    // 2. Compile parent + nested function with unique property names; verify major GC keeps them rooted.
    const src =
        \\function makeBox() {
        \\  return { nestedPropAlpha: 10, nestedPropBeta: 20 };
        \\}
        \\let outerObj = { outerPropGamma: 30 };
        \\let res = makeBox().nestedPropAlpha + outerObj.outerPropGamma;
    ;
    const p1 = try rt.compile("atoms1.js", src, null);
    const after_p1_atoms = irt.heap.atoms.count();
    try testing.expect(after_p1_atoms > base_atoms);

    // Major GC while Program is live keeps parent + nested Proto atoms alive.
    rt.collectGarbage();
    try testing.expectEqual(after_p1_atoms, irt.heap.atoms.count());

    // 3. Repeated compilation of identical source reuses existing atoms without growing `h.atoms`.
    const p2 = try rt.compile("atoms2.js", src, null);
    try testing.expectEqual(after_p1_atoms, irt.heap.atoms.count());

    // 4. Start an Execution, destroy both Programs, verify suspended Execution keeps Proto atoms alive across major GC.
    const ex = try rt.start(p1);
    p1.destroy();
    p2.destroy();
    try testing.expectEqual(api.Status.suspended, try ex.@"resume"(1, null));
    rt.collectGarbage();
    try testing.expectEqual(after_p1_atoms, irt.heap.atoms.count());

    // 5. Destroy Execution and run major GC: weak atom table sweeps all Proto-only atoms back to baseline.
    ex.destroy();
    rt.collectGarbage();
    try testing.expectEqual(base_atoms, irt.heap.atoms.count());
    try testing.expectEqual(base_bytes, rt.memory().bytes);
}

test "M10.5b: initLocals handles zero params, missing/extra args, TDZ, and extra locals" {
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const rt = try api.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    const src =
        \\function zero() { let a = 1; let b = 2; return a + b; }
        \\function three(a, b, c) {
        \\  let x = 10;
        \\  return '' + a + ',' + b + ',' + c + ',' + x;
        \\}
        \\print(zero(7, 8, 9), three(1), three(1, 2, 3, 4, 5));
    ;
    const p1 = try rt.compile("init_locals.js", src, null);
    defer p1.destroy();
    try rt.run(p1, null);
    try testing.expectEqualStrings("3 1,undefined,undefined,10 1,2,3,10\n", out.buffered());

    // Parameter + TDZ local before initialization.
    const tdz_src =
        \\function tdzCheck(p) {
        \\  let v = inner;
        \\  let inner = 99;
        \\  return p + v;
        \\}
        \\tdzCheck(1);
    ;
    const p2 = try rt.compile("init_locals_tdz.js", tdz_src, null);
    defer p2.destroy();
    var fail: api.Failure = .{};
    try testing.expectError(error.Thrown, rt.run(p2, &fail));
    try testing.expect(std.mem.indexOf(u8, fail.message(), "Cannot access 'inner' before initialization") != null);
}

test "M10.5c: fastArrayGet matches generic get_elem for -0, bounds, fractions, NaN, Inf, non-numbers, and non-arrays" {
    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const rt = try api.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    const src =
        \\let a = [10, 20, 30];
        \\print(a[0], a[-0], a[2], a[3], a[-1], a[1.5], a[NaN], a[Infinity], a[-Infinity]);
        \\print(a['1'], a['length'], ({ 0: 99 })[0], 'xyz'[1]);
    ;
    const p1 = try rt.compile("fast_array_get.js", src, null);
    defer p1.destroy();
    try rt.run(p1, null);
    try testing.expectEqualStrings(
        "10 10 30 undefined undefined undefined undefined undefined undefined\n20 3 99 y\n",
        out.buffered(),
    );

    const err_src = "let x = null; x[0];";
    const p2 = try rt.compile("fast_array_get_err.js", err_src, null);
    defer p2.destroy();
    var fail: api.Failure = .{};
    try testing.expectError(error.Thrown, rt.run(p2, &fail));
    try testing.expect(std.mem.indexOf(u8, fail.message(), "TypeError") != null);
}

fn nativeThrowJs(rt: *api.Runtime, _: ?*anyopaque, _: ?api.Handle, args: []const api.Handle, out: *api.NativeOut) api.NativeError!void {
    _ = args;
    _ = out;
    rt.throwJs(.RangeError, &.{ 'b', 'a', 'd' });
    return error.Thrown;
}

fn nativeCallJs(rt: *api.Runtime, _: ?*anyopaque, _: ?api.Handle, args: []const api.Handle, out: *api.NativeOut) api.NativeError!void {
    out.result = rt.call(args[0], null, &.{}, null) catch |e| switch (e) {
        error.OutputFailed => return error.HostError,
        else => |err| return err,
    };
}

test "M11.2: JS->native->JS exception propagation, uncatchable LimitExceeded, and stale thrown_value clearing" {
    var out_buf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const rt = try api.Runtime.create(testing.allocator, .{ .output = &out, .limits = .{ .max_steps = 5000 } });
    defer rt.destroy();

    try rt.defineGlobalFunction("nativeThrow", &nativeThrowJs, null);
    try rt.defineGlobalFunction("callJs", &nativeCallJs, null);

    // 1. Native throwJs and JS->native->JS throw both caught by outer JS try/catch.
    const src =
        \\try { nativeThrow(); } catch (e) { print(e.name); }
        \\function innerThrow() { throw 'from-inner'; }
        \\try { callJs(innerThrow); } catch (e) { print(e); }
    ;
    const p1 = try rt.compile("try_native.js", src, null);
    defer p1.destroy();
    try rt.run(p1, null);
    try testing.expectEqualStrings("RangeError\nfrom-inner\n", out.buffered());

    // 2. Stale thrown_value is cleared when a later throwJs / Runtime.throw sets rt.exception.
    const stale1 = try rt.compile("stale1.js", "throw 'stale-js';", null);
    defer stale1.destroy();
    var f1: api.Failure = .{};
    try testing.expectError(error.Thrown, rt.run(stale1, &f1));
    try testing.expect(std.mem.indexOf(u8, f1.message(), "stale-js") != null);

    const stale2 = try rt.compile("stale2.js", "nativeThrow();", null);
    defer stale2.destroy();
    var f2: api.Failure = .{};
    try testing.expectError(error.Thrown, rt.run(stale2, &f2));
    try testing.expect(std.mem.indexOf(u8, f2.message(), "RangeError: bad") != null);

    // 3. LimitExceeded inside try/catch is uncatchable.
    const lim = try rt.compile("lim.js", "let ran = false; try { while (true) {} } catch (e) { ran = true; }", null);
    defer lim.destroy();
    var f3: api.Failure = .{};
    try testing.expectError(error.LimitExceeded, rt.run(lim, &f3));
}

test "M11.3a: Math.random is deterministic per runtime seed and unimplemented Math members report Unsupported" {
    const src =
        \\for (let i = 0; i < 5; i++) {
        \\  let r = Math.random();
        \\  if (!(r >= 0 && r < 1)) throw 'out of range';
        \\  print(r);
        \\}
    ;

    // 1. Two runtimes with default seed produce identical sequences.
    var out1: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out1.deinit();
    var rt1 = try api.Runtime.create(testing.allocator, .{ .output = &out1.writer });
    defer rt1.destroy();
    const p1 = try rt1.compile("rand1.js", src, null);
    defer p1.destroy();
    try rt1.run(p1, null);

    var out2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out2.deinit();
    var rt2 = try api.Runtime.create(testing.allocator, .{ .output = &out2.writer });
    defer rt2.destroy();
    const p2 = try rt2.compile("rand2.js", src, null);
    defer p2.destroy();
    try rt2.run(p2, null);

    try testing.expectEqualStrings(out1.writer.buffered(), out2.writer.buffered());

    // 2. Two runtimes with the same explicit seed match, and a different seed diverges.
    var out3: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out3.deinit();
    var rt3 = try api.Runtime.create(testing.allocator, .{ .output = &out3.writer, .random_seed = 42 });
    defer rt3.destroy();
    const p3 = try rt3.compile("rand3.js", src, null);
    defer p3.destroy();
    try rt3.run(p3, null);

    var out4: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out4.deinit();
    var rt4 = try api.Runtime.create(testing.allocator, .{ .output = &out4.writer, .random_seed = 42 });
    defer rt4.destroy();
    const p4 = try rt4.compile("rand4.js", src, null);
    defer p4.destroy();
    try rt4.run(p4, null);

    try testing.expectEqualStrings(out3.writer.buffered(), out4.writer.buffered());
    try testing.expect(!std.mem.eql(u8, out1.writer.buffered(), out3.writer.buffered()));

    // 3. Unimplemented Math member (e.g. Math.cosh) raises Unsupported(builtin).
    const unsup = try rt1.compile("unsup.js", "Math.cosh;", null);
    defer unsup.destroy();
    var f: api.Failure = .{};
    try testing.expectError(error.Unsupported, rt1.run(unsup, &f));
    try testing.expect(std.mem.indexOf(u8, f.message(), "cosh") != null);
}

const CountingAllocator = struct {
    child: Allocator,
    live_bytes: usize = 0,

    fn allocator(self: *CountingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live_bytes += len;
        return p;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(buf, alignment, new_len, ret_addr)) return false;
        self.live_bytes = self.live_bytes - buf.len + new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
        self.live_bytes = self.live_bytes - buf.len + new_len;
        return p;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, alignment, ret_addr);
        self.live_bytes -= buf.len;
    }
};

fn findSuspendedCoroutine(h: *const zqjs.heap.Heap) ?*zqjs.heap.Coroutine {
    var cur = h.young;
    while (cur) |obj| : (cur = obj.next) {
        if (obj.kind == .coroutine) {
            const co: *zqjs.heap.Coroutine = @fieldParentPtr("obj", obj);
            if (co.state == .suspended) return co;
        }
    }
    cur = h.old;
    while (cur) |obj| : (cur = obj.next) {
        if (obj.kind == .coroutine) {
            const co: *zqjs.heap.Coroutine = @fieldParentPtr("obj", obj);
            if (co.state == .suspended) return co;
        }
    }
    return null;
}

test "M28b VM: suspended coroutine ownedBytes matches counting allocator and charge" {
    var counter: CountingAllocator = .{ .child = testing.allocator };
    const alloc = counter.allocator();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: zqjs.Diagnostic = .{};
    const src =
        \\async function hang(a, b) {
        \\    let x = a + b;
        \\    let y = x * 2;
        \\    await new Promise(() => {});
        \\    return y;
        \\}
        \\const p = hang(3, 4);
    ;
    const script = try zqjs.parse(arena.allocator(), src, .{}, &d);
    const res = try zqjs.resolve(arena.allocator(), script, &d);

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var rt = zqjs.Runtime.init(alloc, .{}, &discard.writer);
    defer rt.deinit();
    var proto = try zqjs.compile(testing.allocator, &rt.heap, script, res, .{}, &d);
    defer proto.deinit(testing.allocator);
    var f: zqjs.verify.Failure = .{};
    _ = try zqjs.verify.verify(testing.allocator, &proto, .{}, &f);

    var vm = try zqjs.Vm.init(&rt, &proto);
    defer vm.deinit();
    try vm.run();

    const co = findSuspendedCoroutine(&rt.heap) orelse return error.TestUnexpectedResult;
    const reported = co.vtable.ownedBytes(co.engine.?);
    try testing.expectEqual(reported, co.charge);

    const before = counter.live_bytes;
    co.vtable.destroy(co.engine.?);
    co.engine = null;
    const freed = before - counter.live_bytes;
    try testing.expectEqual(reported, freed);
}

test "M28b VM: checkAllAllocationFailures over async program" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: zqjs.Diagnostic = .{};
    const src =
        \\async function add1(x) {
        \\    return await Promise.resolve(x + 1);
        \\}
        \\add1(41).then(v => print(v));
    ;
    const script = try zqjs.parse(arena.allocator(), src, .{}, &d);
    const res = try zqjs.resolve(arena.allocator(), script, &d);

    const Ctx = struct {
        script: zqjs.ast.Script,
        res: zqjs.Resolution,

        fn runOnce(alloc: Allocator, ctx: @This()) !void {
            var discard: std.Io.Writer.Discarding = .init(&.{});
            var rt = zqjs.Runtime.init(alloc, .{}, &discard.writer);
            defer rt.deinit();
            var diag: zqjs.Diagnostic = .{};
            var proto = try zqjs.compile(alloc, &rt.heap, ctx.script, ctx.res, .{}, &diag);
            defer proto.deinit(alloc);
            var f: zqjs.verify.Failure = .{};
            _ = try zqjs.verify.verify(alloc, &proto, .{}, &f);
            var vm = try zqjs.Vm.init(&rt, &proto);
            defer vm.deinit();
            try vm.run();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Ctx.runOnce, .{Ctx{ .script = script, .res = res }});
}

test "M28b VM: uncatchable fault during resume leaves promise pending" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var d: zqjs.Diagnostic = .{};
    const src =
        \\async function inf() {
        \\    await 1;
        \\    while (true) {}
        \\}
        \\const p = inf();
    ;
    const script = try zqjs.parse(arena.allocator(), src, .{}, &d);
    const res = try zqjs.resolve(arena.allocator(), script, &d);

    var discard: std.Io.Writer.Discarding = .init(&.{});
    var rt = zqjs.Runtime.init(testing.allocator, .{ .max_steps = 50 }, &discard.writer);
    defer rt.deinit();
    var proto = try zqjs.compile(testing.allocator, &rt.heap, script, res, .{ .max_steps = 50 }, &d);
    defer proto.deinit(testing.allocator);
    var f: zqjs.verify.Failure = .{};
    _ = try zqjs.verify.verify(testing.allocator, &proto, .{ .max_steps = 50 }, &f);

    var vm = try zqjs.Vm.init(&rt, &proto);
    defer vm.deinit();
    try testing.expectError(error.LimitExceeded, vm.run());
    try testing.expectEqual(zqjs.Limit.steps, rt.limitHit().?);

    // `inf` is in script slot 0, `p` is in script slot 1; `p` must still be pending.
    const p_val = vm.locals[1].asValue();
    try testing.expect(p_val.isObject() and p_val.asObject().kind == .promise);
    try testing.expectEqual(zqjs.heap.PromiseStateTag.pending, p_val.asObject().kind.promise.state);
}

test "M52: property IC invalidation (delete/re-add, defineProperty accessor/writable, freeze, setPrototypeOf, polymorphic, array override)" {
    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const rt = try api.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    const src =
        \\function readX(o) { return o.x; }
        \\function writeX(o, v) { o.x = v; return o.x; }
        \\
        \\// 1. Delete and re-add changes property index.
        \\let a = { x: 1, y: 2 };
        \\print(readX(a), writeX(a, 10));
        \\delete a.x;
        \\a.x = 20;
        \\print(readX(a), writeX(a, 30));
        \\
        \\// 2. Polymorphic sites switching shapes.
        \\let b = { z: 0, x: 40 };
        \\print(readX(a), readX(b), writeX(b, 41), readX(a));
        \\
        \\// 3. Object.defineProperty converting data -> accessor & writable: false.
        \\let gets = 0;
        \\let sets = 0;
        \\Object.defineProperty(a, 'x', {
        \\  get() { gets++; return 99; },
        \\  set(v) { sets += v; },
        \\  configurable: true,
        \\});
        \\print(readX(a), writeX(a, 5), gets, sets);
        \\
        \\let ro = { x: 7 };
        \\print(writeX(ro, 8));
        \\Object.defineProperty(ro, 'x', { writable: false });
        \\let roErr = false;
        \\try { writeX(ro, 9); } catch (e) { roErr = e instanceof TypeError; }
        \\print(ro.x, roErr);
        \\
        \\// 4. Object.freeze & Object.setPrototypeOf.
        \\let fr = { x: 50 };
        \\print(writeX(fr, 51));
        \\Object.freeze(fr);
        \\let frErr = false;
        \\try { writeX(fr, 52); } catch (e) { frErr = e instanceof TypeError; }
        \\print(fr.x, frErr);
        \\
        \\let p1 = { k: 'one' };
        \\let p2 = { other: 0, k: 'two' };
        \\let child = Object.create(p1);
        \\function readK(o) { return o.k; }
        \\print(readK(child));
        \\Object.setPrototypeOf(child, p2);
        \\print(readK(child));
        \\child.k = 'own';
        \\print(readK(child));
        \\
        \\// 5. Array.prototype method IC hit + own property override + fastArraySet on frozen array.
        \\function pushOne(arr, v) { return arr.push(v); }
        \\let arr1 = [1];
        \\let arr2 = [2];
        \\arr2.push = function (v) { return v * 100; };
        \\print(pushOne(arr1, 9), arr1.length, pushOne(arr2, 3));
        \\let fa = [10, 20];
        \\fa[-0] = 11;
        \\Object.freeze(fa);
        \\let faErr = false;
        \\try { fa[0] = 99; } catch (e) { faErr = e instanceof TypeError; }
        \\print(fa[0], faErr);
    ;
    const prog = try rt.compile("m52_ic.js", src, null);
    defer prog.destroy();
    try rt.run(prog, null);
    try testing.expectEqualStrings(
        "1 10\n20 30\n30 40 41 30\n99 99 2 5\n8\n8 false\n51\n51 false\none\ntwo\nown\n2 2 300\n11 false\n",
        out.buffered(),
    );
}

test "M52: superinstructions (inc_local, dec_local, set_local_pop, lt/le_jump_if_false) edge cases" {
    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const rt = try api.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    const src =
        \\// inc_local / dec_local on number, BigInt, string, object valueOf, NaN
        \\let n = 5; n++; ++n; n--; --n;
        \\let bi = 10n; bi++; ++bi; bi--;
        \\let s = '41'; s++;
        \\let o = { valueOf() { return 99; } }; o++;
        \\let nan = NaN; nan++;
        \\print(n, bi, s, o, nan);
        \\
        \\// lt_jump_if_false / le_jump_if_false with NaN, strings, BigInt, throwing valueOf
        \\let hits = 0;
        \\if (NaN < 5) hits += 1;
        \\if (NaN <= 5) hits += 2;
        \\if ('a' < 'b') hits += 4;
        \\if (2n <= 2n) hits += 8;
        \\let threw = false;
        \\try {
        \\  let bad = { valueOf() { throw new Error('boom'); } };
        \\  if (bad < 1) hits += 16;
        \\} catch (e) {
        \\  threw = e.message === 'boom';
        \\}
        \\print(hits, threw);
        \\
        \\// TDZ on inc_local and set_local_pop
        \\let tdz1 = false;
        \\try { x++; let x = 1; } catch (e) { tdz1 = e instanceof ReferenceError; }
        \\let tdz2 = false;
        \\try { y = 2; let y = 1; } catch (e) { tdz2 = e instanceof ReferenceError; }
        \\print(tdz1, tdz2);
    ;
    const prog = try rt.compile("m52_super.js", src, null);
    defer prog.destroy();
    try rt.run(prog, null);
    try testing.expectEqualStrings(
        "5 11 42 100 NaN\n12 true\ntrue true\n",
        out.buffered(),
    );
}

test "M53: arithmetic-const, comparison-jump, set_prop/elem_pop, and fastRemainder short-circuit edge cases" {
    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const rt = try api.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    const src =
        \\function isNegZero(x) { return x === 0 && (1 / x) === -Infinity; }
        \\// add_const / sub_const / mul_const / mod_const on numbers, strings, objects
        \\let s = 'x';
        \\let o = { valueOf() { return 10; } };
        \\print(s + 1, o + 2, o - 3, o * 4, o % 6);
        \\// fastRemainder 0 < a < b short-circuit vs -0, 0, Infinity, fractions
        \\print(3 % 10, 5.5 % 10, 5 % Infinity, isNegZero(-0 % 10), isNegZero(0 % 10));
        \\// gt / ge / strict_eq / strict_ne_jump_if_false with NaN, strings, numbers
        \\let mask = 0;
        \\if (5 > 3) mask += 1;
        \\if (NaN > 3) mask += 2;
        \\if (3 >= 3) mask += 4;
        \\if (NaN >= 3) mask += 8;
        \\if ('a' === 'a') mask += 16;
        \\if (NaN === NaN) mask += 32;
        \\if (1 !== 2) mask += 64;
        \\if (NaN !== NaN) mask += 128;
        \\print(mask);
        \\// set_prop_pop / set_elem_pop
        \\let obj = { a: 1 };
        \\obj.a = 42;
        \\let arr = [1, 2];
        \\arr[1] = 99;
        \\arr.push(7);
        \\print(obj.a, arr[1], arr[2], arr.length);
    ;
    const prog = try rt.compile("m53_super.js", src, null);
    defer prog.destroy();
    try rt.run(prog, null);
    try testing.expectEqualStrings(
        "x1 12 7 40 4\n3 5.5 5 true false\n213\n42 99 7 3\n",
        out.buffered(),
    );
}

test "M54: flattened Slot, *_local arithmetic, get_elem_local, and loop clear_local TDZ preservation" {
    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const rt = try api.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    const src =
        \\// *_local with numbers, strings, objects, and BigInt
        \\let a = 10, b = 3, s = 'hi', o = { valueOf() { return 4; } };
        \\print(a + b, a - b, a * b, a % b, s + b, o + b);
        \\
        \\// TDZ on *_local preserves exact variable name
        \\let tdzMsg = '';
        \\try { 1 + lateVar; let lateVar = 2; } catch (e) { tdzMsg = e.name + ':' + (e.message.indexOf('lateVar') >= 0); }
        \\print(tdzMsg);
        \\
        \\// get_elem_local on array, object, string, and sibling-block slot reuse TDZ safety
        \\let arr = [10, 20, 30];
        \\let sum = 0;
        \\for (let i = 0; i < arr.length; i++) sum = sum + arr[i];
        \\let obj = { k: 77 };
        \\let key = 'k';
        \\let str = 'abc';
        \\let si = 1;
        \\print(sum, obj[key], str[si]);
        \\
        \\let sibTdz = false;
        \\{ let tmp = 1; }
        \\{ try { arr[reused]; } catch (e) { sibTdz = e instanceof ReferenceError; } let reused = 0; }
        \\print(sibTdz);
        \\
        \\// Loop-body TDZ must still throw even with dead clear_local elimination
        \\let loopTdz = 0;
        \\for (let i = 0; i < 2; i++) {
        \\  let ok = i + 1;
        \\  try { let bad = bad + ok; } catch (e) { if (e instanceof ReferenceError) loopTdz++; }
        \\}
        \\print(loopTdz);
    ;
    const prog = try rt.compile("m54_super.js", src, null);
    defer prog.destroy();
    try rt.run(prog, null);
    try testing.expectEqualStrings(
        "13 7 30 1 hi3 7\nReferenceError:true\n60 77 b\ntrue\n2\n",
        out.buffered(),
    );
}

test "M57: *_local_const_jif superinstructions (numbers, NaN, -0, BigInt, strings, TDZ) and pow2 remainder" {
    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const rt = try api.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    const src =
        \\// Numeric, NaN, -0, BigInt, and string comparisons on fused *_local_const_jif
        \\let n = 0;
        \\let hits = 0;
        \\for (let i = 0; i < 5; i++) {
        \\  if (i <= 2) hits++;
        \\  if (i === 3) hits += 10;
        \\  if (i !== 4) hits += 100;
        \\}
        \\let nan = NaN, neg0 = -0, bi = 2n, str = '2';
        \\print(hits,
        \\  (nan < 1 ? 1 : 0),
        \\  (nan <= 1 ? 1 : 0),
        \\  (nan === 1 ? 1 : 0),
        \\  (nan !== 1 ? 1 : 0),
        \\  (neg0 === 0 ? 1 : 0),
        \\  (bi < 3 ? 1 : 0),
        \\  (str === 2 ? 1 : 0),
        \\  (str !== 2 ? 1 : 0));
        \\
        \\// TDZ must still throw when local is uninitialized
        \\let tdz = false;
        \\{ try { if (u < 1) hits++; } catch (e) { tdz = e instanceof ReferenceError; } let u = 0; }
        \\print(tdz);
        \\
        \\// fastRemainder power-of-2 edge cases (-0, negatives, fractions, exact multiples)
        \\let r0 = (-0) % 4;
        \\print(Object.is(r0, -0), (-5) % 4, 5.5 % 4, 8 % 4, 9 % 4, 7 % 8);
    ;
    const prog = try rt.compile("m57_super.js", src, null);
    defer prog.destroy();
    try rt.run(prog, null);
    try testing.expectEqualStrings(
        "413 0 0 0 1 1 1 0 1\ntrue\ntrue -1 1.5 0 1 7\n",
        out.buffered(),
    );
}

test "M58: Shapes (inline/overflow/dict transitions, delete, freeze, and ADD-IC prototype invalidation)" {
    var out_buf: [512]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const rt = try api.Runtime.create(testing.allocator, .{ .output = &out });
    defer rt.destroy();

    const src =
        \\// 1. Shape inline slots (0..3), overflow slots (4..63), and dictionary fallback (>64)
        \\const big = {};
        \\for (let i = 0; i < 70; i++) big['k' + i] = i;
        \\print(big.k0, big.k3, big.k4, big.k63, big.k69, Object.keys(big).length);
        \\
        \\// 2. Tail delete (stays shaped) and non-tail delete (transitions to dict), preserving order
        \\const d = { a: 1, b: 2, c: 3 };
        \\delete d.c;
        \\d.d = 4;
        \\delete d.a;
        \\print(Object.keys(d).join(','), d.b, d.d);
        \\
        \\// 3. ADD-transition IC must respect setter / non-writable added to prototype later
        \\const proto = {};
        \\let setterHits = 0;
        \\function make(v) { const o = Object.create(proto); o.x = v; return o; }
        \\const a1 = make(10);
        \\const a2 = make(20);
        \\Object.defineProperty(proto, 'x', { set(v) { setterHits += v; }, configurable: true });
        \\const a3 = make(5);
        \\print(a1.x, a2.x, setterHits, Object.hasOwn(a3, 'x'));
        \\
        \\// 4. Object.freeze / seal on shaped objects
        \\const f = { p: 1, q: 2 };
        \\Object.freeze(f);
        \\f.p = 99;
        \\f.r = 3;
        \\print(Object.isFrozen(f), Object.isSealed(f), f.p, f.r);
    ;
    const prog = try rt.compile("m58_shapes.js", src, null);
    defer prog.destroy();
    try rt.run(prog, null);
    try testing.expectEqualStrings(
        "0 3 4 63 69 70\nb,d 2 4\n10 20 5 false\ntrue true 1 undefined\n",
        out.buffered(),
    );
}
