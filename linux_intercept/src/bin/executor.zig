const std = @import("std");

const src = @import("src");
const net = src.net;

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

pub fn execute(allocator: std.mem.Allocator, file_cache: *src.FileCacheClient, args: net.ExecuteArgs, _ptrace: *src.Ptrace) !u8 {
    var ignored_names = std.StringHashMap(bool).init(allocator);
    try ignored_names.put("/sys/devices/system/cpu/possible", true);
    defer ignored_names.deinit();

    const exe = try file_cache.file(allocator, args.exe);
    defer allocator.free(exe);

    const argv_rep = try repack_double_array(allocator, args.argv);
    defer allocator.free(argv_rep);

    const envp_rep = try repack_double_array(allocator, args.envp);
    defer allocator.free(envp_rep);

    const initial_cwd = args.cwd;
    const cwd = try file_cache.translate_name(allocator, initial_cwd);
    defer allocator.free(cwd);

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

    _ = _ptrace;
    var ptrace = try src.Ptrace.init(allocator);
    defer ptrace.deinit();
    try ptrace.start(exe, argv_rep, envp_rep);

    var toFree = std.ArrayList([]const u8).init(allocator);
    defer {
        for (toFree.items) |slice| {
            allocator.free(slice);
        }

        toFree.deinit();
    }

    var outputFiles = std.ArrayList([]const u8).init(allocator);
    defer {
        for (outputFiles.items) |slice| {
            allocator.free(slice);
        }

        outputFiles.deinit();
    }

    var executor_arena = std.heap.ArenaAllocator.init(allocator);
    defer executor_arena.deinit();
    const executor_loop_allocator = allocator;

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
                            try outputFiles.append(try allocator.dupe(u8, rel_path));
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
                        try outputFiles.append(try allocator.dupe(u8, path));
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
                const path = try tracee.read_first_arg(allocator);
                defer allocator.free(path);

                if (!std.fs.path.isAbsolute(path)) {
                    log.debug("cwd_dir: {s}, path: {s}", .{ cwd, path });
                    const rel_path = try std.fs.path.join(allocator, &[_][]const u8{ initial_cwd, path });
                    defer allocator.free(rel_path);
                    const new_file = try file_cache.file(allocator, rel_path);
                    defer allocator.free(new_file);
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

                const new_file = try file_cache.file(allocator, path);
                defer allocator.free(new_file);

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
    return 0;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    {
        var env_map = try src.Dotenv.load_env_map(allocator);
        defer env_map.deinit();
        try src.Config.read_from_env_map(env_map);
    }

    var server = try src.JSONRPCServer.init(allocator, src.Config.executor_address);

    std.log.info("Listening on {}", .{server.server.listen_address.getPort()});
    //Single run
    var connection = try server.accept();

    var ptrace = try src.Ptrace.init(allocator);
    defer ptrace.deinit();

    var file_cache: ?src.FileCacheClient = null;
    defer if (file_cache) |*cache| cache.deinit();

    var executing_threads = std.ArrayList(std.Thread).init(allocator);

    errdefer {
        for (executing_threads.items) |thread| {
            thread.join();
        }
    }
    defer {
        executing_threads.deinit();
    }

    while (try connection.next(allocator)) |request| {
        if (std.mem.eql(u8, request.value.method, "connect")) {
            defer request.deinit();
            const params = try std.json.parseFromValue(net.ConnectArgs, allocator, request.value.params, .{});
            defer params.deinit();

            log.debug("Init file cache", .{});
            file_cache = try src.FileCacheClient.init(
                allocator,
                src.Config.cache_directory,
                src.Config.remote_cache_address,
            );

            const response = net.ConnectResponse{};
            try connection.send_response(request.id, response);
        } else if (std.mem.eql(u8, request.value.method, "execute")) {
            const execute_thread = try std.Thread.spawn(.{}, execute_request, .{ allocator, &connection, request, &file_cache.?, &ptrace });
            try executing_threads.append(execute_thread);
        } else if (std.mem.eql(u8, request.value.method, "disconnect")) {
            defer request.deinit();
            const params = try std.json.parseFromValue(net.DisconnectArgs, allocator, request.value.params, .{});
            defer params.deinit();

            const response = net.DisconnectResponse{};
            try connection.send_response(request.id, response);
            break;
        }
    }

    for (executing_threads.items) |thread| {
        thread.join();
    }

    return 0;
}

pub fn execute_request(
    allocator: std.mem.Allocator,
    connection: *src.JSONRPCServer.Connection,
    request: src.JSONRPCServer.Connection.Request,
    file_cache: *src.FileCacheClient,
    ptrace: *src.Ptrace,
) !void {
    defer request.deinit();
    const params = try std.json.parseFromValue(net.ExecuteArgs, allocator, request.value.params, .{});
    defer params.deinit();

    const return_value = try execute(allocator, file_cache, params.value, ptrace);

    const response = net.ExecuteResponse{
        .return_value = return_value,
    };
    try connection.send_response(request.id, response);
}

pub fn repack_double_array(allocator: std.mem.Allocator, array: [][:0]const u8) ![:null]?[*:0]const u8 {
    var result = try allocator.alloc(?[*:0]const u8, array.len + 1);
    for (0..array.len) |i| {
        result[i] = array[i].ptr;
    }
    result[array.len] = null;

    return result[0..array.len :null];
}
