//! System primitives: file I/O, directory ops, environment, process execution.
// zepo-04p: Zig 0.16 — std.Io.Dir removed; all ops use POSIX/C directly.

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

// Declare C stdlib functions not in std.c.
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
extern "c" fn popen(command: [*:0]const u8, mode: [*:0]const u8) ?*std.c.FILE;
extern "c" fn pclose(stream: *std.c.FILE) c_int;
extern "c" fn close(fd: std.c.fd_t) c_int;

fn requireString(v: Value) LispError![]const u8 {
    if (!objects.isString(v)) return error.TypeError;
    return objects.stringBytes(v);
}

fn toCStr(path: []const u8, buf: []u8) ?[*:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf.ptr);
}

// ── File I/O ──────────────────────────────────────────────────────────────────

/// (file-read-string path) → string
pub fn primFileReadString(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const path = try requireString(args[0]);
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path_c = toCStr(path, &pbuf) orelse return error.IOError;
    const f = std.c.fopen(path_c, "rb") orelse return error.IOError;
    defer _ = std.c.fclose(f);
    _ = fseek(f, 0, 2); // SEEK_END
    const size = ftell(f);
    if (size < 0) return error.IOError;
    _ = fseek(f, 0, 0); // SEEK_SET
    const buf = vm.allocator.alloc(u8, @intCast(size)) catch return error.OutOfMemory;
    defer vm.allocator.free(buf);
    const n = std.c.fread(buf.ptr, 1, buf.len, f);
    return objects.makeString(vm.gc, buf[0..n]) catch return error.OutOfMemory;
}

/// (file-write-string path str) → ()
pub fn primFileWriteString(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 2) return error.ArityMismatch;
    const path = try requireString(args[0]);
    const data = try requireString(args[1]);
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path_c = toCStr(path, &pbuf) orelse return error.IOError;
    const f = std.c.fopen(path_c, "wb") orelse return error.IOError;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(data.ptr, 1, data.len, f);
    return value_mod.NIL;
}

/// (file-append-string path str) → ()
pub fn primFileAppendString(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 2) return error.ArityMismatch;
    const path = try requireString(args[0]);
    const data = try requireString(args[1]);
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path_c = toCStr(path, &pbuf) orelse return error.IOError;
    const f = std.c.fopen(path_c, "ab") orelse return error.IOError;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(data.ptr, 1, data.len, f);
    return value_mod.NIL;
}

/// (file-exists? path) → bool
pub fn primFileExistsQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const path = try requireString(args[0]);
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path_c = toCStr(path, &pbuf) orelse return value_mod.FALSE;
    return if (std.c.access(path_c, 0) == 0) value_mod.TRUE else value_mod.FALSE;
}

/// (file-delete path) → ()
pub fn primFileDelete(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const path = try requireString(args[0]);
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path_c = toCStr(path, &pbuf) orelse return error.IOError;
    if (std.c.unlink(path_c) != 0) return error.IOError;
    return value_mod.NIL;
}

// ── Directory ops ─────────────────────────────────────────────────────────────

/// (directory-list path) → list of strings
pub fn primDirectoryList(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const path = try requireString(args[0]);
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path_c = toCStr(path, &pbuf) orelse return error.IOError;
    const dp = std.c.opendir(path_c) orelse return error.IOError;
    defer _ = std.c.closedir(dp);

    var entries: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (entries.items) |e| vm.allocator.free(e);
        entries.deinit(vm.allocator);
    }

    while (std.c.readdir(dp)) |entry| {
        const name = std.mem.sliceTo(&entry.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const dup = vm.allocator.dupe(u8, name) catch return error.OutOfMemory;
        entries.append(vm.allocator, dup) catch return error.OutOfMemory;
    }

    var result: Value = value_mod.NIL;
    var i: usize = entries.items.len;
    while (i > 0) {
        i -= 1;
        const sv = objects.makeString(vm.gc, entries.items[i]) catch return error.OutOfMemory;
        result = objects.makePair(vm.gc, sv, result) catch return error.OutOfMemory;
    }
    return result;
}

/// (make-directory path) → ()
/// Creates path and all missing parent components (like mkdir -p).
pub fn primMakeDirectory(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const path = try requireString(args[0]);
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= pbuf.len) return error.IOError;
    // Walk each prefix and mkdir.
    for (1..path.len + 1) |i| {
        if (i < path.len and path[i] != '/') continue;
        @memcpy(pbuf[0..i], path[0..i]);
        pbuf[i] = 0;
        const seg: [*:0]const u8 = @ptrCast(&pbuf);
        // Ignore EEXIST.
        _ = std.c.mkdir(seg, 0o755);
    }
    return value_mod.NIL;
}

/// (current-directory) → string
pub fn primCurrentDirectory(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 0) return error.ArityMismatch;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ptr = std.c.getcwd(&buf, buf.len) orelse return error.IOError;
    const cwd = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
    return objects.makeString(vm.gc, cwd) catch return error.OutOfMemory;
}

// ── Environment ───────────────────────────────────────────────────────────────

/// (getenv name) → string or #f
pub fn primGetenv(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const name = try requireString(args[0]);
    var nbuf: [512]u8 = undefined;
    if (name.len >= nbuf.len) return value_mod.FALSE;
    @memcpy(nbuf[0..name.len], name);
    nbuf[name.len] = 0;
    const raw = std.c.getenv(@ptrCast(&nbuf)) orelse return value_mod.FALSE;
    const val = std.mem.span(raw);
    return objects.makeString(vm.gc, val) catch return error.OutOfMemory;
}

// ── Process execution ─────────────────────────────────────────────────────────

/// (shell cmd) → string (combined stdout output, exit code ignored)
pub fn primShell(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const cmd = try requireString(args[0]);
    var cbuf: [4096]u8 = undefined;
    const cmd_c = toCStr(cmd, &cbuf) orelse return error.IOError;
    const f = popen(cmd_c, "r") orelse return error.IOError;
    defer _ = pclose(f);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(vm.allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = std.c.fread(&chunk, 1, chunk.len, f);
        if (n == 0) break;
        out.appendSlice(vm.allocator, chunk[0..n]) catch return error.OutOfMemory;
    }
    return objects.makeString(vm.gc, out.items) catch return error.OutOfMemory;
}

/// (shell/status cmd) → integer exit code
pub fn primShellStatus(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const cmd = try requireString(args[0]);
    var cbuf: [4096]u8 = undefined;
    const cmd_c = toCStr(cmd, &cbuf) orelse return error.IOError;
    const f = popen(cmd_c, "r") orelse return error.IOError;
    // drain output
    var chunk: [4096]u8 = undefined;
    while (std.c.fread(&chunk, 1, chunk.len, f) > 0) {}
    const status = pclose(f);
    const code: i63 = if (status >= 0) @intCast((status >> 8) & 0xff) else -1;
    return value_mod.fixnum(code);
}
