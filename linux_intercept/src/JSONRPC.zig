const JSONRPC = @This();
const std = @import("std");
const log = std.log.scoped(.json_rpc);

const PendingEntry = struct {
    slice: []const u8,
};

allocator: std.mem.Allocator,
next_id: usize,
write_lock: std.Thread.Mutex,
reader_lock: std.Thread.Mutex,
pending: std.AutoHashMap(usize, PendingEntry),
//TODO Might be rwlock
pending_lock: std.Thread.Mutex,
pending_reset: std.Thread.ResetEvent,

pub fn init(allocator: std.mem.Allocator) JSONRPC {
    return .{
        .allocator = allocator,
        .next_id = 0,
        .write_lock = .{},
        .pending = std.AutoHashMap(usize, PendingEntry).init(allocator),
        .pending_lock = .{},
        .reader_lock = .{},
        .pending_reset = .{},
    };
}

pub fn deinit(self: JSONRPC) void {
    var it = self.pending.iterator();

    while (it.next()) |e| {
        self.allocator.free(e.value_ptr.slice);
    }
}

pub fn send_message(self: *JSONRPC, writer: anytype, method: []const u8, params: anytype) !usize {
    self.write_lock.lock();
    defer self.write_lock.unlock();

    const id = self.next_id;
    log.debug("send {s}, id {}: {any}", .{ method, id, params });
    try std.json.stringify(.{ .jsonrpc = "2.0", .method = method, .params = params, .id = self.next_id }, .{}, writer);
    try writer.writeAll(&[_]u8{0});
    self.next_id += 1;
    return id;
}

pub fn read_response(self: *JSONRPC, id: usize, reader: anytype, ResponseType: type) !Response(ResponseType) {
    log.debug("read {s}, id {}", .{ @typeName(ResponseType), id });

    //Check pending
    //Try read
    // Read untill yours and wake up others
    //Go sleep
    //Repeat
    while (true) {
        self.pending_lock.lock();
        if (self.pending.get(id)) |pending| {
            _ = self.pending.remove(id);

            self.pending_lock.unlock();

            //Parse it right now
            return try self.parseResponseFromSlice(pending.slice, ResponseType);
        } else {
            self.pending_lock.unlock();

            if (self.reader_lock.tryLock()) {
                errdefer self.reader_lock.unlock();
                self.pending_reset.reset();

                //Second check because some slow thread can hop into reading
                //when it's id been already added by a faster thread
                self.pending_lock.lock();
                if (self.pending.get(id)) |pending| {
                    _ = self.pending.remove(id);

                    self.pending_reset.set();
                    self.reader_lock.unlock();
                    self.pending_lock.unlock();
                    return try self.parseResponseFromSlice(pending.slice, ResponseType);
                }
                self.pending_lock.unlock();

                while (true) {
                    const json_slice = try reader.readUntilDelimiterAlloc(self.allocator, 0, std.json.default_max_value_len);
                    errdefer self.allocator.free(json_slice);

                    const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_slice, .{});
                    defer parsed.deinit();

                    switch (parsed.value) {
                        .object => |obj| {
                            const parsed_id: std.json.Value = obj.get("id") orelse {
                                std.debug.panic("No result field", .{});
                            };

                            if (parsed_id.integer == id) {
                                self.reader_lock.unlock();

                                {
                                    self.pending_lock.lock();
                                    defer self.pending_lock.unlock();
                                    self.pending_reset.set();
                                }

                                return try self.parseResponseFromSlice(json_slice, ResponseType);
                            } else {
                                self.pending_lock.lock();
                                defer self.pending_lock.unlock();

                                try self.pending.put(@bitCast(parsed_id.integer), .{
                                    .slice = json_slice,
                                });
                                self.pending_reset.set();
                            }
                        },
                        else => {
                            std.debug.panic("Unexpected json response", .{});
                        },
                    }
                }
            } else {
                self.pending_reset.wait();
                self.pending_reset.reset();
            }
        }
    }
    while (true) {
        const json_slice = try reader.readUntilDelimiterAlloc(self.allocator, 0, std.json.default_max_value_len);

        return try self.parseResponseFromSlice(json_slice, ResponseType);
    }

    //FIXME: Unoptimal. Wakes many threads at once
}
pub fn parseResponseFromSlice(self: *JSONRPC, json_slice: []const u8, ResponseType: type) !Response(ResponseType) {
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
        .allocator = self.allocator,
        .json_slice = json_slice,
        .value = parsed_value.value,
        .parsed = parsed,
        .parsed_value = parsed_value,
    };
}

pub fn Response(Result: type) type {
    return struct {
        value: Result,
        parsed: std.json.Parsed(std.json.Value),
        parsed_value: std.json.Parsed(Result),
        allocator: std.mem.Allocator,
        json_slice: []const u8,

        pub fn deinit(self: @This()) void {
            self.parsed_value.deinit();
            self.parsed.deinit();
            self.allocator.free(self.json_slice);
        }
    };
}
