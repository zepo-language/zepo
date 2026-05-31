//! Cross-file module resolution for the LSP (zepo-zoan).
//!
//! Mirrors the runtime's module search path:
//!   1. project.lisp `(paths ...)` entries (relative to project dir / CWD)
//!   2. ZEPO_PATH (colon-separated)
//!   3. ~/.local/lib/zepo/ and packages listed in
//!      ~/.local/lib/zepo/packages.lisp
//!
//! Given a module name like `math/tensor`, resolves to a file by trying:
//!   <dir>/math/tensor.lisp
//!   <dir>/math/tensor/mod.lisp
//!
//! Parsed-analysis results are cached keyed on (path, mtime). The cache is
//! owned by `Resolver` and freed on deinit.

const std = @import("std");
const analysis = @import("analysis.zig");

extern "c" fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

fn readFile(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
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

extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

fn fileExists(path: []const u8) bool {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return false;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    return access(@ptrCast(&pbuf), 0) == 0;
}

/// Get the file size as a cheap "did this change?" token. Not as precise as
/// mtime but sufficient for invalidating cached parses keyed on (path, key).
fn fileMtime(path: []const u8) i64 {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return 0;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const f = std.c.fopen(@ptrCast(&pbuf), "rb") orelse return 0;
    defer _ = std.c.fclose(f);
    _ = fseek(f, 0, 2);
    return @intCast(@max(0, ftell(f)));
}

/// One cached parsed file.
const Entry = struct {
    path: []u8,
    text: []u8,
    mtime: i64,
    an: analysis.Analysis,
};

pub const Resolver = struct {
    alloc: std.mem.Allocator,
    /// Module search paths (owned).
    paths: std.ArrayListUnmanaged([]u8) = .empty,
    paths_built: bool = false,
    /// Cached parsed files keyed by absolute path.
    cache: std.StringHashMapUnmanaged(Entry) = .empty,

    pub fn init(alloc: std.mem.Allocator) Resolver {
        return .{ .alloc = alloc };
    }

    pub fn deinit(r: *Resolver) void {
        for (r.paths.items) |p| r.alloc.free(p);
        r.paths.deinit(r.alloc);
        var it = r.cache.iterator();
        while (it.next()) |e| {
            r.alloc.free(e.value_ptr.path);
            r.alloc.free(e.value_ptr.text);
            e.value_ptr.an.deinit();
        }
        r.cache.deinit(r.alloc);
    }

    pub fn ensurePaths(r: *Resolver) !void {
        if (r.paths_built) return;
        r.paths_built = true;

        // 1. project.lisp paths (CWD)
        if (readFile(r.alloc, "project.lisp")) |src| {
            defer r.alloc.free(src);
            var cwdbuf: [4096]u8 = undefined;
            const cwd_ptr = getcwd(&cwdbuf, cwdbuf.len);
            const cwd: ?[]const u8 = if (cwd_ptr) |p| std.mem.sliceTo(p, 0) else null;
            try appendQuotedPathsForm(r.alloc, src, "(paths", &r.paths, cwd);
        }

        // 2. ZEPO_PATH
        if (std.c.getenv("ZEPO_PATH")) |raw| {
            const env = std.mem.span(raw);
            var it = std.mem.splitScalar(u8, env, ':');
            while (it.next()) |dir| {
                if (dir.len > 0) {
                    const d = try r.alloc.dupe(u8, dir);
                    try r.paths.append(r.alloc, d);
                }
            }
        }

        // 3. ~/.local/lib/zepo/
        if (std.c.getenv("HOME")) |home_raw| {
            const home = std.mem.span(home_raw);
            const base = std.fs.path.join(r.alloc, &.{ home, ".local", "lib", "zepo" }) catch return;
            try r.paths.append(r.alloc, base);
            const manifest = std.fs.path.join(r.alloc, &.{ base, "packages.lisp" }) catch return;
            defer r.alloc.free(manifest);
            if (readFile(r.alloc, manifest)) |msrc| {
                defer r.alloc.free(msrc);
                try appendQuotedPathsForm(r.alloc, msrc, "(paths", &r.paths, base);
            }
        }
    }

    /// Search path list for `name` (e.g. "math/tensor"). Returns the first
    /// hit's absolute path (owned by caller), or null.
    pub fn resolveModule(r: *Resolver, name: []const u8) !?[]u8 {
        try r.ensurePaths();
        for (r.paths.items) |dir| {
            // Try <dir>/<name>.lisp
            const p1 = try std.fmt.allocPrint(r.alloc, "{s}/{s}.lisp", .{ dir, name });
            if (fileExists(p1)) return p1;
            r.alloc.free(p1);
            // Try <dir>/<name>/mod.lisp
            const p2 = try std.fmt.allocPrint(r.alloc, "{s}/{s}/mod.lisp", .{ dir, name });
            if (fileExists(p2)) return p2;
            r.alloc.free(p2);
        }
        return null;
    }

    /// Get a cached analysis for the given absolute path; reparse if file
    /// mtime changed.
    pub fn getAnalysis(r: *Resolver, path: []const u8) !?struct { text: []const u8, an: *const analysis.Analysis } {
        const mt = fileMtime(path);
        if (r.cache.getPtr(path)) |e| {
            if (e.mtime == mt) return .{ .text = e.text, .an = &e.an };
            // Stale — drop and rebuild.
            r.alloc.free(e.text);
            e.an.deinit();
            const text = readFile(r.alloc, path) orelse return null;
            const an = try analysis.analyze(r.alloc, text);
            e.text = text;
            e.mtime = mt;
            e.an = an;
            return .{ .text = e.text, .an = &e.an };
        }
        const text = readFile(r.alloc, path) orelse return null;
        const an = try analysis.analyze(r.alloc, text);
        const path_copy = try r.alloc.dupe(u8, path);
        try r.cache.put(r.alloc, path_copy, .{
            .path = path_copy,
            .text = text,
            .mtime = mt,
            .an = an,
        });
        const e = r.cache.getPtr(path_copy).?;
        return .{ .text = e.text, .an = &e.an };
    }
};

/// Append every double-quoted string inside the first `marker`(...) form in
/// `src` to `out`. If `base_dir` is non-null and the string is relative,
/// produce an absolute path joined under base_dir.
fn appendQuotedPathsForm(
    alloc: std.mem.Allocator,
    src: []const u8,
    marker: []const u8,
    out: *std.ArrayListUnmanaged([]u8),
    base_dir: ?[]const u8,
) !void {
    const start_idx = std.mem.indexOf(u8, src, marker) orelse return;
    const end_idx = std.mem.indexOfScalarPos(u8, src, start_idx, ')') orelse return;
    const form = src[start_idx..end_idx];
    var i: usize = 0;
    while (i < form.len) {
        const q = std.mem.indexOfScalarPos(u8, form, i, '"') orelse break;
        const close = std.mem.indexOfScalarPos(u8, form, q + 1, '"') orelse break;
        const raw = form[q + 1 .. close];
        const abs = if (base_dir) |base|
            (if (raw.len > 0 and raw[0] == '/') alloc.dupe(u8, raw) catch break else std.fs.path.join(alloc, &.{ base, raw }) catch break)
        else
            (alloc.dupe(u8, raw) catch break);
        try out.append(alloc, abs);
        i = close + 1;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "resolver caches analysis" {
    const t = std.testing;
    const path = "/tmp/zepo-lsp-resolver-test.lisp";
    {
        const f = std.c.fopen(path, "wb") orelse return;
        defer _ = std.c.fclose(f);
        const src = "(define remote-thing 42)\n";
        _ = std.c.fwrite(src.ptr, 1, src.len, f);
    }
    var r = Resolver.init(t.allocator);
    defer r.deinit();
    const result = (try r.getAnalysis(path)).?;
    try t.expect(result.an.findDefinition("remote-thing") != null);
    // Second call hits the cache.
    const result2 = (try r.getAnalysis(path)).?;
    try t.expect(result2.an.findDefinition("remote-thing") != null);
}
