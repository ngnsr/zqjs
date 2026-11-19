const std = @import("std");
const builtin = @import("builtin");

// Exact toolchain pin (DESIGN_DECISIONS D17); minimum_zig_version in build.zig.zon is only a floor.
comptime {
    if (!std.mem.eql(u8, builtin.zig_version_string, "0.17.1"))
        @compileError("zqjs requires Zig 0.17.1 exactly, found " ++ builtin.zig_version_string);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Two modules (M9.0, D46). `zqjs_internal` is everything (src/root.zig): tests, tools and
    // the CLI's debug modes import it, and it is never exported. `zqjs` (src/api.zig) is the
    // embedding API built on it, and the only module an embedder's build can get: the VM,
    // heap and bytecode stay unreachable, so changing them never breaks an embedder.
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // -Dstack-stress: the VM moves its stacks to fresh allocations on every call, so a
    // stale index or slice into them fails at once (DESIGN_DECISIONS D12). Run the whole
    // suite with it: zig build test -Dstack-stress
    const options = b.addOptions();
    options.addOption(bool, "stack_stress", b.option(bool, "stack-stress", "VM: move the stacks on every call") orelse false);
    // -Dgc-stress: collect at every safepoint, keep collected objects as tombstones, and
    // verify the heap after every collection (GC_DESIGN §11): zig build test -Dgc-stress
    options.addOption(bool, "gc_stress", b.option(bool, "gc-stress", "GC: collect at every safepoint, tombstones, heap verifier") orelse false);
    // -Dgc-mutation=<name>: one deliberately broken piece of the generational collector
    // (heap.Mutation), so the `mutation:` tests can prove the verifier catches it. Only
    // `zig build gc-mutants` uses it; never set it for a real build.
    options.addOption([]const u8, "gc_mutation", b.option([]const u8, "gc-mutation", "GC: break one barrier piece on purpose (tests)") orelse "none");
    mod.addOptions("build_options", options);
    const api = b.addModule("zqjs", .{
        .root_source_file = b.path("src/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zqjs_internal", .module = mod }},
    });
    const imports: []const std.Build.Module.Import = &.{ .{ .name = "zqjs_internal", .module = mod }, .{ .name = "zqjs", .module = api } };

    const exe = b.addExecutable(.{
        .name = "zqjs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    b.installArtifact(exe);

    // M9.2 C ABI static library + header
    const c_api_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    const libzqjs = b.addLibrary(.{
        .name = "zqjs",
        .linkage = .static,
        .root_module = c_api_mod,
    });
    libzqjs.installHeader(b.path("include/zqjs.h"), "zqjs.h");
    b.installArtifact(libzqjs);

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the zqjs CLI").dependOn(&run.step);

    // Unit tests inside src/, an umbrella integration binary (`internal_tests`) so `zig build test`
    // compiles `zqjs_internal` once instead of nine times, plus lazy `test-<name>` steps for
    // running any single suite during iteration. `--fuzz=N` fuzzes only one test per run, so pick
    // fuzz targets with -Dtest-filter:
    //   zig build test --fuzz=100K -Dtest-filter="fuzz: the verifier"
    const filters: []const []const u8 = if (b.option([]const u8, "test-filter", "Run only tests whose name contains this")) |f| &.{f} else &.{};
    const test_step = b.step("test", "Run unit and integration tests");
    const run_unit_tests = b.addRunArtifact(b.addTest(.{ .root_module = mod, .filters = filters }));
    test_step.dependOn(&run_unit_tests.step);
    b.step("test-unit", "Run unit tests inside src/").dependOn(&run_unit_tests.step);

    // Everything in tests/ goes through `zqjs_internal` / `zqjs`. Data files are generated
    // or checked with node by the scripts in tests/harness/.
    const internal_tests = b.addRunArtifact(b.addTest(.{ .name = "internal_tests", .filters = filters, .root_module = b.createModule(.{
        .root_source_file = b.path("tests/internal_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) }));
    internal_tests.setCwd(b.path(".")); // diff_test, gc_test, etc. read repo paths at runtime
    test_step.dependOn(&internal_tests.step);

    for ([_]struct { step: []const u8, file: []const u8 }{
        .{ .step = "test-gc", .file = "gc_test" }, // the garbage collector: store-API scan, generations, cards, mutants
        .{ .step = "test-interpreter", .file = "interpreter_test" }, // both engines: limits, allocation failures, exceptions, fuzzing
        .{ .step = "test-bytecode", .file = "bytecode_test" }, // compiler + verifier over all programs, snapshots, limits, fuzzing
        .{ .step = "test-diff", .file = "diff_test" }, // diff/*.js on both engines: output must equal node's (diff/*.out)
        .{ .step = "test-vm", .file = "vm_test" }, // the VM's step() contract, cleanup, --trace
        .{ .step = "test-syntax", .file = "syntax_test" }, // syntax/cases.jsonl: outcome + resolved dump for each source
        .{ .step = "test-ops", .file = "ops_test" }, // ops/*.jsonl: conversions and operators vs node, bit for bit
        .{ .step = "test-frontend", .file = "frontend_test" }, // allocation-failure paths and fuzzing of parse, resolve, dump
        .{ .step = "test-regex", .file = "regex_test" }, // regex/cases.jsonl: standalone regex compiler and matcher vs node
    }) |entry| {
        const single = b.addRunArtifact(b.addTest(.{ .name = entry.file, .filters = filters, .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/{s}.zig", .{entry.file})),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }) }));
        single.setCwd(b.path("."));
        b.step(entry.step, b.fmt("Run only {s}", .{entry.file})).dependOn(&single.step);
    }

    // The embedding API's tests see only `zqjs`, as an embedder does: an import of
    // `zqjs_internal` there fails to build.
    const api_tests = b.addRunArtifact(b.addTest(.{ .name = "api_test", .filters = filters, .root_module = b.createModule(.{
        .root_source_file = b.path("tests/api_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zqjs", .module = api }},
    }) }));
    api_tests.setCwd(b.path("."));
    test_step.dependOn(&api_tests.step);
    b.step("test-api", "Run embedding API tests").dependOn(&api_tests.step);

    // C ABI layout & unit tests (M9.2)
    const c_api_test_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    const c_api_tests = b.addRunArtifact(b.addTest(.{ .name = "c_api_zig_test", .filters = filters, .root_module = c_api_test_mod }));
    test_step.dependOn(&c_api_tests.step);

    // Pure C11 integration test linked against libzqjs.a (M9.2)
    const c_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_test_mod.addIncludePath(b.path("include"));
    c_test_mod.addCSourceFile(.{
        .file = b.path("tests/c_api_test.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    c_test_mod.linkLibrary(libzqjs);
    const c_test_exe = b.addExecutable(.{
        .name = "c_api_test",
        .root_module = c_test_mod,
    });
    test_step.dependOn(&b.addRunArtifact(c_test_exe).step);

    // M13: Multi-plugin cooperative C11 host (zero external dependencies)
    const plugin_host_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    plugin_host_mod.addIncludePath(b.path("include"));
    plugin_host_mod.addCSourceFile(.{
        .file = b.path("examples/plugin_host.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    plugin_host_mod.linkLibrary(libzqjs);
    const plugin_host_exe = b.addExecutable(.{
        .name = "plugin_host",
        .root_module = plugin_host_mod,
    });
    const run_plugin_host = b.addRunArtifact(plugin_host_exe);
    test_step.dependOn(&run_plugin_host.step);
    b.step("plugin-host", "Build and run the M13 multi-plugin C11 host").dependOn(&run_plugin_host.step);

    // The broken builds (M8.1): for each heap.Mutation, the `mutation:` tests under
    // -Dgc-stress, which pass only if the verifier catches that mutant.
    const mutants = b.step("gc-mutants", "Prove the heap verifier catches each deliberately broken GC piece");
    for ([_][]const u8{ "none", "no_element_barrier", "no_card_set", "keep_remembered_bit", "clean_first_bitmap", "minor_frees_atoms", "no_prop_card_set", "no_dirty_on_remove", "clean_first_prop_bitmap" }) |name| {
        const mutant_options = b.addOptions();
        mutant_options.addOption(bool, "stack_stress", false);
        mutant_options.addOption(bool, "gc_stress", true);
        mutant_options.addOption([]const u8, "gc_mutation", name);
        const mutant_mod = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
        mutant_mod.addOptions("build_options", mutant_options);
        const mutant = b.addRunArtifact(b.addTest(.{ .name = b.fmt("mutant-{s}", .{name}), .filters = &.{"mutation:"}, .root_module = b.createModule(.{
            .root_source_file = b.path("tests/gc_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zqjs_internal", .module = mutant_mod }},
        }) }));
        mutant.setCwd(b.path("."));
        mutants.dependOn(&mutant.step);
    }

    // Portability check for pow (tools/pow_bits.zig): build with any -Dtarget/-Dcpu/-Doptimize.
    const pow_bits = b.addRunArtifact(b.addExecutable(.{
        .name = "pow-bits",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/pow_bits.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    }));
    pow_bits.addPassthruArgs();
    b.step("pow-bits", "Hash pow results for a target (compare across targets)").dependOn(&pow_bits.step);

    // Embedding example (examples/embed.zig): imports only `zqjs`, as an embedder does.
    const example_exe = b.addExecutable(.{
        .name = "embed-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/embed.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zqjs", .module = api }},
        }),
    });
    const run_example = b.addRunArtifact(example_exe);
    run_example.setCwd(b.path("."));
    run_example.addPassthruArgs();
    b.step("example", "Run the embedding API example (examples/embed.zig)").dependOn(&run_example.step);

    // Benchmark baseline (tools/bench.zig): bench/*.js on both engines, always ReleaseFast.
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addOptions("build_options", options);
    const bench = b.addRunArtifact(b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "zqjs_internal", .module = bench_mod }},
        }),
    }));
    bench.setCwd(b.path("."));
    b.step("bench", "Run bench/*.js on both engines (ReleaseFast): steps, heap, median time").dependOn(&bench.step);

    // M10.0 split-phase ZQJS benchmark (tools/m10_bench.zig): ReleaseFast.
    const m10_bench = b.addRunArtifact(b.addExecutable(.{
        .name = "m10-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/m10_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "zqjs_internal", .module = bench_mod }},
        }),
    }));
    m10_bench.setCwd(b.path("."));
    m10_bench.addPassthruArgs();
    b.step("m10-bench", "Run M10 split-phase ZQJS benchmarks (ReleaseFast)").dependOn(&m10_bench.step);

    // M10.0 C-ABI embedding benchmark (tools/m10_c_bench.c): ReleaseFast.
    const bench_api = b.createModule(.{
        .root_source_file = b.path("src/api.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "zqjs_internal", .module = bench_mod }},
    });
    const bench_libzqjs = b.addLibrary(.{
        .name = "zqjs_bench",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{ .{ .name = "zqjs_internal", .module = bench_mod }, .{ .name = "zqjs", .module = bench_api } },
        }),
    });
    const m10_c_mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    m10_c_mod.addIncludePath(b.path("include"));
    m10_c_mod.addCSourceFile(.{
        .file = b.path("tools/m10_c_bench.c"),
        .flags = &.{ "-std=c11", "-O3", "-Wall", "-Wextra", "-Werror" },
    });
    m10_c_mod.linkLibrary(bench_libzqjs);
    const m10_c_bench = b.addRunArtifact(b.addExecutable(.{
        .name = "m10-c-bench",
        .root_module = m10_c_mod,
    }));
    m10_c_bench.setCwd(b.path("."));
    b.step("m10-c-bench", "Run M10 C-ABI embedding benchmarks (ReleaseFast)").dependOn(&m10_c_bench.step);

    // GC report (tools/gc_report.zig): pauses, rates and per-collection series, ReleaseFast.
    const gc_report = b.addRunArtifact(b.addExecutable(.{
        .name = "gc-report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gc_report.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "zqjs_internal", .module = bench_mod }},
        }),
    }));
    gc_report.setCwd(b.path("."));
    gc_report.addPassthruArgs();
    b.step("gc-report", "GC pauses, allocation rate and GC share for bench/ and bench/gc/ (ReleaseFast)").dependOn(&gc_report.step);

    // Optional Raylib C-ABI embedding demo (M11.4). Kept off `zig build` and `zig build test`
    // so the core suite never depends on Raylib being installed.
    const raylib_prefix = b.option([]const u8, "raylib-prefix", "Prefix with include/ and lib/ for Raylib (optional)");
    const raylib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    raylib_mod.addIncludePath(b.path("include"));
    if (raylib_prefix) |prefix| {
        raylib_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{prefix}) });
        raylib_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{prefix}) });
        raylib_mod.linkSystemLibrary("raylib", .{});
    } else if (target.result.os.tag == .macos) {
        if (std.Io.Dir.cwd().access(b.graph.io, "/opt/homebrew/opt/raylib/include", .{})) |_| {
            raylib_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/opt/raylib/include" });
            raylib_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/opt/raylib/lib" });
        } else |_| {}
        raylib_mod.linkSystemLibrary("raylib", .{});
    } else {
        raylib_mod.linkSystemLibrary("raylib", .{ .use_pkg_config = .yes });
    }
    raylib_mod.addCSourceFile(.{
        .file = b.path("examples/raylib_c_demo.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    raylib_mod.linkLibrary(libzqjs);
    const raylib_exe = b.addExecutable(.{
        .name = "raylib_c_demo",
        .root_module = raylib_mod,
    });
    const run_raylib = b.addRunArtifact(raylib_exe);
    run_raylib.addPassthruArgs();
    b.step("raylib-demo", "Build and run the Raylib C-ABI demo (requires Raylib)").dependOn(&run_raylib.step);

    const run_raylib_smoke = b.addRunArtifact(raylib_exe);
    run_raylib_smoke.addArgs(&.{ "--frames", "60", "--verify-errors" });
    b.step("raylib-smoke", "Run the headless Raylib C-ABI smoke test (requires Raylib)").dependOn(&run_raylib_smoke.step);

    // Generated test data: node (goldens, syntax contract), Python stdlib (pow reference),
    // and the pow tables generated from musl. Dev-time only; `zig build test` needs none.
    const check = b.step("check-goldens", "Check syntax cases against node; generated files up to date");
    const update = b.step("update-golden", "Regenerate goldens (node) and pow reference values (Python)");
    for ([_][]const []const u8{
        &.{ "node", "tests/harness/check_syntax_cases.js", "tests/syntax/cases.jsonl" },
        &.{ "node", "tests/harness/golden.js", "--check" },
        &.{ "node", "tools/gen_pow_data.js", "--check" },
        &.{ "node", "tools/gen_builtins.js", "--check" },
        &.{ "node", "tools/gen_regex_cases.js", "--check" },
        &.{ "python3", "-I", "tools/pow_reference.py", "--check" },
    }) |argv| {
        const cmd = b.addSystemCommand(argv);
        cmd.setCwd(b.path("."));
        check.dependOn(&cmd.step);
    }
    // Order matters: pow_reference.py reads the inputs golden.js writes.
    const regen_goldens = b.addSystemCommand(&.{ "node", "tests/harness/golden.js" });
    regen_goldens.setCwd(b.path("."));
    const regen_reference = b.addSystemCommand(&.{ "python3", "-I", "tools/pow_reference.py" });
    regen_reference.setCwd(b.path("."));
    regen_reference.step.dependOn(&regen_goldens.step);
    update.dependOn(&regen_reference.step);
    const regen_regex = b.addSystemCommand(&.{ "node", "tools/gen_regex_cases.js" });
    regen_regex.setCwd(b.path("."));
    update.dependOn(&regen_regex.step);
}
