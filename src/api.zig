//! ZQJS's public embedding API (see EMBEDDING.md, decisions D46-D49).
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
const Value = internal.Value;
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
/// Which JavaScript error constructor `throwJs` raises (M9.1, D53).
pub const ErrorName = internal.ErrorName;

pub const Options = struct {
    limits: Limits = .{},
    /// Where `print` writes. Null: output is discarded.
    output: ?*std.Io.Writer = null,
    /// Optional monotonic nanosecond clock for GC pause telemetry (`Memory.last_gc_pause_ns`
    /// and `Memory.max_gc_pause_ns`). Null: pause durations stay 0 (D8).
    clock: ?*const fn (ctx: ?*anyopaque) u64 = null,
    clock_ctx: ?*anyopaque = null,
    /// Deterministic PRNG seed for `Math.random()` (M11.3a).
    /// Note: `Math.random()` is not cryptographically secure.
    random_seed: u64 = internal.Runtime.default_random_seed,
};

pub const Status = enum { finished, suspended };

pub const CompileError = error{ Source, Busy, OutOfMemory, Internal };
pub const StartError = error{ Busy, LimitExceeded, OutOfMemory, Internal };
pub const RunError = error{ Thrown, HostError, LimitExceeded, Unsupported, OutOfMemory, OutputFailed, Internal };
pub const ModuleLoadError = internal.module.LoadError;
pub const LoadedModule = internal.module.LoadedModule;
pub const ModuleLoader = internal.module.ModuleLoader;
pub const ModuleError = error{ Source, ModuleNotFound, Busy } || RunError;

/// A host native (M9.1, D53): runs with the guard held at depth ≥ 1 and may call back
/// into JS through the sanctioned API (D52).
///
/// Handle ownership across a callback (D50, D53):
/// - **Borrowed temporary handles (`this`, `args`):** owned by the engine's native-call
///   record — valid only during the call, released automatically at teardown on every
///   outcome. A native that wants to retain one beyond the callback must `dup` it; a
///   native may also assign `this` or `args[i]` directly to `out.result` (its value is
///   copied before teardown releases the record's tokens, without double-releasing).
/// - **Result handle (`out.result`):** transfers ownership of the assigned token to the
///   engine, which copies its value into the caller's operand slot and releases the token
///   at teardown on every outcome. Freshly minted tokens (`new*`, `call`) may be assigned
///   directly.
/// - **Host-owned retained handles:** to return a handle `H` the host already owns while
///   keeping `H` valid for later use, the callback must assign `out.result = try H.dup()`.
///   Assigning `H` directly moves `H` to the engine and releases it on teardown.
pub const NativeFn = fn (rt: *Runtime, ctx: ?*anyopaque, this: ?Handle, args: []const Handle, out: *NativeOut) NativeError!void;

pub const NativeOut = struct {
    /// Set on success (null → JS `undefined`). Ownership of the assigned handle moves to
    /// the engine, which copies its value into the caller's operand slot and releases the
    /// handle at teardown on every outcome (D50). To return a host-owned retained handle
    /// without consuming it, assign `try h.dup()`.
    result: ?Handle = null,
    /// Set on `error.HostError` (D53): the engine copies it into the `Failure` before
    /// the native's stack unwinds.
    host_message: []const u8 = "",
};

pub const NativeError = error{ Thrown, HostError, LimitExceeded, Unsupported, OutOfMemory, Internal };

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

    pub const Kind = enum { thrown, host, limit, unsupported, out_of_memory, output, internal };

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

/// Memory numbers of a runtime (accounted bytes, D28/D50).
pub const Memory = struct {
    /// Total accounted runtime memory (`heap_bytes + handle_bytes`).
    bytes: usize,
    /// High-water mark of total accounted runtime memory.
    peak: usize,
    /// GC-managed JavaScript heap bytes.
    heap_bytes: usize,
    /// Allocated handle-table capacity in bytes.
    handle_bytes: usize,
    /// Number of GC collections completed so far (`minor_collections + major_collections`).
    collections: u64,
    /// Number of minor (nursery) collections completed so far.
    minor_collections: u64 = 0,
    /// Number of major (full-heap) collections completed so far.
    major_collections: u64 = 0,
    /// Duration of the most recent GC pause in nanoseconds (`0` when `Options.clock == null`).
    last_gc_pause_ns: u64 = 0,
    /// Maximum GC pause duration observed so far in nanoseconds (`0` when `Options.clock == null`).
    max_gc_pause_ns: u64 = 0,
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
        r.* = .{
            .gpa = gpa,
            .rt = undefined,
            .discard = .init(&.{}),
            .clock = options.clock,
            .clock_ctx = options.clock_ctx,
        };
        r.rt = IRuntime.init(gpa, options.limits, options.output orelse &r.discard.writer);
        r.rt.setRandomSeed(options.random_seed);
        if (options.clock != null) {
            r.rt.heap.observer = .{
                .ctx = r,
                .clock = RuntimeImpl.observerClock,
                .record = RuntimeImpl.observerRecord,
            };
        }
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
        for (r.host_natives.items) |entry| r.gpa.destroy(entry);
        r.host_natives.deinit(r.gpa);
        r.executions.deinit(r.gpa);
        r.programs.deinit(r.gpa);
        r.rt.deinit();
        r.gpa.destroy(r);
    }

    /// Parses, resolves, compiles and verifies `source` (E8). On error.Source, `diag` (if
    /// given) says why and where; the runtime is unchanged. Returns `error.Busy` if called
    /// from inside an active native callback (D52).
    pub fn compile(rt: *Runtime, name: []const u8, source: []const u8, diag: ?*Diagnostic) CompileError!*Program {
        const r = rt.impl();
        const guard = try Guard.enterTopLevel(r);
        defer guard.exit();
        return r.compileImpl(name, source, diag);
    }

    /// Starts `program` from its first instruction, with fresh top-level bindings (E3).
    /// Returns `error.Busy` if called from inside an active native callback (D52).
    pub fn start(rt: *Runtime, program: *Program) StartError!*Execution {
        const r = rt.impl();
        const p = program.impl();
        checkProgramAlive(p);
        const guard = try Guard.enterTopLevel(r);
        defer guard.exit();
        const x = try r.startImpl(p);
        return @ptrCast(x);
    }

    /// Starts `program`, runs it to the end (within `limits.max_steps`), destroys the
    /// execution. Returns `error.Busy` if called from inside an active native callback (D52).
    pub fn run(rt: *Runtime, program: *Program, failure: ?*Failure) (StartError || RunError)!void {
        const r = rt.impl();
        const p = program.impl();
        checkProgramAlive(p);
        const guard = try Guard.enterTopLevel(r);
        defer guard.exit();
        const ex = try r.startImpl(p);
        defer ex.free();
        _ = try ex.resumeImpl(std.math.maxInt(u64), failure);
    }

    /// Registers (or clears) the host ES Module loader callback (M42, D72).
    pub fn setModuleLoader(rt: *Runtime, loader: ?ModuleLoader) error{Busy}!void {
        const r = rt.impl();
        const guard = try Guard.enterTopLevel(r);
        defer guard.exit();
        r.rt.modules.loader = loader;
    }

    /// Loads, links, and executes an ES Module graph on the VM, returning an owned
    /// `Handle` to the entry module's namespace object (M42, D72).
    pub fn runModule(rt: *Runtime, specifier: []const u8, source: []const u8, diag: ?*Diagnostic, failure: ?*Failure) ModuleError!Handle {
        const r = rt.impl();
        const guard = try Guard.enterTopLevel(r);
        defer guard.exit();
        if (r.rt.poisoned) {
            if (failure) |out| out.* = internalFailure();
            return error.Internal;
        }
        prepareRun(&r.rt);
        r.rt.steps = 0;
        r.rt.max_steps = r.rt.limits.max_steps;
        r.rt.stack_base = @frameAddress();

        var mod_diag: internal.module.ModuleDiag = .{};
        const ns_obj = internal.module.runEntry(&r.rt, specifier, source, .vm, &mod_diag) catch |e| switch (e) {
            error.SyntaxError, error.Unsupported => {
                return sourceError(e, mod_diag.diag, mod_diag.source, diag);
            },
            error.ModuleNotFound => {
                if (failure) |out| {
                    out.* = .{ .kind = .host };
                    var w = TextWriter.init(&out.text, &out.text_len, &out.truncated);
                    w.utf8("ModuleNotFound: ");
                    w.utf8(mod_diag.name);
                }
                return error.ModuleNotFound;
            },
            error.InvalidBytecode => {
                return failRun(&r.rt, r.rt.bug("invalid module bytecode"), failure);
            },
            error.LimitExceeded => {
                if (mod_diag.diag.detail == .limit_exceeded) {
                    _ = sourceError(e, mod_diag.diag, mod_diag.source, diag) catch {};
                }
                return failRun(&r.rt, error.LimitExceeded, failure);
            },
            error.Thrown, error.HostError, error.OutOfMemory, error.WriteFailed, error.Internal => |re| return failRun(&r.rt, re, failure),
        };
        return mintHandle(r, Value.fromObject(ns_obj), failure);
    }

    /// Returns an owned `Handle` to the namespace object of an already-loaded module.
    pub fn getModuleNamespace(rt: *Runtime, specifier: []const u8, failure: ?*Failure) (error{ModuleNotFound} || RunError)!Handle {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        if (r.rt.poisoned) {
            if (failure) |out| out.* = internalFailure();
            return error.Internal;
        }
        const mod = r.rt.modules.map.get(specifier) orelse return error.ModuleNotFound;
        const ns_obj = internal.module.getNamespace(&r.rt, mod) catch |e| return failRun(&r.rt, e, failure);
        return mintHandle(r, Value.fromObject(ns_obj), failure);
    }

    /// A major collection, now (between calls or inside a native callback: no script is
    /// mid-instruction, D52).
    pub fn collectGarbage(rt: *Runtime) void {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        r.rt.heap.major_requested = true;
        r.rt.collect();
    }

    pub fn memory(rt: *const Runtime) Memory {
        const r = rt.implConst();
        const guard = Guard.enterReentrant(@constCast(r));
        defer guard.exit();
        const h = &r.rt.heap;
        const hdl = &r.rt.handles;
        return .{
            .bytes = h.bytes + hdl.accounted,
            .peak = h.peak + hdl.peak,
            .heap_bytes = h.bytes,
            .handle_bytes = hdl.accounted,
            .collections = h.stats.collections,
            .minor_collections = h.stats.minor,
            .major_collections = h.stats.collections - h.stats.minor,
            .last_gc_pause_ns = r.last_gc_pause_ns,
            .max_gc_pause_ns = r.max_gc_pause_ns,
        };
    }

    /// Mints a number handle (M9.1, D50). The handle is the caller's to `release` (or
    /// `dup`); while the runtime is poisoned, nothing is minted (E7).
    pub fn newNumber(rt: *Runtime, n: f64) HandleError!Handle {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        if (r.rt.poisoned) return error.Internal; // E7: only destroy works now
        return Handle.fromToken(try handles.Table.mint(&r.rt, Value.fromNumber(n)));
    }

    pub fn newBoolean(rt: *Runtime, b: bool) HandleError!Handle {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        if (r.rt.poisoned) return error.Internal; // E7
        return Handle.fromToken(try handles.Table.mint(&r.rt, Value.fromBool(b)));
    }

    /// Creates a heap string (E10: UTF-16 units in, lone surrogates kept) and mints a
    /// handle to it. Length and heap limits apply as for script strings.
    pub fn newStringUtf16(rt: *Runtime, units: []const u16) HandleError!Handle {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        if (r.rt.poisoned) return error.Internal; // E7
        const s = r.rt.heap.newString(&.{.{ .utf16 = units }}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LimitExceeded => return error.LimitExceeded,
            else => unreachable, // newString only allocates and checks a limit
        };
        return Handle.fromToken(try handles.Table.mint(&r.rt, Value.fromString(s)));
    }

    /// Creates an empty ordinary JS object (`Object.prototype`) and mints an owned handle.
    pub fn newObject(rt: *Runtime) HandleError!Handle {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        if (r.rt.poisoned) return error.Internal;
        const realm = internal.builtins.realm(&r.rt) catch |e| return mapHandleInternalError(e);
        const obj = r.rt.heap.newObject(realm.object_prototype) catch |e| return mapHandleInternalError(e);
        return Handle.fromToken(try handles.Table.mint(&r.rt, Value.fromObject(obj)));
    }

    /// Creates an empty dense JS array (`Array.prototype`) and mints an owned handle.
    pub fn newArray(rt: *Runtime) HandleError!Handle {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        if (r.rt.poisoned) return error.Internal;
        const realm = internal.builtins.realm(&r.rt) catch |e| return mapHandleInternalError(e);
        const arr = r.rt.heap.newArray(realm.array_prototype) catch |e| return mapHandleInternalError(e);
        return Handle.fromToken(try handles.Table.mint(&r.rt, Value.fromObject(arr)));
    }

    /// Creates a zero-initialized `ArrayBuffer` of `byte_len` bytes and mints an owned handle.
    pub fn newArrayBuffer(rt: *Runtime, byte_len: usize) HandleError!Handle {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        if (r.rt.poisoned) return error.Internal;
        const vr = internal.builtins.viewsRealm(&r.rt) catch |e| return mapHandleInternalError(e);
        const ab = r.rt.heap.newArrayBuffer(vr.array_buffer_prototype, byte_len) catch |e| return mapHandleInternalError(e);
        return Handle.fromToken(try handles.Table.mint(&r.rt, Value.fromObject(ab)));
    }

    /// Returns a zero-copy mutable byte slice for an `ArrayBuffer`, `TypedArray` (its view
    /// subslice), or `DataView` (its view subslice), or `null` for any other handle kind.
    pub fn bufferBytes(rt: *Runtime, h: Handle) ?[]u8 {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        const val = handles.Token.checkedValue(&r.rt, h.tok());
        if (!val.isObject()) return null;
        return switch (val.asObject().kind) {
            .array_buffer => |ab| if (ab.detached) @constCast(@as([]const u8, &.{})) else ab.data,
            .typed_array => |ta| blk: {
                const ab = ta.buffer.kind.array_buffer;
                if (ab.detached) break :blk @constCast(@as([]const u8, &.{}));
                break :blk ab.data[ta.byte_offset .. ta.byte_offset + ta.length * ta.kind.bytesPerElement()];
            },
            .data_view => |dv| blk: {
                const ab = dv.buffer.kind.array_buffer;
                if (ab.detached) break :blk @constCast(@as([]const u8, &.{}));
                break :blk ab.data[dv.byte_offset .. dv.byte_offset + dv.byte_length];
            },
            else => null,
        };
    }

    /// Creates a pending JS Promise along with its `resolve` and `reject` capability
    /// functions (`{ promise, resolve, reject }`, M29, D57). All three handles are owned
    /// by the caller; settle the promise by passing `resolve` or `reject` to `rt.call`.
    /// On error (`OutOfMemory`, `LimitExceeded(heap_bytes | handles)`, `Internal`), no
    /// handle slots remain allocated.
    pub fn newPromise(rt: *Runtime) HandleError!PromiseCapability {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        if (r.rt.poisoned) return error.Internal;
        r.rt.limit_hit = null;
        r.rt.heap.limit_hit = null;
        const realm = internal.builtins.realm(&r.rt) catch |e| return mapHandleInternalError(e);
        const p = r.rt.heap.newPromise(realm.promise_prototype) catch |e| return mapHandleInternalError(e);
        const res_cap = r.rt.heap.newPromiseCapability(p, false) catch |e| return mapHandleInternalError(e);
        const rej_cap = r.rt.heap.newPromiseCapability(p, true) catch |e| return mapHandleInternalError(e);
        const p_tok = try handles.Table.mint(&r.rt, Value.fromObject(p));
        errdefer p_tok.release();
        const res_tok = try handles.Table.mint(&r.rt, Value.fromClosure(res_cap));
        errdefer res_tok.release();
        const rej_tok = try handles.Table.mint(&r.rt, Value.fromClosure(rej_cap));
        return .{
            .promise = Handle.fromToken(p_tok),
            .resolve = Handle.fromToken(res_tok),
            .reject = Handle.fromToken(rej_tok),
        };
    }

    /// Inspects the state of the Promise `h` names (M29, D57).
    /// - Returns `null` if `h` is not a Promise object.
    /// - Returns `.pending` without allocating or minting a handle when pending.
    /// - Returns `.{ .fulfilled = val }` or `.{ .rejected = reason }` with a newly minted
    ///   owned `Handle` when settled (`h` itself is borrowed and never consumed).
    pub fn promiseState(rt: *Runtime, h: Handle) HandleError!?PromiseState {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        const v = handles.Token.checkedValue(&r.rt, h.tok());
        if (r.rt.poisoned) return error.Internal;
        if (!v.isObject() or v.asObject().kind != .promise) return null;
        const pr = &v.asObject().kind.promise;
        return switch (pr.state) {
            .pending => .pending,
            .fulfilled => .{ .fulfilled = Handle.fromToken(try handles.Table.mint(&r.rt, pr.result)) },
            .rejected => .{ .rejected = Handle.fromToken(try handles.Table.mint(&r.rt, pr.result)) },
        };
    }

    /// Reads a runtime global (`Math`, `Object`, `Array`, host-registered natives,
    /// `undefined`, `NaN`, `Infinity`) and mints an owned handle (E3: script top-level
    /// bindings are per-execution and are not stored here).
    pub fn getGlobal(rt: *Runtime, name: []const u8, failure: ?*Failure) RunError!Handle {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        if (r.rt.poisoned) {
            if (failure) |out| out.* = internalFailure();
            return error.Internal;
        }
        prepareRun(&r.rt);
        const val = internal.builtins.global(&r.rt, name) catch |e| return failRun(&r.rt, e, failure);
        return mintHandle(r, val, failure);
    }

    /// Reads `obj[key]` using JS property semantics and mints an owned handle. Missing
    /// properties return an owned `undefined` handle; `obj` is borrowed.
    pub fn getProperty(rt: *Runtime, obj: Handle, key: []const u8, failure: ?*Failure) RunError!Handle {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        if (r.rt.poisoned) {
            if (failure) |out| out.* = internalFailure();
            return error.Internal;
        }
        const base = handles.Token.checkedValue(&r.rt, obj.tok());
        prepareRun(&r.rt);
        const k = propertyKey(&r.rt, key) catch |e| return failRun(&r.rt, e, failure);
        const val = internal.object.get(&r.rt, base, k) catch |e| return failRun(&r.rt, e, failure);
        return mintHandle(r, val, failure);
    }

    /// Writes `obj[key] = val` using JS property semantics (dense-array rules apply: D13).
    /// Both `obj` and `val` are borrowed and never released.
    pub fn setProperty(rt: *Runtime, obj: Handle, key: []const u8, val: Handle, failure: ?*Failure) RunError!void {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        if (r.rt.poisoned) {
            if (failure) |out| out.* = internalFailure();
            return error.Internal;
        }
        const base = handles.Token.checkedValue(&r.rt, obj.tok());
        const v = handles.Token.checkedValue(&r.rt, val.tok());
        prepareRun(&r.rt);
        const k = propertyKey(&r.rt, key) catch |e| return failRun(&r.rt, e, failure);
        internal.object.set(&r.rt, base, k, v) catch |e| return failRun(&r.rt, e, failure);
    }

    /// Reads `obj[index]` without string formatting and mints an owned handle. Out-of-range
    /// array indices return an owned `undefined` handle; `obj` is borrowed.
    pub fn getIndex(rt: *Runtime, obj: Handle, index: u32, failure: ?*Failure) RunError!Handle {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        if (r.rt.poisoned) {
            if (failure) |out| out.* = internalFailure();
            return error.Internal;
        }
        const base = handles.Token.checkedValue(&r.rt, obj.tok());
        prepareRun(&r.rt);
        const k = indexKey(&r.rt, index) catch |e| return failRun(&r.rt, e, failure);
        const val = internal.object.get(&r.rt, base, k) catch |e| return failRun(&r.rt, e, failure);
        return mintHandle(r, val, failure);
    }

    /// Writes `obj[index] = val` (dense-array rules apply: `index == length` appends,
    /// `index > length` fails with `error.Unsupported`). Both `obj` and `val` are borrowed.
    pub fn setIndex(rt: *Runtime, obj: Handle, index: u32, val: Handle, failure: ?*Failure) RunError!void {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        if (r.rt.poisoned) {
            if (failure) |out| out.* = internalFailure();
            return error.Internal;
        }
        const base = handles.Token.checkedValue(&r.rt, obj.tok());
        const v = handles.Token.checkedValue(&r.rt, val.tok());
        prepareRun(&r.rt);
        const k = indexKey(&r.rt, index) catch |e| return failRun(&r.rt, e, failure);
        internal.object.set(&r.rt, base, k, v) catch |e| return failRun(&r.rt, e, failure);
    }

    /// JS → host (M9.1, D53): registers a host native as a global function under `name`.
    /// Duplicate names — including built-in names — return `error.NameTaken` and leave
    /// the realm unchanged. `ctx` is borrowed by the runtime until `Runtime.destroy`.
    pub fn defineGlobalFunction(rt: *Runtime, name: []const u8, native: *const NativeFn, ctx: ?*anyopaque) error{ OutOfMemory, NameTaken }!void {
        const r = rt.impl();
        const guard = Guard.enter(r);
        defer guard.exit();
        return r.defineGlobalFunctionImpl(name, native, ctx);
    }

    /// JS → host failure for a deliberate JS exception (M9.1, D53): kind + UTF-16 message,
    /// converted through the E10 rules for the `Failure` text. Must be paired with
    /// returning `error.Thrown` from a `NativeFn`; returning `error.Thrown` without doing
    /// so is a host bug (checked).
    pub fn throwJs(rt: *Runtime, name: ErrorName, message: []const u16) void {
        const r = rt.impl();
        if (!Guard.isActiveCallback(&r.rt))
            @panic("zqjs: throwJs called outside an active NativeFn callback");
        r.rt.exec_ctx.topRecord().?.threw_js = true;
        if (r.rt.poisoned) return;
        const msg = r.rt.heap.newString(&.{.{ .utf16 = message }}) catch |e| {
            r.rt.clearThrown();
            r.rt.pending_throw_fault = e;
            return;
        };
        r.rt.pending_throw_fault = null;
        r.rt.thrown_value = null;
        r.rt.exception = .{ .name = name, .message = msg };
    }

    /// Host → JS (M9.1, D51): calls the function `f` names with `this` and the
    /// arguments, runs it to completion under a fresh chain's cumulative budget (Q8: no
    /// steps parameter in M9.1), and returns the result as a handle the caller owns.
    /// This works while an execution is suspended (a fresh context over the shared
    /// realm); mid-callback (inside a native, P4) it is the guard's engine descent, not
    /// a host entry. A script exception is error.Thrown with the details in `failure`.
    pub fn call(rt: *Runtime, f: Handle, this: ?Handle, args: []const Handle, failure: ?*Failure) RunError!Handle {
        const r = rt.impl();
        const guard = Guard.enterReentrant(r);
        defer guard.exit();
        return callImpl(r, f, this, args, failure);
    }
};

pub const HandleError = error{ OutOfMemory, LimitExceeded, Internal };

/// A host-created Promise and its settlement capabilities (`Runtime.newPromise`, M29, D57).
/// All three handles are independently owned by the caller and must each be `release`d.
pub const PromiseCapability = struct {
    promise: Handle,
    resolve: Handle,
    reject: Handle,
};

/// State of a Promise inspected via `Runtime.promiseState` (M29, D57).
/// For `.fulfilled` and `.rejected`, the associated `Handle` is newly minted and owned
/// by the caller (must be `release`d). `.pending` never allocates or mints a handle.
pub const PromiseState = union(enum) {
    pending,
    fulfilled: Handle,
    rejected: Handle,
};

/// A GC-safe reference to one JS value (M9.1, D50): a value token `{ owner, slot,
/// generation }` naming a reusable slot in the runtime's handle table. Independent
/// ownership is created through `dup`; a released (or foreign) handle panics when used,
/// deterministically while the runtime is alive — even after its slot has been reused.
/// Every read and `release` works while the runtime is poisoned — like
/// `collectGarbage`/`memory`, they touch no VM state.
pub const Handle = struct {
    owner: *anyopaque,
    slot: u32,
    generation: u64,

    fn fromToken(t: handles.Token) Handle {
        return .{
            .owner = t.owner,
            .slot = t.slot,
            .generation = t.generation,
        };
    }

    fn tok(h: Handle) handles.Token {
        return .{
            .owner = @ptrCast(@alignCast(h.owner)),
            .slot = h.slot,
            .generation = h.generation,
        };
    }

    /// What the handle refers to (D54: uniform across all values).
    pub fn kind(h: Handle) HandleKind {
        const t = h.tok();
        const guard = Guard.enterReentrantIrt(t.owner);
        defer guard.exit();
        return t.kind();
    }

    /// The number, or null for any other kind (copies; never allocates, Q10/D54).
    pub fn number(h: Handle) ?f64 {
        const t = h.tok();
        const guard = Guard.enterReentrantIrt(t.owner);
        defer guard.exit();
        return t.number();
    }

    pub fn boolean(h: Handle) ?bool {
        const t = h.tok();
        const guard = Guard.enterReentrantIrt(t.owner);
        defer guard.exit();
        return t.boolean();
    }

    /// Wrong kind → null. Otherwise the string's full UTF-16 length; copies
    /// min(len, buf.len) units, so a too-small `buf` truncates visibly (D54).
    pub fn string(h: Handle, buf: []u16) ?usize {
        const t = h.tok();
        const guard = Guard.enterReentrantIrt(t.owner);
        defer guard.exit();
        return t.string(buf);
    }

    /// A new independently owned handle to the same value in its own slot (D50). Fails
    /// with `LimitExceeded(handles)` at the slot table's cap.
    pub fn dup(h: Handle) HandleError!Handle {
        const t = h.tok();
        const guard = Guard.enterReentrantIrt(t.owner);
        defer guard.exit();
        if (t.owner.poisoned) return error.Internal; // E7: nothing is minted
        return fromToken(try handles.Table.dup(t.owner, t));
    }

    /// Invalidates this handle and recycles its slot (D50). Releasing twice is a host
    /// bug that panics deterministically.
    pub fn release(h: Handle) void {
        const t = h.tok();
        const guard = Guard.enterReentrantIrt(t.owner);
        defer guard.exit();
        t.release();
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
    host_natives: std.ArrayList(*HostNativeEntry) = .empty,
    clock: ?*const fn (ctx: ?*anyopaque) u64 = null,
    clock_ctx: ?*anyopaque = null,
    last_gc_pause_ns: u64 = 0,
    max_gc_pause_ns: u64 = 0,
    /// A static-format buffer for `rt.internal_reason` (the reason of the first
    /// defensive-check failure), so poisoning never allocates.
    reason_buf: [160]u8 = undefined,

    fn observerClock(ctx: *anyopaque) u64 {
        const r: *RuntimeImpl = @ptrCast(@alignCast(ctx));
        return r.clock.?(r.clock_ctx);
    }

    fn observerRecord(ctx: *anyopaque, sample: internal.heap.Heap.Sample) void {
        const r: *RuntimeImpl = @ptrCast(@alignCast(ctx));
        r.last_gc_pause_ns = sample.duration_ns;
        if (sample.duration_ns > r.max_gc_pause_ns) {
            r.max_gc_pause_ns = sample.duration_ns;
        }
    }

    fn defineGlobalFunctionImpl(r: *RuntimeImpl, name: []const u8, native: *const NativeFn, ctx: ?*anyopaque) error{ OutOfMemory, NameTaken }!void {
        if (internal.builtins.isBuiltinGlobal(name)) return error.NameTaken;
        for (r.rt.host_globals.items) |n| if (std.mem.eql(u8, n.name, name)) return error.NameTaken;

        const gpa = r.gpa;
        const name_copy = try gpa.dupe(u8, name);
        errdefer gpa.free(name_copy);
        const entry = try gpa.create(HostNativeEntry);
        errdefer gpa.destroy(entry);
        const nat = try gpa.create(internal.Native);
        errdefer gpa.destroy(nat);
        try r.host_natives.ensureUnusedCapacity(gpa, 1);
        try r.rt.host_globals.ensureUnusedCapacity(gpa, 1);

        entry.* = .{ .owner = r, .func = native, .ctx = ctx };
        nat.* = .{
            .name = name_copy,
            .call = unreachableNativeCall,
            .host = .{ .call = dispatchHostNative, .ctx = entry },
        };
        r.host_natives.appendAssumeCapacity(entry);
        r.rt.host_globals.appendAssumeCapacity(nat);
    }

    fn compileImpl(r: *RuntimeImpl, name: []const u8, source: []const u8, diag: ?*Diagnostic) CompileError!*Program {
        if (r.rt.poisoned) return error.Internal; // E7: only destroy works now
        const gpa = r.gpa;
        const limits = r.rt.limits;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var d: internal.Diagnostic = .{};
        const script = internal.parse(arena.allocator(), source, limits, &d) catch |e| return sourceError(e, d, source, diag);
        const res = internal.resolve(arena.allocator(), script, &d) catch |e| return sourceError(e, d, source, diag);
        const p = try gpa.create(ProgramImpl);
        errdefer gpa.destroy(p);
        p.* = .{ .owner = r, .proto = internal.compileWithOptions(gpa, &r.rt.heap, script, res, limits, .{ .source_name = name, .source = source }, &d) catch |e| return sourceError(e, d, source, diag) };
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
    claimed: bool,

    /// Whether the current thread is inside an active, un-suspended `NativeFn` callback
    /// on `rt` (D52: the top engine record is the capability proof).
    fn isActiveCallback(rt: *IRuntime) bool {
        checkAlive(rt.magic, "Runtime");
        if (!rt.in_call.load(.seq_cst)) return false;
        if (rt.owner_thread != std.Thread.getCurrentId()) return false;
        const rec = rt.exec_ctx.topRecord() orelse return false;
        return rec.live and !rec.suspended;
    }

    /// A host entry (E2): requires depth 0 and an unclaimed thread; claims `in_call` and
    /// `owner_thread`. At depth > 0 (same thread or not): panics, exactly as in M9.0.
    fn enter(r: *RuntimeImpl) Guard {
        return enterIrt(&r.rt);
    }

    fn enterIrt(rt: *IRuntime) Guard {
        checkAlive(rt.magic, "Runtime"); // through a runtime that's gone: caught here (E1)
        if (rt.in_call.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) {
            @panic("zqjs: Runtime entered while another call into it is running");
        }
        rt.owner_thread = std.Thread.getCurrentId();
        rt.stack_base = @frameAddress(); // D60: depth 0, the base of this entry's native stack
        return .{ .rt = rt, .claimed = true };
    }

    /// Top-level entry for `compile`, `start`, and `run` (Q7, D52): returns `error.Busy`
    /// when called on the owner thread from inside an active native callback; panics on
    /// any other overlap (e.g. from an output writer or another thread).
    fn enterTopLevel(r: *RuntimeImpl) error{Busy}!Guard {
        const rt = &r.rt;
        checkAlive(rt.magic, "Runtime");
        if (rt.in_call.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) {
            if (isActiveCallback(rt)) return error.Busy;
            @panic("zqjs: Runtime entered while another call into it is running");
        }
        rt.owner_thread = std.Thread.getCurrentId();
        rt.stack_base = @frameAddress(); // D60: depth 0, the base of this entry's native stack
        return .{ .rt = rt, .claimed = true };
    }

    /// Sanctioned re-entrant entry (Q7, D52): claims depth 0 as a host entry if idle, or
    /// descends at depth > 0 on the owner thread when an un-suspended native-call record
    /// is at the top of `exec_ctx.records`. Any other overlap panics.
    fn enterReentrant(r: *RuntimeImpl) Guard {
        return enterReentrantIrt(&r.rt);
    }

    fn enterReentrantIrt(rt: *IRuntime) Guard {
        checkAlive(rt.magic, "Runtime");
        if (rt.in_call.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) {
            if (isActiveCallback(rt)) return .{ .rt = rt, .claimed = false };
            @panic("zqjs: Runtime entered while another call into it is running");
        }
        rt.owner_thread = std.Thread.getCurrentId();
        rt.stack_base = @frameAddress(); // D60: depth 0, the base of this entry's native stack
        return .{ .rt = rt, .claimed = true };
    }

    fn exit(g: Guard) void {
        if (g.claimed) {
            g.rt.owner_thread = null;
            g.rt.in_call.store(false, .seq_cst);
        }
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
        defer {
            std.debug.assert(rt.exec_ctx.call_depth == x.vm.frames.items.len);
            x.vm.chain = null;
        }
        rt.exec_ctx.call_depth = @intCast(x.vm.frames.items.len); // the frames already live count (D51 #2)
        rt.clearThrown();
        rt.unsupported = null;
        rt.unsupported_name = null;
        rt.limit_hit = null;
        rt.heap.limit_hit = null;
        const state = x.vm.runSteps(steps) catch |e| {
            const f = faultOf(rt, e); // the poison belt runs for every fault (E7)
            x.fault = f;
            if (failure) |out| out.* = f.failure;
            return f.err;
        };
        return if (state == .halted) .finished else .suspended;
    }
};

fn mapHandleInternalError(e: internal.runtime.Error) HandleError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.LimitExceeded => error.LimitExceeded,
        error.Internal => error.Internal,
        else => unreachable,
    };
}

fn prepareRun(rt: *IRuntime) void {
    rt.clearThrown();
    rt.unsupported = null;
    rt.unsupported_name = null;
    rt.limit_hit = null;
    rt.heap.limit_hit = null;
}

fn failRun(rt: *IRuntime, e: internal.runtime.Error, failure: ?*Failure) RunError {
    const fo = faultOf(rt, e);
    if (failure) |out| out.* = fo.failure;
    return fo.err;
}

fn propertyKey(rt: *IRuntime, key: []const u8) internal.runtime.Error!internal.object.Key {
    var ascii = true;
    for (key) |b| {
        if (b >= 0x80) {
            ascii = false;
            break;
        }
    }
    if (ascii) return internal.object.named(rt, key);
    const units = std.unicode.utf8ToUtf16LeAlloc(rt.gpa, key) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return rt.throw(.TypeError, &.{.{ .ascii = "invalid UTF-8 property key" }}),
    };
    defer rt.gpa.free(units);
    return internal.object.keyUnits(rt, units);
}

fn indexKey(rt: *IRuntime, index: u32) internal.runtime.Error!internal.object.Key {
    if (index <= std.math.maxInt(u32) - 1) return .{ .index = index };
    return .{ .atom = try rt.heap.internAscii("4294967295") };
}

/// The belt and the description every fault goes through (E7/E10): an `Internal` from
/// any path poisons the runtime (whoever raised it), and the failure carries the
/// host-facing classification and text. Used by both `resume` and `rt.call`.
fn faultOf(rt: *IRuntime, e: internal.runtime.Error) Fault {
    if (e == error.Internal and !rt.poisoned) {
        rt.poisoned = true;
        if (rt.internal_reason == null) rt.internal_reason = "Internal from a path that does not poison";
    }
    return .{ .err = publicError(e), .failure = describe(rt, e) };
}

/// Host → JS (M9.1, D51): runs the call on a fresh chain. The callee may be a built-in
/// native (runs directly: it never calls back into JS, D40, and charges no steps) or a
/// VM closure (a nested VM over the shared heap and realm, model B).
fn callImpl(r: *RuntimeImpl, f: Handle, this_h: ?Handle, args: []const Handle, failure: ?*Failure) RunError!Handle {
    const rt = &r.rt;
    if (rt.poisoned) {
        if (failure) |out| out.* = internalFailure();
        return error.Internal; // E7: only destroy works now
    }
    // Every token is validated against THIS runtime first: a released or foreign handle
    // panics here, deterministically (E1/D50) — the identity check's exercisable site.
    const callee = handles.Token.checkedValue(rt, f.tok());
    const this_v: internal.Value = if (this_h) |h| handles.Token.checkedValue(rt, h.tok()) else .undefined;
    for (args) |h| _ = handles.Token.checkedValue(rt, h.tok());

    // Fresh chain at depth 0 (D51): a host call begins with a zeroed cumulative budget
    // and saves nothing back (Q8: no slicing in M9.1). Inside an active chain (a native
    // callback calling back into JS), joins the existing chain without resetting budget.
    const top_level = !rt.exec_ctx.active;
    if (top_level) rt.beginChain(0, rt.limits.max_steps);
    const parent_record = rt.exec_ctx.topRecord();
    if (parent_record) |rec| rec.suspended = true;
    const depth_before = rt.exec_ctx.call_depth;
    defer {
        if (parent_record) |rec| rec.suspended = false;
        std.debug.assert(rt.exec_ctx.call_depth == depth_before);
        if (top_level) _ = rt.endChain();
    }
    if (rt.exec_ctx.budget_fault != null) {
        const fo = faultOf(rt, rt.limit(.steps));
        if (failure) |out| out.* = fo.failure;
        return fo.err;
    }
    rt.clearThrown();
    rt.pending_throw_fault = null;
    rt.unsupported = null;
    rt.unsupported_name = null;
    rt.limit_hit = null;
    rt.heap.limit_hit = null;
    rt.host_message_len = 0;
    rt.host_message_truncated = false;

    const argv = r.gpa.alloc(internal.Value, args.len) catch |e| {
        const fo = faultOf(rt, e);
        if (failure) |out| out.* = fo.failure;
        return fo.err;
    };
    defer r.gpa.free(argv);
    for (args, 0..) |h, i| argv[i] = handles.Token.checkedValue(rt, h.tok());

    switch (callee.unpack()) {
        .native => |n| {
            const this_obj: ?internal.Value = if (this_v.isObject()) this_v else null;
            const result = (if (n.host) |h|
                h.call(rt, h.ctx, this_obj, argv)
            else
                n.call(rt, this_v, argv)) catch |e| {
                const err = if (e != error.Internal and rt.exec_ctx.budget_fault != null) rt.limit(.steps) else e;
                const fo = faultOf(rt, err);
                if (failure) |out| out.* = fo.failure;
                return fo.err;
            };
            if (rt.exec_ctx.budget_fault != null) {
                const fo = faultOf(rt, rt.limit(.steps));
                if (failure) |out| out.* = fo.failure;
                return fo.err;
            }
            if (top_level) {
                drainTopLevelMicrotasks(rt, result) catch |e| {
                    const err = if (e != error.Internal and rt.exec_ctx.budget_fault != null) rt.limit(.steps) else e;
                    const fo = faultOf(rt, err);
                    if (failure) |out| out.* = fo.failure;
                    return fo.err;
                };
            }
            return mintHandle(r, result, failure);
        },
        .closure => |c| {
            var target_closure = c;
            var call_this = this_v;
            var bound_combined: ?[]internal.Value = null;
            defer if (bound_combined) |bc| rt.gpa.free(bc);
            var call_argv: []const internal.Value = argv;

            if (c.impl == .bound) {
                const b = c.impl.bound;
                call_this = b.bound_this;
                if (b.bound_args.len > 0) {
                    const buf = rt.gpa.alloc(internal.Value, b.bound_args.len + argv.len) catch |e| {
                        const fo = faultOf(rt, e);
                        if (failure) |out| out.* = fo.failure;
                        return fo.err;
                    };
                    @memcpy(buf[0..b.bound_args.len], b.bound_args);
                    @memcpy(buf[b.bound_args.len..], argv);
                    bound_combined = buf;
                    call_argv = buf;
                }
                if (b.target.isNative()) {
                    const n = b.target.asNative();
                    const this_obj: ?internal.Value = if (call_this.isObjectLike()) call_this else null;
                    const result = (if (n.host) |h|
                        h.call(rt, h.ctx, this_obj, call_argv)
                    else
                        n.call(rt, call_this, call_argv)) catch |e| {
                        const err = if (e != error.Internal and rt.exec_ctx.budget_fault != null) rt.limit(.steps) else e;
                        const fo = faultOf(rt, err);
                        if (failure) |out| out.* = fo.failure;
                        return fo.err;
                    };
                    if (rt.exec_ctx.budget_fault != null) {
                        const fo = faultOf(rt, rt.limit(.steps));
                        if (failure) |out| out.* = fo.failure;
                        return fo.err;
                    }
                    if (top_level) {
                        drainTopLevelMicrotasks(rt, result) catch |e| {
                            const err = if (e != error.Internal and rt.exec_ctx.budget_fault != null) rt.limit(.steps) else e;
                            const fo = faultOf(rt, err);
                            if (failure) |out| out.* = fo.failure;
                            return fo.err;
                        };
                    }
                    return mintHandle(r, result, failure);
                }
                target_closure = b.target.asClosure();
            }
            if (target_closure.impl == .promise_cap) {
                const pc = target_closure.impl.promise_cap;
                const result = internal.builtins.callPromiseCapability(rt, pc.promise, pc.is_reject, call_argv) catch |e| {
                    const fo = faultOf(rt, e);
                    if (failure) |out| out.* = fo.failure;
                    return fo.err;
                };
                if (top_level) {
                    drainTopLevelMicrotasks(rt, result) catch |e| {
                        const err = if (e != error.Internal and rt.exec_ctx.budget_fault != null) rt.limit(.steps) else e;
                        const fo = faultOf(rt, err);
                        if (failure) |out| out.* = fo.failure;
                        return fo.err;
                    };
                }
                return mintHandle(r, result, failure);
            }
            if (target_closure.impl == .native_closure) {
                const nc = target_closure.impl.native_closure;
                const func: *const fn (*IRuntime, *internal.heap.Object, []const internal.Value) internal.runtime.Error!internal.Value = @ptrCast(@alignCast(nc.func));
                const result = func(rt, nc.env, call_argv) catch |e| {
                    const err = if (e != error.Internal and rt.exec_ctx.budget_fault != null) rt.limit(.steps) else e;
                    const fo = faultOf(rt, err);
                    if (failure) |out| out.* = fo.failure;
                    return fo.err;
                };
                if (top_level) {
                    drainTopLevelMicrotasks(rt, result) catch |e| {
                        const err = if (e != error.Internal and rt.exec_ctx.budget_fault != null) rt.limit(.steps) else e;
                        const fo = faultOf(rt, err);
                        if (failure) |out| out.* = fo.failure;
                        return fo.err;
                    };
                }
                return mintHandle(r, result, failure);
            }
            // Model B (D51): a fresh VM, frame 0 the callee; `this` binds by the VM's
            // sloppy rule (object receivers only, D41). Its `return` ends the call.
            const this_obj: ?internal.Value = if (call_this.isObjectLike()) call_this else null;
            if (target_closure.impl == .vm) {
                const callee_proto: *const internal.bytecode.Proto = @ptrCast(@alignCast(target_closure.impl.vm.proto));
                if (callee_proto.is_async) {
                    const result = internal.Vm.callStandalone(rt, target_closure, this_obj, call_argv) catch |e| {
                        const err = if (e != error.Internal and rt.exec_ctx.budget_fault != null) rt.limit(.steps) else e;
                        const fo = faultOf(rt, err);
                        if (failure) |out| out.* = fo.failure;
                        return fo.err;
                    };
                    if (top_level) {
                        drainTopLevelMicrotasks(rt, result) catch |e| {
                            const err = if (e != error.Internal and rt.exec_ctx.budget_fault != null) rt.limit(.steps) else e;
                            const fo = faultOf(rt, err);
                            if (failure) |out| out.* = fo.failure;
                            return fo.err;
                        };
                    }
                    return mintHandle(r, result, failure);
                }
            }
            if (rt.exec_ctx.call_depth >= rt.limits.max_call_depth) {
                const fo = faultOf(rt, rt.limit(.call_depth));
                if (failure) |out| out.* = fo.failure;
                return fo.err;
            }
            rt.checkNativeStack() catch |e| {
                const fo = faultOf(rt, e);
                if (failure) |out| out.* = fo.failure;
                return fo.err;
            };
            var vm = internal.Vm.initCall(rt, target_closure, this_obj, call_argv) catch |e| {
                const fo = faultOf(rt, e);
                if (failure) |out| out.* = fo.failure;
                return fo.err;
            };
            defer vm.deinit(); // unwinds exactly the frames a fault left live
            vm.chain = &rt.exec_ctx;
            rt.exec_ctx.call_depth += 1; // frame 0 is live from here (D51 #2)
            rt.exec_ctx.vms.append(rt.gpa, vm.roots()) catch |e| { // traced from now on
                const fo = faultOf(rt, e);
                if (failure) |out| out.* = fo.failure;
                return fo.err;
            };
            defer rt.exec_ctx.removeVm(&vm); // before deinit frees what it marks
            vm.run() catch |e| {
                const err = if (e != error.Internal and rt.exec_ctx.budget_fault != null) rt.limit(.steps) else e;
                const fo = faultOf(rt, err);
                if (failure) |out| out.* = fo.failure;
                return fo.err;
            };
            if (rt.exec_ctx.budget_fault != null) {
                const fo = faultOf(rt, rt.limit(.steps));
                if (failure) |out| out.* = fo.failure;
                return fo.err;
            }
            const result = vm.nested_result orelse {
                const fo = faultOf(rt, rt.bug("a nested call ended without a result"));
                if (failure) |out| out.* = fo.failure;
                return fo.err;
            };
            if (top_level) {
                drainTopLevelMicrotasks(rt, result) catch |e| {
                    const err = if (e != error.Internal and rt.exec_ctx.budget_fault != null) rt.limit(.steps) else e;
                    const fo = faultOf(rt, err);
                    if (failure) |out| out.* = fo.failure;
                    return fo.err;
                };
            }
            return mintHandle(r, result, failure);
        },
        else => {
            // Not a function: the same TypeError the VM throws at a `.call` (E5: a
            // JS-visible event, described as a thrown failure — not a host error).
            const e = rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }});
            const fo = faultOf(rt, e);
            if (failure) |out| out.* = fo.failure;
            return fo.err;
        },
    }
}

/// Drains queued microtasks at the end of an outermost `rt.call` while keeping `result`
/// rooted across any GC safepoints triggered by resumed coroutines or reactions (D57).
fn drainTopLevelMicrotasks(rt: *IRuntime, result: internal.Value) internal.runtime.Error!void {
    if (rt.microtask_head >= rt.microtasks.items.len) return;
    var root_buf = [_]internal.Value{result};
    var roots: internal.runtime.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const prev_caller = rt.closure_caller;
    rt.closure_caller = .{ .ctx = rt, .call = internal.Vm.callStandalone, .construct = internal.Vm.constructStandalone };
    defer rt.closure_caller = prev_caller;
    try rt.drainMicrotasks();
}

/// Mints the result token the caller owns (D50). A failed mint faults the call with
/// LimitExceeded(handles) or OutOfMemory; the runtime stays usable (E6), nothing leaks.
fn mintHandle(r: *RuntimeImpl, v: internal.Value, failure: ?*Failure) RunError!Handle {
    return Handle.fromToken(handles.Table.mint(&r.rt, v) catch |e| {
        const fo = faultOf(&r.rt, e);
        if (failure) |out| out.* = fo.failure;
        return fo.err;
    });
}

const HostNativeEntry = struct {
    owner: *RuntimeImpl,
    func: *const NativeFn,
    ctx: ?*anyopaque,
};

fn unreachableNativeCall(_: *IRuntime, _: internal.Value, _: []const internal.Value) internal.runtime.Error!internal.Value {
    unreachable;
}

/// Validates and releases every temporary handle (and `out.result`, if distinct and live)
/// at `NativeFn` teardown. Calling this *after* copying any return value into the caller's
/// stack slot preserves the release-order invariant (D50).
fn releaseNativeTokens(irt: *IRuntime, this_tok: ?handles.Token, arg_handles: []const Handle, res_h: ?Handle) void {
    if (res_h) |rh| {
        const rt_tok = rh.tok();
        _ = handles.Token.checkedValue(irt, rt_tok);
        rt_tok.release();
    }
    for (arg_handles) |ah| {
        const t = ah.tok();
        if (t.isLive()) t.release();
    }
    if (this_tok) |t| if (t.isLive()) t.release();
}

/// Dispatches a call to a host-registered native function (M9.1, D50–D53):
/// - Checks `poisoned` (E7) and `max_call_depth` (D51 #2).
/// - Mints temporary tokens for `this` (object receivers only, D41) and `args` (D50).
/// - Pushes a `NativeRecord` onto `exec_ctx.records` as the guard's engine capability (D52).
/// - Invokes the host's `NativeFn`.
/// - Enforces the latched budget check first (D51, S10), then copies `out.result` before
///   releasing any tokens (the release-order invariant, D50), then releases all temporary
///   and result tokens, pops the `NativeRecord`, and unwinds `call_depth` on every outcome.
fn dispatchHostNative(rt: *IRuntime, raw_ctx: ?*anyopaque, this: ?internal.Value, args: []const internal.Value) internal.runtime.Error!internal.Value {
    if (rt.poisoned) return error.Internal;
    const entry: *const HostNativeEntry = @ptrCast(@alignCast(raw_ctx.?));
    const cx = &rt.exec_ctx;
    if (cx.active) {
        if (cx.call_depth >= rt.limits.max_call_depth) return rt.limit(.call_depth);
    }

    var inline_args: [8]Handle = undefined;
    const arg_handles = if (args.len <= inline_args.len)
        inline_args[0..args.len]
    else
        try rt.gpa.alloc(Handle, args.len);
    defer if (args.len > inline_args.len) rt.gpa.free(arg_handles);
    var minted_args: usize = 0;
    var this_tok: ?handles.Token = null;
    errdefer {
        for (arg_handles[0..minted_args]) |h| {
            const t = h.tok();
            if (t.isLive()) t.release();
        }
        if (this_tok) |t| if (t.isLive()) t.release();
    }

    if (this) |tv| {
        this_tok = try handles.Table.mint(rt, tv);
    }
    for (args, 0..) |av, i| {
        const tok = try handles.Table.mint(rt, av);
        arg_handles[i] = Handle.fromToken(tok);
        minted_args += 1;
    }

    var record: internal.runtime.NativeRecord = .{};
    try cx.pushRecord(rt.gpa, &record);
    if (cx.active) cx.call_depth += 1;
    defer {
        if (cx.active) cx.call_depth -= 1;
        cx.popRecord(&record);
    }

    rt.clearThrown();
    rt.pending_throw_fault = null;
    rt.host_message_len = 0;
    rt.host_message_truncated = false;

    const pub_rt: *Runtime = @ptrCast(entry.owner);
    const this_h: ?Handle = if (this_tok) |t| Handle.fromToken(t) else null;
    var out: NativeOut = .{};
    const call_res = entry.func(pub_rt, entry.ctx, this_h, arg_handles, &out);

    // S10: Check latched budget fault FIRST — a native cannot launder a budget exhaustion
    // into success or another non-Internal error (D51, Q8).
    if (cx.active and cx.budget_fault != null) {
        if (call_res) |_| {} else |err| {
            if (err == error.Internal) {
                releaseNativeTokens(rt, this_tok, arg_handles, out.result);
                return rt.bug("NativeFn returned error.Internal");
            }
        }
        releaseNativeTokens(rt, this_tok, arg_handles, out.result);
        return rt.limit(.steps);
    }

    if (call_res) |_| {
        if (record.threw_js)
            @panic("zqjs: throwJs called without returning error.Thrown");
        rt.clearThrown();
        rt.pending_throw_fault = null;
        // Copy result value BEFORE releasing tokens (release-order invariant, D50).
        const val: internal.Value = if (out.result) |rh| handles.Token.checkedValue(rt, rh.tok()) else .undefined;
        releaseNativeTokens(rt, this_tok, arg_handles, out.result);
        return val;
    } else |err| {
        if (record.threw_js and err != error.Thrown)
            @panic("zqjs: throwJs called without returning error.Thrown");
        releaseNativeTokens(rt, this_tok, arg_handles, out.result);
        switch (err) {
            error.Thrown => {
                if (rt.pending_throw_fault) |f| {
                    rt.pending_throw_fault = null;
                    return f;
                }
                if (rt.exception == null and rt.thrown_value == null)
                    @panic("zqjs: NativeFn returned error.Thrown without calling throwJs");
                return error.Thrown;
            },
            error.HostError => {
                if (out.host_message.len == 0)
                    @panic("zqjs: NativeFn returned error.HostError with an empty host_message");
                var w = TextWriter.init(&rt.host_message_buf, &rt.host_message_len, &rt.host_message_truncated);
                w.utf8(out.host_message);
                return error.HostError;
            },
            error.LimitExceeded => {
                if (rt.limitHit() == null) rt.limit_hit = .steps;
                return error.LimitExceeded;
            },
            error.Unsupported => {
                if (rt.unsupported == null) rt.unsupported = .builtin;
                return error.Unsupported;
            },
            error.OutOfMemory => return error.OutOfMemory,
            error.Internal => return rt.bug("NativeFn returned error.Internal"),
        }
    }
}

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
        error.HostError => error.HostError,
        error.LimitExceeded => error.LimitExceeded,
        error.Unsupported => error.Unsupported,
        error.OutOfMemory => error.OutOfMemory,
        error.Internal => error.Internal,
        error.WriteFailed => error.OutputFailed,
    };
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

/// Allocation-free, getter-free data-property lookup along the prototype chain (D46/E10).
fn lookupDataProp(obj: *const internal.heap.Object, key_ascii: []const u8) ?Value {
    var cur: ?*const internal.heap.Object = obj;
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

fn closureName(cl: *const internal.heap.Closure) ?ThrownName {
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
            const proto: *const Proto = @ptrCast(@alignCast(vm.proto));
            const n = if (proto.name.len > 0) proto.name else proto.inferred_name;
            break :blk if (n.len > 0) .{ .utf8 = n } else null;
        },
        .tree => |tr| blk: {
            const func: *const internal.ast.Function = @ptrCast(@alignCast(tr.func));
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

fn describe(rt: *IRuntime, e: internal.runtime.Error) Failure {
    var f: Failure = .{};
    var w = TextWriter.init(&f.text, &f.text_len, &f.truncated);
    switch (e) {
        error.Thrown => {
            f.kind = .thrown;
            if (rt.thrown_value) |v| {
                w.utf8("Uncaught ");
                if (extractThrownError(v)) |info| {
                    switch (info.name) {
                        .utf16 => |u| w.utf16(u),
                        .utf8 => |s| w.utf8(s),
                    }
                    if (info.message) |m| {
                        if (m.len > 0) {
                            w.utf8(": ");
                            w.utf16(m);
                        }
                    }
                } else {
                    var buf: internal.ops.NumberBuf = undefined;
                    if (internal.ops.toPiece(rt, v, &buf)) |piece| switch (piece) {
                        .ascii => |a| w.utf8(a),
                        .utf16 => |u| w.utf16(u),
                    } else |_| w.utf8("[value]");
                }
            } else {
                const ex = rt.exception.?;
                w.utf8(@tagName(ex.name));
                w.utf8(": ");
                w.utf16(ex.message.units);
            }
        },
        error.HostError => {
            f.kind = .host;
            @memcpy(f.text[0..rt.host_message_len], rt.host_message_buf[0..rt.host_message_len]);
            f.text_len = rt.host_message_len;
            f.truncated = rt.host_message_truncated;
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
