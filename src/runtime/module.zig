//! ES Modules: Host Module Loader, Module Registry, Linking & Evaluation (M42, D72).
//!
//! Lifecycle:
//!   1. Load & Parse (DFS from entry, deduplicated by `canonical_id`, bounded by `Limits.max_modules`)
//!   2. Link (resolve imports/re-exports, detect missing/ambiguous exports, allocate `heap.Cell`s,
//!      hoist top-level function declarations, materialize namespace exotic objects)
//!   3. Evaluate (DFS post-order, at most once per Runtime, caching completion/error)

const std = @import("std");
const Allocator = std.mem.Allocator;
const ast = @import("../frontend/ast.zig");
const parser = @import("../frontend/parser.zig");
const resolver = @import("../frontend/resolver.zig");
const Resolution = resolver.Resolution;
const Diagnostic = @import("../frontend/diag.zig").Diagnostic;
const compiler = @import("../bytecode/compiler.zig");
const Proto = @import("../bytecode/bytecode.zig").Proto;
const verify = @import("../bytecode/verify.zig");
const heap = @import("heap.zig");
const Value = @import("value.zig").Value;
const builtins = @import("builtins.zig");
const ops = @import("ops.zig");
const rt_mod = @import("runtime.zig");
const Runtime = rt_mod.Runtime;
const RuntimeError = rt_mod.Error;
const ValueRoots = rt_mod.ValueRoots;
const Vm = @import("../vm/vm.zig").Vm;
const machine = @import("../interp/machine.zig");
const Engine = @import("../run.zig").Engine;

pub const LoadError = error{ ModuleNotFound, HostError, OutOfMemory };

pub const LoadedModule = struct {
    canonical_id: []const u8,
    source: []const u8,
    free: ?*const fn (ctx: ?*anyopaque, canonical_id: []const u8, source: []const u8) void = null,
};

pub const ModuleLoader = struct {
    ctx: ?*anyopaque = null,
    load: *const fn (ctx: ?*anyopaque, referrer_id: ?[]const u8, specifier: []const u8) LoadError!LoadedModule,
};

pub const ModuleDiag = struct {
    diag: Diagnostic = .{},
    source: []const u8 = "",
    name: []const u8 = "",
    host_message: []const u8 = "",
};

pub const ModuleError = error{
    SyntaxError,
    Unsupported,
    LimitExceeded,
    ModuleNotFound,
    HostError,
    OutOfMemory,
    InvalidBytecode,
};

pub const Status = enum {
    unlinked,
    linking,
    linked,
    evaluating,
    evaluating_async,
    evaluated,
    errored,
};

const ImportLink = struct {
    repl_idx: u32,
    dep: *ModuleRecord,
    /// `null` means `import * as ns` (namespace object).
    imported_name: ?[]const u8,
    span: ast.Span,
};

const IndirectExport = struct {
    dep: *ModuleRecord,
    /// `null` means `export * as ns` / re-exported namespace binding (`~all~`).
    imported_name: ?[]const u8,
    span: ast.Span,
};

pub const AsyncEvalOrder = union(enum) {
    unset,
    evaluating: u64,
    done,
};

pub const ModuleRecord = struct {
    canonical_id: []const u8,
    source: []const u8,
    arena: *std.heap.ArenaAllocator,
    script: ast.Script,
    res: Resolution,
    proto: ?*Proto = null,
    cells: []*heap.Cell = &.{},
    namespace: ?*heap.Object = null,
    namespace_cell: ?*heap.Cell = null,
    import_meta: ?*heap.Object = null,
    status: Status = .unlinked,
    eval_error: ?Value = null,
    eval_fault: ?RuntimeError = null,

    has_tla: bool = false,
    async_eval_order: AsyncEvalOrder = .unset,
    proto_promoted: bool = false,
    pending_async_deps: u32 = 0,
    async_parents: std.ArrayList(*ModuleRecord) = .empty,
    eval_promise: ?*heap.Object = null,
    dfs_index: u32 = 0,
    dfs_ancestor_index: u32 = 0,
    cycle_root: ?*ModuleRecord = null,
    mod_index: u32 = 0,

    local_exports: std.StringHashMapUnmanaged(*heap.Cell) = .empty,
    indirect_exports: std.StringHashMapUnmanaged(IndirectExport) = .empty,
    star_reexports: std.ArrayList(*ModuleRecord) = .empty,
    deps: std.ArrayList(*ModuleRecord) = .empty,
    import_links: std.ArrayList(ImportLink) = .empty,

    fn deinit(m: *ModuleRecord, gpa: Allocator) void {
        if (m.proto) |p| {
            p.deinit(gpa);
            gpa.destroy(p);
        }
        if (m.cells.len > 0) gpa.free(m.cells);
        m.async_parents.deinit(gpa);
        m.local_exports.deinit(gpa);
        m.indirect_exports.deinit(gpa);
        m.star_reexports.deinit(gpa);
        m.deps.deinit(gpa);
        m.import_links.deinit(gpa);
        m.arena.deinit();
        gpa.destroy(m.arena);
        gpa.free(m.source);
        gpa.free(m.canonical_id);
    }
};

pub const ModuleRegistry = struct {
    map: std.StringHashMapUnmanaged(*ModuleRecord) = .empty,
    list: std.ArrayList(*ModuleRecord) = .empty,
    loader: ?ModuleLoader = null,
    async_eval_counter: u64 = 0,

    pub fn deinit(reg: *ModuleRegistry, gpa: Allocator) void {
        for (reg.list.items) |m| {
            m.deinit(gpa);
            gpa.destroy(m);
        }
        reg.list.deinit(gpa);
        reg.map.deinit(gpa);
    }

    pub fn markRoots(reg: *const ModuleRegistry, h: *heap.Heap) void {
        for (reg.list.items) |m| {
            for (m.cells) |cell| h.markObj(&cell.obj);
            if (m.namespace) |ns| h.markObj(&ns.obj);
            if (m.namespace_cell) |nc| h.markObj(&nc.obj);
            if (m.import_meta) |im| h.markObj(&im.obj);
            if (m.eval_promise) |ep| h.markObj(&ep.obj);
            if (m.eval_error) |v| h.markValue(v);
            if (m.proto) |p| {
                if (!h.in_minor or !m.proto_promoted) {
                    markProto(p, h);
                    m.proto_promoted = true;
                }
            }
        }
    }

    pub fn markProto(p: *const Proto, h: *heap.Heap) void {
        for (p.consts) |c| h.markValue(c);
        for (p.name_atoms) |a| h.markObj(@constCast(&a.obj));
        for (p.functions) |*child| markProto(child, h);
    }
};

/// Holds compiled `Proto`s and top-level `Cell` slices owned by `--preload` scripts
/// so closures they define remain live and GC-rooted across subsequent execution.
pub const PreloadPool = struct {
    protos: std.ArrayList(*Proto) = .empty,
    cell_slices: std.ArrayList([]*heap.Cell) = .empty,
    promoted_count: usize = 0,

    pub fn deinit(self: *PreloadPool, gpa: Allocator) void {
        for (self.protos.items) |p| {
            p.deinit(gpa);
            gpa.destroy(p);
        }
        self.protos.deinit(gpa);
        for (self.cell_slices.items) |cs| gpa.free(cs);
        self.cell_slices.deinit(gpa);
    }

    pub fn markRoots(ctx: *anyopaque, h: *heap.Heap) void {
        const self: *PreloadPool = @ptrCast(@alignCast(ctx));
        const start: usize = if (h.in_minor) self.promoted_count else 0;
        for (self.protos.items[start..]) |p| ModuleRegistry.markProto(p, h);
        self.promoted_count = self.protos.items.len;
        for (self.cell_slices.items) |cs| {
            for (cs) |cell| h.markObj(&cell.obj);
        }
    }
};

fn emptyReplLookup(_: *const anyopaque, _: []const u8) ?resolver.ReplKind {
    return null;
}

/// Executes a preloaded script in an existing `Runtime` so globals and functions it defines
/// remain live and GC-safe across subsequent script or module execution on both engines.
/// When `export_globals` is true, top-level declarations are exposed on `globalThis` so
/// subsequent `--preload` scripts and ES modules can reference them directly.
pub fn runPreloadScript(
    rt: *Runtime,
    arena: Allocator,
    source: []const u8,
    engine: Engine,
    export_globals: bool,
    diag: *Diagnostic,
    pool: *PreloadPool,
) (ModuleError || RuntimeError)!void {
    const script = parser.parse(arena, source, rt.limits, diag) catch |e| return switch (e) {
        error.SyntaxError => error.SyntaxError,
        error.Unsupported => error.Unsupported,
        error.LimitExceeded => error.LimitExceeded,
        error.OutOfMemory => error.OutOfMemory,
    };
    const res_ptr = try arena.create(Resolution);
    const dummy_ctx: u8 = 0;
    const repl_lookup: ?resolver.ReplLookup = if (export_globals) .{
        .ctx = &dummy_ctx,
        .get = emptyReplLookup,
    } else null;
    res_ptr.* = resolver.resolveWithRepl(arena, script, repl_lookup, diag) catch |e| return switch (e) {
        error.SyntaxError => error.SyntaxError,
        error.Unsupported => error.Unsupported,
        error.OutOfMemory => error.OutOfMemory,
    };

    var cells: []*heap.Cell = &.{};
    if (res_ptr.repl_bindings.len > 0) {
        cells = try rt.gpa.alloc(*heap.Cell, res_ptr.repl_bindings.len);
        var cells_owned = false;
        errdefer if (!cells_owned) rt.gpa.free(cells);
        for (res_ptr.repl_bindings, 0..) |rb, i| {
            const init_val: ?Value = if (rb.kind == .@"var") .undefined else null;
            cells[i] = rt.heap.newCell(init_val) catch |e| return mapHeapErr(e, rt);
        }
        try pool.cell_slices.append(rt.gpa, cells);
        cells_owned = true;
    }

    if (engine == .vm) {
        const p = try rt.gpa.create(Proto);
        var owned_by_pool = false;
        errdefer if (!owned_by_pool) rt.gpa.destroy(p);
        p.* = compiler.compile(rt.gpa, &rt.heap, script, res_ptr.*, rt.limits, diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LimitExceeded => return error.LimitExceeded,
        };
        errdefer if (!owned_by_pool) p.deinit(rt.gpa);
        var vfail: verify.Failure = .{};
        _ = verify.verify(rt.gpa, p, rt.limits, &vfail) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBytecode => return error.InvalidBytecode,
        };
        if (cells.len > 0) setProtoReplCells(p, cells);
        try pool.protos.append(rt.gpa, p);
        owned_by_pool = true;
        var vm = try Vm.init(rt, p);
        defer vm.deinit();
        try vm.run();
    } else {
        try machine.runRepl(rt, script, res_ptr, cells);
    }

    if (export_globals and cells.len > 0) {
        const realm = try builtins.realm(rt);
        var held = [_]Value{.undefined};
        var roots: ValueRoots = .{ .values = &held };
        try roots.register(rt);
        defer roots.unregister(rt);
        for (res_ptr.repl_bindings, 0..) |rb, i| {
            if (cells[i].value) |val| {
                const atom = try rt.heap.internUtf8(rb.name);
                held[0] = Value.fromString(atom);
                try rt.heap.defineProperty(realm.global_object, atom, .{
                    .value = val,
                    .writable = true,
                    .enumerable = true,
                    .configurable = true,
                });
            }
        }
    }
}

fn setProtoReplCells(p: *Proto, cells: []*heap.Cell) void {
    p.repl_cells = cells;
    for (p.functions) |*child| setProtoReplCells(child, cells);
}

fn setProtoModuleRecord(p: *Proto, mod: *ModuleRecord) void {
    p.module_record = mod;
    for (p.functions) |*child| setProtoModuleRecord(child, mod);
}

/// Loads, parses, compiles (if `.vm`), links, and evaluates an ES module graph.
/// Returns the entry module's namespace object on success.
pub fn runEntry(
    rt: *Runtime,
    specifier: []const u8,
    entry_source: ?[]const u8,
    engine: Engine,
    mod_diag: *ModuleDiag,
) (ModuleError || RuntimeError)!*heap.Object {
    const entry = try loadAndLink(rt, specifier, entry_source, engine, mod_diag);
    const ep = try evaluateModule(rt, entry, engine);
    var held = [_]Value{Value.fromObject(ep)};
    var roots: ValueRoots = .{ .values = &held };
    try roots.register(rt);
    defer roots.unregister(rt);
    if (engine == .vm) {
        const prev_caller = rt.closure_caller;
        if (rt.closure_caller == null) {
            rt.closure_caller = .{ .ctx = rt, .call = Vm.callStandalone, .construct = Vm.constructStandalone };
        }
        defer rt.closure_caller = prev_caller;
        try rt.drainMicrotasks();
    } else if (rt.closure_caller == null) {
        // Install a Machine closure_caller while draining microtasks on treewalk.
        var empty_script = entry.script;
        empty_script.statements = &.{};
        try machine.runModule(rt, empty_script, &entry.res, entry.cells, entry);
    } else {
        try rt.drainMicrotasks();
    }
    switch (ep.kind.promise.state) {
        .fulfilled => {},
        .rejected => return rt.throwValue(ep.kind.promise.result),
        .pending => {},
    }
    return try getNamespace(rt, entry);
}

pub fn loadAndLink(
    rt: *Runtime,
    specifier: []const u8,
    entry_source: ?[]const u8,
    engine: Engine,
    mod_diag: *ModuleDiag,
) ModuleError!*ModuleRecord {
    const start_len = rt.modules.list.items.len;
    errdefer rollbackNewModules(rt, start_len);

    const entry = try loadModule(rt, null, specifier, entry_source, engine, mod_diag);
    try linkGraph(rt, engine, start_len, mod_diag);
    return entry;
}

fn rollbackNewModules(rt: *Runtime, start_len: usize) void {
    const gpa = rt.gpa;
    while (rt.modules.list.items.len > start_len) {
        const m = rt.modules.list.pop().?;
        _ = rt.modules.map.remove(m.canonical_id);
        m.deinit(gpa);
        gpa.destroy(m);
    }
}

fn loadModule(
    rt: *Runtime,
    referrer_id: ?[]const u8,
    specifier: []const u8,
    direct_source: ?[]const u8,
    engine: Engine,
    mod_diag: *ModuleDiag,
) ModuleError!*ModuleRecord {
    const gpa = rt.gpa;

    var loaded: LoadedModule = undefined;
    var has_loaded = false;
    if (direct_source) |src| {
        loaded = .{ .canonical_id = specifier, .source = src };
    } else {
        const loader = rt.modules.loader orelse {
            mod_diag.name = specifier;
            return error.ModuleNotFound;
        };
        loaded = loader.load(loader.ctx, referrer_id, specifier) catch |e| switch (e) {
            error.ModuleNotFound => {
                mod_diag.name = specifier;
                return error.ModuleNotFound;
            },
            error.HostError => {
                mod_diag.name = specifier;
                return error.HostError;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        has_loaded = true;
    }
    defer if (has_loaded) {
        if (loaded.free) |free_fn| {
            const loader_ctx = if (rt.modules.loader) |l| l.ctx else null;
            free_fn(loader_ctx, loaded.canonical_id, loaded.source);
        }
    };

    if (rt.modules.map.get(loaded.canonical_id)) |existing| {
        return existing;
    }

    if (rt.modules.list.items.len >= rt.limits.max_modules) {
        rt.limit_hit = .modules;
        mod_diag.diag = .{ .detail = .{ .limit_exceeded = .modules } };
        mod_diag.name = loaded.canonical_id;
        return error.LimitExceeded;
    }

    var owned_by_registry = false;
    const owned_id = try gpa.dupe(u8, loaded.canonical_id);
    errdefer if (!owned_by_registry) gpa.free(owned_id);
    const owned_src = try gpa.dupe(u8, loaded.source);
    errdefer if (!owned_by_registry) gpa.free(owned_src);

    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    errdefer if (!owned_by_registry) {
        arena.deinit();
        gpa.destroy(arena);
    };

    var diag: Diagnostic = .{};
    const script = parser.parseWithOptions(arena.allocator(), owned_src, rt.limits, .{ .source_kind = .module }, &diag) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        mod_diag.diag = diag;
        mod_diag.source = if (direct_source != null) direct_source.? else "";
        mod_diag.name = "";
        return switch (e) {
            error.SyntaxError => error.SyntaxError,
            error.Unsupported => error.Unsupported,
            error.LimitExceeded => error.LimitExceeded,
            error.OutOfMemory => error.OutOfMemory,
        };
    };

    const res = resolver.resolve(arena.allocator(), script, &diag) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        mod_diag.diag = diag;
        mod_diag.source = if (direct_source != null) direct_source.? else "";
        mod_diag.name = "";
        return switch (e) {
            error.SyntaxError => error.SyntaxError,
            error.Unsupported => error.Unsupported,
            error.OutOfMemory => error.OutOfMemory,
        };
    };

    var proto_ptr: ?*Proto = null;
    errdefer if (!owned_by_registry) if (proto_ptr) |p| {
        p.deinit(gpa);
        gpa.destroy(p);
    };
    if (engine == .vm) {
        const p = try gpa.create(Proto);
        errdefer gpa.destroy(p);
        p.* = compiler.compileWithOptions(gpa, &rt.heap, script, res, rt.limits, .{ .is_module = true, .top_level_await = script.has_top_level_await }, &diag) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LimitExceeded => {
                mod_diag.diag = diag;
                mod_diag.source = if (direct_source != null) direct_source.? else "";
                return error.LimitExceeded;
            },
        };
        var vfail: verify.Failure = .{};
        _ = verify.verify(gpa, p, rt.limits, &vfail) catch |e| switch (e) {
            error.OutOfMemory => {
                p.deinit(gpa);
                return error.OutOfMemory;
            },
            error.InvalidBytecode => {
                p.deinit(gpa);
                return error.InvalidBytecode;
            },
        };
        proto_ptr = p;
    }

    const mod = try gpa.create(ModuleRecord);
    errdefer if (!owned_by_registry) gpa.destroy(mod);
    mod.* = .{
        .canonical_id = owned_id,
        .source = owned_src,
        .arena = arena,
        .script = script,
        .res = res,
        .proto = proto_ptr,
        .has_tla = script.has_top_level_await,
        .mod_index = @intCast(rt.modules.list.items.len),
    };
    if (proto_ptr) |p| setProtoModuleRecord(p, mod);

    try rt.modules.list.ensureUnusedCapacity(gpa, 1);
    try rt.modules.map.ensureUnusedCapacity(gpa, 1);
    rt.modules.list.appendAssumeCapacity(mod);
    rt.modules.map.putAssumeCapacity(owned_id, mod);
    owned_by_registry = true;

    // DFS load all dependencies in source order.
    for (script.statements) |s| {
        const dep_spec: ?[]const u8 = switch (s.data) {
            .import_decl => |imp| imp.specifier,
            .export_decl => |exp| switch (exp) {
                .reexport_named => |rn| rn.from,
                .reexport_all => |ra| ra.from,
                else => null,
            },
            else => null,
        };
        if (dep_spec) |spec| {
            const dep = try loadModule(rt, mod.canonical_id, spec, null, engine, mod_diag);
            try mod.deps.append(gpa, dep);
        }
    }

    return mod;
}

fn linkGraph(rt: *Runtime, engine: Engine, start_len: usize, mod_diag: *ModuleDiag) ModuleError!void {
    const gpa = rt.gpa;
    const mods = rt.modules.list.items[start_len..];

    // Step 1: Allocate local cells for each new module and populate local_exports / indirect_exports / star_reexports.
    for (mods) |m| {
        const cells = try gpa.alloc(*heap.Cell, m.res.repl_bindings.len);
        m.cells = cells;
        for (cells) |*slot| slot.* = undefined;

        var is_import = try gpa.alloc(bool, m.res.repl_bindings.len);
        defer gpa.free(is_import);
        @memset(is_import, false);

        var dep_idx: usize = 0;
        for (m.script.statements) |s| switch (s.data) {
            .import_decl => |imp| {
                const dep = m.deps.items[dep_idx];
                dep_idx += 1;
                if (imp.default_binding) |db| {
                    const ri = m.res.bindings[db.binding].repl_index.?;
                    is_import[ri] = true;
                    try m.import_links.append(gpa, .{ .repl_idx = ri, .dep = dep, .imported_name = "default", .span = db.span });
                }
                if (imp.namespace_binding) |nb| {
                    const ri = m.res.bindings[nb.binding].repl_index.?;
                    // Namespace imports own their own cell (populated in Step 2) so
                    // `import * as ns from ...; export { ns };` shares the cell safely.
                    try m.import_links.append(gpa, .{ .repl_idx = ri, .dep = dep, .imported_name = null, .span = nb.span });
                }
                for (imp.named) |sp| {
                    const ri = m.res.bindings[sp.local.binding].repl_index.?;
                    is_import[ri] = true;
                    const imp_name = try decodeIdentName(m.arena.allocator(), sp.imported);
                    try m.import_links.append(gpa, .{ .repl_idx = ri, .dep = dep, .imported_name = imp_name, .span = sp.span });
                }
            },
            .export_decl => |exp| switch (exp) {
                .reexport_named => |rn| {
                    const dep = m.deps.items[dep_idx];
                    dep_idx += 1;
                    for (rn.specifiers) |sp| {
                        const exp_name = try decodeIdentName(m.arena.allocator(), sp.exported);
                        const imp_name = try decodeIdentName(m.arena.allocator(), sp.imported);
                        try m.indirect_exports.put(gpa, exp_name, .{
                            .dep = dep,
                            .imported_name = imp_name,
                            .span = sp.span,
                        });
                    }
                },
                .reexport_all => |ra| {
                    const dep = m.deps.items[dep_idx];
                    dep_idx += 1;
                    if (ra.namespace) |ns_name| {
                        const dec_ns = try decodeIdentName(m.arena.allocator(), ns_name);
                        try m.indirect_exports.put(gpa, dec_ns, .{
                            .dep = dep,
                            .imported_name = null,
                            .span = s.span,
                        });
                    } else {
                        try m.star_reexports.append(gpa, dep);
                    }
                },
                else => {},
            },
            else => {},
        };

        // Allocate fresh cells for all non-import top-level bindings (`var` starts as undefined; let/const start in TDZ).
        for (m.res.repl_bindings, 0..) |rb, i| {
            if (!is_import[i]) {
                const init_val: ?Value = if (rb.kind == .@"var") .undefined else null;
                cells[i] = rt.heap.newCell(init_val) catch |e| return mapHeapErr(e, rt);
            }
        }

        // Populate `local_exports` from export declarations.
        for (m.script.statements) |s| if (s.data == .export_decl) switch (s.data.export_decl) {
            .declaration => |decl| for (decl.declarators) |d| try addPatternExports(gpa, m, d.pattern),
            .function => |f| {
                const ri = m.res.bindings[f.name.?.binding].repl_index.?;
                const exp_name = try decodeIdentName(m.arena.allocator(), f.name.?.name);
                try m.local_exports.put(gpa, exp_name, m.cells[ri]);
            },
            .class => |cls| {
                const ri = m.res.bindings[cls.name.?.binding].repl_index.?;
                const exp_name = try decodeIdentName(m.arena.allocator(), cls.name.?.name);
                try m.local_exports.put(gpa, exp_name, m.cells[ri]);
            },
            .default_expr => |de| {
                const ri = m.res.bindings[de.binding].repl_index.?;
                try m.local_exports.put(gpa, "default", m.cells[ri]);
            },
            .default_function => |df| {
                const ri = m.res.bindings[df.binding].repl_index.?;
                try m.local_exports.put(gpa, "default", m.cells[ri]);
            },
            .default_class => |dc| {
                const ri = m.res.bindings[dc.binding].repl_index.?;
                try m.local_exports.put(gpa, "default", m.cells[ri]);
            },
            .named => |specs| for (specs) |sp| {
                const ri = m.res.refs[sp.local.id].repl;
                const exp_name = try decodeIdentName(m.arena.allocator(), sp.exported);
                var matched_import: ?ImportLink = null;
                for (m.import_links.items) |link| {
                    if (link.repl_idx == ri) {
                        matched_import = link;
                        break;
                    }
                }
                if (matched_import) |link| {
                    try m.indirect_exports.put(gpa, exp_name, .{
                        .dep = link.dep,
                        .imported_name = link.imported_name,
                        .span = sp.span,
                    });
                } else {
                    try m.local_exports.put(gpa, exp_name, m.cells[ri]);
                }
            },
            .reexport_named, .reexport_all => {},
        };
    }

    // Step 2: Resolve all imports & indirect re-exports across the graph.
    for (mods) |m| {
        for (m.import_links.items) |link| {
            if (link.imported_name) |imp_name| {
                const resolved = try resolveExportTop(gpa, link.dep, imp_name);
                switch (resolved) {
                    .resolved => |r| m.cells[link.repl_idx] = r.cell,
                    .namespace => |target| {
                        m.cells[link.repl_idx] = getNamespaceCell(rt, target) catch |e| return mapRuntimeToModErr(e);
                    },
                    .not_found => {
                        mod_diag.diag = .{ .detail = .{ .syntax_error = "does not provide an export named" }, .start = link.span.start, .end = link.span.end };
                        return error.SyntaxError;
                    },
                    .ambiguous => {
                        mod_diag.diag = .{ .detail = .{ .syntax_error = "ambiguous indirect export" }, .start = link.span.start, .end = link.span.end };
                        return error.SyntaxError;
                    },
                }
            } else {
                const ns_obj = getNamespace(rt, link.dep) catch |e| return mapRuntimeToModErr(e);
                rt.heap.storeCell(m.cells[link.repl_idx], Value.fromObject(ns_obj));
            }
        }

        var ind_it = m.indirect_exports.iterator();
        while (ind_it.next()) |entry| {
            const ind = entry.value_ptr.*;
            const imp_name = ind.imported_name orelse continue;
            const resolved = try resolveExportTop(gpa, ind.dep, imp_name);
            switch (resolved) {
                .resolved, .namespace => {},
                .not_found => {
                    mod_diag.diag = .{ .detail = .{ .syntax_error = "does not provide an export named" }, .start = ind.span.start, .end = ind.span.end };
                    return error.SyntaxError;
                },
                .ambiguous => {
                    mod_diag.diag = .{ .detail = .{ .syntax_error = "ambiguous indirect export" }, .start = ind.span.start, .end = ind.span.end };
                    return error.SyntaxError;
                },
            }
        }
    }

    // Step 3: Wire `Proto.repl_cells` and hoist top-level function declarations before evaluation.
    for (mods) |m| {
        if (engine == .vm) {
            setProtoReplCells(m.proto.?, m.cells);
            var fn_idx: usize = 0;
            for (m.script.statements) |s| switch (s.data) {
                .function => |f| {
                    const cl = rt.heap.newVmClosure(&m.proto.?.functions[fn_idx], 0) catch |e| return mapHeapErr(e, rt);
                    fn_idx += 1;
                    const ri = m.res.bindings[f.name.?.binding].repl_index.?;
                    rt.heap.storeCell(m.cells[ri], Value.fromClosure(cl));
                },
                .export_decl => |exp| switch (exp) {
                    .function => |f| {
                        const cl = rt.heap.newVmClosure(&m.proto.?.functions[fn_idx], 0) catch |e| return mapHeapErr(e, rt);
                        fn_idx += 1;
                        const ri = m.res.bindings[f.name.?.binding].repl_index.?;
                        rt.heap.storeCell(m.cells[ri], Value.fromClosure(cl));
                    },
                    .default_function => |df| {
                        const cl = rt.heap.newVmClosure(&m.proto.?.functions[fn_idx], 0) catch |e| return mapHeapErr(e, rt);
                        fn_idx += 1;
                        const def_ri = m.res.bindings[df.binding].repl_index.?;
                        rt.heap.storeCell(m.cells[def_ri], Value.fromClosure(cl));
                        if (df.func.name) |n| {
                            const name_ri = m.res.bindings[n.binding].repl_index.?;
                            rt.heap.storeCell(m.cells[name_ri], Value.fromClosure(cl));
                        }
                    },
                    else => {},
                },
                else => {},
            };
        } else {
            for (m.script.statements) |s| switch (s.data) {
                .function => |f| {
                    const cl = rt.heap.newTreeClosure(f, null) catch |e| return mapHeapErr(e, rt);
                    cl.impl.tree.res = @ptrCast(&m.res);
                    cl.impl.tree.repl_cells = m.cells;
                    cl.impl.tree.module_record = m;
                    const ri = m.res.bindings[f.name.?.binding].repl_index.?;
                    rt.heap.storeCell(m.cells[ri], Value.fromClosure(cl));
                },
                .export_decl => |exp| switch (exp) {
                    .function => |f| {
                        const cl = rt.heap.newTreeClosure(f, null) catch |e| return mapHeapErr(e, rt);
                        cl.impl.tree.res = @ptrCast(&m.res);
                        cl.impl.tree.repl_cells = m.cells;
                        cl.impl.tree.module_record = m;
                        const ri = m.res.bindings[f.name.?.binding].repl_index.?;
                        rt.heap.storeCell(m.cells[ri], Value.fromClosure(cl));
                    },
                    .default_function => |df| {
                        const cl = rt.heap.newTreeClosure(df.func, null) catch |e| return mapHeapErr(e, rt);
                        cl.impl.tree.res = @ptrCast(&m.res);
                        cl.impl.tree.repl_cells = m.cells;
                        cl.impl.tree.module_record = m;
                        const def_ri = m.res.bindings[df.binding].repl_index.?;
                        rt.heap.storeCell(m.cells[def_ri], Value.fromClosure(cl));
                        if (df.func.name) |n| {
                            const name_ri = m.res.bindings[n.binding].repl_index.?;
                            rt.heap.storeCell(m.cells[name_ri], Value.fromClosure(cl));
                        }
                    },
                    else => {},
                },
                else => {},
            };
        }
        m.status = .linked;
    }
}

fn mapRuntimeToModErr(e: RuntimeError) ModuleError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.LimitExceeded => error.LimitExceeded,
        error.Unsupported => error.Unsupported,
        else => error.HostError,
    };
}

fn mapHeapErr(e: heap.Error, rt: *Runtime) ModuleError {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.LimitExceeded => {
            rt.limit_hit = rt.heap.limit_hit;
            return error.LimitExceeded;
        },
    };
}

fn decodeIdentName(arena: Allocator, raw: []const u8) error{OutOfMemory}![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len and raw[i + 1] == 'u') {
            if (i + 2 < raw.len and raw[i + 2] == '{') {
                if (std.mem.indexOfScalarPos(u8, raw, i + 3, '}')) |close| {
                    if (std.fmt.parseInt(u21, raw[i + 3 .. close], 16)) |cp| {
                        var buf: [4]u8 = undefined;
                        if (std.unicode.utf8Encode(cp, &buf)) |n| {
                            try out.appendSlice(arena, buf[0..n]);
                            i = close + 1;
                            continue;
                        } else |_| {}
                    } else |_| {}
                }
            } else if (i + 6 <= raw.len) {
                if (std.fmt.parseInt(u16, raw[i + 2 .. i + 6], 16)) |cu1| {
                    var cp: u21 = cu1;
                    var next_i = i + 6;
                    if (cu1 >= 0xD800 and cu1 <= 0xDBFF and next_i + 6 <= raw.len and raw[next_i] == '\\' and raw[next_i + 1] == 'u') {
                        if (std.fmt.parseInt(u16, raw[next_i + 2 .. next_i + 6], 16)) |cu2| {
                            if (cu2 >= 0xDC00 and cu2 <= 0xDFFF) {
                                cp = 0x10000 + (@as(u21, cu1 - 0xD800) << 10) + @as(u21, cu2 - 0xDC00);
                                next_i += 6;
                            }
                        } else |_| {}
                    }
                    var buf: [4]u8 = undefined;
                    if (std.unicode.utf8Encode(cp, &buf)) |n| {
                        try out.appendSlice(arena, buf[0..n]);
                        i = next_i;
                        continue;
                    } else |_| {}
                } else |_| {}
            }
        }
        try out.append(arena, raw[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

fn addPatternExports(gpa: Allocator, m: *ModuleRecord, pat: *const ast.Pattern) Allocator.Error!void {
    switch (pat.data) {
        .binding => |d| {
            const ri = m.res.bindings[d.binding].repl_index.?;
            const exp_name = try decodeIdentName(m.arena.allocator(), d.name);
            try m.local_exports.put(gpa, exp_name, m.cells[ri]);
        },
        .array => |arr| {
            for (arr.elems) |maybe| if (maybe) |el| try addPatternExports(gpa, m, el.pattern);
            if (arr.rest) |r| try addPatternExports(gpa, m, r);
        },
        .object => |obj| {
            for (obj.props) |pr| try addPatternExports(gpa, m, pr.pattern);
            if (obj.rest) |r| try addPatternExports(gpa, m, r);
        },
        .target => unreachable,
    }
}

const ResolveKey = struct {
    mod: *const ModuleRecord,
    name: []const u8,
};

const ResolveResult = union(enum) {
    resolved: struct { mod: *const ModuleRecord, cell: *heap.Cell },
    namespace: *ModuleRecord,
    not_found,
    ambiguous,
};

fn resolveExportTop(gpa: Allocator, mod: *const ModuleRecord, name: []const u8) error{OutOfMemory}!ResolveResult {
    var visited: std.ArrayList(ResolveKey) = .empty;
    defer visited.deinit(gpa);
    return resolveExport(gpa, mod, name, &visited);
}

fn resolveExport(gpa: Allocator, mod: *const ModuleRecord, name: []const u8, visited: *std.ArrayList(ResolveKey)) error{OutOfMemory}!ResolveResult {
    for (visited.items) |v| {
        if (v.mod == mod and std.mem.eql(u8, v.name, name)) return .not_found;
    }
    try visited.append(gpa, .{ .mod = mod, .name = name });

    if (mod.local_exports.get(name)) |cell| {
        return .{ .resolved = .{ .mod = mod, .cell = cell } };
    }
    if (mod.indirect_exports.get(name)) |ind| {
        if (ind.imported_name) |imp_name| {
            return resolveExport(gpa, ind.dep, imp_name, visited);
        }
        return .{ .namespace = ind.dep };
    }
    if (std.mem.eql(u8, name, "default")) return .not_found;

    var star_res: ResolveResult = .not_found;
    for (mod.star_reexports.items) |star_dep| {
        const sub = try resolveExport(gpa, star_dep, name, visited);
        switch (sub) {
            .not_found => {},
            .ambiguous => return .ambiguous,
            .resolved => |r| switch (star_res) {
                .not_found => star_res = .{ .resolved = r },
                .resolved => |prev| {
                    if (prev.cell != r.cell) return .ambiguous;
                },
                .namespace => return .ambiguous,
                .ambiguous => unreachable,
            },
            .namespace => |target| switch (star_res) {
                .not_found => star_res = .{ .namespace = target },
                .namespace => |prev_target| {
                    if (prev_target != target) return .ambiguous;
                },
                .resolved => return .ambiguous,
                .ambiguous => unreachable,
            },
        }
    }
    return star_res;
}

fn getNamespaceCell(rt: *Runtime, mod: *ModuleRecord) RuntimeError!*heap.Cell {
    if (mod.namespace_cell) |c| return c;
    _ = try getNamespace(rt, mod);
    return mod.namespace_cell.?;
}

pub fn getNamespace(rt: *Runtime, mod: *ModuleRecord) RuntimeError!*heap.Object {
    if (mod.namespace) |ns| return ns;
    if (mod.namespace_cell == null) {
        mod.namespace_cell = try rt.heap.newCell(null);
    }

    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(rt.gpa);
    var visited: std.AutoHashMapUnmanaged(*const ModuleRecord, void) = .empty;
    defer visited.deinit(rt.gpa);

    try collectExportedNames(rt.gpa, mod, &names, &visited, false);

    // Root interned atoms in a temporary GC array while collecting entries so `-Dgc-stress`
    // cannot sweep weak atoms before `newModuleNamespace` takes ownership.
    const atom_roots = try rt.heap.newArray(null);
    var held = [_]Value{ Value.fromObject(atom_roots), .undefined };
    var roots: ValueRoots = .{ .values = &held };
    try roots.register(rt);
    defer roots.unregister(rt);

    var entries: std.ArrayList(heap.ModuleExport) = .empty;
    defer entries.deinit(rt.gpa);

    var it = names.keyIterator();
    while (it.next()) |key_ptr| {
        const export_name = key_ptr.*;
        const resolved = try resolveExportTop(rt.gpa, mod, export_name);
        const cell: *heap.Cell = switch (resolved) {
            .resolved => |r| r.cell,
            .namespace => |target| try getNamespaceCell(rt, target),
            .ambiguous, .not_found => continue,
        };
        const atom = try rt.heap.internUtf8(export_name);
        try rt.heap.appendElement(atom_roots, Value.fromString(atom));
        try entries.append(rt.gpa, .{ .name = atom, .cell = cell });
    }

    std.mem.sort(heap.ModuleExport, entries.items, {}, struct {
        fn lt(_: void, a: heap.ModuleExport, b: heap.ModuleExport) bool {
            return std.mem.order(u16, a.name.units, b.name.units) == .lt;
        }
    }.lt);

    const ns_obj = try rt.heap.newModuleNamespace(entries.items);
    held[1] = Value.fromObject(ns_obj);
    const realm = try builtins.realm(rt);
    const tag_str = try rt.heap.internAscii("Module");
    try rt.heap.definePropKey(ns_obj, heap.PropKey.fromSymbol(realm.sym_to_string_tag), .{
        .value = Value.fromString(tag_str),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    mod.namespace = ns_obj;
    rt.heap.storeCell(mod.namespace_cell.?, Value.fromObject(ns_obj));
    return ns_obj;
}

fn collectExportedNames(
    gpa: Allocator,
    mod: *const ModuleRecord,
    out: *std.StringHashMapUnmanaged(void),
    visited: *std.AutoHashMapUnmanaged(*const ModuleRecord, void),
    via_star: bool,
) error{OutOfMemory}!void {
    if (visited.contains(mod)) return;
    try visited.put(gpa, mod, {});

    var loc_it = mod.local_exports.keyIterator();
    while (loc_it.next()) |k| {
        if (via_star and std.mem.eql(u8, k.*, "default")) continue;
        try out.put(gpa, k.*, {});
    }

    var ind_it = mod.indirect_exports.keyIterator();
    while (ind_it.next()) |k| {
        if (via_star and std.mem.eql(u8, k.*, "default")) continue;
        try out.put(gpa, k.*, {});
    }

    for (mod.star_reexports.items) |star_dep| {
        try collectExportedNames(gpa, star_dep, out, visited, true);
    }
}

pub fn getImportMeta(rt: *Runtime, mod: *ModuleRecord) RuntimeError!*heap.Object {
    if (mod.import_meta) |im| return im;

    const obj = try rt.heap.newObject(null);
    var held = [_]Value{ Value.fromObject(obj), .undefined };
    var roots: ValueRoots = .{ .values = &held };
    try roots.register(rt);
    defer roots.unregister(rt);

    const is_fs = if (rt.modules.loader) |l| l.load == FsLoader.load else false;
    var owned_url: ?[]u8 = null;
    defer if (owned_url) |u| rt.gpa.free(u);

    const url_utf8: []const u8 = if (is_fs and !std.mem.startsWith(u8, mod.canonical_id, "file://")) blk: {
        owned_url = try std.fmt.allocPrint(rt.gpa, "file://{s}", .{mod.canonical_id});
        break :blk owned_url.?;
    } else mod.canonical_id;

    const url_str = try utf8ToHeapString(rt, url_utf8);
    held[1] = Value.fromString(url_str);

    try rt.heap.defineProperty(obj, try rt.heap.internAscii("url"), .{
        .value = held[1],
        .writable = true,
        .enumerable = true,
        .configurable = true,
    });
    mod.import_meta = obj;
    return obj;
}

fn utf8ToHeapString(rt: *Runtime, text: []const u8) RuntimeError!*heap.String {
    if (std.unicode.utf8ValidateSlice(text)) {
        const units = std.unicode.utf8ToUtf16LeAlloc(rt.gpa, text) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return rt.heap.internAscii(text),
        };
        defer rt.gpa.free(units);
        return rt.heap.newString(&.{.{ .utf16 = units }});
    }
    return rt.heap.internAscii(text);
}

pub fn dynamicImport(
    rt: *Runtime,
    referrer_mod: ?*ModuleRecord,
    specifier_val: Value,
    engine: Engine,
) RuntimeError!*heap.Object {
    const r = try builtins.realm(rt);
    const p = try rt.heap.newPromise(r.promise_prototype);

    var held = [_]Value{ Value.fromObject(p), specifier_val, .undefined, .undefined };
    var roots: ValueRoots = .{ .values = &held };
    try roots.register(rt);
    defer roots.unregister(rt);

    const spec_str_val = ops.toStringValue(rt, specifier_val) catch |e| switch (e) {
        error.Thrown => {
            const err_val = try rt.catchValue();
            try builtins.settlePromiseFromJob(rt, p, true, err_val);
            return p;
        },
        else => return e,
    };
    held[1] = spec_str_val;

    // Defer loading/linking/evaluation to a microtask per ES `HostLoadImportedModule` /
    // `ContinueDynamicImport` so dynamic `import()` never preempts an active DFS `Evaluate`.
    const env = try rt.heap.newArray(null);
    held[2] = Value.fromObject(env);
    const ref_num: f64 = if (referrer_mod) |rm| @floatFromInt(rm.mod_index) else -1.0;
    try rt.heap.appendElements(env, &.{
        Value.fromObject(p),
        spec_str_val,
        Value.fromNumber(ref_num),
        Value.fromNumber(@floatFromInt(@backingInt(engine))),
    });
    const job_cb = try rt.heap.newNativeClosure(&dynImportJobCb, env);
    held[3] = Value.fromClosure(job_cb);
    try rt.microtasks.ensureUnusedCapacity(rt.gpa, 1);
    rt.microtasks.appendAssumeCapacity(.{
        .kind = .reaction,
        .child = null,
        .cb = held[3],
        .arg = .undefined,
    });
    return p;
}

fn dynImportJobCb(rt: *Runtime, env: *heap.Object, _: []const Value) RuntimeError!Value {
    const p = env.kind.array.items[0].asObject();
    const spec_str_val = env.kind.array.items[1];
    const ref_num = env.kind.array.items[2].asNumber();
    const engine: Engine = @fromBackingInt(@intCast(@as(u8, @intFromFloat(env.kind.array.items[3].asNumber()))));

    var held = [_]Value{ Value.fromObject(p), spec_str_val, .undefined, .undefined, .undefined };
    var roots: ValueRoots = .{ .values = &held };
    try roots.register(rt);
    defer roots.unregister(rt);

    const spec_utf8 = std.unicode.utf16LeToUtf8Alloc(rt.gpa, spec_str_val.asString().units) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try rejectPromiseWithError(rt, p, .TypeError, "Invalid module specifier");
            return .undefined;
        },
    };
    defer rt.gpa.free(spec_utf8);

    const referrer_id: ?[]const u8 = if (ref_num >= 0) rt.modules.list.items[@intFromFloat(ref_num)].canonical_id else null;
    const start_len = rt.modules.list.items.len;
    var mod_diag: ModuleDiag = .{};

    const target_mod = loadAndLinkFromReferrer(rt, referrer_id, spec_utf8, engine, start_len, &mod_diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LimitExceeded => return error.LimitExceeded,
        error.Unsupported => return error.Unsupported,
        error.InvalidBytecode => return rt.bug("invalid module bytecode"),
        error.SyntaxError => {
            const msg = switch (mod_diag.diag.detail) {
                .syntax_error => |m| m,
                else => "SyntaxError",
            };
            try rejectPromiseWithError(rt, p, .SyntaxError, msg);
            return .undefined;
        },
        error.ModuleNotFound => {
            try rejectPromiseWithError(rt, p, .TypeError, "Cannot find module");
            return .undefined;
        },
        error.HostError => {
            try rejectPromiseWithError(rt, p, .TypeError, "Module load failed");
            return .undefined;
        },
    };

    const ep = try evaluateModule(rt, target_mod, engine);
    try attachDynImportReaction(rt, target_mod, ep, p, &held);
    return .undefined;
}

fn loadAndLinkFromReferrer(
    rt: *Runtime,
    referrer_id: ?[]const u8,
    specifier: []const u8,
    engine: Engine,
    start_len: usize,
    mod_diag: *ModuleDiag,
) ModuleError!*ModuleRecord {
    errdefer rollbackNewModules(rt, start_len);
    const mod = try loadModule(rt, referrer_id, specifier, null, engine, mod_diag);
    try linkGraph(rt, engine, start_len, mod_diag);
    return mod;
}

fn attachDynImportReaction(rt: *Runtime, target: *ModuleRecord, ep: *heap.Object, result_p: *heap.Object, held: *[5]Value) RuntimeError!void {
    const env = try rt.heap.newArray(null);
    held[2] = Value.fromObject(env);
    try rt.heap.appendElements(env, &.{ Value.fromNumber(@floatFromInt(target.mod_index)), Value.fromObject(result_p) });
    const on_ful = try rt.heap.newNativeClosure(&dynImportFulfillCb, env);
    held[3] = Value.fromClosure(on_ful);
    const on_rej = try rt.heap.newNativeClosure(&dynImportRejectCb, env);
    held[4] = Value.fromClosure(on_rej);
    try builtins.performPromiseThen(rt, ep, held[3], held[4]);
}

fn dynImportFulfillCb(rt: *Runtime, env: *heap.Object, _: []const Value) RuntimeError!Value {
    const mod_idx: usize = @intFromFloat(env.kind.array.items[0].asNumber());
    const result_p = env.kind.array.items[1].asObject();
    const mod = rt.modules.list.items[mod_idx];
    var held = [_]Value{ Value.fromObject(result_p), .undefined };
    var roots: ValueRoots = .{ .values = &held };
    try roots.register(rt);
    defer roots.unregister(rt);
    const ns = try getNamespace(rt, mod);
    held[1] = Value.fromObject(ns);
    try builtins.resolvePromiseValue(rt, result_p, held[1]);
    return .undefined;
}

fn dynImportRejectCb(rt: *Runtime, env: *heap.Object, args: []const Value) RuntimeError!Value {
    const result_p = env.kind.array.items[1].asObject();
    const reason: Value = if (args.len > 0) args[0] else .undefined;
    try builtins.settlePromiseFromJob(rt, result_p, true, reason);
    return .undefined;
}

fn rejectPromiseWithError(rt: *Runtime, p: *heap.Object, err_name: @FieldType(rt_mod.Exception, "name"), msg: []const u8) RuntimeError!void {
    const e = rt.throw(err_name, &.{.{ .ascii = msg }});
    if (e == error.Thrown) {
        const err_val = try rt.catchValue();
        try builtins.settlePromiseFromJob(rt, p, true, err_val);
        return;
    }
    return e;
}

/// ES2025 `Evaluate()` on a Cyclic Module Record.
/// Returns the module's (or its cycle root's) top-level capability promise.
pub fn evaluateModule(rt: *Runtime, start_mod: *ModuleRecord, engine: Engine) RuntimeError!*heap.Object {
    const mod: *ModuleRecord = switch (start_mod.status) {
        .evaluating_async, .evaluated, .errored => start_mod.cycle_root orelse start_mod,
        .linked => start_mod,
        .evaluating => start_mod,
        .unlinked, .linking => return rt.bug("evaluating unlinked module"),
    };

    if (mod.eval_fault) |fault| return fault;
    if (mod.eval_promise) |ep| return ep;

    const r = try builtins.realm(rt);
    const cap = try rt.heap.newPromise(r.promise_prototype);
    mod.eval_promise = cap;

    var stack: std.ArrayList(*ModuleRecord) = .empty;
    defer stack.deinit(rt.gpa);

    _ = innerModuleEvaluation(rt, mod, engine, &stack, 0) catch |e| {
        if (e == error.Thrown) {
            const err_val = try rt.catchValue();
            for (stack.items) |w| {
                if (w.status == .evaluating) {
                    w.status = .errored;
                    w.eval_error = err_val;
                    if (w.async_eval_order == .evaluating) w.async_eval_order = .done;
                }
            }
            mod.status = .errored;
            mod.eval_error = err_val;
            if (mod.async_eval_order == .evaluating) mod.async_eval_order = .done;
            try builtins.settlePromiseFromJob(rt, cap, true, err_val);
            return cap;
        }
        for (stack.items) |w| {
            if (w.status == .evaluating) {
                w.status = .errored;
                w.eval_fault = e;
            }
        }
        mod.status = .errored;
        mod.eval_fault = e;
        return e;
    };

    if (mod.async_eval_order != .evaluating) {
        try builtins.resolvePromiseValue(rt, cap, .undefined);
    }
    return cap;
}

fn innerModuleEvaluation(
    rt: *Runtime,
    mod: *ModuleRecord,
    engine: Engine,
    stack: *std.ArrayList(*ModuleRecord),
    index: u32,
) RuntimeError!u32 {
    switch (mod.status) {
        .evaluated, .evaluating_async, .evaluating => return index,
        .errored => {
            if (mod.eval_error) |v| return rt.throwValue(v);
            return mod.eval_fault.?;
        },
        .linked => {},
        .unlinked, .linking => return rt.bug("evaluating unlinked module"),
    }

    mod.status = .evaluating;
    mod.dfs_index = index;
    mod.dfs_ancestor_index = index;
    mod.pending_async_deps = 0;
    var next_index = index + 1;
    try stack.append(rt.gpa, mod);

    for (mod.deps.items) |dep| {
        next_index = try innerModuleEvaluation(rt, dep, engine, stack, next_index);
        var req = dep;
        if (req.status == .evaluating) {
            mod.dfs_ancestor_index = @min(mod.dfs_ancestor_index, req.dfs_ancestor_index);
        } else {
            req = req.cycle_root orelse req;
            if (req.status == .errored) {
                if (req.eval_error) |v| return rt.throwValue(v);
                return req.eval_fault.?;
            }
        }
        if (req.async_eval_order == .evaluating) {
            mod.pending_async_deps += 1;
            try req.async_parents.append(rt.gpa, mod);
        }
    }

    if (mod.pending_async_deps > 0 or mod.has_tla) {
        rt.modules.async_eval_counter += 1;
        mod.async_eval_order = .{ .evaluating = rt.modules.async_eval_counter };
        if (mod.pending_async_deps == 0) {
            try executeAsyncModule(rt, mod, engine);
        }
    } else {
        try runSyncModuleBody(rt, mod, engine);
    }

    if (mod.dfs_ancestor_index == mod.dfs_index) {
        while (true) {
            const w = stack.pop().?;
            w.status = if (w.async_eval_order == .unset) .evaluated else .evaluating_async;
            w.cycle_root = mod;
            if (w == mod) break;
        }
    }

    return next_index;
}

fn runSyncModuleBody(rt: *Runtime, mod: *ModuleRecord, engine: Engine) RuntimeError!void {
    if (engine == .vm) {
        try runVmModule(rt, mod.proto.?);
    } else {
        try machine.runModuleBody(rt, mod.script, &mod.res, mod.cells, mod);
    }
}

fn runVmModule(rt: *Runtime, proto: *const Proto) RuntimeError!void {
    var vm = try Vm.init(rt, proto);
    defer vm.deinit();
    // Always run as nested so `Vm.run()` does not drain microtasks mid-`InnerModuleEvaluation`
    // (which would let sibling TLA modules settle before the DFS graph finishes).
    vm.nested = true;
    try rt.addRoots(vm.roots());
    defer rt.removeRoots(&vm);
    try vm.run();
}

fn executeAsyncModule(rt: *Runtime, mod: *ModuleRecord, engine: Engine) RuntimeError!void {
    if (mod.status == .errored) return;
    if (!mod.has_tla) {
        runSyncModuleBody(rt, mod, engine) catch |e| {
            return handleAsyncModuleFailure(rt, mod, e);
        };
        try fulfillAsyncModule(rt, mod, engine);
        return;
    }

    const body_p_val = (if (engine == .vm)
        Vm.startTopLevelAsync(rt, mod.proto.?)
    else
        machine.runModuleTopLevelAsync(rt, mod.script, &mod.res, mod.cells, mod)) catch |e| {
        return handleAsyncModuleFailure(rt, mod, e);
    };

    var held = [_]Value{ body_p_val, .undefined, .undefined, .undefined };
    var roots: ValueRoots = .{ .values = &held };
    try roots.register(rt);
    defer roots.unregister(rt);

    const env = try rt.heap.newArray(null);
    held[1] = Value.fromObject(env);
    try rt.heap.appendElements(env, &.{
        Value.fromNumber(@floatFromInt(mod.mod_index)),
        Value.fromNumber(@floatFromInt(@backingInt(engine))),
    });
    const on_ful = try rt.heap.newNativeClosure(&asyncModFulfillCb, env);
    held[2] = Value.fromClosure(on_ful);
    const on_rej = try rt.heap.newNativeClosure(&asyncModRejectCb, env);
    held[3] = Value.fromClosure(on_rej);
    try builtins.performPromiseThen(rt, body_p_val.asObject(), held[2], held[3]);
}

fn handleAsyncModuleFailure(rt: *Runtime, mod: *ModuleRecord, e: RuntimeError) RuntimeError!void {
    if (e == error.Thrown) {
        const val = try rt.catchValue();
        try rejectAsyncModule(rt, mod, val);
        return;
    }
    mod.status = .errored;
    mod.eval_fault = e;
    return e;
}

fn asyncModFulfillCb(rt: *Runtime, env: *heap.Object, _: []const Value) RuntimeError!Value {
    const mod_idx: usize = @intFromFloat(env.kind.array.items[0].asNumber());
    const engine: Engine = @fromBackingInt(@intCast(@as(u8, @intFromFloat(env.kind.array.items[1].asNumber()))));
    const mod = rt.modules.list.items[mod_idx];
    try fulfillAsyncModule(rt, mod, engine);
    return .undefined;
}

fn asyncModRejectCb(rt: *Runtime, env: *heap.Object, args: []const Value) RuntimeError!Value {
    const mod_idx: usize = @intFromFloat(env.kind.array.items[0].asNumber());
    const mod = rt.modules.list.items[mod_idx];
    const reason: Value = if (args.len > 0) args[0] else .undefined;
    try rejectAsyncModule(rt, mod, reason);
    return .undefined;
}

fn gatherAvailableAncestors(
    gpa: Allocator,
    mod: *ModuleRecord,
    exec_list: *std.ArrayList(*ModuleRecord),
) error{OutOfMemory}!void {
    for (mod.async_parents.items) |m| {
        if (m.status == .errored) continue;
        var in_list = false;
        for (exec_list.items) |existing| {
            if (existing == m) {
                in_list = true;
                break;
            }
        }
        if (in_list) continue;
        if (m.pending_async_deps == 0) continue;
        m.pending_async_deps -= 1;
        if (m.pending_async_deps == 0) {
            try exec_list.append(gpa, m);
            if (!m.has_tla) {
                try gatherAvailableAncestors(gpa, m, exec_list);
            }
        }
    }
}

fn fulfillAsyncModule(rt: *Runtime, mod: *ModuleRecord, engine: Engine) RuntimeError!void {
    if (mod.status == .errored) return;
    mod.async_eval_order = .done;
    mod.status = .evaluated;
    if (mod.eval_promise) |ep| {
        try builtins.resolvePromiseValue(rt, ep, .undefined);
    }

    var exec_list: std.ArrayList(*ModuleRecord) = .empty;
    defer exec_list.deinit(rt.gpa);
    try gatherAvailableAncestors(rt.gpa, mod, &exec_list);

    std.mem.sort(*ModuleRecord, exec_list.items, {}, struct {
        fn lt(_: void, a: *ModuleRecord, b: *ModuleRecord) bool {
            return a.async_eval_order.evaluating < b.async_eval_order.evaluating;
        }
    }.lt);

    for (exec_list.items) |m| {
        if (m.status == .errored) continue;
        if (m.has_tla) {
            try executeAsyncModule(rt, m, engine);
        } else {
            runSyncModuleBody(rt, m, engine) catch |e| {
                try handleAsyncModuleFailure(rt, m, e);
                continue;
            };
            m.async_eval_order = .done;
            m.status = .evaluated;
            if (m.eval_promise) |ep| {
                try builtins.resolvePromiseValue(rt, ep, .undefined);
            }
        }
    }
}

fn rejectAsyncModule(rt: *Runtime, mod: *ModuleRecord, reason: Value) RuntimeError!void {
    if (mod.status == .errored) return;
    mod.async_eval_order = .done;
    mod.status = .errored;
    mod.eval_error = reason;
    if (mod.eval_promise) |ep| {
        try builtins.settlePromiseFromJob(rt, ep, true, reason);
    }
    for (mod.async_parents.items) |parent| {
        try rejectAsyncModule(rt, parent, reason);
    }
}

/// Built-in filesystem loader for CLI (`./` and `../` relative to `referrer_id`, normalized).
pub const FsLoader = struct {
    gpa: Allocator,
    io: std.Io,
    max_source_bytes: u32,
    fallback_referrer: ?[]const u8 = null,

    pub fn loader(self: *FsLoader) ModuleLoader {
        return .{ .ctx = self, .load = load };
    }

    fn load(ctx: ?*anyopaque, referrer_id: ?[]const u8, specifier: []const u8) LoadError!LoadedModule {
        if (comptime @import("builtin").os.tag == .freestanding) return error.ModuleNotFound;
        const self: *FsLoader = @ptrCast(@alignCast(ctx.?));
        const resolved = try resolveFsPath(self.gpa, self.io, referrer_id orelse self.fallback_referrer, specifier);
        errdefer self.gpa.free(resolved);

        const source = std.Io.Dir.cwd().readFileAlloc(self.io, resolved, self.gpa, .limited(self.max_source_bytes + 1)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ModuleNotFound,
        };
        if (source.len > self.max_source_bytes) {
            self.gpa.free(source);
            return error.HostError;
        }
        return .{
            .canonical_id = resolved,
            .source = source,
            .free = freeLoaded,
        };
    }

    fn freeLoaded(ctx: ?*anyopaque, canonical_id: []const u8, source: []const u8) void {
        const self: *FsLoader = @ptrCast(@alignCast(ctx.?));
        self.gpa.free(canonical_id);
        self.gpa.free(source);
    }
};

pub fn resolveFsPath(gpa: Allocator, io: std.Io, referrer_id: ?[]const u8, specifier: []const u8) error{ ModuleNotFound, OutOfMemory }![]u8 {
    const is_rel = std.mem.startsWith(u8, specifier, "./") or
        std.mem.startsWith(u8, specifier, "../") or
        std.mem.eql(u8, specifier, ".") or
        std.mem.eql(u8, specifier, "..");

    if (referrer_id == null) {
        if (!is_rel and !std.fs.path.isAbsolute(specifier)) {
            return error.ModuleNotFound;
        }
        if (std.fs.path.isAbsolute(specifier)) return normalizePath(gpa, specifier);
        if (comptime @import("builtin").os.tag == .freestanding) return normalizePath(gpa, specifier);
        const cwd = std.Io.Dir.cwd().realPathFileAlloc(io, ".", gpa) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return normalizePath(gpa, specifier),
        };
        defer gpa.free(cwd);
        const joined = try std.fs.path.join(gpa, &.{ cwd, specifier });
        defer gpa.free(joined);
        return normalizePath(gpa, joined);
    }

    if (!is_rel) {
        if (!std.fs.path.isAbsolute(specifier)) return error.ModuleNotFound;
        return normalizePath(gpa, specifier);
    }

    const dir = std.fs.path.dirname(referrer_id.?) orelse ".";
    const joined = try std.fs.path.join(gpa, &.{ dir, specifier });
    defer gpa.free(joined);
    return normalizePath(gpa, joined);
}

fn normalizePath(gpa: Allocator, path: []const u8) error{OutOfMemory}![]u8 {
    const is_abs = std.fs.path.isAbsolute(path);
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
            } else if (!is_abs) {
                try parts.append(gpa, "..");
            }
            continue;
        }
        try parts.append(gpa, seg);
    }

    if (parts.items.len == 0) {
        return gpa.dupe(u8, if (is_abs) "/" else ".");
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    if (is_abs) try out.append(gpa, '/');
    for (parts.items, 0..) |p, i| {
        if (i > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, p);
    }
    return out.toOwnedSlice(gpa);
}
