//! C ABI layer for ZQJS (M9.2).
//!
//! Wraps the public Zig embedding API (`zqjs`) with `extern` C types, explicit wrapper
//! lifetime tracking, and pre-flight validation so invalid, stale, destroyed, foreign, or
//! disallowed re-entrant calls return deterministic `zqjs_status` codes instead of
//! panicking or propagating Zig errors across the C ABI.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zqjs = @import("zqjs");
const internal = @import("zqjs_internal");

const default_allocator: Allocator = std.heap.smp_allocator;

const c_runtime_magic: u32 = 0x5A51_4352; // "ZQCR"
const c_program_magic: u32 = 0x5A51_4350; // "ZQCP"
const c_execution_magic: u32 = 0x5A51_4345; // "ZQCE"

pub const ZqjsHandle = extern struct {
    owner: ?*anyopaque = null,
    slot: u32 = 0,
    generation: u64 = 0,

    fn fromZig(h: zqjs.Handle) ZqjsHandle {
        return .{
            .owner = h.owner,
            .slot = h.slot,
            .generation = h.generation,
        };
    }

    fn toZig(self: ZqjsHandle) zqjs.Handle {
        return .{
            .owner = self.owner.?,
            .slot = self.slot,
            .generation = self.generation,
        };
    }
};

pub const CNativeOut = extern struct {
    has_result: bool = false,
    result: ZqjsHandle = .{},
    host_message: ?[*]const u8 = null,
    host_message_len: usize = 0,
};

pub const NativeFn = *const fn (
    rt: ?*anyopaque,
    ctx: ?*anyopaque,
    opt_this: ?*const ZqjsHandle,
    args: ?[*]const ZqjsHandle,
    argc: usize,
    out: *CNativeOut,
) callconv(.c) Status;

const CNativeEntry = struct {
    cr: *CRuntime,
    func: NativeFn,
    ctx: ?*anyopaque,
};

pub const Status = enum(c_int) {
    ok = 0,
    suspended = 1,
    finished = 2,
    err_source = -1,
    err_busy = -2,
    err_thrown = -3,
    err_host = -4,
    err_limit_exceeded = -5,
    err_unsupported = -6,
    err_out_of_memory = -7,
    err_output_failed = -8,
    err_name_taken = -9,
    err_internal = -10,
    err_invalid_arg = -11,
    err_invalid_state = -12,
    err_stale_handle = -13,
    err_foreign_handle = -14,
    err_type = -15,
};

pub const CLimit = enum(c_int) {
    none = -1,
    source_bytes = 0,
    nesting_depth = 1,
    steps = 2,
    heap_bytes = 3,
    string_length = 4,
    code_bytes = 5,
    constants = 6,
    call_depth = 7,
    stack_slots = 8,
    interpreter_depth = 9,
    conversion_depth = 10,
    handles = 11,
};

pub const CFailureKind = enum(c_int) {
    thrown = 0,
    host = 1,
    limit = 2,
    unsupported = 3,
    out_of_memory = 4,
    output = 5,
    internal = 6,
};

pub const CErrorName = enum(c_int) {
    type_error = 0,
    range_error = 1,
    reference_error = 2,
};

pub const CHandleKind = enum(c_int) {
    undefined = 0,
    null_val = 1,
    boolean = 2,
    number = 3,
    string = 4,
    function = 5,
    object = 6,
    array = 7,
};

pub const CLimits = extern struct {
    max_source_bytes: u32,
    max_nesting_depth: u16,
    max_steps: u64,
    max_heap_bytes: usize,
    nursery_bytes: usize,
    max_string_length: usize,
    max_code_bytes: u32,
    max_constants: u32,
    max_call_depth: u32,
    max_stack_slots: u32,
    max_interpreter_depth: u32,
    max_conversion_depth: u32,
    max_handles: u32,

    fn fromZig(l: zqjs.Limits) CLimits {
        return .{
            .max_source_bytes = l.max_source_bytes,
            .max_nesting_depth = l.max_nesting_depth,
            .max_steps = l.max_steps,
            .max_heap_bytes = l.max_heap_bytes,
            .nursery_bytes = l.nursery_bytes,
            .max_string_length = l.max_string_length,
            .max_code_bytes = l.max_code_bytes,
            .max_constants = l.max_constants,
            .max_call_depth = l.max_call_depth,
            .max_stack_slots = l.max_stack_slots,
            .max_interpreter_depth = l.max_interpreter_depth,
            .max_conversion_depth = l.max_conversion_depth,
            .max_handles = l.max_handles,
        };
    }

    fn toZig(self: CLimits) zqjs.Limits {
        return .{
            .max_source_bytes = self.max_source_bytes,
            .max_nesting_depth = self.max_nesting_depth,
            .max_steps = self.max_steps,
            .max_heap_bytes = self.max_heap_bytes,
            .nursery_bytes = self.nursery_bytes,
            .max_string_length = self.max_string_length,
            .max_code_bytes = self.max_code_bytes,
            .max_constants = self.max_constants,
            .max_call_depth = self.max_call_depth,
            .max_stack_slots = self.max_stack_slots,
            .max_interpreter_depth = self.max_interpreter_depth,
            .max_conversion_depth = self.max_conversion_depth,
            .max_handles = self.max_handles,
        };
    }
};

pub const OutputFn = *const fn (ctx: ?*anyopaque, bytes: [*c]const u8, len: usize) callconv(.c) bool;
pub const ClockFn = *const fn (ctx: ?*anyopaque) callconv(.c) u64;

pub const COptions = extern struct {
    limits: CLimits,
    output_fn: ?OutputFn,
    output_ctx: ?*anyopaque,
    clock_fn: ?ClockFn,
    clock_ctx: ?*anyopaque,
};

pub const CDiagnostic = extern struct {
    message: [257]u8,
    message_len: usize,
    truncated: bool,
    line: u32,
    column: u32,
    start: u32,
    end: u32,

    fn writeFromZig(self: *CDiagnostic, d: *const zqjs.Diagnostic) void {
        const msg = d.message();
        const n = @min(msg.len, 256);
        @memcpy(self.message[0..n], msg[0..n]);
        self.message[n] = 0;
        self.message_len = n;
        self.truncated = d.truncated;
        self.line = d.line;
        self.column = d.column;
        self.start = d.start;
        self.end = d.end;
    }
};

pub const CFailure = extern struct {
    kind: CFailureKind,
    limit: CLimit,
    message: [257]u8,
    message_len: usize,
    truncated: bool,

    fn writeFromZig(self: *CFailure, f: *const zqjs.Failure) void {
        self.kind = switch (f.kind) {
            .thrown => .thrown,
            .host => .host,
            .limit => .limit,
            .unsupported => .unsupported,
            .out_of_memory => .out_of_memory,
            .output => .output,
            .internal => .internal,
        };
        self.limit = if (f.limit) |lim| switch (lim) {
            .source_bytes => .source_bytes,
            .nesting_depth => .nesting_depth,
            .steps => .steps,
            .heap_bytes => .heap_bytes,
            .string_length => .string_length,
            .code_bytes => .code_bytes,
            .constants => .constants,
            .call_depth => .call_depth,
            .stack_slots => .stack_slots,
            .interpreter_depth => .interpreter_depth,
            .conversion_depth => .conversion_depth,
            .handles => .handles,
        } else .none;
        const msg = f.message();
        const n = @min(msg.len, 256);
        @memcpy(self.message[0..n], msg[0..n]);
        self.message[n] = 0;
        self.message_len = n;
        self.truncated = f.truncated;
    }
};

pub const CMemory = extern struct {
    bytes: usize,
    peak: usize,
    heap_bytes: usize,
    handle_bytes: usize,
    collections: u64,
    minor_collections: u64,
    major_collections: u64,
    last_gc_pause_ns: u64,
    max_gc_pause_ns: u64,

    fn fromZig(m: zqjs.Memory) CMemory {
        return .{
            .bytes = m.bytes,
            .peak = m.peak,
            .heap_bytes = m.heap_bytes,
            .handle_bytes = m.handle_bytes,
            .collections = m.collections,
            .minor_collections = m.minor_collections,
            .major_collections = m.major_collections,
            .last_gc_pause_ns = m.last_gc_pause_ns,
            .max_gc_pause_ns = m.max_gc_pause_ns,
        };
    }
};

const CRuntime = struct {
    magic: u32 = c_runtime_magic,
    gpa: Allocator,
    rt: *zqjs.Runtime = undefined,
    irt: *internal.Runtime = undefined,
    output_fn: ?OutputFn = null,
    output_ctx: ?*anyopaque = null,
    writer: std.Io.Writer = .{
        .vtable = &.{ .drain = writerDrain },
        .buffer = &.{},
    },
    clock_fn: ?ClockFn = null,
    clock_ctx: ?*anyopaque = null,
    in_non_native_callback: bool = false,
    programs: std.ArrayList(*CProgram) = .empty,
    executions: std.ArrayList(*CExecution) = .empty,
    natives: std.ArrayList(*CNativeEntry) = .empty,

    fn writerDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const cr: *CRuntime = @fieldParentPtr("writer", w);
        const cb = cr.output_fn orelse return std.Io.Writer.countSplat(data, splat);
        const prev = cr.in_non_native_callback;
        cr.in_non_native_callback = true;
        defer cr.in_non_native_callback = prev;

        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            if (slice.len > 0) {
                if (!cb(cr.output_ctx, slice.ptr, slice.len)) return error.WriteFailed;
                total += slice.len;
            }
        }
        const tail = data[data.len - 1];
        if (tail.len > 0) {
            for (0..splat) |_| {
                if (!cb(cr.output_ctx, tail.ptr, tail.len)) return error.WriteFailed;
                total += tail.len;
            }
        }
        return total;
    }

    fn clockAdapter(raw: ?*anyopaque) u64 {
        const cr: *CRuntime = @ptrCast(@alignCast(raw.?));
        const cb = cr.clock_fn orelse return 0;
        const prev = cr.in_non_native_callback;
        cr.in_non_native_callback = true;
        defer cr.in_non_native_callback = prev;
        return cb(cr.clock_ctx);
    }

    fn isActiveCallback(cr: *const CRuntime) bool {
        if (!cr.irt.in_call.load(.seq_cst)) return false;
        if (cr.irt.owner_thread != std.Thread.getCurrentId()) return false;
        const rec = cr.irt.exec_ctx.topRecord() orelse return false;
        return rec.live and !rec.suspended;
    }

    fn checkHostEntry(cr: *const CRuntime) ?Status {
        if (cr.magic != c_runtime_magic) return .err_invalid_state;
        if (cr.in_non_native_callback) return .err_busy;
        if (cr.irt.in_call.load(.seq_cst)) return .err_busy;
        return null;
    }

    fn checkReentrantEntry(cr: *const CRuntime) ?Status {
        if (cr.magic != c_runtime_magic) return .err_invalid_state;
        if (cr.in_non_native_callback) return .err_busy;
        if (cr.irt.in_call.load(.seq_cst)) {
            if (!cr.isActiveCallback()) return .err_busy;
        }
        return null;
    }
};

const CProgram = struct {
    magic: u32 = c_program_magic,
    owner: *CRuntime,
    prog: *zqjs.Program,
};

const CExecution = struct {
    magic: u32 = c_execution_magic,
    owner: *CRuntime,
    exec: *zqjs.Execution,
};

fn validateRuntime(raw: ?*const anyopaque) ?*CRuntime {
    const p = raw orelse return null;
    const cr: *CRuntime = @ptrCast(@alignCast(@constCast(p)));
    if (cr.magic != c_runtime_magic) return null;
    return cr;
}

fn validateProgram(raw: ?*anyopaque) ?*CProgram {
    const p = raw orelse return null;
    const cp: *CProgram = @ptrCast(@alignCast(p));
    if (cp.magic != c_program_magic) return null;
    if (cp.owner.magic != c_runtime_magic) return null;
    return cp;
}

fn validateExecution(raw: ?*anyopaque) ?*CExecution {
    const p = raw orelse return null;
    const ce: *CExecution = @ptrCast(@alignCast(p));
    if (ce.magic != c_execution_magic) return null;
    if (ce.owner.magic != c_runtime_magic) return null;
    return ce;
}

fn mapRunError(err: zqjs.RunError) Status {
    return switch (err) {
        error.Thrown => .err_thrown,
        error.HostError => .err_host,
        error.LimitExceeded => .err_limit_exceeded,
        error.Unsupported => .err_unsupported,
        error.OutOfMemory => .err_out_of_memory,
        error.OutputFailed => .err_output_failed,
        error.Internal => .err_internal,
    };
}

fn createRuntimeWithAllocator(gpa: Allocator, opts_opt: ?*const COptions, out_rt: *?*anyopaque) Status {
    const cr = gpa.create(CRuntime) catch return .err_out_of_memory;
    errdefer gpa.destroy(cr);

    const opts: COptions = if (opts_opt) |o| o.* else zqjs_options_default();
    cr.* = .{
        .gpa = gpa,
        .output_fn = opts.output_fn,
        .output_ctx = opts.output_ctx,
        .clock_fn = opts.clock_fn,
        .clock_ctx = opts.clock_ctx,
    };

    const zig_opts: zqjs.Options = .{
        .limits = opts.limits.toZig(),
        .output = if (opts.output_fn != null) &cr.writer else null,
        .clock = if (opts.clock_fn != null) CRuntime.clockAdapter else null,
        .clock_ctx = if (opts.clock_fn != null) cr else null,
    };

    cr.rt = zqjs.Runtime.create(gpa, zig_opts) catch return .err_out_of_memory;
    errdefer cr.rt.destroy();

    // Mint and immediately release a temporary handle to obtain `*internal.Runtime`
    // without adding any non-approved declaration to `src/api.zig`.
    const probe = cr.rt.newBoolean(false) catch |err| return switch (err) {
        error.OutOfMemory => .err_out_of_memory,
        error.LimitExceeded => .err_limit_exceeded,
        error.Internal => .err_internal,
    };
    cr.irt = @ptrCast(@alignCast(probe.owner));
    probe.release();

    out_rt.* = cr;
    return .ok;
}

// ---- Exported C ABI functions ----

pub export fn zqjs_limits_default() callconv(.c) CLimits {
    return CLimits.fromZig(.{});
}

pub export fn zqjs_options_default() callconv(.c) COptions {
    return .{
        .limits = zqjs_limits_default(),
        .output_fn = null,
        .output_ctx = null,
        .clock_fn = null,
        .clock_ctx = null,
    };
}

pub export fn zqjs_runtime_create(opts: ?*const COptions, out_rt: ?*?*anyopaque) callconv(.c) Status {
    const out = out_rt orelse return .err_invalid_arg;
    out.* = null;
    return createRuntimeWithAllocator(default_allocator, opts, out);
}

pub export fn zqjs_runtime_destroy(raw_rt: ?*anyopaque) callconv(.c) Status {
    const p = raw_rt orelse return .ok;
    const cr = validateRuntime(p) orelse return .err_invalid_state;
    if (cr.checkHostEntry()) |st| return st;

    cr.magic = 0;
    for (cr.executions.items) |ce| {
        ce.magic = 0;
        cr.gpa.destroy(ce);
    }
    cr.executions.deinit(cr.gpa);

    for (cr.programs.items) |cp| {
        cp.magic = 0;
        cr.gpa.destroy(cp);
    }
    cr.programs.deinit(cr.gpa);

    for (cr.natives.items) |ne| cr.gpa.destroy(ne);
    cr.natives.deinit(cr.gpa);

    cr.rt.destroy();
    cr.gpa.destroy(cr);
    return .ok;
}

pub export fn zqjs_runtime_compile(
    raw_rt: ?*anyopaque,
    name_ptr: ?[*]const u8,
    name_len: usize,
    source_ptr: ?[*]const u8,
    source_len: usize,
    out_diag: ?*CDiagnostic,
    out_prog: ?*?*anyopaque,
) callconv(.c) Status {
    const out = out_prog orelse return .err_invalid_arg;
    out.* = null;
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.checkHostEntry()) |st| return st;
    if (name_len > 0 and name_ptr == null) return .err_invalid_arg;
    if (source_len > 0 and source_ptr == null) return .err_invalid_arg;

    const name: []const u8 = if (name_ptr) |np| np[0..name_len] else "";
    const source: []const u8 = if (source_ptr) |sp| sp[0..source_len] else "";

    var diag: zqjs.Diagnostic = .{};
    const prog = cr.rt.compile(name, source, if (out_diag != null) &diag else null) catch |err| {
        if (out_diag) |od| od.writeFromZig(&diag);
        return switch (err) {
            error.Source => .err_source,
            error.Busy => .err_busy,
            error.OutOfMemory => .err_out_of_memory,
            error.Internal => .err_internal,
        };
    };

    const cp = cr.gpa.create(CProgram) catch {
        prog.destroy();
        return .err_out_of_memory;
    };
    cp.* = .{ .owner = cr, .prog = prog };
    cr.programs.append(cr.gpa, cp) catch {
        cp.magic = 0;
        cr.gpa.destroy(cp);
        prog.destroy();
        return .err_out_of_memory;
    };

    out.* = cp;
    return .ok;
}

pub export fn zqjs_program_destroy(raw_prog: ?*anyopaque) callconv(.c) Status {
    const p = raw_prog orelse return .ok;
    const cp = validateProgram(p) orelse return .err_invalid_state;
    const cr = cp.owner;
    if (cr.checkHostEntry()) |st| return st;

    for (cr.programs.items, 0..) |item, i| {
        if (item == cp) {
            _ = cr.programs.swapRemove(i);
            break;
        }
    }
    cp.magic = 0;
    cp.prog.destroy();
    cr.gpa.destroy(cp);
    return .ok;
}

pub export fn zqjs_runtime_run(raw_rt: ?*anyopaque, raw_prog: ?*anyopaque, out_fail: ?*CFailure) callconv(.c) Status {
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    const cp = validateProgram(raw_prog) orelse return if (raw_prog == null) .err_invalid_arg else .err_invalid_state;
    if (cp.owner != cr) return .err_foreign_handle;
    if (cr.checkHostEntry()) |st| return st;

    var failure: zqjs.Failure = .{};
    cr.rt.run(cp.prog, if (out_fail != null) &failure else null) catch |err| switch (err) {
        error.Busy => return .err_busy,
        error.LimitExceeded => {
            if (out_fail) |of| of.writeFromZig(&failure);
            return .err_limit_exceeded;
        },
        error.OutOfMemory => {
            if (out_fail) |of| of.writeFromZig(&failure);
            return .err_out_of_memory;
        },
        error.Internal => {
            if (out_fail) |of| of.writeFromZig(&failure);
            return .err_internal;
        },
        error.Thrown, error.HostError, error.Unsupported, error.OutputFailed => |run_err| {
            if (out_fail) |of| of.writeFromZig(&failure);
            return mapRunError(run_err);
        },
    };
    return .ok;
}

pub export fn zqjs_runtime_start(raw_rt: ?*anyopaque, raw_prog: ?*anyopaque, out_exec: ?*?*anyopaque) callconv(.c) Status {
    const out = out_exec orelse return .err_invalid_arg;
    out.* = null;
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    const cp = validateProgram(raw_prog) orelse return if (raw_prog == null) .err_invalid_arg else .err_invalid_state;
    if (cp.owner != cr) return .err_foreign_handle;
    if (cr.checkHostEntry()) |st| return st;

    const exec = cr.rt.start(cp.prog) catch |err| return switch (err) {
        error.Busy => .err_busy,
        error.LimitExceeded => .err_limit_exceeded,
        error.OutOfMemory => .err_out_of_memory,
        error.Internal => .err_internal,
    };

    const ce = cr.gpa.create(CExecution) catch {
        exec.destroy();
        return .err_out_of_memory;
    };
    ce.* = .{ .owner = cr, .exec = exec };
    cr.executions.append(cr.gpa, ce) catch {
        ce.magic = 0;
        cr.gpa.destroy(ce);
        exec.destroy();
        return .err_out_of_memory;
    };

    out.* = ce;
    return .ok;
}

pub export fn zqjs_execution_resume(raw_exec: ?*anyopaque, steps: u64, out_fail: ?*CFailure) callconv(.c) Status {
    const ce = validateExecution(raw_exec) orelse return if (raw_exec == null) .err_invalid_arg else .err_invalid_state;
    const cr = ce.owner;
    if (cr.checkHostEntry()) |st| return st;

    var failure: zqjs.Failure = .{};
    const st = ce.exec.@"resume"(steps, if (out_fail != null) &failure else null) catch |err| {
        if (out_fail) |of| of.writeFromZig(&failure);
        return mapRunError(err);
    };
    return switch (st) {
        .suspended => .suspended,
        .finished => .finished,
    };
}

pub export fn zqjs_execution_destroy(raw_exec: ?*anyopaque) callconv(.c) Status {
    const p = raw_exec orelse return .ok;
    const ce = validateExecution(p) orelse return .err_invalid_state;
    const cr = ce.owner;
    if (cr.checkHostEntry()) |st| return st;

    for (cr.executions.items, 0..) |item, i| {
        if (item == ce) {
            _ = cr.executions.swapRemove(i);
            break;
        }
    }
    ce.magic = 0;
    ce.exec.destroy();
    cr.gpa.destroy(ce);
    return .ok;
}

pub export fn zqjs_runtime_collect_garbage(raw_rt: ?*anyopaque) callconv(.c) Status {
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.checkReentrantEntry()) |st| return st;
    cr.rt.collectGarbage();
    return .ok;
}

pub export fn zqjs_runtime_memory(raw_rt: ?*const anyopaque, out_mem: ?*CMemory) callconv(.c) Status {
    const out = out_mem orelse return .err_invalid_arg;
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.checkReentrantEntry()) |st| return st;
    out.* = CMemory.fromZig(cr.rt.memory());
    return .ok;
}

// ---- Stage 2: Handles & Native Callbacks ----

const HandleCheck = union(enum) {
    ok: zqjs.Handle,
    err: Status,
};

fn validateHandle(cr: *const CRuntime, h: ZqjsHandle) HandleCheck {
    const owner = h.owner orelse return .{ .err = .err_stale_handle };
    if (owner != @as(*anyopaque, @ptrCast(cr.irt))) return .{ .err = .err_foreign_handle };
    const tok: internal.handles.Token = .{
        .owner = cr.irt,
        .slot = h.slot,
        .generation = h.generation,
    };
    if (!tok.isLive()) return .{ .err = .err_stale_handle };
    return .{ .ok = h.toZig() };
}

fn mapHandleError(err: zqjs.HandleError) Status {
    return switch (err) {
        error.OutOfMemory => .err_out_of_memory,
        error.LimitExceeded => .err_limit_exceeded,
        error.Internal => .err_internal,
    };
}

fn mapHandleKind(k: zqjs.HandleKind) CHandleKind {
    return switch (k) {
        .undefined => .undefined,
        .null => .null_val,
        .boolean => .boolean,
        .number => .number,
        .string => .string,
        .function => .function,
        .object => .object,
        .array => .array,
    };
}

pub export fn zqjs_new_number(raw_rt: ?*anyopaque, n: f64, out_handle: ?*ZqjsHandle) callconv(.c) Status {
    const out = out_handle orelse return .err_invalid_arg;
    out.* = .{};
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.checkReentrantEntry()) |st| return st;

    const zh = cr.rt.newNumber(n) catch |err| return mapHandleError(err);
    out.* = ZqjsHandle.fromZig(zh);
    return .ok;
}

pub export fn zqjs_new_boolean(raw_rt: ?*anyopaque, b: bool, out_handle: ?*ZqjsHandle) callconv(.c) Status {
    const out = out_handle orelse return .err_invalid_arg;
    out.* = .{};
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.checkReentrantEntry()) |st| return st;

    const zh = cr.rt.newBoolean(b) catch |err| return mapHandleError(err);
    out.* = ZqjsHandle.fromZig(zh);
    return .ok;
}

pub export fn zqjs_new_string_utf16(
    raw_rt: ?*anyopaque,
    units_ptr: ?[*]const u16,
    len: usize,
    out_handle: ?*ZqjsHandle,
) callconv(.c) Status {
    const out = out_handle orelse return .err_invalid_arg;
    out.* = .{};
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.checkReentrantEntry()) |st| return st;
    if (len > 0 and units_ptr == null) return .err_invalid_arg;

    const units: []const u16 = if (units_ptr) |up| up[0..len] else &.{};
    const zh = cr.rt.newStringUtf16(units) catch |err| return mapHandleError(err);
    out.* = ZqjsHandle.fromZig(zh);
    return .ok;
}

pub export fn zqjs_handle_kind_of(raw_rt: ?*const anyopaque, h: ZqjsHandle, out_kind: ?*CHandleKind) callconv(.c) Status {
    const out = out_kind orelse return .err_invalid_arg;
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.checkReentrantEntry()) |st| return st;
    const zh = switch (validateHandle(cr, h)) {
        .ok => |v| v,
        .err => |st| return st,
    };
    out.* = mapHandleKind(zh.kind());
    return .ok;
}

pub export fn zqjs_handle_number(raw_rt: ?*const anyopaque, h: ZqjsHandle, out_n: ?*f64) callconv(.c) Status {
    const out = out_n orelse return .err_invalid_arg;
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.checkReentrantEntry()) |st| return st;
    const zh = switch (validateHandle(cr, h)) {
        .ok => |v| v,
        .err => |st| return st,
    };
    out.* = zh.number() orelse return .err_type;
    return .ok;
}

pub export fn zqjs_handle_boolean(raw_rt: ?*const anyopaque, h: ZqjsHandle, out_b: ?*bool) callconv(.c) Status {
    const out = out_b orelse return .err_invalid_arg;
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.checkReentrantEntry()) |st| return st;
    const zh = switch (validateHandle(cr, h)) {
        .ok => |v| v,
        .err => |st| return st,
    };
    out.* = zh.boolean() orelse return .err_type;
    return .ok;
}

pub export fn zqjs_handle_string_utf16(
    raw_rt: ?*const anyopaque,
    h: ZqjsHandle,
    buf_ptr: ?[*]u16,
    buf_len: usize,
    out_full_len: ?*usize,
) callconv(.c) Status {
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.checkReentrantEntry()) |st| return st;
    if (buf_len > 0 and buf_ptr == null) return .err_invalid_arg;
    const zh = switch (validateHandle(cr, h)) {
        .ok => |v| v,
        .err => |st| return st,
    };
    const buf: []u16 = if (buf_ptr) |bp| bp[0..buf_len] else &.{};
    const full_len = zh.string(buf) orelse return .err_type;
    if (out_full_len) |ol| ol.* = full_len;
    return .ok;
}

pub export fn zqjs_handle_dup(raw_rt: ?*anyopaque, h: ZqjsHandle, out_handle: ?*ZqjsHandle) callconv(.c) Status {
    const out = out_handle orelse return .err_invalid_arg;
    out.* = .{};
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.checkReentrantEntry()) |st| return st;
    const zh = switch (validateHandle(cr, h)) {
        .ok => |v| v,
        .err => |st| return st,
    };
    const duped = zh.dup() catch |err| return mapHandleError(err);
    out.* = ZqjsHandle.fromZig(duped);
    return .ok;
}

pub export fn zqjs_handle_release(raw_rt: ?*anyopaque, h: ZqjsHandle) callconv(.c) Status {
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.checkReentrantEntry()) |st| return st;
    const zh = switch (validateHandle(cr, h)) {
        .ok => |v| v,
        .err => |st| return st,
    };
    zh.release();
    return .ok;
}

fn cNativeBridge(
    rt: *zqjs.Runtime,
    raw: ?*anyopaque,
    this_opt: ?zqjs.Handle,
    args: []const zqjs.Handle,
    out: *zqjs.NativeOut,
) zqjs.NativeError!void {
    const entry: *CNativeEntry = @ptrCast(@alignCast(raw.?));
    const cr = entry.cr;

    var this_c: ZqjsHandle = .{};
    const this_ptr: ?*const ZqjsHandle = if (this_opt) |th| blk: {
        this_c = ZqjsHandle.fromZig(th);
        break :blk &this_c;
    } else null;

    var inline_args: [8]ZqjsHandle = undefined;
    const heap_args: ?[]ZqjsHandle = if (args.len > inline_args.len)
        cr.gpa.alloc(ZqjsHandle, args.len) catch return error.OutOfMemory
    else
        null;
    defer if (heap_args) |buf| cr.gpa.free(buf);
    const c_args = if (heap_args) |buf| buf else inline_args[0..args.len];
    for (args, 0..) |ah, i| c_args[i] = ZqjsHandle.fromZig(ah);

    var c_out: CNativeOut = .{};
    const status = entry.func(
        cr,
        entry.ctx,
        this_ptr,
        if (args.len > 0) c_args.ptr else null,
        args.len,
        &c_out,
    );

    const rec_opt = cr.irt.exec_ctx.topRecord();
    const did_throw = if (rec_opt) |rec| rec.threw_js else false;

    if (c_out.has_result) {
        switch (validateHandle(cr, c_out.result)) {
            .ok => |zh| out.result = zh,
            .err => {
                if (status == .ok) {
                    if (rec_opt) |rec| rec.threw_js = false;
                    cr.irt.exception = null;
                    out.host_message = "invalid native result handle";
                    return error.HostError;
                }
            },
        }
    }

    switch (status) {
        .ok => {
            if (did_throw) {
                if (rec_opt) |rec| rec.threw_js = false;
                cr.irt.exception = null;
                out.host_message = "native returned ZQJS_OK after throw_js";
                return error.HostError;
            }
            return;
        },
        .err_thrown => {
            if (!did_throw) {
                const fallback = [_]u16{ 't', 'h', 'r', 'o', 'w', 'n' };
                rt.throwJs(.TypeError, &fallback);
            }
            return error.Thrown;
        },
        .err_host => {
            if (c_out.host_message_len > 0 and c_out.host_message != null) {
                out.host_message = c_out.host_message.?[0..c_out.host_message_len];
            } else {
                out.host_message = "host error";
            }
            return error.HostError;
        },
        .err_limit_exceeded => return error.LimitExceeded,
        .err_unsupported => return error.Unsupported,
        .err_out_of_memory => return error.OutOfMemory,
        else => return error.Internal,
    }
}

pub export fn zqjs_runtime_define_global_function(
    raw_rt: ?*anyopaque,
    name_ptr: ?[*]const u8,
    name_len: usize,
    fn_opt: ?NativeFn,
    ctx: ?*anyopaque,
) callconv(.c) Status {
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.checkHostEntry()) |st| return st;
    const func = fn_opt orelse return .err_invalid_arg;
    if (name_len == 0 or name_ptr == null) return .err_invalid_arg;

    const entry = cr.gpa.create(CNativeEntry) catch return .err_out_of_memory;
    entry.* = .{ .cr = cr, .func = func, .ctx = ctx };

    cr.natives.ensureUnusedCapacity(cr.gpa, 1) catch {
        cr.gpa.destroy(entry);
        return .err_out_of_memory;
    };

    const name = name_ptr.?[0..name_len];
    cr.rt.defineGlobalFunction(name, cNativeBridge, entry) catch |err| {
        cr.gpa.destroy(entry);
        return switch (err) {
            error.OutOfMemory => .err_out_of_memory,
            error.NameTaken => .err_name_taken,
        };
    };
    cr.natives.appendAssumeCapacity(entry);
    return .ok;
}

pub export fn zqjs_runtime_throw_js(
    raw_rt: ?*anyopaque,
    err_name: CErrorName,
    msg_ptr: ?[*]const u16,
    msg_len: usize,
) callconv(.c) Status {
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.in_non_native_callback or !cr.isActiveCallback()) return .err_invalid_state;
    if (msg_len > 0 and msg_ptr == null) return .err_invalid_arg;

    const zig_name: zqjs.ErrorName = switch (err_name) {
        .type_error => .TypeError,
        .range_error => .RangeError,
        .reference_error => .ReferenceError,
    };
    const units: []const u16 = if (msg_ptr) |mp| mp[0..msg_len] else &.{};
    cr.rt.throwJs(zig_name, units);
    return .ok;
}

pub export fn zqjs_runtime_call(
    raw_rt: ?*anyopaque,
    fn_h: ZqjsHandle,
    opt_this: ?*const ZqjsHandle,
    args_ptr: ?[*]const ZqjsHandle,
    argc: usize,
    out_fail: ?*CFailure,
    out_result: ?*ZqjsHandle,
) callconv(.c) Status {
    const out = out_result orelse return .err_invalid_arg;
    out.* = .{};
    const cr = validateRuntime(raw_rt) orelse return if (raw_rt == null) .err_invalid_arg else .err_invalid_state;
    if (cr.checkReentrantEntry()) |st| return st;
    if (argc > 0 and args_ptr == null) return .err_invalid_arg;

    const callee = switch (validateHandle(cr, fn_h)) {
        .ok => |v| v,
        .err => |st| return st,
    };
    const this_v: ?zqjs.Handle = if (opt_this) |tp| switch (validateHandle(cr, tp.*)) {
        .ok => |v| v,
        .err => |st| return st,
    } else null;

    var inline_args: [8]zqjs.Handle = undefined;
    const heap_args: ?[]zqjs.Handle = if (argc > inline_args.len)
        cr.gpa.alloc(zqjs.Handle, argc) catch return .err_out_of_memory
    else
        null;
    defer if (heap_args) |buf| cr.gpa.free(buf);
    const z_args = if (heap_args) |buf| buf else inline_args[0..argc];

    if (args_ptr) |ap| {
        for (0..argc) |i| {
            z_args[i] = switch (validateHandle(cr, ap[i])) {
                .ok => |v| v,
                .err => |st| return st,
            };
        }
    }

    var failure: zqjs.Failure = .{};
    const res = cr.rt.call(callee, this_v, z_args, if (out_fail != null) &failure else null) catch |err| {
        if (out_fail) |of| of.writeFromZig(&failure);
        return mapRunError(err);
    };
    out.* = ZqjsHandle.fromZig(res);
    return .ok;
}

// ---- Stage 1 ABI layout & lifecycle tests ----

const testing = std.testing;

test "C ABI extern struct fields & enum values" {
    try testing.expectEqual(@as(usize, 24), @sizeOf(ZqjsHandle));
    try testing.expectEqual(@as(usize, 8), @alignOf(ZqjsHandle));
    try testing.expectEqual(@as(usize, 0), @offsetOf(ZqjsHandle, "owner"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(ZqjsHandle, "slot"));
    try testing.expectEqual(@as(usize, 16), @offsetOf(ZqjsHandle, "generation"));
    try testing.expectEqual(
        std.mem.alignForward(usize, 257, @alignOf(usize)),
        @offsetOf(CDiagnostic, "message_len") - @offsetOf(CDiagnostic, "message"),
    );
}

test "C ABI Stage 1: lifecycle, slice resume, GC telemetry, and invalid-state checks without panics" {
    var out_buf: [256]u8 = undefined;
    var out_len: usize = 0;
    const WriterCtx = struct {
        buf: *[256]u8,
        len: *usize,
        fn write(raw: ?*anyopaque, bytes: [*c]const u8, len: usize) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const n = @min(len, self.buf.len - self.len.*);
            @memcpy(self.buf[self.len.*..][0..n], bytes[0..n]);
            self.len.* += n;
            return true;
        }
    };
    var wctx: WriterCtx = .{ .buf = &out_buf, .len = &out_len };

    var opts = zqjs_options_default();
    opts.output_fn = WriterCtx.write;
    opts.output_ctx = &wctx;

    var rt: ?*anyopaque = null;
    try testing.expectEqual(Status.ok, createRuntimeWithAllocator(testing.allocator, &opts, &rt));

    var prog: ?*anyopaque = null;
    var diag: CDiagnostic = undefined;
    const src = "let s = 0; for (let i = 1; i <= 5; i++) s += i; print(s);";
    try testing.expectEqual(Status.ok, zqjs_runtime_compile(rt, "sum.js", 6, src.ptr, src.len, &diag, &prog));

    var exec: ?*anyopaque = null;
    try testing.expectEqual(Status.ok, zqjs_runtime_start(rt, prog, &exec));
    try testing.expectEqual(Status.ok, zqjs_program_destroy(prog));
    // Double destroy / stale program returns invalid_state instead of panicking.
    try testing.expectEqual(Status.err_invalid_state, zqjs_program_destroy(prog));

    var steps_total: usize = 0;
    while (true) {
        var fail: CFailure = undefined;
        const st = zqjs_execution_resume(exec, 3, &fail);
        steps_total += 1;
        if (st == .finished) break;
        try testing.expectEqual(Status.suspended, st);
    }
    try testing.expect(steps_total > 1);
    try testing.expectEqualStrings("15\n", out_buf[0..out_len]);

    try testing.expectEqual(Status.ok, zqjs_execution_destroy(exec));
    try testing.expectEqual(Status.err_invalid_state, zqjs_execution_destroy(exec));

    try testing.expectEqual(Status.ok, zqjs_runtime_collect_garbage(rt));
    var mem: CMemory = undefined;
    try testing.expectEqual(Status.ok, zqjs_runtime_memory(rt, &mem));
    try testing.expect(mem.collections >= 1);

    try testing.expectEqual(Status.ok, zqjs_runtime_destroy(rt));
    try testing.expectEqual(Status.ok, zqjs_runtime_destroy(null));
}

test "C ABI lifecycle: destroy Program while Execution is suspended, and destroy Runtime with live children (no leaks)" {
    var out_buf: [128]u8 = undefined;
    var out_len: usize = 0;
    const WriterCtx = struct {
        buf: *[128]u8,
        len: *usize,
        fn write(raw: ?*anyopaque, bytes: [*c]const u8, len: usize) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const n = @min(len, self.buf.len - self.len.*);
            @memcpy(self.buf[self.len.*..][0..n], bytes[0..n]);
            self.len.* += n;
            return true;
        }
    };
    var wctx: WriterCtx = .{ .buf = &out_buf, .len = &out_len };

    var opts = zqjs_options_default();
    opts.output_fn = WriterCtx.write;
    opts.output_ctx = &wctx;

    // 1. Destroy Program while Execution is suspended mid-run, then resume to finished
    {
        var rt: ?*anyopaque = null;
        try testing.expectEqual(Status.ok, createRuntimeWithAllocator(testing.allocator, &opts, &rt));
        defer _ = zqjs_runtime_destroy(rt);

        const src = "let msg = 'kept constant'; let k = 0; for (let i = 0; i < 4; i++) k += i; print(msg);";
        var diag: CDiagnostic = undefined;
        var prog: ?*anyopaque = null;
        try testing.expectEqual(Status.ok, zqjs_runtime_compile(rt, "mid.js", 6, src.ptr, src.len, &diag, &prog));

        var exec: ?*anyopaque = null;
        try testing.expectEqual(Status.ok, zqjs_runtime_start(rt, prog, &exec));
        defer _ = zqjs_execution_destroy(exec);

        var fail: CFailure = undefined;
        try testing.expectEqual(Status.suspended, zqjs_execution_resume(exec, 2, &fail));
        try testing.expectEqual(Status.ok, zqjs_program_destroy(prog));
        try testing.expectEqual(Status.err_invalid_state, zqjs_program_destroy(prog));

        while (true) {
            const st = zqjs_execution_resume(exec, 4, &fail);
            if (st == .finished) break;
            try testing.expectEqual(Status.suspended, st);
        }
        try testing.expectEqualStrings("kept constant\n", out_buf[0..out_len]);
    }

    // 2. Destroy Runtime while child Program, suspended Execution, and Handle still exist (no leaks)
    {
        var rt: ?*anyopaque = null;
        try testing.expectEqual(Status.ok, createRuntimeWithAllocator(testing.allocator, &opts, &rt));

        const src = "let a = 1; let b = 2; let c = a + b;";
        var diag: CDiagnostic = undefined;
        var prog: ?*anyopaque = null;
        try testing.expectEqual(Status.ok, zqjs_runtime_compile(rt, "live.js", 7, src.ptr, src.len, &diag, &prog));

        var exec: ?*anyopaque = null;
        try testing.expectEqual(Status.ok, zqjs_runtime_start(rt, prog, &exec));
        var fail: CFailure = undefined;
        try testing.expectEqual(Status.suspended, zqjs_execution_resume(exec, 1, &fail));

        var h: ZqjsHandle = .{};
        try testing.expectEqual(Status.ok, zqjs_new_number(rt, 123.0, &h));

        try testing.expectEqual(Status.ok, zqjs_runtime_destroy(rt));
    }
}
