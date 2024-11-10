const FileCacheClient = @This();

pub fn init() FileCacheClient {
    return .{};
}

pub fn file(self: *FileCacheClient, name: [:0]const u8) [:0]const u8 {
    _ = self;
    return name;
}
