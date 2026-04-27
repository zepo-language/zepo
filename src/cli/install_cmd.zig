const std = @import("std");

pub fn runInstall(alloc: std.mem.Allocator, pkg_path: []const u8) !void {
    const stderr = std.fs.File.stderr();
    const stdout = std.fs.File.stdout();

    // Resolve the package name from the last path component.
    const pkg_name = std.fs.path.basename(pkg_path);
    if (pkg_name.len == 0) {
        try stderr.writeAll("error: invalid package path\n");
        std.process.exit(1);
    }

    // Destination: ~/.local/lib/zepo/<pkg_name>
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch {
        try stderr.writeAll("error: HOME not set\n");
        std.process.exit(1);
    };
    defer alloc.free(home);

    const dest_base = try std.fs.path.join(alloc, &.{ home, ".local/lib/zepo" });
    defer alloc.free(dest_base);
    const dest = try std.fs.path.join(alloc, &.{ dest_base, pkg_name });
    defer alloc.free(dest);

    // Ensure destination base exists.
    std.fs.cwd().makePath(dest_base) catch {};

    // Copy the directory tree.
    var src_dir = std.fs.cwd().openDir(pkg_path, .{ .iterate = true }) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: cannot open '{s}': {}\n", .{ pkg_path, e }) catch "error: cannot open source\n";
        try stderr.writeAll(msg);
        std.process.exit(1);
    };
    defer src_dir.close();

    std.fs.cwd().deleteTree(dest) catch {};
    try std.fs.cwd().makePath(dest);
    var dest_dir = try std.fs.cwd().openDir(dest, .{});
    defer dest_dir.close();

    try copyDirAll(alloc, src_dir, dest_dir);

    var msg_buf: [512]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf, "installed '{s}' → {s}\n", .{ pkg_name, dest });
    try stdout.writeAll(msg);
}

fn copyDirAll(alloc: std.mem.Allocator, src: std.fs.Dir, dest: std.fs.Dir) !void {
    var it = src.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const data = try src.readFileAlloc(alloc, entry.name, 16 * 1024 * 1024);
                defer alloc.free(data);
                const f = try dest.createFile(entry.name, .{ .truncate = true });
                defer f.close();
                try f.writeAll(data);
            },
            .directory => {
                dest.makeDir(entry.name) catch {};
                var sub_src = try src.openDir(entry.name, .{ .iterate = true });
                defer sub_src.close();
                var sub_dest = try dest.openDir(entry.name, .{});
                defer sub_dest.close();
                try copyDirAll(alloc, sub_src, sub_dest);
            },
            else => {},
        }
    }
}
