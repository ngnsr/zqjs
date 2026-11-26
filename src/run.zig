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
const ast = @import("frontend/ast.zig");
const bytecode = @import("bytecode/bytecode.zig");
const heap = @import("runtime/heap.zig");
const Value = @import("runtime/value.zig").Value;
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
            error.Thrown => try writeThrown(&rt, mode, report),
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

const ThrownName = union(enum) {
    utf16: []const u16,
    utf8: []const u8,
};

const ThrownErrorInfo = struct {
    name: ThrownName,
    message: ?[]const u16,
};

fn asciiEqlUtf16(ascii: []const u8, units: []const u16) bool {
    if (ascii.len != units.len) return false;
    for (ascii, units) |a, u| {
        if (u != a) return false;
    }
    return true;
}

/// Allocation-free, getter-free data-property lookup along the prototype chain.
fn lookupDataProp(obj: *const heap.Object, key_ascii: []const u8) ?Value {
    var cur: ?*const heap.Object = obj;
    var depth: usize = 0;
    while (cur) |o| : ({
        cur = o.proto;
        depth += 1;
    }) {
        if (depth >= 64 or o.kind == .proxy) return null;
        var it = o.props.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (!k.isSymbol() and asciiEqlUtf16(key_ascii, k.asAtom().units)) {
                if (entry.value_ptr.is_accessor) return null;
                return entry.value_ptr.value;
            }
        }
    }
    return null;
}

fn closureName(cl: *const heap.Closure) ?ThrownName {
    if (cl.meta) |m| {
        var it = m.props.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (!k.isSymbol() and asciiEqlUtf16("name", k.asAtom().units)) {
                if (entry.value_ptr.is_accessor) return null;
                const val = entry.value_ptr.value;
                if (val.isString() and val.asString().units.len > 0) return .{ .utf16 = val.asString().units };
                return null;
            }
        }
        if (m.name_deleted) return null;
    }
    return switch (cl.impl) {
        .vm => |vm| blk: {
            const proto: *const bytecode.Proto = @ptrCast(@alignCast(vm.proto));
            const n = if (proto.name.len > 0) proto.name else proto.inferred_name;
            break :blk if (n.len > 0) .{ .utf8 = n } else null;
        },
        .tree => |tr| blk: {
            const func: *const ast.Function = @ptrCast(@alignCast(tr.func));
            const n = if (func.name) |d| d.name else func.inferred_name;
            break :blk if (n.len > 0) .{ .utf8 = n } else null;
        },
        .bound => |b| if (b.name.units.len > 0) .{ .utf16 = b.name.units } else null,
        else => null,
    };
}

fn isObjectName(n: ThrownName) bool {
    return switch (n) {
        .utf8 => |s| std.mem.eql(u8, s, "Object"),
        .utf16 => |u| asciiEqlUtf16("Object", u),
    };
}

/// Extracts error-like `{ name, message }` (or custom constructor name + string `message`,
/// e.g. Test262's `Test262Error`) from a thrown object without allocating or invoking getters.
fn extractThrownError(v: Value) ?ThrownErrorInfo {
    if (!v.isObject()) return null;
    const obj = v.asObject();
    const msg_units: ?[]const u16 = if (lookupDataProp(obj, "message")) |mv|
        (if (mv.isString()) mv.asString().units else null)
    else
        null;
    if (lookupDataProp(obj, "name")) |nv| {
        if (nv.isString() and nv.asString().units.len > 0) {
            return .{ .name = .{ .utf16 = nv.asString().units }, .message = msg_units };
        }
    }
    if (msg_units != null) {
        if (lookupDataProp(obj, "constructor")) |cv| {
            if (cv.isClosure()) {
                if (closureName(cv.asClosure())) |cn| {
                    if (!isObjectName(cn)) return .{ .name = cn, .message = msg_units };
                }
            }
        }
    }
    return null;
}

fn writeThrown(rt: *Runtime, mode: Mode, report: *Writer) Writer.Error!void {
    if (rt.thrown_value) |v| {
        try report.writeAll("Uncaught ");
        if (extractThrownError(v)) |info| {
            switch (info.name) {
                .utf16 => |u| try ops.writeUtf16(report, u),
                .utf8 => |s| try report.writeAll(s),
            }
            if (mode == .normal) {
                if (info.message) |m| {
                    if (m.len > 0) {
                        try report.writeAll(": ");
                        try ops.writeUtf16(report, m);
                    }
                }
            }
        } else if (mode == .normal) {
            var buf: ops.NumberBuf = undefined;
            if (ops.toPiece(rt, v, &buf)) |piece| switch (piece) {
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
            try writeThrown(&rt, mode, report);
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
