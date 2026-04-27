const std = @import("std");
const zepo = @import("zepo");
const readline = @import("readline.zig");

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

pub fn runRepl(ctx: *zepo.runtime.EvalContext, alloc: std.mem.Allocator) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    // History file: ~/.zepo_history
    const hist_path: ?[]const u8 = if (std.process.getEnvVarOwned(alloc, "HOME")) |home|
        std.fs.path.join(alloc, &.{ home, ".zepo_history" }) catch null
    else |_|
        null;
    defer if (hist_path) |p| alloc.free(p);

    var history = readline.History.init(alloc, hist_path);
    defer history.deinit();
    history.load();

    var input = std.ArrayListUnmanaged(u8){};
    defer input.deinit(alloc);

    var depth: i32 = 0;

    try stdout.writeAll("Zepo REPL  (Ctrl-D to exit, Ctrl-C to cancel)\n");

    while (true) {
        const prompt = if (depth == 0) "> " else "  ";
        const line = readline.readLine(alloc, prompt, &history, ctx, completeSymbol) catch |e| switch (e) {
            error.Interrupted => {
                input.clearRetainingCapacity();
                depth = 0;
                try stdout.writeAll("\n");
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
                var msg_buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "error: {}\n", .{e}) catch "error\n";
                try stderr.writeAll(msg);
                input.clearRetainingCapacity();
                continue;
            };
            var buf = std.ArrayListUnmanaged(u8){};
            defer buf.deinit(alloc);
            zepo.prims.io.displayValue(&buf, alloc, result) catch {};
            try buf.append(alloc, '\n');
            try stdout.writeAll(buf.items);
            input.clearRetainingCapacity();
        }
    }

    history.save();
    try stdout.writeAll("\nBye.\n");
}
