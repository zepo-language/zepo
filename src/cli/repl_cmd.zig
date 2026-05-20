const std = @import("std");
const zepo = @import("zepo");
const readline = @import("readline.zig");
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

fn writeStdout(bytes: []const u8) void {
    _ = std.c.write(1, bytes.ptr, bytes.len);
}

fn completeSymbol(
    prefix: []const u8,
    ctx_ptr: ?*anyopaque,
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]u8),
) void {
    const ctx: *zepo.runtime.EvalContext = @ptrCast(@alignCast(ctx_ptr orelse return));
    const env = ctx.currentEnv();
    for (env.entries.items) |entry| {
        const sym = entry.sym_slot.*;
        if (!zepo.runtime.objects.isSymbol(sym)) continue;
        const name = zepo.runtime.objects.symbolName(sym);
        if (std.mem.startsWith(u8, name, prefix)) {
            const copy = alloc.dupe(u8, name) catch continue;
            out.append(alloc, copy) catch {
                alloc.free(copy);
                return;
            };
        }
    }
}

pub fn runRepl(ctx: *zepo.runtime.EvalContext, alloc: std.mem.Allocator, preload: []const []const u8) !void {
    // Apply project.lisp module paths if present.
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

    // Pre-load any files passed on the command line.
    for (preload) |path| {
        // zepo-n3h
        const src = readFilePosix(alloc, path) orelse {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "error: cannot read '{s}'\n", .{path}) catch "error: cannot read file\n";
            writeStdout(msg);
            continue;
        };
        defer alloc.free(src);
        _ = ctx.evalString(src, path) catch |e| {
            ctx.printDiagnostic(StderrWriter{}, e);
        };
    }

    // History file: ~/.zepo_history
    const hist_path: ?[]const u8 = blk: {
        const home = std.mem.span(std.c.getenv("HOME") orelse break :blk null);
        break :blk std.fs.path.join(alloc, &.{ home, ".zepo_history" }) catch null;
    };
    defer if (hist_path) |p| alloc.free(p);

    var history = readline.History.init(alloc, hist_path);
    defer history.deinit();
    history.load();

    var input = std.ArrayListUnmanaged(u8).empty;
    defer input.deinit(alloc);

    var depth: i32 = 0;

    // zepo-n3h
    {
        const msg = "Zepo REPL  (Ctrl-D to exit, Ctrl-C to cancel)\n";
        writeStdout(msg);
    }

    while (true) {
        const prompt = if (depth == 0) "> " else "  ";
        const line = readline.readLine(alloc, prompt, &history, ctx, completeSymbol) catch |e| switch (e) {
            error.Interrupted => {
                input.clearRetainingCapacity();
                depth = 0;
                writeStdout("\n");
                continue;
            },
            else => return e,
        } orelse break;
        defer alloc.free(line);

        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), ".quit")) break;

        try history.add(line);

        try input.appendSlice(alloc, line);
        try input.append(alloc, '\n');

        // Track paren depth to detect complete expressions.
        var in_str = false;
        for (line) |c| {
            if (c == '"') in_str = !in_str;
            if (!in_str) {
                if (c == '(') depth += 1;
                if (c == ')') depth -= 1;
            }
        }

        if (depth <= 0 and input.items.len > 0) {
            depth = 0;
            const trimmed = std.mem.trim(u8, input.items, " \t\r\n");
            if (trimmed.len == 0) {
                input.clearRetainingCapacity();
                continue;
            }
            const result = ctx.evalString(input.items, "<repl>") catch |e| {
                ctx.printDiagnostic(StderrWriter{}, e);
                input.clearRetainingCapacity();
                continue;
            };
            var buf = std.ArrayListUnmanaged(u8).empty;
            defer buf.deinit(alloc);
            zepo.prims.io.displayValue(&buf, alloc, result) catch {};
            try buf.append(alloc, '\n');
            writeStdout(buf.items);
            input.clearRetainingCapacity();
        }
    }

    history.save();
    // zepo-n3h
    writeStdout("\nBye.\n");
}
