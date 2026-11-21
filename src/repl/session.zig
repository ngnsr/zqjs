//! Interactive REPL Session: persistent top-level bindings (`ReplEnv`), `Proto` pool,
//! top-level `await` & `for await`, input ergonomics, dot-commands, and REPL loop (D71).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Limits = @import("../limits.zig").Limits;
const Diagnostic = @import("../frontend/diag.zig").Diagnostic;
const ast = @import("../frontend/ast.zig");
const parser = @import("../frontend/parser.zig");
const resolver = @import("../frontend/resolver.zig");
const Resolution = resolver.Resolution;
const dump = @import("../frontend/dump.zig");
const compiler = @import("../bytecode/compiler.zig");
const Proto = @import("../bytecode/bytecode.zig").Proto;
const verify = @import("../bytecode/verify.zig");
const disasm = @import("../bytecode/disasm.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const RuntimeError = @import("../runtime/runtime.zig").Error;
const Value = @import("../runtime/value.zig").Value;
const heap = @import("../runtime/heap.zig");
const ops = @import("../runtime/ops.zig");
const builtins = @import("../runtime/builtins.zig");
const Vm = @import("../vm/vm.zig").Vm;
const machine = @import("../interp/machine.zig");
const Engine = @import("../run.zig").Engine;
const inspect = @import("inspect.zig");
const complete = @import("complete.zig");
const editor = @import("editor.zig");

pub const ReplEntry = struct {
    name: []const u8,
    cell: *heap.Cell,
    kind: resolver.ReplKind,
};

pub const SessionOptions = struct {
    limits: Limits = .{},
    engine: Engine = .vm,
    trace: bool = false,
    verify_heap: bool = false,
    color: bool = false,
    io: ?std.Io = null,
    history_path: ?[]const u8 = null,
};

pub const EvalOutcome = union(enum) {
    value: Value,
    /// Uncaught JS exception (already printed to `err` by `eval`, `_error` updated).
    thrown,
    /// Frontend or runtime error (already printed to `err` by `eval`).
    failed,
    /// Empty or whitespace-only input.
    empty,
};

pub const Session = struct {
    gpa: Allocator,
    rt: Runtime,
    out: *Writer,
    err: *Writer,
    engine: Engine,
    trace: bool,
    color: bool,
    io: ?std.Io,
    history_path: ?[]const u8,

    /// Persistent top-level bindings (`name -> { cell, kind }`), strongly rooted.
    repl_env: std.StringHashMapUnmanaged(ReplEntry) = .empty,
    /// Heap-allocated Protos so pointers never relocate when the list grows.
    protos: std.ArrayList(*Proto) = .empty,
    /// Per-chunk `[]*heap.Cell` slices borrowed by Protos and tree closures.
    repl_cell_slices: std.ArrayList([]*heap.Cell) = .empty,
    /// Frontend arenas & resolutions kept alive for `--engine=treewalk` closures.
    tree_arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
    tree_resolutions: std.ArrayList(*Resolution) = .empty,
    /// Source strings kept alive for tree-walker AST name slices.
    tree_sources: std.ArrayList([]const u8) = .empty,
    /// Successfully evaluated source snippets (for `.save`).
    session_lines: std.ArrayList([]const u8) = .empty,

    pub fn create(gpa: Allocator, out: *Writer, err: *Writer, options: SessionOptions) !*Session {
        const s = try gpa.create(Session);
        errdefer gpa.destroy(s);

        s.* = .{
            .gpa = gpa,
            .rt = Runtime.init(gpa, options.limits, out),
            .out = out,
            .err = err,
            .engine = options.engine,
            .trace = options.trace,
            .color = options.color,
            .io = options.io,
            .history_path = options.history_path,
        };
        errdefer s.rt.deinit();

        s.rt.stack_base = @frameAddress();
        s.rt.heap.verify_always = options.verify_heap or s.rt.heap.verify_always;

        try s.rt.addRoots(.{ .ctx = s, .mark = markRoots });
        // Initialize realm eagerly so Tab completion works on line 1.
        _ = try builtins.realm(&s.rt);
        try s.initSpecialBindings();
        return s;
    }

    pub fn destroy(s: *Session) void {
        s.rt.removeRoots(s);
        var it = s.repl_env.valueIterator();
        while (it.next()) |e| s.gpa.free(e.name);
        s.repl_env.deinit(s.gpa);

        for (s.protos.items) |p| {
            p.deinit(s.gpa);
            s.gpa.destroy(p);
        }
        s.protos.deinit(s.gpa);

        for (s.repl_cell_slices.items) |sl| s.gpa.free(sl);
        s.repl_cell_slices.deinit(s.gpa);

        for (s.tree_arenas.items) |a| {
            a.deinit();
            s.gpa.destroy(a);
        }
        s.tree_arenas.deinit(s.gpa);

        for (s.tree_resolutions.items) |r| s.gpa.destroy(r);
        s.tree_resolutions.deinit(s.gpa);

        for (s.tree_sources.items) |src| s.gpa.free(src);
        s.tree_sources.deinit(s.gpa);

        for (s.session_lines.items) |line| s.gpa.free(line);
        s.session_lines.deinit(s.gpa);

        s.rt.deinit();
        s.gpa.destroy(s);
    }

    fn initSpecialBindings(s: *Session) !void {
        try s.setSpecialCell("_", .undefined);
        try s.setSpecialCell("_error", .undefined);
    }

    fn setSpecialCell(s: *Session, name: []const u8, val: Value) !void {
        if (s.repl_env.getPtr(name)) |entry| {
            s.rt.heap.storeCell(entry.cell, val);
            return;
        }
        const cell = try s.rt.heap.newCell(val);
        const duped = try s.gpa.dupe(u8, name);
        errdefer s.gpa.free(duped);
        try s.repl_env.put(s.gpa, duped, .{ .name = duped, .cell = cell, .kind = .let });
    }

    fn markRoots(ctx: *anyopaque, h: *heap.Heap) void {
        const s: *Session = @ptrCast(@alignCast(ctx));
        var it = s.repl_env.valueIterator();
        while (it.next()) |e| {
            h.markObj(&e.cell.obj);
        }
        for (s.protos.items) |p| {
            markProto(p, h);
        }
    }

    fn markProto(p: *const Proto, h: *heap.Heap) void {
        for (p.consts) |c| h.markValue(c);
        for (p.name_atoms) |a| h.markObj(@constCast(&a.obj));
        for (p.repl_cells) |cell| h.markObj(&cell.obj);
        for (p.functions) |*child| markProto(child, h);
    }

    fn setProtoReplCells(p: *Proto, cells: []*heap.Cell) void {
        p.repl_cells = cells;
        for (p.functions) |*child| setProtoReplCells(child, cells);
    }

    pub fn replLookup(s: *const Session) resolver.ReplLookup {
        return .{
            .ctx = s,
            .get = struct {
                fn call(ctx: *const anyopaque, name: []const u8) ?resolver.ReplKind {
                    const self: *const Session = @ptrCast(@alignCast(ctx));
                    const entry = self.repl_env.get(name) orelse return null;
                    return entry.kind;
                }
            }.call,
        };
    }

    pub fn completionLookup(s: *const Session) complete.ReplBindingLookup {
        return .{
            .ctx = s,
            .get = struct {
                fn call(ctx: *const anyopaque, name: []const u8) ?Value {
                    const self: *const Session = @ptrCast(@alignCast(ctx));
                    const entry = self.repl_env.get(name) orelse return null;
                    return entry.cell.value;
                }
            }.call,
            .list = struct {
                fn call(ctx: *const anyopaque, gpa: Allocator, out: *std.ArrayList([]const u8)) Allocator.Error!void {
                    const self: *const Session = @ptrCast(@alignCast(ctx));
                    var it = self.repl_env.keyIterator();
                    while (it.next()) |k| {
                        try out.append(gpa, k.*);
                    }
                }
            }.call,
        };
    }

    /// Evaluates one REPL chunk (with object-literal & ASI heuristics, persistent bindings,
    /// top-level await, and transactional error recovery).
    pub fn eval(s: *Session, raw_source: []const u8) !EvalOutcome {
        const trimmed = std.mem.trim(u8, raw_source, " \t\r\n");
        if (trimmed.len == 0) return .empty;

        // Per-line step budget reset so --max-steps doesn't permanently exhaust the session.
        s.rt.steps = 0;
        s.rt.limit_hit = null;
        s.rt.repl_result = .undefined;
        s.rt.clearThrown();

        // Keep source alive if treewalk may create closures referencing source slices.
        const owned_source = try s.gpa.dupe(u8, trimmed);
        var keep_source = false;
        defer if (!keep_source) s.gpa.free(owned_source);

        const arena = try s.gpa.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(s.gpa);
        var keep_arena = false;
        defer if (!keep_arena) {
            arena.deinit();
            s.gpa.destroy(arena);
        };

        var diag: Diagnostic = .{};
        const parse_res = try s.parseWithHeuristics(arena.allocator(), owned_source, &diag);
        const eff_source = parse_res.source;
        const script = parse_res.script orelse {
            try diag.render(eff_source, "<repl>", s.err);
            try s.err.flush();
            return .failed;
        };

        const res = resolver.resolveWithRepl(arena.allocator(), script, s.replLookup(), &diag) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            try diag.render(eff_source, "<repl>", s.err);
            try s.err.flush();
            return .failed;
        };

        const is_tla = script.has_top_level_await;

        // Prepare cells for REPL bindings & transactional undo log.
        const UndoEntry = struct {
            name: []const u8,
            new_cell: *heap.Cell,
            prev: ?ReplEntry,
            owned_new_name: ?[]const u8,
        };
        var undo: std.ArrayList(UndoEntry) = .empty;
        defer undo.deinit(s.gpa);

        const cells = try s.gpa.alloc(*heap.Cell, res.repl_bindings.len);
        var keep_cells = false;
        defer if (!keep_cells) s.gpa.free(cells);

        if (s.engine == .vm) {
            const proto_ptr = try s.gpa.create(Proto);
            var keep_proto = false;
            defer if (!keep_proto) s.gpa.destroy(proto_ptr);

            proto_ptr.* = compiler.compileWithOptions(
                s.gpa,
                &s.rt.heap,
                script,
                res,
                s.rt.limits,
                .{ .repl = true, .top_level_await = is_tla },
                &diag,
            ) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LimitExceeded => {
                    try diag.render(eff_source, "<repl>", s.err);
                    try s.err.flush();
                    return .failed;
                },
            };
            var deinit_proto = true;
            defer if (deinit_proto) proto_ptr.deinit(s.gpa);

            var vfail: verify.Failure = .{};
            _ = verify.verify(s.gpa, proto_ptr, s.rt.limits, &vfail) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidBytecode => {
                    try s.err.print("<repl>: internal error: invalid bytecode at {d}: {s}\n", .{ vfail.pc, vfail.reason });
                    try s.err.flush();
                    return .failed;
                },
            };

            // Now bind ReplEnv entries transactionally after parse/resolve/compile/verify all succeeded.
            try s.applyReplBindings(res.repl_bindings, cells, &undo);
            setProtoReplCells(proto_ptr, cells);

            try s.protos.append(s.gpa, proto_ptr);
            keep_proto = true;
            deinit_proto = false;

            try s.repl_cell_slices.append(s.gpa, cells);
            keep_cells = true;

            if (is_tla) {
                const promise_val = Vm.startTopLevelAsync(&s.rt, proto_ptr) catch |e| {
                    try s.rollbackTdz(&undo);
                    return try s.reportRuntimeError(e);
                };
                return try s.finishTopLevelAwait(promise_val, &undo, trimmed);
            } else {
                var vm = Vm.init(&s.rt, proto_ptr) catch |e| {
                    try s.rollbackTdz(&undo);
                    return try s.reportRuntimeError(e);
                };
                defer vm.deinit();
                const run_res = if (s.trace) runTraced(&vm, s.err) else vm.run();
                run_res catch |e| {
                    try s.rollbackTdz(&undo);
                    return try s.reportRuntimeError(e);
                };
                s.rt.drainMicrotasks() catch |e| {
                    try s.rollbackTdz(&undo);
                    return try s.reportRuntimeError(e);
                };
                try s.setSpecialCell("_", s.rt.repl_result);
                try s.recordSessionLine(trimmed);
                return .{ .value = s.rt.repl_result };
            }
        } else {
            // Tree-walker engine
            try s.applyReplBindings(res.repl_bindings, cells, &undo);
            const res_ptr = try s.gpa.create(Resolution);
            res_ptr.* = res;

            try s.tree_arenas.append(s.gpa, arena);
            keep_arena = true;
            try s.tree_resolutions.append(s.gpa, res_ptr);
            if (eff_source.ptr == owned_source.ptr) {
                try s.tree_sources.append(s.gpa, owned_source);
                keep_source = true;
            } else {
                try s.tree_sources.append(s.gpa, try s.gpa.dupe(u8, eff_source));
            }
            try s.repl_cell_slices.append(s.gpa, cells);
            keep_cells = true;

            if (is_tla) {
                const promise_val = machine.runReplTopLevelAsync(&s.rt, script, res_ptr, cells) catch |e| {
                    try s.rollbackTdz(&undo);
                    return try s.reportRuntimeError(e);
                };
                return try s.finishTopLevelAwait(promise_val, &undo, trimmed);
            } else {
                machine.runRepl(&s.rt, script, res_ptr, cells) catch |e| {
                    try s.rollbackTdz(&undo);
                    return try s.reportRuntimeError(e);
                };
                try s.setSpecialCell("_", s.rt.repl_result);
                try s.recordSessionLine(trimmed);
                return .{ .value = s.rt.repl_result };
            }
        }
    }

    fn finishTopLevelAwait(s: *Session, promise_val: Value, undo: anytype, trimmed: []const u8) !EvalOutcome {
        s.rt.drainMicrotasks() catch |e| {
            try s.rollbackTdz(undo);
            return try s.reportRuntimeError(e);
        };
        const p_obj = promise_val.asObject();
        const ps = p_obj.kind.promise;
        switch (ps.state) {
            .fulfilled => {
                try s.setSpecialCell("_", ps.result);
                try s.recordSessionLine(trimmed);
                return .{ .value = ps.result };
            },
            .rejected => {
                try s.rollbackTdz(undo);
                try s.setSpecialCell("_error", ps.result);
                try s.err.writeAll("Uncaught ");
                try inspect.inspect(&s.rt, ps.result, s.err, .{ .color = s.color });
                try s.err.writeByte('\n');
                try s.err.flush();
                return .thrown;
            },
            .pending => {
                try s.recordSessionLine(trimmed);
                return .{ .value = promise_val };
            },
        }
    }

    fn applyReplBindings(
        s: *Session,
        bindings: []const resolver.ReplBinding,
        cells: []*heap.Cell,
        undo: anytype,
    ) !void {
        for (bindings, 0..) |rb, i| {
            if (rb.is_decl) {
                const cell = try s.rt.heap.newCell(null);
                cells[i] = cell;
                if (s.repl_env.getPtr(rb.name)) |existing| {
                    try undo.append(s.gpa, .{
                        .name = existing.name,
                        .new_cell = cell,
                        .prev = existing.*,
                        .owned_new_name = null,
                    });
                    existing.cell = cell;
                    existing.kind = rb.kind;
                } else {
                    const duped = try s.gpa.dupe(u8, rb.name);
                    errdefer s.gpa.free(duped);
                    try s.repl_env.put(s.gpa, duped, .{ .name = duped, .cell = cell, .kind = rb.kind });
                    try undo.append(s.gpa, .{
                        .name = duped,
                        .new_cell = cell,
                        .prev = null,
                        .owned_new_name = duped,
                    });
                }
            } else {
                const existing = s.repl_env.get(rb.name) orelse unreachable;
                cells[i] = existing.cell;
            }
        }
    }

    fn rollbackTdz(s: *Session, undo: anytype) !void {
        var i = undo.items.len;
        while (i > 0) {
            i -= 1;
            const u = undo.items[i];
            if (u.new_cell.value != null) continue;
            if (u.prev) |prev_entry| {
                if (s.repl_env.getPtr(u.name)) |ptr| {
                    ptr.* = prev_entry;
                }
            } else {
                _ = s.repl_env.remove(u.name);
                if (u.owned_new_name) |n| s.gpa.free(n);
            }
        }
    }

    fn recordSessionLine(s: *Session, line: []const u8) !void {
        try s.session_lines.append(s.gpa, try s.gpa.dupe(u8, line));
    }

    const ParseHeuristicResult = struct {
        source: []const u8,
        script: ?ast.Script,
    };

    fn parseWithHeuristics(s: *Session, arena: Allocator, source: []const u8, diag: *Diagnostic) !ParseHeuristicResult {
        const parse_opts: parser.ParseOptions = .{ .allow_top_level_await = true };

        // 1. Object literal heuristic: `{ ... }` -> try `({ ... });` first, fall back on SyntaxError.
        if (source.len >= 2 and source[0] == '{' and source[source.len - 1] == '}') {
            const wrapped = try std.fmt.allocPrint(arena, "({s});", .{source});
            var wrap_diag: Diagnostic = .{};
            if (parser.parseWithOptions(arena, wrapped, s.rt.limits, parse_opts, &wrap_diag)) |sc| {
                return .{ .source = wrapped, .script = sc };
            } else |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                if (e != error.SyntaxError) {
                    diag.* = wrap_diag;
                    return .{ .source = wrapped, .script = null };
                }
                // Fall through to normal block parsing.
            }
        }

        // 2. Normal parse.
        if (parser.parseWithOptions(arena, source, s.rt.limits, parse_opts, diag)) |sc| {
            return .{ .source = source, .script = sc };
        } else |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            // 3. Missing trailing semicolon heuristic: Unsupported(asi) at EOF -> retry with `;`.
            if (e == error.Unsupported and diag.detail == .unsupported and diag.detail.unsupported == .asi and diag.start >= source.len) {
                const with_semi = try std.fmt.allocPrint(arena, "{s};", .{source});
                var semi_diag: Diagnostic = .{};
                if (parser.parseWithOptions(arena, with_semi, s.rt.limits, parse_opts, &semi_diag)) |sc2| {
                    return .{ .source = with_semi, .script = sc2 };
                } else |e2| {
                    if (e2 == error.OutOfMemory) return error.OutOfMemory;
                    diag.* = semi_diag;
                    return .{ .source = with_semi, .script = null };
                }
            }
            return .{ .source = source, .script = null };
        }
    }

    fn reportRuntimeError(s: *Session, e: RuntimeError) !EvalOutcome {
        switch (e) {
            error.OutOfMemory, error.WriteFailed => |host| return host,
            error.Internal => {
                try s.err.print("<repl>: internal error: {s}\n", .{s.rt.internal_reason orelse "unknown"});
                try s.err.flush();
                return .failed;
            },
            error.Thrown => {
                const err_val = s.rt.catchValue() catch |ce| {
                    if (ce == error.OutOfMemory) return error.OutOfMemory;
                    try s.err.writeAll("Uncaught error\n");
                    try s.err.flush();
                    return .thrown;
                };
                try s.setSpecialCell("_error", err_val);
                try s.err.writeAll("Uncaught ");
                try inspect.inspect(&s.rt, err_val, s.err, .{ .color = s.color });
                try s.err.writeByte('\n');
                try s.err.flush();
                return .thrown;
            },
            error.HostError => {
                try s.err.print("<repl>: {s}\n", .{s.rt.host_message_buf[0..s.rt.host_message_len]});
                try s.err.flush();
                return .failed;
            },
            error.LimitExceeded => {
                try s.err.print("<repl>: LimitExceeded({s})\n", .{@tagName(s.rt.limitHit().?)});
                try s.err.flush();
                return .failed;
            },
            error.Unsupported => {
                try s.err.print("<repl>: Unsupported({s}): {s}", .{ @tagName(s.rt.unsupported.?), s.rt.unsupported.?.description() });
                if (s.rt.unsupported_name) |n| {
                    try s.err.writeAll(" ('");
                    try ops.writeUtf16(s.err, n.units);
                    try s.err.writeAll("')");
                }
                try s.err.writeByte('\n');
                try s.err.flush();
                return .failed;
            },
        }
    }

    pub const DotCommandOutcome = enum {
        handled,
        exit,
        clear_buffer,
        enter_editor,
        not_a_command,
    };

    /// Executes a REPL dot-command (e.g. `.help`, `.gc`, `.bc <src>`).
    pub fn runDotCommand(s: *Session, line: []const u8) !DotCommandOutcome {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, ".")) return .not_a_command;

        const space_idx = std.mem.indexOfAny(u8, trimmed, " \t");
        const cmd = if (space_idx) |idx| trimmed[0..idx] else trimmed;
        const arg = if (space_idx) |idx| std.mem.trim(u8, trimmed[idx + 1 ..], " \t") else "";

        if (std.mem.eql(u8, cmd, ".help")) {
            try s.out.writeAll(
                \\.help              Show this help message
                \\.exit              Exit the REPL
                \\.clear             Reset session bindings (_ and _error preserved as undefined)
                \\.break             Abort current multi-line input
                \\.editor            Enter multi-line editor mode (Ctrl-D to run, Ctrl-C to cancel)
                \\.load <path>       Load and evaluate a JS file in the current session
                \\.save <path>       Save evaluated session lines to a file
                \\.ast <src>         Print resolved AST for <src>
                \\.bc <src>          Print verified bytecode disassembly for <src>
                \\.trace [on|off]    Toggle or set VM instruction tracing
                \\.gc                Force a garbage collection and print heap stats
                \\.mem               Print heap memory statistics
                \\.engine [vm|treewalk] Show or switch active execution engine
                \\.limits            Print active runtime limits
                \\
            );
            try s.out.flush();
            return .handled;
        } else if (std.mem.eql(u8, cmd, ".exit")) {
            return .exit;
        } else if (std.mem.eql(u8, cmd, ".break")) {
            return .clear_buffer;
        } else if (std.mem.eql(u8, cmd, ".editor")) {
            return .enter_editor;
        } else if (std.mem.eql(u8, cmd, ".clear")) {
            var it = s.repl_env.valueIterator();
            while (it.next()) |e| s.gpa.free(e.name);
            s.repl_env.clearRetainingCapacity();
            try s.initSpecialBindings();
            s.rt.repl_result = .undefined;
            try s.out.writeAll("Clearing context...\n");
            try s.out.flush();
            return .handled;
        } else if (std.mem.eql(u8, cmd, ".gc")) {
            const before = s.rt.heap.bytes;
            s.rt.collect();
            const after = s.rt.heap.bytes;
            try s.out.print("GC: {d} -> {d} bytes (freed {d})\n", .{ before, after, before -| after });
            try s.out.flush();
            return .handled;
        } else if (std.mem.eql(u8, cmd, ".mem")) {
            try s.out.print("heap: {d} bytes (peak {d}, total allocated {d}, max {d})\n", .{
                s.rt.heap.bytes,
                s.rt.heap.peak,
                s.rt.heap.allocated,
                s.rt.heap.max_bytes,
            });
            try s.out.flush();
            return .handled;
        } else if (std.mem.eql(u8, cmd, ".limits")) {
            const l = s.rt.limits;
            try s.out.print("max_steps={d} max_heap_bytes={d} max_call_depth={d} max_stack_slots={d} max_source_bytes={d}\n", .{
                l.max_steps,
                l.max_heap_bytes,
                l.max_call_depth,
                l.max_stack_slots,
                l.max_source_bytes,
            });
            try s.out.flush();
            return .handled;
        } else if (std.mem.eql(u8, cmd, ".trace")) {
            if (std.mem.eql(u8, arg, "on")) {
                s.trace = true;
            } else if (std.mem.eql(u8, arg, "off")) {
                s.trace = false;
            } else if (arg.len == 0) {
                s.trace = !s.trace;
            } else {
                try s.err.writeAll("usage: .trace [on|off]\n");
                try s.err.flush();
                return .handled;
            }
            try s.out.print("trace: {s}\n", .{if (s.trace) "on" else "off"});
            try s.out.flush();
            return .handled;
        } else if (std.mem.eql(u8, cmd, ".engine")) {
            if (arg.len == 0) {
                try s.out.print("engine: {s}\n", .{@tagName(s.engine)});
                try s.out.flush();
                return .handled;
            }
            if (std.meta.stringToEnum(Engine, arg)) |eng| {
                s.engine = eng;
                try s.out.print("engine: {s}\n", .{@tagName(s.engine)});
                try s.out.flush();
            } else {
                try s.err.writeAll("usage: .engine [vm|treewalk]\n");
                try s.err.flush();
            }
            return .handled;
        } else if (std.mem.eql(u8, cmd, ".ast")) {
            if (arg.len == 0) {
                try s.err.writeAll("usage: .ast <source>\n");
                try s.err.flush();
                return .handled;
            }
            var arena = std.heap.ArenaAllocator.init(s.gpa);
            defer arena.deinit();
            var diag: Diagnostic = .{};
            const parse_res = try s.parseWithHeuristics(arena.allocator(), arg, &diag);
            const script = parse_res.script orelse {
                try diag.render(parse_res.source, "<repl>", s.err);
                try s.err.flush();
                return .handled;
            };
            const res = resolver.resolveWithRepl(arena.allocator(), script, s.replLookup(), &diag) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                try diag.render(parse_res.source, "<repl>", s.err);
                try s.err.flush();
                return .handled;
            };
            try dump.script(script, res, s.out);
            try s.out.flush();
            return .handled;
        } else if (std.mem.eql(u8, cmd, ".bc")) {
            if (arg.len == 0) {
                try s.err.writeAll("usage: .bc <source>\n");
                try s.err.flush();
                return .handled;
            }
            var arena = std.heap.ArenaAllocator.init(s.gpa);
            defer arena.deinit();
            var diag: Diagnostic = .{};
            const parse_res = try s.parseWithHeuristics(arena.allocator(), arg, &diag);
            const script = parse_res.script orelse {
                try diag.render(parse_res.source, "<repl>", s.err);
                try s.err.flush();
                return .handled;
            };
            const res = resolver.resolveWithRepl(arena.allocator(), script, s.replLookup(), &diag) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                try diag.render(parse_res.source, "<repl>", s.err);
                try s.err.flush();
                return .handled;
            };
            var proto = compiler.compileWithOptions(
                s.gpa,
                &s.rt.heap,
                script,
                res,
                s.rt.limits,
                .{ .repl = true, .top_level_await = script.has_top_level_await },
                &diag,
            ) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.LimitExceeded => {
                    try diag.render(parse_res.source, "<repl>", s.err);
                    try s.err.flush();
                    return .handled;
                },
            };
            defer proto.deinit(s.gpa);
            var vfail: verify.Failure = .{};
            _ = verify.verify(s.gpa, &proto, s.rt.limits, &vfail) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidBytecode => {
                    try s.err.print("<repl>: internal error: invalid bytecode at {d}: {s}\n", .{ vfail.pc, vfail.reason });
                    try s.err.flush();
                    return .handled;
                },
            };
            try disasm.disassemble(proto, s.out);
            try s.out.flush();
            return .handled;
        } else if (std.mem.eql(u8, cmd, ".load")) {
            if (arg.len == 0) {
                try s.err.writeAll("usage: .load <path>\n");
                try s.err.flush();
                return .handled;
            }
            const io = s.io orelse {
                try s.err.writeAll(".load: no IO context available\n");
                try s.err.flush();
                return .handled;
            };
            const data = std.Io.Dir.cwd().readFileAlloc(io, arg, s.gpa, .limited(s.rt.limits.max_source_bytes + 1)) catch |e| {
                try s.err.print(".load {s}: {s}\n", .{ arg, @errorName(e) });
                try s.err.flush();
                return .handled;
            };
            defer s.gpa.free(data);
            switch (try s.eval(data)) {
                .value => |v| {
                    try inspect.inspect(&s.rt, v, s.out, .{ .color = s.color });
                    try s.out.writeByte('\n');
                    try s.out.flush();
                },
                .thrown, .failed, .empty => {},
            }
            return .handled;
        } else if (std.mem.eql(u8, cmd, ".save")) {
            if (arg.len == 0) {
                try s.err.writeAll("usage: .save <path>\n");
                try s.err.flush();
                return .handled;
            }
            const io = s.io orelse {
                try s.err.writeAll(".save: no IO context available\n");
                try s.err.flush();
                return .handled;
            };
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(s.gpa);
            for (s.session_lines.items) |sl| {
                try buf.appendSlice(s.gpa, sl);
                try buf.append(s.gpa, '\n');
            }
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = arg, .data = buf.items }) catch |e| {
                try s.err.print(".save {s}: {s}\n", .{ arg, @errorName(e) });
                try s.err.flush();
                return .handled;
            };
            try s.out.print("Session saved to {s}\n", .{arg});
            try s.out.flush();
            return .handled;
        }

        try s.err.print("Unknown REPL command: {s} (type .help for commands)\n", .{cmd});
        try s.err.flush();
        return .handled;
    }

    /// Runs the interactive (or piped) REPL loop until `.exit` or EOF.
    pub fn runLoop(s: *Session) !u8 {
        const is_tty = editor.LineEditor.isTty();
        var ed = editor.LineEditor.init(s.gpa, .{
            .color = s.color,
            .history_path = s.history_path,
            .io = s.io,
            .complete_ctx = s,
            .complete_fn = struct {
                fn call(ctx: *anyopaque, line: []const u8, cursor: usize, gpa: Allocator) Allocator.Error!complete.CompletionResult {
                    const self: *Session = @ptrCast(@alignCast(ctx));
                    return complete.complete(gpa, line, cursor, &self.rt, self.completionLookup());
                }
            }.call,
            .highlight_fn = complete.highlight,
        });
        defer {
            ed.saveHistory();
            ed.deinit();
        }
        ed.loadHistory();

        if (is_tty) {
            try s.out.writeAll("Welcome to zqjs REPL. Type .help for more information.\n");
            try s.out.flush();
        }

        var accum: std.ArrayList(u8) = .empty;
        defer accum.deinit(s.gpa);

        while (true) {
            const prompt = if (accum.items.len == 0) "zqjs> " else "...   ";
            const res = try ed.readLine(prompt, s.out);
            switch (res) {
                .eof => {
                    if (accum.items.len > 0) {
                        accum.clearRetainingCapacity();
                        continue;
                    }
                    break;
                },
                .interrupt => {
                    accum.clearRetainingCapacity();
                    continue;
                },
                .line => |line| {
                    if (accum.items.len == 0) {
                        switch (try s.runDotCommand(line)) {
                            .exit => break,
                            .clear_buffer => {
                                accum.clearRetainingCapacity();
                                continue;
                            },
                            .enter_editor => {
                                try s.runEditorMode(&ed);
                                continue;
                            },
                            .handled => continue,
                            .not_a_command => {},
                        }
                    } else {
                        const t = std.mem.trim(u8, line, " \t\r\n");
                        if (std.mem.eql(u8, t, ".break")) {
                            accum.clearRetainingCapacity();
                            continue;
                        }
                    }

                    if (accum.items.len > 0) try accum.append(s.gpa, '\n');
                    try accum.appendSlice(s.gpa, line);

                    if (is_tty and !complete.isComplete(accum.items)) {
                        continue;
                    }

                    // For piped non-TTY input, wait until complete if EOF hasn't arrived yet.
                    if (!is_tty and !complete.isComplete(accum.items)) {
                        continue;
                    }

                    const src = accum.items;
                    if (std.mem.trim(u8, src, " \t\r\n").len > 0) {
                        try ed.addHistory(src);
                    }
                    switch (try s.eval(src)) {
                        .value => |v| {
                            try inspect.inspect(&s.rt, v, s.out, .{ .color = s.color });
                            try s.out.writeByte('\n');
                            try s.out.flush();
                        },
                        .thrown, .failed, .empty => {},
                    }
                    accum.clearRetainingCapacity();
                },
            }
        }

        // If piped input ended with an incomplete buffer, evaluate it anyway so syntax errors are reported.
        if (accum.items.len > 0) {
            switch (try s.eval(accum.items)) {
                .value => |v| {
                    try inspect.inspect(&s.rt, v, s.out, .{ .color = s.color });
                    try s.out.writeByte('\n');
                    try s.out.flush();
                },
                .thrown, .failed, .empty => {},
            }
        }

        return 0;
    }

    fn runEditorMode(s: *Session, ed: *editor.LineEditor) !void {
        try s.out.writeAll("// Entering editor mode (Ctrl-D to finish, Ctrl-C to cancel)\n");
        try s.out.flush();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(s.gpa);

        while (true) {
            const res = try ed.readLine("", s.out);
            switch (res) {
                .eof => break,
                .interrupt => {
                    buf.clearRetainingCapacity();
                    return;
                },
                .line => |line| {
                    if (buf.items.len > 0) try buf.append(s.gpa, '\n');
                    try buf.appendSlice(s.gpa, line);
                },
            }
        }
        if (std.mem.trim(u8, buf.items, " \t\r\n").len == 0) return;
        try ed.addHistory(buf.items);
        switch (try s.eval(buf.items)) {
            .value => |v| {
                try inspect.inspect(&s.rt, v, s.out, .{ .color = s.color });
                try s.out.writeByte('\n');
                try s.out.flush();
            },
            .thrown, .failed, .empty => {},
        }
    }
};

fn runTraced(vm: *Vm, t: *Writer) RuntimeError!void {
    while (true) {
        if (!vm.halted) {
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
