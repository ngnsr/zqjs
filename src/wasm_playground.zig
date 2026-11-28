//! Freestanding WASM32 bridge for the browser playground (`wasm32-freestanding`).
//!
//! Zero WASI or OS imports: all I/O is collected into in-memory buffers and returned as a
//! single module-owned UTF-8 JSON buffer whose lifetime lasts until the next `zqjs_eval`.

const std = @import("std");
const builtin = @import("builtin");
const zqjs = @import("zqjs_internal");
const cli_options = @import("cli_options");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const default_max_steps: u64 = 200_000_000;
const default_max_heap_bytes: usize = 64 * 1024 * 1024;
const min_heap_bytes: usize = 64 * 1024;
const max_heap_bytes_cap: usize = 512 * 1024 * 1024;

const host_allocator: Allocator = if (builtin.cpu.arch.isWasm())
    std.heap.wasm_allocator
else
    std.heap.page_allocator;

var last_result: []u8 = &.{};

const Stats = struct {
    steps: u64 = 0,
    peak_heap_bytes: usize = 0,
    heap_bytes: usize = 0,
    collections: u64 = 0,
    minor_collections: u64 = 0,
};

export fn zqjs_alloc(len: usize) usize {
    if (len == 0) return 0;
    const buf = host_allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

export fn zqjs_free(ptr: usize, len: usize) void {
    if (ptr == 0 or len == 0) return;
    const slice = @as([*]u8, @ptrFromInt(ptr))[0..len];
    host_allocator.free(slice);
}

export fn zqjs_version_ptr() usize {
    return @intFromPtr(cli_options.version.ptr);
}

export fn zqjs_version_len() usize {
    return cli_options.version.len;
}

export fn zqjs_result_len() usize {
    return last_result.len;
}

export fn zqjs_eval(
    src_ptr: usize,
    src_len: usize,
    engine_id: u32,
    is_module: u32,
    max_steps: u64,
    max_heap_bytes: usize,
) usize {
    if (last_result.len > 0) {
        host_allocator.free(last_result);
        last_result = &.{};
    }

    const source: []const u8 = if (src_ptr == 0 or src_len == 0)
        ""
    else
        @as([*]const u8, @ptrFromInt(src_ptr))[0..src_len];

    const engine: zqjs.Engine = switch (engine_id) {
        1 => .treewalk,
        else => .vm,
    };

    const json = evalToJson(
        host_allocator,
        source,
        engine,
        is_module != 0,
        max_steps,
        max_heap_bytes,
    ) catch return 0;

    last_result = json;
    return @intFromPtr(last_result.ptr);
}

pub fn evalToJson(
    gpa: Allocator,
    source: []const u8,
    engine: zqjs.Engine,
    is_module: bool,
    max_steps: u64,
    max_heap_bytes: usize,
) Allocator.Error![]u8 {
    var limits: zqjs.Limits = .{
        .max_steps = if (max_steps == 0) default_max_steps else max_steps,
        .max_heap_bytes = if (max_heap_bytes == 0)
            default_max_heap_bytes
        else
            std.math.clamp(max_heap_bytes, min_heap_bytes, max_heap_bytes_cap),
    };
    if (builtin.cpu.arch.isWasm()) {
        // Keep native-recursion checks comfortably inside the WASM shadow stack.
        limits.max_native_stack_bytes = 512 * 1024;
    }

    var out_buf: Writer.Allocating = .init(gpa);
    defer out_buf.deinit();
    var err_buf: Writer.Allocating = .init(gpa);
    defer err_buf.deinit();
    var ast_buf: Writer.Allocating = .init(gpa);
    defer ast_buf.deinit();
    var bc_buf: Writer.Allocating = .init(gpa);
    defer bc_buf.deinit();

    var stats: Stats = .{};
    const exit_code: u8 = if (is_module)
        try evalModule(gpa, source, engine, limits, &out_buf.writer, &err_buf.writer, &stats)
    else
        try evalScript(gpa, source, engine, limits, &out_buf.writer, &err_buf.writer, &ast_buf.writer, &bc_buf.writer, &stats);

    var json_buf: Writer.Allocating = .init(gpa);
    errdefer json_buf.deinit();
    const w = &json_buf.writer;

    writeResultJson(
        w,
        exit_code,
        out_buf.written(),
        err_buf.written(),
        ast_buf.written(),
        bc_buf.written(),
        stats,
    ) catch return error.OutOfMemory;

    return json_buf.toOwnedSlice();
}

fn captureStats(rt: *const zqjs.Runtime) Stats {
    return .{
        .steps = rt.steps,
        .peak_heap_bytes = rt.heap.peak,
        .heap_bytes = rt.heap.bytes,
        .collections = rt.heap.stats.collections,
        .minor_collections = rt.heap.stats.minor,
    };
}

fn evalModule(
    gpa: Allocator,
    source: []const u8,
    engine: zqjs.Engine,
    limits: zqjs.Limits,
    out: *Writer,
    err: *Writer,
    stats: *Stats,
) Allocator.Error!u8 {
    const name = "<playground.mjs>";
    var rt = zqjs.Runtime.init(gpa, limits, out);
    defer rt.deinit();
    rt.stack_base = @frameAddress();
    rt.modules.loader = null;

    var mod_diag: zqjs.module.ModuleDiag = .{};
    _ = zqjs.module.runEntry(&rt, name, source, engine, &mod_diag) catch |e| {
        stats.* = captureStats(&rt);
        return reportModuleError(&rt, e, mod_diag, name, err);
    };
    stats.* = captureStats(&rt);
    return 0;
}

fn evalScript(
    gpa: Allocator,
    source: []const u8,
    engine: zqjs.Engine,
    limits: zqjs.Limits,
    out: *Writer,
    err: *Writer,
    ast_out: *Writer,
    bc_out: *Writer,
    stats: *Stats,
) Allocator.Error!u8 {
    const name = "<playground>";
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var diag: zqjs.Diagnostic = .{};

    const script = zqjs.parse(arena.allocator(), source, limits, &diag) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        diag.render(source, name, err) catch return error.OutOfMemory;
        return 1;
    };
    const res = zqjs.resolve(arena.allocator(), script, &diag) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        diag.render(source, name, err) catch return error.OutOfMemory;
        return 1;
    };

    zqjs.dump.script(script, res, ast_out) catch return error.OutOfMemory;

    var rt = zqjs.Runtime.init(gpa, limits, out);
    defer rt.deinit();
    rt.stack_base = @frameAddress();
    rt.modules.loader = null;

    const exit_code: u8 = switch (engine) {
        .vm => blk: {
            var proto = zqjs.compile(gpa, &rt.heap, script, res, limits, &diag) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LimitExceeded => {
                    diag.render(source, name, err) catch return error.OutOfMemory;
                    break :blk 1;
                },
            };
            defer proto.deinit(gpa);

            var failure: zqjs.verify.Failure = .{};
            _ = zqjs.verify.verify(gpa, &proto, limits, &failure) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidBytecode => {
                    err.print("{s}: internal error: invalid bytecode at {d}: {s}\n", .{ name, failure.pc, failure.reason }) catch return error.OutOfMemory;
                    break :blk 70;
                },
            };

            zqjs.disassemble(proto, bc_out) catch return error.OutOfMemory;

            var vm = zqjs.Vm.init(&rt, &proto) catch |e| {
                break :blk try reportRuntimeError(&rt, e, name, err);
            };
            defer vm.deinit();

            vm.run() catch |e| {
                break :blk try reportRuntimeError(&rt, e, name, err);
            };
            break :blk 0;
        },
        .treewalk => blk: {
            const code: u8 = if (zqjs.interpret(&rt, script, res)) |_|
                0
            else |e|
                try reportRuntimeError(&rt, e, name, err);
            // Populate bytecode disassembly separately so tree-walker heap stats stay exact.
            try disassembleScriptBestEffort(gpa, script, res, limits, bc_out);
            break :blk code;
        },
    };

    stats.* = captureStats(&rt);
    return exit_code;
}

fn disassembleScriptBestEffort(
    gpa: Allocator,
    script: zqjs.ast.Script,
    res: zqjs.Resolution,
    limits: zqjs.Limits,
    bc_out: *Writer,
) Allocator.Error!void {
    var temp_heap = zqjs.Heap.init(gpa, limits);
    defer temp_heap.deinit();
    var diag: zqjs.Diagnostic = .{};
    var proto = zqjs.compile(gpa, &temp_heap, script, res, limits, &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LimitExceeded => return,
    };
    defer proto.deinit(gpa);
    var failure: zqjs.verify.Failure = .{};
    _ = zqjs.verify.verify(gpa, &proto, limits, &failure) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBytecode => return,
    };
    zqjs.disassemble(proto, bc_out) catch return error.OutOfMemory;
}

fn reportRuntimeError(rt: *zqjs.Runtime, e: zqjs.runtime.Error, name: []const u8, report: *Writer) Allocator.Error!u8 {
    switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return error.OutOfMemory,
        error.Internal => {
            report.print("{s}: internal error: {s}\n", .{ name, rt.internal_reason orelse "unknown" }) catch return error.OutOfMemory;
            return 70;
        },
        error.Thrown => {
            zqjs.thrown.write(rt, report, false) catch return error.OutOfMemory;
            return 1;
        },
        error.HostError => {
            report.print("{s}: {s}\n", .{ name, rt.host_message_buf[0..rt.host_message_len] }) catch return error.OutOfMemory;
            return 1;
        },
        error.LimitExceeded => {
            if (rt.limitHit()) |lim| {
                report.print("{s}: LimitExceeded({s})\n", .{ name, @tagName(lim) }) catch return error.OutOfMemory;
            } else {
                report.print("{s}: LimitExceeded\n", .{name}) catch return error.OutOfMemory;
            }
            return 1;
        },
        error.Unsupported => {
            if (rt.unsupported) |u| {
                report.print("{s}: Unsupported({s}): {s}", .{ name, @tagName(u), u.description() }) catch return error.OutOfMemory;
                if (rt.unsupported_name) |n| {
                    report.writeAll(" ('") catch return error.OutOfMemory;
                    zqjs.ops.writeUtf16(report, n.units) catch return error.OutOfMemory;
                    report.writeAll("')") catch return error.OutOfMemory;
                }
                report.writeByte('\n') catch return error.OutOfMemory;
            } else {
                report.print("{s}: Unsupported\n", .{name}) catch return error.OutOfMemory;
            }
            return 1;
        },
    }
}

fn reportModuleError(
    rt: *zqjs.Runtime,
    e: anyerror,
    mod_diag: zqjs.module.ModuleDiag,
    name: []const u8,
    report: *Writer,
) Allocator.Error!u8 {
    switch (e) {
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
        error.InvalidBytecode, error.Internal => {
            report.print("{s}: internal error: {s}\n", .{ name, rt.internal_reason orelse "invalid bytecode" }) catch return error.OutOfMemory;
            return 70;
        },
        error.SyntaxError, error.Unsupported => {
            if (mod_diag.source.len > 0) {
                mod_diag.diag.render(mod_diag.source, name, report) catch return error.OutOfMemory;
            } else if (e == error.Unsupported) {
                if (rt.unsupported) |u| {
                    report.print("{s}: Unsupported({s}): {s}\n", .{ name, @tagName(u), u.description() }) catch return error.OutOfMemory;
                } else {
                    report.print("{s}: {s}\n", .{ name, @errorName(e) }) catch return error.OutOfMemory;
                }
            } else if (mod_diag.diag.detail == .syntax_error) {
                report.print("{s}: SyntaxError: {s}\n", .{ name, mod_diag.diag.detail.syntax_error }) catch return error.OutOfMemory;
            } else {
                report.print("{s}: {s}\n", .{ name, @errorName(e) }) catch return error.OutOfMemory;
            }
            return 1;
        },
        error.ModuleNotFound => {
            report.print("{s}: Cannot find module '{s}'\n", .{ name, mod_diag.name }) catch return error.OutOfMemory;
            return 1;
        },
        error.Thrown => {
            zqjs.thrown.write(rt, report, false) catch return error.OutOfMemory;
            return 1;
        },
        error.HostError => {
            report.print("{s}: {s}\n", .{ name, rt.host_message_buf[0..rt.host_message_len] }) catch return error.OutOfMemory;
            return 1;
        },
        error.LimitExceeded => {
            if (rt.limitHit()) |lim| {
                report.print("{s}: LimitExceeded({s})\n", .{ name, @tagName(lim) }) catch return error.OutOfMemory;
            } else {
                report.print("{s}: LimitExceeded\n", .{name}) catch return error.OutOfMemory;
            }
            return 1;
        },
        else => {
            report.print("{s}: {s}\n", .{ name, @errorName(e) }) catch return error.OutOfMemory;
            return 1;
        },
    }
}

fn writeResultJson(
    w: *Writer,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    ast: []const u8,
    bytecode: []const u8,
    stats: Stats,
) Writer.Error!void {
    try w.print("{{\"ok\":{s},\"exitCode\":{d},\"stdout\":", .{
        if (exit_code == 0) "true" else "false",
        exit_code,
    });
    try writeJsonString(w, stdout);
    try w.writeAll(",\"stderr\":");
    try writeJsonString(w, stderr);
    try w.writeAll(",\"ast\":");
    try writeJsonString(w, ast);
    try w.writeAll(",\"bytecode\":");
    try writeJsonString(w, bytecode);
    try w.print(
        ",\"stats\":{{\"steps\":{d},\"peakHeapBytes\":{d},\"heapBytes\":{d},\"collections\":{d},\"minorCollections\":{d}}}}}",
        .{
            stats.steps,
            stats.peak_heap_bytes,
            stats.heap_bytes,
            stats.collections,
            stats.minor_collections,
        },
    );
}

fn writeJsonString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x08 => try w.writeAll("\\b"),
            0x0c => try w.writeAll("\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

// ---------------------------------------------------------------- Unit Tests

const ParsedResult = struct {
    ok: bool,
    exitCode: u8,
    stdout: []const u8,
    stderr: []const u8,
    ast: []const u8,
    bytecode: []const u8,
    stats: struct {
        steps: u64,
        peakHeapBytes: usize,
        heapBytes: usize,
        collections: u64,
        minorCollections: u64,
    },
};

test "evalToJson: valid JS on VM and treewalk" {
    const gpa = std.testing.allocator;
    for ([_]zqjs.Engine{ .vm, .treewalk }) |engine| {
        const json = try evalToJson(gpa, "console.log('hi', 1 + 2);", engine, false, 0, 0);
        defer gpa.free(json);

        const parsed = try std.json.parseFromSlice(ParsedResult, gpa, json, .{});
        defer parsed.deinit();

        try std.testing.expect(parsed.value.ok);
        try std.testing.expectEqual(@as(u8, 0), parsed.value.exitCode);
        try std.testing.expectEqualStrings("hi 3\n", parsed.value.stdout);
        try std.testing.expectEqualStrings("", parsed.value.stderr);
        try std.testing.expect(parsed.value.ast.len > 0);
        try std.testing.expect(parsed.value.bytecode.len > 0);
        try std.testing.expect(parsed.value.stats.steps > 0);
        try std.testing.expect(parsed.value.stats.peakHeapBytes > 0);
    }
}

test "evalToJson: syntax error" {
    const gpa = std.testing.allocator;
    const json = try evalToJson(gpa, "const x = ;", .vm, false, 0, 0);
    defer gpa.free(json);

    const parsed = try std.json.parseFromSlice(ParsedResult, gpa, json, .{});
    defer parsed.deinit();

    try std.testing.expect(!parsed.value.ok);
    try std.testing.expectEqual(@as(u8, 1), parsed.value.exitCode);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.stderr, "SyntaxError") != null);
    try std.testing.expectEqualStrings("", parsed.value.ast);
    try std.testing.expectEqualStrings("", parsed.value.bytecode);
}

test "evalToJson: LimitExceeded(steps)" {
    const gpa = std.testing.allocator;
    const json = try evalToJson(gpa, "while (true) {}", .vm, false, 5_000, 0);
    defer gpa.free(json);

    const parsed = try std.json.parseFromSlice(ParsedResult, gpa, json, .{});
    defer parsed.deinit();

    try std.testing.expect(!parsed.value.ok);
    try std.testing.expectEqual(@as(u8, 1), parsed.value.exitCode);
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.stderr, "LimitExceeded(steps)") != null);
    try std.testing.expect(parsed.value.stats.steps >= 5_000);
}

test "evalToJson: JSON escaping of quotes, backslashes, and control chars" {
    const gpa = std.testing.allocator;
    const json = try evalToJson(gpa, "console.log('a\"b\\\\c\\td\\re\\x01f');", .vm, false, 0, 0);
    defer gpa.free(json);

    const parsed = try std.json.parseFromSlice(ParsedResult, gpa, json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value.ok);
    try std.testing.expectEqualStrings("a\"b\\c\td\re\x01f\n", parsed.value.stdout);
}
