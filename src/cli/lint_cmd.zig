const std = @import("std");
const lsp_cmd = @import("lsp_cmd.zig");

/// zepo lint [file...]
/// Runs the LSP diagnostic pass over each file and prints results.
/// Exits 1 if any diagnostics are found.
pub fn runLint(alloc: std.mem.Allocator, lint_args: []const []const u8) !void {
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();

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
        try stdout.writeAll("No .lisp files found.\n");
        return;
    }

    var total_diags: usize = 0;

    for (files.items) |path| {
        const src = std.Io.Dir.cwd().readFileAlloc(alloc, path, 16 * 1024 * 1024) catch |e| {
            var buf: [256]u8 = undefined;
            try stderr.writeAll(std.fmt.bufPrint(&buf, "error: cannot read '{s}': {}\n", .{ path, e }) catch "error: cannot read file\n");
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
            const line = try std.fmt.bufPrint(&buf, "{s}:{d}:{d}: {s}\n", .{
                path, d.start_line + 1, d.start_char + 1, d.message,
            });
            try stdout.writeAll(line);
            total_diags += 1;
        }
    }

    if (total_diags > 0) {
        var buf: [64]u8 = undefined;
        try stderr.writeAll(try std.fmt.bufPrint(&buf, "\n{d} diagnostic(s) found.\n", .{total_diags}));
        std.process.exit(1);
    } else {
        try stdout.writeAll("No issues found.\n");
    }
}

fn collectLisp(alloc: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var dir = std.Io.Dir.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const full = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".lisp")) {
                    try out.append(alloc, full);
                } else {
                    alloc.free(full);
                }
            },
            .directory => {
                try collectLisp(alloc, full, out);
                alloc.free(full);
            },
            else => alloc.free(full),
        }
    }
}
