const std = @import("std");

pub fn main() !u8 {
//    std.debug.print("Environ {s}\n", .{std.os.environ});
    _ = try std.io.getStdOut().write("HAHAHAHAHAH! MEOW!\n");
    return 0;
}
