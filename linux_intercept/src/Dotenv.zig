const std = @import("std");
const log = std.log.scoped(.dotenv);

const INITIAL_BUF_SIZE = 64;

// Searches all .env files by going to the root
const DotenvIterator = struct {
    current_dir: std.fs.Dir,

    pub fn deinit(self: *DotenvIterator) void {
        self.current_dir.close();
    }

    pub fn next(self: *DotenvIterator) !?std.fs.File {
        while (true) {
            var old_dir = self.current_dir;
            defer old_dir.close();

            const file = old_dir.openFile(".env", .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    var root_buf = [1]u8{0};
                    if (std.mem.eql(u8, old_dir.realpath(".", &root_buf) catch "", "/"))
                        return null;

                    self.current_dir = try old_dir.openDir("..", .{});
                    continue;
                },
                else => {
                    return err;
                },
            };
            self.current_dir = try old_dir.openDir("..", .{});
            return file;
        }
    }
};

pub fn load_env_map(allocator: std.mem.Allocator) !std.process.EnvMap {
    var result = try std.process.getEnvMap(allocator);

    var dotenvIt = DotenvIterator{
        .current_dir = try std.fs.cwd().openDir(".", .{ .iterate = true }),
    };
    defer dotenvIt.deinit();

    var first_dotenv = try dotenvIt.next() orelse {
        return result;
    };
    var buff_reader = std.io.bufferedReader(first_dotenv.reader());
    var dotenv_map = try parse_env_map(allocator, buff_reader.reader());
    defer dotenv_map.deinit();

    var env_it = dotenv_map.iterator();
    while (env_it.next()) |e| {
        try result.put(e.key_ptr.*, e.value_ptr.*);
    }

    return result;
}

pub fn parse_env_map(allocator: std.mem.Allocator, reader: anytype) !std.process.EnvMap {
    var result = std.process.EnvMap.init(allocator);
    var var_name = try std.ArrayList(u8).initCapacity(allocator, INITIAL_BUF_SIZE);
    var var_value = try std.ArrayList(u8).initCapacity(allocator, INITIAL_BUF_SIZE);

    var state: enum {
        NoName,
        Name,
    } = .NoName;

    while (true) {
        const next = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        switch (state) {
            .NoName => {
                switch (next) {
                    ' ', '\t', '\n', '\r' => continue,
                    '#' => {
                        try reader.skipUntilDelimiterOrEof('\n');
                        continue;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        try var_name.append(next);
                        state = .Name;
                        continue;
                    },
                    else => {
                        log.err("Unexpected {} at a begining", .{next});
                        return error.UnexpectedToken;
                    },
                }
            },
            .Name => {
                switch (next) {
                    '=' => {
                        try reader.streamUntilDelimiter(var_value.writer(), '\n', null);
                        try result.putMove(try var_name.toOwnedSlice(), try var_value.toOwnedSlice());
                        state = .NoName;
                        continue;
                    },
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => {
                        try var_name.append(next);
                        state = .Name;
                        continue;
                    },
                    else => {
                        log.err("Unexpected {} during name parse", .{next});
                        return error.UnexpectedToken;
                    },
                }
            },
        }
    }

    return result;
}
