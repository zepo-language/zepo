//! System primitives: file I/O, directory ops, environment, process execution.

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

fn requireString(v: Value) LispError![]const u8 {
    if (!objects.isString(v)) return error.TypeError;
    return objects.stringBytes(v);
}

// ── File I/O ──────────────────────────────────────────────────────────────────

/// (file-read-string path) → string
pub fn primFileReadString(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const path = try requireString(args[0]);
    const src = std.fs.cwd().readFileAlloc(vm.allocator, path, 64 * 1024 * 1024) catch return error.IOError;
    defer vm.allocator.free(src);
    return objects.makeString(vm.gc, src) catch return error.OutOfMemory;
}

/// (file-write-string path str) → ()
pub fn primFileWriteString(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 2) return error.ArityMismatch;
    const path = try requireString(args[0]);
    const data = try requireString(args[1]);
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return error.IOError;
    defer f.close();
    f.writeAll(data) catch return error.IOError;
    return value_mod.NIL;
}

/// (file-append-string path str) → ()
pub fn primFileAppendString(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 2) return error.ArityMismatch;
    const path = try requireString(args[0]);
    const data = try requireString(args[1]);
    const f = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch
        std.fs.cwd().createFile(path, .{}) catch return error.IOError;
    defer f.close();
    f.seekFromEnd(0) catch return error.IOError;
    f.writeAll(data) catch return error.IOError;
    return value_mod.NIL;
}

/// (file-exists? path) → bool
pub fn primFileExistsQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const path = try requireString(args[0]);
    std.fs.cwd().access(path, .{}) catch return value_mod.FALSE;
    return value_mod.TRUE;
}

/// (file-delete path) → ()
pub fn primFileDelete(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const path = try requireString(args[0]);
    std.fs.cwd().deleteFile(path) catch return error.IOError;
    return value_mod.NIL;
}

// ── Directory ops ─────────────────────────────────────────────────────────────

/// (directory-list path) → list of strings
pub fn primDirectoryList(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const path = try requireString(args[0]);
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return error.IOError;
    defer dir.close();

    var result: Value = value_mod.NIL;
    var entries: std.ArrayListUnmanaged([]u8) = .{};
    defer {
        for (entries.items) |e| vm.allocator.free(e);
        entries.deinit(vm.allocator);
    }

    var it = dir.iterate();
    while (it.next() catch return error.IOError) |entry| {
        const name = vm.allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
        entries.append(vm.allocator, name) catch return error.OutOfMemory;
    }

    var i: usize = entries.items.len;
    while (i > 0) {
        i -= 1;
        const sv = objects.makeString(vm.gc, entries.items[i]) catch return error.OutOfMemory;
        result = objects.makePair(vm.gc, sv, result) catch return error.OutOfMemory;
    }
    return result;
}

/// (make-directory path) → ()
pub fn primMakeDirectory(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const path = try requireString(args[0]);
    std.fs.cwd().makePath(path) catch return error.IOError;
    return value_mod.NIL;
}

/// (current-directory) → string
pub fn primCurrentDirectory(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 0) return error.ArityMismatch;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &buf) catch return error.IOError;
    return objects.makeString(vm.gc, cwd) catch return error.OutOfMemory;
}

// ── Environment ───────────────────────────────────────────────────────────────

/// (getenv name) → string or #f
pub fn primGetenv(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const name = try requireString(args[0]);
    const val = std.process.getEnvVarOwned(vm.allocator, name) catch return value_mod.FALSE;
    defer vm.allocator.free(val);
    return objects.makeString(vm.gc, val) catch return error.OutOfMemory;
}

// ── Process execution ─────────────────────────────────────────────────────────

/// (shell cmd) → string (combined stdout output, exit code ignored)
pub fn primShell(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const cmd = try requireString(args[0]);

    const result = std.process.Child.run(.{
        .allocator = vm.allocator,
        .argv = &.{ "/bin/sh", "-c", cmd },
    }) catch return error.IOError;
    defer vm.allocator.free(result.stdout);
    defer vm.allocator.free(result.stderr);

    return objects.makeString(vm.gc, result.stdout) catch return error.OutOfMemory;
}

/// (shell/status cmd) → integer exit code
pub fn primShellStatus(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const cmd = try requireString(args[0]);

    const result = std.process.Child.run(.{
        .allocator = vm.allocator,
        .argv = &.{ "/bin/sh", "-c", cmd },
    }) catch return error.IOError;
    defer vm.allocator.free(result.stdout);
    defer vm.allocator.free(result.stderr);

    const code: i63 = switch (result.term) {
        .Exited => |c| @intCast(c),
        else => -1,
    };
    return value_mod.fixnum(code);
}
