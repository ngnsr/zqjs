//! M4: bytecode compiler, verifier and disassembler. Nothing executes bytecode yet (the
//! VM is M5), so the oracle here is the verifier: every program we have must compile to
//! bytecode it accepts, with exactly the stack depth the compiler claims and no
//! unreachable code.
//!
//! Snapshots: tests/bytecode/NAME.js and NAME.txt (its `zqjs --dump-bytecode` listing).
//! After an intended change, regenerate and review the diff:
//!   for f in tests/bytecode/*.js; do zig-out/bin/zqjs --dump-bytecode "$f" > "${f%.js}.txt"; done

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zqjs = @import("zqjs");
const Limits = zqjs.Limits;

const Compiled = struct {
    proto: zqjs.bytecode.Proto,
    heap: zqjs.Heap,

    fn deinit(c: *Compiled, gpa: Allocator) void {
        c.proto.deinit(gpa);
        c.heap.deinit();
    }
};

/// parse → resolve → compile → verify, and check the compiler's claims against what the
/// verifier measured. Front-end rejections return their error (callers decide).
fn compileChecked(gpa: Allocator, source: []const u8, limits: Limits, diag: *zqjs.Diagnostic) !Compiled {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const script = try zqjs.parse(arena.allocator(), source, limits, diag);
    const res = try zqjs.resolve(arena.allocator(), script, diag);
    var heap = zqjs.Heap.init(gpa, limits);
    errdefer heap.deinit();
    var proto = zqjs.compile(gpa, &heap, script, res, limits, diag) catch |e| {
        // A failed compile leaves no trace on the heap (Heap.rollback).
        try testing.expect(heap.young == null and heap.old == null);
        try testing.expectEqual(@as(usize, 0), heap.bytes);
        return e;
    };
    errdefer proto.deinit(gpa);
    var failure: zqjs.verify.Failure = .{};
    const info = zqjs.verify.verify(gpa, &proto, limits, &failure) catch |e| {
        if (e == error.InvalidBytecode) std.debug.print("invalid bytecode at {d}: {s}\nsource: {s}\n", .{ failure.pc, failure.reason, source });
        return e;
    };
    if (info.max_stack != proto.max_stack or info.unreachable_instructions != 0) {
        std.debug.print("compiler claims max_stack {d}, verifier measured {d}; {d} unreachable instructions\nsource: {s}\n", .{ proto.max_stack, info.max_stack, info.unreachable_instructions, source });
        return error.TestUnexpectedResult;
    }
    return .{ .proto = proto, .heap = heap };
}

fn expectCompiles(source: []const u8) !void {
    var diag: zqjs.Diagnostic = .{};
    var c = try compileChecked(testing.allocator, source, .{}, &diag);
    c.deinit(testing.allocator);
}

test "every diff program and every accepted syntax case compiles to verified bytecode" {
    const io = testing.io;
    const gpa = testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/diff", .{ .iterate = true });
    defer dir.close(io);
    var programs: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".js")) continue;
        const source = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        defer gpa.free(source);
        try expectCompiles(source);
        programs += 1;
    }
    try testing.expect(programs > 0);

    var cases: usize = 0;
    var lines = std.mem.splitScalar(u8, @embedFile("syntax/cases.jsonl"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice([]const []const u8, gpa, line, .{});
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value[0], "ok")) continue;
        try expectCompiles(parsed.value[1]);
        cases += 1;
    }
    try testing.expect(cases > 50);
}

test "unreachable code is not emitted, and max_stack is exact" {
    for ([_][]const u8{
        "while (true) { break; print(1, 2, 3); }", // after break
        "for (;;) { continue; print(1, 2, 3); }", // after continue; update unreachable too
        "for (let i = 0; ; i++) { if (i) break; else continue; print(1, 2, 3); }", // both branches leave
        "for (;;) {} print(1, 2, 3);", // after a loop with no exit
        "for (;;) { break; } print(1, 2, 3);", // ... but reachable when it has one
        "{ { 1; } } { let x = 1; { let x = 2; } }", // plain blocks
        "let a = 1; a = a && (a || print(a, a, a)); print(a++, ++a, a--, --a);",
    }) |src| try expectCompiles(src);
}

test "bytecode snapshots" {
    const io = testing.io;
    const gpa = testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(io, "tests/bytecode", .{ .iterate = true });
    defer dir.close(io);
    var count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".js")) continue;
        count += 1;
        const source = try dir.readFileAlloc(io, entry.name, gpa, .limited(1 << 20));
        defer gpa.free(source);
        const txt = try std.fmt.allocPrint(gpa, "{s}.txt", .{entry.name[0 .. entry.name.len - 3]});
        defer gpa.free(txt);
        const expected = try dir.readFileAlloc(io, txt, gpa, .limited(1 << 20));
        defer gpa.free(expected);

        var diag: zqjs.Diagnostic = .{};
        var c = try compileChecked(gpa, source, .{}, &diag);
        defer c.deinit(gpa);
        var got: std.Io.Writer.Allocating = .init(gpa);
        defer got.deinit();
        try zqjs.disassemble(c.proto, &got.writer);
        if (!std.mem.eql(u8, got.written(), expected)) {
            std.debug.print("\n== {s}\n-- expected\n{s}-- got\n{s}", .{ entry.name, expected, got.written() });
            failures += 1;
        }
    }
    try testing.expect(count > 0);
    try testing.expectEqual(@as(usize, 0), failures);
}

test "constant pool and name table are deduplicated" {
    var diag: zqjs.Diagnostic = .{};
    var c = try compileChecked(testing.allocator, "1; 1; 'a'; 'a'; '\\u0061'; 2; 1.0; print(1); print(x); print;", .{}, &diag);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), c.proto.consts.len); // 1, 'a', 2
    try testing.expectEqual(@as(usize, 2), c.proto.names.len); // print, x
    try testing.expectEqual(@as(f64, 2), c.proto.consts[2].number);
}

fn expectLimit(source: []const u8, limits: Limits, which: zqjs.Limit) !void {
    var diag: zqjs.Diagnostic = .{};
    try testing.expectError(error.LimitExceeded, compileChecked(testing.allocator, source, limits, &diag));
    try testing.expectEqual(which, diag.detail.limit_exceeded);
}

test "code size, pool sizes and the heap are limited, and a failed compile frees its strings" {
    try expectLimit("let x = 1; x = x + 1; x = x + 1;", .{ .max_code_bytes = 40 }, .code_bytes);
    try expectLimit("1; 2; 3;", .{ .max_constants = 2 }, .constants);
    try expectLimit("1; 1; 1; 'a'; 'a';", .{ .max_constants = 1 }, .constants); // duplicates are free
    try expectLimit("a; b; c;", .{ .max_constants = 2 }, .constants); // names share the limit
    // 'abc' costs 70 accounted bytes on a 64-bit target (32 header + 6 + 2 × 16), the
    // second string ~110: the first fits, the second doesn't, and the first must be
    // rolled back (compileChecked checks the heap is empty after the failure).
    try expectLimit("'abc'; 'defghijklmnopqrstuvwxyz';", .{ .max_heap_bytes = 100 }, .heap_bytes);
    try expectLimit("'abc'; 'abcdef';", .{ .max_string_length = 4 }, .string_length);
}

fn compileOnce(gpa: Allocator, source: []const u8) !void {
    var diag: zqjs.Diagnostic = .{};
    var c = compileChecked(gpa, source, .{}, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return error.TestUnexpectedResult,
    };
    c.deinit(gpa);
}

test "error paths: every allocation failing once leaks nothing" {
    for ([_][]const u8{
        "let s = 'a'; for (let i = 0; i < 3; i++) { if (i === 1) continue; s += i + 'b' + 'a'; } print(s, x, 1, 1);",
        "const c = 1; while (c) { c += print('rhs') && 2; break; }",
    }) |src| try testing.checkAllAllocationFailures(testing.allocator, compileOnce, .{src});
}

fn fuzzCompile(_: void, smith: *testing.Smith) anyerror!void {
    var buf: [1024]u8 = undefined;
    const source = buf[0..smith.slice(&buf)];
    var diag: zqjs.Diagnostic = .{};
    var c = compileChecked(testing.allocator, source, .{ .max_nesting_depth = 64 }, &diag) catch |e| switch (e) {
        error.SyntaxError, error.Unsupported, error.LimitExceeded => return,
        else => return e,
    };
    c.deinit(testing.allocator);
}

test "fuzz: anything the front end accepts compiles to verified bytecode" {
    try testing.fuzz({}, fuzzCompile, .{ .corpus = &.{
        "let s = ''; for (let i = 0; i < 10; i++) { if (i === 5) continue; s += i; } print(s);",
        "const c = 1; for (;;) { if (c) break; else continue; } c = c && print(c || 2, -c, !c);",
        "let x; { let x = x; while (x) { let y = x++; } }",
    } });
}

fn op(o: zqjs.bytecode.Op) u8 {
    return @backingInt(o);
}

fn fuzzVerify(_: void, smith: *testing.Smith) anyerror!void {
    var code: [256]u8 = undefined;
    const len = smith.slice(&code);
    var failure: zqjs.verify.Failure = .{};
    const p: zqjs.bytecode.Proto = .{
        .code = code[0..len],
        .consts = &.{ .{ .number = 1 }, .{ .number = 2 } },
        .names = &.{ "a", "b" },
        .slot_count = 3,
        .max_stack = 4,
    };
    const info = zqjs.verify.verify(testing.allocator, &p, .{}, &failure) catch |e| switch (e) {
        error.InvalidBytecode => return,
        else => return e,
    };
    try testing.expect(info.max_stack <= p.max_stack);
    var out: std.Io.Writer.Discarding = .init(&.{});
    try zqjs.disassemble(p, &out.writer); // must not trip on anything the verifier accepts
}

test "fuzz: the verifier rejects or accepts arbitrary bytes without crashing" {
    try testing.fuzz({}, fuzzVerify, .{ .corpus = &.{
        &.{ op(.push_undefined), op(.pop), op(.halt) },
        &.{ op(.push_true), op(.jump_if_false), 7, 0, 0, 0, op(.halt), op(.halt) },
        &.{ op(.push_const), 1, 0, 0, 0, op(.dup), op(.call), 1, 0, 0, 0, op(.pop), op(.halt) },
    } });
}
