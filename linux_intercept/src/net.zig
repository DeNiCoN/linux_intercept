pub const Args = struct {
    exe: [:0]const u8,
    cwd: [:0]const u8,
    argv: [][:0]const u8,
    envp: [][:0]const u8,
};
