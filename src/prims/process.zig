// zepo-wgt: process-spawn with stdin/stdout pipes
const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const LispError = runtime.LispError;
const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;

extern "c" fn fgets(s: [*]u8, n: c_int, stream: *std.c.FILE) ?[*:0]u8;

fn toFloat(v: Value) f64 {
    if (value_mod.isFixnum(v)) return @floatFromInt(value_mod.fixnumVal(v));
    return objects.floatVal(v);
}

fn makeInt(n: i64) Value {
    // zepo-9usm: gate on the real fixnum range (process values — pids, fds,
    // exit codes — are always tiny, so the clamp fallback is unreachable in
    // practice; the point is never to hand fixnum() an out-of-range value).
    if (value_mod.fixnumFits(n))
        return value_mod.fixnum(@intCast(n));
    return value_mod.fixnum(0);
}

// ── C externs ────────────────────────────────────────────────────────────────
// zepo-wgt
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn dup2(oldfd: c_int, newfd: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn kill(pid: c_int, sig: c_int) c_int;
extern "c" fn fdopen(fd: c_int, mode: [*:0]const u8) ?*std.c.FILE;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, nmemb: usize, stream: *std.c.FILE) usize;
extern "c" fn fflush(stream: *std.c.FILE) c_int;

// ── Process object ────────────────────────────────────────────────────────────
// zepo-wgt
pub const TAG_PROCESS: u64 = 0x70726F63; // "proc"

pub const ProcessPayload = struct {
    pid: c_int,
    stdin_file: ?*std.c.FILE,   // write end — null if closed
    stdout_file: ?*std.c.FILE,  // read end  — null if closed
    allocator: std.mem.Allocator,
    exited: bool,
    exit_code: c_int,
};

fn deinitProcess(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const pp: *ProcessPayload = @alignCast(@ptrCast(p));
        if (pp.stdin_file) |f| _ = std.c.fclose(f);
        if (pp.stdout_file) |f| _ = std.c.fclose(f);
        if (!pp.exited) {
            var st: c_int = 0;
            _ = waitpid(pp.pid, &st, 0);
        }
        pp.allocator.destroy(pp);
    }
}

pub fn isProcess(v: Value) bool {
    return value_mod.isPtr(v) and objects.isForeign(v) and
        objects.foreignTypeTag(v) == TAG_PROCESS;
}

fn getProcess(v: Value) *ProcessPayload {
    return @alignCast(@ptrCast(objects.foreignPayload(v)));
}

// ── (process-spawn cmd arg1 arg2 ...) → process ──────────────────────────────
// zepo-wgt: fork+exec with two pipes: parent writes to child stdin, reads child stdout.
pub fn primProcessSpawn(vm: *VM, args: []const Value) LispError!Value {
    if (args.len < 1) return error.ArityMismatch;

    // Build null-terminated argv on the stack (max 64 args).
    var argv_buf: [65]?[*:0]const u8 = [_]?[*:0]const u8{null} ** 65;
    var c_strs: [64][4096]u8 = undefined;

    if (args.len > 64) return error.ContractViolation;

    for (args, 0..) |a, i| {
        if (!objects.isString(a)) return error.TypeError;
        const s = objects.stringBytes(a);
        if (s.len >= 4096) return error.ContractViolation;
        @memcpy(c_strs[i][0..s.len], s);
        c_strs[i][s.len] = 0;
        argv_buf[i] = @ptrCast(&c_strs[i]);
    }
    // argv_buf[args.len] stays null — sentinel

    // stdin pipe: parent writes [1], child reads [0]
    var stdin_pipe: [2]c_int = undefined;
    // stdout pipe: child writes [1], parent reads [0]
    var stdout_pipe: [2]c_int = undefined;

    if (pipe(&stdin_pipe) != 0) return error.IOError;
    if (pipe(&stdout_pipe) != 0) {
        _ = close(stdin_pipe[0]);
        _ = close(stdin_pipe[1]);
        return error.IOError;
    }

    const pid = fork();
    if (pid < 0) {
        _ = close(stdin_pipe[0]); _ = close(stdin_pipe[1]);
        _ = close(stdout_pipe[0]); _ = close(stdout_pipe[1]);
        return error.IOError;
    }

    if (pid == 0) {
        // Child: wire up pipes to stdin/stdout, close unused ends, exec.
        _ = dup2(stdin_pipe[0], 0);   // stdin  ← read end of stdin pipe
        _ = dup2(stdout_pipe[1], 1);  // stdout → write end of stdout pipe
        _ = close(stdin_pipe[0]); _ = close(stdin_pipe[1]);
        _ = close(stdout_pipe[0]); _ = close(stdout_pipe[1]);
        _ = execvp(argv_buf[0].?, @ptrCast(&argv_buf));
        // execvp only returns on error — exit child.
        std.process.exit(127);
    }

    // Parent: close the child-side ends.
    _ = close(stdin_pipe[0]);
    _ = close(stdout_pipe[1]);

    // Wrap fds as FILE* for buffered I/O.
    const stdin_f = fdopen(stdin_pipe[1], "w") orelse {
        _ = close(stdin_pipe[1]); _ = close(stdout_pipe[0]);
        return error.IOError;
    };
    const stdout_f = fdopen(stdout_pipe[0], "r") orelse {
        _ = std.c.fclose(stdin_f); _ = close(stdout_pipe[0]);
        return error.IOError;
    };

    const pp = vm.allocator.create(ProcessPayload) catch {
        _ = std.c.fclose(stdin_f); _ = std.c.fclose(stdout_f);
        return error.OutOfMemory;
    };
    pp.* = .{
        .pid = pid,
        .stdin_file = stdin_f,
        .stdout_file = stdout_f,
        .allocator = vm.allocator,
        .exited = false,
        .exit_code = 0,
    };

    return objects.makeForeign(vm.gc, pp, deinitProcess, TAG_PROCESS) catch return error.OutOfMemory;
}

// ── (process? val) ────────────────────────────────────────────────────────────
pub fn primProcessQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    return if (isProcess(args[0])) value_mod.TRUE else value_mod.FALSE;
}

// ── (process-pid proc) → integer ─────────────────────────────────────────────
pub fn primProcessPid(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isProcess(args[0])) return error.TypeError;
    const pp = getProcess(args[0]);
    return makeInt(@intCast(pp.pid));
}

// ── (process-send proc str) — write string to child stdin ────────────────────
// zepo-wgt
pub fn primProcessSend(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 2) return error.ArityMismatch;
    if (!isProcess(args[0])) return error.TypeError;
    if (!objects.isString(args[1])) return error.TypeError;
    const pp = getProcess(args[0]);
    const f = pp.stdin_file orelse return error.IOError;
    const s = objects.stringBytes(args[1]);
    if (s.len > 0) _ = fwrite(s.ptr, 1, s.len, f);
    _ = fflush(f);
    return value_mod.NIL;
}

// ── (process-close-stdin proc) — signal EOF to child ─────────────────────────
pub fn primProcessCloseStdin(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isProcess(args[0])) return error.TypeError;
    const pp = getProcess(args[0]);
    if (pp.stdin_file) |f| {
        _ = std.c.fclose(f);
        pp.stdin_file = null;
    }
    return value_mod.NIL;
}

// ── (process-recv proc max-bytes) → string (empty = EOF) ─────────────────────
// zepo-wgt
pub fn primProcessRecv(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!isProcess(args[0])) return error.TypeError;
    if (!objects.isNumber(args[1])) return error.TypeError;
    const pp = getProcess(args[0]);
    const f = pp.stdout_file orelse return objects.makeString(vm.gc, "") catch return error.OutOfMemory;
    const max: usize = @intFromFloat(toFloat(args[1]));
    const buf = vm.allocator.alloc(u8, max) catch return error.OutOfMemory;
    defer vm.allocator.free(buf);
    const n = std.c.fread(buf.ptr, 1, max, f);
    return objects.makeString(vm.gc, buf[0..n]) catch return error.OutOfMemory;
}

// ── (process-recv-line proc) → string or eof-object ──────────────────────────
// zepo-wgt
pub fn primProcessRecvLine(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isProcess(args[0])) return error.TypeError;
    const pp = getProcess(args[0]);
    const f = pp.stdout_file orelse return value_mod.EOF_VAL;

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(vm.allocator);
    var tmp: [256]u8 = undefined;
    var got_any = false;

    while (true) {
        const result = fgets(@ptrCast(&tmp), @intCast(tmp.len), f);
        if (result == null) {
            if (!got_any) return value_mod.EOF_VAL;
            break;
        }
        got_any = true;
        const slice = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&tmp)), 0);
        if (slice.len > 0 and slice[slice.len - 1] == '\n') {
            buf.appendSlice(vm.allocator, slice[0 .. slice.len - 1]) catch return error.OutOfMemory;
            break;
        }
        buf.appendSlice(vm.allocator, slice) catch return error.OutOfMemory;
    }
    return objects.makeString(vm.gc, buf.items) catch return error.OutOfMemory;
}

// ── (process-recv-all proc) → string ─────────────────────────────────────────
pub fn primProcessRecvAll(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isProcess(args[0])) return error.TypeError;
    const pp = getProcess(args[0]);
    const f = pp.stdout_file orelse return objects.makeString(vm.gc, "") catch return error.OutOfMemory;

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(vm.allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&tmp, 1, tmp.len, f);
        if (n == 0) break;
        buf.appendSlice(vm.allocator, tmp[0..n]) catch return error.OutOfMemory;
    }
    return objects.makeString(vm.gc, buf.items) catch return error.OutOfMemory;
}

// ── (process-wait proc) → exit-code ──────────────────────────────────────────
// zepo-wgt: close stdin first (signals EOF), then wait for child to exit.
pub fn primProcessWait(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isProcess(args[0])) return error.TypeError;
    const pp = getProcess(args[0]);
    if (pp.exited) return makeInt(@intCast(pp.exit_code));
    // Close stdin so child sees EOF if it's reading.
    if (pp.stdin_file) |f| { _ = std.c.fclose(f); pp.stdin_file = null; }
    var status: c_int = 0;
    _ = waitpid(pp.pid, &status, 0);
    pp.exit_code = (status >> 8) & 0xff;
    pp.exited = true;
    return makeInt(@intCast(pp.exit_code));
}

// ── (process-kill proc sig) ───────────────────────────────────────────────────
pub fn primProcessKill(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!isProcess(args[0])) return error.TypeError;
    if (!objects.isNumber(args[1])) return error.TypeError;
    const pp = getProcess(args[0]);
    const sig: c_int = @intFromFloat(toFloat(args[1]));
    _ = kill(pp.pid, sig);
    return value_mod.NIL;
}
