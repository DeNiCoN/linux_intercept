const std = @import("std");
const RPCClient = @import("RPCClient.zig");

const FileCacheClient = @This();

root_name: []const u8,
root_dir: std.fs.Dir,
rpc: RPCClient,
cached: std.StringHashMap(bool),

pub fn init(allocator: std.mem.Allocator, root: []const u8, address: std.net.Address) FileCacheClient {
    try std.fs.makeDirAbsolute(root);
    const root_dir = try std.fs.openDirAbsolute(root, {});
    const rpc = RPCClient.init(address);

    const cached = std.AutoHashMap([]const u8, bool).init(allocator);
    return .{
        .root_name = root,
        .root_dir = root_dir,
        .rpc = rpc,
        .cached = cached,
    };
}

pub fn deinit(self: FileCacheClient) void {
    self.cached.deinit();
    self.rpc.deinit();
}

pub fn file(self: *FileCacheClient, allocator: std.mem.Allocator, name: []const u8) ![:0]const u8 {
    if (!std.fs.path.isAbsolute(name)) {
        std.debug.panic("Not absolute path in cache: {}", .{name});
    }
    const result_path = try std.fs.path.joinZ(allocator, &[_][]const u8{ self.root_name, name[1..] });
    if (self.is_cached(name)) {
        return result_path;
    } else {
        const response = try self.rpc.fetchFile(name);
        defer response.deinit();

        switch (response.value.status) {
            .FileIncoming => {
                const opened_file = try std.fs.createFileAbsolute(result_path, .{ .mode = response.mode });
                defer opened_file.close();

                self.streamReadFile(self.rpc.stream, opened_file);
            },
            .NoFile => {
                self.cache_no_file(name);
            },
        }

        try self.cached.put(name, true);
    }

    return result_path;
}

pub fn is_cached(self: FileCacheClient, name: []const u8) bool {
    return self.cached.contains(name);
}

pub fn cache_no_file(name: []const u8) void {
    _ = name;
}

pub fn streamReadFile(buffered_reader: anytype, opened_file: std.fs.File) !void {
    const contents_size = try buffered_reader.readInt(u64, .little);
    std.log.debug("Stream read file of size {}", .{contents_size});
    var size_left = contents_size;
    var buf: [1024 * 1024]u8 = undefined;

    while (size_left != 0) {
        const to_read = @min(size_left, buf.len);
        const read = try buffered_reader.readAll(buf[0..to_read]);
        if (read != to_read) {
            std.debug.panic("End of stream {} {}", .{read, to_read});
        }
        try opened_file.writeAll(buf[0..to_read]);
        size_left -= to_read;
    }
}

pub fn streamWriteFile(buffered_writer: anytype, fileToSend: std.fs.File) !void {
    const contents_size: u64 = (try fileToSend.stat()).size;
    std.log.debug("Stream write file of size {}", .{contents_size});
    try buffered_writer.writeInt(u64, contents_size, .little);

    const reader = fileToSend.reader();
    var size_left = contents_size;
    var buf: [1024 * 1024]u8 = undefined;

    while (size_left != 0) {
        const to_read = @min(size_left, buf.len);
        std.log.debug("Read file {}", .{@as(f64, @floatFromInt(size_left))/@as(f64, @floatFromInt(contents_size))});
        const read = try reader.readAll(buf[0..to_read]);
        if (read != to_read) {
            std.debug.panic("End of stream {} {}", .{read, to_read});
        }
        std.log.debug("Sending file {}", .{@as(f64, @floatFromInt(size_left))/@as(f64, @floatFromInt(contents_size))});
        try buffered_writer.writeAll(buf[0..to_read]);
        size_left -= to_read;
    }
    std.log.debug("Write finished", .{});
}
