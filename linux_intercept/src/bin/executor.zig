const std = @import("std");
const net = std.net;

const src = @import("src");

const c = @cImport(
    @cInclude("sys/wait.h"),
);

const trace_log = std.log.scoped(.trace);

const std_options: std.Options = .{
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .trace, .level = .debug },
    },
};

pub fn main() !u8 {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = allocator.deinit();

    //TODO Seems like file cache should be connected when executables start coming
    //Or file cache exists as separate process from initiator
    var file_cache = src.FileCacheClient.init(allocator.allocator(), "/tmp/.cache/linux_intercept", src.Config.remote_cache_address);

    const loopback = try net.Ip4Address.parse("127.0.0.1", 23423);
    const localhost = net.Address{ .in = loopback };

    var server = try localhost.listen(.{ .reuse_port = true });

    std.log.info("Listening on {}", .{server.listen_address.getPort()});
    while (true) {
        const connection = try server.accept();
        defer connection.stream.close();
        std.log.info("Client connected. Reading message", .{});

        const buffered_reader = std.io.bufferedReader(connection.stream.reader());
        var reader = std.json.reader(allocator.allocator(), buffered_reader);
        var parsed = try std.json.parseFromTokenSource(src.net.Args, allocator.allocator(), &reader, .{});
        defer parsed.deinit();
        std.log.info("exe: {s} argv: {s} envp: {s}", .{ parsed.value.exe, parsed.value.argv, parsed.value.envp });

        const exe = try file_cache.file(allocator.allocator(), parsed.value.exe);
        defer allocator.allocator().free(exe);

        const argv_rep = try repack_double_array(allocator.allocator(), parsed.value.argv);
        defer allocator.allocator().free(argv_rep);

        const envp_rep = try repack_double_array(allocator.allocator(), parsed.value.envp);
        defer allocator.allocator().free(envp_rep);
        // Run locally under ptrace intercepting filesystem calls
        // Collect stdout, stderr and exit code
        // TODO Run in ptrace
        // TODO Make a list of interesting calls
        // openat
        // newfstatat
        // access
        //
        // sys/devices/system/cpu/possible
        // TODO Implement remote cache
        // TODO  basic JSONRPC like with streaming files on successfull response
        // TODO First start with all blocking

        var ptrace = try src.Ptrace.init(allocator.allocator());
        try ptrace.start(exe, argv_rep, envp_rep);

        var toFree = std.ArrayList([]const u8).init(allocator.allocator());
        defer {
            for (toFree.items) |slice| {
                allocator.allocator().free(slice);
            }

            toFree.deinit();
        }

        while (try ptrace.next()) |tracee| {
            switch (tracee.stop_reason) {
                .OpenAt => {
                    if (tracee.status == .ExitSyscall) {
                        tracee.cont();
                        continue;
                    }
                    const path = try tracee.read_first_arg(allocator.allocator());
                    defer allocator.allocator().free(path);

                    const new_file = try file_cache.file(allocator.allocator(), path);
                    defer allocator.allocator().free(new_file);

                    tracee.set_first_arg(new_file);
                    tracee.setregs();
                    //tracee.cont();
                },
                else => {
                    tracee.cont();
                },
            }
            trace_log.debug("Stop reason: {}, Status: {}", .{ tracee.stop_reason, tracee.status });
            tracee.cont();
        }
    }
    return 0;
}

pub fn repack_double_array(allocator: std.mem.Allocator, array: [][:0]const u8) ![:null]?[*:0]const u8 {
    var result = try allocator.alloc(?[*:0]const u8, array.len + 1);
    for (0..array.len) |i| {
        result[i] = array[i].ptr;
    }
    result[array.len] = null;

    return result[0..array.len :null];
}
