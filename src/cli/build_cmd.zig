const std = @import("std");
const zepo = @import("zepo");
const main_opts = @import("main_opts");
const project_config = @import("project_config.zig");
const ProjectConfig = project_config.ProjectConfig;

// build.zig written into the temp dir. Placeholders: {s}=src_dir, {s}=src_dir, {s}=binary_name.
pub const BUILD_ZIG_TEMPLATE =
    \\const std = @import("std");
    \\pub fn build(b: *std.Build) void {{
    \\    const target = b.standardTargetOptions(.{{}});
    \\    const optimize = b.standardOptimizeOption(.{{}});
    \\    const lib_opts = b.addOptions();
    \\    const stdlib_src = std.fs.cwd().readFileAlloc(
    \\        b.allocator, "{s}/lib/stdlib.lisp", 1 << 20,
    \\    ) catch @panic("stdlib.lisp not found");
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

pub fn setupModulePath(alloc: std.mem.Allocator, dirs: *std.ArrayListUnmanaged([]const u8), src_dir: []const u8) !void {
    if (std.fs.selfExePathAlloc(alloc)) |exe| {
        defer alloc.free(exe);
        if (std.fs.path.dirname(exe)) |exe_dir| {
            if (std.fs.path.join(alloc, &.{ exe_dir, "../../lib" })) |p|
                try dirs.append(alloc, p)
            else |_| {}
        }
    } else |_| {}
    // ~/.local/lib/zepo/ + packages listed in packages.lisp manifest
    try project_config.appendGlobalPaths(alloc, dirs);
    // During development: project lib/ is next to src_dir
    if (std.fs.path.join(alloc, &.{ src_dir, "lib" })) |p|
        try dirs.append(alloc, p)
    else |_| {}
    if (std.process.getEnvVarOwned(alloc, "ZEPO_PATH")) |zpath| {
        defer alloc.free(zpath);
        var it = std.mem.splitScalar(u8, zpath, ':');
        while (it.next()) |seg|
            if (seg.len > 0) try dirs.append(alloc, try alloc.dupe(u8, seg));
    } else |_| {}
}

pub fn runBuild(alloc: std.mem.Allocator, args: []const []const u8) !void {
    const stderr = std.fs.File.stderr();

    // Parse args: <input.lisp> [-o outname]
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

    // ── Discovery pass ───────────────────────────────────────────────────────
    // Run the program once to find which module files it loads from disk.
    var module_log = std.StringHashMap([]const u8).init(alloc);
    var module_order: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        var kit = module_log.keyIterator();
        while (kit.next()) |k| alloc.free(k.*);
        var vit = module_log.valueIterator();
        while (vit.next()) |v| alloc.free(v.*);
        module_log.deinit();
        module_order.deinit(alloc); // keys are owned by module_log, not freed here
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
        try zepo.runtime.loadStdlib(&ctx);
        var path_dirs: std.ArrayListUnmanaged([]const u8) = .{};
        defer { for (path_dirs.items) |d| alloc.free(d); path_dirs.deinit(alloc); }
        try setupModulePath(alloc, &path_dirs, src_dir);
        // Prepend project.lisp paths so project modules take precedence.
        var cfg_opt = ProjectConfig.loadOptional(alloc);
        defer if (cfg_opt) |*c| c.deinit();
        var proj_path_buf: std.ArrayListUnmanaged([]const u8) = .{};
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
        const prog_src = std.fs.cwd().readFileAlloc(alloc, input_path, 16 * 1024 * 1024) catch |e| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: cannot read '{s}': {}\n", .{ input_path, e }) catch "error\n";
            try stderr.writeAll(msg);
            std.process.exit(1);
        };
        defer alloc.free(prog_src);
        _ = ctx.evalString(prog_src, input_path) catch |e| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "warning: discovery pass stopped early ({}); bundled modules may be incomplete\n", .{e}) catch "warning: discovery pass stopped early\n";
            stderr.writeAll(msg) catch {};
        };
    }

    // ── Temp dir setup ────────────────────────────────────────────────────────
    const ts = std.time.milliTimestamp();
    const tmp_path = try std.fmt.allocPrint(alloc, "/tmp/zepo-build-{d}", .{ts});
    defer alloc.free(tmp_path);
    std.fs.cwd().deleteTree(tmp_path) catch {};
    try std.fs.cwd().makePath(tmp_path);
    var tmp_dir = try std.fs.cwd().openDir(tmp_path, .{});
    defer tmp_dir.close();

    // Write user program.
    const prog_src2 = try std.fs.cwd().readFileAlloc(alloc, input_path, 16 * 1024 * 1024);
    defer alloc.free(prog_src2);
    try tmp_dir.writeFile(.{ .sub_path = "program.lisp", .data = prog_src2 });

    // ── Generate standalone_main.zig ─────────────────────────────────────────
    var runner = std.ArrayList(u8){};
    defer runner.deinit(alloc);
    const w = runner.writer(alloc);

    try w.writeAll(
        \\const std = @import("std");
        \\const zepo = @import("zepo");
        \\const PROGRAM = @embedFile("program.lisp");
        \\
    );

    // Embed each bundled module and copy its file into temp/lib/
    var mod_idx: usize = 0;
    for (module_order.items) |mod_name| {
        const file_path = module_log.get(mod_name) orelse continue;
        const rel = try std.fmt.allocPrint(alloc, "lib/{s}.lisp", .{mod_name});
        defer alloc.free(rel);
        if (std.fs.path.dirname(rel)) |par| tmp_dir.makePath(par) catch {};
        const fsrc = std.fs.cwd().readFileAlloc(alloc, file_path, 4 * 1024 * 1024) catch continue;
        defer alloc.free(fsrc);
        tmp_dir.writeFile(.{ .sub_path = rel, .data = fsrc }) catch continue;
        try w.print("const MODULE_{d} = @embedFile(\"{s}\");\n", .{ mod_idx, rel });
        mod_idx += 1;
    }

    try w.writeAll(
        \\pub fn main() !void {
        \\    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
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
        \\    try zepo.runtime.loadStdlib(&ctx);
        \\
    );
    for (0..mod_idx) |j| {
        try w.print("    _ = ctx.evalString(MODULE_{d}, \"<module>\") catch {{}};\n", .{j});
    }
    try w.writeAll(
        \\    _ = ctx.evalString(PROGRAM, "<program>") catch |e| {
        \\        const se = std.fs.File.stderr();
        \\        var buf: [256]u8 = undefined;
        \\        const msg = std.fmt.bufPrint(&buf, "error: {}\n", .{e}) catch "error\n";
        \\        se.writeAll(msg) catch {};
        \\        std.process.exit(1);
        \\    };
        \\}
        \\
    );
    try tmp_dir.writeFile(.{ .sub_path = "standalone_main.zig", .data = runner.items });

    // ── Write build.zig ───────────────────────────────────────────────────────
    const build_zig_src = try std.fmt.allocPrint(alloc, BUILD_ZIG_TEMPLATE, .{ src_dir, src_dir, binary_name });
    defer alloc.free(build_zig_src);
    try tmp_dir.writeFile(.{ .sub_path = "build.zig", .data = build_zig_src });

    // ── Run zig build ─────────────────────────────────────────────────────────
    const out_prefix = try std.fs.path.join(alloc, &.{ tmp_path, "out" });
    defer alloc.free(out_prefix);
    var child = std.process.Child.init(&.{ "zig", "build", "-p", out_prefix }, alloc);
    child.cwd = tmp_path;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: failed to run zig: {}\n", .{e}) catch "error\n";
        try stderr.writeAll(msg);
        std.process.exit(1);
    };
    if (term != .Exited or term.Exited != 0) {
        try stderr.writeAll("error: zig build failed\n");
        std.process.exit(1);
    }

    // ── Copy binary ───────────────────────────────────────────────────────────
    const built_bin = try std.fs.path.join(alloc, &.{ out_prefix, "bin", binary_name });
    defer alloc.free(built_bin);
    std.fs.cwd().copyFile(built_bin, std.fs.cwd(), output_path, .{}) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: cannot copy binary: {}\n", .{e}) catch "error\n";
        try stderr.writeAll(msg);
        std.process.exit(1);
    };
    std.fs.cwd().deleteTree(tmp_path) catch {};

    const stdout = std.fs.File.stdout();
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "built: {s}\n", .{output_path}) catch "built.\n";
    try stdout.writeAll(msg);
}
