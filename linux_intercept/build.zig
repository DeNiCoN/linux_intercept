const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{ .name = "linux_intercept", .root_source_file = b.path("main.zig"), .target = b.host, .link_libc = true });

    b.installArtifact(exe);
}
