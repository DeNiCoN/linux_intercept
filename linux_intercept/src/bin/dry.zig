const std = @import("std");
const src = @import("src");
const log = std.log;
const os = std.os;

pub fn print_help(writer: anytype) !void {
    try std.fmt.format(writer, "Usage: dry <exe> [args]...\n", .{});
}

pub fn main() !u8 {
    log.debug("Command args: {s}", .{os.argv});
    if (os.argv.len < 2) {
        try print_help(std.io.getStdErr().writer());
        return 1;
    } else if (std.mem.eql(u8, std.mem.span(os.argv[1]), "--help")) {
        try print_help(std.io.getStdOut().writer());
        return 0;
    }
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    var ptrace = try src.Ptrace.init(allocator.allocator());
    const file: [*:0]u8 = os.argv[1];

    var argv_list = try std.ArrayList(?[*:0]const u8).initCapacity(allocator, os.argv.len + 1);
    argv_list.appendSliceAssumeCapacity(os.argv[1..]);
    const argv = try argv_list.toOwnedSliceSentinel(null);
    defer allocator.free(argv);

    try ptrace.start(file, argv, std.mem.span(std.c.environ));

    while (try ptrace.next()) |tracee| {
        switch (tracee.stop_reason) {
            .OpenAt => {
                if (tracee.status == .ExitSyscall) {
                    tracee.cont();
                    continue;
                }
                const path = try tracee.read_first_arg(allocator.allocator());
                defer allocator.allocator().free(path);

                tracee.cont();
            },
            else => {
                tracee.cont();
            },
        }
    }
    return 0;
}
