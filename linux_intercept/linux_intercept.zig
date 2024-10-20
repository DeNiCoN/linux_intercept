const std = @import("std");
const log = std.log;
const os = std.os;

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

const tracee_imp = @import("tracee.zig");
pub const Tracee = tracee_imp.Tracee;
pub const TraceeStatus = tracee_imp.TraceeStatus;
pub const StopReason = tracee_imp.StopReason;
pub const ExecveArgs = tracee_imp.ExecveArgs;
const read_string_array = tracee_imp.read_string_array;
const free_string_array = tracee_imp.free_string_array;
const systable = @import("systable.zig");
const sys_panic = @import("utils.zig").sys_panic;

pub const Shmem = struct {
    name: [:0]const u8,
    mem: *anyopaque,
    header: *c.intercept_header,

    pub fn init(comptime name: [:0]const u8) !Shmem {
        const fd: c_int = c.shm_open(name, c.O_RDWR | c.O_CREAT | c.O_EXCL, 777);
        if (fd == -1) {
            _ = c.shm_unlink(name);
            sys_panic("Failed to open shared memory:", .{});
        }

        const page_size: c_long = c.getpagesize();
        if (c.ftruncate(fd, page_size) == -1) {
            sys_panic("Ftruncate", .{});
        }

        const intercept_shared_mem: ?*anyopaque =
            c.mmap(c.NULL, @bitCast(page_size), c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);

        if (intercept_shared_mem == null) {
            sys_panic("Failed to mmap shared memory null:", .{});
        }

        if (intercept_shared_mem.? == c.MAP_FAILED) {
            sys_panic("Failed to mmap shared memory:", .{});
        }

        return .{ .name = name, .mem = intercept_shared_mem.?, .header = @ptrCast(@alignCast(intercept_shared_mem.?)) };
    }

    pub fn deinit(self: Shmem) void {
        if (c.shm_unlink(self.name) == -1) {
            sys_panic("Failed shm_unlink:", .{});
        }

        const page_size: c_int = c.getpagesize();
        if (c.munmap(self.mem, @intCast(page_size)) == -1) {
            sys_panic("Failed munmap:", .{});
        }
    }
};

pub const Ptrace = struct {
    tracees: std.AutoHashMap(c_int, Tracee),
    allocator: std.mem.Allocator,
    shared_memory: Shmem,
    initial_pid: ?c_long = null,

    stub_exe: [:0]u8,
    stub_argv: [*:null]?[*:0]u8,

    pub fn init(allocator: std.mem.Allocator) !Ptrace {
        const tracee_states = std.AutoHashMap(c_int, Tracee).init(allocator);

        var shared_memory = try Shmem.init("/linux_intercept");
        const stub_exe = "/home/denicon/projects/MagDiploma/linux_intercept/zig-out/bin/process_stub";

        const stub_exe_mem = shared_memory.alloc(u8, stub_exe.len + 1);
        @memcpy(stub_exe_mem, stub_exe);

        const stub_argv_mem = shared_memory.alloc([*]?[*:0]u8, 2);
        stub_argv_mem[0] = &stub_exe_mem;
        stub_argv_mem[1] = null;

        return .{
            .tracees = tracee_states,
            .allocator = allocator,
            .shared_memory = shared_memory,
            .stub_exe = stub_exe_mem,
            .stub_argv = stub_argv_mem,
        };
    }

    pub fn deinit(self: *Ptrace) void {
        self.tracees.deinit();

        // TODO dealoc?
        self.shared_memory.deinit();
    }

    pub fn is_initial(self: *Ptrace, tracee: Tracee) bool {
        return self.initial_pid != null and self.initial_pid == tracee.pid;
    }

    pub fn start(self: *Ptrace, file: [*:0]u8, argv: [*c][*c]u8) !void {
        const initial_pid = c.fork();
        if (initial_pid == -1) {
            sys_panic("fork failed", .{});
        }

        self.initial_pid = initial_pid;

        switch (initial_pid) {
            0 => {
                log.debug("Child", .{});

                const current_pid = c.getpid();
                log.debug("c [{}]: Ptrace me", .{current_pid});

                if (c.ptrace(c.PT_TRACE_ME, current_pid, @as(c_int, 0), @as(c_int, 0)) == -1) {
                    sys_panic("Ptrace failed: ", .{});
                }

                log.debug("Executing {s}", .{file});

                if (c.execvp(file, argv) == -1) {
                    sys_panic("Exec failed", .{});
                }
            },
            else => {
                log.debug("Parent", .{});

                if (c.waitpid(initial_pid, 0, 0) == -1) {
                    sys_panic("wait child", .{});
                }

                if (c.ptrace(c.PTRACE_SETOPTIONS, initial_pid, @as(c_int, 0), c.PTRACE_O_EXITKILL | c.PTRACE_O_TRACECLONE | c.PTRACE_O_TRACEFORK | c.PTRACE_O_TRACEVFORK | c.PTRACE_O_TRACEEXEC | c.PTRACE_O_TRACEEXIT | c.PTRACE_O_TRACESYSGOOD) == -1) {
                    sys_panic("ptrace set options", .{});
                }

                if (c.ptrace(c.PTRACE_SYSCALL, initial_pid, @as(c_int, 0), @as(c_int, 0)) == -1) {
                    sys_panic("trace begin", .{});
                }

                try self.tracees.put(initial_pid, Tracee{
                    .pid = initial_pid,
                    .status = TraceeStatus.EnterSyscall,
                    .stop_reason = StopReason.None,
                    .ptrace = self,
                });
            },
        }
    }

    pub fn next(self: *Ptrace) !?*Tracee {
        while (true) {
            var status: c_int = undefined;
            const pid = c.waitpid(-1, &status, 0);

            if (pid == -1) {
                if (std.c._errno().* == c.ECHILD) {
                    log.debug("No children", .{});
                    return null;
                }
                sys_panic("trace wait", .{});
            }

            var tracee = self.tracees.getPtr(pid).?;

            if (c.WIFSTOPPED(status)) {
                // Handle new childs when stopped on clone event
                if (status >> 8 == (c.SIGTRAP | (c.PTRACE_EVENT_CLONE << 8))) {
                    log.debug("PTRACE_EVENT_CLONE", .{});
                } else if (status >> 8 == (c.SIGTRAP | (c.PTRACE_EVENT_FORK << 8))) {
                    log.debug("PTRACE_EVENT_FORK", .{});

                    var new_pid: c_int = undefined;
                    if (c.ptrace(c.PTRACE_GETEVENTMSG, pid, @as(c_int, 0), &new_pid) == -1) {
                        sys_panic("geteventmsg failed", .{});
                    }

                    log.debug("New child: {}", .{new_pid});

                    if (c.waitpid(new_pid, 0, 0) == -1) {
                        sys_panic("wait new child", .{});
                    }

                    if (tracee.status == .LocalExecution) {
                        if (c.ptrace(c.PTRACE_DETACH, new_pid, @as(c_int, 0), c.NULL) == -1) {
                            sys_panic("trace new child", .{});
                        }
                    } else {
                        if (c.ptrace(c.PTRACE_SYSCALL, new_pid, @as(c_int, 0), c.NULL) == -1) {
                            sys_panic("trace new child", .{});
                        }

                        try self.tracees.put(new_pid, Tracee{
                            .pid = new_pid,
                            .status = .EnterSyscall,
                            .stop_reason = .None,
                            .ptrace = self,
                        });
                    }
                    tracee.cont_same();
                    continue;
                } else if (status >> 8 == (c.SIGTRAP | (c.PTRACE_EVENT_VFORK << 8))) {
                    log.debug("PTRACE_EVENT_VFORK", .{});
                } else if (status >> 8 == (c.SIGTRAP | (c.PTRACE_EVENT_EXIT << 8))) {
                    log.debug("PTRACE_EVENT_EXIT", .{});
                    tracee.stop_reason = .Exit;
                    return tracee;
                } else if (status >> 8 == (c.SIGTRAP | (c.PTRACE_EVENT_EXEC << 8))) {
                    log.debug("PTRACE_EVENT_EXEC", .{});
                    tracee.cont_same();
                    continue;
                }

                if (c.WSTOPSIG(status) & 0x80 == 0) {
                    log.debug("NOSYSCALL", .{});
                    tracee.cont_same();
                    continue;
                }
            } else if (c.WIFEXITED(status)) {
                //Normal exit of child process
                //Next wait is supposed to fail
                log.debug("LAST EXIT", .{});
                continue;
            }

            switch (tracee.status) {
                TraceeStatus.EnterSyscall => {
                    try tracee.update_regs();

                    const syscall = tracee.regs.orig_rax;
                    const syscall_name = systable.syscall_to_str(syscall);

                    if (syscall == c.SYS_execve) {
                        const exe_name = try tracee.read_string(tracee.regs.rdi, self.allocator);
                        defer self.allocator.free(exe_name);

                        const argv = try read_string_array(tracee.*, tracee.regs.rsi, self.allocator);
                        defer free_string_array(self.allocator, argv);
                        const envp = try read_string_array(tracee.*, tracee.regs.rdx, self.allocator);
                        defer free_string_array(self.allocator, envp);
                        // if (execve_succeeds(exe, argv, envp)) {}

                        //TODO Read argv and envp
                        //
                        //TODO Mock the execve call in a fork to decide if it will succeed
                        //Establish shared memory
                        //Substitude arguments by changing registers
                        //Detach from child
                        //
                        //TODO Future: seccomp to only catch execve calls

                        log.info("[{}] {s}(\"{s}\", {s}, {*}, {}, {}, {})", .{ pid, syscall_name, exe_name, argv, envp, tracee.regs.r10, tracee.regs.r8, tracee.regs.r9 });

                        tracee.stop_reason = .ExecveEnter;
                        return tracee;
                    } else {
                        log.debug("[{}] {s}({}, {}, {}, {}, {}, {})", .{ pid, syscall_name, tracee.regs.rdi, tracee.regs.rsi, tracee.regs.rdx, tracee.regs.r10, tracee.regs.r8, tracee.regs.r9 });
                    }

                    tracee.cont();
                },
                TraceeStatus.ExitSyscall => {
                    try tracee.update_regs();

                    const syscall = tracee.regs.orig_rax;

                    if (syscall == c.SYS_execve) {
                        log.info("Exec ended", .{});
                    }

                    if (syscall == c.SYS_write) {
                        log.debug("Write", .{});
                    }

                    log.debug("[{}] = {}", .{ pid, tracee.regs.rax });

                    tracee.cont();
                },
                .LocalExecution => {
                    tracee.cont_same();
                },
            }
        }
    }

    pub fn stub_exe_remote_address(self: *Ptrace, tracee: *Tracee) c_ulonglong {
        _ = tracee;
        return self.shared_memory.as_tracee_address(self.stub_exe);
    }

    pub fn stub_argv_remote_address(self: *Ptrace, tracee: *Tracee) c_ulonglong {
        _ = tracee;
        return self.shared_memory.as_tracee_address(self.stub_argv);
    }

    pub fn stub_envp_remote_address(self: *Ptrace, tracee: *Tracee) c_ulonglong {
        _ = self;
        return tracee.regs.rdx;
    }
};

pub const ProcessManager = struct {
    local: std.AutoHashMap(c_long, bool),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ProcessManager {
        return .{
            .local = std.AutoHashMap(c_long, bool).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProcessManager) void {
        self.local.deinit();
    }

    pub fn should_local(self: ProcessManager, tracee: *const Tracee) bool {
        _ = self;
        _ = tracee;
        return true;
    }

    pub fn allow_local(self: *ProcessManager, tracee: *Tracee) !void {
        log.info("Executing [{}] locally", .{tracee.pid});
        try self.local.put(tracee.pid, true);
        tracee.local_execution();
    }

    pub fn allow_remote(self: ProcessManager, tracee: *Tracee, args: ExecveArgs) !void {
        tracee.replace_execve_to_stub();
        tracee.detach();

        self.send_to_remote(tracee, args);
    }

    pub fn finished(self: *ProcessManager, tracee: *const Tracee) !void {
        log.info("Finished [{}]", .{tracee.pid});
        if (!self.local.remove(tracee.pid)) {
            return error.NoSuchPid;
        }
    }
};
