const std = @import("std");
const log = std.log;
const os = std.os;
const systable = @import("systable.zig");
const sys_panic = @import("utils.zig").sys_panic;

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("sys/ptrace.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/user.h");
    @cInclude("sys/syscall.h");
    @cInclude("sys/mman.h");
    @cInclude("fcntl.h");
    @cInclude("string.h");
    @cInclude("preload.h");
});

const Ptrace = @import("linux_intercept.zig").Ptrace;

pub const TraceeStatus = enum { EnterSyscall, ExitSyscall, LocalExecution };
pub const StopReason = enum { None, ExecveEnter, Exit };

pub const ExecveArgs = struct {
    exe: [:0]const u8,
    argv: [][*:0]const u8,
    envp: [][*:0]const u8,
    allocator: std.mem.Allocator,

    pub fn from_tracee(
        tracee: Tracee,
        allocator: std.mem.Allocator,
    ) !ExecveArgs {
        const argv = try read_string_array(tracee, tracee.regs.rsi, allocator);
        const envp = try read_string_array(tracee, tracee.regs.rdx, allocator);
        const exe = try tracee.read_string(tracee.regs.rdi, allocator);

        return .{
            .allocator = allocator,
            .exe = exe,
            .argv = argv,
            .envp = envp,
        };
    }

    pub fn deinit(self: *ExecveArgs) void {
        defer self.allocator.free(self.exe);
        defer free_string_array(self.allocator, self.argv);
        defer free_string_array(self.allocator, self.envp);
    }

    pub fn can_be_executed(self: ExecveArgs) bool {
        _ = self;
        return true;
    }
};

pub const Tracee = struct {
    pid: c_long,
    regs: c.user_regs_struct = .{},
    status: TraceeStatus,
    stop_reason: StopReason,
    ptrace: *Ptrace,

    pub fn replace_execve_to_stub(self: *Tracee) !void {
        self.regs.rdi = self.ptrace.stub_exe_remote_address(self);
        self.regs.rsi = self.ptrace.stub_argv_remote_address(self);
        self.regs.rdx = self.ptrace.stub_envp_remote_address(self);
        if (c.ptrace(c.PTRACE_SETREGS, self.pid, @as(c_int, 0), &self.regs) == -1) {
            sys_panic("failed to set regs for [{}]", .{self.pid});
        }

        var buf: [512]u8 = undefined;
        var allocator = std.heap.FixedBufferAllocator.init(&buf);

        log.info("Exe: {s}", .{self.read_string(self.regs.rdi, allocator.allocator()) catch ""});

        const argv = try read_string_array(self.*, self.regs.rsi, allocator.allocator());
        log.info("Argv: {s}", .{argv});

        log.info("Envp: {}", .{self.regs.rdx});
    }

    pub fn get_execve_args(self: Tracee, allocator: std.mem.Allocator) !ExecveArgs {
        return ExecveArgs.from_tracee(self, allocator);
    }

    pub fn cont(self: *Tracee) void {
        switch (self.status) {
            .EnterSyscall => {
                if (c.ptrace(c.PTRACE_SYSCALL, self.pid, @as(c_int, 0), @as(c_int, 0)) == -1) {
                    sys_panic("trace end", .{});
                }

                self.status = .ExitSyscall;
                log.debug("Exit next", .{});
            },
            .ExitSyscall => {
                if (c.ptrace(c.PTRACE_SYSCALL, self.pid, @as(c_int, 0), @as(c_int, 0)) == -1) {
                    sys_panic("trace end", .{});
                }

                self.status = .EnterSyscall;
                log.debug("Enter next", .{});
            },
            .LocalExecution => {
                if (c.ptrace(c.PTRACE_CONT, self.pid, @as(c_int, 0), @as(c_int, 0)) == -1) {
                    sys_panic("trace end", .{});
                }
                log.debug("LOCAL_EXEC_CONT", .{});
            },
        }

        self.stop_reason = .None;
    }

    pub fn cont_same(self: *Tracee) void {
        switch (self.status) {
            .EnterSyscall => {
                if (c.ptrace(c.PTRACE_SYSCALL, self.pid, @as(c_int, 0), @as(c_int, 0)) == -1) {
                    sys_panic("trace end", .{});
                }
                log.debug("Exit next", .{});
            },
            .ExitSyscall => {
                if (c.ptrace(c.PTRACE_SYSCALL, self.pid, @as(c_int, 0), @as(c_int, 0)) == -1) {
                    sys_panic("trace end", .{});
                }
                log.debug("Enter next", .{});
            },
            .LocalExecution => {
                if (c.ptrace(c.PTRACE_CONT, self.pid, @as(c_int, 0), @as(c_int, 0)) == -1) {
                    sys_panic("trace end", .{});
                }
                log.debug("LOCAL_EXEC_CONT", .{});
            },
        }

        self.stop_reason = .None;
    }

    pub fn detach(self: *Tracee) void {
        if (c.ptrace(c.PTRACE_DETACH, self.pid, @as(c_int, 0), @as(c_int, 0)) == -1)
            sys_panic("trace detach", .{});
    }

    pub fn local_execution(self: *Tracee) void {
        self.status = .LocalExecution;
        self.cont();
    }

    pub fn update_regs(self: *Tracee) !void {
        if (c.ptrace(c.PTRACE_GETREGS, self.pid, @as(c_int, 0), &self.regs) == -1) {
            if (std.c._errno().* == c.ESRCH) {
                log.debug("[{}] Child exit?", .{self.pid});
                return error.ChildExit;
            }

            sys_panic("trace get registers", .{});
        }
    }

    pub fn read_word(pid: c_long, remote_address: c_ulonglong) !usize {
        std.c._errno().* = 0;
        const word = c.ptrace(c.PTRACE_PEEKDATA, pid, remote_address, c.NULL);
        if (std.c._errno().* != 0) {
            if (std.c._errno().* == c.EFAULT or std.c._errno().* == c.EIO) {
                return error.FailedRead;
            } else {
                sys_panic("Unknown peekdata error", .{});
            }
        }

        return @bitCast(word);
    }

    pub fn read_string(self: Tracee, address: c_ulonglong, allocator: std.mem.Allocator) ![:0]const u8 {
        const INITIAL_BUFFER_SIZE = 32;
        var str_builder = std.ArrayList(u8).initCapacity(allocator, INITIAL_BUFFER_SIZE) catch {
            return error.OutOfMemory;
        };

        errdefer str_builder.deinit();

        var i: usize = 0;
        while (true) {
            const word = try read_word(self.pid, address + i);

            const word_bytes: [*]const u8 = @ptrCast(&word);

            for (0..@sizeOf(c_long)) |idx| {
                const byte = word_bytes[idx];
                if (byte == 0) {
                    break;
                }
                try str_builder.append(byte);
            }

            // Stop if we encountered a null terminator
            if (word_bytes[0] == 0 or word_bytes[1] == 0 or word_bytes[2] == 0 or word_bytes[3] == 0) {
                break;
            }

            i += @sizeOf(usize);
        }

        try str_builder.append(0);
        return str_builder.toOwnedSliceSentinel(0);
    }
};

pub fn read_string_array(tracee: Tracee, address: c_ulonglong, allocator: std.mem.Allocator) ![][*:0]const u8 {
    var string_array = std.ArrayList([*:0]const u8).init(allocator);
    errdefer string_array.deinit();

    const word_size = @sizeOf(usize);
    var i: usize = 0;
    var mem = try Tracee.read_word(tracee.pid, address + i * word_size);
    while (mem != 0) {
        try string_array.append(try tracee.read_string(mem, allocator));

        i += 1;
        mem = try Tracee.read_word(tracee.pid, address + i * word_size);
    }

    return try string_array.toOwnedSlice();
}

pub fn free_string_array(allocator: std.mem.Allocator, strings: [][*:0]const u8) void {
    _ = allocator;
    _ = strings;

    // var i: usize = 0;
    // while (strings[i] != null) : (i += 1) {
    //     allocator.free(strings[i].?);
    // }
    // allocator.free(strings);
}
