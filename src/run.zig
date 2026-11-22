//! Source text → parse → resolve → run, with outcome reporting. Shared by the CLI and
//! the differential tests so both print exactly the same thing.
//!
//! Engines:
//!   .vm        compile → verify → VM (the default)
//!   .treewalk  the tree-walking oracle (DESIGN_DECISIONS D16)
//! Bytecode is always verified before it runs, in every build mode; a verifier
//! rejection is a compiler bug, reported as an internal error (exit code 70), and the
//! code is never executed.
//!
//! Modes:
//!   .normal   program output to `out`; diagnostics and `Uncaught …` to `err`
//!   .harness  everything to `out`, and an uncaught exception prints only
//!             `Uncaught <Name>`, which is what tests/harness/golden.js prints for node
//!             (messages are never compared, LANGUAGE.md §1).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Limits = @import("limits.zig").Limits;
const Diagnostic = @import("frontend/diag.zig").Diagnostic;
const parse = @import("frontend/parser.zig").parse;
const resolve = @import("frontend/resolver.zig").resolve;
const Runtime = @import("runtime/runtime.zig").Runtime;
const module = @import("runtime/module.zig");
const ops = @import("runtime/ops.zig");
const treewalk = @import("interp/machine.zig");
const compile = @import("bytecode/compiler.zig").compile;
const verify = @import("bytecode/verify.zig");
const disasm = @import("bytecode/disasm.zig");
const Vm = @import("vm/vm.zig").Vm;

const RuntimeError = @import("runtime/runtime.zig").Error;

pub const Mode = enum { normal, harness };
pub const Engine = enum { vm, treewalk };

pub const Options = struct {
    mode: Mode = .normal,
    engine: Engine = .vm,
    /// VM only: before each instruction, write its listing line and the operand stack.
    trace: ?*Writer = null,
    /// Collect at every safepoint, not only when the heap asks (tests; GC_DESIGN §11).
    collect_always: bool = false,
    /// Run the heap verifier after every collection, without the rest of -Dgc-stress.
    verify_heap: bool = false,
};

pub const Error = Allocator.Error || Writer.Error;

/// Returns the process exit code: 0 on success, 1 if the script did not complete.
pub fn runSource(gpa: Allocator, name: []const u8, source: []const u8, limits: Limits, options: Options, out: *Writer, err: *Writer) Error!u8 {
    const mode = options.mode;
    const report = if (mode == .harness) out else err;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var diag: Diagnostic = .{};

    const script = parse(arena.allocator(), source, limits, &diag) catch |e|
        return frontendFailure(e, diag, source, name, report);
    const res = resolve(arena.allocator(), script, &diag) catch |e|
        return frontendFailure(e, diag, source, name, report);

    var rt = Runtime.init(gpa, limits, out);
    defer rt.deinit();
    rt.stack_base = @frameAddress();
    // An option can only add collections: under -Dgc-stress every safepoint collects anyway.
    rt.heap.collect_always = options.collect_always or rt.heap.collect_always;
    rt.heap.verify_always = options.verify_heap or rt.heap.verify_always;
    const outcome = switch (options.engine) {
        .treewalk => treewalk.run(&rt, script, res),
        .vm => vm: {
            var proto = compile(gpa, &rt.heap, script, res, limits, &diag) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LimitExceeded => return frontendFailure(e, diag, source, name, report),
            };
            defer proto.deinit(gpa);
            var failure: verify.Failure = .{};
            _ = verify.verify(gpa, &proto, limits, &failure) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidBytecode => {
                    try report.print("{s}: internal error: invalid bytecode at {d}: {s}\n", .{ name, failure.pc, failure.reason });
                    return 70;
                },
            };
            // The script's own frame can already exceed max_stack_slots.
            var vm = Vm.init(&rt, &proto) catch |e| break :vm @as(RuntimeError!void, e);
            defer vm.deinit();
            break :vm if (options.trace) |t| runTraced(&vm, t) else vm.run();
        },
    };
    outcome catch |e| {
        switch (e) {
            error.OutOfMemory, error.WriteFailed => |host| return host,
            error.Internal => {
                try report.print("{s}: internal error: {s}\n", .{ name, rt.internal_reason orelse "unknown" });
                return 70;
            },
            error.Thrown => {
                if (rt.thrown_value) |v| {
                    try report.writeAll("Uncaught ");
                    if (mode == .normal) {
                        var buf: ops.NumberBuf = undefined;
                        if (ops.toPiece(&rt, v, &buf)) |piece| switch (piece) {
                            .ascii => |a| try report.writeAll(a),
                            .utf16 => |u| try ops.writeUtf16(report, u),
                        } else |_| try report.writeAll("[value]");
                    }
                    try report.writeByte('\n');
                } else {
                    const ex = rt.exception.?;
                    try report.print("Uncaught {s}", .{@tagName(ex.name)});
                    if (mode == .normal) {
                        try report.writeAll(": ");
                        try ops.writeUtf16(report, ex.message.units);
                    }
                    try report.writeByte('\n');
                }
            },
            error.HostError => try report.print("{s}: {s}\n", .{ name, rt.host_message_buf[0..rt.host_message_len] }),
            error.LimitExceeded => try report.print("{s}: LimitExceeded({s})\n", .{ name, @tagName(rt.limitHit().?) }),
            error.Unsupported => {
                try report.print("{s}: Unsupported({s}): {s}", .{ name, @tagName(rt.unsupported.?), rt.unsupported.?.description() });
                if (rt.unsupported_name) |n| {
                    try report.writeAll(" ('");
                    try ops.writeUtf16(report, n.units);
                    try report.writeAll("')");
                }
                try report.writeByte('\n');
            },
        }
        return 1;
    };
    return 0;
}

fn runTraced(vm: *Vm, t: *Writer) RuntimeError!void {
    while (true) {
        if (!vm.halted) {
            // Indented by call depth. Padded to a column, so the stacks line up; a line too
            // long for the buffer (a long string constant) is written unpadded.
            try t.splatByteAll(' ', 2 * (vm.frames.items.len - 1));
            var buf: [128]u8 = undefined;
            var line: Writer = .fixed(&buf);
            if (disasm.instruction(vm.proto().*, vm.pc, &line)) {
                try t.print("{s:<56}", .{line.buffered()});
            } else |_| try disasm.instruction(vm.proto().*, vm.pc, t);
            try t.writeAll(" |");
            for (vm.operands(), 0..) |v, i| {
                try t.writeAll(if (i > 0) ", " else " ");
                try disasm.value(v, t);
            }
            try t.writeByte('\n');
        }
        if (try vm.step() == .halted) return;
    }
}

fn frontendFailure(e: anyerror, diag: Diagnostic, source: []const u8, name: []const u8, report: *Writer) Error!u8 {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    try diag.render(source, name, report);
    return 1;
}

/// Loads, links, and executes an ES Module graph from `name` (with optional `io` for
/// filesystem imports), returning the process exit code.
pub fn runModule(gpa: Allocator, name: []const u8, source: []const u8, io: std.Io, limits: Limits, options: Options, out: *Writer, err: *Writer) Error!u8 {
    const mode = options.mode;
    const report = if (mode == .harness) out else err;

    var rt = Runtime.init(gpa, limits, out);
    defer rt.deinit();
    rt.stack_base = @frameAddress();
    rt.heap.collect_always = options.collect_always or rt.heap.collect_always;
    rt.heap.verify_always = options.verify_heap or rt.heap.verify_always;

    var fs_loader: module.FsLoader = .{
        .gpa = gpa,
        .io = io,
        .max_source_bytes = limits.max_source_bytes,
    };
    rt.modules.loader = fs_loader.loader();

    const canonical = module.resolveFsPath(gpa, io, null, name) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ModuleNotFound => try gpa.dupe(u8, name),
    };
    defer gpa.free(canonical);

    var mod_diag: module.ModuleDiag = .{};
    _ = module.runEntry(&rt, canonical, source, options.engine, &mod_diag) catch |e| switch (e) {
        error.OutOfMemory, error.WriteFailed => |host| return host,
        error.InvalidBytecode, error.Internal => {
            try report.print("{s}: internal error: {s}\n", .{ name, rt.internal_reason orelse "invalid bytecode" });
            return 70;
        },
        error.SyntaxError, error.Unsupported => {
            if (mod_diag.source.len > 0) {
                try mod_diag.diag.render(mod_diag.source, name, report);
            } else if (e == error.Unsupported) {
                if (rt.unsupported) |u| {
                    try report.print("{s}: Unsupported({s})\n", .{ name, @tagName(u) });
                } else {
                    try report.print("{s}: {s}\n", .{ name, @errorName(e) });
                }
            } else if (mod_diag.diag.detail == .syntax_error) {
                try report.print("{s}: SyntaxError: {s}\n", .{ name, mod_diag.diag.detail.syntax_error });
            } else {
                try report.print("{s}: {s}\n", .{ name, @errorName(e) });
            }
            return 1;
        },
        error.ModuleNotFound => {
            try report.print("{s}: Cannot find module '{s}'\n", .{ name, mod_diag.name });
            return 1;
        },
        error.Thrown => {
            if (rt.thrown_value) |v| {
                try report.writeAll("Uncaught ");
                if (mode == .normal) {
                    var buf: ops.NumberBuf = undefined;
                    if (ops.toPiece(&rt, v, &buf)) |piece| switch (piece) {
                        .ascii => |a| try report.writeAll(a),
                        .utf16 => |u| try ops.writeUtf16(report, u),
                    } else |_| try report.writeAll("[value]");
                }
                try report.writeByte('\n');
            } else {
                const ex = rt.exception.?;
                try report.print("Uncaught {s}", .{@tagName(ex.name)});
                if (mode == .normal) {
                    try report.writeAll(": ");
                    try ops.writeUtf16(report, ex.message.units);
                }
                try report.writeByte('\n');
            }
            return 1;
        },
        error.HostError => {
            try report.print("{s}: {s}\n", .{ name, rt.host_message_buf[0..rt.host_message_len] });
            return 1;
        },
        error.LimitExceeded => {
            try report.print("{s}: LimitExceeded({s})\n", .{ name, @tagName(rt.limitHit().?) });
            return 1;
        },
    };
    return 0;
}
