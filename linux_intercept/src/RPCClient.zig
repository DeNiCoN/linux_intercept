const std = @import("std");
const net = @import("net.zig");

const log = std.log.scoped(.rpc_client);

const RPCClient = @This();

const buf_size = 1024 * 1024;

const BufferedReader = std.io.BufferedReader(buf_size, std.net.Stream.Reader);

stream: std.net.Stream,
reader: BufferedReader,
writer: std.io.BufferedWriter(buf_size, std.net.Stream.Writer),
next_id: usize,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, address: std.net.Address) !RPCClient {
    log.debug("Connecting to {}", .{address});
    const stream = try std.net.tcpConnectToAddress(address);
    log.info("Connected", .{});

    return .{
        .stream = stream,
        .reader = std.io.BufferedReader(buf_size, std.net.Stream.Reader){ .unbuffered_reader = stream.reader() },
        .writer = std.io.BufferedWriter(buf_size, std.net.Stream.Writer){ .unbuffered_writer = stream.writer() },
        .next_id = 0,
        .allocator = allocator,
    };
}

pub fn fetchFile(self: *RPCClient, name: []const u8) !Response(net.FetchFileResponse) {
    log.debug("Fetch file {s}", .{name});
    try self.send_message("fetchFile", net.FetchFileArgs{ .name = name });
    return try self.read_response(net.FetchFileResponse);
}

pub fn sendFile(self: *RPCClient, name: []const u8) !Response(net.SendFileResponse) {
    log.debug("Send file {s}", .{name});
    try self.send_message("sendFile", net.SendFileArgs{ .name = name });
    return try self.read_response(net.SendFileResponse);
}

pub fn send_message(self: *RPCClient, method: []const u8, params: anytype) !void {
    try std.json.stringify(.{ .jsonrpc = "2.0", .method = method, .params = params, .id = self.next_id }, .{}, self.writer.writer());
    try self.writer.writer().writeAll(&[_]u8{0});
    try self.writer.flush();
    self.next_id += 1;
}

pub fn deinit(self: RPCClient) void {
    self.stream.close();
}

pub fn Response(Result: type) type {
    return struct {
        value: Result,
        parsed: std.json.Parsed(std.json.Value),
        parsed_value: std.json.Parsed(Result),

        pub fn deinit(self: @This()) void {
            self.parsed_value.deinit();
            self.parsed.deinit();
        }
    };
}

pub fn read_response(self: *RPCClient, ResponseType: type) !Response(ResponseType) {
    log.debug("Reading {s}", .{@typeName(ResponseType)});
    const json_slice = try self.reader.reader().readUntilDelimiterAlloc(self.allocator, 0, std.json.default_max_value_len);
    defer self.allocator.free(json_slice);
    const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_slice, .{});

    const parsed_value = switch (parsed.value) {
        .object => |obj| blk: {
            const res: std.json.Value = obj.get("result") orelse {
                std.debug.panic("No result field", .{});
            };

            break :blk try std.json.parseFromValue(ResponseType, self.allocator, res, .{});
        },
        else => {
            std.debug.panic("Unexpected json response", .{});
        },
    };

    return .{
        .value = parsed_value.value,
        .parsed = parsed,
        .parsed_value = parsed_value,
    };
}
