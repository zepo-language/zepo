const std = @import("std");
const zepo = @import("zepo");
const ProjectConfig = @import("project_config.zig").ProjectConfig;

pub fn runTest(ctx: *zepo.runtime.EvalContext, alloc: std.mem.Allocator, test_args: []const []const u8) !void {
    // Load project.lisp for module paths and test-dir (optional).
    var cfg_opt = ProjectConfig.loadOptional(alloc);
    defer if (cfg_opt) |*c| c.deinit();

    var path_buf: std.ArrayListUnmanaged([]const u8) = .{};
    var path_owned: usize = 0;
    defer {
        for (path_buf.items[0..path_owned]) |p| alloc.free(p);
        path_buf.deinit(alloc);
    }
    if (cfg_opt) |*cfg| {
        try cfg.applyModulePath(alloc, ctx.module_path, &path_buf);
        path_owned = path_buf.items.len -| ctx.module_path.len;
    } else {
        try path_buf.appendSlice(alloc, ctx.module_path);
    }
    ctx.module_path = path_buf.items;

    if (test_args.len > 0) {
        const passed = runFile(ctx, alloc, test_args[0]);
        std.process.exit(if (passed) 0 else 1);
    }

    const test_dir_name = if (cfg_opt) |*cfg| cfg.test_dir else "tests";

    // Project mode: discover <test-dir>/**/*_test.lisp
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (files.items) |f| alloc.free(f);
        files.deinit(alloc);
    }

    const stderr = std.fs.File.stderr();
    var tests_dir = std.fs.cwd().openDir(test_dir_name, .{ .iterate = true }) catch {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: no {s}/ directory found — run from project root\n", .{test_dir_name}) catch "error: tests dir not found\n";
        try stderr.writeAll(msg);
        std.process.exit(1);
    };
    defer tests_dir.close();

    try collectTests(alloc, tests_dir, test_dir_name, &files);

    if (files.items.len == 0) {
        const stdout = std.fs.File.stdout();
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "No test files found ({s}/**/*_test.lisp)\n", .{test_dir_name}) catch "No test files found\n";
        try stdout.writeAll(msg);
        return;
    }

    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var passed: usize = 0;
    var failed: usize = 0;
    for (files.items) |f| {
        if (runFile(ctx, alloc, f)) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    const stdout = std.fs.File.stdout();
    var buf: [128]u8 = undefined;
    const summary = try std.fmt.bufPrint(&buf, "\n{d} passed, {d} failed\n", .{ passed, failed });
    try stdout.writeAll(summary);

    if (failed > 0) std.process.exit(1);
}

fn runFile(ctx: *zepo.runtime.EvalContext, alloc: std.mem.Allocator, path: []const u8) bool {
    const stdout = std.fs.File.stdout();
    var buf: [512]u8 = undefined;

    const src = std.fs.cwd().readFileAlloc(alloc, path, 16 * 1024 * 1024) catch |e| {
        const msg = std.fmt.bufPrint(&buf, "FAIL  {s}  (cannot read: {})\n", .{ path, e }) catch "FAIL\n";
        stdout.writeAll(msg) catch {};
        return false;
    };
    defer alloc.free(src);

    _ = ctx.evalString(src, path) catch |e| {
        const msg = std.fmt.bufPrint(&buf, "FAIL  {s}  ({s})\n", .{ path, @errorName(e) }) catch "FAIL\n";
        stdout.writeAll(msg) catch {};
        ctx.printDiagnostic(std.fs.File.stderr(), e);
        return false;
    };

    const msg = std.fmt.bufPrint(&buf, "ok    {s}\n", .{path}) catch "ok\n";
    stdout.writeAll(msg) catch {};
    return true;
}

fn collectTests(alloc: std.mem.Allocator, dir: std.fs.Dir, prefix: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const full = try std.fs.path.join(alloc, &.{ prefix, entry.name });
        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.name, "_test.lisp")) {
                    try out.append(alloc, full);
                } else {
                    alloc.free(full);
                }
            },
            .directory => {
                var sub = try dir.openDir(entry.name, .{ .iterate = true });
                defer sub.close();
                try collectTests(alloc, sub, full, out);
                alloc.free(full);
            },
            else => alloc.free(full),
        }
    }
}
