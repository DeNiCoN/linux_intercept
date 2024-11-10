const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const preload = b.addSharedLibrary(.{
        .name = "preload",
        .target = b.host,
        .link_libc = true,
        .optimize = optimize,
    });
    preload.addCSourceFiles(.{ .files = &.{"csrc/preload.c"} });

    b.installArtifact(preload);

    const process_stub = b.addExecutable(.{
        .name = "process_stub",
        .root_source_file = b.path("src/bin/process_stub.zig"),
        .target = b.host,
    });
    b.installArtifact(process_stub);

    const src_module = b.createModule(.{
        .root_source_file = b.path("src/mod.zig"),
    });
    src_module.addIncludePath(b.path("."));

    const intercept = b.addExecutable(.{
        .name = "intercept",
        .root_source_file = b.path("src/bin/intercept.zig"),
        .target = b.host,
        .link_libc = true,
    });
    intercept.root_module.addImport("src", src_module);

    b.installArtifact(intercept);

    const run_exe = b.addRunArtifact(intercept);
    const run_step = b.step("run_intercept", "Run the intercept");
    run_step.dependOn(&run_exe.step);
    run_step.dependOn(&preload.step);
    run_step.dependOn(&process_stub.step);

    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    const executor = b.addExecutable(.{
        .name = "executor",
        .root_source_file = b.path("src/bin/executor.zig"),
        .target = b.host,
        .link_libc = true,
    });
    executor.root_module.addImport("src", src_module);

    const run_executor = b.addRunArtifact(executor);
    if (b.args) |args| {
        run_executor.addArgs(args);
    }

    const run_executor_step = b.step("run_executor", "Run the executor");
    run_executor_step.dependOn(&run_executor.step);

    // const preload_path = try std.fmt.allocPrint(b.allocator, "{s}/lib/{s}", .{ b.install_prefix, preload.out_filename });
    // //defer b.allocator.free(preload_path);
    // run_exe.setEnvironmentVariable("LD_PRELOAD", preload_path);
}
