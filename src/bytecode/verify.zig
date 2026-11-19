//! Bytecode verifier. Treats a Proto tree as untrusted input and proves the properties
//! the VM relies on:
//!
//!   1. sizes within Limits (code bytes of the whole tree, constants, names per Proto)
//!   2. every byte belongs to a well-formed instruction: valid opcode, operands
//!      complete (decoding never runs past the end). This covers *all* bytes, so
//!      malformed code can't hide in unreachable parts (after an unconditional jump).
//!   3. operands in range: slot < slot_count, const < consts.len, name < names.len,
//!      function < functions.len, capture < captures.len; constants are numbers or
//!      strings; param_count ≤ slot_count
//!   4. every jump target is the start of an instruction
//!   5. over all reachable paths: the stack never underflows, never exceeds
//!      `max_stack`, has the same depth wherever paths meet, is empty at `halt` and
//!      holds exactly the return value at `return`
//!   6. termination: no reachable instruction falls off the end of the code
//!   7. structure (M6): the root is the script and captures nothing; every nested Proto
//!      is a function; `halt` only in the script, `return` and `push_callee` only in
//!      functions; each function's capture descriptors point into its *parent*: a slot
//!      below the parent's slot_count or an entry of the parent's own captures, so
//!      `make_closure` (which reads them) can only copy existing cells
//!
//! It also reports what it measured (`Info`), so tests can check the compiler's
//! claims exactly: the stack depth actually reachable, and how much code is
//! unreachable (the compiler emits none).
//!
//! Not checked statically: whether a slot holds a value or a cell (the *_local vs
//! *_cell instructions). The VM checks that on every access; a mismatch is a VM or
//! compiler bug, never a JavaScript result. Nor does the verifier check *semantics*;
//! that is the differential tests' job.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Limits = @import("../limits.zig").Limits;
const bc = @import("bytecode.zig");
const Op = bc.Op;
const Proto = bc.Proto;

pub const Error = error{ InvalidBytecode, OutOfMemory };

/// Why verification failed: the offending Proto and instruction, and a static message.
pub const Failure = struct { proto: ?*const Proto = null, pc: u32 = 0, reason: []const u8 = "" };

pub const Info = struct {
    /// Deepest stack over all reachable paths of the root (≤ its max_stack).
    max_stack: u32 = 0,
    /// Instructions that no path from their Proto's entry reaches, over the whole tree.
    unreachable_instructions: u32 = 0,
    /// Protos whose declared max_stack is larger than what they can reach.
    inexact_max_stack: u32 = 0,
};

/// `root` (not a copy) because `failure.proto` points into the tree.
pub fn verify(gpa: Allocator, root: *const Proto, limits: Limits, failure: *Failure) Error!Info {
    var v: Verifier = .{ .gpa = gpa, .limits = limits, .failure = failure };
    if (root.kind != .script) return v.fail(root, 0, "the root is not a script");
    if (root.captures.len != 0) return v.fail(root, 0, "the script captures nothing");
    var info: Info = .{};
    info.max_stack = try v.proto(root, null, &info);
    return info;
}

const Verifier = struct {
    gpa: Allocator,
    limits: Limits,
    failure: *Failure,
    code_bytes: usize = 0,

    fn fail(v: *Verifier, p: *const Proto, pc: u32, reason: []const u8) Error {
        v.failure.* = .{ .proto = p, .pc = pc, .reason = reason };
        return error.InvalidBytecode;
    }

    /// Verifies `p` and its functions; returns the stack depth `p` can reach.
    fn proto(v: *Verifier, p: *const Proto, parent: ?*const Proto, info: *Info) Error!u32 {
        // 1. sizes
        v.code_bytes += p.code.len;
        if (v.code_bytes > v.limits.max_code_bytes) return v.fail(p, 0, "code larger than max_code_bytes");
        if (p.consts.len > v.limits.max_constants) return v.fail(p, 0, "more constants than max_constants");
        if (p.names.len > v.limits.max_constants) return v.fail(p, 0, "more names than max_constants");
        if (p.code.len == 0) return v.fail(p, 0, "empty code");
        if (@as(u64, p.param_slot) + p.param_count > p.slot_count) return v.fail(p, 0, "more parameters than slots");
        for (p.consts) |k| switch (k) {
            .number, .string => {},
            else => return v.fail(p, 0, "constant is not a number or string"),
        };
        // 7. structure: where this function's captures come from
        if (parent) |pp| for (p.captures) |c| switch (c.from) {
            .parent_slot => if (c.index >= pp.slot_count) return v.fail(p, 0, "capture from a slot the parent doesn't have"),
            .parent_capture => if (c.index >= pp.captures.len) return v.fail(p, 0, "capture from a capture the parent doesn't have"),
        };
        for (p.functions) |*f| if (f.kind != .function) return v.fail(p, 0, "a nested proto is not a function");

        // 2-3. decode every instruction linearly, recording where instructions start.
        var starts = try std.DynamicBitSetUnmanaged.initEmpty(v.gpa, p.code.len);
        defer starts.deinit(v.gpa);
        var count: u32 = 0;
        var pc: usize = 0;
        while (pc < p.code.len) {
            const at: u32 = @intCast(pc);
            const op = Op.decode(p.code[pc]) orelse return v.fail(p, at, "invalid opcode");
            if (op.size() > p.code.len - pc) return v.fail(p, at, "instruction runs past the end of the code");
            switch (op) {
                .halt => if (p.kind != .script) return v.fail(p, at, "halt in a function"),
                .@"return" => if (p.kind != .function) return v.fail(p, at, "return outside a function"),
                .push_callee => if (p.kind != .function) return v.fail(p, at, "push_callee outside a function"),
                .get_arg, .rest_array => if (p.kind != .function) return v.fail(p, at, "function-only instruction outside a function"),
                .await => if (p.kind != .function or !p.is_async or p.is_generator) return v.fail(p, at, "await outside an async function"),
                .generator_start, .yield, .yield_star_step => if (p.kind != .function or !p.is_generator) return v.fail(p, at, "generator instruction outside a generator"),
                .new_regexp => {
                    const k0 = bc.readU32(p.code, pc + 1);
                    const k1 = bc.readU32(p.code, pc + 5);
                    if (k0 < p.consts.len and k1 < p.consts.len) {
                        if (p.consts[k0] != .string or p.consts[k1] != .string)
                            return v.fail(p, at, "new_regexp operand is not a string constant");
                    }
                },
                .get_template_obj => {
                    const idx = bc.readU32(p.code, pc + 1);
                    if (idx >= p.templates.len)
                        return v.fail(p, at, "template index out of range");
                    const site = p.templates[idx];
                    if (site.cooked.len != site.raw.len)
                        return v.fail(p, at, "template cooked/raw length mismatch");
                    for (site.cooked) |k| {
                        if (k != std.math.maxInt(u32) and (k >= p.consts.len or p.consts[k] != .string))
                            return v.fail(p, at, "template cooked operand is not a string constant");
                    }
                    for (site.raw) |k| {
                        if (k >= p.consts.len or p.consts[k] != .string)
                            return v.fail(p, at, "template raw operand is not a string constant");
                    }
                },
                else => {},
            }
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
                    .function => x < p.functions.len,
                    .capture => x < p.captures.len,
                };
                if (!ok) return v.fail(p, at, switch (kind) {
                    .slot => "slot out of range",
                    .@"const" => "constant index out of range",
                    .name => "name index out of range",
                    .target => "jump target out of range",
                    .function => "function index out of range",
                    .capture => "capture index out of range",
                    .argc => unreachable,
                });
            }
            pc += op.size();
        }

        // 4. jump targets land on instruction starts.
        pc = 0;
        while (pc < p.code.len) : (pc += opAt(p, pc).size()) {
            if (target(p, pc)) |t| if (!starts.isSet(t)) return v.fail(p, @intCast(pc), "jump target inside an instruction");
        }
        for (p.handlers) |h| {
            if (h.try_start >= h.try_end or h.try_end > p.code.len) return v.fail(p, 0, "exception handler range out of bounds");
            if (!starts.isSet(h.try_start)) return v.fail(p, h.try_start, "exception handler try_start inside an instruction");
            if (h.try_end < p.code.len and !starts.isSet(h.try_end)) return v.fail(p, h.try_end, "exception handler try_end inside an instruction");
            if (h.catch_pc >= p.code.len or !starts.isSet(h.catch_pc)) return v.fail(p, 0, "exception handler catch_pc invalid");
            if (h.stack_depth + @intFromBool(h.has_binding) > p.max_stack) return v.fail(p, h.catch_pc, "exception handler stack depth exceeds max_stack");
        }

        // 5-6. abstract interpretation: stack depth at entry of each reachable instruction.
        const unvisited = std.math.maxInt(u32);
        const depth = try v.gpa.alloc(u32, p.code.len);
        defer v.gpa.free(depth);
        @memset(depth, unvisited);
        var work: std.ArrayList(u32) = .empty;
        defer work.deinit(v.gpa);
        try work.ensureTotalCapacity(v.gpa, count); // each instruction is queued at most once

        var max: u32 = 0;
        var reached: u32 = 1;
        depth[0] = 0;
        work.appendAssumeCapacity(0);
        for (p.handlers) |h| {
            const catch_depth = h.stack_depth + @intFromBool(h.has_binding);
            if (depth[h.catch_pc] == unvisited) {
                depth[h.catch_pc] = catch_depth;
                work.appendAssumeCapacity(h.catch_pc);
                reached += 1;
            } else if (depth[h.catch_pc] != catch_depth) {
                return v.fail(p, h.catch_pc, "inconsistent stack depth at catch handler");
            }
        }
        while (work.pop()) |at| {
            const op = opAt(p, at);
            const op_info = op.info();
            const d: u64 = depth[at];
            const argc: u32 = if (op_info.operands.len > 0 and op_info.operands[0] == .argc) bc.readU32(p.code, at + 1) else 0;
            const pops = op.popsWith(argc);
            if (d < pops) return v.fail(p, at, "stack underflow");
            const after = d - pops + op_info.pushes;
            // An instruction that pops and pushes (dup) peaks at its result depth.
            if (after > p.max_stack) return v.fail(p, at, "stack deeper than max_stack");
            max = @max(max, @as(u32, @intCast(after)));

            var succ: [2]?u32 = .{ null, null };
            switch (op) {
                .halt => if (after != 0) return v.fail(p, at, "stack not empty at halt"),
                .@"return" => if (after != 0) return v.fail(p, at, "stack holds more than the return value at return"),
                .throw => {},
                .jump => succ[0] = target(p, at).?,
                else => {
                    const next = at + op.size();
                    if (next >= p.code.len) return v.fail(p, at, "execution falls off the end of the code");
                    succ[0] = next;
                    succ[1] = target(p, at); // conditional jumps
                },
            }
            for (succ) |maybe| if (maybe) |s| {
                if (depth[s] == unvisited) {
                    depth[s] = @intCast(after);
                    work.appendAssumeCapacity(s);
                    reached += 1;
                } else if (depth[s] != after) {
                    return v.fail(p, s, "inconsistent stack depth where paths meet");
                }
            };
        }
        info.unreachable_instructions += count - reached;
        if (max != p.max_stack) info.inexact_max_stack += 1;

        // 7. the nested functions, with this Proto as their parent.
        for (p.functions) |*f| _ = try v.proto(f, p, info);
        return max;
    }
};

/// Only for offsets already known to start a valid instruction.
fn opAt(p: *const Proto, pc: usize) Op {
    return @fromBackingInt(@intCast(p.code[pc]));
}

fn target(p: *const Proto, pc: usize) ?u32 {
    return switch (opAt(p, pc)) {
        .jump, .jump_if_false, .jump_if_true => bc.readU32(p.code, pc + 1),
        else => null,
    };
}

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
    try testing.expectError(error.InvalidBytecode, verify(testing.allocator, &p, .{}, &f));
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
    const info = try verify(testing.allocator, &p, .{}, &f);
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
    try expectInvalid(enc(.{ .get_global_or_undefined, 1, .pop, .halt }), 1, "name index out of range");
    try expectInvalid(enc(.{ .get_global_or_undefined, 0, .typeof, .pop, .halt }), 0, "stack deeper than max_stack");
    try expectInvalid(enc(.{ .typeof, .halt }), 0, "stack underflow");
    try expectInvalid(enc(.{ .jump, 100 }), 0, "jump target out of range");
    try expectInvalid(enc(.{ .jump, 2, .halt }), 0, "jump target inside an instruction");
    try expectInvalid(enc(.{ .pop, .halt }), 0, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .push_null, .call, 2, .pop, .halt }), 2, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .dup, .pop, .pop, .halt }), 1, "stack deeper than max_stack");
    try expectInvalid(enc(.{ .push_null, .halt }), 1, "stack not empty at halt");
    try expectInvalid(enc(.{.push_null}), 1, "execution falls off the end of the code");
    // M7: instructions whose pops depend on their operand, and the stack shuffles.
    try expectInvalid(enc(.{ .push_null, .new_array, 2, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .push_null, .call_method, 1, .pop, .halt }), 2, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .push_null, .rot3, .halt }), 2, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .dup2, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .push_null, .dup2, .pop, .pop, .pop, .pop, .halt }), 3, "stack deeper than max_stack");
    try expectInvalid(enc(.{ .new_object, .get_prop, 1, .pop, .halt }), 1, "name index out of range");
    // Two paths reach offset 7 (`halt`), one with an extra value on the stack.
    try expectInvalid(enc(.{ .push_true, .jump_if_false, 7, .push_null, .halt }), 1, "inconsistent stack depth where paths meet");
    // M22: bitwise opcodes pop 2 / 1 and push 1.
    try expectInvalid(enc(.{ .push_null, .shl, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .shr, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .ushr, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .bit_and, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .bit_xor, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .bit_or, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .bit_not, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .iter_close, .halt }), 0, "stack underflow");
    try expectInvalid(enc(.{ .iter_close_throw, .halt }), 0, "stack underflow");
}

test "limits are checked again, and constants must be numbers or strings" {
    var f: Failure = .{};
    const code = enc(.{.halt});
    try testing.expectError(error.InvalidBytecode, verify(testing.allocator, &.{ .code = code, .consts = &.{}, .names = &.{}, .slot_count = 0, .max_stack = 0 }, .{ .max_code_bytes = 0 }, &f));
    try testing.expectEqualStrings("code larger than max_code_bytes", f.reason);
    try testing.expectError(error.InvalidBytecode, verify(testing.allocator, &.{ .code = code, .consts = &.{.null}, .names = &.{}, .slot_count = 0, .max_stack = 0 }, .{}, &f));
    try testing.expectEqualStrings("constant is not a number or string", f.reason);
}

/// A script `make_closure 0; pop; halt` (1 slot) around one function, to test the rules
/// about nested Protos. Returns the failure reason, or null if the tree verifies.
fn verifyTree(child: Proto) !?[]const u8 {
    var children = [_]Proto{child};
    const root: Proto = .{ .code = enc(.{ .make_closure, 0, .pop, .halt }), .consts = &.{}, .names = &.{"x"}, .slot_count = 1, .max_stack = 1, .functions = &children };
    var f: Failure = .{};
    _ = verify(testing.allocator, &root, .{}, &f) catch |e| switch (e) {
        error.InvalidBytecode => {
            try testing.expectEqual(@as(?*const Proto, &children[0]), f.proto); // the failing Proto is named
            return f.reason;
        },
        else => return e,
    };
    return null;
}

fn function(code: []const u8, opts: struct { slots: u32 = 0, stack: u32 = 1, params: u32 = 0, captures: []const Proto.Capture = &.{} }) Proto {
    return .{ .kind = .function, .code = code, .consts = &.{}, .names = &.{"x"}, .slot_count = opts.slots, .max_stack = opts.stack, .param_count = opts.params, .captures = opts.captures };
}

test "nested functions: structure and capture descriptors" {
    const ret = enc(.{ .push_undefined, .@"return" });
    try testing.expectEqual(@as(?[]const u8, null), try verifyTree(function(ret, .{})));
    try testing.expectEqual(@as(?[]const u8, null), try verifyTree(function(enc(.{ .get_capture, 0, 0, .@"return" }), .{ .captures = &.{.{ .from = .parent_slot, .index = 0 }} })));
    try testing.expectEqualStrings("capture from a slot the parent doesn't have", (try verifyTree(function(ret, .{ .captures = &.{.{ .from = .parent_slot, .index = 1 }} }))).?);
    try testing.expectEqualStrings("capture from a capture the parent doesn't have", (try verifyTree(function(ret, .{ .captures = &.{.{ .from = .parent_capture, .index = 0 }} }))).?);
    try testing.expectEqualStrings("capture index out of range", (try verifyTree(function(enc(.{ .get_capture, 0, 0, .@"return" }), .{}))).?);
    try testing.expectEqualStrings("halt in a function", (try verifyTree(function(enc(.{.halt}), .{}))).?);
    try testing.expectEqualStrings("stack holds more than the return value at return", (try verifyTree(function(enc(.{ .push_null, .push_null, .@"return" }), .{ .stack = 2 }))).?);
    try testing.expectEqualStrings("stack underflow", (try verifyTree(function(enc(.{.@"return"}), .{}))).?);
    try testing.expectEqualStrings("more parameters than slots", (try verifyTree(function(ret, .{ .params = 1 }))).?);
    try testing.expectEqualStrings("function index out of range", (try verifyTree(function(enc(.{ .make_closure, 0, .@"return" }), .{}))).?);
    try testing.expectEqualStrings("execution falls off the end of the code", (try verifyTree(function(enc(.{.push_undefined}), .{}))).?);
    // Malformed code after an unconditional jump is still rejected: every byte is decoded.
    try testing.expectEqualStrings("invalid opcode", (try verifyTree(function(comptime enc(.{ .jump, 0 }) ++ &[_]u8{0xff}, .{}))).?);
    var script_child = function(ret, .{});
    script_child.kind = .script;
    try testing.expectEqualStrings("a nested proto is not a function", blk: {
        var children = [_]Proto{script_child};
        const root: Proto = .{ .code = enc(.{.halt}), .consts = &.{}, .names = &.{}, .slot_count = 0, .max_stack = 0, .functions = &children };
        var f: Failure = .{};
        try testing.expectError(error.InvalidBytecode, verify(testing.allocator, &root, .{}, &f));
        break :blk f.reason;
    });
}

test "return and push_callee only in functions; the script captures nothing" {
    try expectInvalid(enc(.{ .push_null, .@"return" }), 1, "return outside a function");
    try expectInvalid(enc(.{ .push_callee, .pop, .halt }), 1, "push_callee outside a function");
    var f: Failure = .{};
    const root: Proto = .{ .code = enc(.{.halt}), .consts = &.{}, .names = &.{}, .slot_count = 0, .max_stack = 0, .captures = &.{.{ .from = .parent_slot, .index = 0 }} };
    try testing.expectError(error.InvalidBytecode, verify(testing.allocator, &root, .{}, &f));
    try testing.expectEqualStrings("the script captures nothing", f.reason);
}

test "the code-size limit covers the whole tree" {
    const ret = enc(.{ .push_undefined, .@"return" });
    var children = [_]Proto{function(ret, .{})};
    const root: Proto = .{ .code = enc(.{ .make_closure, 0, .pop, .halt }), .consts = &.{}, .names = &.{}, .slot_count = 0, .max_stack = 1, .functions = &children };
    var f: Failure = .{};
    _ = try verify(testing.allocator, &root, .{ .max_code_bytes = 9 }, &f); // 7 + 2 bytes
    try testing.expectError(error.InvalidBytecode, verify(testing.allocator, &root, .{ .max_code_bytes = 8 }, &f));
}

test "instanceof pops 2, pushes 1 and checks underflow" {
    const ok: Proto = .{ .code = enc(.{ .push_null, .push_null, .instanceof, .pop, .halt }), .consts = &.{}, .names = &.{}, .slot_count = 0, .max_stack = 2 };
    var f: Failure = .{};
    try testing.expectEqual(@as(u32, 2), (try verify(testing.allocator, &ok, .{}, &f)).max_stack);
    try expectInvalid(enc(.{ .push_null, .instanceof, .pop, .halt }), 1, "stack underflow");
}

test "M26: new opcodes verification rules" {
    // get_arg and rest_array are only allowed in functions.
    try expectInvalid(enc(.{ .get_arg, 0, .pop, .halt }), 1, "function-only instruction outside a function");
    try expectInvalid(enc(.{ .rest_array, 0, .pop, .halt }), 1, "function-only instruction outside a function");
    // Valid inside functions with exact max_stack.
    try testing.expectEqual(@as(?[]const u8, null), try verifyTree(function(enc(.{ .get_arg, 0, .@"return" }), .{ .stack = 1 })));
    try testing.expectEqual(@as(?[]const u8, null), try verifyTree(function(enc(.{ .rest_array, 0, .@"return" }), .{ .stack = 1 })));

    // Stack underflow checks for spread, array, object, and destructuring opcodes.
    try expectInvalid(enc(.{ .array_push, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .array_push, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .array_spread, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .object_spread, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .call_spread, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .call_method_spread, .pop, .halt }), 2, "stack underflow");
    try expectInvalid(enc(.{ .push_null, .push_null, .call_method_spread, .pop, .halt }), 2, "stack underflow");
    try expectInvalid(enc(.{ .new_call_spread, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .iter_rest, .pop, .halt }), 1, "stack underflow");
    try expectInvalid(enc(.{ .require_obj, .pop, .halt }), 1, "stack underflow");
    // object_rest pops 1 + argc values.
    try expectInvalid(enc(.{ .push_null, .push_null, .object_rest, 2, .pop, .halt }), 2, "stack underflow");

    // Valid stack effects for M26 opcodes.
    var f: Failure = .{};
    const valid_spread: Proto = .{
        .code = enc(.{
            .new_array,          0,
            .push_null,          .array_push,
            .push_null,          .array_spread,
            .pop,                .new_object,
            .push_null,          .object_spread,
            .require_obj,        .push_null,
            .push_null,          .object_rest,
            2,                   .pop,
            .push_null,          .iter_rest,
            .pop,                .push_null,
            .new_array,          0,
            .call_spread,        .pop,
            .push_null,          .push_null,
            .new_array,          0,
            .call_method_spread, .pop,
            .push_null,          .new_array,
            0,                   .new_call_spread,
            .pop,                .halt,
        }),
        .consts = &.{},
        .names = &.{},
        .slot_count = 0,
        .max_stack = 3,
    };
    const info = try verify(testing.allocator, &valid_spread, .{}, &f);
    try testing.expectEqual(@as(u32, 3), info.max_stack);
    try testing.expectEqual(@as(u32, 0), info.unreachable_instructions);
    try testing.expectEqual(@as(u32, 0), info.inexact_max_stack);
}

test "M30: new_regexp requires two string constant operands" {
    const heap = @import("../runtime/heap.zig");
    var s0: heap.String = .{ .obj = .{ .kind = .string, .next = null }, .units = &.{'a'} };
    var s1: heap.String = .{ .obj = .{ .kind = .string, .next = null }, .units = &.{'g'} };
    const ok: Proto = .{
        .code = enc(.{ .new_regexp, 0, 1, .pop, .halt }),
        .consts = &.{ .{ .string = &s0 }, .{ .string = &s1 } },
        .names = &.{},
        .slot_count = 0,
        .max_stack = 1,
    };
    var f: Failure = .{};
    try testing.expectEqual(@as(u32, 1), (try verify(testing.allocator, &ok, .{}, &f)).max_stack);

    try expectInvalid(enc(.{ .new_regexp, 0, 2, .pop, .halt }), 1, "constant index out of range");

    const bad_type: Proto = .{
        .code = enc(.{ .new_regexp, 0, 1, .pop, .halt }),
        .consts = &.{ .{ .string = &s0 }, .{ .number = 1 } },
        .names = &.{},
        .slot_count = 0,
        .max_stack = 1,
    };
    try testing.expectError(error.InvalidBytecode, verify(testing.allocator, &bad_type, .{}, &f));
    try testing.expectEqualStrings("new_regexp operand is not a string constant", f.reason);
}
