/// fmt_cmd.zig — Lisp source formatter for zepo
///
/// zepo fmt [--check] [--stdout] [file...]
///
/// Self-contained: tokenizer, CST parser, pretty-printer, entry point.
/// No GC, no eval — pure text transformation.

const std = @import("std");
// zepo-g44i: formatter core lives in the zepo module so the LSP can use it
// without dragging cli/ into its module graph.
const zepo = @import("zepo");
const formatSource = zepo.format.formatSource;

// zepo-n3h
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

fn readFilePosix(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return null;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const f = std.c.fopen(@ptrCast(&pbuf), "rb") orelse return null;
    defer _ = std.c.fclose(f);
    _ = fseek(f, 0, 2);
    const size: usize = @intCast(@max(0, ftell(f)));
    _ = fseek(f, 0, 0);
    const buf = alloc.alloc(u8, size) catch return null;
    _ = std.c.fread(buf.ptr, 1, size, f);
    return buf;
}

fn writeFilePosix(path: []const u8, data: []const u8) bool {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return false;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const f = std.c.fopen(@ptrCast(&pbuf), "wb") orelse return false;
    defer _ = std.c.fclose(f);
    _ = std.c.fwrite(data.ptr, 1, data.len, f);
    return true;
}

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

fn collectLispFiles(alloc: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayListUnmanaged([]u8)) !void {
    var pbuf: [4096]u8 = undefined;
    const n = @min(dir_path.len, pbuf.len - 1);
    @memcpy(pbuf[0..n], dir_path[0..n]);
    pbuf[n] = 0;
    const d = std.c.opendir(@ptrCast(&pbuf)) orelse return;
    defer _ = std.c.closedir(d);
    while (std.c.readdir(d)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.sliceTo(name_ptr, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        switch (entry.type) {
            std.c.DT.DIR => {
                const sub = try std.fs.path.join(alloc, &.{ dir_path, name });
                defer alloc.free(sub);
                try collectLispFiles(alloc, sub, out);
            },
            std.c.DT.REG => {
                if (std.mem.endsWith(u8, name, ".lisp")) {
                    const path = try std.fs.path.join(alloc, &.{ dir_path, name });
                    try out.append(alloc, path);
                }
            },
            else => {},
        }
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn runFmt(alloc: std.mem.Allocator, fmt_args: []const []const u8) !void {
    var check_mode = false;
    var stdout_mode = false;
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(alloc);

    // Parse flags
    for (fmt_args) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_mode = true;
        } else if (std.mem.eql(u8, arg, "--stdout")) {
            stdout_mode = true;
        } else {
            try files.append(alloc, arg);
        }
    }

    // Discover files if none given
    var discovered: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (discovered.items) |p| alloc.free(p);
        discovered.deinit(alloc);
    }

    var file_list: []const []const u8 = files.items;
    if (files.items.len == 0) {
        try collectLispFiles(alloc, "src", &discovered);
        try collectLispFiles(alloc, "modules", &discovered);
        file_list = discovered.items;
    }

    var would_change: bool = false;

    for (file_list) |path| {
        // zepo-n3h
        const src = readFilePosix(alloc, path) orelse {
            const msg = try std.fmt.allocPrint(alloc, "error: cannot read '{s}'\n", .{path});
            defer alloc.free(msg);
            _ = std.c.write(2, msg.ptr, msg.len);
            std.process.exit(1);
        };
        defer alloc.free(src);

        const formatted = try formatSource(alloc, src);
        defer alloc.free(formatted);

        if (check_mode) {
            if (!std.mem.eql(u8, src, formatted)) {
                const msg = try std.fmt.allocPrint(alloc, "would reformat: {s}\n", .{path});
                defer alloc.free(msg);
                _ = std.c.write(2, msg.ptr, msg.len);
                would_change = true;
            }
        } else if (stdout_mode) {
            _ = std.c.write(1, formatted.ptr, formatted.len);
        } else {
            if (!std.mem.eql(u8, src, formatted)) {
                // zepo-n3h
                _ = writeFilePosix(path, formatted);
                const msg2 = try std.fmt.allocPrint(alloc, "reformatted: {s}\n", .{path});
                defer alloc.free(msg2);
                _ = std.c.write(2, msg2.ptr, msg2.len);
            }
        }
    }

    if (check_mode and would_change) {
        std.process.exit(1);
    }
}
