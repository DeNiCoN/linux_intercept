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
    try self.rpc_server.run_consecutive();
}
