//! The VM's `step()` contract (DESIGN_DECISIONS D35), driven directly: one instruction
//! per call, budget charged first, precise faults, nothing executes after halt or a
//! fault, cleanup of partially initialised state, and the `--trace` format.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zqjs = @import("zqjs");
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
        _ = try zqjs.verify.verify(gpa, s.proto, limits, &f);
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
    try testing.expectEqual(@as(?zqjs.Value, .{ .number = 1 }), vm.slots[0]);
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
