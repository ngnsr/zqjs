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

    const mod = b.addModule("zqjs", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // -Dstack-stress: the VM moves its stacks to fresh allocations on every call, so a
    // stale index or slice into them fails at once (DESIGN_DECISIONS D12). Run the whole
    // suite with it: zig build test -Dstack-stress
    const options = b.addOptions();
    options.addOption(bool, "stack_stress", b.option(bool, "stack-stress", "VM: move the stacks on every call") orelse false);
    mod.addOptions("build_options", options);
    const imports: []const std.Build.Module.Import = &.{.{ .name = "zqjs", .module = mod }};

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

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the zqjs CLI").dependOn(&run.step);

    // Two test binaries: unit tests inside src/, and integration tests in tests/.
    // `--fuzz=N` fuzzes only one test per run, so pick fuzz targets with -Dtest-filter:
    //   zig build test --fuzz=100K -Dtest-filter="fuzz: the verifier"
    const filters: []const []const u8 = if (b.option([]const u8, "test-filter", "Run only tests whose name contains this")) |f| &.{f} else &.{};
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod, .filters = filters })).step);
    const integration = b.addRunArtifact(b.addTest(.{ .filters = filters, .root_module = b.createModule(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) }));
    integration.setCwd(b.path(".")); // diff_test reads tests/diff at runtime
    test_step.dependOn(&integration.step);

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

    // Generated test data: node (goldens, syntax contract), Python stdlib (pow reference),
    // and the pow tables generated from musl. Dev-time only; `zig build test` needs none.
    const check = b.step("check-goldens", "Check syntax cases against node; generated files up to date");
    const update = b.step("update-golden", "Regenerate goldens (node) and pow reference values (Python)");
    for ([_][]const []const u8{
        &.{ "node", "tests/harness/check_syntax_cases.js", "tests/syntax/cases.jsonl" },
        &.{ "node", "tests/harness/golden.js", "--check" },
        &.{ "node", "tools/gen_pow_data.js", "--check" },
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
}
