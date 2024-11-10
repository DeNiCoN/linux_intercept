const std = @import("std");
const c = @cImport({
    @cInclude("string.h");
});

pub fn sys_panic(comptime str: []const u8, args: anytype) void {
    const errno_str = c.strerror(std.c._errno().*);

    std.debug.panic(str ++ ": {s}", args ++ .{errno_str});
}
