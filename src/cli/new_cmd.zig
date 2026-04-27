const std = @import("std");

pub fn runNew(alloc: std.mem.Allocator, new_args: []const []const u8) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();
    const cwd = std.fs.cwd();

    // Must be inside a project.
    cwd.access("project.lisp", .{}) catch {
        try stderr.writeAll("error: not inside a zepo project — run 'zepo init' first\n");
        std.process.exit(1);
    };

    if (new_args.len == 0) {
        try stderr.writeAll("Usage: zepo new <type> [name]\n  Types: module, lib, test\n  module → modules/<name>.lisp\n  lib    → lib/<name>/  (package)\n  test   → tests/<name>_test.lisp\n");
        std.process.exit(1);
    }

    const kind = new_args[0];
    const name = if (new_args.len > 1)
        new_args[1]
    else
        try promptName(alloc, kind);
    defer if (new_args.len <= 1) alloc.free(name);

    if (std.mem.eql(u8, kind, "module")) {
        try newModule(alloc, cwd, name, stdout, stderr);
    } else if (std.mem.eql(u8, kind, "lib")) {
        try newLib(alloc, cwd, name, stdout, stderr);
    } else if (std.mem.eql(u8, kind, "test")) {
        try newTest(alloc, cwd, name, stdout, stderr);
    } else {
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "error: unknown type '{s}' — expected: module, lib, test\n", .{kind});
        try stderr.writeAll(msg);
        std.process.exit(1);
    }
}

fn promptName(alloc: std.mem.Allocator, kind: []const u8) ![]const u8 {
    const stdout = std.fs.File.stdout();
    const stdin = std.fs.File.stdin();
    var buf: [256]u8 = undefined;
    var reader = stdin.reader(&buf);

    var prompt_buf: [64]u8 = undefined;
    const prompt = try std.fmt.bufPrint(&prompt_buf, "{s} name: ", .{kind});
    try stdout.writeAll(prompt);

    const line = (try reader.interface.takeDelimiter('\n')) orelse {
        try stdout.writeAll("\n");
        std.process.exit(1);
    };
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) {
        try std.fs.File.stderr().writeAll("error: name cannot be empty\n");
        std.process.exit(1);
    }
    return alloc.dupe(u8, trimmed);
}

fn newModule(alloc: std.mem.Allocator, cwd: std.fs.Dir, name: []const u8, stdout: std.fs.File, stderr: std.fs.File) !void {
    const filename = try std.fmt.allocPrint(alloc, "{s}.lisp", .{name});
    defer alloc.free(filename);
    const path = try std.fs.path.join(alloc, &.{ "modules", filename });
    defer alloc.free(path);

    guardExists(cwd, path, stderr);
    try cwd.makePath("modules");

    const f = try cwd.createFile(path, .{ .truncate = true });
    defer f.close();

    var content_buf: [256]u8 = undefined;
    const content = try std.fmt.bufPrint(&content_buf,
        \\(module {s}
        \\  (export))
        \\
        \\; Add your exported definitions here.
        \\
    , .{name});
    try f.writeAll(content);

    var msg_buf: [128]u8 = undefined;
    try stdout.writeAll(try std.fmt.bufPrint(&msg_buf, "created  {s}\n", .{path}));
}

fn newLib(alloc: std.mem.Allocator, cwd: std.fs.Dir, name: []const u8, stdout: std.fs.File, stderr: std.fs.File) !void {
    // Package directory: lib/<name>/package.lisp + lib/<name>/mod.lisp
    const pkg_dir_path = try std.fs.path.join(alloc, &.{ "lib", name });
    defer alloc.free(pkg_dir_path);
    try cwd.makePath(pkg_dir_path);

    const pkg_manifest = try std.fs.path.join(alloc, &.{ pkg_dir_path, "package.lisp" });
    defer alloc.free(pkg_manifest);
    guardExists(cwd, pkg_manifest, stderr);

    const mod_path = try std.fs.path.join(alloc, &.{ pkg_dir_path, "mod.lisp" });
    defer alloc.free(mod_path);

    {
        const f = try cwd.createFile(pkg_manifest, .{ .truncate = true });
        defer f.close();
        var buf: [256]u8 = undefined;
        try f.writeAll(try std.fmt.bufPrint(&buf,
            \\(package {s}
            \\  (version "0.1.0"))
            \\
        , .{name}));
    }
    {
        const f = try cwd.createFile(mod_path, .{ .truncate = true });
        defer f.close();
        var buf: [256]u8 = undefined;
        try f.writeAll(try std.fmt.bufPrint(&buf,
            \\(module {s}
            \\  (export))
            \\
            \\; Add your exported definitions here.
            \\
        , .{name}));
    }

    var msg_buf: [256]u8 = undefined;
    try stdout.writeAll(try std.fmt.bufPrint(&msg_buf, "created  {s}/\n", .{pkg_dir_path}));
    try newTest(alloc, cwd, name, stdout, stderr);
}

fn newTest(alloc: std.mem.Allocator, cwd: std.fs.Dir, name: []const u8, stdout: std.fs.File, stderr: std.fs.File) !void {
    const filename = try std.fmt.allocPrint(alloc, "{s}_test.lisp", .{name});
    defer alloc.free(filename);
    const path = try std.fs.path.join(alloc, &.{ "tests", filename });
    defer alloc.free(path);

    guardExists(cwd, path, stderr);
    try cwd.makePath("tests");

    const f = try cwd.createFile(path, .{ .truncate = true });
    defer f.close();

    var content_buf: [256]u8 = undefined;
    const content = try std.fmt.bufPrint(&content_buf,
        \\; Tests for {s}
        \\
        \\(assert #t) ; replace with real assertions
        \\
    , .{name});
    try f.writeAll(content);

    var msg_buf: [128]u8 = undefined;
    try stdout.writeAll(try std.fmt.bufPrint(&msg_buf, "created  {s}\n", .{path}));
}

fn guardExists(cwd: std.fs.Dir, path: []const u8, stderr: std.fs.File) void {
    if (cwd.access(path, .{})) |_| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: '{s}' already exists\n", .{path}) catch "error: file already exists\n";
        stderr.writeAll(msg) catch {};
        std.process.exit(1);
    } else |_| {}
}
