const std = @import("std");
const zepo = @import("zepo");
const ProjectConfig = @import("project_config.zig").ProjectConfig;

// zepo-n3h
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

// zepo-qp1o: re-exec one child per file in discovery mode (full isolation).
extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;

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

const StderrWriter = struct {
    pub fn writeAll(_: StderrWriter, bytes: []const u8) error{}!void {
        _ = std.c.write(2, bytes.ptr, bytes.len);
    }
};

fn writeStdout(bytes: []const u8) void {
    _ = std.c.write(1, bytes.ptr, bytes.len);
}
fn writeStderr(bytes: []const u8) void {
    _ = std.c.write(2, bytes.ptr, bytes.len);
}

pub fn runTest(ctx: *zepo.runtime.EvalContext, alloc: std.mem.Allocator, self_path: []const u8, test_args: []const []const u8) !void {
    // Load project.lisp for module paths and test-dir (optional).
    var cfg_opt = ProjectConfig.loadOptional(alloc);
    defer if (cfg_opt) |*c| c.deinit();

    var path_buf: std.ArrayListUnmanaged([]const u8) = .empty;
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
    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (files.items) |f| alloc.free(f);
        files.deinit(alloc);
    }

    // zepo-n3h: verify test dir exists
    {
        var pbuf: [4096]u8 = undefined;
        const n = @min(test_dir_name.len, pbuf.len - 1);
        @memcpy(pbuf[0..n], test_dir_name[0..n]);
        pbuf[n] = 0;
        const d = std.c.opendir(@ptrCast(&pbuf)) orelse {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: no {s}/ directory found — run from project root\n", .{test_dir_name}) catch "error: tests dir not found\n";
            writeStderr(msg);
            std.process.exit(1);
        };
        _ = std.c.closedir(d);
    }

    try collectTests(alloc, test_dir_name, &files);

    if (files.items.len == 0) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "No test files found ({s}/**/*_test.lisp)\n", .{test_dir_name}) catch "No test files found\n";
        writeStdout(msg);
        return;
    }

    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    // zepo-qp1o: run each file in a FRESH child process (`<self> test <file>`).
    // Files used to share one EvalContext, so two files importing different test
    // modules (test vs testing) collided on overlapping export names, and the
    // frameworks' mutable *tests* registries leaked across files. A subprocess
    // gives each file a pristine interpreter — the only fully-correct isolation.
    var passed: usize = 0;
    var failed: usize = 0;
    for (files.items) |f| {
        if (runFileIsolated(alloc, self_path, f)) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    var buf: [128]u8 = undefined;
    const summary = std.fmt.bufPrint(&buf, "\n{d} passed, {d} failed\n", .{ passed, failed }) catch "\n?\n";
    writeStdout(summary);

    if (failed > 0) std.process.exit(1);
}

// zepo-qp1o: run one test file in a fresh child process: `<self> test <path>`.
// The child takes the single-file path in runTest (runs it in-process, then
// exits 0/1). Child stdout/stderr are inherited, so its PASS/FAIL/Summary lines
// stream through; the parent only needs the exit status. Env (ZEPO_PATH) and
// cwd are inherited across fork, so module resolution and relative paths work.
fn runFileIsolated(alloc: std.mem.Allocator, self_path: []const u8, path: []const u8) bool {
    const self_z = alloc.dupeZ(u8, self_path) catch return false;
    defer alloc.free(self_z);
    const test_z = alloc.dupeZ(u8, "test") catch return false;
    defer alloc.free(test_z);
    const path_z = alloc.dupeZ(u8, path) catch return false;
    defer alloc.free(path_z);

    var argv = [_]?[*:0]const u8{ self_z.ptr, test_z.ptr, path_z.ptr, null };
    const pid = fork();
    if (pid < 0) return false;
    if (pid == 0) {
        _ = execvp(self_z.ptr, @ptrCast(&argv));
        _exit(127); // execvp only returns on error
    }
    var status: c_int = 0;
    _ = waitpid(pid, &status, 0);
    // Normal exit with code 0 → file passed. (status & 0x7f) == 0 means exited
    // (not signalled); high byte holds the exit code.
    return (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;
}

fn runFile(ctx: *zepo.runtime.EvalContext, alloc: std.mem.Allocator, path: []const u8) bool {
    var buf: [512]u8 = undefined;

    // zepo-n3h
    const src = readFilePosix(alloc, path) orelse {
        const msg = std.fmt.bufPrint(&buf, "FAIL  {s}  (cannot read file)\n", .{path}) catch "FAIL\n";
        writeStdout(msg);
        return false;
    };
    defer alloc.free(src);

    _ = ctx.evalString(src, path) catch |e| {
        const msg = std.fmt.bufPrint(&buf, "FAIL  {s}  ({s})\n", .{ path, @errorName(e) }) catch "FAIL\n";
        writeStdout(msg);
        ctx.printDiagnostic(StderrWriter{}, e);
        return false;
    };

    const msg = std.fmt.bufPrint(&buf, "ok    {s}\n", .{path}) catch "ok\n";
    writeStdout(msg);
    return true;
}

// zepo-n3h: POSIX-based directory traversal
fn collectTests(alloc: std.mem.Allocator, prefix: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var pbuf: [4096]u8 = undefined;
    const n = @min(prefix.len, pbuf.len - 1);
    @memcpy(pbuf[0..n], prefix[0..n]);
    pbuf[n] = 0;
    const d = std.c.opendir(@ptrCast(&pbuf)) orelse return;
    defer _ = std.c.closedir(d);
    while (std.c.readdir(d)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.sliceTo(name_ptr, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const full = try std.fs.path.join(alloc, &.{ prefix, name });
        switch (entry.type) {
            std.c.DT.REG => {
                if (std.mem.endsWith(u8, name, "_test.lisp")) {
                    try out.append(alloc, full);
                } else {
                    alloc.free(full);
                }
            },
            std.c.DT.DIR => {
                try collectTests(alloc, full, out);
                alloc.free(full);
            },
            else => alloc.free(full),
        }
    }
}
