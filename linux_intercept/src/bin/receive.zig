const std = @import("std");
const net = std.net;
const src = @import("src");
const RPCServer = src.RPCServer;

pub fn main() !u8 {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = allocator.deinit();

    var rpc = try RPCServer.init(allocator.allocator(), src.Config.executor_address.getPort());
    defer rpc.deinit();

    try rpc.run_single();

    return 0;
}
