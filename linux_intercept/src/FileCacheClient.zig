const std = @import("std");
const RPCClient = @import("RPCClient.zig");

const FileCacheClient = @This();
const log = std.log.scoped(.file_client);

root_name: []const u8,
root_dir: std.fs.Dir,
rpc: RPCClient,
cached: std.StringHashMap(bool),

pub fn init(allocator: std.mem.Allocator, root: []const u8, address: std.net.Address) !FileCacheClient {
    log.debug("Creating directory at {s}", .{root});
    try std.fs.cwd().makePath(root);
    const root_dir = try std.fs.openDirAbsolute(root, .{});
    log.debug("Creating rpc to {}", .{address});
    const rpc = try RPCClient.init(allocator, address);

    const cached = std.StringHashMap(bool).init(allocator);
    return .{
        .root_name = root,
        .root_dir = root_dir,
        .rpc = rpc,
        .cached = cached,
    };
}

pub fn deinit(self: *FileCacheClient) void {
    var iterator = self.cached.iterator();
    while (iterator.next()) |entry| {
        self.cached.allocator.free(entry.key_ptr.*);
    }

    self.cached.deinit();
    self.rpc.deinit();
}

pub fn translate_name(self: FileCacheClient, allocator: std.mem.Allocator, name: []const u8) ![:0]const u8 {
    if (!std.fs.path.isAbsolute(name)) {
        std.debug.panic("Not absolute path in cache: {s}", .{name});
    }

    const result_path = try std.fs.path.joinZ(allocator, &[_][]const u8{ self.root_name, name[1..] });
    return result_path;
}

pub fn file(self: *FileCacheClient, allocator: std.mem.Allocator, name: []const u8) ![:0]const u8 {
    if (!std.fs.path.isAbsolute(name)) {
        std.debug.panic("Not absolute path in cache: {s}", .{name});
    }
    const result_path = try std.fs.path.joinZ(allocator, &[_][]const u8{ self.root_name, name[1..] });
    errdefer allocator.free(result_path);
    if (self.is_cached(name)) {
        return result_path;
    } else {
        const response = try self.rpc.fetchFile(name);
        defer response.deinit();

        switch (response.value.status) {
            .FileIncoming => {
                try self.root_dir.makePath(std.fs.path.dirname(result_path) orelse ".");

                const opened_file = try std.fs.createFileAbsolute(result_path, .{ .mode = response.value.mode });
                defer opened_file.close();

                try streamReadFile(self.rpc.reader.reader(), opened_file);
            },
            .NoFile => {
                try self.cache_no_file(name);
            },
            .IsDir => {
                //FIXME: Directories are empty by default
                self.root_dir.makePath(std.fs.path.dirname(result_path) orelse ".") catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => {
                        return err;
                    },
                };

                std.fs.makeDirAbsolute(result_path) catch |err| switch (err) {
                    error.PathAlreadyExists => {},
                    else => {
                        return err;
                    },
                };
            },
        }

        log.info("Value {s}", .{name});
        try self.cached.put(try self.cached.allocator.dupe(u8, name), true);
    }

    return result_path;
}

pub fn is_cached(self: FileCacheClient, name: []const u8) bool {
    return self.cached.contains(name);
}

pub fn cache_no_file(self: *FileCacheClient, name: []const u8) !void {
    try self.cached.put(try self.cached.allocator.dupe(u8, name), false);
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
            std.debug.panic("End of stream {} {}", .{ read, to_read });
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
    var buf: [16 * 1024 * 1024]u8 = undefined;

    while (size_left != 0) {
        const to_read = @min(size_left, buf.len);
        std.log.debug("Read file {}", .{@as(f64, @floatFromInt(size_left)) / @as(f64, @floatFromInt(contents_size))});
        const read = try reader.readAll(buf[0..to_read]);
        if (read != to_read) {
            std.debug.panic("End of stream {} {}", .{ read, to_read });
        }
        std.log.debug("Sending file {}", .{@as(f64, @floatFromInt(size_left)) / @as(f64, @floatFromInt(contents_size))});
        try buffered_writer.writeAll(buf[0..to_read]);
        size_left -= to_read;
    }
    std.log.debug("Write finished", .{});
}

pub fn sendFile(self: *FileCacheClient, path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) {
        std.debug.panic("Not absolute path in cache: {s}", .{path});
    }
    log.info("sendFile: {s}", .{path});
    const resp = try self.rpc.sendFile(path);
    defer resp.deinit();
    if (resp.value.status != .Ok)
        std.debug.panic("Unexpected response", .{});

    const result_path = try std.fs.path.joinZ(self.cached.allocator, &[_][]const u8{ self.root_name, path[1..] });
    defer self.cached.allocator.free(result_path);

    log.info("Sending {s}", .{result_path});
    const out_file = try std.fs.openFileAbsolute(result_path, .{});
    defer out_file.close();

    try FileCacheClient.streamWriteFile(self.rpc.writer.writer(), out_file);
    try self.rpc.writer.flush();
}
