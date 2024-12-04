const std = @import("std");

pub const remote_cache_port_default: u16 = 23424;
pub const remote_cache_ip_default = "127.0.0.1";
pub var remote_cache_port: u16 = remote_cache_port_default;
pub var remote_cache_ip: []const u8 = remote_cache_ip_default;
pub var remote_cache_address = std.net.Address.resolveIp(remote_cache_ip_default, remote_cache_port_default) catch unreachable;

pub const executor_port_default: u16 = 23423;
pub const executor_ip_default = "127.0.0.1";
pub var executor_port: u16 = executor_port_default;
pub var executor_ip: []const u8 = executor_ip_default;
pub var executor_address = std.net.Address.resolveIp(executor_ip_default, executor_port_default) catch unreachable;

pub var preload_path: []const u8 = "/home/denicon/projects/Study/MagDiploma/linux_intercept/zig-out/lib/libpreload.so";
pub var executable: []const u8 = "ffmpeg";
pub var cache_directory: []const u8 = "/tmp/.cache/linux_intercept";

pub fn read_from_env_map(env_map: std.process.EnvMap) !void {
    if (env_map.get("REMOTE_CACHE_PORT")) |port_buf| {
        remote_cache_port = try std.fmt.parseInt(u16, port_buf, 10);
    }
    remote_cache_ip = env_map.get("REMOTE_CACHE_IP") orelse remote_cache_ip;
    remote_cache_address = try std.net.Address.resolveIp(remote_cache_ip, remote_cache_port);

    if (env_map.get("EXECUTOR_PORT")) |port_buf| {
        executor_port = try std.fmt.parseInt(u16, port_buf, 10);
    }
    executor_ip = env_map.get("EXECUTOR_IP") orelse executor_ip;
    executor_address = try std.net.Address.resolveIp(executor_ip, executor_port);

    executable = env_map.get("INTERCEPT_EXECUTABLE") orelse executable;
    cache_directory = env_map.get("EXECUTOR_CACHE_DIRECTORY") orelse cache_directory;
}

// defaults
// env
// .env
// args
