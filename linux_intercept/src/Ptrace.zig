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
    @cInclude("csrc/preload.h");
});

const Tracee = @import("Tracee.zig");
const systable = @import("systable.zig");
const sys_panic = @import("utils.zig").sys_panic;
const Config = @import("Config.zig");

pub const GPShmem = struct {
    shared_memory: Shmem,
    header: *c.intercept_header,
    buffer_allocator: std.heap.FixedBufferAllocator,

    pub fn init(name: [:0]const u8) !GPShmem {
        const page_size: c_long = c.getpagesize();
        const mem_size = page_size * 16;

        const shared_memory = try Shmem.init(name, mem_size);
        const header: *c.intercept_header = @ptrCast(@alignCast(shared_memory.mem));
        header.processes = 0;

        const alloc_buffer = shared_memory.mem[@sizeOf(c.intercept_header)..];

        return .{
            .shared_memory = shared_memory,
            .header = header,
            .buffer_allocator = std.heap.FixedBufferAllocator.init(alloc_buffer),
        };
    }

    pub fn deinit(self: GPShmem) void {
        self.shared_memory.deinit();
    }

    pub fn alloc(self: *GPShmem, comptime T: type, n: usize) ![]T {
        return self.buffer_allocator.allocator().alloc(T, n);
    }

    pub fn as_tracee_address(self: *const GPShmem, tracee: Tracee, address: *const anyopaque) c_ulonglong {
        //FIXME mem_id probably does not work in all cases
        // if (self.header.entries[tracee.mem_id].pid != tracee.pid) {
        //     std.debug.panic("tracee mem_id {} does not correspond stored pid {} ({} actual) in shared memory. \n All entries: {any}", .{ tracee.mem_id, self.header.entries[tracee.mem_id].pid, tracee.pid, self.header.entries });
        // }

        if (tracee.mem_id >= self.header.processes) {
            std.debug.panic("Mem id {} out of range {}", .{ tracee.mem_id, self.header.processes });
        }

        //log.debug("Tracee address for mem_id", args: anytype)
        const offset: i128 = (@intFromPtr(address) - @intFromPtr(self.shared_memory.mem.ptr));
        if (offset >= self.shared_memory.mem.len or offset < 0) {
            std.debug.panic("Address out of shared memory bounds", .{});
        }

        return self.header.entries[tracee.mem_id].address + (@intFromPtr(address) - @intFromPtr(self.shared_memory.mem.ptr));
    }
    pub fn allocator(self: *GPShmem) std.mem.Allocator {
        return self.buffer_allocator.allocator();
    }
};

pub const Shmem = struct {
    name: [:0]const u8,
    mem: []u8,

    pub fn init(name: [:0]const u8, mem_size: c_long) !Shmem {
        const fd: c_int = c.shm_open(name, c.O_RDWR | c.O_CREAT | c.O_EXCL, 0o777);
        if (fd == -1) {
            _ = c.shm_unlink(name);
            sys_panic("Failed to open shared memory:", .{});
        }

        if (c.ftruncate(fd, mem_size) == -1) {
            sys_panic("Ftruncate", .{});
        }

        const intercept_shared_mem: ?*anyopaque =
            c.mmap(c.NULL, @bitCast(mem_size), c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);

        if (intercept_shared_mem == null) {
            sys_panic("Failed to mmap shared memory null:", .{});
        }

        if (intercept_shared_mem.? == c.MAP_FAILED) {
            sys_panic("Failed to mmap shared memory:", .{});
        }

        const mem: []u8 = @as([*]u8, @ptrCast(intercept_shared_mem.?))[0..@bitCast(mem_size)];

        return .{
            .name = name,
            .mem = mem,
        };
    }

    pub fn deinit(self: Shmem) void {
        if (c.shm_unlink(self.name) == -1) {
            sys_panic("Failed shm_unlink:", .{});
        }

        const page_size: c_int = c.getpagesize();
        const mem_size = page_size * 16;
        if (c.munmap(@ptrCast(self.mem), @intCast(mem_size)) == -1) {
            sys_panic("Failed munmap:", .{});
        }
    }
};

pub fn NonInvalidatableHashMap(K: type, V: type) type {
    return struct {
        const Node = std.DoublyLinkedList(V).Node;

        pool: std.heap.MemoryPool(Node),
        list: std.DoublyLinkedList(V),
        map: std.AutoHashMap(K, *Node),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .pool = std.heap.MemoryPool(Node).init(allocator),
                .list = std.DoublyLinkedList(V){},
                .map = std.AutoHashMap(K, *Node).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.map.deinit();
            self.pool.deinit();
        }

        pub fn put(self: *Self, key: K, value: V) std.mem.Allocator.Error!void {
            const node = try self.pool.create();
            node.data = value;
            try self.map.put(key, node);
        }

        pub fn count(self: Self) usize {
            return self.map.count();
        }

        pub fn getPtr(self: Self, key: K) ?*V {
            const node = self.map.get(key) orelse {
                return null;
            };
            return &node.data;
        }
    };
}

tracees: NonInvalidatableHashMap(c_int, Tracee),
unknown: std.AutoHashMap(c_int, c_int),
allocator: std.mem.Allocator,
shared_memory: GPShmem,
initial_pid: ?c_long = null,

shmem_name: [:0]u8,
sem_name: [:0]u8,

const Ptrace = @This();

pub fn init(allocator: std.mem.Allocator) !Ptrace {
    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    const uid = rand.int(u64);
    log.info("Shmem uid: {}", .{uid});
    const shmem_name = try std.fmt.allocPrintZ(allocator, "linux_intercept_{}", .{uid});
    const sem_name = try std.fmt.allocPrintZ(allocator, "linux_intercept_sem_{}", .{uid});

    const shared_memory = try GPShmem.init(shmem_name);

    return .{
        .tracees = NonInvalidatableHashMap(c_int, Tracee).init(allocator),
        .unknown = std.AutoHashMap(c_int, c_int).init(allocator),
        .allocator = allocator,
        .shared_memory = shared_memory,
        .shmem_name = shmem_name,
        .sem_name = sem_name,
    };
}

pub fn deinit(self: *Ptrace) void {
    self.shared_memory.deinit();
    self.unknown.deinit();
    self.tracees.deinit();

    self.allocator.free(self.sem_name);
    self.allocator.free(self.shmem_name);
}

pub fn is_initial(self: *Ptrace, tracee: Tracee) bool {
    return self.initial_pid != null and self.initial_pid == tracee.pid;
}

pub fn setenv(allocator: std.mem.Allocator, env_list: *std.ArrayList(?[*:0]const u8), key: []const u8, value: []const u8) ![:0]const u8 {
    const env = try std.fmt.allocPrintZ(allocator, "{s}={s}", .{ key, value });
    for (env_list.items, 0..) |env_val, i| {
        if (std.mem.startsWith(u8, std.mem.span(env_val.?), key)) {
            env_list.items[i] = env.ptr;
            break;
        }
    } else {
        env_list.appendAssumeCapacity(env.ptr);
    }

    return env;
}

pub fn start(self: *Ptrace, file: [*:0]const u8, argv: [:null]?[*:0]const u8, envp: [:null]?[*:0]const u8) !void {
    var env_list = try std.ArrayList(?[*:0]const u8).initCapacity(self.allocator, envp.len + 3);
    env_list.appendSliceAssumeCapacity(envp);

    const shmem_env = try setenv(self.allocator, &env_list, "LINUX_INTERCEPT_SHMEM_NAME", self.shmem_name);
    defer self.allocator.free(shmem_env);

    const sem_env = try setenv(self.allocator, &env_list, "LINUX_INTERCEPT_SEM_NAME", self.sem_name);
    defer self.allocator.free(sem_env);

    const ld_preload_env = try setenv(self.allocator, &env_list, "LD_PRELOAD", Config.preload_path);
    defer self.allocator.free(ld_preload_env);

    const modified_env = try env_list.toOwnedSliceSentinel(null);
    defer self.allocator.free(modified_env);

    log.debug("starting {s}", .{file});
    const initial_pid = c.fork();
    if (initial_pid == -1) {
        sys_panic("fork failed", .{});
    }

    //FIXME initial_pid updated from multiple threads
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

            return std.posix.execvpeZ(file, argv, modified_env);
        },
        else => {
            log.debug("Parent", .{});

            if (c.waitpid(initial_pid, 0, 0) == -1) {
                sys_panic("wait child", .{});
            }

            if (c.ptrace(
                c.PTRACE_SETOPTIONS,
                initial_pid,
                @as(c_int, 0),
                c.PTRACE_O_EXITKILL |
                    c.PTRACE_O_TRACECLONE |
                    c.PTRACE_O_TRACEFORK |
                    c.PTRACE_O_TRACEVFORK |
                    c.PTRACE_O_TRACEEXEC |
                    c.PTRACE_O_TRACEEXIT |
                    c.PTRACE_O_TRACESYSGOOD,
            ) == -1) {
                sys_panic("ptrace set options", .{});
            }

            if (c.ptrace(c.PTRACE_SYSCALL, initial_pid, @as(c_int, 0), @as(c_int, 0)) == -1) {
                sys_panic("trace begin", .{});
            }

            try self.tracees.put(initial_pid, Tracee{
                .id = self.tracees.count(),
                .mem_id = 0,
                .pid = initial_pid,
                .status = .EnterSyscall,
                .stop_reason = .None,
                .ptrace = self,
            });
        },
    }
}

fn process_new_child(self: *Ptrace, tracee: *Tracee) !void {
    var new_pid: c_int = undefined;
    if (c.ptrace(c.PTRACE_GETEVENTMSG, tracee.pid, @as(c_int, 0), &new_pid) == -1) {
        sys_panic("geteventmsg failed", .{});
    }

    log.debug("New child: {}. Parent status: {}", .{ new_pid, tracee.status });

    if (!self.unknown.contains(new_pid)) {
        log.debug("unknown", .{});
        if (c.waitpid(new_pid, 0, 0) == -1) {
            sys_panic("wait new child", .{});
        }
    } else {
        _ = self.unknown.remove(new_pid);
    }

    if (tracee.status == .LocalExecution) {
        log.debug("Local execution detach child", .{});
        if (c.ptrace(c.PTRACE_DETACH, new_pid, @as(c_int, 0), c.NULL) == -1) {
            sys_panic("trace new child", .{});
        }
    } else {
        log.debug("next_syscall child", .{});
        if (c.ptrace(c.PTRACE_SYSCALL, new_pid, @as(c_int, 0), c.NULL) == -1) {
            sys_panic("trace new child", .{});
        }

        log.debug("put lock", .{});
        try self.tracees.put(new_pid, Tracee{
            .id = self.tracees.count(),
            .mem_id = tracee.mem_id,
            .pid = new_pid,
            .status = .EnterSyscall,
            .stop_reason = .None,
            .ptrace = self,
        });
    }
    tracee.cont_same();
}

pub fn next(self: *Ptrace) !?*Tracee {
    while (true) {
        var waitinfo: std.c.siginfo_t = undefined;
        if (c.waitid(c.P_ALL, 0, @ptrCast(&waitinfo), c.WEXITED | c.WSTOPPED | c.__WNOTHREAD | c.WNOWAIT) < 0) {
            if (std.c._errno().* == c.ECHILD) {
                log.debug("No children", .{});
                return null;
            }
            sys_panic("wait any child", .{});
        }

        var pid = waitinfo.fields.common.first.piduid.pid;

        var status: c_int = undefined;
        pid = c.waitpid(pid, &status, 0);

        if (pid == -1) {
            if (std.c._errno().* == c.ECHILD) {
                log.debug("No children", .{});
                return null;
            }
            sys_panic("trace wait", .{});
        }

        var tracee = self.tracees.getPtr(pid) orelse {
            log.debug("No pid {}", .{pid});
            try self.unknown.put(pid, 0);
            continue;
            //std.debug.panic("No pid {}", .{pid});
        };

        if (c.WIFSTOPPED(status)) {
            // Handle new childs when stopped on clone event
            if (status >> 8 == (c.SIGTRAP | (c.PTRACE_EVENT_CLONE << 8))) {
                log.debug("PTRACE_EVENT_CLONE", .{});
                try self.process_new_child(tracee);
                continue;
            } else if (status >> 8 == (c.SIGTRAP | (c.PTRACE_EVENT_FORK << 8))) {
                log.debug("PTRACE_EVENT_FORK", .{});
                try self.process_new_child(tracee);
                continue;
            } else if (status >> 8 == (c.SIGTRAP | (c.PTRACE_EVENT_VFORK << 8))) {
                log.debug("PTRACE_EVENT_VFORK", .{});
                try self.process_new_child(tracee);
                continue;
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
            .EnterSyscall => {
                try tracee.update_regs();

                const syscall = tracee.regs.orig_rax;
                const syscall_name = systable.syscall_to_str(syscall);

                if (syscall == c.SYS_execve) {
                    const exe_name = try tracee.read_string(tracee.regs.rdi, self.allocator);
                    defer self.allocator.free(exe_name);

                    const argv = try Tracee.read_string_array(tracee.*, tracee.regs.rsi, self.allocator);
                    defer Tracee.free_string_array(self.allocator, argv);
                    // if (execve_succeeds(exe, argv, envp)) {}

                    //TODO Future: seccomp to only catch execve calls

                    const envp = try Tracee.read_string_array(tracee.*, tracee.regs.rdx, self.allocator);
                    defer Tracee.free_string_array(self.allocator, envp);
                    // const envp_ld = try self.shared_memory.alloc(?[*:0]const u8, envp.len + 1);
                    // var i: usize = 0;
                    // for (envp) |env| {
                    //     if (!std.mem.startsWith(u8, std.mem.span(env), "LD_PRELOAD")) {
                    //         envp_ld[i] = env;
                    //         i += 1;
                    //     }
                    // }
                    // envp_ld[i] = null;

                    // tracee.regs.rdx = self.shared_memory.as_tracee_address(@ptrCast(envp_ld.ptr));
                    // tracee.setregs();
                    //Copy without LD_PRELOAD
                    log.info("[{}] {s}(\"{s}\", {s}, {*}, {}, {}, {})", .{ pid, syscall_name, exe_name, argv, envp, tracee.regs.r10, tracee.regs.r8, tracee.regs.r9 });

                    tracee.stop_reason = .ExecveEnter;
                    return tracee;
                } else if (syscall == c.SYS_openat) {
                    log.debug("[{}] {s}({}, {}, {}, {}, {}, {})", .{ pid, syscall_name, tracee.regs.rdi, tracee.regs.rsi, tracee.regs.rdx, tracee.regs.r10, tracee.regs.r8, tracee.regs.r9 });
                    tracee.stop_reason = .OpenAt;
                    return tracee;
                } else if (syscall == c.SYS_access) {
                    log.debug("[{}] {s}({}, {}, {}, {}, {}, {})", .{ pid, syscall_name, tracee.regs.rdi, tracee.regs.rsi, tracee.regs.rdx, tracee.regs.r10, tracee.regs.r8, tracee.regs.r9 });
                    tracee.stop_reason = .Access;
                    return tracee;
                } else if (syscall == c.SYS_newfstatat) {
                    log.debug("[{}] {s}({}, {}, {}, {}, {}, {})", .{ pid, syscall_name, tracee.regs.rdi, tracee.regs.rsi, tracee.regs.rdx, tracee.regs.r10, tracee.regs.r8, tracee.regs.r9 });
                    tracee.stop_reason = .Newfstatat;
                    return tracee;
                } else {
                    log.debug("[{}] {s}({}, {}, {}, {}, {}, {})", .{ pid, syscall_name, tracee.regs.rdi, tracee.regs.rsi, tracee.regs.rdx, tracee.regs.r10, tracee.regs.r8, tracee.regs.r9 });
                }

                tracee.cont();
            },
            .ExitSyscall => {
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

pub fn will_succeed(self: *Ptrace, args: Tracee.ExecveArgs) bool {
    _ = self;
    std.fs.accessAbsoluteZ(args.exe, .{ .mode = .read_only }) catch return false;
    return true;
}

pub const FDTable = struct {
    // table: std.AutoHashMap(c_ulonglong, []const u8),

    // pub fn init(allocator: std.mem.Allocator) FDTable {
    //     return .{ .table = std.AutoHashMap(c_ulonglong, []const u8).init(allocator) };
    // }

    // pub fn deinit(self: *FDTable) void {
    //     var iterator = self.table.iterator();
    //     while (iterator.next()) |entry| {
    //         self.table.allocator.free(entry.value_ptr.*);
    //     }
    //     self.table.deinit();
    // }

    // pub fn register(self: FDTable, fd: c_ulonglong, name: []const u8) !void {
    //     const duped_value = try std.table.allocator.dupe(name);
    //     errdefer std.table.allocator.free(duped_value);
    //     try self.table.put(fd, duped_value);
    // }
};
