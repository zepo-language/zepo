const std = @import("std");
const zepo = @import("zepo");
const ProjectConfig = @import("project_config.zig").ProjectConfig;

pub fn runRun(ctx: *zepo.runtime.EvalContext, alloc: std.mem.Allocator, run_args: []const []const u8) !void {
    // Load project.lisp if present (optional — not required when running a file directly).
    var cfg_opt = ProjectConfig.loadOptional(alloc);
    defer if (cfg_opt) |*c| c.deinit();

    // Build module search path: project paths first, then existing (exe-relative, ZEPO_PATH).
    var path_buf: std.ArrayListUnmanaged([]const u8) = .{};
    var path_owned: usize = 0; // number of abs paths we allocated at the front
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

    // Determine file to run.
    const file: []const u8 = if (run_args.len > 0)
        run_args[0]
    else if (cfg_opt) |*cfg|
        cfg.entry
    else {
        const stderr = std.fs.File.stderr();
        try stderr.writeAll("error: no project.lisp found — pass a file: zepo run file.lisp\n");
        std.process.exit(1);
    };

    const src = std.fs.cwd().readFileAlloc(alloc, file, 16 * 1024 * 1024) catch |e| {
        std.debug.print("error: cannot read '{s}': {}\n", .{ file, e });
        std.process.exit(1);
    };
    defer alloc.free(src);

    _ = ctx.evalString(src, file) catch |e| {
        ctx.printDiagnostic(std.fs.File.stderr(), e);
        std.process.exit(1);
    };
}
