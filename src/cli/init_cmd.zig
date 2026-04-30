const std = @import("std");

pub fn runInit(alloc: std.mem.Allocator, extra_args: []const []const u8) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    // If a directory name was given, create it and work inside it.
    if (extra_args.len > 0) {
        const dir_name = extra_args[0];
        std.fs.cwd().makePath(dir_name) catch |e| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: cannot create directory '{s}': {s}\n", .{ dir_name, @errorName(e) }) catch "error: cannot create directory\n";
            try stderr.writeAll(msg);
            std.process.exit(1);
        };
        try std.posix.chdir(dir_name);
    }

    const cwd = std.fs.cwd();

    // Error if project.lisp already exists.
    if (cwd.access("project.lisp", .{})) |_| {
        try stderr.writeAll("error: project.lisp already exists — already a zepo project\n");
        std.process.exit(1);
    } else |_| {}

    // Infer project name from CWD.
    const cwd_path = try std.fs.realpathAlloc(alloc, ".");
    defer alloc.free(cwd_path);
    const name = std.fs.path.basename(cwd_path);

    // Write project.lisp.
    {
        const f = try cwd.createFile("project.lisp", .{ .truncate = true });
        defer f.close();
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
        try f.writeAll(content);
    }

    // Create src/main.lisp.
    try cwd.makePath("src");
    {
        const f = try cwd.createFile("src/main.lisp", .{ .truncate = true });
        defer f.close();
        var buf: [256]u8 = undefined;
        const content = try std.fmt.bufPrint(&buf,
            \\(define (main)
            \\  (println "Hello from {s}!"))
            \\
            \\(main)
            \\
        , .{name});
        try f.writeAll(content);
    }

    // Create modules/, lib/, and tests/.
    try cwd.makePath("modules");
    try cwd.makePath("lib");
    try cwd.makePath("tests");

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
    try stdout.writeAll(msg);
}
