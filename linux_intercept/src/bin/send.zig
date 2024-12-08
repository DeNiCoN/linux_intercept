const std = @import("std");
const net = std.net;
// const src = @import("src");
// const RPCClient = src.RPCClient;

pub const testStruct = struct {
    connect: fn (file_cache_port: u16) void,
};
//const rpcs = JSONRPC(.{.connect = })

const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn testFn(file_cache_port: u16) void {
    std.log.info("Test {}", .{file_cache_port});
}

pub fn main() !u8 {
    const a = testStruct{
        .connect = testFn,
    };
    a.connect(16);
    std.log.info("{}", .{@typeInfo(testStruct).Struct});
    return 0;

    // var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    // defer _ = allocator.deinit();

    // var rpc = try RPCClient.init(allocator.allocator(), src.Config.executor_address);
    // defer rpc.deinit();

    // const videos_dir = try std.fs.cwd().openDir("test/input_videos", .{ .iterate = true });

    // var videos_dir_walker = try videos_dir.walk(allocator.allocator());
    // defer videos_dir_walker.deinit();

    // var totalFileSize: usize = 0;
    // var timer = try std.time.Timer.start();

    // while (try videos_dir_walker.next()) |entry| {
    //     switch (entry.kind) {
    //         .file => {
    //             std.log.info("File: {s}", .{entry.path});
    //             const resp = try rpc.sendFile(entry.path);
    //             defer resp.deinit();
    //             if (resp.value.status != .Ok)
    //                 std.debug.panic("Unexpected response", .{});

    //             const file = try entry.dir.openFile(entry.path, .{});
    //             defer file.close();

    //             totalFileSize += (try file.stat()).size;
    //             try src.FileCacheClient.streamWriteFile(rpc.writer.writer(), file);
    //             try rpc.writer.flush();
    //         },
    //         else => {
    //             continue;
    //         },
    //     }
    // }

    // std.log.info("Wrote {} MB of data in {} milliseconds", .{ totalFileSize / (1024 * 1024), timer.read() / (1000 * 1000) });
    // return 0;
}
