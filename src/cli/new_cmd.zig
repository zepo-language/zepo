const std = @import("std");

// zepo-n3h
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

fn makePath(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/') {
            if (i == 0) continue;
            @memcpy(buf[0..i], path[0..i]);
            buf[i] = 0;
            _ = std.c.mkdir(@ptrCast(&buf), 0o755);
        }
    }
}

fn accessExists(path: []const u8) bool {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return false;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    return std.c.access(@ptrCast(&pbuf), 0) == 0;
}

fn writeStdout(bytes: []const u8) void {
    _ = std.c.write(1, bytes.ptr, bytes.len);
}
fn writeStderr(bytes: []const u8) void {
    _ = std.c.write(2, bytes.ptr, bytes.len);
}

pub fn runNew(alloc: std.mem.Allocator, new_args: []const []const u8) !void {
    if (new_args.len == 0) {
        // zepo-n3h
        writeStderr("Usage: zepo new <type> [name]\n  Types: module, lib, test, package\n  module  → modules/<name>.lisp         (requires project)\n  test    → tests/<name>_test.lisp      (requires project)\n  lib     → <name>/<name>.lisp          (standalone, single-file library)\n  package → <name>/src/main.lisp        (standalone, multi-module package)\n");
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
        try newPackage(alloc, name);
        return;
    }
    if (std.mem.eql(u8, kind, "lib")) {
        try newLib(alloc, name);
        return;
    }

    // All other types must be run inside a project.
    // zepo-n3h
    if (!accessExists("project.lisp")) {
        writeStderr("error: not inside a zepo project — run 'zepo init' first\n");
        std.process.exit(1);
    }

    if (std.mem.eql(u8, kind, "module")) {
        try newModule(alloc, name);
    } else if (std.mem.eql(u8, kind, "test")) {
        try newTest(alloc, name);
    } else {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: unknown type '{s}' — expected: module, lib, test, package\n", .{kind}) catch "error: unknown type\n";
        writeStderr(msg);
        std.process.exit(1);
    }
}

// zepo-n3h: read a line from stdin using std.c.read
fn promptName(alloc: std.mem.Allocator, kind: []const u8) ![]const u8 {
    var prompt_buf: [64]u8 = undefined;
    const prompt = std.fmt.bufPrint(&prompt_buf, "{s} name: ", .{kind}) catch "name: ";
    _ = std.c.write(1, prompt.ptr, prompt.len);

    var line_buf: [256]u8 = undefined;
    var len: usize = 0;
    while (len < line_buf.len) {
        var b: u8 = 0;
        const n = std.c.read(0, @as([*]u8, @ptrCast(&b)), 1);
        if (n <= 0) break;
        if (b == '\n') break;
        line_buf[len] = b;
        len += 1;
    }
    _ = std.c.write(1, "\n", 1);
    const trimmed = std.mem.trim(u8, line_buf[0..len], " \t\r");
    if (trimmed.len == 0) {
        writeStderr("error: name cannot be empty\n");
        std.process.exit(1);
    }
    return alloc.dupe(u8, trimmed);
}

fn newModule(alloc: std.mem.Allocator, name: []const u8) !void {
    const filename = try std.fmt.allocPrint(alloc, "{s}.lisp", .{name});
    defer alloc.free(filename);
    const path = try std.fs.path.join(alloc, &.{ "modules", filename });
    defer alloc.free(path);

    guardExists(path);
    makePath("modules");

    var content_buf: [256]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf,
        \\(module {s}
        \\  (export))
        \\
        \\; Add your exported definitions here.
        \\
    , .{name}) catch return error.NoSpaceLeft;
    _ = writeFilePosix(path, content);

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "created  {s}\n", .{path}) catch "created\n";
    writeStdout(msg);
}

fn newLib(alloc: std.mem.Allocator, name: []const u8) !void {
    guardExists(name);
    makePath(name);

    const lib_filename = try std.fmt.allocPrint(alloc, "{s}.lisp", .{name});
    defer alloc.free(lib_filename);
    const lib_path = try std.fs.path.join(alloc, &.{ name, lib_filename });
    defer alloc.free(lib_path);

    {
        var buf: [512]u8 = undefined;
        const content = std.fmt.bufPrint(&buf,
            \\(lib {s}
            \\  :version "0.1.0"
            \\  :docstring ""
            \\  (export))
            \\
            \\; Add your exported definitions here.
            \\
        , .{name}) catch return error.NoSpaceLeft;
        _ = writeFilePosix(lib_path, content);
    }

    var msg_buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf,
        \\created  {s}/
        \\         {s}
        \\
        \\Next steps:
        \\  1. Add definitions to {s}
        \\  2. List exported names in (lib {s} ... (export ...))
        \\  3. zepo install ./{s}
        \\  4. (import :libs ({s})) in your program
        \\
    , .{ name, lib_path, lib_path, name, name, name }) catch "created\n";
    writeStdout(msg);
}

fn newTest(alloc: std.mem.Allocator, name: []const u8) !void {
    const filename = try std.fmt.allocPrint(alloc, "{s}_test.lisp", .{name});
    defer alloc.free(filename);
    const path = try std.fs.path.join(alloc, &.{ "tests", filename });
    defer alloc.free(path);

    guardExists(path);
    makePath("tests");

    var content_buf: [256]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf,
        \\; Tests for {s}
        \\
        \\(assert #t) ; replace with real assertions
        \\
    , .{name}) catch return error.NoSpaceLeft;
    _ = writeFilePosix(path, content);

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "created  {s}\n", .{path}) catch "created\n";
    writeStdout(msg);
}

fn newPackage(alloc: std.mem.Allocator, name: []const u8) !void {
    guardExists(name);
    const src_dir_path = try std.fs.path.join(alloc, &.{ name, "src" });
    defer alloc.free(src_dir_path);
    makePath(src_dir_path);

    const main_path = try std.fs.path.join(alloc, &.{ src_dir_path, "main.lisp" });
    defer alloc.free(main_path);
    {
        var buf: [512]u8 = undefined;
        const content = std.fmt.bufPrint(&buf,
            \\(package {s}
            \\  :version "0.1.0"
            \\  :docstring "")
            \\
            \\; Add modules to src/ and import them here.
            \\; (import :modules ({s}.core))
            \\
        , .{ name, name }) catch return error.NoSpaceLeft;
        _ = writeFilePosix(main_path, content);
    }

    var msg_buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf,
        \\created  {s}/
        \\         {s}
        \\
        \\Next steps:
        \\  1. Edit {s} — set version, docstring, add modules
        \\  2. Add source files to {s}/
        \\  3. zepo install ./{s}
        \\  4. (import :packages ({s})) in your program
        \\
    , .{ name, main_path, main_path, src_dir_path, name, name }) catch "created\n";
    writeStdout(msg);
}

// zepo-n3h
fn guardExists(path: []const u8) void {
    if (accessExists(path)) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: '{s}' already exists\n", .{path}) catch "error: file already exists\n";
        writeStderr(msg);
        std.process.exit(1);
    }
}
