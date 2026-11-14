//! Bytecode verifier. Treats a Proto as untrusted input and proves the properties the
//! M5 VM relies on to run without bounds checks:
//!
//!   1. sizes within Limits (code bytes, constants, names)
//!   2. every byte belongs to a well-formed instruction: valid opcode, operands
//!      complete (decoding never runs past the end)
//!   3. operands in range: slot < slot_count, const < consts.len, name < names.len,
//!      and constants are numbers or strings
//!   4. every jump target is the start of an instruction
//!   5. over all reachable paths: the stack never underflows, never exceeds
//!      `max_stack`, has the same depth wherever paths meet, and is empty at `halt`
//!   6. termination: no reachable instruction falls off the end of the code
//!
//! It also reports what it measured (`Info`), so tests can check the compiler's
//! claims exactly: the deepest stack actually reachable, and how much code is
//! unreachable (the compiler emits none).
//!
//! The verifier does not check *semantics* (that the code does what the source says);
//! that is the differential tests' job from M5 on.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Limits = @import("../limits.zig").Limits;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const Proto = bc.Proto;

pub const Error = error{ InvalidBytecode, OutOfMemory };

/// Why verification failed: the offending instruction and a static message.
pub const Failure = struct { pc: u32 = 0, reason: []const u8 = "" };

pub const Info = struct {
    /// Deepest stack over all reachable paths (≤ Proto.max_stack).
    max_stack: u32,
    /// Instructions that no path from the entry reaches.
    unreachable_instructions: u32,
};

pub fn verify(gpa: Allocator, p: Proto, limits: Limits, failure: *Failure) Error!Info {
    var v: Verifier = .{ .p = p, .failure = failure };
    // 1. sizes
    if (p.code.len > limits.max_code_bytes) return v.fail(0, "code larger than max_code_bytes");
    if (p.consts.len > limits.max_constants) return v.fail(0, "more constants than max_constants");
    if (p.names.len > limits.max_constants) return v.fail(0, "more names than max_constants");
    if (p.code.len == 0) return v.fail(0, "empty code");
    for (p.consts) |k| switch (k) {
        .number, .string => {},
        else => return v.fail(0, "constant is not a number or string"),
    };

    // 2-3. decode every instruction linearly, recording where instructions start.
    var starts = try std.DynamicBitSetUnmanaged.initEmpty(gpa, p.code.len);
    defer starts.deinit(gpa);
    var count: u32 = 0;
    var pc: usize = 0;
    while (pc < p.code.len) {
        const at: u32 = @intCast(pc);
        const op = std.enums.fromInt(Op, p.code[pc]) orelse return v.fail(at, "invalid opcode");
        if (op.size() > p.code.len - pc) return v.fail(at, "instruction runs past the end of the code");
        starts.set(pc);
        count += 1;
        for (op.info().operands, 0..) |kind, i| {
            const x = bc.readU32(p.code, pc + 1 + 4 * i);
            const ok = switch (kind) {
                .slot => x < p.slot_count,
                .@"const" => x < p.consts.len,
                .name => x < p.names.len,
                .target => x < p.code.len, // boundary checked below
                .argc => true, // bounded by the stack check
            };
            if (!ok) return v.fail(at, switch (kind) {
                .slot => "slot out of range",
                .@"const" => "constant index out of range",
                .name => "name index out of range",
                .target => "jump target out of range",
                .argc => unreachable,
            });
        }
        pc += op.size();
    }

    // 4. jump targets land on instruction starts.
    pc = 0;
    while (pc < p.code.len) : (pc += v.opAt(pc).size()) {
        if (v.target(pc)) |t| if (!starts.isSet(t)) return v.fail(@intCast(pc), "jump target inside an instruction");
    }

    // 5-6. abstract interpretation: stack depth at entry of each reachable instruction.
    const unvisited = std.math.maxInt(u32);
    const depth = try gpa.alloc(u32, p.code.len);
    defer gpa.free(depth);
    @memset(depth, unvisited);
    var work: std.ArrayList(u32) = .empty;
    defer work.deinit(gpa);
    try work.ensureTotalCapacity(gpa, count); // each instruction is queued at most once

    var max: u32 = 0;
    var reached: u32 = 1;
    depth[0] = 0;
    work.appendAssumeCapacity(0);
    while (work.pop()) |at| {
        const op = v.opAt(at);
        const info = op.info();
        const d: u64 = depth[at];
        const pops: u64 = @as(u64, info.pops) + if (op == .call) bc.readU32(p.code, at + 1) else 0;
        if (d < pops) return v.fail(at, "stack underflow");
        const after = d - pops + info.pushes;
        // An instruction that pops and pushes (dup) peaks at its result depth.
        if (after > p.max_stack) return v.fail(at, "stack deeper than max_stack");
        max = @max(max, @as(u32, @intCast(after)));

        var succ: [2]?u32 = .{ null, null };
        switch (op) {
            .halt => if (after != 0) return v.fail(at, "stack not empty at halt"),
            .jump => succ[0] = v.target(at).?,
            else => {
                const next = at + op.size();
                if (next >= p.code.len) return v.fail(at, "execution falls off the end of the code");
                succ[0] = next;
                succ[1] = v.target(at); // conditional jumps
            },
        }
        for (succ) |maybe| if (maybe) |s| {
            if (depth[s] == unvisited) {
                depth[s] = @intCast(after);
                work.appendAssumeCapacity(s);
                reached += 1;
            } else if (depth[s] != after) {
                return v.fail(s, "inconsistent stack depth where paths meet");
            }
        };
    }
    return .{ .max_stack = max, .unreachable_instructions = count - reached };
}

const Verifier = struct {
    p: Proto,
    failure: *Failure,

    fn fail(v: *Verifier, pc: u32, reason: []const u8) Error {
        v.failure.* = .{ .pc = pc, .reason = reason };
        return error.InvalidBytecode;
    }

    /// Only for offsets already known to start a valid instruction.
    fn opAt(v: *const Verifier, pc: usize) Op {
        return @fromBackingInt(@intCast(v.p.code[pc]));
    }

    fn target(v: *const Verifier, pc: usize) ?u32 {
        return switch (v.opAt(pc)) {
            .jump, .jump_if_false, .jump_if_true => bc.readU32(v.p.code, pc + 1),
            else => null,
        };
    }
};

// ---- unit tests: hand-written bytecode, one per rule

const testing = std.testing;

fn enc(comptime parts: anytype) []const u8 {
    const bytes = comptime blk: {
        var out: []const u8 = &.{};
        for (parts) |part| out = out ++ switch (@typeInfo(@TypeOf(part))) {
            .enum_literal => &[_]u8{@backingInt(@as(Op, part))},
            .comptime_int => &std.mem.toBytes(std.mem.nativeToLittle(u32, part)),
            else => @compileError("opcode or integer"),
        };
        break :blk out;
    };
    return bytes;
}

fn expectInvalid(code: []const u8, max_stack: u32, reason: []const u8) !void {
    var f: Failure = .{};
    const p: Proto = .{ .code = code, .consts = &.{.{ .number = 1 }}, .names = &.{"x"}, .slot_count = 1, .max_stack = max_stack };
    try testing.expectError(error.InvalidBytecode, verify(testing.allocator, p, .{}, &f));
    try testing.expectEqualStrings(reason, f.reason);
}

test "valid code reports its real stack use and unreachable code" {
    var f: Failure = .{};
    const p: Proto = .{
        .code = enc(.{ .push_const, 0, .dup, .add, .pop, .jump, 14, .pop, .halt }),
        .consts = &.{.{ .number = 1 }},
        .names = &.{},
        .slot_count = 0,
        .max_stack = 5, // a generous claim is safe; Info reports the truth
    };
    const info = try verify(testing.allocator, p, .{}, &f);
    try testing.expectEqual(@as(u32, 2), info.max_stack);
    try testing.expectEqual(@as(u32, 1), info.unreachable_instructions); // the second pop
}

test "every rule rejects malformed code" {
    try expectInvalid(&.{}, 0, "empty code");
    try expectInvalid(&.{0xff}, 0, "invalid opcode");
    try expectInvalid(comptime enc(.{.push_const}) ++ &[_]u8{ 0, 0 }, 1, "instruction runs past the end of the code");
    try expectInvalid(enc(.{ .push_const, 1, .pop, .halt }), 1, "constant index out of range");
    try expectInvalid(enc(.{ .get_local, 1, 0, .pop, .halt }), 1, "slot out of range");
    try expectInvalid(enc(.{ .get_global, 1, .pop, .halt }), 1, "name index out of range");
    try expectInvalid(enc(.{ .jump, 100 }), 0, "jump target out of range");
    try expectInvalid(enc(.{ .jump, 2, .halt }), 0, "jump target inside an instruction");
    try expectInvalid(enc(.{ .pop, .halt }), 0, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .push_null, .call, 2, .pop, .halt }), 2, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .dup, .pop, .pop, .halt }), 1, "stack deeper than max_stack");
    try expectInvalid(enc(.{ .push_null, .halt }), 1, "stack not empty at halt");
    try expectInvalid(enc(.{.push_null}), 1, "execution falls off the end of the code");
    // Two paths reach offset 7 (`halt`), one with an extra value on the stack.
    try expectInvalid(enc(.{ .push_true, .jump_if_false, 7, .push_null, .halt }), 1, "inconsistent stack depth where paths meet");
}

test "limits are checked again, and constants must be numbers or strings" {
    var f: Failure = .{};
    const code = enc(.{.halt});
    try testing.expectError(error.InvalidBytecode, verify(testing.allocator, .{ .code = code, .consts = &.{}, .names = &.{}, .slot_count = 0, .max_stack = 0 }, .{ .max_code_bytes = 0 }, &f));
    try testing.expectEqualStrings("code larger than max_code_bytes", f.reason);
    try testing.expectError(error.InvalidBytecode, verify(testing.allocator, .{ .code = code, .consts = &.{.null}, .names = &.{}, .slot_count = 0, .max_stack = 0 }, .{}, &f));
    try testing.expectEqualStrings("constant is not a number or string", f.reason);
}
