const std = @import("std");
const src = @import("src");

pub const std_options: std.Options = .{
    .log_level = .info,

    .log_scope_levels = &[_]std.log.ScopeLevel{
        .{ .scope = .tracee_memory, .level = .info },
        .{ .scope = .rpc_server, .level = .debug },
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

    var server = try src.FileCacheServer.init(allocator.allocator(), src.Config.remote_cache_address);
    defer server.deinit();
    try server.run();
    return 0;
}
