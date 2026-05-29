//! Module-loading operations on EvalContext: (module ...), (package ...),
//! (include ...), (import ...) forms plus search-path resolution.

const std = @import("std");

// zepo-04p: Zig 0.16 removed std.io and std.Io.Dir convenience methods.
// Use POSIX/C directly for file I/O.
extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

fn readFilePosix(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= pbuf.len) return null;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const path_c: [*:0]const u8 = @ptrCast(&pbuf);
    const f = std.c.fopen(path_c, "rb") orelse return null;
    defer _ = std.c.fclose(f);
    _ = fseek(f, 0, 2); // SEEK_END
    const sz = ftell(f);
    if (sz < 0) return null;
    _ = fseek(f, 0, 0); // SEEK_SET
    const buf = alloc.alloc(u8, @intCast(sz)) catch return null;
    const n = std.c.fread(buf.ptr, 1, buf.len, f);
    return buf[0..n];
}

fn fileExistsPosix(path: []const u8) bool {
    var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= pbuf.len) return false;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    return std.c.access(@ptrCast(&pbuf), 0) == 0;
}

// Minimal reader for std.io.fixedBufferStream replacement (removed in Zig 0.16).
const SliceReader = struct {
    buf: []const u8 = &.{},
    pos: usize = 0,

    pub fn readNoEof(self: *SliceReader, dest: []u8) !void {
        if (self.pos + dest.len > self.buf.len) return error.EndOfStream;
        @memcpy(dest, self.buf[self.pos..][0..dest.len]);
        self.pos += dest.len;
    }

    pub fn readInt(self: *SliceReader, comptime T: type, endian: std.builtin.Endian) !T {
        const n = @sizeOf(T);
        if (self.pos + n > self.buf.len) return error.EndOfStream;
        const bytes = self.buf[self.pos..][0..n];
        self.pos += n;
        return std.mem.readInt(T, bytes[0..n], endian);
    }
};
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const gc_collector = @import("../gc/collector.zig");
const HandleScope = gc_collector.HandleScope;

const module_mod = @import("module.zig");
const ContainerMeta = module_mod.ContainerMeta;

const runtime_objects = @import("objects.zig");
const hashtable = @import("hashtable.zig");
const eval = @import("eval.zig");
const EvalContext = eval.EvalContext;
const isHeadSymbol = eval.isHeadSymbol;

const cg_mod = @import("../cg/mod.zig");
const serialize = cg_mod.serialize;
const VM = @import("../vm/mod.zig").VM;

/// Walk a Value list consuming leading `:keyword value` pairs, populating meta.
/// Returns the first non-keyword element (the rest of the form body).
/// Keyword names: :docstring, :version, :author, :license, :depends.
fn parseContainerKeywords(alloc: std.mem.Allocator, objects: anytype, list: Value, meta: *ContainerMeta) !Value {
    var cur = list;
    while (!value_mod.isNil(cur)) {
        if (!objects.isPair(cur)) break;
        const elem = objects.pairCar(cur).*;
        // Keywords are symbols starting with ':'
        if (!objects.isSymbol(elem)) break;
        const sym_name = objects.symbolName(elem);
        if (sym_name.len == 0 or sym_name[0] != ':') break;
        const kw = sym_name[1..]; // strip leading ':'

        const rest = objects.pairCdr(cur).*;
        if (!objects.isPair(rest)) break;
        const val = objects.pairCar(rest).*;
        cur = objects.pairCdr(rest).*;

        if (std.mem.eql(u8, kw, "docstring")) {
            if (objects.isString(val)) {
                if (meta.docstring) |s| alloc.free(s);
                meta.docstring = try alloc.dupe(u8, objects.stringBytes(val));
            }
        } else if (std.mem.eql(u8, kw, "version")) {
            if (objects.isString(val)) {
                if (meta.version) |s| alloc.free(s);
                meta.version = try alloc.dupe(u8, objects.stringBytes(val));
            }
        } else if (std.mem.eql(u8, kw, "author")) {
            if (objects.isString(val)) {
                if (meta.author) |s| alloc.free(s);
                meta.author = try alloc.dupe(u8, objects.stringBytes(val));
            }
        } else if (std.mem.eql(u8, kw, "license")) {
            if (objects.isString(val)) {
                if (meta.license) |s| alloc.free(s);
                meta.license = try alloc.dupe(u8, objects.stringBytes(val));
            }
        } else if (std.mem.eql(u8, kw, "depends")) {
            // :depends (a b c) — val must be a list of symbols/strings
            var deps: std.ArrayListUnmanaged([]const u8) = .empty;
            errdefer { for (deps.items) |d| alloc.free(d); deps.deinit(alloc); }
            var dep = val;
            while (!value_mod.isNil(dep)) {
                if (!objects.isPair(dep)) break;
                const d = objects.pairCar(dep).*;
                if (objects.isSymbol(d)) {
                    try deps.append(alloc, try alloc.dupe(u8, objects.symbolName(d)));
                } else if (objects.isString(d)) {
                    try deps.append(alloc, try alloc.dupe(u8, objects.stringBytes(d)));
                }
                dep = objects.pairCdr(dep).*;
            }
            for (meta.depends) |d| alloc.free(d);
            if (meta.depends.len > 0) alloc.free(meta.depends);
            meta.depends = try deps.toOwnedSlice(alloc);
        }
        // Unknown keywords are silently ignored for forward-compatibility.
    }
    return cur;
}

pub fn evalModuleDecl(ctx: *EvalContext, form: Value) !Value {
    if (ctx.current_module != null) return error.ModuleNotAtTopLevel;

    const objects = runtime_objects;

    // head is `module`; rest = (<name> (export ...) body...)
    const rest = objects.pairCdr(form).*;
    if (!objects.isPair(rest)) return error.InvalidSpecialForm;
    const name_v = objects.pairCar(rest).*;
    if (!objects.isSymbol(name_v)) return error.InvalidSpecialForm;
    const name = objects.symbolName(name_v);

    // Root all traversal values now — registry.create, markExport, and the
    // body loop all can trigger GC via allocation.
    var scope = HandleScope{};
    ctx.gc.roots.pushHandleScope(&scope);
    defer ctx.gc.roots.popHandleScope();

    // Parse leading :keyword metadata, then look for optional (export ...).
    var meta = ContainerMeta.init(ctx.allocator);
    errdefer meta.deinit();
    const after_name = objects.pairCdr(rest).*;
    const after_meta = try parseContainerKeywords(ctx.allocator, objects, after_name, &meta);

    const after_name_slot = scope.push(after_meta);
    const exports_slot = scope.push(value_mod.NIL);
    const iter_slot = scope.push(value_mod.NIL);
    if (objects.isPair(after_name_slot.*)) {
        const first = objects.pairCar(after_name_slot.*).*;
        if (isHeadSymbol(first, "export")) {
            exports_slot.* = first;
            iter_slot.* = objects.pairCdr(after_name_slot.*).*;
        } else {
            iter_slot.* = after_name_slot.*;
        }
    } else {
        iter_slot.* = after_name_slot.*;
    }

    const m = try ctx.registry.create(name);
    m.meta = meta;
    // meta is now owned by m; reset local so errdefer doesn't double-free.
    meta = ContainerMeta.init(ctx.allocator);

    // Register exports before running body so exports can be validated
    // against body-defined names.
    if (!value_mod.isNil(exports_slot.*)) {
        const cur_slot = scope.push(objects.pairCdr(exports_slot.*).*);
        while (!value_mod.isNil(cur_slot.*)) {
            if (!objects.isPair(cur_slot.*)) return error.InvalidSpecialForm;
            const nm_v = objects.pairCar(cur_slot.*).*;
            if (!objects.isSymbol(nm_v)) return error.InvalidSpecialForm;
            try m.markExport(objects.symbolName(nm_v));
            cur_slot.* = objects.pairCdr(cur_slot.*).*;
        }
    }

    ctx.enterModule(m);

    const form_slot = scope.push(value_mod.NIL);

    var last: Value = value_mod.NIL;
    while (!value_mod.isNil(iter_slot.*)) {
        if (!objects.isPair(iter_slot.*)) {
            ctx.leaveModule();
            return error.InvalidSpecialForm;
        }
        form_slot.* = objects.pairCar(iter_slot.*).*;
        iter_slot.* = objects.pairCdr(iter_slot.*).*;
        const body_form = form_slot.*;
        // Nested module declarations are not allowed.
        if (isHeadSymbol(body_form, "module")) {
            ctx.leaveModule();
            return error.ModuleNotAtTopLevel;
        }
        // `import` at module-body top level is fine; route through evalImport
        // so currentEnv() targets the module's env.
        if (isHeadSymbol(body_form, "import")) {
            last = evalImport(ctx, body_form) catch |e| {
                if (ctx.last_error_span == null) ctx.last_error_span = ctx.spans.get(body_form);
                ctx.leaveModule();
                return e;
            };
            continue;
        }
        last = ctx.evalForm(body_form) catch |e| {
            if (ctx.last_error_span == null) ctx.last_error_span = ctx.spans.get(body_form);
            ctx.leaveModule();
            return e;
        };
    }

    // Validate every exported name now exists in the module env.
    // Skip in discovery mode — definitions are intentionally not evaluated.
    if (!ctx.discovery_mode) {
        var it = m.exports.keyIterator();
        while (it.next()) |k| {
            const sym = try ctx.symbols.intern(k.*);
            if (m.env.findEntry(sym) == null) {
                ctx.leaveModule();
                return error.ExportNotDefined;
            }
        }
    }

    ctx.leaveModule();
    return last;
}

/// Evaluate `(package name :keyword value... body...)`.
/// A package is a distribution container — registers in the module registry
/// (so `(import :packages (name))` can find it) and stores ContainerMeta.
/// Body forms are evaluated in the package's module environment.
pub fn evalPackageDecl(ctx: *EvalContext, form: Value) !Value {
    if (ctx.current_module != null) return error.ModuleNotAtTopLevel;

    const objects = runtime_objects;
    const rest = objects.pairCdr(form).*;
    if (!objects.isPair(rest)) return error.InvalidSpecialForm;
    const name_v = objects.pairCar(rest).*;
    if (!objects.isSymbol(name_v)) return error.InvalidSpecialForm;
    const name = objects.symbolName(name_v);

    var scope = HandleScope{};
    ctx.gc.roots.pushHandleScope(&scope);
    defer ctx.gc.roots.popHandleScope();

    var meta = ContainerMeta.init(ctx.allocator);
    errdefer meta.deinit();
    const after_name = objects.pairCdr(rest).*;
    const after_meta = try parseContainerKeywords(ctx.allocator, objects, after_name, &meta);

    const iter_slot = scope.push(after_meta);

    const m = try ctx.registry.create(name);
    m.meta = meta;
    meta = ContainerMeta.init(ctx.allocator);

    ctx.enterModule(m);

    const form_slot = scope.push(value_mod.NIL);
    var last: Value = value_mod.NIL;
    while (!value_mod.isNil(iter_slot.*)) {
        if (!objects.isPair(iter_slot.*)) {
            ctx.leaveModule();
            return error.InvalidSpecialForm;
        }
        form_slot.* = objects.pairCar(iter_slot.*).*;
        iter_slot.* = objects.pairCdr(iter_slot.*).*;
        const body_form = form_slot.*;
        if (isHeadSymbol(body_form, "module") or isHeadSymbol(body_form, "lib") or isHeadSymbol(body_form, "package")) {
            ctx.leaveModule();
            return error.ModuleNotAtTopLevel;
        }
        if (isHeadSymbol(body_form, "import")) {
            last = evalImport(ctx, body_form) catch |e| {
                if (ctx.last_error_span == null) ctx.last_error_span = ctx.spans.get(body_form);
                ctx.leaveModule();
                return e;
            };
            continue;
        }
        last = ctx.evalForm(body_form) catch |e| {
            if (ctx.last_error_span == null) ctx.last_error_span = ctx.spans.get(body_form);
            ctx.leaveModule();
            return e;
        };
        // zepo-zc0: package has no explicit (export ...) form — by design,
        // anything `define`d in a package body is public. Auto-export the
        // defined name. Imports above DO NOT reach this point, so the
        // package's transitively-imported names stay private.
        if (isHeadSymbol(body_form, "define")) {
            const rest_form = objects.pairCdr(body_form).*;
            if (objects.isPair(rest_form)) {
                const head = objects.pairCar(rest_form).*;
                const defined_name_v = if (objects.isPair(head)) objects.pairCar(head).* else head;
                if (objects.isSymbol(defined_name_v)) {
                    m.markExport(objects.symbolName(defined_name_v)) catch |e| {
                        ctx.leaveModule();
                        return e;
                    };
                }
            }
        }
    }

    ctx.leaveModule();
    return last;
}

/// Evaluate `(lib name :keyword value... (export ...) body...)`.
/// A lib is a compiled artifact container — same semantics as module but
/// declared with the `lib` keyword to signal it is a distributable library.
pub fn evalLibDecl(ctx: *EvalContext, form: Value) !Value {
    if (ctx.current_module != null) return error.ModuleNotAtTopLevel;

    const objects = runtime_objects;
    const rest = objects.pairCdr(form).*;
    if (!objects.isPair(rest)) return error.InvalidSpecialForm;
    const name_v = objects.pairCar(rest).*;
    if (!objects.isSymbol(name_v)) return error.InvalidSpecialForm;
    const name = objects.symbolName(name_v);

    var scope = HandleScope{};
    ctx.gc.roots.pushHandleScope(&scope);
    defer ctx.gc.roots.popHandleScope();

    var meta = ContainerMeta.init(ctx.allocator);
    errdefer meta.deinit();
    const after_name = objects.pairCdr(rest).*;
    const after_meta = try parseContainerKeywords(ctx.allocator, objects, after_name, &meta);

    const after_name_slot = scope.push(after_meta);
    const exports_slot = scope.push(value_mod.NIL);
    const iter_slot = scope.push(value_mod.NIL);
    if (objects.isPair(after_name_slot.*)) {
        const first = objects.pairCar(after_name_slot.*).*;
        if (isHeadSymbol(first, "export")) {
            exports_slot.* = first;
            iter_slot.* = objects.pairCdr(after_name_slot.*).*;
        } else {
            iter_slot.* = after_name_slot.*;
        }
    } else {
        iter_slot.* = after_name_slot.*;
    }

    const m = try ctx.registry.create(name);
    m.meta = meta;
    meta = ContainerMeta.init(ctx.allocator);

    if (!value_mod.isNil(exports_slot.*)) {
        const cur_slot = scope.push(objects.pairCdr(exports_slot.*).*);
        while (!value_mod.isNil(cur_slot.*)) {
            if (!objects.isPair(cur_slot.*)) return error.InvalidSpecialForm;
            const nm_v = objects.pairCar(cur_slot.*).*;
            if (!objects.isSymbol(nm_v)) return error.InvalidSpecialForm;
            try m.markExport(objects.symbolName(nm_v));
            cur_slot.* = objects.pairCdr(cur_slot.*).*;
        }
    }

    ctx.enterModule(m);

    const form_slot = scope.push(value_mod.NIL);
    var last: Value = value_mod.NIL;
    while (!value_mod.isNil(iter_slot.*)) {
        if (!objects.isPair(iter_slot.*)) {
            ctx.leaveModule();
            return error.InvalidSpecialForm;
        }
        form_slot.* = objects.pairCar(iter_slot.*).*;
        iter_slot.* = objects.pairCdr(iter_slot.*).*;
        const body_form = form_slot.*;
        if (isHeadSymbol(body_form, "module") or isHeadSymbol(body_form, "lib")) {
            ctx.leaveModule();
            return error.ModuleNotAtTopLevel;
        }
        if (isHeadSymbol(body_form, "import")) {
            last = evalImport(ctx, body_form) catch |e| {
                if (ctx.last_error_span == null) ctx.last_error_span = ctx.spans.get(body_form);
                ctx.leaveModule();
                return e;
            };
            continue;
        }
        last = ctx.evalForm(body_form) catch |e| {
            if (ctx.last_error_span == null) ctx.last_error_span = ctx.spans.get(body_form);
            ctx.leaveModule();
            return e;
        };
    }

    if (!ctx.discovery_mode) {
        var it = m.exports.keyIterator();
        while (it.next()) |k| {
            const sym = try ctx.symbols.intern(k.*);
            if (m.env.findEntry(sym) == null) {
                ctx.leaveModule();
                return error.ExportNotDefined;
            }
        }
    }

    ctx.leaveModule();
    return last;
}

/// Evaluate `(include "path")` — reads and evaluates a file in the current env.
pub fn evalInclude(ctx: *EvalContext, form: Value) anyerror!Value {
    const objects = runtime_objects;
    const rest = objects.pairCdr(form).*;
    if (!objects.isPair(rest)) return error.InvalidSpecialForm;
    const path_v = objects.pairCar(rest).*;
    if (!objects.isString(path_v)) return error.InvalidSpecialForm;
    const path = objects.stringBytes(path_v);
    const src = readFilePosix(ctx.allocator, path) orelse return error.IOError;
    defer ctx.allocator.free(src);
    return ctx.evalString(src, path);
}

/// Walk module_path looking for <name>.lisp or <pkg>/<mod>.lisp and evaluate it.
/// Supports two forms:
///   bare name  "clap"       → <dir>/clap.lisp  OR  <dir>/clap/mod.lisp (needs package.lisp)
///   pkg/mod    "tui/list"   → <dir>/tui/list.lisp (needs <dir>/tui/package.lisp)
pub fn logModuleFile(ctx: *EvalContext, name: []const u8, path: []const u8) void {
    const log = ctx.module_file_log orelse return;
    if (log.contains(name)) return;
    const k = ctx.allocator.dupe(u8, name) catch return;
    const v = ctx.allocator.dupe(u8, path) catch { ctx.allocator.free(k); return; };
    log.put(k, v) catch { ctx.allocator.free(k); ctx.allocator.free(v); return; };
    if (ctx.module_file_order) |ord| ord.append(ctx.allocator, k) catch {};
}

/// Open and read a file by explicit path string. Tries the path as-is (works
/// for both absolute and CWD-relative paths since openat with an absolute path
/// ignores the dirfd on POSIX).
fn readModuleFile(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    return readFilePosix(alloc, path);
}

/// Load `name` from an explicit path list — the core of auto-loading.
pub fn tryAutoLoadFromPaths(ctx: *EvalContext, name: []const u8, paths: []const []const u8) anyerror!void {
    if (ctx.gc.trace.module) {
        std.debug.print("[module] loading '{s}' ({d} search paths)\n", .{ name, paths.len });
    }
    const saved_module = ctx.current_module;
    ctx.current_module = null;
    defer ctx.current_module = saved_module;

    const slash = std.mem.indexOfScalar(u8, name, '/');

    for (paths) |dir| {
        if (slash) |idx| {
            const pkg = name[0..idx];
            const mod = name[idx + 1 ..];

            // Try compiled .zbc first, then fall back to .lisp source.
            const zbc_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/{s}.zbc", .{ dir, pkg, mod }) catch continue;
            defer ctx.allocator.free(zbc_path);
            if (tryLoadZbc(ctx, name, zbc_path)) {
                logModuleFile(ctx, name, zbc_path);
            } else {
                const full_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/{s}.lisp", .{ dir, pkg, mod }) catch continue;
                defer ctx.allocator.free(full_path);
                const src = readModuleFile(ctx.allocator, full_path) orelse continue;
                defer ctx.allocator.free(src);
                _ = try ctx.evalString(src, full_path);
                logModuleFile(ctx, name, full_path);
            }
        } else {
            // Try <dir>/<name>.zbc first.
            const zbc_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.zbc", .{ dir, name }) catch continue;
            defer ctx.allocator.free(zbc_path);
            if (tryLoadZbc(ctx, name, zbc_path)) {
                logModuleFile(ctx, name, zbc_path);
            } else {
                // Try <dir>/<name>.lisp
                const file_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.lisp", .{ dir, name }) catch continue;
                defer ctx.allocator.free(file_path);
                if (readModuleFile(ctx.allocator, file_path)) |src| {
                    defer ctx.allocator.free(src);
                    _ = try ctx.evalString(src, file_path);
                    logModuleFile(ctx, name, file_path);
                } else {
                    // Try <dir>/<name>/mod.lisp (package entry point).
                    const manifest = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/package.lisp", .{ dir, name }) catch continue;
                    defer ctx.allocator.free(manifest);
                    if (!fileExistsPosix(manifest)) continue;
                    // Try compiled mod.zbc first.
                    const mod_zbc = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/mod.zbc", .{ dir, name }) catch continue;
                    defer ctx.allocator.free(mod_zbc);
                    if (!tryLoadZbc(ctx, name, mod_zbc)) {
                        const mod_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/mod.lisp", .{ dir, name }) catch continue;
                        defer ctx.allocator.free(mod_path);
                        const src = readModuleFile(ctx.allocator, mod_path) orelse continue;
                        defer ctx.allocator.free(src);
                        _ = try ctx.evalString(src, mod_path);
                    }
                    logModuleFile(ctx, name, mod_zbc);
                }
            }
        }
        if (ctx.registry.get(name) != null) {
            if (ctx.gc.trace.module) {
                const path = if (ctx.module_file_log) |log| log.get(name) orelse "<unknown>" else "<unknown>";
                std.debug.print("[module] loaded '{s}' from '{s}'\n", .{ name, path });
            }
            return;
        }
    }
    if (ctx.gc.trace.module) {
        std.debug.print("[module] '{s}' not found in {d} search path(s)\n", .{ name, paths.len });
    }
}

/// Auto-load `name` using ctx.module_path (legacy / bare-import path).
pub fn tryAutoLoad(ctx: *EvalContext, name: []const u8) anyerror!void {
    return tryAutoLoadFromPaths(ctx, name, ctx.module_path);
}

/// Try to load a .zbc file for `name`. Returns true on success, false if the
/// file doesn't exist or fails to parse (falls back to source loading).
fn tryLoadZbc(ctx: *EvalContext, name: []const u8, zbc_path: []const u8) bool {
    loadZbc(ctx, name, zbc_path) catch return false;
    return true;
}

/// Load a pre-compiled .zbc library file into ctx.
pub fn loadZbc(ctx: *EvalContext, _: []const u8, zbc_path: []const u8) !void {
    const data = readFilePosix(ctx.allocator, zbc_path) orelse return error.FileNotFound;
    defer ctx.allocator.free(data);

    const base_offset: u32 = @intCast(ctx.compiled.items.len);

    // Name store: scratch buffer for deserialized name strings.
    // Appended during read; slices stay valid as long as name_store lives.
    // We move ownership into the context after loading.
    var name_store: std.ArrayListUnmanaged(u8) = .empty;
    errdefer name_store.deinit(ctx.allocator);

    var fbs = SliceReader{ .buf = data };
    var result = try serialize.read(
        &fbs,
        ctx.allocator,
        ctx.gc,
        ctx.symbols,
        base_offset,
        &name_store,
    );
    errdefer result.deinit();

    // Transfer name_store ownership to a heap allocation so the slices in
    // CompiledFn.names remain valid after this function returns.
    const ns_buf = try ctx.allocator.dupe(u8, name_store.items);
    name_store.deinit(ctx.allocator);
    // Patch all names slices to point into ns_buf.
    var ns_offset: usize = 0;
    for (result.fns) |*f| {
        for (f.names) |*n| {
            n.* = ns_buf[ns_offset .. ns_offset + n.len];
            ns_offset += n.len;
        }
        for (f.keyword_params) |*kp| {
            kp.name = ns_buf[ns_offset .. ns_offset + kp.name.len];
            ns_offset += kp.name.len;
        }
    }
    // Append the name buffer to context's owned list so it's freed on deinit.
    try ctx.zbc_name_bufs.append(ctx.allocator, ns_buf);

    // zepo-nhl: box each deserialized fn so its pointer is stable across later
    // ctx.compiled reallocations (live frames hold *CompiledFn into the boxes).
    for (result.fns) |f| {
        const boxed = try ctx.allocator.create(cg_mod.CompiledFn);
        boxed.* = f;
        try ctx.compiled.append(ctx.allocator, boxed);
    }
    ctx.allocator.free(result.fns); // slice itself freed; boxed items owned by ctx.compiled

    // Rebuild VM with updated compiled_fns.
    if (ctx.vm) |*v| { v.deinit(); ctx.vm = null; }
    ctx.vm = try VM.init(ctx.gc, ctx.currentEnv(), ctx.symbols, ctx.compiled.items, ctx.allocator, ctx.vm_max_regs);
    if (ctx.current_module != null) ctx.vm.?.fallback_globals = ctx.globals;
    ctx.vm.?.do_import = @import("eval.zig").vmImportCallback;
    ctx.vm.?.do_import_ctx = ctx;
    ctx.vm.?.installAsRoot();

    // If this library declared a module, set up the registry entry and run
    // thunks inside the module environment — same as evalModuleDecl does.
    const module_name = result.module_name;
    defer ctx.allocator.free(module_name);
    const exports = result.exports;
    defer {
        for (exports) |ex| ctx.allocator.free(ex);
        ctx.allocator.free(exports);
    }

    const saved_module = ctx.current_module;
    defer ctx.current_module = saved_module;

    if (module_name.len > 0) {
        const m = try ctx.registry.create(module_name);
        ctx.current_module = m;
        // Rebuild VM so it targets the module env.
        if (ctx.vm) |*v| { v.deinit(); ctx.vm = null; }
        ctx.vm = try VM.init(ctx.gc, ctx.currentEnv(), ctx.symbols, ctx.compiled.items, ctx.allocator, ctx.vm_max_regs);
        ctx.vm.?.fallback_globals = ctx.globals;
        ctx.vm.?.do_import = @import("eval.zig").vmImportCallback;
        ctx.vm.?.do_import_ctx = ctx;
        ctx.vm.?.installAsRoot();
    }

    // Run each top-level thunk.
    for (result.toplevel_ids) |fn_id| {
        _ = try ctx.vm.?.run(fn_id, &.{});
    }
    ctx.allocator.free(result.toplevel_ids);

    // Mark exports and finalize the module.
    if (ctx.current_module) |m| {
        for (exports) |ex| try m.markExport(ex);
        m.initialized = true;
    }
}

/// Import a module by name strings — used by the VM IMPORT opcode callback.
pub fn doImportByName(
    ctx: *EvalContext,
    mod_name: []const u8,
    alias: ?[]const u8,
    only: ?[]const []const u8,
) @import("errors.zig").LispError!void {
    // NOTE: auto-loading is intentionally omitted here. Calling evalString from
    // inside a VM IMPORT callback overwrites ctx.vm and GC roots, corrupting
    // the outer VM's frame stack. Modules must be pre-loaded (e.g. imported at
    // top level) before they can be (re-)imported inside a function body.
    const target = ctx.registry.get(mod_name) orelse return error.ModuleNotFound;
    if (!target.initialized) return error.ImportBeforeInitialization;
    const active = ctx.currentEnv();

    if (alias) |a| {
        for (target.env.entries.items) |entry| {
            const nm = runtime_objects.symbolName(entry.sym_slot.*);
            if (!target.isExported(nm)) continue;
            const prefixed = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ a, nm });
            defer ctx.allocator.free(prefixed);
            const sym = try ctx.symbols.intern(prefixed);
            try active.define(sym, entry.val_slot.*);
        }
        return;
    }
    if (only) |names| {
        for (names) |nm| {
            if (!target.isExported(nm)) return error.ImportNameNotExported;
            const sym = try ctx.symbols.intern(nm);
            const entry = target.env.findEntry(sym) orelse return error.ExportNotDefined;
            active.importEntry(entry) catch |e| switch (e) {
                error.ImportNameConflict => {
                    if (active.findEntry(entry.sym_slot.*)) |existing| {
                        if (existing.val_slot.* == entry.val_slot.*) continue;
                    }
                    return error.ImportNameConflict;
                },
                else => return e,
            };
        }
        return;
    }
    // zepo-zc0: import all — only the target module's DECLARED exports,
    // never its transitively-imported names. Existing binding wins; silently
    // skip conflicts.
    for (target.env.entries.items) |entry| {
        const nm = runtime_objects.symbolName(entry.sym_slot.*);
        if (!target.isExported(nm)) continue;
        active.importEntry(entry) catch |e| switch (e) {
            error.ImportNameConflict => {},
            else => return e,
        };
    }
}

/// Evaluate an `(import <name>)` or `(import <name> (only <sym>+))` form.
/// Load a lib by name from installed lib dirs.
/// Prefers .zbc over .lisp; searches <dir>/<name>.zbc, <dir>/<name>.lisp,
/// <dir>/<name>/mod.zbc, <dir>/<name>/mod.lisp.
pub fn tryImportLib(ctx: *EvalContext, name: []const u8, paths: []const []const u8) anyerror!void {
    if (ctx.gc.trace.module) {
        std.debug.print("[lib] loading '{s}' ({d} lib paths)\n", .{ name, paths.len });
    }
    const saved_module = ctx.current_module;
    ctx.current_module = null;
    defer ctx.current_module = saved_module;

    for (paths) |dir| {
        // Prefer .zbc
        const zbc = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.zbc", .{ dir, name }) catch continue;
        defer ctx.allocator.free(zbc);
        if (tryLoadZbc(ctx, name, zbc)) { logModuleFile(ctx, name, zbc); break; }

        const lisp = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.lisp", .{ dir, name }) catch continue;
        defer ctx.allocator.free(lisp);
        if (readModuleFile(ctx.allocator, lisp)) |src| {
            defer ctx.allocator.free(src);
            _ = try ctx.evalString(src, lisp);
            logModuleFile(ctx, name, lisp);
            break;
        }

        const mod_zbc = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/mod.zbc", .{ dir, name }) catch continue;
        defer ctx.allocator.free(mod_zbc);
        if (tryLoadZbc(ctx, name, mod_zbc)) { logModuleFile(ctx, name, mod_zbc); break; }

        const mod_lisp = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/mod.lisp", .{ dir, name }) catch continue;
        defer ctx.allocator.free(mod_lisp);
        if (readModuleFile(ctx.allocator, mod_lisp)) |src| {
            defer ctx.allocator.free(src);
            _ = try ctx.evalString(src, mod_lisp);
            logModuleFile(ctx, name, mod_lisp);
            break;
        }
    }
    if (ctx.gc.trace.module and ctx.registry.get(name) == null) {
        std.debug.print("[lib] '{s}' not found in {d} lib path(s)\n", .{ name, paths.len });
    }
}

/// Load a package by name from installed package roots.
/// Searches <base>/<name>/src/main.zbc then <base>/<name>/src/main.lisp.
/// Adds <base>/<name>/src/ to ctx.module_path so sub-modules resolve.
pub fn tryImportPackage(ctx: *EvalContext, name: []const u8, roots: []const []const u8) anyerror!void {
    if (ctx.gc.trace.module) {
        std.debug.print("[pkg] loading '{s}' ({d} package roots)\n", .{ name, roots.len });
    }
    const saved_module = ctx.current_module;
    ctx.current_module = null;
    defer ctx.current_module = saved_module;

    for (roots) |base| {
        const src_dir = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/src", .{ base, name }) catch continue;
        // src_dir ownership transferred to module_path; don't defer-free here.

        const main_zbc = std.fmt.allocPrint(ctx.allocator, "{s}/main.zbc", .{src_dir}) catch {
            ctx.allocator.free(src_dir);
            continue;
        };
        defer ctx.allocator.free(main_zbc);

        const loaded = blk: {
            if (tryLoadZbc(ctx, name, main_zbc)) { logModuleFile(ctx, name, main_zbc); break :blk true; }
            const main_lisp = std.fmt.allocPrint(ctx.allocator, "{s}/main.lisp", .{src_dir}) catch { break :blk false; };
            defer ctx.allocator.free(main_lisp);
            if (readModuleFile(ctx.allocator, main_lisp)) |src| {
                defer ctx.allocator.free(src);
                _ = ctx.evalString(src, main_lisp) catch { break :blk false; };
                logModuleFile(ctx, name, main_lisp);
                break :blk true;
            }
            break :blk false;
        };

        if (loaded) {
            // Mount src/ on module_path so (import :modules (name.submod)) resolves.
            const old_len = ctx.module_path.len;
            const new_path = ctx.allocator.alloc([]const u8, old_len + 1) catch { ctx.allocator.free(src_dir); break; };
            @memcpy(new_path[0..old_len], ctx.module_path);
            new_path[old_len] = src_dir;
            // Register for cleanup in EvalContext.deinit.
            ctx.owned_module_path_dirs.append(ctx.allocator, src_dir) catch {};
            ctx.owned_module_path_slices.append(ctx.allocator, new_path) catch {};
            ctx.module_path = new_path;
            break;
        } else {
            ctx.allocator.free(src_dir);
        }
    }
    if (ctx.gc.trace.module and ctx.registry.get(name) == null) {
        std.debug.print("[pkg] '{s}' not found in {d} package root(s)\n", .{ name, roots.len });
    }
}

/// Import a single module name using an explicit path list and tier.
/// Auto-loads if needed, then imports all exported names into the active env.
fn importOneName(ctx: *EvalContext, mod_name: []const u8, paths: []const []const u8, tier: []const u8) !void {
    if (ctx.registry.get(mod_name) == null) {
        if (std.mem.eql(u8, tier, "libs")) {
            try tryImportLib(ctx, mod_name, paths);
        } else if (std.mem.eql(u8, tier, "packages")) {
            try tryImportPackage(ctx, mod_name, paths);
        } else {
            try tryAutoLoadFromPaths(ctx, mod_name, paths);
        }
    }
    const target = ctx.registry.get(mod_name) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "note: '{s}' not found in search paths\n", .{mod_name}) catch "";
        _ = std.c.write(2, msg.ptr, msg.len);
        return error.ModuleNotFound;
    };
    if (!target.initialized) return error.ImportBeforeInitialization;
    const active = ctx.currentEnv();
    for (target.env.entries.items) |entry| {
        active.importEntry(entry) catch |e| switch (e) {
            error.ImportNameConflict => {},
            else => return e,
        };
    }
}

/// Handle `(import :modules (...) :libs (...) :packages (...))`.
/// Parses keyword/list pairs and loads each name from the matching path tier.
fn evalImportKeyword(ctx: *EvalContext, args: Value) !Value {
    const objects = runtime_objects;
    var scope = HandleScope{};
    ctx.gc.roots.pushHandleScope(&scope);
    defer ctx.gc.roots.popHandleScope();

    const cur_slot = scope.push(args);
    while (!value_mod.isNil(cur_slot.*)) {
        if (!objects.isPair(cur_slot.*)) return error.InvalidSpecialForm;
        const kw_v = objects.pairCar(cur_slot.*).*;
        if (!objects.isSymbol(kw_v)) return error.InvalidSpecialForm;
        const kw_name = objects.symbolName(kw_v);
        if (kw_name.len == 0 or kw_name[0] != ':') return error.InvalidSpecialForm;
        const tier = kw_name[1..];

        cur_slot.* = objects.pairCdr(cur_slot.*).*;
        if (!objects.isPair(cur_slot.*)) return error.InvalidSpecialForm;
        const list_v = objects.pairCar(cur_slot.*).*;
        cur_slot.* = objects.pairCdr(cur_slot.*).*;

        const paths: []const []const u8 = if (std.mem.eql(u8, tier, "libs"))
            ctx.lib_path
        else if (std.mem.eql(u8, tier, "packages"))
            ctx.package_path
        else // "modules" or anything else falls back to module_path
            ctx.module_path;

        // Walk the name list.
        const name_slot = scope.push(list_v);
        while (!value_mod.isNil(name_slot.*)) {
            if (!objects.isPair(name_slot.*)) return error.InvalidSpecialForm;
            const nm_v = objects.pairCar(name_slot.*).*;
            name_slot.* = objects.pairCdr(name_slot.*).*;
            if (!objects.isSymbol(nm_v)) return error.InvalidSpecialForm;
            const nm = objects.symbolName(nm_v);
            try importOneName(ctx, nm, paths, tier);
        }
    }
    return value_mod.NIL;
}

pub fn evalImport(ctx: *EvalContext, form: Value) !Value {
    const objects = runtime_objects;

    // Root `rest` before tryAutoLoad: auto-loading calls evalString which can
    // trigger a minor GC, moving any nursery pair. Without rooting, the `rest`
    // local becomes a stale from-space pointer and the tail read below returns
    // garbage → InvalidSpecialForm.
    var scope = HandleScope{};
    ctx.gc.roots.pushHandleScope(&scope);
    defer ctx.gc.roots.popHandleScope();

    const rest_slot = scope.push(objects.pairCdr(form).*);
    if (!objects.isPair(rest_slot.*)) return error.InvalidSpecialForm;
    const name_v = objects.pairCar(rest_slot.*).*;
    if (!objects.isSymbol(name_v)) return error.ImportNameMustBeSymbol;

    // Keyword dispatch: (import :modules (...) :libs (...) :packages (...))
    const name_str = objects.symbolName(name_v);
    if (name_str.len > 0 and name_str[0] == ':') {
        return evalImportKeyword(ctx, rest_slot.*);
    }

    const mod_name = name_str; // symbol is old-gen, stable across GC

    // Auto-load from search path if not yet registered.
    if (ctx.registry.get(mod_name) == null) {
        try tryAutoLoad(ctx, mod_name);
    }

    const target = ctx.registry.get(mod_name) orelse {
        var hdr_buf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "note: '{s}' not found in search paths:\n", .{mod_name}) catch "";
        _ = std.c.write(2, hdr.ptr, hdr.len);
        if (ctx.module_path.len == 0) {
            const nm = "  (no search paths — add paths to project.lisp or set ZEPO_PATH)\n";
            _ = std.c.write(2, nm, nm.len);
        } else {
            for (ctx.module_path) |dir| {
                var line_buf: [512]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "  {s}/{s}.lisp\n", .{ dir, mod_name }) catch continue;
                _ = std.c.write(2, line.ptr, line.len);
            }
        }
        return error.ModuleNotFound;
    };
    if (!target.initialized) return error.ImportBeforeInitialization;

    const tail = objects.pairCdr(rest_slot.*).*;
    const active = ctx.currentEnv();

    if (value_mod.isNil(tail)) {
        // zepo-zc0: Full import brings ONLY the module's declared exports into
        // the active env. Non-exported names (including the module's own
        // transitively-imported deps) stay private — closures defined inside
        // the module still resolve them via LOAD_GLOBAL's closure home_env
        // fallback (see vm/dispatch.zig). Name conflicts are silently skipped
        // — existing binding wins.
        for (target.env.entries.items) |entry| {
            const nm = runtime_objects.symbolName(entry.sym_slot.*);
            if (!target.isExported(nm)) continue;
            active.importEntry(entry) catch |e| switch (e) {
                error.ImportNameConflict => {},
                else => return e,
            };
        }
        // zepo-cnj4: ALSO bind the module's FULL path as a namespace alias,
        // so callers get qualified access for free without an explicit :as
        // clause. The full path (e.g. `math/tensor`) is used rather than the
        // last segment so it never collides with an exported short name (the
        // module that exports `tensor` as a constructor can still be aliased
        // because `math/tensor` is a distinct symbol). The leading `(import
        // math/tensor)` flat-dump still works for back compat; once
        // [[zepo-cnj4-rm]] migrates call sites, the flat-dump goes away and
        // qualified access becomes mandatory.
        const path_sym = try ctx.symbols.intern(mod_name);
        if (active.findEntry(path_sym) == null) {
            const ns = hashtable.make(ctx.gc) catch return error.OutOfMemory;
            const ns_slot = scope.push(ns);
            for (target.env.entries.items) |entry| {
                const nm = runtime_objects.symbolName(entry.sym_slot.*);
                // zepo-we7e: include ALL of the module's bindings — exported
                // AND non-exported. Non-exports are accessible only via the
                // qualified `home/path.name` syntax (never unqualified — that
                // would be the zepo-zc0 leak). This is the same Python-style
                // "private by convention" model: accessible by qualifier when
                // you really need it (e.g. macro hygiene), discouraged by
                // convention.
                const key_sym = try ctx.symbols.intern(nm);
                hashtable.putDistinct(ctx.gc, ns_slot.*, key_sym, entry.val_slot.*) catch
                    return error.OutOfMemory;
            }
            try active.define(path_sym, ns_slot.*);
        }
        return value_mod.NIL;
    }

    if (!objects.isPair(tail)) return error.InvalidSpecialForm;
    const selector = objects.pairCar(tail).*;
    const after_selector = objects.pairCdr(tail).*;

    // zepo-aqm: (import name :as alias)
    //
    // Binds `alias` in the importer's env to a NAMESPACE VALUE (currently a
    // hash_table keyed by symbol). Accessing members is done via the qualified
    // syntax `alias.name` (ADR 0001), which LOAD_GLOBAL detects at lookup time
    // and resolves into the namespace.
    //
    // `:as` is the canonical spelling (keyword-flavored to match :version etc.).
    // Bare `as` is also accepted as a transitional convenience.
    if (objects.isSymbol(selector) and
        (std.mem.eql(u8, objects.symbolName(selector), ":as") or
            std.mem.eql(u8, objects.symbolName(selector), "as")))
    {
        if (!objects.isPair(after_selector)) return error.InvalidSpecialForm;
        const alias_v = objects.pairCar(after_selector).*;
        if (!objects.isSymbol(alias_v)) return error.InvalidSpecialForm;
        if (!value_mod.isNil(objects.pairCdr(after_selector).*)) return error.InvalidSpecialForm;

        // Build the namespace hash_table.
        const ns = hashtable.make(ctx.gc) catch return error.OutOfMemory;
        const ns_slot = scope.push(ns);
        for (target.env.entries.items) |entry| {
            const nm = runtime_objects.symbolName(entry.sym_slot.*);
            if (!target.isExported(nm)) continue;
            const key_sym = try ctx.symbols.intern(nm);
            hashtable.putDistinct(ctx.gc, ns_slot.*, key_sym, entry.val_slot.*) catch
                return error.OutOfMemory;
        }
        const alias_sym = try ctx.symbols.intern(objects.symbolName(alias_v));
        try active.define(alias_sym, ns_slot.*);
        return value_mod.NIL;
    }

    if (!value_mod.isNil(after_selector)) return error.InvalidSpecialForm;
    // zepo-ug3: two shapes accepted for selective import:
    //   (import M (only a b c))  -- explicit, original form
    //   (import M (a b c))       -- sugar, all elements are names
    // Discriminator: if the list's head is a non-symbol or a symbol other than
    // `only`, treat the whole list as the name list.
    if (!objects.isPair(selector)) return error.InvalidSpecialForm;
    var cur = blk: {
        const head_v = objects.pairCar(selector).*;
        if (objects.isSymbol(head_v) and std.mem.eql(u8, objects.symbolName(head_v), "only")) {
            break :blk objects.pairCdr(selector).*;
        }
        break :blk selector; // sugar: entire list is the name list
    };
    while (!value_mod.isNil(cur)) {
        if (!objects.isPair(cur)) return error.InvalidSpecialForm;
        const nm_v = objects.pairCar(cur).*;
        if (!objects.isSymbol(nm_v)) return error.InvalidSpecialForm;
        const nm = objects.symbolName(nm_v);
        if (!target.isExported(nm)) return error.ImportNameNotExported;
        const sym = try ctx.symbols.intern(nm);
        const entry = target.env.findEntry(sym) orelse return error.ExportNotDefined;
        active.importEntry(entry) catch |e| switch (e) {
            error.ImportNameConflict => {
                if (active.findEntry(entry.sym_slot.*)) |existing| {
                    if (existing.val_slot.* == entry.val_slot.*) {} else return error.ImportNameConflict;
                } else return error.ImportNameConflict;
            },
            else => return e,
        };
        cur = objects.pairCdr(cur).*;
    }
    // zepo-y1a4 + zepo-we7e: selective imports also bind the auto-alias
    // namespace so macros expanded from the imported module can still reach
    // their home internals via the qualified `home/path.name` form (which
    // we7e rewrites them to at defmacro time).
    const path_sym2 = try ctx.symbols.intern(mod_name);
    if (active.findEntry(path_sym2) == null) {
        const ns = hashtable.make(ctx.gc) catch return error.OutOfMemory;
        const ns_slot = scope.push(ns);
        for (target.env.entries.items) |entry| {
            const nm = runtime_objects.symbolName(entry.sym_slot.*);
            const key_sym = try ctx.symbols.intern(nm);
            hashtable.putDistinct(ctx.gc, ns_slot.*, key_sym, entry.val_slot.*) catch
                return error.OutOfMemory;
        }
        try active.define(path_sym2, ns_slot.*);
    }
    return value_mod.NIL;
}
