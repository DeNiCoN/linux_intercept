const std = @import("std");

pub fn main() !u8 {
    //    std.debug.print("Environ {s}\n", .{std.os.environ});
    _ = try std.io.getStdOut().write("HAHAHAHAHAH! MEOW!\n");
    var argsIt = std.process.args();
    _ = argsIt.next();
    const socket_path = argsIt.next().?;
    const stream = try std.net.connectUnixSocket(socket_path);

    _ = try std.io.getStdOut().write("Waiting for return code");
    const return_code = try stream.reader().readByte();
    try std.fmt.format(std.io.getStdOut().writer(), "return code = {}", .{return_code});

    return return_code;
}
