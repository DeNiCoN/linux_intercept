const std = @import("std");
const net = @import("net.zig");
const FileCacheClient = @import("FileCacheClient.zig");

const log = std.log.scoped(.rpc_server);

const JSONRPCServer = @This();

server: std.net.Server,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, listen_address: std.net.Address) !JSONRPCServer {
    const server = try listen_address.listen(.{ .reuse_port = true });

    return .{
        .server = server,
        .allocator = allocator,
    };
}

pub fn deinit(self: *JSONRPCServer) void {
    self.server.deinit();
}

const JSONRPCRequest = struct {
    jsonrpc: []const u8,
    method: []const u8,
    params: std.json.Value,
    id: usize,
};

pub const Connection = struct {
    connection: std.net.Server.Connection,
    buffered_reader: std.io.BufferedReader(4096, std.net.Stream.Reader),
    write_lock: std.Thread.Mutex,

    pub fn init(connection: std.net.Server.Connection) !Connection {
        return .{
            .connection = connection,
            .buffered_reader = std.io.bufferedReader(connection.stream.reader()),
            .write_lock = .{},
        };
    }

    pub fn close(self: *Connection) void {
        self.connection.stream.close();
    }

    pub const Request = struct {
        value: JSONRPCRequest,
        parsed: std.json.Parsed(JSONRPCRequest),
        json_slice: []const u8,
        allocator: std.mem.Allocator,
        id: usize,

        pub fn deinit(self: Request) void {
            self.allocator.free(self.json_slice);
            self.parsed.deinit();
        }
    };

    pub fn next(self: *Connection, allocator: std.mem.Allocator) !?Request {
        log.debug("reading next message", .{});
        const json_slice = try self.buffered_reader.reader().readUntilDelimiterAlloc(allocator, 0, std.json.default_max_value_len);
        errdefer allocator.free(json_slice);
        const parsed = try std.json.parseFromSlice(JSONRPCRequest, allocator, json_slice, .{});
        errdefer parsed.deinit();

        log.debug("request method: {s}", .{parsed.value.method});
        return .{
            .parsed = parsed,
            .value = parsed.value,
            .json_slice = json_slice,
            .allocator = allocator,
            .id = parsed.value.id,
        };
    }

    pub fn send_response(self: *Connection, id: usize, result: anytype) !void {
        self.write_lock.lock();
        defer self.write_lock.unlock();
        log.debug("Sending {s}", .{@typeName(@TypeOf(result))});
        var buffered_writer = std.io.bufferedWriter(self.connection.stream.writer());
        try std.json.stringify(.{ .jsonrpc = "2.0", .result = result, .id = id }, .{}, buffered_writer.writer());
        try buffered_writer.writer().writeAll(&[_]u8{0});
        try buffered_writer.flush();
    }
};

pub fn accept(self: *JSONRPCServer) !Connection {
    const connection = try self.server.accept();
    log.debug("Got connection {}", .{connection.address});

    return Connection.init(connection);
}
