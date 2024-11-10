const std = @import("std");
const log = std.log;
const net = std.net;
const Tracee = @import("Tracee.zig");

local: std.AutoHashMap(c_long, bool),
allocator: std.mem.Allocator,

const ProcessManager = @This();

pub fn init(allocator: std.mem.Allocator) ProcessManager {
    return .{
        .local = std.AutoHashMap(c_long, bool).init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *ProcessManager) void {
    self.local.deinit();
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
    try tracee.replace_execve_to_stub();
    tracee.detach();

    try self.send_to_remote(tracee, args);
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

pub fn send_to_remote(self: *ProcessManager, tracee: *const Tracee, args: Tracee.ExecveArgs) !void {
    const loopback = try net.Ip4Address.parse("127.0.0.1", 23423);
    const localhost = net.Address{ .in = loopback };

    std.log.debug("Connecting to {}", .{loopback.getPort()});
    const stream = try net.tcpConnectToAddress(localhost);
    std.log.info("Connected", .{});
    defer stream.close();

    const cwd = try std.fs.cwd().realpathAlloc(self.allocator, ".");
    defer self.allocator.free(cwd);
    _ = tracee;
    try std.json.stringify(.{ .exe = args.exe, .cwd = cwd, .argv = args.argv, .envp = args.envp }, .{}, stream.writer());
}
