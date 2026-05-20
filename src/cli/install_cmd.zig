const std = @import("std");
const zepo = @import("zepo");
const project_config = @import("project_config.zig");
const build_cmd = @import("build_cmd.zig");
const cg_serialize = zepo.cg.serialize;

// zepo-n3h
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn system(cmd: [*:0]const u8) c_int;
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

fn accessExists(path: []const u8) bool {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return false;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    return std.c.access(@ptrCast(&pbuf), 0) == 0;
}

fn writeStdout(bytes: []const u8) void {
    _ = std.c.write(1, bytes.ptr, bytes.len);
}
fn writeStderr(bytes: []const u8) void {
    _ = std.c.write(2, bytes.ptr, bytes.len);
}

pub fn runInstall(alloc: std.mem.Allocator, pkg_path: []const u8) !void {
    const pkg_name = std.fs.path.basename(pkg_path);
    if (pkg_name.len == 0) {
        writeStderr("error: invalid package path\n");
        std.process.exit(1);
    }

    const home = std.mem.span(std.c.getenv("HOME") orelse {
        writeStderr("error: HOME not set\n");
        std.process.exit(1);
    });

    const dest_base = try std.fs.path.join(alloc, &.{ home, ".local/lib/zepo" });
    defer alloc.free(dest_base);
    const dest = try std.fs.path.join(alloc, &.{ dest_base, pkg_name });
    defer alloc.free(dest);

    // zepo-n3h: delete dest tree via shell, then recreate
    makePath(dest_base);
    {
        var shell_buf: [8192]u8 = undefined;
        const cmd = std.fmt.bufPrint(&shell_buf, "rm -rf {s}", .{dest}) catch "";
        if (cmd.len > 0 and cmd.len < shell_buf.len) {
            shell_buf[cmd.len] = 0;
            _ = system(@ptrCast(&shell_buf));
        }
    }
    makePath(dest);

    // Copy source tree first.
    try copyDirPosix(alloc, pkg_path, dest);

    // Detect structure: package (has src/main.lisp) or lib (<name>.lisp at root).
    const has_src_main = blk: {
        const check = std.fs.path.join(alloc, &.{ dest, "src", "main.lisp" }) catch break :blk false;
        defer alloc.free(check);
        break :blk accessExists(check);
    };
    const has_lib_file = blk: {
        const lib_name = try std.fmt.allocPrint(alloc, "{s}.lisp", .{pkg_name});
        defer alloc.free(lib_name);
        const check = std.fs.path.join(alloc, &.{ dest, lib_name }) catch break :blk false;
        defer alloc.free(check);
        break :blk accessExists(check);
    };

    // Compile the appropriate subtree.
    var compiled: usize = 0;
    var failed: usize = 0;
    if (has_src_main) {
        const src_compile_path = std.fs.path.join(alloc, &.{ dest, "src" }) catch dest;
        defer if (src_compile_path.ptr != dest.ptr) alloc.free(src_compile_path);
        compileTree(alloc, src_compile_path, &compiled, &failed);
    } else if (has_lib_file) {
        compileTree(alloc, dest, &compiled, &failed);
    } else {
        compileTree(alloc, dest, &compiled, &failed);
    }

    project_config.registerGlobalPackage(alloc, pkg_name) catch {};

    const kind_str: []const u8 = if (has_src_main) "package" else "lib";
    var msg_buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf,
        "installed {s} '{s}' → {s}\n  {d} file(s) compiled, {d} skipped\n",
        .{ kind_str, pkg_name, dest, compiled, failed },
    ) catch "installed\n";
    writeStdout(msg);
}

/// Walk dir_path and compile every .lisp to a sibling .zbc.
fn compileTree(
    alloc: std.mem.Allocator,
    dir_path: []const u8,
    compiled: *usize,
    failed: *usize,
) void {
    // zepo-n3h: use POSIX readdir
    var pbuf: [4096]u8 = undefined;
    const n = @min(dir_path.len, pbuf.len - 1);
    @memcpy(pbuf[0..n], dir_path[0..n]);
    pbuf[n] = 0;
    const d = std.c.opendir(@ptrCast(&pbuf)) orelse return;
    defer _ = std.c.closedir(d);
    while (std.c.readdir(d)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.sliceTo(name_ptr, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        switch (entry.type) {
            std.c.DT.REG => {
                if (!std.mem.endsWith(u8, name, ".lisp")) continue;
                if (std.mem.eql(u8, name, "package.lisp")) continue;
                const lisp_path = std.fs.path.join(alloc, &.{ dir_path, name }) catch continue;
                defer alloc.free(lisp_path);
                const stem = name[0 .. name.len - ".lisp".len];
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
            std.c.DT.DIR => {
                const sub_path = std.fs.path.join(alloc, &.{ dir_path, name }) catch continue;
                defer alloc.free(sub_path);
                compileTree(alloc, sub_path, compiled, failed);
            },
            else => {},
        }
    }
}

/// Compile one .lisp file to a .zbc file.
fn compileLibFile(alloc: std.mem.Allocator, lisp_path: []const u8, zbc_path: []const u8) !void {
    // zepo-n3h
    const src = readFilePosix(alloc, lisp_path) orelse return error.FileNotFound;
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

    // Capture module name and exports from the registry.
    var module_name: []const u8 = "";
    var exports: std.ArrayListUnmanaged([]const u8) = .empty;
    defer exports.deinit(alloc);
    var reg_it = ctx.registry.table.iterator();
    if (reg_it.next()) |entry| {
        module_name = entry.key_ptr.*;
        var ex_it = entry.value_ptr.*.exports.keyIterator();
        while (ex_it.next()) |k| try exports.append(alloc, k.*);
    }

    // Write .zbc file.
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    const BufWriter = struct {
        b: *std.ArrayListUnmanaged(u8),
        a: std.mem.Allocator,
        pub fn writeAll(self: @This(), data: []const u8) !void {
            try self.b.appendSlice(self.a, data);
        }
        pub fn writeInt(self: @This(), comptime T: type, value: T, endian: std.builtin.Endian) !void {
            var tmp: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &tmp, value, endian);
            try self.b.appendSlice(self.a, &tmp);
        }
    };
    try cg_serialize.write(BufWriter{ .b = &buf, .a = alloc }, adjusted, rel_toplevel, module_name, exports.items);
    // zepo-n3h
    _ = writeFilePosix(zbc_path, buf.items);
}

// zepo-n3h: POSIX-based recursive directory copy
fn copyDirPosix(alloc: std.mem.Allocator, src_path: []const u8, dest_path: []const u8) !void {
    var pbuf: [4096]u8 = undefined;
    const n = @min(src_path.len, pbuf.len - 1);
    @memcpy(pbuf[0..n], src_path[0..n]);
    pbuf[n] = 0;
    const d = std.c.opendir(@ptrCast(&pbuf)) orelse return;
    defer _ = std.c.closedir(d);
    while (std.c.readdir(d)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.sliceTo(name_ptr, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const src_child = try std.fs.path.join(alloc, &.{ src_path, name });
        defer alloc.free(src_child);
        const dest_child = try std.fs.path.join(alloc, &.{ dest_path, name });
        defer alloc.free(dest_child);
        switch (entry.type) {
            std.c.DT.REG => {
                const data = readFilePosix(alloc, src_child) orelse continue;
                defer alloc.free(data);
                _ = writeFilePosix(dest_child, data);
            },
            std.c.DT.DIR => {
                makePath(dest_child);
                try copyDirPosix(alloc, src_child, dest_child);
            },
            else => {},
        }
    }
}
