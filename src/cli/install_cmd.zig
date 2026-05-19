const std = @import("std");
const zepo = @import("zepo");
const project_config = @import("project_config.zig");
const build_cmd = @import("build_cmd.zig");
const cg_serialize = zepo.cg.serialize;

pub fn runInstall(alloc: std.mem.Allocator, pkg_path: []const u8) !void {
    const stderr = std.Io.File.stderr();
    const stdout = std.Io.File.stdout();

    const pkg_name = std.fs.path.basename(pkg_path);
    if (pkg_name.len == 0) {
        try stderr.writeAll("error: invalid package path\n");
        std.process.exit(1);
    }

    const home = std.mem.span(std.c.getenv("HOME") orelse {
        try stderr.writeAll("error: HOME not set\n");
        std.process.exit(1);
    });

    const dest_base = try std.fs.path.join(alloc, &.{ home, ".local/lib/zepo" });
    defer alloc.free(dest_base);
    const dest = try std.fs.path.join(alloc, &.{ dest_base, pkg_name });
    defer alloc.free(dest);

    std.Io.Dir.cwd().makePath(dest_base) catch {};
    std.Io.Dir.cwd().deleteTree(dest) catch {};
    try std.Io.Dir.cwd().makePath(dest);

    var src_dir = std.Io.Dir.cwd().openDir(pkg_path, .{ .iterate = true }) catch |e| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "error: cannot open '{s}': {}\n", .{ pkg_path, e }) catch "error: cannot open source\n";
        try stderr.writeAll(msg);
        std.process.exit(1);
    };
    defer src_dir.close();

    var dest_dir = try std.Io.Dir.cwd().openDir(dest, .{});
    defer dest_dir.close();

    // Copy source tree first.
    try copyDirAll(alloc, src_dir, dest_dir);

    // Detect structure: package (has src/main.lisp) or lib (<name>.lisp at root).
    const has_src_main = blk: {
        const check = std.fs.path.join(alloc, &.{ dest, "src", "main.lisp" }) catch break :blk false;
        defer alloc.free(check);
        std.Io.Dir.cwd().access(check, .{}) catch break :blk false;
        break :blk true;
    };
    const has_lib_file = blk: {
        const lib_name = try std.fmt.allocPrint(alloc, "{s}.lisp", .{pkg_name});
        defer alloc.free(lib_name);
        const check = std.fs.path.join(alloc, &.{ dest, lib_name }) catch break :blk false;
        defer alloc.free(check);
        std.Io.Dir.cwd().access(check, .{}) catch break :blk false;
        break :blk true;
    };

    // Compile the appropriate subtree.
    var compiled: usize = 0;
    var failed: usize = 0;
    if (has_src_main) {
        // Package structure: compile src/ only.
        const src_compile_path = std.fs.path.join(alloc, &.{ dest, "src" }) catch dest;
        defer if (src_compile_path.ptr != dest.ptr) alloc.free(src_compile_path);
        var src_compile_dir = std.Io.Dir.cwd().openDir(src_compile_path, .{ .iterate = true }) catch dest_dir;
        defer if (src_compile_dir.fd != dest_dir.fd) src_compile_dir.close();
        compileTree(alloc, src_compile_path, src_compile_dir, &compiled, &failed);
    } else if (has_lib_file) {
        // Lib structure: compile root .lisp files only.
        compileTree(alloc, dest, dest_dir, &compiled, &failed);
    } else {
        // Unknown structure: compile everything.
        compileTree(alloc, dest, dest_dir, &compiled, &failed);
    }

    project_config.registerGlobalPackage(alloc, pkg_name) catch {};

    const kind_str: []const u8 = if (has_src_main) "package" else "lib";
    var msg_buf: [512]u8 = undefined;
    const msg = try std.fmt.bufPrint(&msg_buf,
        "installed {s} '{s}' → {s}\n  {d} file(s) compiled, {d} skipped\n",
        .{ kind_str, pkg_name, dest, compiled, failed },
    );
    try stdout.writeAll(msg);
}

/// Walk dest_dir and compile every .lisp to a sibling .zbc.
fn compileTree(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    dir: std.fs.Dir,
    compiled: *usize,
    failed: *usize,
) void {
    var it = dir.iterate();
    while (it.next() catch return) |entry| {
        switch (entry.kind) {
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".lisp")) continue;
                if (std.mem.eql(u8, entry.name, "package.lisp")) continue;
                const lisp_path = std.fs.path.join(alloc, &.{ dir_path, entry.name }) catch continue;
                defer alloc.free(lisp_path);
                const stem = entry.name[0 .. entry.name.len - ".lisp".len];
                const zbc_name = std.fmt.allocPrint(alloc, "{s}.zbc", .{stem}) catch continue;
                defer alloc.free(zbc_name);
                const zbc_path = std.fs.path.join(alloc, &.{ dir_path, zbc_name }) catch continue;
                defer alloc.free(zbc_path);
                if (compileLibFile(alloc, lisp_path, zbc_path)) {
                    compiled.* += 1;
                } else |_| {
                    failed.* += 1;
                }
            },
            .directory => {
                const sub_path = std.fs.path.join(alloc, &.{ dir_path, entry.name }) catch continue;
                defer alloc.free(sub_path);
                var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer sub_dir.close();
                compileTree(alloc, sub_path, sub_dir, compiled, failed);
            },
            else => {},
        }
    }
}

/// Compile one .lisp file to a .zbc file.
fn compileLibFile(alloc: std.mem.Allocator, lisp_path: []const u8, zbc_path: []const u8) !void {
    const src = try std.Io.Dir.cwd().readFileAlloc(alloc, lisp_path, 4 * 1024 * 1024);
    defer alloc.free(src);

    // Build a fresh interpreter context.
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

    // Set up module search path (installed libs + ZEPO_PATH).
    var path_dirs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer { for (path_dirs.items) |d| alloc.free(d); path_dirs.deinit(alloc); }
    try build_cmd.setupModulePath(alloc, &path_dirs, @import("main_opts").zepo_src_dir);
    ctx.module_path = path_dirs.items;

    // Record the fn_id base before evaluating.
    const fn_base: u32 = @intCast(ctx.compiled.items.len);

    // Track top-level thunk fn_ids.
    var toplevel_ids: std.ArrayListUnmanaged(u32) = .empty;
    defer toplevel_ids.deinit(alloc);
    ctx.toplevel_fn_ids = &toplevel_ids;

    // Evaluate the library source.
    _ = try ctx.evalString(src, lisp_path);

    // Collect only the fns produced by this library.
    const lib_fns = ctx.compiled.items[fn_base..];

    // Adjust stored fn_ids to be 0-based within this library for portability.
    // The serializer writes them relative to zero; the loader adds base_offset.
    const adjusted = try alloc.alloc(zepo.cg.CompiledFn, lib_fns.len);
    defer alloc.free(adjusted);
    @memcpy(adjusted, lib_fns);
    for (adjusted, 0..) |*f, i| f.id = @intCast(i);

    // Adjust MAKE_CLOSURE operands to be relative to fn_base = 0.
    for (adjusted) |*f| {
        const BC_MAKE_CLOSURE = @intFromEnum(zepo.cg.Opcode.MAKE_CLOSURE);
        for (f.code) |*ins| {
            const op_byte = ins.* & 0xFF;
            if (op_byte == BC_MAKE_CLOSURE) {
                const a = zepo.cg.bytecode.decodeA(ins.*);
                const bc_val = zepo.cg.bytecode.decodeBC(ins.*);
                if (bc_val >= fn_base and bc_val < fn_base + lib_fns.len) {
                    ins.* = zepo.cg.bytecode.encodeBC(.MAKE_CLOSURE, a, @intCast(bc_val - fn_base));
                }
            }
        }
    }

    // Adjust toplevel_ids to be relative to zero.
    var rel_toplevel = try alloc.alloc(u32, toplevel_ids.items.len);
    defer alloc.free(rel_toplevel);
    for (toplevel_ids.items, 0..) |id, i| {
        rel_toplevel[i] = id - fn_base;
    }

    // Capture module name and exports from the registry (at most one module per file).
    var module_name: []const u8 = "";
    var exports: std.ArrayListUnmanaged([]const u8) = .empty;
    defer exports.deinit(alloc);
    var reg_it = ctx.registry.table.iterator();
    if (reg_it.next()) |entry| {
        module_name = entry.key_ptr.*;
        var ex_it = entry.value_ptr.*.exports.keyIterator();
        while (ex_it.next()) |k| try exports.append(alloc, k.*);
    }

    // Write .zbc file: serialize into a buffer then write atomically.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try cg_serialize.write(buf.writer(alloc), adjusted, rel_toplevel, module_name, exports.items);
    try std.Io.Dir.cwd().writeFile(.{ .sub_path = zbc_path, .data = buf.items });
}

fn copyDirAll(alloc: std.mem.Allocator, src: std.fs.Dir, dest: std.fs.Dir) !void {
    var it = src.iterate();
    while (try it.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const data = try src.readFileAlloc(alloc, entry.name, 16 * 1024 * 1024);
                defer alloc.free(data);
                const f = try dest.createFile(entry.name, .{ .truncate = true });
                defer f.close();
                try f.writeAll(data);
            },
            .directory => {
                dest.makeDir(entry.name) catch {};
                var sub_src = try src.openDir(entry.name, .{ .iterate = true });
                defer sub_src.close();
                var sub_dest = try dest.openDir(entry.name, .{});
                defer sub_dest.close();
                try copyDirAll(alloc, sub_src, sub_dest);
            },
            else => {},
        }
    }
}
