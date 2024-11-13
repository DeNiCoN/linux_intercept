const std = @import("std");

pub const Args = struct {
    exe: [:0]const u8,
    cwd: [:0]const u8,
    argv: [][:0]const u8,
    envp: [][:0]const u8,
};

pub const FetchFileArgs = struct {
    name: []const u8,
};

pub const FetchFileResponse = struct {
    status: enum {
        FileIncoming,
        NoFile,
    },

    mode: std.fs.File.Mode,
};

pub const SendFileArgs = struct {
    name: []const u8,
};

pub const SendFileResponse = struct {
    status: enum { Ok },
};
