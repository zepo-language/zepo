const std = @import("std");

// zepo-n3h
extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;

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

pub fn runInit(alloc: std.mem.Allocator, extra_args: []const []const u8) !void {
    // If a directory name was given, create it and work inside it.
    if (extra_args.len > 0) {
        const dir_name = extra_args[0];
        // zepo-n3h
        makePath(dir_name);
        var cbuf: [4096]u8 = undefined;
        if (dir_name.len < cbuf.len) {
            @memcpy(cbuf[0..dir_name.len], dir_name);
            cbuf[dir_name.len] = 0;
            _ = std.c.chdir(@ptrCast(&cbuf));
        }
    }

    // Error if project.lisp already exists.
    // zepo-n3h
    if (accessExists("project.lisp")) {
        writeStderr("error: project.lisp already exists — already a zepo project\n");
        std.process.exit(1);
    }

    // Infer project name from CWD.
    // zepo-n3h
    var cwdbuf: [4096]u8 = undefined;
    const cwd_ptr = getcwd(&cwdbuf, cwdbuf.len);
    const cwd_str: []const u8 = if (cwd_ptr) |p| std.mem.sliceTo(p, 0) else ".";
    const cwd_owned = try alloc.dupe(u8, cwd_str);
    defer alloc.free(cwd_owned);
    const name = std.fs.path.basename(cwd_owned);

    // Write project.lisp.
    {
        var buf: [512]u8 = undefined;
        const content = try std.fmt.bufPrint(&buf,
            \\(project
            \\  (name "{s}")
            \\  (version "0.1.0")
            \\  (entry "src/main.lisp")
            \\  (paths "modules" "lib")
            \\  (test-dir "tests"))
            \\
        , .{name});
        if (!writeFilePosix("project.lisp", content)) {
            writeStderr("error: cannot write project.lisp\n");
            std.process.exit(1);
        }
    }

    // Create src/main.lisp.
    makePath("src");
    {
        var buf: [256]u8 = undefined;
        const content = try std.fmt.bufPrint(&buf,
            \\(define (main)
            \\  (println "Hello from {s}!"))
            \\
            \\(main)
            \\
        , .{name});
        _ = writeFilePosix("src/main.lisp", content);
    }

    // Create modules/, lib/, and tests/.
    makePath("modules");
    makePath("lib");
    makePath("tests");

    var msg_buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf,
        \\Created zepo project: {s}
        \\  project.lisp
        \\  src/main.lisp
        \\  modules/
        \\  lib/
        \\  tests/
        \\
        \\Run: zepo run
        \\
    , .{name});
    writeStdout(msg);
}
