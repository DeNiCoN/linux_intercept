const std = @import("std");

pub const ExecuteArgs = struct {
    exe: [:0]const u8,
    cwd: [:0]const u8,
    argv: [][:0]const u8,
    envp: [][:0]const u8,
};

pub const ExecuteResponse = struct {
    return_value: u8,
};

pub const FetchFileArgs = struct {
    name: []const u8,
};

pub const FetchFileResponse = struct {
    status: enum {
        FileIncoming,
        NoFile,
        IsDir,
    },

    mode: std.fs.File.Mode,
};

pub const SendFileArgs = struct {
    name: []const u8,
};

pub const SendFileResponse = struct {
    status: enum { Ok },
};

pub const ConnectArgs = struct {
    cache_port: u16,
    manager_port: u16,
};

pub const ConnectResponse = struct {};

pub const DisconnectArgs = struct {};

pub const DisconnectResponse = struct {};
