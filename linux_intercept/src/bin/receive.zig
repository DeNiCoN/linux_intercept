const std = @import("std");
const net = std.net;
const src = @import("src");
const RPCServer = src.RPCServer;

pub fn main() !u8 {
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = allocator.deinit();
    {
        var env_map = try src.Dotenv.load_env_map(allocator.allocator());
        defer env_map.deinit();
        try src.Config.read_from_env_map(env_map);
    }

    var rpc = try RPCServer.init(allocator.allocator(), src.Config.executor_address.getPort());
    defer rpc.deinit();

    try rpc.run_single();

    return 0;
}
