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

    const test_step = b.step("test", "Run unit tests and syntax-case tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    const cases = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/syntax_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    test_step.dependOn(&b.addRunArtifact(cases).step);

    const node = b.addSystemCommand(&.{"node"});
    node.addFileArg(b.path("tests/harness/check_syntax_cases.js"));
    node.addFileArg(b.path("tests/syntax/cases.jsonl"));
    b.step("check-node", "Check tests/syntax/cases.jsonl against node").dependOn(&node.step);
}
