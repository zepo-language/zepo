const std = @import("std");
const zepo = @import("zepo");

const build_cmd = @import("cli/build_cmd.zig");
const project_config = @import("cli/project_config.zig");
const fmt_cmd = @import("cli/fmt_cmd.zig");
const init_cmd = @import("cli/init_cmd.zig");
const install_cmd = @import("cli/install_cmd.zig");
const lint_cmd = @import("cli/lint_cmd.zig");
const lsp_cmd = @import("cli/lsp_cmd.zig");
const new_cmd = @import("cli/new_cmd.zig");
const repl_cmd = @import("cli/repl_cmd.zig");
const run_cmd = @import("cli/run_cmd.zig");
const test_cmd = @import("cli/test_cmd.zig");

const HELP =
    \\Usage: zepo [options] [file]
    \\       zepo init
    \\       zepo lsp
    \\       zepo new <type> [name]
    \\       zepo run [file.lisp]
    \\       zepo test [file.lisp]
    \\       zepo install <path>
    \\       zepo build <file.lisp> [-o outname]
    \\
    \\Options:
    \\  --repl             Start an interactive REPL
    \\  --max-regs=N       Set VM register pool ceiling (default: 4194304, ~660K recursion levels)
    \\  --help             Show this help message
    \\
    \\Commands:
    \\  fmt [file...]        Format source files in place (--check for CI)
    \\  init                 Scaffold a new project in the current directory
    \\  lint [file...]       Run diagnostics on source files
    \\  lsp                  Start the LSP server (stdio JSON-RPC)
    \\  new <type> [name]    Generate a component (module, lib, test, package)
    \\  run [file.lisp]      Run a file or the project entry point
    \\  test [file.lisp]     Run a test file or discover tests/**/*_test.lisp
    \\  install <path>       Install a package to ~/.local/lib/zepo/
    \\  build <file.lisp>    Compile to a standalone native binary
    \\    -o <name>          Output binary name (default: input stem)
    \\
    \\Arguments:
    \\  file          Path to a .lisp file to evaluate
    \\
    \\If no arguments are given, this help is shown.
    \\
;

// zepo-op7: macOS main thread is capped at ~8MB stack, which limits zepo
// recursion depth to ~5–8K non-tail frames. Run the real logic on a worker
// thread with a large stack so user programs can recurse freely.
// zepo-8e6: Zig 0.16 removed std.process.argsAlloc; main now accepts
// std.process.Init.Minimal so the runtime hands us the argv slice directly.
var g_argv: std.process.Args.Vector = &.{};

pub fn main(init: std.process.Init.Minimal) !void {
    g_argv = init.args.vector;
    var result: anyerror!void = {};
    const t = try std.Thread.spawn(
        .{ .stack_size = 1024 * 1024 * 1024 },
        workerMain,
        .{&result},
    );
    t.join();
    return result;
}

fn workerMain(out: *anyerror!void) void {
    out.* = realMain();
}

fn collectArgs(alloc: std.mem.Allocator) ![]const []const u8 {
    var list = std.ArrayListUnmanaged([]const u8).empty;
    for (g_argv) |a| try list.append(alloc, std.mem.sliceTo(a, 0));
    return list.toOwnedSlice(alloc);
}

// Minimal stderr writer for printDiagnostic (anytype).
const StderrWriter = struct {
    pub fn writeAll(_: *const StderrWriter, data: []const u8) !void {
        _ = std.c.write(2, data.ptr, data.len);
    }
};

fn realMain() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try collectArgs(alloc);
    defer alloc.free(args);

    if (args.len < 2) {
        _ = std.c.write(1, HELP.ptr, HELP.len);
        return;
    }

    const arg = args[1];

    // zepo-cvh: parse --max-regs=N before the command/script
    var user_max_regs: ?usize = null;
    const cmd_start: usize = if (std.mem.startsWith(u8, arg, "--max-regs=")) blk: {
        user_max_regs = std.fmt.parseInt(usize, arg["--max-regs=".len..], 10) catch null;
        break :blk 2;
    } else 1;

    if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
        _ = std.c.write(1, HELP.ptr, HELP.len);
        return;
    }

    if (std.mem.eql(u8, arg, "fmt")) {
        try fmt_cmd.runFmt(alloc, args[2..]);
        return;
    }

    if (std.mem.eql(u8, arg, "init")) {
        try init_cmd.runInit(alloc, args[2..]);
        return;
    }

    if (std.mem.eql(u8, arg, "lint")) {
        try lint_cmd.runLint(alloc, args[2..]);
        return;
    }

    if (std.mem.eql(u8, arg, "lsp")) {
        try lsp_cmd.runLsp(alloc);
        return;
    }

    if (std.mem.eql(u8, arg, "new")) {
        try new_cmd.runNew(alloc, args[2..]);
        return;
    }

    if (std.mem.eql(u8, arg, "install")) {
        if (args.len < 3) {
            _ = std.c.write(2, "error: install requires a path argument\n", 40);
            std.process.exit(1);
        }
        try install_cmd.runInstall(alloc, args[2]);
        return;
    }

    if (std.mem.eql(u8, arg, "build")) {
        if (args.len < 3) {
            // No file arg: look for project.lisp and use entry + project name.
            var cfg = project_config.ProjectConfig.loadOptional(alloc) orelse {
                _ = std.c.write(2, "error: build requires a .lisp file (or run from a project directory with project.lisp)\n", 87);
                std.process.exit(1);
            };
            defer cfg.deinit();
            const synthetic = try alloc.dupe([]const u8, &.{ cfg.entry, "-o", cfg.name });
            defer alloc.free(synthetic);
            try build_cmd.runBuild(alloc, synthetic);
        } else {
            try build_cmd.runBuild(alloc, args[2..]);
        }
        return;
    }

    // Build interpreter.
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
    if (user_max_regs) |n| ctx.vm_max_regs = n;
    try zepo.runtime.loadStdlib(&ctx);

    // *program-mode* — #t when running as a script, #f when loaded into the REPL.
    // Default #f; run/file dispatch sets it to #t below.
    {
        const sym = try syms.intern("*program-mode*");
        try globals.define(sym, zepo.abi.value.FALSE);
    }

    // Build module search path: exe/../lib, then ZEPO_PATH entries.
    var path_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (path_dirs.items) |d| alloc.free(d);
        path_dirs.deinit(alloc);
    }
    // zepo-n3h: selfExePathAlloc removed in Zig 0.16; exe-relative lib path skipped.
    // ~/.local/lib/zepo/ + packages listed in packages.lisp manifest
    const installed_start = path_dirs.items.len;
    try project_config.appendGlobalPaths(alloc, &path_dirs);
    const installed_end = path_dirs.items.len;
    ctx.lib_path = path_dirs.items[installed_start..installed_end];
    // package_path: just the base ~/.local/lib/zepo/ (first entry added by appendGlobalPaths)
    ctx.package_path = if (installed_end > installed_start) path_dirs.items[installed_start .. installed_start + 1] else &.{};
    // ZEPO_PATH — override/extra paths (colon-separated)
    if (std.c.getenv("ZEPO_PATH")) |raw| {
        const env = std.mem.span(raw);
        var it = std.mem.splitScalar(u8, env, ':');
        while (it.next()) |dir| {
            if (dir.len > 0) try path_dirs.append(alloc, try alloc.dupe(u8, dir));
        }
    }
    ctx.module_path = path_dirs.items;

    if (cmd_start >= args.len) {
        _ = std.c.write(2, "error: --max-regs requires a script or command\n", 47);
        std.process.exit(1);
    }
    const interp_arg = args[cmd_start];
    if (std.mem.eql(u8, interp_arg, "--repl")) {
        // argv for preloaded files: [file, extra-args...]  (no "zepo --repl" prefix)
        zepo.prims.io.program_argv = args[cmd_start + 1 ..];
        try repl_cmd.runRepl(&ctx, alloc, args[cmd_start + 1 ..]);
    } else if (std.mem.eql(u8, interp_arg, "run")) {
        zepo.prims.io.program_argv = args[cmd_start + 1 ..];
        setProgramMode(&syms, &globals);
        try run_cmd.runRun(&ctx, alloc, args[cmd_start + 1 ..]);
    } else if (std.mem.eql(u8, interp_arg, "test")) {
        zepo.prims.io.program_argv = args[cmd_start + 1 ..];
        try test_cmd.runTest(&ctx, alloc, args[cmd_start + 1 ..]);
    } else {
        // Direct file: zepo script.lisp arg1 arg2
        zepo.prims.io.program_argv = args[cmd_start..];
        setProgramMode(&syms, &globals);
        try runFile(&ctx, alloc, interp_arg);
    }
}

fn setProgramMode(syms: *zepo.runtime.SymbolTable, globals: *zepo.runtime.GlobalEnv) void {
    const sym = syms.intern("*program-mode*") catch return;
    globals.set(sym, zepo.abi.value.TRUE) catch {};
}

// zepo-8e6: Zig 0.16 removed std.Io.Dir; read file via POSIX fopen/fread.
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

fn runFile(ctx: *zepo.runtime.EvalContext, alloc: std.mem.Allocator, path: []const u8) !void {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const f = std.c.fopen(@ptrCast(&pbuf), "rb") orelse {
        std.debug.print("error: cannot read '{s}': file not found\n", .{path});
        std.process.exit(1);
    };
    defer _ = std.c.fclose(f);
    _ = fseek(f, 0, 2); // SEEK_END
    const size: usize = @intCast(ftell(f));
    _ = fseek(f, 0, 0); // SEEK_SET
    const src = alloc.alloc(u8, size) catch {
        std.debug.print("error: out of memory reading '{s}'\n", .{path});
        std.process.exit(1);
    };
    defer alloc.free(src);
    _ = std.c.fread(src.ptr, 1, size, f);
    const sw = StderrWriter{};
    _ = ctx.evalString(src, path) catch |e| {
        ctx.printDiagnostic(&sw, e);
        std.process.exit(1);
    };
}
