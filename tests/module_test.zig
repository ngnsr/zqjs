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
        \\print(Reflect.deleteProperty(ns, 'a'));
        \\try { delete ns.a; print('no-throw'); } catch (e) { print(e instanceof TypeError); }
    ;
    try expectBothEngines(
        &entries,
        "main.js",
        main_src,
        "a,default,setZ,z\ntrue\nfalse true\n[object Module]\n2 1 3\n99\na,default,setZ,z\nfalse\ntrue\n",
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
    // Dynamic import with 2nd options argument -> Unsupported; invalid import.foo -> SyntaxError
    try expectBothEnginesErr(&.{}, "main.js", "import('./a.js', {});", error.Unsupported);
    try expectBothEnginesErr(&.{}, "main.js", "import.foo;", error.SyntaxError);
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

test "M48: import.meta identity, prototype, url, nested closures, and mutability" {
    const entries = [_]MemEntry{
        .{ .id = "sub/mod.js", .src =
        \\export const getMeta = () => import.meta;
        \\export function getUrl() { return import.meta.url; }
        },
    };
    const main_src =
        \\import { getMeta, getUrl } from './sub/mod.js';
        \\print(Object.getPrototypeOf(import.meta) === null);
        \\print(import.meta === import.meta);
        \\print(import.meta.url);
        \\import.meta.custom = 123;
        \\function inner() { return import.meta.custom; }
        \\print(inner(), import.meta?.url);
        \\const m2 = getMeta();
        \\print(m2 === getMeta(), m2 !== import.meta, getUrl());
    ;
    try expectBothEngines(
        &entries,
        "main.js",
        main_src,
        "true\ntrue\nmain.js\n123 main.js\ntrue true sub/mod.js\n",
    );
}

test "M48: dynamic import() from modules, nested closures, Promise.all, namespace identity, and errors" {
    const entries = [_]MemEntry{
        .{ .id = "dep.js", .src = "export let count = 1; export function inc() { count++; }" },
        .{ .id = "a.js", .src = "export const v = 'A';" },
        .{ .id = "b.js", .src = "export const v = 'B';" },
        .{ .id = "bad_syntax.js", .src = "export const x = ;" },
        .{ .id = "throws.js", .src = "throw new Error('boom');" },
    };
    const main_src =
        \\import * as staticNs from './dep.js';
        \\async function loadDep() { return await import('./dep.js'); }
        \\const dynNs = await loadDep();
        \\print(dynNs === staticNs, dynNs.count);
        \\staticNs.inc();
        \\print(dynNs.count);
        \\const [pa, pb] = await Promise.all([import('./a.js'), import('./b.js')]);
        \\print(pa.v, pb.v);
        \\try { await import('./missing.js'); print('nope1'); } catch (e) { print('err1', e instanceof TypeError); }
        \\try { await import('./bad_syntax.js'); print('nope2'); } catch (e) { print('err2', e instanceof SyntaxError); }
        \\try { await import('./throws.js'); print('nope3'); } catch (e) { print('err3', e.message); }
        \\try { await import({ toString() { throw new Error('tostr'); } }); print('nope4'); } catch (e) { print('err4', e.message); }
        \\try { await import(Symbol('s')); print('nope5'); } catch (e) { print('err5', e instanceof TypeError); }
    ;
    try expectBothEngines(
        &entries,
        "main.js",
        main_src,
        "true 1\n2\nA B\nerr1 true\nerr2 true\nerr3 boom\nerr4 tostr\nerr5 true\n",
    );
}

test "M48: dynamic import() from plain script (both engines)" {
    const entries = [_]MemEntry{
        .{ .id = "lib.js", .src = "export const answer = 42;" },
    };
    for ([_]Engine{ .vm, .treewalk }) |engine| {
        var out_buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out_buf.deinit();
        var rt = Runtime.init(testing.allocator, .{}, &out_buf.writer);
        defer rt.deinit();
        rt.stack_base = @frameAddress();
        const ml: MemLoader = .{ .entries = &entries };
        rt.modules.loader = ml.loader();

        const src = "import('./lib.js').then(ns => print(ns.answer));";
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var diag: zqjs.Diagnostic = .{};
        const script = try zqjs.parse(arena.allocator(), src, .{}, &diag);
        const res = try zqjs.resolve(arena.allocator(), script, &diag);
        if (engine == .vm) {
            var p = try zqjs.compile(testing.allocator, &rt.heap, script, res, .{}, &diag);
            defer p.deinit(testing.allocator);
            var vm = try zqjs.Vm.init(&rt, &p);
            defer vm.deinit();
            try vm.run();
            try rt.drainMicrotasks();
        } else {
            try zqjs.interpret(&rt, script, res);
        }
        try testing.expectEqualStrings("42\n", out_buf.written());
    }
}

test "M48: top-level await, for await, linear/diamond/parallel TLA, sync->TLA, and cycles" {
    // 1. Single TLA + for await + linear chain
    const entries1 = [_]MemEntry{
        .{ .id = "b.js", .src =
        \\print('b1');
        \\export const val = await Promise.resolve(21);
        \\print('b2');
        },
        .{ .id = "a.js", .src =
        \\import { val } from './b.js';
        \\print('a1', val);
        \\const asyncIter = {
        \\  [Symbol.asyncIterator]() {
        \\    let i = 0;
        \\    return { next() { i++; return Promise.resolve(i <= 2 ? { value: i, done: false } : { value: undefined, done: true }); } };
        \\  }
        \\};
        \\let sum = 0;
        \\for await (const x of asyncIter) sum += x;
        \\export const total = val + sum;
        \\print('a2', total);
        },
    };
    try expectBothEngines(
        &entries1,
        "main.js",
        "import { total } from './a.js'; print('main', total);",
        "b1\nb2\na1 21\na2 24\nmain 24\n",
    );

    // 2. Diamond & parallel sibling TLA ordering + sync module importing TLA module
    const entries2 = [_]MemEntry{
        .{ .id = "s1.js", .src = "print('s1 start'); export const x = await Promise.resolve(1); print('s1 end');" },
        .{ .id = "s2.js", .src = "print('s2 start'); export const y = await Promise.resolve(2); print('s2 end');" },
        .{ .id = "sync_mid.js", .src = "import { x } from './s1.js'; export const x2 = x * 10; print('sync_mid', x2);" },
    };
    try expectBothEngines(
        &entries2,
        "main.js",
        "import { x2 } from './sync_mid.js'; import { y } from './s2.js'; print('main', x2, y);",
        "s1 start\ns2 start\ns1 end\ns2 end\nsync_mid 10\nmain 10 2\n",
    );

    // 3. TLA rejection propagates to parent and entry
    const entries3 = [_]MemEntry{
        .{ .id = "fail_tla.js", .src = "await Promise.reject(new Error('tla_fail')); export const x = 1;" },
    };
    try expectBothEnginesErr(&entries3, "main.js", "import { x } from './fail_tla.js'; print(x);", error.Thrown);

    // 4. Circular dependency with TLA
    const entries4 = [_]MemEntry{
        .{ .id = "cyc_b.js", .src =
        \\import { fromA } from './cyc_a.js';
        \\export const fromB = await Promise.resolve(10);
        \\export function readA() { return fromA(); }
        },
        .{ .id = "cyc_a.js", .src =
        \\import { fromB } from './cyc_b.js';
        \\export function fromA() { return 5; }
        \\print('cyc_a', fromB);
        },
    };
    try expectBothEngines(&entries4, "cyc_a.js", entries4[1].src, "cyc_a 10\n");

    // 5. Dynamic import of a TLA module
    const entries5 = [_]MemEntry{
        .{ .id = "tla_dyn.js", .src = "export const v = await Promise.resolve('async_ok');" },
    };
    try expectBothEngines(&entries5, "main.js", "const ns = await import('./tla_dyn.js'); print(ns.v);", "async_ok\n");
}

test "Test262 module conformance: ambiguous bindings, namespace re-exports, unicode sort (both engines)" {
    // 1. Ambiguous star re-exports are omitted from namespace object
    const ambig_entries = [_]MemEntry{
        .{ .id = "a.js", .src = "export const first = 1; export const both = 'a';" },
        .{ .id = "b.js", .src = "export const second = 2; export const both = 'b';" },
        .{ .id = "re.js", .src = "export * from './a.js'; export * from './b.js';" },
    };
    try expectBothEngines(
        &ambig_entries,
        "main.js",
        "import * as ns from './re.js'; print('first' in ns, 'second' in ns, 'both' in ns, Object.keys(ns).join(','));",
        "true true false first,second\n",
    );

    // 2. Same namespace re-exported via `export * as` and `import * as; export { ... }` is unambiguous
    const ns_unambig_entries = [_]MemEntry{
        .{ .id = "target.js", .src = "export const v = 42;" },
        .{ .id = "f1.js", .src = "export * as foo from './target.js';" },
        .{ .id = "f2.js", .src = "import * as t from './target.js'; export { t as foo };" },
        .{ .id = "re.js", .src = "export * from './f1.js'; export * from './f2.js';" },
    };
    try expectBothEngines(
        &ns_unambig_entries,
        "main.js",
        "import { foo } from './re.js'; print(typeof foo, foo.v);",
        "object 42\n",
    );

    // 3. Mutual `export * as` cycle does not infinitely recurse in getNamespace
    const mutual_ns_entries = [_]MemEntry{
        .{ .id = "a.js", .src = "export const x = 1; export * as b from './b.js';" },
        .{ .id = "b.js", .src = "export const y = 2; export * as a from './a.js';" },
    };
    try expectBothEngines(
        &mutual_ns_entries,
        "main.js",
        "import * as a from './a.js'; print(a.x, a.b.y, a.b.a === a);",
        "1 2 true\n",
    );

    // 4. Unicode & escaped export names sort in UTF-16 code-unit order
    const sort_entries = [_]MemEntry{
        .{ .id = "u.js", .src = "var x = 1; export { x as π, x as \\u03bc, x as λ, x as _, x as $ }; export default null;" },
    };
    try expectBothEngines(
        &sort_entries,
        "main.js",
        "import * as ns from './u.js'; print(Object.getOwnPropertyNames(ns).map(k => k.charCodeAt(0)).join(','));",
        "36,95,100,955,956,960\n",
    );
}

test "Test262 module conformance: TLA ordering, cycles, errored cycle dynamic import, DFS (both engines)" {
    // 1. Async module does not block sibling sync module
    const sibling_entries = [_]MemEntry{
        .{ .id = "tla.js", .src = "globalThis.flag = false; await 0; globalThis.flag = true;" },
        .{ .id = "sync.js", .src = "export const seen = globalThis.flag;" },
    };
    try expectBothEngines(
        &sibling_entries,
        "main.js",
        "import './tla.js'; import { seen } from './sync.js'; print(seen, globalThis.flag);",
        "false true\n",
    );

    // 2. DFS invariant via GatherAvailableAncestors + AsyncEvaluationOrder
    const dfs_entries = [_]MemEntry{
        .{ .id = "async.js", .src = "await Promise.resolve(); globalThis.ord = 'async';" },
        .{ .id = "d1.js", .src = "import './async.js'; globalThis.ord += ':d1';" },
        .{ .id = "d2.js", .src = "import './async.js'; globalThis.ord += ':d2';" },
        .{ .id = "ind.js", .src = "import './d1.js'; import './d2.js'; globalThis.ord += ':ind';" },
    };
    try expectBothEngines(
        &dfs_entries,
        "main.js",
        "import './d1.js'; import './d2.js'; import './ind.js'; print(globalThis.ord);",
        "async:d1:d2:ind\n",
    );

    // 3. Pending async dep from separate cycle waits for cycle root
    const cyc_entries = [_]MemEntry{
        .{ .id = "setup.js", .src = "globalThis.logs = [];" },
        .{ .id = "leaf.js", .src = "import './root.js'; globalThis.logs.push('leaf_s'); await Promise.resolve(); globalThis.logs.push('leaf_e');" },
        .{ .id = "root.js", .src = "import './leaf.js'; globalThis.logs.push('root_s'); await Promise.resolve(); globalThis.logs.push('root_e');" },
        .{ .id = "imp.js", .src = "import './leaf.js'; globalThis.logs.push('imp');" },
    };
    try expectBothEngines(
        &cyc_entries,
        "main.js",
        "import './setup.js'; import './root.js'; import './imp.js'; print(globalThis.logs.join(','));",
        "leaf_s,leaf_e,root_s,root_e,imp\n",
    );

    // 4. Re-importing parent of already-evaluated TLA module does not hang
    const no_hang_entries = [_]MemEntry{
        .{ .id = "tla.js", .src = "await Promise.resolve();" },
        .{ .id = "parent.js", .src = "import './tla.js'; export const ok = 'yes';" },
        .{ .id = "grand.js", .src = "import { ok } from './parent.js'; export { ok };" },
    };
    try expectBothEngines(
        &no_hang_entries,
        "main.js",
        "import './parent.js'; const ns = await import('./grand.js'); print(ns.ok);",
        "yes\n",
    );

    // 5. Dynamic import of fulfilled member of errored async cycle rejects with cycle root error
    const err_cyc_entries = [_]MemEntry{
        .{ .id = "a.js", .src = "import './b.js'; export const a = 1;" },
        .{ .id = "c.js", .src = "import './a.js'; export const c = 3;" },
        .{ .id = "b.js", .src = "import './c.js'; await Promise.resolve(); throw new Error('boom_b');" },
        .{ .id = "entry_bad.js", .src = "import './b.js';" },
    };
    try expectBothEngines(
        &err_cyc_entries,
        "main.js",
        \\let e1 = null, e2 = null;
        \\try { await import('./entry_bad.js'); } catch (e) { e1 = e; }
        \\try { await import('./c.js'); } catch (e) { e2 = e; }
        \\print(e1.message, e1 === e2);
    ,
        "boom_b true\n",
    );

    // 6. Dynamic import does not preempt active DFS evaluation order
    const verify_dfs_entries = [_]MemEntry{
        .{ .id = "shared.js", .src = "export const order = []; export function done(p) { return p.then(() => print(order.join(','))); }" },
        .{ .id = "a.js", .src = "import { order, done } from './shared.js'; done(import('./b.js')); order.push('A');" },
        .{ .id = "b.js", .src = "import { order } from './shared.js'; order.push('B');" },
    };
    try expectBothEngines(
        &verify_dfs_entries,
        "main.js",
        "import './a.js'; import './b.js';",
        "A,B\n",
    );
}

test "CLI --preload helper: preload globals visible to self-importing module (both engines)" {
    for ([_]Engine{ .vm, .treewalk }) |engine| {
        var out_buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out_buf.deinit();

        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();

        var pool: module.PreloadPool = .{};
        defer pool.deinit(testing.allocator);

        var rt = Runtime.init(testing.allocator, .{}, &out_buf.writer);
        defer rt.deinit();
        rt.stack_base = @frameAddress();
        try rt.addRoots(.{ .ctx = &pool, .mark = module.PreloadPool.markRoots });
        defer rt.removeRoots(&pool);

        var diag: zqjs.Diagnostic = .{};
        try module.runPreloadScript(
            &rt,
            arena.allocator(),
            "function checkEq(a, b) { if (a !== b) throw new Error('mismatch'); } var PRELOAD_TAG = 'ok';",
            engine,
            true,
            &diag,
            &pool,
        );

        const self_src =
            \\import * as self from './self.js';
            \\export let val = 10;
            \\checkEq(PRELOAD_TAG, 'ok');
            \\checkEq(self.val, 10);
            \\val = 20;
            \\print(self.val, PRELOAD_TAG);
        ;
        const entries = [_]MemEntry{
            .{ .id = "self.js", .src = self_src },
        };
        const ml: MemLoader = .{ .entries = &entries };
        rt.modules.loader = ml.loader();

        var mod_diag: module.ModuleDiag = .{};
        _ = try module.runEntry(&rt, "self.js", self_src, engine, &mod_diag);
        try testing.expectEqualStrings("20 ok\n", out_buf.written());
    }
}
