const std = @import("std");
const net = @import("net.zig");
const JSONRPC = @import("JSONRPC.zig");

const log = std.log.scoped(.executor_rpc_client);
const ExecutorRPCClient = @This();

const buf_size = 1024 * 1024;

const BufferedReader = std.io.BufferedReader(buf_size, std.net.Stream.Reader);
const BufferedWriter = std.io.BufferedWriter(buf_size, std.net.Stream.Writer);

jsonrpc: JSONRPC,
stream: std.net.Stream,
reader: BufferedReader,
writer: BufferedWriter,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, address: std.net.Address) !ExecutorRPCClient {
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

pub fn connect(self: *ExecutorRPCClient, file_cache_port: u16, process_manager_port: u16) !JSONRPC.Response(net.ConnectResponse) {
    const id = try self.jsonrpc.send_message(self.writer.writer(), "connect", net.ConnectArgs{ .cache_port = file_cache_port, .manager_port = process_manager_port });
    try self.writer.flush();
    return try self.jsonrpc.read_response(id, self.reader.reader(), net.ConnectResponse);
}

pub fn disconnect(self: *ExecutorRPCClient) !JSONRPC.Response(net.DisconnectResponse) {
    const id = try self.jsonrpc.send_message(self.writer.writer(), "disconnect", net.DisconnectArgs{});
    try self.writer.flush();
    return try self.jsonrpc.read_response(id, self.reader.reader(), net.DisconnectResponse);
}

pub fn execute(self: *ExecutorRPCClient, args: net.ExecuteArgs) !JSONRPC.Response(net.ExecuteResponse) {
    const id = try self.jsonrpc.send_message(self.writer.writer(), "execute", args);
    try self.writer.flush();
    return try self.jsonrpc.read_response(id, self.reader.reader(), net.ExecuteResponse);
}

pub fn deinit(self: *ExecutorRPCClient) void {
    self.writer.flush() catch {};
    self.stream.close();
}
