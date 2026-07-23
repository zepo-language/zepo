const std = @import("std");
const zepo = @import("zepo");
const ProjectConfig = @import("project_config.zig").ProjectConfig;

// zepo-n3h
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

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

pub fn runRun(ctx: *zepo.runtime.EvalContext, alloc: std.mem.Allocator, run_args: []const []const u8) !void {
    // Load project.lisp if present (optional — not required when running a file directly).
    var cfg_opt = ProjectConfig.loadOptional(alloc);
    defer if (cfg_opt) |*c| c.deinit();

    // Build module search path: project paths first, then existing (exe-relative, ZEPO_PATH).
    var path_buf: std.ArrayListUnmanaged([]const u8) = .empty;
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
        // zepo-n3h
        const msg = "error: no project.lisp found — pass a file: zepo run file.lisp\n";
        _ = std.c.write(2, msg, msg.len);
        std.process.exit(1);
    };

    // zepo-n3h
    const src = readFilePosix(alloc, file) orelse {
        std.debug.print("error: cannot read '{s}'\n", .{file});
        std.process.exit(1);
    };
    defer alloc.free(src);

    _ = ctx.evalString(src, file) catch |e| {
        // zepo-n3h
        ctx.printDiagnostic(StderrWriter{}, e);
        std.process.exit(1);
    };
    // zepo-nwaw: give fibers spawned but never scheduled a turn to run, then
    // exit non-zero if any died from an unhandled condition (the scheduler
    // already printed its diagnostic).
    if (ctx.vm) |*vm| {
        vm.drainFibers() catch {};
        if (vm.unhandled_fiber_error) std.process.exit(1);
    }
}
