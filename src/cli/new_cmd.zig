const std = @import("std");

pub fn runNew(alloc: std.mem.Allocator, new_args: []const []const u8) !void {
    const stdout = std.Io.File.stdout();
    const stderr = std.Io.File.stderr();
    const cwd = std.Io.Dir.cwd();

    if (new_args.len == 0) {
        try stderr.writeAll("Usage: zepo new <type> [name]\n  Types: module, lib, test, package\n  module  → modules/<name>.lisp         (requires project)\n  test    → tests/<name>_test.lisp      (requires project)\n  lib     → <name>/<name>.lisp          (standalone, single-file library)\n  package → <name>/src/main.lisp        (standalone, multi-module package)\n");
        std.process.exit(1);
    }

    const kind = new_args[0];
    const name = if (new_args.len > 1)
        new_args[1]
    else
        try promptName(alloc, kind);
    defer if (new_args.len <= 1) alloc.free(name);

    // 'package' and 'lib' are standalone — no project.lisp required.
    if (std.mem.eql(u8, kind, "package")) {
        try newPackage(alloc, cwd, name, stdout, stderr);
        return;
    }
    if (std.mem.eql(u8, kind, "lib")) {
        try newLib(alloc, cwd, name, stdout, stderr);
        return;
    }

    // All other types must be run inside a project.
    cwd.access("project.lisp", .{}) catch {
        try stderr.writeAll("error: not inside a zepo project — run 'zepo init' first\n");
        std.process.exit(1);
    };

    if (std.mem.eql(u8, kind, "module")) {
        try newModule(alloc, cwd, name, stdout, stderr);
    } else if (std.mem.eql(u8, kind, "test")) {
        try newTest(alloc, cwd, name, stdout, stderr);
    } else {
        var buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "error: unknown type '{s}' — expected: module, lib, test, package\n", .{kind});
        try stderr.writeAll(msg);
        std.process.exit(1);
    }
}

fn promptName(alloc: std.mem.Allocator, kind: []const u8) ![]const u8 {
    const stdout = std.Io.File.stdout();
    const stdin = std.Io.File.stdin();
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
        try std.Io.File.stderr().writeAll("error: name cannot be empty\n");
        std.process.exit(1);
    }
    return alloc.dupe(u8, trimmed);
}

fn newModule(alloc: std.mem.Allocator, cwd: std.fs.Dir, name: []const u8, stdout: std.Io.File, stderr: std.Io.File) !void {
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

fn newLib(alloc: std.mem.Allocator, cwd: std.fs.Dir, name: []const u8, stdout: std.Io.File, stderr: std.Io.File) !void {
    // Standalone single-file library: <name>/<name>.lisp with (lib ...) container.
    guardExists(cwd, name, stderr);
    try cwd.makePath(name);

    const lib_filename = try std.fmt.allocPrint(alloc, "{s}.lisp", .{name});
    defer alloc.free(lib_filename);
    const lib_path = try std.fs.path.join(alloc, &.{ name, lib_filename });
    defer alloc.free(lib_path);

    {
        const f = try cwd.createFile(lib_path, .{ .truncate = true });
        defer f.close();
        var buf: [512]u8 = undefined;
        try f.writeAll(try std.fmt.bufPrint(&buf,
            \\(lib {s}
            \\  :version "0.1.0"
            \\  :docstring ""
            \\  (export))
            \\
            \\; Add your exported definitions here.
            \\
        , .{name}));
    }

    var msg_buf: [1024]u8 = undefined;
    try stdout.writeAll(try std.fmt.bufPrint(&msg_buf,
        \\created  {s}/
        \\         {s}
        \\
        \\Next steps:
        \\  1. Add definitions to {s}
        \\  2. List exported names in (lib {s} ... (export ...))
        \\  3. zepo install ./{s}
        \\  4. (import :libs ({s})) in your program
        \\
    , .{ name, lib_path, lib_path, name, name, name }));
}

fn newTest(alloc: std.mem.Allocator, cwd: std.fs.Dir, name: []const u8, stdout: std.Io.File, stderr: std.Io.File) !void {
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

fn newPackage(alloc: std.mem.Allocator, cwd: std.fs.Dir, name: []const u8, stdout: std.Io.File, stderr: std.Io.File) !void {
    // Layout: <name>/src/main.lisp — package entry point with (package ...) container.
    guardExists(cwd, name, stderr);
    const src_dir_path = try std.fs.path.join(alloc, &.{ name, "src" });
    defer alloc.free(src_dir_path);
    try cwd.makePath(src_dir_path);

    const main_path = try std.fs.path.join(alloc, &.{ src_dir_path, "main.lisp" });
    defer alloc.free(main_path);
    {
        const f = try cwd.createFile(main_path, .{ .truncate = true });
        defer f.close();
        var buf: [512]u8 = undefined;
        try f.writeAll(try std.fmt.bufPrint(&buf,
            \\(package {s}
            \\  :version "0.1.0"
            \\  :docstring "")
            \\
            \\; Add modules to src/ and import them here.
            \\; (import :modules ({s}.core))
            \\
        , .{ name, name }));
    }

    var msg_buf: [1024]u8 = undefined;
    try stdout.writeAll(try std.fmt.bufPrint(&msg_buf,
        \\created  {s}/
        \\         {s}
        \\
        \\Next steps:
        \\  1. Edit {s} — set version, docstring, add modules
        \\  2. Add source files to {s}/
        \\  3. zepo install ./{s}
        \\  4. (import :packages ({s})) in your program
        \\
    , .{ name, main_path, main_path, src_dir_path, name, name }));
}

fn guardExists(cwd: std.fs.Dir, path: []const u8, stderr: std.Io.File) void {
    if (cwd.access(path, .{})) |_| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: '{s}' already exists\n", .{path}) catch "error: file already exists\n";
        stderr.writeAll(msg) catch {};
        std.process.exit(1);
    } else |_| {}
}
