const std = @import("std");
const RPCServer = @import("RPCServer.zig");

const FileCacheServer = @This();

rpc_server: RPCServer,

pub fn init(allocator: std.mem.Allocator, listen_address: std.net.Address) !FileCacheServer {
    const rpc_server = try RPCServer.init(allocator, listen_address);
    return .{
        .rpc_server = rpc_server,
    };
}

pub fn deinit(self: *FileCacheServer) void {
    self.rpc_server.deinit();
}

pub fn run(self: *FileCacheServer) !void {
    //FIXME: Ideally we should be able to signal FileCacheServer that it should quit
    //TODO Try to use poll/epoll with some pipe
    try self.rpc_server.run_single();
}
