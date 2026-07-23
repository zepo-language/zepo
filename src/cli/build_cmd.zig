// zepo-n3h: Zig 0.16 removed std.Io.Dir/File and std.time.milliTimestamp;
// all I/O uses POSIX C functions, temp dir uses getpid() for uniqueness.
const std = @import("std");
const zepo = @import("zepo");
const main_opts = @import("main_opts");
const project_config = @import("project_config.zig");
const ProjectConfig = project_config.ProjectConfig;

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;
// zepo-imna: process spawning goes through fork+execvp, never a shell, so a
// metacharacter in any argument (an attacker-controlled output name or path)
// is inert. This replaces the previous `system()` shell calls.
extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;

// zepo-imna: fork + execvp a command with NO shell. argv is passed to execvp
// verbatim, so shell metacharacters in any argument are never interpreted.
// Optionally chdir into `cwd` first. Returns the child's exit code, or -1 if
// fork/waitpid failed.
fn execSync(argv: [*:null]const ?[*:0]const u8, cwd: ?[*:0]const u8) c_int {
    const pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        if (cwd) |dir| {
            if (chdir(dir) != 0) std.process.exit(127);
        }
        _ = execvp(argv[0].?, argv);
        std.process.exit(127); // execvp only returns on failure
    }
    var status: c_int = 0;
    if (waitpid(pid, &status, 0) < 0) return -1;
    return (status >> 8) & 0xff;
}

fn writeMsg(fd: c_int, s: []const u8) void {
    _ = std.c.write(fd, s.ptr, s.len);
}

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

fn deleteTree(path: []const u8) void {
    var buf: [4096]u8 = undefined;
    // zepo-imna: `path` is a single argv element to `rm`, never a shell word.
    const path_z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    const argv = [_:null]?[*:0]const u8{ "rm", "-rf", path_z };
    _ = execSync(&argv, null);
}

// build.zig written into the temp dir. Placeholders: {s}=src_dir, {s}=binary_name.
// zepo-g3k: stdlib.lisp is copied into the temp dir so @embedFile works at build time.
pub const BUILD_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {{
    \\    const target = b.standardTargetOptions(.{{}});
    \\    const optimize = b.standardOptimizeOption(.{{}});
    \\    const lib_opts = b.addOptions();
    \\    const stdlib_src: []const u8 = @embedFile("stdlib.lisp");
    \\    lib_opts.addOption([]const u8, "stdlib_src", stdlib_src);
    \\    const zepo_mod = b.addModule("zepo", .{{
    \\        .root_source_file = .{{ .cwd_relative = "{s}/src/root.zig" }},
    \\        .target = target,
    \\    }});
    \\    zepo_mod.addOptions("lib_opts", lib_opts);
    \\    const exe = b.addExecutable(.{{
    \\        .name = "{s}",
    \\        .root_module = b.createModule(.{{
    \\            .root_source_file = b.path("standalone_main.zig"),
    \\            .target = target,
    \\            .optimize = optimize,
    \\            .imports = &.{{.{{ .name = "zepo", .module = zepo_mod }}}},
    \\        }}),
    \\    }});
    \\    b.installArtifact(exe);
    \\}}
    \\
;

pub fn appendInstalledPaths(alloc: std.mem.Allocator, dirs: *std.ArrayListUnmanaged([]const u8), src_dir: []const u8) !void {
    try project_config.appendGlobalPaths(alloc, dirs);
    if (std.fs.path.join(alloc, &.{ src_dir, "lib" })) |p|
        try dirs.append(alloc, p)
    else |_| {}
}

pub fn setupModulePath(alloc: std.mem.Allocator, dirs: *std.ArrayListUnmanaged([]const u8), src_dir: []const u8) !void {
    try appendInstalledPaths(alloc, dirs, src_dir);
    if (std.c.getenv("ZEPO_PATH")) |raw| {
        const zpath = std.mem.span(raw);
        var it = std.mem.splitScalar(u8, zpath, ':');
        while (it.next()) |seg|
            if (seg.len > 0) try dirs.append(alloc, try alloc.dupe(u8, seg));
    }
}

pub fn setupInstalledPaths(
    alloc: std.mem.Allocator,
    ctx: *zepo.runtime.EvalContext,
    src_dir: []const u8,
    installed_dirs: *std.ArrayListUnmanaged([]const u8),
) !void {
    const base_len = installed_dirs.items.len;
    try appendInstalledPaths(alloc, installed_dirs, src_dir);
    ctx.lib_path = installed_dirs.items[base_len..];
    if (std.c.getenv("HOME")) |raw| {
        const home = std.mem.span(raw);
        if (std.fs.path.join(alloc, &.{ home, ".local", "lib", "zepo" })) |p|
            try installed_dirs.append(alloc, p)
        else |_| {}
        ctx.package_path = installed_dirs.items[installed_dirs.items.len - 1 ..];
    }
}

pub fn runBuild(alloc: std.mem.Allocator, args: []const []const u8) !void {
    const input_path = args[0];
    var out_name: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o") and i + 1 < args.len) {
            i += 1;
            out_name = args[i];
        }
    }
    const output_path = out_name orelse std.fs.path.stem(input_path);
    const binary_name = std.fs.path.basename(output_path);
    const src_dir = main_opts.zepo_src_dir;

    // ── Discovery pass ────────────────────────────────────────────────────────
    var module_log = std.StringHashMap([]const u8).init(alloc);
    var module_order: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        var kit = module_log.keyIterator();
        while (kit.next()) |k| alloc.free(k.*);
        var vit = module_log.valueIterator();
        while (vit.next()) |v| alloc.free(v.*);
        module_log.deinit();
        module_order.deinit(alloc);
    }
    {
        var gc = try zepo.GC.init(alloc);
        defer gc.deinit();
        var syms = try zepo.runtime.SymbolTable.init(&gc, alloc);
        defer syms.deinit();
        var globals = try zepo.runtime.GlobalEnv.init(&gc, alloc);
        defer globals.deinit();
        try zepo.prims.registerAll(&gc, &globals, &syms);
        var ctx = try zepo.runtime.EvalContext.init(&gc, &syms, &globals, alloc);
        defer ctx.deinit();
        ctx.installRootVisitor();
        try zepo.runtime.loadStdlib(&ctx);
        var installed_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (installed_dirs.items) |d| alloc.free(d); installed_dirs.deinit(alloc); }
        try setupInstalledPaths(alloc, &ctx, src_dir, &installed_dirs);

        var path_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
        defer { for (path_dirs.items) |d| alloc.free(d); path_dirs.deinit(alloc); }
        try setupModulePath(alloc, &path_dirs, src_dir);
        var cfg_opt = ProjectConfig.loadOptional(alloc);
        defer if (cfg_opt) |*c| c.deinit();
        var proj_path_buf: std.ArrayListUnmanaged([]const u8) = .empty;
        var proj_path_owned: usize = 0;
        defer {
            for (proj_path_buf.items[0..proj_path_owned]) |p| alloc.free(p);
            proj_path_buf.deinit(alloc);
        }
        if (cfg_opt) |*cfg| {
            try cfg.applyModulePath(alloc, path_dirs.items, &proj_path_buf);
            proj_path_owned = proj_path_buf.items.len -| path_dirs.items.len;
            ctx.module_path = proj_path_buf.items;
        } else {
            ctx.module_path = path_dirs.items;
        }
        ctx.module_file_log = &module_log;
        ctx.module_file_order = &module_order;
        ctx.discovery_mode = true;
        const prog_src = readFilePosix(alloc, input_path) orelse {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: cannot read '{s}'\n", .{input_path}) catch "error: cannot read input\n";
            writeMsg(2, msg);
            std.process.exit(1);
        };
        defer alloc.free(prog_src);
        _ = ctx.evalString(prog_src, input_path) catch {};
    }

    // ── Temp dir ──────────────────────────────────────────────────────────────
    const pid = std.c.getpid();
    const tmp_path = try std.fmt.allocPrint(alloc, "/tmp/zepo-build-{d}", .{pid});
    defer alloc.free(tmp_path);
    deleteTree(tmp_path);
    makePath(tmp_path);

    // Write user program.
    const prog_src2 = readFilePosix(alloc, input_path) orelse {
        writeMsg(2, "error: cannot read input\n");
        std.process.exit(1);
    };
    defer alloc.free(prog_src2);
    {
        const p = try std.fmt.allocPrint(alloc, "{s}/program.lisp", .{tmp_path});
        defer alloc.free(p);
        _ = writeFilePosix(p, prog_src2);
    }

    // ── Generate standalone_main.zig ──────────────────────────────────────────
    var runner: std.ArrayListUnmanaged(u8) = .empty;
    defer runner.deinit(alloc);

    try runner.appendSlice(alloc,
        \\const std = @import("std");
        \\const zepo = @import("zepo");
        \\const PROGRAM = @embedFile("program.lisp");
        \\
    );

    var mod_idx: usize = 0;
    var mod_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer mod_names.deinit(alloc);
    for (module_order.items) |mod_name| {
        const file_path = module_log.get(mod_name) orelse continue;
        const rel = try std.fmt.allocPrint(alloc, "lib/{s}.lisp", .{mod_name});
        defer alloc.free(rel);
        // makePath for parent directory
        if (std.fs.path.dirname(rel)) |par| {
            const full_par = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ tmp_path, par });
            defer alloc.free(full_par);
            makePath(full_par);
        }
        const fsrc = readFilePosix(alloc, file_path) orelse continue;
        defer alloc.free(fsrc);
        const full_rel = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ tmp_path, rel });
        defer alloc.free(full_rel);
        _ = writeFilePosix(full_rel, fsrc);
        var ebuf: [256]u8 = undefined;
        const embed_line = std.fmt.bufPrint(&ebuf, "const MODULE_{d} = @embedFile(\"{s}\");\n", .{ mod_idx, rel }) catch continue;
        try runner.appendSlice(alloc, embed_line);
        try mod_names.append(alloc, mod_name);
        mod_idx += 1;
    }

    try runner.appendSlice(alloc,
        \\pub fn main() !void {
        \\    var result: anyerror!void = {};
        \\    const t = try std.Thread.spawn(
        \\        .{ .stack_size = 1024 * 1024 * 1024 },
        \\        workerMain,
        \\        .{&result},
        \\    );
        \\    t.join();
        \\    return result;
        \\}
        \\fn workerMain(out: *anyerror!void) void {
        \\    out.* = realMain();
        \\}
        \\fn realMain() !void {
        \\    var gpa: std.heap.DebugAllocator(.{}) = .{};
        \\    defer _ = gpa.deinit();
        \\    const alloc = gpa.allocator();
        \\    var gc = try zepo.GC.init(alloc);
        \\    defer gc.deinit();
        \\    var syms = try zepo.runtime.SymbolTable.init(&gc, alloc);
        \\    defer syms.deinit();
        \\    var globals = try zepo.runtime.GlobalEnv.init(&gc, alloc);
        \\    defer globals.deinit();
        \\    try zepo.prims.registerAll(&gc, &globals, &syms);
        \\    var ctx = try zepo.runtime.EvalContext.init(&gc, &syms, &globals, alloc);
        \\    defer ctx.deinit();
        \\    ctx.installRootVisitor();
        \\    try zepo.runtime.loadStdlib(&ctx);
        \\
    );
    for (mod_names.items, 0..) |mod_name, j| {
        var lbuf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&lbuf,
            "    if (ctx.evalString(MODULE_{d}, \"{s}\")) |_| {{}} else |_| {{}};\n",
            .{ j, mod_name }) catch continue;
        try runner.appendSlice(alloc, line);
    }
    try runner.appendSlice(alloc,
        \\    if (ctx.evalString(PROGRAM, "<program>")) |_| {} else |_| {
        \\        std.process.exit(1);
        \\    }
        \\}
        \\
    );
    {
        const p = try std.fmt.allocPrint(alloc, "{s}/standalone_main.zig", .{tmp_path});
        defer alloc.free(p);
        _ = writeFilePosix(p, runner.items);
    }

    // ── Write build.zig ───────────────────────────────────────────────────────
    // zepo-g3k: copy stdlib.lisp into temp dir so @embedFile("stdlib.lisp") resolves.
    {
        const stdlib_src_path = try std.fmt.allocPrint(alloc, "{s}/lib/stdlib.lisp", .{src_dir});
        defer alloc.free(stdlib_src_path);
        const stdlib_dst_path = try std.fmt.allocPrint(alloc, "{s}/stdlib.lisp", .{tmp_path});
        defer alloc.free(stdlib_dst_path);
        const stdlib_data = readFilePosix(alloc, stdlib_src_path) orelse {
            writeMsg(2, "error: cannot read stdlib.lisp\n");
            std.process.exit(1);
        };
        defer alloc.free(stdlib_data);
        _ = writeFilePosix(stdlib_dst_path, stdlib_data);
    }
    const build_zig_src = try std.fmt.allocPrint(alloc, BUILD_ZIG_TEMPLATE, .{ src_dir, binary_name });
    defer alloc.free(build_zig_src);
    {
        const p = try std.fmt.allocPrint(alloc, "{s}/build.zig", .{tmp_path});
        defer alloc.free(p);
        _ = writeFilePosix(p, build_zig_src);
    }

    // ── Run zig build ─────────────────────────────────────────────────────────
    const out_prefix = try std.fmt.allocPrint(alloc, "{s}/out", .{tmp_path});
    defer alloc.free(out_prefix);
    // zepo-imna: run `zig build` via argv exec with cwd = the temp dir, instead
    // of a `cd {s} && zig build -p {s}` shell string. No shell means the
    // interpolated paths can never inject a command.
    var op_buf: [4096]u8 = undefined;
    const out_prefix_z = std.fmt.bufPrintZ(&op_buf, "{s}", .{out_prefix}) catch return error.NoSpaceLeft;
    var tp_buf: [4096]u8 = undefined;
    const tmp_path_z = std.fmt.bufPrintZ(&tp_buf, "{s}", .{tmp_path}) catch return error.NoSpaceLeft;
    const zig_argv = [_:null]?[*:0]const u8{ "zig", "build", "-p", out_prefix_z, "-Doptimize=ReleaseFast" };
    const exit_code = execSync(&zig_argv, tmp_path_z);
    if (exit_code != 0) {
        writeMsg(2, "error: zig build failed\n");
        std.process.exit(1);
    }

    // ── Copy binary ───────────────────────────────────────────────────────────
    const built_bin = try std.fmt.allocPrint(alloc, "{s}/bin/{s}", .{ out_prefix, binary_name });
    defer alloc.free(built_bin);
    const bin_data = readFilePosix(alloc, built_bin) orelse {
        writeMsg(2, "error: binary not found after build\n");
        std.process.exit(1);
    };
    defer alloc.free(bin_data);
    if (!writeFilePosix(output_path, bin_data)) {
        writeMsg(2, "error: cannot write output binary\n");
        std.process.exit(1);
    }
    // chmod +x — zepo-imna: direct chmod(2), not `system("chmod +x " ++ name)`.
    // output_path comes from `-o` or project.lisp's name, so a value like
    // `x; rm -rf ~` must never reach a shell.
    var chbuf: [4096]u8 = undefined;
    const output_path_z = std.fmt.bufPrintZ(&chbuf, "{s}", .{output_path}) catch return error.NoSpaceLeft;
    if (std.c.chmod(output_path_z, @as(std.c.mode_t, 0o755)) != 0) {
        writeMsg(2, "warning: could not set +x on output binary\n");
    }
    deleteTree(tmp_path);

    var mbuf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&mbuf, "built: {s}\n", .{output_path}) catch "built.\n";
    writeMsg(1, msg);
}
