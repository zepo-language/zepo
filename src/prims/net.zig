// zepo-nj6: non-blocking TCP networking primitives
//
// Each socket is O_NONBLOCK. EAGAIN/EWOULDBLOCK causes the current fiber to
// be registered with the scheduler's poll set and yields (blocking yield with
// pc-1 re-execute). On wakeup, the CALL is re-executed and the operation
// retried. tcp-send partial writes are tracked via TcpConn.out_offset so
// re-execution continues from where the last write left off.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const LispError = runtime.LispError;
const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const sched_mod = @import("../vm/sched.zig");

// ── POSIX externs ─────────────────────────────────────────────────────────────

extern "c" fn socket(domain: c_int, @"type": c_int, protocol: c_int) c_int;
extern "c" fn bind(sockfd: c_int, addr: *const anyopaque, addrlen: c_uint) c_int;
extern "c" fn listen(sockfd: c_int, backlog: c_int) c_int;
extern "c" fn accept(sockfd: c_int, addr: ?*anyopaque, addrlen: ?*c_uint) c_int;
extern "c" fn connect(sockfd: c_int, addr: *const anyopaque, addrlen: c_uint) c_int;
extern "c" fn setsockopt(sockfd: c_int, level: c_int, optname: c_int, optval: *const anyopaque, optlen: c_uint) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, arg: c_int) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
extern "c" fn htons(s: u16) u16;

// ── Platform constants (macOS) ────────────────────────────────────────────────

const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;
const IPPROTO_TCP: c_int = 6;
const SOL_SOCKET: c_int = 0xffff;
const SO_REUSEADDR: c_int = 0x0004;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0x0004;
const EAGAIN: c_int = 35;
const EWOULDBLOCK: c_int = 35;

// macOS struct sockaddr_in (has sin_len field)
const SockaddrIn = extern struct {
    sin_len: u8 = @sizeOf(SockaddrIn),
    sin_family: u8 = 2, // AF_INET
    sin_port: u16 = 0,
    sin_addr: u32 = 0,
    sin_zero: [8]u8 = std.mem.zeroes([8]u8),
};

fn getErrno() c_int {
    return std.c._errno().*;
}

fn setNonBlocking(fd: c_int) bool {
    const flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return false;
    return fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0;
}

// ── GC type tags ─────────────────────────────────────────────────────────────

pub const TAG_TCP_CONN: u64 = 0x74637370;
pub const TAG_TCP_SERVER: u64 = 0x74637376;

// ── TcpConn ───────────────────────────────────────────────────────────────────

const RECV_BUF_SIZE = 4096;

pub const TcpConn = struct {
    fd: c_int,
    allocator: std.mem.Allocator,
    buf: [RECV_BUF_SIZE]u8 = undefined,
    buf_start: usize = 0,
    buf_end: usize = 0,
    out_offset: usize = 0,
};

fn makeTcpConn(vm: *VM, fd: c_int) !Value {
    const conn = try vm.allocator.create(TcpConn);
    conn.* = .{ .fd = fd, .allocator = vm.allocator };
    return try objects.makeForeign(vm.gc, conn, tcpConnDeinit, TAG_TCP_CONN);
}

fn tcpConnDeinit(ptr: ?*anyopaque) callconv(.c) void {
    const conn: *TcpConn = @ptrCast(@alignCast(ptr orelse return));
    if (conn.fd >= 0) _ = close(conn.fd);
    conn.allocator.destroy(conn);
}

fn getTcpConn(v: Value) LispError!*TcpConn {
    if (!objects.isForeign(v)) return error.TypeError;
    if (objects.foreignTypeTag(v) != TAG_TCP_CONN) return error.TypeError;
    return @ptrCast(@alignCast(objects.foreignPayload(v) orelse return error.ContractViolation));
}

// ── TcpServer ─────────────────────────────────────────────────────────────────

pub const TcpServer = struct {
    fd: c_int,
    allocator: std.mem.Allocator,
};

fn makeTcpServer(vm: *VM, fd: c_int) !Value {
    const srv = try vm.allocator.create(TcpServer);
    srv.* = .{ .fd = fd, .allocator = vm.allocator };
    return try objects.makeForeign(vm.gc, srv, tcpServerDeinit, TAG_TCP_SERVER);
}

fn tcpServerDeinit(ptr: ?*anyopaque) callconv(.c) void {
    const srv: *TcpServer = @ptrCast(@alignCast(ptr orelse return));
    if (srv.fd >= 0) _ = close(srv.fd);
    srv.allocator.destroy(srv);
}

fn getTcpServer(v: Value) LispError!*TcpServer {
    if (!objects.isForeign(v)) return error.TypeError;
    if (objects.foreignTypeTag(v) != TAG_TCP_SERVER) return error.TypeError;
    return @ptrCast(@alignCast(objects.foreignPayload(v) orelse return error.ContractViolation));
}

// ── Blocking yield helper ─────────────────────────────────────────────────────

fn yieldOnFd(vm: *VM, fd: c_int, events: c_short) LispError!void {
    const sched = vm.scheduler orelse return error.ContractViolation;
    const my_idx: usize = if (vm.current_fiber_idx == 0)
        sched_mod.MAIN_FIBER
    else
        vm.current_fiber_idx - 1;
    try sched.blockFiberOnFd(my_idx, fd, events);
    vm.yield_requested = true;
    vm.block_on_yield = true;
}

// ── (tcp-listen port) → server ────────────────────────────────────────────────
pub fn primTcpListen(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!value_mod.isFixnum(args[0])) return error.TypeError;
    const port: u16 = @intCast(value_mod.fixnumVal(args[0]));

    const fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return error.IOError;

    const one: c_int = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&one), @sizeOf(c_int)) < 0) {
        _ = close(fd);
        return error.IOError;
    }

    var addr = SockaddrIn{
        .sin_port = htons(port),
        .sin_addr = 0, // INADDR_ANY
    };
    if (bind(fd, @ptrCast(&addr), @sizeOf(SockaddrIn)) < 0) {
        _ = close(fd);
        return error.IOError;
    }
    if (listen(fd, 128) < 0) {
        _ = close(fd);
        return error.IOError;
    }
    if (!setNonBlocking(fd)) {
        _ = close(fd);
        return error.IOError;
    }
    return makeTcpServer(vm, fd) catch return error.OutOfMemory;
}

// ── (tcp-accept server) → conn ────────────────────────────────────────────────
pub fn primTcpAccept(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const srv = try getTcpServer(args[0]);

    const conn_fd = accept(srv.fd, null, null);
    if (conn_fd >= 0) {
        _ = setNonBlocking(conn_fd);
        return makeTcpConn(vm, conn_fd) catch return error.OutOfMemory;
    }
    const err = getErrno();
    if (err == EAGAIN or err == EWOULDBLOCK) {
        try yieldOnFd(vm, srv.fd, sched_mod.POLLIN);
        return value_mod.NIL;
    }
    return error.IOError;
}

// ── (tcp-connect host port) → conn ────────────────────────────────────────────
// Synchronous: non-blocking connect handshake adds complexity that client code
// rarely needs. Spawned fibers make the block invisible to callers anyway.
pub fn primTcpConnect(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    if (!value_mod.isFixnum(args[1])) return error.TypeError;

    const host = objects.stringBytes(args[0]);
    const port: u16 = @intCast(value_mod.fixnumVal(args[1]));

    var addr = SockaddrIn{ .sin_port = htons(port) };
    if (!resolveToAddr(host, &addr.sin_addr)) return error.IOError;

    const fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return error.IOError;

    if (connect(fd, @ptrCast(&addr), @sizeOf(SockaddrIn)) < 0) {
        _ = close(fd);
        return error.IOError;
    }
    if (!setNonBlocking(fd)) {
        _ = close(fd);
        return error.IOError;
    }
    return makeTcpConn(vm, fd) catch return error.OutOfMemory;
}

// ── (tcp-recv conn n) → string|eof ───────────────────────────────────────────
pub fn primTcpRecv(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const conn = try getTcpConn(args[0]);
    if (!value_mod.isFixnum(args[1])) return error.TypeError;
    const n: usize = @intCast(value_mod.fixnumVal(args[1]));

    const buf = try vm.allocator.alloc(u8, n);
    defer vm.allocator.free(buf);

    const rc = read(conn.fd, buf.ptr, n);
    if (rc > 0) {
        const got: usize = @intCast(rc);
        return objects.makeString(vm.gc, buf[0..got]) catch return error.OutOfMemory;
    }
    if (rc == 0) return value_mod.EOF_VAL;
    const err = getErrno();
    if (err == EAGAIN or err == EWOULDBLOCK) {
        try yieldOnFd(vm, conn.fd, sched_mod.POLLIN);
        return value_mod.NIL;
    }
    return error.IOError;
}

// ── (tcp-recv-line conn) → string|eof ────────────────────────────────────────
pub fn primTcpRecvLine(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const conn = try getTcpConn(args[0]);

    while (true) {
        const window = conn.buf[conn.buf_start..conn.buf_end];
        if (std.mem.indexOfScalar(u8, window, '\n')) |rel| {
            const result = objects.makeString(vm.gc, window[0..rel]) catch return error.OutOfMemory;
            conn.buf_start += rel + 1;
            if (conn.buf_start == conn.buf_end) {
                conn.buf_start = 0;
                conn.buf_end = 0;
            }
            return result;
        }
        if (conn.buf_start > 0) {
            const remaining = conn.buf_end - conn.buf_start;
            std.mem.copyForwards(u8, conn.buf[0..remaining], conn.buf[conn.buf_start..conn.buf_end]);
            conn.buf_start = 0;
            conn.buf_end = remaining;
        }
        if (conn.buf_end == RECV_BUF_SIZE) return error.IOError;
        const space = conn.buf[conn.buf_end..RECV_BUF_SIZE];
        const rc = read(conn.fd, space.ptr, space.len);
        if (rc > 0) {
            conn.buf_end += @intCast(rc);
            continue;
        }
        if (rc == 0) return value_mod.EOF_VAL;
        const err = getErrno();
        if (err == EAGAIN or err == EWOULDBLOCK) {
            try yieldOnFd(vm, conn.fd, sched_mod.POLLIN);
            return value_mod.NIL;
        }
        return error.IOError;
    }
}

// ── (tcp-send conn data) → #void ─────────────────────────────────────────────
pub fn primTcpSend(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const conn = try getTcpConn(args[0]);
    if (!objects.isString(args[1])) return error.TypeError;
    const data = objects.stringBytes(args[1]);

    while (conn.out_offset < data.len) {
        const remaining = data[conn.out_offset..];
        const rc = write(conn.fd, remaining.ptr, remaining.len);
        if (rc > 0) {
            conn.out_offset += @intCast(rc);
        } else {
            const err = getErrno();
            if (err == EAGAIN or err == EWOULDBLOCK) {
                try yieldOnFd(vm, conn.fd, sched_mod.POLLOUT);
                return value_mod.NIL;
            }
            conn.out_offset = 0;
            return error.IOError;
        }
    }
    conn.out_offset = 0;
    return value_mod.NIL;
}

// ── (tcp-close handle) → #void ────────────────────────────────────────────────
pub fn primTcpClose(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isForeign(args[0])) return error.TypeError;
    const tag = objects.foreignTypeTag(args[0]);
    if (tag == TAG_TCP_CONN) {
        const conn = try getTcpConn(args[0]);
        if (conn.fd >= 0) {
            _ = close(conn.fd);
            conn.fd = -1;
        }
    } else if (tag == TAG_TCP_SERVER) {
        const srv = try getTcpServer(args[0]);
        if (srv.fd >= 0) {
            _ = close(srv.fd);
            srv.fd = -1;
        }
    } else return error.TypeError;
    return value_mod.NIL;
}

// ── (tcp-socket? v) → bool ────────────────────────────────────────────────────
pub fn primTcpSocketQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const is = objects.isForeign(args[0]) and objects.foreignTypeTag(args[0]) == TAG_TCP_CONN;
    return if (is) value_mod.TRUE else value_mod.FALSE;
}

// ── (tcp-server? v) → bool ────────────────────────────────────────────────────
pub fn primTcpServerQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const is = objects.isForeign(args[0]) and objects.foreignTypeTag(args[0]) == TAG_TCP_SERVER;
    return if (is) value_mod.TRUE else value_mod.FALSE;
}

// ── DNS / address resolution ──────────────────────────────────────────────────

// Resolve host to a network-order IPv4 address stored in *out.
// Handles dotted-decimal directly; falls back to getaddrinfo for hostnames.
fn resolveToAddr(host: []const u8, out: *u32) bool {
    var ip: [4]u8 = undefined;
    if (parseIpv4(host, &ip)) {
        out.* = @as(u32, ip[0]) |
            (@as(u32, ip[1]) << 8) |
            (@as(u32, ip[2]) << 16) |
            (@as(u32, ip[3]) << 24);
        return true;
    }
    // getaddrinfo hostname lookup
    var hints = std.mem.zeroes(std.c.addrinfo);
    hints.family = AF_INET;
    hints.socktype = SOCK_STREAM;
    var host_buf: [256]u8 = undefined;
    if (host.len >= host_buf.len) return false;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;
    var res: ?*std.c.addrinfo = null;
    const rc = std.c.getaddrinfo(host_buf[0..host.len :0].ptr, null, &hints, &res);
    defer if (res) |r| std.c.freeaddrinfo(r);
    if (@intFromEnum(rc) != 0 or res == null) return false;
    const sa: *SockaddrIn = @ptrCast(@alignCast(res.?.addr orelse return false));
    out.* = sa.sin_addr;
    return true;
}

fn parseIpv4(s: []const u8, out: *[4]u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    for (out) |*b| {
        const part = it.next() orelse return false;
        b.* = std.fmt.parseInt(u8, part, 10) catch return false;
    }
    return it.next() == null;
}
