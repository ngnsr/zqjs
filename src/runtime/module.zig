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
    imported_name: []const u8,
    span: ast.Span,
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
    import_meta: ?*heap.Object = null,
    status: Status = .unlinked,
    eval_error: ?Value = null,
    eval_fault: ?RuntimeError = null,

    has_tla: bool = false,
    async_eval: bool = false,
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
    ns_reexports: std.StringHashMapUnmanaged(struct { dep: *ModuleRecord, cell: *heap.Cell }) = .empty,
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
        m.ns_reexports.deinit(gpa);
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
            if (m.import_meta) |im| h.markObj(&im.obj);
            if (m.eval_promise) |ep| h.markObj(&ep.obj);
            if (m.eval_error) |v| h.markValue(v);
            var ns_it = m.ns_reexports.valueIterator();
            while (ns_it.next()) |entry| h.markObj(&entry.cell.obj);
            if (m.proto) |p| markProto(p, h);
        }
    }

    fn markProto(p: *const Proto, h: *heap.Heap) void {
        for (p.consts) |c| h.markValue(c);
        for (p.name_atoms) |a| h.markObj(@constCast(&a.obj));
        for (p.repl_cells) |cell| h.markObj(&cell.obj);
        for (p.functions) |*child| markProto(child, h);
    }
};

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
    try evaluateModule(rt, entry, engine);
    if (entry.eval_promise) |ep| {
        var held = [_]Value{Value.fromObject(ep)};
        var roots: ValueRoots = .{ .values = &held };
        try roots.register(rt);
        defer roots.unregister(rt);
        const prev_caller = rt.closure_caller;
        if (engine == .vm and rt.closure_caller == null) {
            rt.closure_caller = .{ .ctx = rt, .call = Vm.callStandalone, .construct = Vm.constructStandalone };
        }
        defer rt.closure_caller = prev_caller;
        try rt.drainMicrotasks();
        switch (ep.kind.promise.state) {
            .fulfilled => {},
            .rejected => return rt.throwValue(ep.kind.promise.result),
            .pending => {},
        }
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
                    is_import[ri] = true;
                    try m.import_links.append(gpa, .{ .repl_idx = ri, .dep = dep, .imported_name = null, .span = nb.span });
                }
                for (imp.named) |sp| {
                    const ri = m.res.bindings[sp.local.binding].repl_index.?;
                    is_import[ri] = true;
                    try m.import_links.append(gpa, .{ .repl_idx = ri, .dep = dep, .imported_name = sp.imported, .span = sp.span });
                }
            },
            .export_decl => |exp| switch (exp) {
                .reexport_named => |rn| {
                    const dep = m.deps.items[dep_idx];
                    dep_idx += 1;
                    for (rn.specifiers) |sp| {
                        try m.indirect_exports.put(gpa, sp.exported, .{
                            .dep = dep,
                            .imported_name = sp.imported,
                            .span = sp.span,
                        });
                    }
                },
                .reexport_all => |ra| {
                    const dep = m.deps.items[dep_idx];
                    dep_idx += 1;
                    if (ra.namespace) |ns_name| {
                        const cell = rt.heap.newCell(null) catch |e| return mapHeapErr(e, rt);
                        try m.ns_reexports.put(gpa, ns_name, .{ .dep = dep, .cell = cell });
                        try m.local_exports.put(gpa, ns_name, cell);
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
                try m.local_exports.put(gpa, f.name.?.name, m.cells[ri]);
            },
            .class => |cls| {
                const ri = m.res.bindings[cls.name.?.binding].repl_index.?;
                try m.local_exports.put(gpa, cls.name.?.name, m.cells[ri]);
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
                try m.local_exports.put(gpa, sp.exported, m.cells[ri]);
            },
            .reexport_named, .reexport_all => {},
        };
    }

    // Step 2: Populate `export * as ns` cells, and resolve all imports & indirect re-exports across the graph.
    for (mods) |m| {
        var ns_it = m.ns_reexports.valueIterator();
        while (ns_it.next()) |entry| {
            const ns_obj = getNamespace(rt, entry.dep) catch |e| return mapRuntimeToModErr(e);
            rt.heap.storeCell(entry.cell, Value.fromObject(ns_obj));
        }
        for (m.import_links.items) |link| {
            if (link.imported_name) |imp_name| {
                const resolved = try resolveExportTop(gpa, link.dep, imp_name);
                switch (resolved) {
                    .resolved => |r| m.cells[link.repl_idx] = r.cell,
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
                m.cells[link.repl_idx] = rt.heap.newCell(Value.fromObject(ns_obj)) catch |e| return mapHeapErr(e, rt);
            }
        }

        var ind_it = m.indirect_exports.iterator();
        while (ind_it.next()) |entry| {
            const ind = entry.value_ptr.*;
            const resolved = try resolveExportTop(gpa, ind.dep, ind.imported_name);
            switch (resolved) {
                .resolved => {},
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

fn addPatternExports(gpa: Allocator, m: *ModuleRecord, pat: *const ast.Pattern) Allocator.Error!void {
    switch (pat.data) {
        .binding => |d| {
            const ri = m.res.bindings[d.binding].repl_index.?;
            try m.local_exports.put(gpa, d.name, m.cells[ri]);
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
        return resolveExport(gpa, ind.dep, ind.imported_name, visited);
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
                .ambiguous => unreachable,
            },
        }
    }
    return star_res;
}

pub fn getNamespace(rt: *Runtime, mod: *ModuleRecord) RuntimeError!*heap.Object {
    if (mod.namespace) |ns| return ns;

    var names: std.StringHashMapUnmanaged(*heap.Cell) = .empty;
    defer names.deinit(rt.gpa);
    var visited: std.AutoHashMapUnmanaged(*const ModuleRecord, void) = .empty;
    defer visited.deinit(rt.gpa);

    try collectExportedNames(rt.gpa, mod, &names, &visited, false);

    var entries: std.ArrayList(heap.ModuleExport) = .empty;
    defer entries.deinit(rt.gpa);

    var it = names.iterator();
    while (it.next()) |e| {
        const atom = try rt.heap.internAscii(e.key_ptr.*);
        try entries.append(rt.gpa, .{ .name = atom, .cell = e.value_ptr.* });
    }

    std.mem.sort(heap.ModuleExport, entries.items, {}, struct {
        fn lt(_: void, a: heap.ModuleExport, b: heap.ModuleExport) bool {
            return std.mem.order(u16, a.name.units, b.name.units) == .lt;
        }
    }.lt);

    const ns_obj = try rt.heap.newModuleNamespace(entries.items);
    const realm = try builtins.realm(rt);
    const tag_str = try rt.heap.internAscii("Module");
    try rt.heap.definePropKey(ns_obj, heap.PropKey.fromSymbol(realm.sym_to_string_tag), .{
        .value = Value.fromString(tag_str),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    mod.namespace = ns_obj;
    return ns_obj;
}

fn collectExportedNames(
    gpa: Allocator,
    mod: *const ModuleRecord,
    out: *std.StringHashMapUnmanaged(*heap.Cell),
    visited: *std.AutoHashMapUnmanaged(*const ModuleRecord, void),
    via_star: bool,
) error{OutOfMemory}!void {
    if (visited.contains(mod)) return;
    try visited.put(gpa, mod, {});

    var loc_it = mod.local_exports.iterator();
    while (loc_it.next()) |e| {
        if (via_star and std.mem.eql(u8, e.key_ptr.*, "default")) continue;
        if (!out.contains(e.key_ptr.*)) {
            try out.put(gpa, e.key_ptr.*, e.value_ptr.*);
        }
    }

    var ind_it = mod.indirect_exports.iterator();
    while (ind_it.next()) |e| {
        if (via_star and std.mem.eql(u8, e.key_ptr.*, "default")) continue;
        if (!out.contains(e.key_ptr.*)) {
            if (try resolveExportTop(gpa, e.value_ptr.dep, e.value_ptr.imported_name) == .resolved) {
                const res = try resolveExportTop(gpa, e.value_ptr.dep, e.value_ptr.imported_name);
                try out.put(gpa, e.key_ptr.*, res.resolved.cell);
            }
        }
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

    var held = [_]Value{ Value.fromObject(p), specifier_val, .undefined, .undefined, .undefined };
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

    const spec_utf8 = std.unicode.utf16LeToUtf8Alloc(rt.gpa, spec_str_val.asString().units) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try rejectPromiseWithError(rt, p, .TypeError, "Invalid module specifier");
            return p;
        },
    };
    defer rt.gpa.free(spec_utf8);

    const referrer_id: ?[]const u8 = if (referrer_mod) |rm| rm.canonical_id else null;
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
            return p;
        },
        error.ModuleNotFound => {
            try rejectPromiseWithError(rt, p, .TypeError, "Cannot find module");
            return p;
        },
        error.HostError => {
            try rejectPromiseWithError(rt, p, .TypeError, "Module load failed");
            return p;
        },
    };

    switch (target_mod.status) {
        .evaluated => {
            const ns = try getNamespace(rt, target_mod);
            held[2] = Value.fromObject(ns);
            try builtins.resolvePromiseValue(rt, p, held[2]);
            return p;
        },
        .errored => {
            if (target_mod.eval_error) |v| {
                try builtins.settlePromiseFromJob(rt, p, true, v);
                return p;
            }
            return target_mod.eval_fault.?;
        },
        .evaluating => {
            const ns = try getNamespace(rt, target_mod);
            held[2] = Value.fromObject(ns);
            try builtins.resolvePromiseValue(rt, p, held[2]);
            return p;
        },
        .evaluating_async => {
            try attachDynImportReaction(rt, target_mod, p, &held);
            return p;
        },
        .linked => {
            evaluateModule(rt, target_mod, engine) catch |e| switch (e) {
                error.Thrown => {
                    const err_val = try rt.catchValue();
                    try builtins.settlePromiseFromJob(rt, p, true, err_val);
                    return p;
                },
                else => return e,
            };
            switch (target_mod.status) {
                .evaluated => {
                    const ns = try getNamespace(rt, target_mod);
                    held[2] = Value.fromObject(ns);
                    try builtins.resolvePromiseValue(rt, p, held[2]);
                },
                .evaluating_async => try attachDynImportReaction(rt, target_mod, p, &held),
                .errored => {
                    if (target_mod.eval_error) |v| {
                        try builtins.settlePromiseFromJob(rt, p, true, v);
                    } else {
                        return target_mod.eval_fault.?;
                    }
                },
                else => unreachable,
            }
            return p;
        },
        .unlinked, .linking => return rt.bug("evaluating unlinked module"),
    }
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

fn attachDynImportReaction(rt: *Runtime, target: *ModuleRecord, result_p: *heap.Object, held: *[5]Value) RuntimeError!void {
    const ep = target.eval_promise orelse return rt.bug("evaluating_async module missing eval_promise");
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

pub fn evaluateModule(rt: *Runtime, mod: *ModuleRecord, engine: Engine) RuntimeError!void {
    switch (mod.status) {
        .evaluated, .evaluating, .evaluating_async => return,
        .errored => {
            if (mod.eval_error) |v| return rt.throwValue(v);
            return mod.eval_fault.?;
        },
        .linked => {},
        .unlinked, .linking => return rt.bug("evaluating unlinked module"),
    }

    var stack: std.ArrayList(*ModuleRecord) = .empty;
    defer stack.deinit(rt.gpa);

    _ = innerModuleEvaluation(rt, mod, engine, &stack, 0) catch |e| {
        const err_val: ?Value = if (e == error.Thrown) (rt.catchValue() catch null) else null;
        for (stack.items) |w| {
            if (w.status == .evaluating) {
                w.status = .errored;
                if (err_val) |v| w.eval_error = v else w.eval_fault = e;
            }
        }
        if (err_val) |v| return rt.throwValue(v);
        return e;
    };
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
        if (dep.status == .evaluating) {
            mod.dfs_ancestor_index = @min(mod.dfs_ancestor_index, dep.dfs_ancestor_index);
        } else {
            const dep_root = dep.cycle_root orelse dep;
            if (dep_root.status == .errored) {
                if (dep_root.eval_error) |v| return rt.throwValue(v);
                return dep_root.eval_fault.?;
            }
            if (dep_root.async_eval) {
                mod.pending_async_deps += 1;
                try dep_root.async_parents.append(rt.gpa, mod);
            }
        }
    }

    if (mod.pending_async_deps > 0 or mod.has_tla) {
        mod.async_eval = true;
    }

    if (mod.dfs_ancestor_index == mod.dfs_index) {
        var scc: std.ArrayList(*ModuleRecord) = .empty;
        defer scc.deinit(rt.gpa);
        var has_async = false;
        while (true) {
            const w = stack.pop().?;
            w.cycle_root = mod;
            if (w.async_eval) has_async = true;
            try scc.append(rt.gpa, w);
            if (w == mod) break;
        }

        if (!has_async) {
            for (scc.items) |w| {
                runSyncModuleBody(rt, w, engine) catch |e| {
                    w.status = .errored;
                    if (e == error.Thrown) {
                        if (rt.catchValue()) |val| {
                            w.eval_error = val;
                            _ = rt.throwValue(val) catch {};
                        } else |_| {
                            w.eval_fault = e;
                        }
                    } else {
                        w.eval_fault = e;
                    }
                    return e;
                };
                w.status = .evaluated;
            }
        } else {
            const r = try builtins.realm(rt);
            for (scc.items) |w| {
                w.async_eval = true;
                w.status = .evaluating_async;
                if (w.eval_promise == null) {
                    w.eval_promise = try rt.heap.newPromise(r.promise_prototype);
                }
            }
            // In a cycle with TLA, a non-TLA member depending on a TLA member in the same SCC must wait for it.
            for (scc.items) |w| {
                if (!w.has_tla and w.pending_async_deps == 0) {
                    for (w.deps.items) |dep| {
                        if (dep != w and dep.cycle_root == mod and dep.has_tla) {
                            w.pending_async_deps += 1;
                            try dep.async_parents.append(rt.gpa, w);
                        }
                    }
                }
            }
            for (scc.items) |w| {
                if (w.pending_async_deps == 0) {
                    try executeAsyncModule(rt, w, engine);
                }
            }
        }
    }

    return next_index;
}

fn runSyncModuleBody(rt: *Runtime, mod: *ModuleRecord, engine: Engine) RuntimeError!void {
    if (engine == .vm) {
        try runVmModule(rt, mod.proto.?, true);
    } else {
        try machine.runModule(rt, mod.script, &mod.res, mod.cells, mod);
    }
}

fn runAsyncDepSyncBody(rt: *Runtime, mod: *ModuleRecord, engine: Engine) RuntimeError!void {
    if (engine == .vm) {
        try runVmModule(rt, mod.proto.?, false);
    } else {
        try machine.runModuleBody(rt, mod.script, &mod.res, mod.cells, mod);
    }
}

fn runVmModule(rt: *Runtime, proto: *const Proto, drain: bool) RuntimeError!void {
    var vm = try Vm.init(rt, proto);
    defer vm.deinit();
    const is_nested = rt.engine_roots != null;
    if (is_nested) {
        vm.nested = true;
        try rt.addRoots(vm.roots());
    }
    defer if (is_nested) rt.removeRoots(&vm);
    try vm.run();
    if (drain) try rt.drainMicrotasks();
}

fn executeAsyncModule(rt: *Runtime, mod: *ModuleRecord, engine: Engine) RuntimeError!void {
    if (mod.status == .errored) return;
    if (!mod.has_tla) {
        runAsyncDepSyncBody(rt, mod, engine) catch |e| {
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

fn fulfillAsyncModule(rt: *Runtime, mod: *ModuleRecord, engine: Engine) RuntimeError!void {
    if (mod.status == .errored) return;
    mod.status = .evaluated;
    if (mod.eval_promise) |ep| {
        try builtins.resolvePromiseValue(rt, ep, .undefined);
    }
    for (mod.async_parents.items) |parent| {
        if (parent.status != .evaluating_async) continue;
        parent.pending_async_deps -= 1;
        if (parent.pending_async_deps == 0) {
            try executeAsyncModule(rt, parent, engine);
        }
    }
}

fn rejectAsyncModule(rt: *Runtime, mod: *ModuleRecord, reason: Value) RuntimeError!void {
    if (mod.status == .errored) return;
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

    pub fn loader(self: *FsLoader) ModuleLoader {
        return .{ .ctx = self, .load = load };
    }

    fn load(ctx: ?*anyopaque, referrer_id: ?[]const u8, specifier: []const u8) LoadError!LoadedModule {
        const self: *FsLoader = @ptrCast(@alignCast(ctx.?));
        const resolved = try resolveFsPath(self.gpa, self.io, referrer_id, specifier);
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
