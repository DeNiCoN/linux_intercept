// Top-level declarations are order-independent:
const print = std.debug.print;
const panic = std.debug.panic;
const std = @import("std");
const os = std.os;
const assert = std.debug.assert;

pub const std_options: std.Options = .{
    .log_level = .info,

    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .tracee_memory, .level = .info },
        .{ .scope = .rpc_server, .level = .info },
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

pub fn run_ptrace_interceptor() !void {
    var gp_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gp_allocator.deinit();
    var allocator = gp_allocator.allocator();

    var ptrace = try Ptrace.init(allocator);
    defer ptrace.deinit();

    const file: [*:0]u8 = os.argv[1];

    var argv_list = try std.ArrayList(?[*:0]const u8).initCapacity(allocator, os.argv.len + 1);
    argv_list.appendSliceAssumeCapacity(os.argv[1..]);
    const argv = try argv_list.toOwnedSliceSentinel(null);
    defer allocator.free(argv);

    try ptrace.start(file, argv, std.mem.span(std.c.environ));

    var process_manager = ProcessManager.init(allocator, try std.Thread.getCpuCount());
    defer process_manager.deinit();

    const file_cache_thread = try std.Thread.spawn(.{}, run_file_cache_server, .{});

    try process_manager.connect(src.Config.executor_address);

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
            .OpenAt => {
                if (tracee.status == .ExitSyscall) {
                    tracee.cont();
                    continue;
                }
                const path = try tracee.read_second_arg(allocator);
                defer allocator.free(path);
                if (std.mem.eql(u8, path, "/sys/devices/system/cpu/possible")) {
                    log.warn("cpu/possible is Unimplemented", .{});
                } else if (std.mem.eql(u8, path, "/sys/devices/system/cpu/online")) {
                    const new_path = try process_manager.process_count_stub_file();
                    try tracee.set_second_arg(new_path);
                    tracee.setregs();
                }
                tracee.cont();
            },
            .SchedGetAffinity => {
                log.warn("SchedGetAffinity is Unimplemented", .{});
            },
            else => {
                tracee.cont();
            },
        }
    }

    //The program has finished
    try process_manager.disconnect();
    //File cache should stop by itself
    file_cache_thread.join();
}

pub fn run_file_cache_server() !void {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = allocator.deinit();

    var server = try src.FileCacheServer.init(allocator.allocator(), src.Config.remote_cache_address);
    defer server.deinit();
    try server.run();
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
    defer _ = allocator.deinit();
    {
        var env_map = try src.Dotenv.load_env_map(allocator.allocator());
        defer env_map.deinit();
        try src.Config.read_from_env_map(env_map);
    }

    try run_ptrace_interceptor();
    return 0;
}
