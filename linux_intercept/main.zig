// Top-level declarations are order-independent:
const print = std.debug.print;
const panic = std.debug.panic;
const std = @import("std");
const os = std.os;
const assert = std.debug.assert;

pub const std_options: std.Options = .{ .log_level = .info };

const log = std.log;

const allocator = std.heap.PageAllocator();

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("sys/ptrace.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/user.h");
    @cInclude("sys/syscall.h");
    @cInclude("string.h");
});

pub fn sys_panic(src: std.builtin.SourceLocation, comptime str: []const u8, args: anytype) void {
    const errno_str = c.strerror(std.c._errno().*);

    const stderr = std.io.getStdErr();

    const err_writer = stderr.writer();
    err_writer.print("{s}:{}: ", .{ src.file, src.line }) catch c.exit(1);
    err_writer.print(str, args) catch c.exit(1);
    err_writer.print(": {s}\n", .{errno_str}) catch c.exit(1);

    c.exit(c.EXIT_FAILURE);
}

pub fn main() void {
    log.debug("Command args: {s}\n", .{os.argv});

    const pid = c.fork();
    if (pid == -1) {
        sys_panic(@src(), "fork failed", .{});
    }

    switch (pid) {
        0 => {
            log.debug("Child\n", .{});
            const file = os.argv[1];
            const argv: [*c][*c]u8 = @ptrCast(os.argv[1..]);

            const current_pid = c.getpid();
            std.log.debug("c [{}]: Ptrace me", .{current_pid});

            if (c.ptrace(c.PT_TRACE_ME, current_pid, @as(c_int, 0), @as(c_int, 0)) == -1) {
                sys_panic(@src(), "Ptrace failed: ", .{});
            }

            log.debug("Executing {s}\n", .{file});

            if (c.execvp(file, argv) == -1) {
                sys_panic(@src(), "Exec failed", .{});
            }
        },
        else => {
            log.debug("Parent\n", .{});

            if (c.waitpid(pid, 0, 0) == -1) {
                sys_panic(@src(), "wait child", .{});
            }

            if (c.ptrace(c.PTRACE_SETOPTIONS, pid, @as(c_int, 0), c.PTRACE_O_EXITKILL) == -1) {
                sys_panic(@src(), "ptrace set options", .{});
            }

            while (true) {
                if (c.ptrace(c.PTRACE_SYSCALL, pid, @as(c_int, 0), @as(c_int, 0)) == -1) {
                    sys_panic(@src(), "trace begin", .{});
                }

                if (c.waitpid(pid, 0, 0) == -1) {
                    sys_panic(@src(), "trace wait", .{});
                }

                var regs: c.user_regs_struct = undefined;
                if (c.ptrace(c.PTRACE_GETREGS, pid, @as(c_int, 0), &regs) == -1)
                    sys_panic(@src(), "trace get registers", .{});

                const syscall = regs.orig_rax;

                if (syscall == c.SYS_execve) {
                    log.info("exec({}, {}, {}, {}, {}, {})", .{ regs.rdi, regs.rsi, regs.rdx, regs.r10, regs.r8, regs.r9 });
                } else {
                    log.debug("{}({}, {}, {}, {}, {}, {})", .{ syscall, regs.rdi, regs.rsi, regs.rdx, regs.r10, regs.r8, regs.r9 });
                }

                if (c.ptrace(c.PTRACE_SYSCALL, pid, @as(c_int, 0), @as(c_int, 0)) == -1)
                    sys_panic(@src(), "trace end", .{});
                if (c.waitpid(pid, 0, 0) == -1)
                    sys_panic(@src(), "trace end wait", .{});

                if (c.ptrace(c.PTRACE_GETREGS, pid, @as(c_int, 0), &regs) == -1) {
                    log.debug(" = ?\n", .{});
                    if (std.c._errno().* == c.ESRCH)
                        c.exit(@intCast(regs.rdi)); // system call was _exit(2) or similar

                    sys_panic(@src(), "getregs fail", .{});
                }

                if (syscall == c.SYS_execve) {
                    log.info("Exec ended", .{});
                }

                if (syscall == c.SYS_write) {
                    log.debug("Write", .{});
                }

                log.debug(" = {}\n", .{regs.rax});
            }
        },
    }
}
