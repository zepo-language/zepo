//! TCP networking primitives.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const errs = @import("../runtime/errors.zig");
const LispError = errs.LispError;

pub const TAG_TCP_CONN: u64 = 0x74637370; // "tcsp"
pub const TAG_TCP_SERVER: u64 = 0x74637376; // "tcsv"

const TcpConn = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    closed: bool = false,
};

const TcpServer = struct {
    server: std.net.Server,
    allocator: std.mem.Allocator,
    closed: bool = false,
};

fn deinitConn(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const conn: *TcpConn = @alignCast(@ptrCast(p));
        if (!conn.closed) conn.stream.close();
        conn.allocator.destroy(conn);
    }
}

fn deinitServer(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const srv: *TcpServer = @alignCast(@ptrCast(p));
        if (!srv.closed) srv.server.deinit();
        srv.allocator.destroy(srv);
    }
}

fn isTcpConn(v: Value) bool {
    return objects.isForeign(v) and objects.foreignTypeTag(v) == TAG_TCP_CONN;
}

fn isTcpServer(v: Value) bool {
    return objects.isForeign(v) and objects.foreignTypeTag(v) == TAG_TCP_SERVER;
}

pub fn primTcpConnect(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.ContractViolation;
    if (!value_mod.isFixnum(args[1])) return error.ContractViolation;
    const host = objects.stringBytes(args[0]);
    const port: u16 = @intCast(@max(0, @min(65535, value_mod.fixnumVal(args[1]))));
    const stream = std.net.tcpConnectToHost(vm.allocator, host, port) catch |e| {
        const msg = std.fmt.allocPrint(vm.allocator, "tcp-connect: {s}", .{@errorName(e)}) catch
            return error.OutOfMemory;
        if (vm.error_msg) |old| vm.allocator.free(old);
        vm.error_msg = msg;
        return error.UserError;
    };
    const conn = vm.allocator.create(TcpConn) catch return error.OutOfMemory;
    conn.* = .{ .stream = stream, .allocator = vm.allocator };
    return objects.makeForeign(vm.gc, conn, deinitConn, TAG_TCP_CONN) catch return error.OutOfMemory;
}

pub fn primTcpSend(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!isTcpConn(args[0])) return error.ContractViolation;
    if (!objects.isString(args[1])) return error.ContractViolation;
    const conn: *TcpConn = @alignCast(@ptrCast(objects.foreignPayload(args[0]).?));
    if (conn.closed) return error.ContractViolation;
    const data = objects.stringBytes(args[1]);
    conn.stream.writeAll(data) catch |e| {
        const msg = std.fmt.allocPrint(vm.allocator, "tcp-send: {s}", .{@errorName(e)}) catch
            return error.OutOfMemory;
        if (vm.error_msg) |old| vm.allocator.free(old);
        vm.error_msg = msg;
        return error.UserError;
    };
    return value_mod.fixnum(@intCast(data.len));
}

pub fn primTcpRecv(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!isTcpConn(args[0])) return error.ContractViolation;
    if (!value_mod.isFixnum(args[1])) return error.ContractViolation;
    const conn: *TcpConn = @alignCast(@ptrCast(objects.foreignPayload(args[0]).?));
    if (conn.closed) return error.ContractViolation;
    const max: usize = @intCast(@max(0, value_mod.fixnumVal(args[1])));
    const buf = vm.allocator.alloc(u8, max) catch return error.OutOfMemory;
    defer vm.allocator.free(buf);
    const n = conn.stream.read(buf) catch |e| {
        const msg = std.fmt.allocPrint(vm.allocator, "tcp-recv: {s}", .{@errorName(e)}) catch
            return error.OutOfMemory;
        if (vm.error_msg) |old| vm.allocator.free(old);
        vm.error_msg = msg;
        return error.UserError;
    };
    return objects.makeString(vm.gc, buf[0..n]) catch return error.OutOfMemory;
}

pub fn primTcpClose(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    if (isTcpConn(args[0])) {
        const conn: *TcpConn = @alignCast(@ptrCast(objects.foreignPayload(args[0]).?));
        if (!conn.closed) {
            conn.stream.close();
            conn.closed = true;
        }
        return value_mod.NIL;
    }
    if (isTcpServer(args[0])) {
        const srv: *TcpServer = @alignCast(@ptrCast(objects.foreignPayload(args[0]).?));
        if (!srv.closed) {
            srv.server.deinit();
            srv.closed = true;
        }
        return value_mod.NIL;
    }
    return error.ContractViolation;
}

pub fn primTcpSocketQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    return if (isTcpConn(args[0])) value_mod.TRUE else value_mod.FALSE;
}

pub fn primTcpServerQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    return if (isTcpServer(args[0])) value_mod.TRUE else value_mod.FALSE;
}

// ── Server ────────────────────────────────────────────────────────────────────

pub fn primTcpListen(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!value_mod.isFixnum(args[0])) return error.ContractViolation;
    const port: u16 = @intCast(@max(0, @min(65535, value_mod.fixnumVal(args[0]))));
    const addr = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    const server = addr.listen(.{ .reuse_address = true }) catch |e| {
        const msg = std.fmt.allocPrint(vm.allocator, "tcp-listen: {s}", .{@errorName(e)}) catch
            return error.OutOfMemory;
        if (vm.error_msg) |old| vm.allocator.free(old);
        vm.error_msg = msg;
        return error.UserError;
    };
    const srv = vm.allocator.create(TcpServer) catch return error.OutOfMemory;
    srv.* = .{ .server = server, .allocator = vm.allocator };
    return objects.makeForeign(vm.gc, srv, deinitServer, TAG_TCP_SERVER) catch return error.OutOfMemory;
}

pub fn primTcpAccept(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isTcpServer(args[0])) return error.ContractViolation;
    const srv: *TcpServer = @alignCast(@ptrCast(objects.foreignPayload(args[0]).?));
    if (srv.closed) return error.ContractViolation;
    const conn_raw = srv.server.accept() catch |e| {
        const msg = std.fmt.allocPrint(vm.allocator, "tcp-accept: {s}", .{@errorName(e)}) catch
            return error.OutOfMemory;
        if (vm.error_msg) |old| vm.allocator.free(old);
        vm.error_msg = msg;
        return error.UserError;
    };
    const conn = vm.allocator.create(TcpConn) catch return error.OutOfMemory;
    conn.* = .{ .stream = conn_raw.stream, .allocator = vm.allocator };
    return objects.makeForeign(vm.gc, conn, deinitConn, TAG_TCP_CONN) catch return error.OutOfMemory;
}
