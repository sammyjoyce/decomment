const std = @import("std");

/// build.zig.zon is the single source of truth for the version, so `--version`
/// and the package metadata can never drift apart.
const version = @import("build.zig.zon").version;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const decomment = b.addModule("decomment", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "decomment",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "decomment", .module = decomment },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run decomment");
    run_step.dependOn(&run_cmd.step);

    const module_tests = b.addTest(.{ .root_module = decomment });
    const run_module_tests = b.addRunArtifact(module_tests);

    const cli_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const cli_integration_options = b.addOptions();
    cli_integration_options.addOptionPath("decomment_exe", exe.getEmittedBin());
    const cli_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "cli_integration_options",
                .module = cli_integration_options.createModule(),
            }},
        }),
    });
    const run_cli_integration_tests = b.addRunArtifact(cli_integration_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_cli_integration_tests.step);
}
