const std = @import("std");
const log = std.log;
const tracee_memory_log = std.log.scoped(.tracee_memory);
const os = std.os;
const systable = @import("systable.zig");
const sys_panic = @import("utils.zig").sys_panic;
const builtin = @import("builtin");

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
    @cInclude("csrc/preload.h");
});

const Ptrace = @import("Ptrace.zig");
const Config = @import("Config.zig");

pub const Status = enum {
    EnterSyscall,
    ExitSyscall,
    LocalExecution,
};
pub const StopReason = enum {
    None,
    ExecveEnter,
    Exit,
    OpenAt,
    Access,
    Newfstatat,
    SchedGetAffinity,
};

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

    pub fn deinit(self: ExecveArgs) void {
        self.allocator.free(self.exe);
        free_string_array(self.allocator, self.argv);
        free_string_array(self.allocator, self.envp);
    }

    pub fn should_be_executed(self: ExecveArgs) bool {
        return std.mem.endsWith(u8, self.exe, Config.executable);
    }

    pub fn dupe(self: ExecveArgs, allocator: std.mem.Allocator) !ExecveArgs {
        return .{
            .allocator = allocator,
            .exe = try allocator.dupeZ(u8, self.exe),
            .argv = try dupe_string_array(self.allocator, self.argv),
            .envp = try dupe_string_array(self.allocator, self.envp),
        };
    }
};

id: usize,
mem_id: usize,
pid: c_long,
regs: c.user_regs_struct = .{},
status: Status,
stop_reason: StopReason,
ptrace: *Ptrace,
const Tracee = @This();

pub fn setregs(self: *Tracee) void {
    if (c.ptrace(c.PTRACE_SETREGS, self.pid, @as(c_int, 0), &self.regs) == -1) {
        sys_panic("failed to set regs for [{}]", .{self.pid});
    }
}

pub const TraceeMemoryArgv = struct {
    allocator: std.mem.Allocator,
    exe: [:0]const u8,
    argv: [:null]?[*:0]const u8,
    argv_tracee_space: [:0]const usize,

    pub fn deinit(self: TraceeMemoryArgv) void {
        const normal: [][*:0]const u8 = @ptrCast(self.argv[0..]);
        Tracee.free_string_array(self.allocator, normal);
        self.allocator.free(self.argv_tracee_space);
    }
};

pub fn makeExecveArgs(self: *Tracee, exe: []const u8, args: []const []const u8) !TraceeMemoryArgv {
    const allocator = self.ptrace.shared_memory.allocator();
    const exe_duped = try allocator.dupeZ(u8, exe);

    var argv_list = try std.ArrayList(?[*:0]const u8).initCapacity(allocator, args.len + 2);
    argv_list.appendAssumeCapacity(exe_duped.ptr);
    for (args) |arg| {
        argv_list.appendAssumeCapacity(try allocator.dupeZ(u8, arg));
    }

    const argv_tracee_space = try allocator.allocSentinel(usize, argv_list.items.len, 0);

    for (argv_list.items, 0..) |arg, i| {
        argv_tracee_space[i] = self.ptrace.shared_memory.as_tracee_address(self.*, arg.?);
    }

    return .{
        .allocator = allocator,
        .exe = exe_duped,
        .argv = try argv_list.toOwnedSliceSentinel(null),
        .argv_tracee_space = argv_tracee_space,
    };
}

pub fn replace_execve_to_stub(self: *Tracee, args: TraceeMemoryArgv) !void {
    //TODO Explore if we can use /proc/pid/mem to write to memory

    self.regs.rdi = self.ptrace.shared_memory.as_tracee_address(self.*, args.exe.ptr);
    self.regs.rsi = self.ptrace.shared_memory.as_tracee_address(self.*, @ptrCast(args.argv_tracee_space.ptr));
    self.regs.rdx = self.regs.rdx;
    self.setregs();

    var buf: [512]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&buf);

    log.info("Exe: {s}", .{try self.read_string(self.regs.rdi, allocator.allocator())});

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
                sys_panic("ENTER trace end", .{});
            }
            log.debug("Exit next", .{});
        },
        .ExitSyscall => {
            if (c.ptrace(c.PTRACE_SYSCALL, self.pid, @as(c_int, 0), @as(c_int, 0)) == -1) {
                sys_panic("EXIT trace end", .{});
            }
            log.debug("Enter next", .{});
        },
        .LocalExecution => {
            if (c.ptrace(c.PTRACE_CONT, self.pid, @as(c_int, 0), @as(c_int, 0)) == -1) {
                sys_panic("LOCAL_EXEC trace end", .{});
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
        } else {
            i += @sizeOf(usize);
            continue;
        }

        // Stop if we encountered a null terminator
        break;
    }

    tracee_memory_log.debug("Read string: {s}", .{str_builder.items});
    return str_builder.toOwnedSliceSentinel(0);
}

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
    for (strings) |str| {
        allocator.free(std.mem.span(str));
    }
    allocator.free(strings);
}

pub fn dupe_string_array(allocator: std.mem.Allocator, strings: [][*:0]const u8) ![][*:0]const u8 {
    const result = try allocator.alloc([*:0]const u8, strings.len);

    for (strings, 0..) |str, i| {
        result[i] = try allocator.dupeZ(u8, std.mem.span(str));
    }
    return result;
}

pub fn arg_first(self: *Tracee) *c_ulonglong {
    return &self.regs.rdi;
}

pub fn arg_second(self: *Tracee) *c_ulonglong {
    return &self.regs.rsi;
}

pub fn arg_third(self: *Tracee) *c_ulonglong {
    return &self.regs.rdx;
}

pub fn arg_fourth(self: *Tracee) *c_ulonglong {
    return &self.regs.r10;
}

pub fn arg_fifth(self: *Tracee) *c_ulonglong {
    return &self.regs.r8;
}

pub fn arg_sixth(self: *Tracee) *c_ulonglong {
    return &self.regs.r9;
}

pub fn read_first_arg(self: Tracee, allocator: std.mem.Allocator) ![:0]const u8 {
    return try self.read_string(self.regs.rdi, allocator);
}

pub fn set_first_arg(self: *Tracee, string: []const u8) !void {
    self.regs.rdi = try self.copy_to_stack(string);
    // const copied_string = try self.ptrace.shared_memory.allocator().dupeZ(u8, string);
    // self.regs.rdi = self.ptrace.shared_memory.as_tracee_address(self.*, copied_string.ptr);
}

pub fn read_second_arg(self: Tracee, allocator: std.mem.Allocator) ![:0]const u8 {
    return try self.read_string(self.regs.rsi, allocator);
}

pub fn set_second_arg(self: *Tracee, string: []const u8) !void {
    self.regs.rsi = try self.copy_to_stack(string);
    //log.info("set_second_arg check: {s}", .{reread});
    // const copied_string = try self.ptrace.shared_memory.allocator().dupeZ(u8, string);
    // self.regs.rsi = self.ptrace.shared_memory.as_tracee_address(self.*, copied_string.ptr);
}

pub fn copy_to_stack(self: Tracee, string: []const u8) !c_ulonglong {
    var stack_addr = self.regs.rsp - (128 + std.c.PATH_MAX);
    const file_addr = stack_addr;

    //const native_endian = builtin.cpu.arch.endian();

    var i: usize = 0;
    var val: c_long = 0;
    while (i <= string.len) {
        val = 0;
        for (0..@sizeOf(c_long)) |j| {
            if (i + j >= string.len) {
                val |= @as(c_long, @intCast(0)) << (@as(u6, @intCast(j)) * 8);
                break;
            }

            val |= @as(c_long, @intCast(string[i + j])) << (@as(u6, @intCast(j)) * 8);
        }
        if (c.ptrace(c.PTRACE_POKETEXT, self.pid, stack_addr, val) == -1) {
            sys_panic("Failed to copy string to stack for [{}]", .{self.pid});
        }

        i += @sizeOf(c_long);
        stack_addr += @sizeOf(c_long);
    }
    return file_addr;
}
