// Top-level declarations are order-independent:
const print = std.debug.print;
const panic = std.debug.panic;
const std = @import("std");
const os = std.os;
const assert = std.debug.assert;

pub const std_options: std.Options = .{
    .log_level = .debug,

    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .tracee_memory, .level = .info },
    },
};

const log = std.log;

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("sys/ptrace.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/user.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/mman.h");
    @cInclude("string.h");
});

const src = @import("src");
const systable = src.systable;
const Tracee = src.Tracee;
const Ptrace = src.Ptrace;
const ProcessManager = src.ProcessManager;

pub fn print_help(writer: anytype) !void {
    try std.fmt.format(writer, "Usage: linux_intercept <exe> [args]...\n", .{});
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

    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena_allocator.allocator();

    var ptrace = try Ptrace.init(allocator);
    defer ptrace.deinit();

    const file: [*:0]u8 = os.argv[1];

    var argv_list = try std.ArrayList(?[*:0]const u8).initCapacity(allocator, os.argv.len + 1);
    argv_list.appendSliceAssumeCapacity(os.argv[1..]);
    const argv = try argv_list.toOwnedSliceSentinel(null);
    defer allocator.free(argv);

    try ptrace.start(file, argv, std.mem.span(std.c.environ));

    var process_manager = ProcessManager.init(allocator);

    while (try ptrace.next()) |tracee| {
        switch (tracee.stop_reason) {
            .ExecveEnter => {
                if (ptrace.is_initial(tracee.*)) {
                    tracee.cont();
                    continue;
                }

                var args = try tracee.get_execve_args(allocator);
                defer args.deinit();

                if (args.should_be_executed() and ptrace.will_succeed(args)) {
                    if (process_manager.should_local(tracee)) {
                        try process_manager.allow_local(tracee);
                    } else {
                        try process_manager.allow_remote(tracee, args);
                    }
                } else {
                    tracee.cont();
                }
            },
            .Exit => {
                if (process_manager.is_executing(tracee)) {
                    try process_manager.finished(tracee);
                }
                tracee.detach();
            },
            .None => {
                std.debug.panic("None stop_reason", .{});
            },
            else => {
                tracee.cont();
            },
        }
    }
    return 0;
}
