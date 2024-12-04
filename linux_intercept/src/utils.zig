const std = @import("std");
const c = @cImport({
    @cInclude("string.h");
});

pub fn sys_panic(comptime str: []const u8, args: anytype) void {
    const errno_str = c.strerror(std.c._errno().*);

    std.debug.panic(str ++ ": {s}", args ++ .{errno_str});
}

pub fn getCWDPathAlloc(allocator: std.mem.Allocator, pid: c_long) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "/proc/{}/cwd", .{ pid });
    defer allocator.free(path);
    const result_buf = try allocator.alloc(u8, std.posix.PATH_MAX);
    errdefer allocator.free(result_buf);

    var result = try std.posix.readlink(path, result_buf);
    result = try allocator.realloc(result_buf, result.len);
    return result;
}

pub fn getFDPathAlloc(allocator: std.mem.Allocator, pid: c_long, fd: c_ulonglong) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "/proc/{}/fd/{}", .{ pid, fd });
    defer allocator.free(path);
    const result_buf = try allocator.alloc(u8, std.posix.PATH_MAX);
    errdefer allocator.free(result_buf);

    var result = try std.posix.readlink(path, result_buf);
    result = try allocator.realloc(result_buf, result.len);
    return result;
}
