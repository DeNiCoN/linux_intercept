const std = @import("std");

pub fn main() !u8 {
    _ = try std.io.getStdOut().write("HAHAHAHAHAH! MEOW!\n");
    return 0;
}
