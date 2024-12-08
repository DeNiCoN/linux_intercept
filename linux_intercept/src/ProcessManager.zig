const std = @import("std");
const log = std.log.scoped(.process_manager);
const net = @import("net.zig");
const Tracee = @import("Tracee.zig");
const Config = @import("Config.zig");
const ExecutorRPCClient = @import("ExecutorRPCClient.zig");
const utils = @import("utils.zig");
const sys_panic = utils.sys_panic;

local: std.AutoHashMap(c_long, bool),
executor_rpc: ?ExecutorRPCClient,
allocator: std.mem.Allocator,

waiting_threads: std.AutoHashMap(c_long, std.Thread),
waiting_threads_mu: std.Thread.Mutex,

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
    @cInclude("fcntl.h");
    @cInclude("string.h");
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
    @cInclude("csrc/preload.h");
});

const ProcessManager = @This();

pub fn init(allocator: std.mem.Allocator) ProcessManager {
    return .{
        .local = std.AutoHashMap(c_long, bool).init(allocator),
        .allocator = allocator,
        .executor_rpc = null,
        .waiting_threads = std.AutoHashMap(c_long, std.Thread).init(allocator),
        .waiting_threads_mu = .{},
    };
}

pub fn deinit(self: *ProcessManager) void {
    self.local.deinit();
    if (self.executor_rpc) |*value| {
        value.deinit();
    }

    var it = self.waiting_threads.iterator();
    while (it.next()) |thread| {
        thread.value_ptr.join();
    }

    self.waiting_threads.deinit();
}

pub fn connect(self: *ProcessManager, address: std.net.Address) !void {
    self.executor_rpc = try ExecutorRPCClient.init(self.allocator, address);
    const response = try self.executor_rpc.?.connect(Config.remote_cache_port, 0);
    defer response.deinit();
}

pub fn disconnect(self: *ProcessManager) !void {
    const response = try self.executor_rpc.?.disconnect();
    defer response.deinit();
}

pub fn should_local(self: ProcessManager, tracee: *const Tracee) bool {
    _ = self;
    _ = tracee;
    return false;
}

pub fn allow_local(self: *ProcessManager, tracee: *Tracee) !void {
    log.info("Executing [{}] locally", .{tracee.pid});
    try self.local.put(tracee.pid, true);
    tracee.local_execution();
}

pub fn allow_remote(self: *ProcessManager, tracee: *Tracee, args: Tracee.ExecveArgs) !void {
    const pipe_path = try std.fmt.allocPrintZ(self.allocator, "/tmp/linux_intercept_pipe_{}", .{tracee.pid});
    log.debug("pipe_path = {s}", .{pipe_path});
    defer self.allocator.free(pipe_path);

    const unix_socket_addr = try std.net.Address.initUnix(pipe_path);
    var pipe_server = try unix_socket_addr.listen(.{});
    defer pipe_server.deinit();

    // Make pipe, change argv, initial talk to stub, dealloc argv
    // Sync to tracee
    const traceeArgs = try tracee.makeExecveArgs(Config.stub_exe_path, &[_][]const u8{pipe_path});

    try tracee.replace_execve_to_stub(traceeArgs);
    tracee.detach();

    //FIXME: Check if accept should run before client connects
    const pipe_connection = try pipe_server.accept();
    traceeArgs.deinit();

    //self.threads.append(try std.Thread.spawn(.{}, remote_execution, .{ self, tracee, args, pipe_connection.stream }));

    //TODO Implement generic cloner?
    //Or find a better way to work with a bunch of strings
    var dupedArgs = try args.dupe(self.allocator);
    errdefer dupedArgs.deinit();

    {
        self.waiting_threads_mu.lock();
        const execute_thread = try std.Thread.spawn(.{}, remote_execution, .{ self, tracee, dupedArgs, pipe_connection.stream });
        defer self.waiting_threads_mu.unlock();
        try self.waiting_threads.put(tracee.pid, execute_thread);
    }
    //FIXME What if we telefork? Does there need to be additional handling?
}

pub fn finished(self: *ProcessManager, tracee: *const Tracee) !void {
    log.info("Finished [{}]", .{tracee.pid});
    if (!self.local.remove(tracee.pid)) {
        return error.NoSuchPid;
    }
}

pub fn is_executing(self: *ProcessManager, tracee: *const Tracee) bool {
    return self.local.contains(tracee.pid);
}

pub fn remote_execution(self: *ProcessManager, tracee: *const Tracee, args: Tracee.ExecveArgs, ipc_stream: std.net.Stream) !void {
    defer args.deinit();

    const cwd = try utils.getCWDPathAlloc(self.allocator, tracee.pid);
    defer self.allocator.free(cwd);

    const argv_packed = try pack_double_array(self.allocator, args.argv);
    defer self.allocator.free(argv_packed);
    const envp_packed = try pack_double_array(self.allocator, args.envp);
    defer self.allocator.free(envp_packed);

    const cwdZ = try self.allocator.dupeZ(u8, cwd);
    defer self.allocator.free(cwdZ);
    const exit_code = try self.executor_rpc.?.execute(net.ExecuteArgs{
        .cwd = cwdZ,
        .exe = args.exe,
        .argv = argv_packed,
        .envp = envp_packed,
    });
    defer exit_code.deinit();

    try ipc_stream.writeAll(&std.mem.toBytes(exit_code.value.return_value));

    {
        self.waiting_threads_mu.lock();
        defer self.waiting_threads_mu.unlock();
        std.debug.assert(self.waiting_threads.remove(tracee.pid));
    }
}

pub fn pack_double_array(allocator: std.mem.Allocator, array: [][*:0]const u8) ![][:0]const u8 {
    var result = try allocator.alloc([:0]const u8, array.len);
    for (0..array.len) |i| {
        result[i] = std.mem.span(array[i]);
    }

    return result;
}
