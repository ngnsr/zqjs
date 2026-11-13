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
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    const integration = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/all.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) }));
    integration.setCwd(b.path(".")); // diff_test reads tests/diff at runtime
    test_step.dependOn(&integration.step);

    const check_node = b.step("check-node", "Check syntax cases and goldens against node");
    const node = b.addSystemCommand(&.{"node"});
    node.addFileArg(b.path("tests/harness/check_syntax_cases.js"));
    node.addFileArg(b.path("tests/syntax/cases.jsonl"));
    check_node.dependOn(&node.step);
    const goldens = b.addSystemCommand(&.{ "node", "tests/harness/golden.js", "--check" });
    goldens.setCwd(b.path("."));
    check_node.dependOn(&goldens.step);

    const update = b.addSystemCommand(&.{ "node", "tests/harness/golden.js" });
    update.setCwd(b.path("."));
    b.step("update-golden", "Regenerate tests/ops and tests/diff/*.out with node").dependOn(&update.step);
}
