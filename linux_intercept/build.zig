const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const preload = b.addSharedLibrary(.{ .name = "preload", .target = b.host, .link_libc = true, .optimize = optimize });
    preload.addCSourceFiles(.{ .files = &.{"preload.c"} });

    b.installArtifact(preload);

    const process_stub = b.addExecutable(.{
        .name = "process_stub",
        .root_source_file = b.path("process_stub.zig"),
        .target = b.host,
    });
    b.installArtifact(process_stub);

    const exe = b.addExecutable(.{
        .name = "linux_intercept",
        .root_source_file = b.path("main.zig"),
        .target = b.host,
        .link_libc = true,
    });

    b.installArtifact(exe);
    exe.addIncludePath(b.path("."));

    const run_exe = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);
    run_step.dependOn(&preload.step);

    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    // const preload_path = try std.fmt.allocPrint(b.allocator, "{s}/lib/{s}", .{ b.install_prefix, preload.out_filename });
    // //defer b.allocator.free(preload_path);
    // run_exe.setEnvironmentVariable("LD_PRELOAD", preload_path);
}
