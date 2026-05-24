//! Tests for src/cli/project_config.zig.
//! Exercises the parsing logic by writing temp project.lisp files and
//! calling ProjectConfig.load / loadOptional from that directory.

// zepo-ue2

const std = @import("std");
const Io = std.Io;
const project_config = @import("project_config");
const ProjectConfig = project_config.ProjectConfig;

/// Write `content` as "project.lisp" inside `dir`.
fn writeProjectLisp(dir: Io.Dir, content: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = "project.lisp", .data = content });
}

/// Save and restore the process CWD around `func`.  Uses `fchdir` on the
/// open dir fd — avoids string-path construction and is atomic on POSIX.
fn withDir(dir: Io.Dir, comptime func: fn (std.mem.Allocator) anyerror!void, alloc: std.mem.Allocator) !void {
    // Open CWD by fd so we can restore it later.
    const saved_fd = std.c.open(".", .{ .DIRECTORY = true }, @as(std.c.mode_t, 0));
    if (saved_fd < 0) return error.OpenCwdFailed;
    defer _ = std.c.close(saved_fd);
    // Change to the target dir.
    if (std.c.fchdir(dir.handle) != 0) return error.FchdirFailed;
    defer _ = std.c.fchdir(saved_fd); // restore; ignore error in defer
    try func(alloc);
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "project_config: parse full project.lisp" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeProjectLisp(tmp.dir,
        \\(project
        \\  (name "myapp")
        \\  (version "1.2.3")
        \\  (entry "src/main.lisp")
        \\  (paths "lib" "modules")
        \\  (test-dir "tests"))
    );

    try withDir(tmp.dir, struct {
        fn run(alloc: std.mem.Allocator) anyerror!void {
            var cfg = ProjectConfig.load(alloc) orelse return error.ConfigNotLoaded;
            defer cfg.deinit();
            try std.testing.expectEqualStrings("myapp", cfg.name);
            try std.testing.expectEqualStrings("1.2.3", cfg.version);
            try std.testing.expectEqualStrings("src/main.lisp", cfg.entry);
            try std.testing.expectEqualStrings("tests", cfg.test_dir);
            try std.testing.expectEqual(@as(usize, 2), cfg.paths.len);
        }
    }.run, std.testing.allocator);
}

test "project_config: missing optional fields use defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeProjectLisp(tmp.dir, "(project (name \"minimal\"))");

    try withDir(tmp.dir, struct {
        fn run(alloc: std.mem.Allocator) anyerror!void {
            var cfg = ProjectConfig.load(alloc) orelse return error.ConfigNotLoaded;
            defer cfg.deinit();
            try std.testing.expectEqualStrings("minimal", cfg.name);
            try std.testing.expectEqualStrings("0.0.0", cfg.version);
            try std.testing.expectEqualStrings("src/main.lisp", cfg.entry);
            try std.testing.expectEqualStrings("tests", cfg.test_dir);
        }
    }.run, std.testing.allocator);
}

test "project_config: loadOptional returns null when no project.lisp" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Do not write project.lisp — directory is empty.

    try withDir(tmp.dir, struct {
        fn run(alloc: std.mem.Allocator) anyerror!void {
            const result = ProjectConfig.loadOptional(alloc);
            try std.testing.expect(result == null);
        }
    }.run, std.testing.allocator);
}

test "project_config: single-path paths field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeProjectLisp(tmp.dir,
        \\(project (name "sp") (paths "src"))
    );

    try withDir(tmp.dir, struct {
        fn run(alloc: std.mem.Allocator) anyerror!void {
            var cfg = ProjectConfig.load(alloc) orelse return error.ConfigNotLoaded;
            defer cfg.deinit();
            try std.testing.expectEqual(@as(usize, 1), cfg.paths.len);
            try std.testing.expectEqualStrings("src", cfg.paths[0]);
        }
    }.run, std.testing.allocator);
}

test "project_config: no paths field uses default two paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeProjectLisp(tmp.dir,
        \\(project (name "nopaths") (version "0.1.0"))
    );

    try withDir(tmp.dir, struct {
        fn run(alloc: std.mem.Allocator) anyerror!void {
            var cfg = ProjectConfig.load(alloc) orelse return error.ConfigNotLoaded;
            defer cfg.deinit();
            // Default paths: ["modules", "lib"].
            try std.testing.expectEqual(@as(usize, 2), cfg.paths.len);
        }
    }.run, std.testing.allocator);
}
