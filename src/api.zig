//! ZQJS's public embedding API (M9.0; design in M9_0_PLAN.md, decisions D46-D49).
//!
//! This is the only module an embedder's build gets (`zqjs`). It is built on the internal
//! module (`zqjs_internal`, src/root.zig) and exposes none of it: the VM, the heap, bytecode
//! and the GC stay private, so changing them never breaks an embedder. Every public
//! declaration is pinned by tests/api_test.zig: a new one is a reviewed decision.
//!
//! Three opaque types, owned in a strict hierarchy (E1):
//!   Runtime      a heap, a realm and everything below; one call at a time (E2)
//!    ├ Program   a compiled, verified script; runs any number of times (E3)
//!    └ Execution one run of a program, resumed in slices of steps (E4, E5)
//! Errors come back as error values plus a `Failure` (E6-E10); nothing here panics on a
//! script's behalf.

const std = @import("std");
const Allocator = std.mem.Allocator;
const internal = @import("zqjs_internal");
const IRuntime = internal.Runtime;
const handles = internal.handles;
const Proto = internal.bytecode.Proto;
const Vm = internal.Vm;
const alive_magic = internal.runtime.alive_magic;

/// Resource limits of a runtime (DESIGN_DECISIONS D15): heap bytes, string length, call
/// depth, steps per execution (`max_steps`, cumulative over its resumes: E4)…
pub const Limits = internal.Limits;
/// Which limit an operation hit.
pub const Limit = internal.Limit;

pub const Options = struct {
    limits: Limits = .{},
    /// Where `print` writes. Null: output is discarded.
    output: ?*std.Io.Writer = null,
};

pub const Status = enum { finished, suspended };

pub const CompileError = error{ Source, OutOfMemory, Internal };
pub const StartError = error{ LimitExceeded, OutOfMemory, Internal };
pub const RunError = error{ Thrown, LimitExceeded, Unsupported, OutOfMemory, OutputFailed, Internal };

/// UTF-8 text in a fixed buffer, never allocated (E10): always valid UTF-8, cut at a code
/// point boundary with "…" when it doesn't fit, `truncated` then set.
const TextWriter = struct {
    bytes: *[capacity]u8,
    len: *usize,
    truncated: *bool,
    /// The last boundary at which "…" still fits.
    cut: usize = 0,

    const capacity = 256;
    const ellipsis = "\u{2026}";

    fn init(bytes: *[capacity]u8, len: *usize, truncated: *bool) TextWriter {
        len.* = 0;
        truncated.* = false;
        return .{ .bytes = bytes, .len = len, .truncated = truncated };
    }

    fn codePoint(t: *TextWriter, cp: u21) void {
        if (t.truncated.*) return;
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch std.unicode.utf8Encode(0xFFFD, &enc) catch unreachable;
        if (t.len.* + n <= capacity) {
            @memcpy(t.bytes[t.len.*..][0..n], enc[0..n]);
            t.len.* += n;
            if (t.len.* <= capacity - ellipsis.len) t.cut = t.len.*;
            return;
        }
        t.len.* = t.cut;
        @memcpy(t.bytes[t.len.*..][0..ellipsis.len], ellipsis);
        t.len.* += ellipsis.len;
        t.truncated.* = true;
    }

    /// UTF-8 in (invalid sequences become U+FFFD).
    fn utf8(t: *TextWriter, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch {
                t.codePoint(0xFFFD);
                i += 1;
                continue;
            };
            if (i + n > s.len) {
                t.codePoint(0xFFFD);
                return;
            }
            t.codePoint(std.unicode.utf8Decode(s[i..][0..n]) catch 0xFFFD);
            i += n;
        }
    }

    /// UTF-16 in, as `print` converts it: pairs combine, a lone surrogate becomes U+FFFD.
    fn utf16(t: *TextWriter, units: []const u16) void {
        var i: usize = 0;
        while (i < units.len) : (i += 1) {
            const u = units[i];
            if (u >= 0xD800 and u <= 0xDBFF and i + 1 < units.len and units[i + 1] >= 0xDC00 and units[i + 1] <= 0xDFFF) {
                t.codePoint(0x10000 + ((@as(u21, u) - 0xD800) << 10) + (units[i + 1] - 0xDC00));
                i += 1;
            } else t.codePoint(if (u >= 0xD800 and u <= 0xDFFF) 0xFFFD else u);
        }
    }
};

/// Why a call failed (E6-E10), filled when it returns an error.
pub const Failure = struct {
    kind: Kind = .internal,
    limit: ?Limit = null,
    /// "TypeError: x is not a function", "Unsupported(builtin): …", "LimitExceeded(steps)"…
    text: [256]u8 = undefined,
    text_len: usize = 0,
    truncated: bool = false,

    pub const Kind = enum { thrown, limit, unsupported, out_of_memory, output, internal };

    pub fn message(f: *const Failure) []const u8 {
        return f.text[0..f.text_len];
    }
};

/// Why a compile failed (E8): the message, where, and a rendering like the CLI's.
pub const Diagnostic = struct {
    /// "SyntaxError: …", "Unsupported(asi): …", "LimitExceeded(source_bytes)"
    text: [256]u8 = undefined,
    text_len: usize = 0,
    truncated: bool = false,
    line: u32 = 0,
    column: u32 = 0,
    /// Byte span in the source.
    start: u32 = 0,
    end: u32 = 0,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.text[0..d.text_len];
    }

    /// `name:line:col: message`, then the source line and a caret.
    pub fn render(d: *const Diagnostic, source: []const u8, name: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const loc = internal.Diagnostic.locate(source, d.start);
        try w.print("{s}:{d}:{d}: {s}\n", .{ name, d.line, d.column, d.message() });
        try w.print("  {s}\n  ", .{source[loc.line_start..loc.line_end]});
        try w.splatByteAll(' ', loc.column - 1);
        try w.writeAll("^\n");
    }
};

/// Memory numbers of a runtime (accounted bytes, D28).
pub const Memory = struct {
    bytes: usize,
    peak: usize,
    collections: u64,
};

pub const Runtime = opaque {
    fn impl(rt: *Runtime) *RuntimeImpl {
        return @ptrCast(@alignCast(rt));
    }

    fn implConst(rt: *const Runtime) *const RuntimeImpl {
        return @ptrCast(@alignCast(rt));
    }

    pub fn create(gpa: Allocator, options: Options) error{OutOfMemory}!*Runtime {
        const r = try gpa.create(RuntimeImpl);
        r.* = .{ .gpa = gpa, .rt = undefined, .discard = .init(&.{}) };
        r.rt = IRuntime.init(gpa, options.limits, options.output orelse &r.discard.writer);
        return @ptrCast(r);
    }

    /// Destroys everything the runtime still owns (E1), then the runtime.
    pub fn destroy(rt: *Runtime) void {
        const r = rt.impl();
        const guard = Guard.enter(r);
        _ = guard;
        r.rt.magic = 0; // handle operations must not enter after this (E1)
        while (r.executions.items.len > 0) r.executions.items[r.executions.items.len - 1].free();
        while (r.programs.items.len > 0) r.programs.items[r.programs.items.len - 1].free();
        r.executions.deinit(r.gpa);
        r.programs.deinit(r.gpa);
        r.rt.deinit();
        r.gpa.destroy(r);
    }

    /// Parses, resolves, compiles and verifies `source` (E8). On error.Source, `diag` (if
    /// given) says why and where; the runtime is unchanged.
    pub fn compile(rt: *Runtime, name: []const u8, source: []const u8, diag: ?*Diagnostic) CompileError!*Program {
        const r = rt.impl();
        const guard = Guard.enter(r);
        defer guard.exit();
        return r.compileImpl(name, source, diag);
    }

    /// Starts `program` from its first instruction, with fresh top-level bindings (E3).
    pub fn start(rt: *Runtime, program: *Program) StartError!*Execution {
        const r = rt.impl();
        const p = program.impl();
        checkProgramAlive(p);
        const guard = Guard.enter(r);
        defer guard.exit();
        const x = try r.startImpl(p);
        return @ptrCast(x);
    }

    /// Starts `program`, runs it to the end (within `limits.max_steps`), destroys the
    /// execution.
    pub fn run(rt: *Runtime, program: *Program, failure: ?*Failure) (StartError || RunError)!void {
        const r = rt.impl();
        const p = program.impl();
        checkProgramAlive(p);
        const guard = Guard.enter(r);
        defer guard.exit();
        const ex = try r.startImpl(p);
        defer ex.free();
        _ = try ex.resumeImpl(std.math.maxInt(u64), failure);
    }

    /// A major collection, now (between calls: no script is mid-instruction).
    pub fn collectGarbage(rt: *Runtime) void {
        const r = rt.impl();
        const guard = Guard.enter(r);
        defer guard.exit();
        r.rt.heap.major_requested = true;
        r.rt.collect();
    }

    pub fn memory(rt: *const Runtime) Memory {
        const r = rt.implConst();
        const guard = Guard.enter(@constCast(r));
        defer guard.exit();
        const h = &r.rt.heap;
        return .{
            .bytes = h.bytes + r.rt.handles.accounted, // handle pool bytes (D50)
            .peak = h.peak + r.rt.handles.peak,
            .collections = h.stats.collections,
        };
    }

    /// Mints a number handle (M9.1, D50). The token is the caller's to `release` (or
    /// `dup`); while the runtime is poisoned, nothing is minted (E7).
    pub fn newNumber(rt: *Runtime, n: f64) HandleError!*Handle {
        const r = rt.impl();
        const guard = Guard.enter(r);
        defer guard.exit();
        if (r.rt.poisoned) return error.Internal; // E7: only destroy works now
        return @ptrCast(try handles.Table.mint(&r.rt, .{ .number = n }));
    }

    pub fn newBoolean(rt: *Runtime, b: bool) HandleError!*Handle {
        const r = rt.impl();
        const guard = Guard.enter(r);
        defer guard.exit();
        if (r.rt.poisoned) return error.Internal; // E7
        return @ptrCast(try handles.Table.mint(&r.rt, .{ .boolean = b }));
    }

    /// Creates a heap string (E10: UTF-16 units in, lone surrogates kept) and mints a
    /// handle to it. Length and heap limits apply as for script strings.
    pub fn newStringUtf16(rt: *Runtime, units: []const u16) HandleError!*Handle {
        const r = rt.impl();
        const guard = Guard.enter(r);
        defer guard.exit();
        if (r.rt.poisoned) return error.Internal; // E7
        const s = r.rt.heap.newString(&.{.{ .utf16 = units }}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LimitExceeded => return error.LimitExceeded,
            else => unreachable, // newString only allocates and checks a limit
        };
        return @ptrCast(try handles.Table.mint(&r.rt, .{ .string = s }));
    }
};

pub const HandleError = error{ OutOfMemory, LimitExceeded, Internal };

/// A GC-safe reference to one JS value (M9.1, D50): a pointer to a token the runtime
/// owns. Handles may be copied only through `dup`; a released (or foreign) handle panics
/// when used, deterministically while the runtime is alive. Every operation works while
/// the runtime is poisoned — like `collectGarbage`/`memory`, they touch no VM state.
pub const Handle = opaque {
    fn tok(h: *const Handle) *handles.Token {
        return @ptrCast(@alignCast(@constCast(h)));
    }

    /// What the handle refers to (D54: uniform across all values).
    pub fn kind(h: *const Handle) HandleKind {
        const guard = Guard.enterIrt(h.tok().owner);
        defer guard.exit();
        return h.tok().kind();
    }

    /// The number, or null for any other kind (copies; never allocates, Q10/D54).
    pub fn number(h: *const Handle) ?f64 {
        const guard = Guard.enterIrt(h.tok().owner);
        defer guard.exit();
        return h.tok().number();
    }

    pub fn boolean(h: *const Handle) ?bool {
        const guard = Guard.enterIrt(h.tok().owner);
        defer guard.exit();
        return h.tok().boolean();
    }

    /// Wrong kind → null. Otherwise the string's full UTF-16 length; copies
    /// min(len, buf.len) units, so a too-small `buf` truncates visibly (D54).
    pub fn string(h: *const Handle, buf: []u16) ?usize {
        const guard = Guard.enterIrt(h.tok().owner);
        defer guard.exit();
        return h.tok().string(buf);
    }

    /// A new independently owned handle to the same value (Q3/Q4): the slot's reference
    /// count goes up. Fails with `LimitExceeded(handles)` at the pool's cap (D50).
    pub fn dup(h: *const Handle) HandleError!*Handle {
        const t = h.tok();
        const guard = Guard.enterIrt(t.owner);
        defer guard.exit();
        if (t.owner.poisoned) return error.Internal; // E7: nothing is minted
        return @ptrCast(try handles.Table.dup(t.owner, t));
    }

    /// Kills this handle and drops its slot reference; the slot's value becomes
    /// collectible at the last release (D50). Releasing twice is the host bug the token
    /// check panics on.
    pub fn release(h: *Handle) void {
        const guard = Guard.enterIrt(h.tok().owner);
        defer guard.exit();
        h.tok().release();
    }
};

/// How `Handle.kind` classifies a value (D54). Named `HandleKind` to stay clear of
/// `Failure.Kind`.
pub const HandleKind = handles.Kind;

pub const Program = opaque {
    fn impl(p: *Program) *ProgramImpl {
        return @ptrCast(@alignCast(p));
    }

    /// Drops the host's handle at once (E1). Executions of it keep running; its memory goes
    /// with the last of them, or with the runtime.
    pub fn destroy(program: *Program) void {
        const p = program.impl();
        checkAlive(p.magic, "Program");
        if (std.debug.runtime_safety and !p.host) @panic("zqjs: Program used after destroy");
        const guard = Guard.enter(p.owner);
        defer guard.exit();
        p.host = false;
        p.refs -= 1;
        if (p.refs == 0) p.free();
    }
};

pub const Execution = opaque {
    fn impl(ex: *Execution) *ExecutionImpl {
        return @ptrCast(@alignCast(ex));
    }

    /// Runs at most `steps` instructions (E4). `.suspended`: the slice ran out with the
    /// script unfinished; resume again to continue exactly where it stopped. `.finished`: it
    /// completed. An error faults this execution, and later resumes return the same error
    /// and failure; the runtime stays usable (E6).
    pub fn @"resume"(ex: *Execution, steps: u64, failure: ?*Failure) RunError!Status {
        const x = ex.impl();
        checkAlive(x.magic, "Execution");
        const guard = Guard.enter(x.owner);
        defer guard.exit();
        return x.resumeImpl(steps, failure);
    }

    /// Releases the execution and its roots, whatever its state (E1).
    pub fn destroy(ex: *Execution) void {
        const x = ex.impl();
        checkAlive(x.magic, "Execution");
        const guard = Guard.enter(x.owner);
        defer guard.exit();
        x.free();
    }
};

// ---- implementation (private)

const RuntimeImpl = struct {
    gpa: Allocator,
    rt: IRuntime,
    discard: std.Io.Writer.Discarding,
    programs: std.ArrayList(*ProgramImpl) = .empty,
    executions: std.ArrayList(*ExecutionImpl) = .empty,
    /// A static-format buffer for `rt.internal_reason` (the reason of the first
    /// defensive-check failure), so poisoning never allocates.
    reason_buf: [160]u8 = undefined,

    fn compileImpl(r: *RuntimeImpl, name: []const u8, source: []const u8, diag: ?*Diagnostic) CompileError!*Program {
        if (r.rt.poisoned) return error.Internal; // E7: only destroy works now
        _ = name;
        const gpa = r.gpa;
        const limits = r.rt.limits;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var d: internal.Diagnostic = .{};
        const script = internal.parse(arena.allocator(), source, limits, &d) catch |e| return sourceError(e, d, source, diag);
        const res = internal.resolve(arena.allocator(), script, &d) catch |e| return sourceError(e, d, source, diag);
        const p = try gpa.create(ProgramImpl);
        errdefer gpa.destroy(p);
        p.* = .{ .owner = r, .proto = internal.compile(gpa, &r.rt.heap, script, res, limits, &d) catch |e| return sourceError(e, d, source, diag) };
        errdefer p.proto.deinit(gpa);
        var failure: internal.verify.Failure = .{};
        _ = internal.verify.verify(gpa, &p.proto, limits, &failure) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidBytecode => r.invalidBytecode(&failure), // a compiler bug, never the script's (E7)
        };
        try r.programs.ensureUnusedCapacity(gpa, 1);
        try r.rt.addRoots(Vm.protoRoots(&p.proto)); // its constants live from now on (E3)
        r.programs.appendAssumeCapacity(p);
        return @ptrCast(p);
    }

    /// Poisons the runtime (E7): the compiler or verifier broke an invariant, so nothing
    /// it produced can be trusted.
    fn invalidBytecode(r: *RuntimeImpl, failure: *const internal.verify.Failure) CompileError {
        r.rt.poisoned = true;
        if (r.rt.internal_reason == null)
            r.rt.internal_reason = std.fmt.bufPrint(&r.reason_buf, "invalid bytecode at {d}: {s}", .{ failure.pc, failure.reason }) catch "invalid bytecode";
        return error.Internal;
    }

    fn startImpl(r: *RuntimeImpl, p: *ProgramImpl) StartError!*ExecutionImpl {
        if (r.rt.poisoned) return error.Internal; // E7: only destroy works now
        std.debug.assert(p.owner == r);
        const gpa = r.gpa;
        const x = try gpa.create(ExecutionImpl);
        errdefer gpa.destroy(x);
        x.* = .{
            .owner = r,
            .program = p,
            .vm = Vm.init(&r.rt, &p.proto) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.LimitExceeded => error.LimitExceeded,
                else => unreachable, // init only checks a limit and allocates
            },
        };
        errdefer x.vm.deinit();
        try r.executions.ensureUnusedCapacity(gpa, 1);
        try r.rt.addRoots(x.vm.roots());
        r.executions.appendAssumeCapacity(x);
        p.refs += 1; // the execution keeps the program alive (E1)
        return x;
    }
};

const Guard = struct {
    rt: *IRuntime,

    /// A host entry (E2). The atomic claim *is* the entry-kind stack's depth-0 bottom
    /// (D52): while it is held — for the whole top-level call, native callbacks
    /// included — any further host entry panics, same thread or not, exactly as in
    /// M9.0. The sanctioned engine descents (a native calling back through the public
    /// API, Q7) do not claim: they check the execution context's engine records (the
    /// in-flight native-call record as proof, D52) and run on the owner thread; that
    /// wiring lands with native dispatch (P4), which is what first creates engine
    /// entries.
    fn enter(r: *RuntimeImpl) Guard {
        return enterIrt(&r.rt);
    }

    /// Entry reached through an internal reference (a handle names its runtime).
    fn enterIrt(rt: *IRuntime) Guard {
        checkAlive(rt.magic, "Runtime"); // through a runtime that's gone: caught here (E1)
        if (rt.in_call.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) {
            @panic("zqjs: Runtime entered while another call into it is running");
        }
        return .{ .rt = rt };
    }

    fn exit(g: Guard) void {
        g.rt.in_call.store(false, .seq_cst);
    }
};

/// The tag live implementations carry is the internal runtime's (`alive_magic`,
/// runtime.zig): cleared (or the memory freed) on destroy, so a safe build's entry-point
/// check catches a use after destroy (E1). Best effort: the memory may have been reused,
/// so a missed catch is possible; documented as such.

fn checkAlive(magic: u32, comptime type_name: []const u8) void {
    if (std.debug.runtime_safety and magic != alive_magic)
        @panic("zqjs: " ++ type_name ++ " used after destroy");
}

/// A program's public handle dies at `Program.destroy`, even while its impl lives on for
/// its executions (E1): the `host` flag catches that case deterministically, the magic tag
/// the rest.
fn checkProgramAlive(p: *ProgramImpl) void {
    checkAlive(p.magic, "Program");
    if (std.debug.runtime_safety and !p.host) @panic("zqjs: Program used after destroy");
}

const ProgramImpl = struct {
    owner: *RuntimeImpl,
    proto: Proto,
    /// The host's handle, plus one per execution (E1).
    refs: u32 = 1,
    magic: u32 = alive_magic,
    /// The public handle still exists; `Program.destroy` clears it while executions keep
    /// the impl alive, so a later use of the handle is caught deterministically (E1).
    host: bool = true,

    fn free(p: *ProgramImpl) void {
        const r = p.owner;
        p.magic = 0;
        p.host = false;
        r.rt.removeRoots(&p.proto);
        for (r.programs.items, 0..) |q, i| if (q == p) {
            _ = r.programs.swapRemove(i);
            break;
        };
        p.proto.deinit(r.gpa);
        r.gpa.destroy(p);
    }
};

const Fault = struct { err: RunError, failure: Failure };

const ExecutionImpl = struct {
    owner: *RuntimeImpl,
    program: *ProgramImpl,
    vm: Vm,
    /// Steps charged over all resumes (E4): never reset.
    used: u64 = 0,
    fault: ?Fault = null,
    magic: u32 = alive_magic,

    fn free(x: *ExecutionImpl) void {
        const r = x.owner;
        x.magic = 0;
        r.rt.removeRoots(&x.vm);
        x.vm.deinit();
        for (r.executions.items, 0..) |y, i| if (y == x) {
            _ = r.executions.swapRemove(i);
            break;
        };
        const p = x.program;
        r.gpa.destroy(x);
        p.refs -= 1;
        if (p.refs == 0) p.free();
    }

    fn resumeImpl(x: *ExecutionImpl, steps: u64, failure: ?*Failure) RunError!Status {
        if (x.owner.rt.poisoned) {
            if (failure) |out| out.* = internalFailure();
            return error.Internal;
        }
        if (x.fault) |f| {
            if (failure) |out| out.* = f.failure;
            return f.err;
        }
        if (x.vm.halted) return .finished;
        const rt = &x.owner.rt;
        // The chain (M9.1, D51): one shared execution context per top-level entry. The
        // budget is cumulative per execution (E4): the context adopts `used`, every VM
        // and native record in the chain charges the same live counters, and the updated
        // count is saved back at the chain's end.
        rt.beginChain(x.used, rt.limits.max_steps);
        defer x.used = rt.endChain();
        x.vm.chain = &rt.exec_ctx; // its frames charge the chain's shared depth
        defer x.vm.chain = null;
        rt.exec_ctx.call_depth = @intCast(x.vm.frames.items.len); // the frames already live count (D51 #2)
        rt.exception = null;
        rt.unsupported = null;
        rt.unsupported_name = null;
        rt.limit_hit = null;
        rt.heap.limit_hit = null;
        var n: u64 = 0;
        while (n < steps) : (n += 1) {
            const state = x.vm.step() catch |e| {
                // Every Internal poisons (E7), whoever raised it: rt.bug does it, and
                // this is the belt that keeps the guarantee if a producer ever forgets.
                if (e == error.Internal and !rt.poisoned) {
                    rt.poisoned = true;
                    if (rt.internal_reason == null) rt.internal_reason = "Internal from a path that does not poison";
                }
                const f: Fault = .{ .err = publicError(e), .failure = describe(rt, e) };
                x.fault = f;
                if (failure) |out| out.* = f.failure;
                return f.err;
            };
            if (state == .halted) return .finished;
        }
        return if (x.vm.halted) .finished else .suspended;
    }
};

fn sourceError(e: anyerror, d: internal.Diagnostic, source: []const u8, diag: ?*Diagnostic) CompileError {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    if (diag) |out| {
        const loc = internal.Diagnostic.locate(source, d.start);
        out.* = .{ .line = loc.line, .column = loc.column, .start = d.start, .end = d.end };
        var w = TextWriter.init(&out.text, &out.text_len, &out.truncated);
        switch (d.detail) {
            .syntax_error => |msg| {
                w.utf8("SyntaxError: ");
                w.utf8(msg);
            },
            .unsupported => |f| {
                w.utf8("Unsupported(");
                w.utf8(@tagName(f));
                w.utf8("): ");
                w.utf8(f.description());
                if (d.end > d.start and d.end - d.start <= 16) {
                    w.utf8(" ('");
                    w.utf8(source[d.start..d.end]);
                    w.utf8("')");
                }
            },
            .limit_exceeded => |l| {
                w.utf8("LimitExceeded(");
                w.utf8(@tagName(l));
                w.utf8(")");
            },
        }
    }
    return error.Source;
}

/// The fixed text of an `internal` failure (E10): a ZQJS bug, never the script's.
fn internalFailure() Failure {
    var f: Failure = .{};
    var w = TextWriter.init(&f.text, &f.text_len, &f.truncated);
    w.utf8("internal error");
    return f;
}

fn publicError(e: internal.runtime.Error) RunError {
    return switch (e) {
        error.Thrown => error.Thrown,
        error.LimitExceeded => error.LimitExceeded,
        error.Unsupported => error.Unsupported,
        error.OutOfMemory => error.OutOfMemory,
        error.Internal => error.Internal,
        error.WriteFailed => error.OutputFailed,
    };
}

fn describe(rt: *IRuntime, e: internal.runtime.Error) Failure {
    var f: Failure = .{};
    var w = TextWriter.init(&f.text, &f.text_len, &f.truncated);
    switch (e) {
        error.Thrown => {
            f.kind = .thrown;
            const ex = rt.exception.?;
            w.utf8(@tagName(ex.name));
            w.utf8(": ");
            w.utf16(ex.message.units);
        },
        error.LimitExceeded => {
            f.kind = .limit;
            f.limit = rt.limitHit();
            w.utf8("LimitExceeded(");
            w.utf8(if (f.limit) |l| @tagName(l) else "?");
            w.utf8(")");
        },
        error.Unsupported => {
            f.kind = .unsupported;
            const feature = rt.unsupported.?;
            w.utf8("Unsupported(");
            w.utf8(@tagName(feature));
            w.utf8("): ");
            w.utf8(feature.description());
            if (rt.unsupported_name) |n| {
                w.utf8(" ('");
                w.utf16(n.units);
                w.utf8("')");
            }
        },
        error.OutOfMemory => {
            f.kind = .out_of_memory;
            w.utf8("out of memory");
        },
        error.Internal => {
            f.kind = .internal;
            w.utf8("internal error");
        },
        error.WriteFailed => {
            f.kind = .output;
            w.utf8("the output writer failed");
        },
    }
    return f;
}
