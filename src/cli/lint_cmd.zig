const std = @import("std");
const lsp_cmd = @import("lsp_cmd.zig");

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

fn writeStdout(bytes: []const u8) void {
    _ = std.c.write(1, bytes.ptr, bytes.len);
}
fn writeStderr(bytes: []const u8) void {
    _ = std.c.write(2, bytes.ptr, bytes.len);
}

/// zepo lint [file...]
/// Runs the LSP diagnostic pass over each file and prints results.
/// Exits 1 if any diagnostics are found.
pub fn runLint(alloc: std.mem.Allocator, lint_args: []const []const u8) !void {
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer files.deinit(alloc);

    if (lint_args.len > 0) {
        try files.appendSlice(alloc, lint_args);
    } else {
        // Discover .lisp files under src/ and modules/.
        try collectLisp(alloc, "src", &files);
        try collectLisp(alloc, "modules", &files);
    }

    if (files.items.len == 0) {
        const msg = "No .lisp files found.\n";
        writeStdout(msg);
        return;
    }

    var total_diags: usize = 0;

    for (files.items) |path| {
        // zepo-n3h
        const src = readFilePosix(alloc, path) orelse {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: cannot read '{s}'\n", .{path}) catch "error: cannot read file\n";
            writeStderr(msg);
            continue;
        };
        defer alloc.free(src);

        var diags = try lsp_cmd.checkDocument(alloc, path, src);
        defer {
            for (diags.items) |d| if (d.msg_owned) alloc.free(d.message);
            diags.deinit(alloc);
        }

        for (diags.items) |d| {
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "{s}:{d}:{d}: {s}\n", .{
                path, d.start_line + 1, d.start_char + 1, d.message,
            }) catch continue;
            writeStdout(line);
            total_diags += 1;
        }
    }

    if (total_diags > 0) {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "\n{d} diagnostic(s) found.\n", .{total_diags}) catch "diagnostics found.\n";
        writeStderr(msg);
        std.process.exit(1);
    } else {
        writeStdout("No issues found.\n");
    }
}

// zepo-n3h
fn collectLisp(alloc: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
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
        const full = try std.fs.path.join(alloc, &.{ dir_path, name });
        switch (entry.type) {
            std.c.DT.REG => {
                if (std.mem.endsWith(u8, name, ".lisp")) {
                    try out.append(alloc, full);
                } else {
                    alloc.free(full);
                }
            },
            std.c.DT.DIR => {
                try collectLisp(alloc, full, out);
                alloc.free(full);
            },
            else => alloc.free(full),
        }
    }
}
