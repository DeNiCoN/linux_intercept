const std = @import("std");
const net = @import("net.zig");
const JSONRPC = @import("JSONRPC.zig");

const log = std.log.scoped(.rpc_client);

const RPCClient = @This();

const buf_size = 1024 * 1024;

const BufferedReader = std.io.BufferedReader(buf_size, std.net.Stream.Reader);
const BufferedWriter = std.io.BufferedWriter(buf_size, std.net.Stream.Writer);

jsonrpc: JSONRPC,
stream: std.net.Stream,
reader: BufferedReader,
writer: BufferedWriter,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, address: std.net.Address) !RPCClient {
    log.debug("Connecting to {}", .{address});
    const stream = try std.net.tcpConnectToAddress(address);
    log.info("Connected", .{});

    const reader = std.io.BufferedReader(buf_size, std.net.Stream.Reader){ .unbuffered_reader = stream.reader() };
    const writer = std.io.BufferedWriter(buf_size, std.net.Stream.Writer){ .unbuffered_writer = stream.writer() };
    return .{
        .jsonrpc = JSONRPC.init(allocator),
        .stream = stream,
        .reader = reader,
        .writer = writer,
        .allocator = allocator,
    };
}

pub fn fetchFile(self: *RPCClient, name: []const u8) !JSONRPC.Response(net.FetchFileResponse) {
    const id = try self.jsonrpc.send_message(self.writer.writer(), "fetchFile", net.FetchFileArgs{ .name = name });
    try self.writer.flush();
    return try self.jsonrpc.read_response(id, self.reader.reader(), net.FetchFileResponse);
}

pub fn sendFile(self: *RPCClient, name: []const u8) !JSONRPC.Response(net.SendFileResponse) {
    const id = try self.jsonrpc.send_message(self.writer.writer(), "sendFile", net.SendFileArgs{ .name = name });
    try self.writer.flush();
    return try self.jsonrpc.read_response(id,self.reader.reader(), net.SendFileResponse);
}

pub fn deinit(self: *RPCClient) void {
    self.writer.flush() catch {};
    self.stream.close();
}
