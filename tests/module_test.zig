//! ES Modules (M42, D72) integration tests on both VM and tree-walking Machine.

const std = @import("std");
const testing = std.testing;
const zqjs = @import("zqjs_internal");
const module = zqjs.module;
const Runtime = zqjs.Runtime;
const Limits = zqjs.Limits;
const Engine = zqjs.Engine;

const MemEntry = struct {
    id: []const u8,
    src: []const u8,
};

const MemLoader = struct {
    entries: []const MemEntry,

    fn loader(self: *const MemLoader) module.ModuleLoader {
        return .{ .ctx = @constCast(self), .load = load };
    }

    fn load(ctx: ?*anyopaque, referrer_id: ?[]const u8, specifier: []const u8) module.LoadError!module.LoadedModule {
        const self: *const MemLoader = @ptrCast(@alignCast(ctx.?));
        const key = resolveRel(referrer_id, specifier);
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.id, key)) {
                return .{ .canonical_id = e.id, .source = e.src };
            }
        }
        return error.ModuleNotFound;
    }

    fn resolveRel(_: ?[]const u8, specifier: []const u8) []const u8 {
        if (std.mem.startsWith(u8, specifier, "./")) return specifier[2..];
        return specifier;
    }
};

fn runMemModules(
    gpa: std.mem.Allocator,
    entries: []const MemEntry,
    entry_id: []const u8,
    entry_src: []const u8,
    engine: Engine,
    limits: Limits,
) !struct { out: []u8, err: ?anyerror, diag: module.ModuleDiag } {
    var out_buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer out_buf.deinit();

    var rt = Runtime.init(gpa, limits, &out_buf.writer);
    defer rt.deinit();
    rt.stack_base = @frameAddress();

    const ml: MemLoader = .{ .entries = entries };
    rt.modules.loader = ml.loader();

    var mod_diag: module.ModuleDiag = .{};
    _ = module.runEntry(&rt, entry_id, entry_src, engine, &mod_diag) catch |e| {
        return .{ .out = try out_buf.toOwnedSlice(), .err = e, .diag = mod_diag };
    };
    return .{ .out = try out_buf.toOwnedSlice(), .err = null, .diag = mod_diag };
}

fn expectBothEngines(entries: []const MemEntry, entry_id: []const u8, entry_src: []const u8, expected_out: []const u8) !void {
    for ([_]Engine{ .vm, .treewalk }) |engine| {
        const res = try runMemModules(testing.allocator, entries, entry_id, entry_src, engine, .{});
        defer testing.allocator.free(res.out);
        if (res.err) |e| {
            std.debug.print("engine {s} failed with {s}\n", .{ @tagName(engine), @errorName(e) });
            return e;
        }
        try testing.expectEqualStrings(expected_out, res.out);
    }
}

fn expectBothEnginesErr(entries: []const MemEntry, entry_id: []const u8, entry_src: []const u8, expected_err: anyerror) !void {
    for ([_]Engine{ .vm, .treewalk }) |engine| {
        const res = try runMemModules(testing.allocator, entries, entry_id, entry_src, engine, .{});
        defer testing.allocator.free(res.out);
        try testing.expectEqual(@as(?anyerror, expected_err), res.err);
    }
}

test "M42: named exports, aliasing, default exports, and side-effect imports" {
    const entries = [_]MemEntry{
        .{ .id = "side.js", .src = "print('side');" },
        .{ .id = "math.js", .src =
        \\export const pi = 3;
        \\export let x = 10;
        \\function add(a, b) { return a + b; }
        \\export { add as sum };
        \\export default function() { return 42; }
        },
        .{ .id = "cls.js", .src =
        \\export default class { value() { return 7; } }
        },
        .{ .id = "expr.js", .src =
        \\export default 100 + 23;
        },
    };
    const main_src =
        \\import './side.js';
        \\import defFn, { pi, sum as add } from './math.js';
        \\import DefCls from './cls.js';
        \\import exprVal from './expr.js';
        \\print(pi, add(2, 3), defFn(), defFn.name);
        \\print(new DefCls().value(), DefCls.name, exprVal);
    ;
    try expectBothEngines(&entries, "main.js", main_src, "side\n3 5 42 default\n7 default 123\n");
}

test "M42: live bindings (mutation visible in importer, importer write throws TypeError)" {
    const entries = [_]MemEntry{
        .{ .id = "counter.js", .src =
        \\export let count = 0;
        \\export function inc() { count += 1; }
        },
    };
    const main_src =
        \\import { count, inc } from './counter.js';
        \\print(count);
        \\inc();
        \\print(count);
        \\inc();
        \\print(count);
        \\let caught = false;
        \\try {
        \\    count = 99;
        \\} catch (e) {
        \\    caught = (e instanceof TypeError);
        \\}
        \\print(caught, count);
    ;
    try expectBothEngines(&entries, "main.js", main_src, "0\n1\n2\ntrue 2\n");
}

test "M42: re-exports (named, default, export *, export * as ns, diamond deduplication)" {
    const entries = [_]MemEntry{
        .{ .id = "base.js", .src =
        \\export const a = 1;
        \\export const b = 2;
        \\export default 'def';
        },
        .{ .id = "left.js", .src = "export * from './base.js';" },
        .{ .id = "right.js", .src = "export * from './base.js';" },
        .{ .id = "re.js", .src =
        \\export * from './left.js';
        \\export * from './right.js';
        \\export { default, default as defAlias, b as renamedB } from './base.js';
        \\export * as baseNs from './base.js';
        },
    };
    const main_src =
        \\import def, { a, renamedB, defAlias, baseNs } from './re.js';
        \\print(def, a, renamedB, defAlias, baseNs.a, baseNs.default);
    ;
    try expectBothEngines(&entries, "main.js", main_src, "def 1 2 def 1 def\n");
}

test "M42: ambiguous export * and missing export are SyntaxError" {
    const amb_entries = [_]MemEntry{
        .{ .id = "a.js", .src = "export const x = 1;" },
        .{ .id = "b.js", .src = "export const x = 2;" },
        .{ .id = "c.js", .src = "export * from './a.js'; export * from './b.js';" },
    };
    try expectBothEnginesErr(&amb_entries, "main.js", "import { x } from './c.js';", error.SyntaxError);

    const miss_entries = [_]MemEntry{
        .{ .id = "a.js", .src = "export const x = 1;" },
    };
    try expectBothEnginesErr(&miss_entries, "main.js", "import { y } from './a.js';", error.SyntaxError);
}

test "M42: circular dependencies (hoisted functions work, TDZ throws ReferenceError)" {
    const fn_entries = [_]MemEntry{
        .{ .id = "even.js", .src =
        \\import { isOdd } from './odd.js';
        \\export function isEven(n) { return n === 0 ? true : isOdd(n - 1); }
        },
        .{ .id = "odd.js", .src =
        \\import { isEven } from './even.js';
        \\export function isOdd(n) { return n === 0 ? false : isEven(n - 1); }
        },
    };
    try expectBothEngines(&fn_entries, "main.js", "import { isEven } from './even.js'; print(isEven(4), isEven(5));", "true false\n");

    const tdz_entries = [_]MemEntry{
        .{ .id = "a.js", .src =
        \\import { bVal } from './b.js';
        \\export let aVal = 10;
        \\print('a:', bVal);
        },
        .{ .id = "b.js", .src =
        \\import { aVal } from './a.js';
        \\export let bVal = 20;
        \\try { print(aVal); } catch (e) { print('tdz:', e instanceof ReferenceError); }
        },
    };
    try expectBothEngines(&tdz_entries, "main.js", "import './a.js';", "tdz: true\na: 20\n");
}

test "M42: module namespace exotic object" {
    const entries = [_]MemEntry{
        .{ .id = "m.js", .src =
        \\export let z = 1;
        \\export const a = 2;
        \\export default 3;
        \\export function setZ(v) { z = v; }
        },
    };
    const main_src =
        \\import * as ns from './m.js';
        \\print(Object.keys(ns).join(','));
        \\print(Object.getPrototypeOf(ns) === null);
        \\print(Object.isExtensible(ns), Object.isSealed(ns));
        \\print(Object.prototype.toString.call(ns));
        \\print(ns.a, ns.z, ns.default);
        \\ns.setZ(99);
        \\print(ns.z);
        \\const forInKeys = [];
        \\for (const k in ns) forInKeys.push(k);
        \\print(forInKeys.join(','));
        \\print(delete ns.a);
    ;
    try expectBothEngines(
        &entries,
        "main.js",
        main_src,
        "a,default,setZ,z\ntrue\nfalse true\n[object Module]\n2 1 3\n99\na,default,setZ,z\nfalse\n",
    );
}

test "M42: diamond dependency graph evaluates shared module exactly once in post-order" {
    const entries = [_]MemEntry{
        .{ .id = "shared.js", .src = "print('shared'); export const v = 1;" },
        .{ .id = "left.js", .src = "import { v } from './shared.js'; print('left'); export const lv = v + 1;" },
        .{ .id = "right.js", .src = "import { v } from './shared.js'; print('right'); export const rv = v + 2;" },
    };
    const main_src =
        \\import { lv } from './left.js';
        \\import { rv } from './right.js';
        \\print('main', lv, rv);
    ;
    try expectBothEngines(&entries, "main.js", main_src, "shared\nleft\nright\nmain 2 3\n");
}

test "M42: async/await, generators, classes, and top-level this across modules" {
    const entries = [_]MemEntry{
        .{ .id = "lib.js", .src =
        \\export const topThis = this;
        \\export const arrowThis = () => this;
        \\export async function asyncAdd(a, b) { return await Promise.resolve(a + b); }
        \\export function* gen() { yield 1; yield 2; }
        \\export class Box { constructor(v) { this.v = v; } }
        },
    };
    const main_src =
        \\import { topThis, arrowThis, asyncAdd, gen, Box } from './lib.js';
        \\print(this === undefined, topThis === undefined, arrowThis() === undefined);
        \\print([...gen()].join(','));
        \\print(new Box(42).v);
        \\asyncAdd(10, 20).then(v => print(v));
    ;
    try expectBothEngines(&entries, "main.js", main_src, "true true true\n1,2\n42\n30\n");
}

test "M42: module early syntax errors and intentional unsupported boundaries" {
    // Duplicate export
    try expectBothEnginesErr(&.{}, "main.js", "export const a = 1; export const a = 2;", error.SyntaxError);
    try expectBothEnginesErr(&.{}, "main.js", "export default 1; export default 2;", error.SyntaxError);
    // Export undefined local
    try expectBothEnginesErr(&.{}, "main.js", "export { missing };", error.SyntaxError);
    // Duplicate import binding / redeclared import
    const dup_imp = [_]MemEntry{.{ .id = "a.js", .src = "export const x = 1;" }};
    try expectBothEnginesErr(&dup_imp, "main.js", "import { x, x } from './a.js';", error.SyntaxError);
    try expectBothEnginesErr(&dup_imp, "main.js", "import { x } from './a.js'; let x = 2;", error.SyntaxError);
    // Dynamic import and import.meta -> Unsupported
    try expectBothEnginesErr(&.{}, "main.js", "import('./a.js');", error.Unsupported);
    try expectBothEnginesErr(&.{}, "main.js", "import.meta;", error.Unsupported);
}

test "M42: Limits.max_modules enforced" {
    const entries = [_]MemEntry{
        .{ .id = "a.js", .src = "import './b.js';" },
        .{ .id = "b.js", .src = "export const x = 1;" },
    };
    for ([_]Engine{ .vm, .treewalk }) |engine| {
        const res = try runMemModules(testing.allocator, &entries, "main.js", "import './a.js';", engine, .{ .max_modules = 2 });
        defer testing.allocator.free(res.out);
        try testing.expectEqual(@as(?anyerror, error.LimitExceeded), res.err);
    }
}

test "M42: allocation failure handling (OOM) leaks nothing" {
    const entries = [_]MemEntry{
        .{ .id = "dep.js", .src = "export let x = 10; export function f() { return x; }" },
    };
    const main_src =
        \\import * as ns from './dep.js';
        \\import { f } from './dep.js';
        \\print(ns.x, f());
    ;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: std.mem.Allocator) !void {
            const res = runMemModules(alloc, &entries, "main.js", main_src, .vm, .{}) catch |e| return e;
            defer alloc.free(res.out);
            if (res.err) |e| {
                if (e == error.OutOfMemory or e == error.WriteFailed) return error.OutOfMemory;
                return e;
            }
            try testing.expectEqualStrings("10 10\n", res.out);
        }
    }.run, .{});
}
