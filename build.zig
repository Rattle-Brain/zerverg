const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tls = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("tls", tls.module("tls"));

    const exe = b.addExecutable(.{
        .name = "zerverg",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run zerverg").dependOn(&run_cmd.step);

    // `zig build dev`: no auth, plain HTTP, 127.0.0.1, ./dev-data.
    const dev = b.addRunArtifact(exe);
    dev.setCwd(b.path("."));
    dev.addArgs(&.{ "serve", "--dev", "--data", "dev-data" });
    b.step("dev", "Run a development server (no auth!)").dependOn(&dev.step);

    // `zig build staging`: real logins and TLS, ./staging-data.
    const staging = b.addRunArtifact(exe);
    staging.setCwd(b.path("."));
    staging.addArgs(&.{ "serve", "--config", "deploy/zerverg.staging.zon" });
    b.step("staging", "Run a staging server (auth + TLS)")
        .dependOn(&staging.step);

    const tests = b.addTest(.{ .root_module = exe_module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
