// Parses project.lisp for project metadata.
// Format:
//   (project
//     (name "myapp")
//     (version "0.1.0")
//     (entry "src/main.lisp")
//     (paths "lib" "vendor")
//     (test-dir "tests"))

const std = @import("std");

pub const ProjectConfig = struct {
    name: []const u8,
    version: []const u8,
    entry: []const u8,
    paths: []const []const u8,
    test_dir: []const u8,
    _arena: std.heap.ArenaAllocator,

    pub fn deinit(cfg: *ProjectConfig) void {
        cfg._arena.deinit();
    }

    /// Load project.lisp from CWD. Returns null silently if not found.
    pub fn loadOptional(alloc: std.mem.Allocator) ?ProjectConfig {
        const src = std.fs.cwd().readFileAlloc(alloc, "project.lisp", 64 * 1024) catch return null;
        defer alloc.free(src);
        return parse(alloc, src);
    }

    /// Load and parse project.lisp from CWD.
    /// Returns null (with error written to stderr) if not found or malformed.
    pub fn load(alloc: std.mem.Allocator) ?ProjectConfig {
        const stderr = std.fs.File.stderr();
        const src = std.fs.cwd().readFileAlloc(alloc, "project.lisp", 64 * 1024) catch {
            stderr.writeAll("error: no project.lisp found — run 'zepo init' first\n") catch {};
            return null;
        };
        defer alloc.free(src);
        return parse(alloc, src);
    }

    fn parse(alloc: std.mem.Allocator, src: []const u8) ProjectConfig {
        var arena = std.heap.ArenaAllocator.init(alloc);
        const a = arena.allocator();

        const name = extractString(src, "(name \"") orelse "unknown";
        const version = extractString(src, "(version \"") orelse "0.0.0";
        const entry = extractString(src, "(entry \"") orelse "src/main.lisp";
        const test_dir = extractString(src, "(test-dir \"") orelse "tests";

        const paths = extractPaths(a, src, "(paths") orelse
            (a.dupe([]const u8, &[_][]const u8{ "modules", "lib" }) catch &[_][]const u8{});

        return .{
            .name = a.dupe(u8, name) catch name,
            .version = a.dupe(u8, version) catch version,
            .entry = a.dupe(u8, entry) catch entry,
            .paths = paths,
            .test_dir = a.dupe(u8, test_dir) catch test_dir,
            ._arena = arena,
        };
    }

    /// Resolve cfg.paths to absolute paths (relative to CWD) and prepend to
    /// ctx.module_path. The returned slice is owned by `path_buf` which the
    /// caller must deinit.
    pub fn applyModulePath(
        cfg: *const ProjectConfig,
        alloc: std.mem.Allocator,
        existing: []const []const u8,
        path_buf: *std.ArrayListUnmanaged([]const u8),
    ) !void {
        const cwd = std.fs.cwd().realpathAlloc(alloc, ".") catch null;
        defer if (cwd) |p| alloc.free(p);

        for (cfg.paths) |rel| {
            const abs = if (cwd) |base|
                std.fs.path.join(alloc, &.{ base, rel }) catch continue
            else
                alloc.dupe(u8, rel) catch continue;
            try path_buf.append(alloc, abs);
        }
        try path_buf.appendSlice(alloc, existing);
    }
};

fn extractString(src: []const u8, marker: []const u8) ?[]const u8 {
    const start_idx = std.mem.indexOf(u8, src, marker) orelse return null;
    const val_start = start_idx + marker.len;
    const val_end = std.mem.indexOfScalarPos(u8, src, val_start, '"') orelse return null;
    return src[val_start..val_end];
}

/// Read ~/.local/lib/zepo/packages.lisp and append the base dir plus each
/// listed package directory to `dirs`. Silent on missing manifest.
pub fn appendGlobalPaths(alloc: std.mem.Allocator, dirs: *std.ArrayListUnmanaged([]const u8)) !void {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return;
    defer alloc.free(home);
    const base = std.fs.path.join(alloc, &.{ home, ".local", "lib", "zepo" }) catch return;
    try dirs.append(alloc, base);
    const manifest_path = std.fs.path.join(alloc, &.{ base, "packages.lisp" }) catch return;
    defer alloc.free(manifest_path);
    const src = std.fs.cwd().readFileAlloc(alloc, manifest_path, 64 * 1024) catch return;
    defer alloc.free(src);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const pkgs = extractPaths(arena.allocator(), src, "(paths") orelse return;
    for (pkgs) |pkg| {
        const abs = std.fs.path.join(alloc, &.{ base, pkg }) catch continue;
        try dirs.append(alloc, abs);
    }
}

/// Register a package name in ~/.local/lib/zepo/packages.lisp.
/// Creates the manifest if it doesn't exist; skips if already listed.
pub fn registerGlobalPackage(alloc: std.mem.Allocator, pkg_name: []const u8) !void {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return;
    defer alloc.free(home);
    const base = std.fs.path.join(alloc, &.{ home, ".local", "lib", "zepo" }) catch return;
    defer alloc.free(base);
    const manifest_path = std.fs.path.join(alloc, &.{ base, "packages.lisp" }) catch return;
    defer alloc.free(manifest_path);
    const existing = std.fs.cwd().readFileAlloc(alloc, manifest_path, 64 * 1024) catch "";
    defer if (existing.len > 0) alloc.free(existing);
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const current = extractPaths(arena.allocator(), existing, "(paths") orelse &[_][]const u8{};
    for (current) |p| {
        if (std.mem.eql(u8, p, pkg_name)) return;
    }
    var out = std.ArrayList(u8){};
    defer out.deinit(alloc);
    try out.appendSlice(alloc, "(paths");
    for (current) |p| {
        try out.appendSlice(alloc, " \"");
        try out.appendSlice(alloc, p);
        try out.append(alloc, '"');
    }
    try out.appendSlice(alloc, " \"");
    try out.appendSlice(alloc, pkg_name);
    try out.appendSlice(alloc, "\")\n");
    const f = try std.fs.cwd().createFile(manifest_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(out.items);
}

fn extractPaths(alloc: std.mem.Allocator, src: []const u8, marker: []const u8) ?[][]const u8 {
    const start_idx = std.mem.indexOf(u8, src, marker) orelse return null;
    // Find the closing ')' of this form.
    const end_idx = std.mem.indexOfScalarPos(u8, src, start_idx, ')') orelse return null;
    const form = src[start_idx..end_idx];

    var list: std.ArrayListUnmanaged([]const u8) = .{};
    var i: usize = 0;
    while (i < form.len) {
        const q = std.mem.indexOfScalarPos(u8, form, i, '"') orelse break;
        const close = std.mem.indexOfScalarPos(u8, form, q + 1, '"') orelse break;
        const s = alloc.dupe(u8, form[q + 1 .. close]) catch break;
        list.append(alloc, s) catch break;
        i = close + 1;
    }
    if (list.items.len == 0) return null;
    return list.toOwnedSlice(alloc) catch null;
}
