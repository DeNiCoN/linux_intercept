const std = @import("std");
const net = std.net;

const src = @import("src");

const c = @cImport({
    @cInclude("sys/wait.h");
    @cInclude("fcntl.h");
});

const log = std.log.scoped(.trace);

pub const std_options: std.Options = .{
    .log_level = .info,
    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .trace, .level = .info },
    },
};

pub fn main() !u8 {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = allocator.deinit();
    {
        var env_map = try src.Dotenv.load_env_map(allocator.allocator());
        defer env_map.deinit();
        try src.Config.read_from_env_map(env_map);
    }

    var ignored_names = std.StringHashMap(bool).init(allocator.allocator());
    try ignored_names.put("/sys/devices/system/cpu/possible", true);

    var server = try src.Config.executor_address.listen(.{ .reuse_port = true });

    std.log.info("Listening on {}", .{server.listen_address.getPort()});
    while (true) {
        const connection = try server.accept();
        defer connection.stream.close();
        std.log.info("Client connected. Reading message", .{});

        const buffered_reader = std.io.bufferedReader(connection.stream.reader());
        var reader = std.json.reader(allocator.allocator(), buffered_reader);
        defer reader.deinit();
        var parsed = try std.json.parseFromTokenSource(src.net.Args, allocator.allocator(), &reader, .{});
        defer parsed.deinit();
        std.log.info("exe: {s} argv: {s} envp: {s}", .{ parsed.value.exe, parsed.value.argv, parsed.value.envp });

        //TODO Seems like file cache should be connected when executables start coming
        //Or file cache exists as separate process from initiator
        var file_cache = try src.FileCacheClient.init(
            allocator.allocator(),
            src.Config.cache_directory,
            src.Config.remote_cache_address,
        );
        defer file_cache.deinit();

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

        const initial_cwd = parsed.value.cwd;
        const cwd = try file_cache.translate_name(allocator.allocator(), parsed.value.cwd);
        defer allocator.allocator().free(cwd);

        {
            var root_dir = try std.fs.openDirAbsolute("/", .{});
            defer root_dir.close();
            //FIXME: Possible empty cwd
            try root_dir.makePath(cwd[1..]);
        }

        var cwd_dir = try std.fs.openDirAbsolute(cwd, .{});
        defer cwd_dir.close();
        //TODO This should be mutexed
        try cwd_dir.setAsCwd();

        var ptrace = try src.Ptrace.init(allocator.allocator());
        defer ptrace.deinit();
        try ptrace.start(exe, argv_rep, envp_rep);

        var toFree = std.ArrayList([]const u8).init(allocator.allocator());
        defer {
            for (toFree.items) |slice| {
                allocator.allocator().free(slice);
            }

            toFree.deinit();
        }

        var outputFiles = std.ArrayList([]const u8).init(allocator.allocator());
        defer {
            for (outputFiles.items) |slice| {
                allocator.allocator().free(slice);
            }

            outputFiles.deinit();
        }

        var executor_arena = std.heap.ArenaAllocator.init(allocator.allocator());
        defer executor_arena.deinit();
        const executor_loop_allocator = executor_arena.allocator();

        while (try ptrace.next()) |tracee| {
            _ = executor_arena.reset(.retain_capacity);

            log.debug("PID: {}, Stop reason: {}, Status: {}", .{ tracee.pid, tracee.stop_reason, tracee.status });
            switch (tracee.stop_reason) {
                .OpenAt, .Newfstatat => {
                    if (tracee.status == .ExitSyscall) {
                        tracee.cont();
                        continue;
                    }
                    const path = try tracee.read_second_arg(executor_loop_allocator);
                    defer executor_loop_allocator.free(path);

                    if (!std.fs.path.isAbsolute(path)) {
                        const full_relative_directory = if (@as(c_int, @bitCast(@as(c_uint, @truncate(tracee.arg_first().*)))) == c.AT_FDCWD)
                            try src.utils.getCWDPathAlloc(executor_loop_allocator, tracee.pid)
                        else
                            try src.utils.getFDPathAlloc(executor_loop_allocator, tracee.pid, tracee.arg_first().*);
                        defer executor_loop_allocator.free(full_relative_directory);

                        //There should be no open directories outside the cache
                        std.debug.assert(std.mem.startsWith(u8, full_relative_directory, src.Config.cache_directory));

                        const relative_directory = full_relative_directory[src.Config.cache_directory.len..];

                        log.info("dir: {s}, path: {s}", .{ relative_directory, path });

                        const rel_path = try std.fs.path.join(executor_loop_allocator, &[_][]const u8{ relative_directory, path });
                        defer executor_loop_allocator.free(rel_path);

                        const new_file = try file_cache.file(executor_loop_allocator, rel_path);
                        defer executor_loop_allocator.free(new_file);

                        //FIXME: Does not work in general
                        {
                            var root_dir = try std.fs.openDirAbsolute("/", .{});
                            defer root_dir.close();
                            try root_dir.makePath(std.fs.path.dirname(new_file) orelse ".");
                        }

                        if (tracee.stop_reason == .OpenAt) {
                            if (tracee.regs.rdx & c.O_CREAT != 0) {
                                log.info("New file: {s}", .{rel_path});
                                try outputFiles.append(try allocator.allocator().dupe(u8, rel_path));
                                tracee.cont();
                                continue;
                            }
                        }

                        tracee.cont();
                        continue;
                    }

                    if (std.mem.startsWith(u8, path, "/dev")) {
                        tracee.cont();
                        continue;
                    }

                    if (ignored_names.contains(path)) {
                        tracee.cont();
                        continue;
                    }

                    if (std.mem.eql(u8, path, src.Config.preload_path)) {
                        tracee.cont();
                        continue;
                    }
                    log.debug("Second arg: {s}", .{path});
                    if (tracee.stop_reason == .OpenAt) {
                        if (tracee.regs.rdx & (c.O_CREAT | c.O_WRONLY | c.O_RDWR) != 0) {
                            log.info("New file: {s}", .{path});
                            try outputFiles.append(try allocator.allocator().dupe(u8, path));
                            tracee.cont();
                            continue;
                        }
                    }

                    const new_file = try file_cache.file(executor_loop_allocator, path);
                    defer executor_loop_allocator.free(new_file);

                    try tracee.set_second_arg(new_file);
                    tracee.setregs();
                    tracee.cont();
                },
                .Access => {
                    if (tracee.status == .ExitSyscall) {
                        tracee.cont();
                        continue;
                    }
                    const path = try tracee.read_first_arg(allocator.allocator());
                    defer allocator.allocator().free(path);

                    if (!std.fs.path.isAbsolute(path)) {
                        log.debug("cwd_dir: {s}, path: {s}", .{ cwd, path });
                        const rel_path = try std.fs.path.join(allocator.allocator(), &[_][]const u8{ initial_cwd, path });
                        defer allocator.allocator().free(rel_path);
                        const new_file = try file_cache.file(allocator.allocator(), rel_path);
                        defer allocator.allocator().free(new_file);
                        {
                            var root_dir = try std.fs.openDirAbsolute("/", .{});
                            defer root_dir.close();
                            try root_dir.makePath(std.fs.path.dirname(new_file) orelse ".");
                        }
                        tracee.cont();
                        continue;
                    }

                    if (std.mem.startsWith(u8, path, "/dev")) {
                        tracee.cont();
                        continue;
                    }

                    if (ignored_names.contains(path)) {
                        tracee.cont();
                        continue;
                    }

                    if (std.mem.eql(u8, path, src.Config.preload_path)) {
                        tracee.cont();
                        continue;
                    }
                    log.debug("Acesss: {s}", .{path});

                    const new_file = try file_cache.file(allocator.allocator(), path);
                    defer allocator.allocator().free(new_file);

                    try tracee.set_first_arg(new_file);
                    tracee.setregs();
                    tracee.cont();
                },
                else => {
                    tracee.cont();
                },
            }
        }

        log.info("Sending back files: {s}", .{outputFiles.items});
        // The tracee is finished. Send back the results
        for (outputFiles.items) |path| {
            try file_cache.sendFile(path);
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
