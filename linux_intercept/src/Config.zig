const std = @import("std");

const remote_cache_port = 23424;
pub const remote_cache_address = std.net.Address{ .in = std.net.Ip4Address.parse("127.0.0.1", remote_cache_port) catch unreachable };
// = std.net.Address{ .in6 = std.net.Ip6Address.parse("", remote_cache_port) catch {} };

const executor_port = 23423;
pub const executor_address = std.net.Address{ .in = std.net.Ip4Address.parse("127.0.0.1", executor_port) catch unreachable };
