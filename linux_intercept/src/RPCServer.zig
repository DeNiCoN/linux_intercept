const std = @import("std");
const net = @import("net.zig");
const FileCacheClient = @import("FileCacheClient.zig");

const log = std.log.scoped(.rpc_server);

const RPCServer = @This();

server: std.net.Server,
allocator: std.mem.Allocator,
next_id: usize,

pub fn init(allocator: std.mem.Allocator, port: u16) !RPCServer {
    const loopback = try std.net.Ip4Address.parse("127.0.0.1", port);
    const localhost = std.net.Address{ .in = loopback };
    const server = try localhost.listen(.{ .reuse_port = true });

    return .{
        .server = server,
        .next_id = 0,
        .allocator = allocator,
    };
}

pub fn deinit(self: *RPCServer) void {
    self.server.deinit();
}

const JSONRPCRequest = struct {
    jsonrpc: []const u8,
    method: []const u8,
    params: std.json.Value,
    id: usize,
};

pub fn run_single(self: *RPCServer) !void {
    self.run_single_impl() catch |err| switch (err) {
        error.UnexpectedEndOfInput => return,
        error.EndOfStream => return,
        else => return err,
    };
}

pub fn run_single_impl(self: *RPCServer) !void {
    log.debug("Listening on {}", .{self.server.listen_address.getPort()});
    const connection = try self.server.accept();
    log.debug("Got connection {}", .{connection.address});
    defer connection.stream.close();

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    var buffered_reader = std.io.bufferedReader(connection.stream.reader());
    while (true) {
        defer _ = arena.reset(.retain_capacity);
        log.debug("Reading next message", .{});
        const json_slice = try buffered_reader.reader().readUntilDelimiterAlloc(arena.allocator(), 0, std.json.default_max_value_len);
        defer arena.allocator().free(json_slice);
        var parsed = try std.json.parseFromSlice(JSONRPCRequest, arena.allocator(), json_slice, .{});
        defer parsed.deinit();

        if (std.mem.eql(u8, parsed.value.method, "fetchFile")) {
            log.debug("fetchFile", .{});
            const params = try std.json.parseFromValue(net.FetchFileArgs, arena.allocator(), parsed.value.params, .{});
            defer params.deinit();

            const response = try self.fetchFile(params.value.name);
            try self.send_response(connection.stream.writer(), response);
            const file = try std.fs.openFileAbsolute(params.value.name, .{});
            try FileCacheClient.streamWriteFile(connection.stream.writer(), file);
            log.debug("fetchFile finished", .{});
        } else if (std.mem.eql(u8, parsed.value.method, "sendFile")) {
            log.debug("sendFile", .{});
            const params = try std.json.parseFromValue(net.SendFileArgs, arena.allocator(), parsed.value.params, .{});
            defer params.deinit();

            const response = try self.sendFile(params.value.name);
            try self.send_response(connection.stream.writer(), response);

            const dir = try std.fs.cwd().makeOpenPath("test/send_output", .{});
            const file = try dir.createFile(params.value.name, .{});
            try FileCacheClient.streamReadFile(buffered_reader.reader(), file);
            log.debug("sendFile finished", .{});
        }
    }
}

pub fn send_response(self: *RPCServer, writer: anytype, result: anytype) !void {
    log.debug("Sending {s}", .{@typeName(@TypeOf(result))});
    var buffered_writer = std.io.bufferedWriter(writer);
    try std.json.stringify(.{ .jsonrpc = "2.0", .result = result, .id = self.next_id }, .{}, buffered_writer.writer());
    try buffered_writer.writer().writeAll(&[_]u8{0});
    try buffered_writer.flush();
    self.next_id += 1;
}

pub fn sendFile(self: *RPCServer, name: []const u8) !net.SendFileResponse {
    _ = self;
    _ = name;

    return .{
        .status = .Ok,
    };
}

pub fn fetchFile(self: *RPCServer, name: []const u8) !net.FetchFileResponse {
    _ = self;
    const file = try std.fs.openFileAbsolute(name, .{});

    return .{
        .status = .FileIncoming,
        .mode = (try file.stat()).mode,
    };
}
