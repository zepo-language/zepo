//! Module-loading operations on EvalContext: (module ...), (package ...),
//! (include ...), (import ...) forms plus search-path resolution.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const gc_collector = @import("../gc/collector.zig");
const HandleScope = gc_collector.HandleScope;

const package_mod = @import("package.zig");
const PackageInfo = package_mod.PackageInfo;

const runtime_objects = @import("objects.zig");
const eval = @import("eval.zig");
const EvalContext = eval.EvalContext;
const isHeadSymbol = eval.isHeadSymbol;

pub fn evalModuleDecl(ctx: *EvalContext, form: Value) !Value {
    if (ctx.current_module != null) return error.ModuleNotAtTopLevel;

    const objects = runtime_objects;

    // head is `module`; rest = (<name> (export ...) body...)
    const rest = objects.pairCdr(form).*;
    if (!objects.isPair(rest)) return error.InvalidSpecialForm;
    const name_v = objects.pairCar(rest).*;
    if (!objects.isSymbol(name_v)) return error.InvalidSpecialForm;
    const name = objects.symbolName(name_v);

    const after_name = objects.pairCdr(rest).*;
    // Optional (export sym ...) — must be first in body if present.
    var body_cur = after_name;
    var exports_form: ?Value = null;
    if (objects.isPair(body_cur)) {
        const first = objects.pairCar(body_cur).*;
        if (isHeadSymbol(first, "export")) {
            exports_form = first;
            body_cur = objects.pairCdr(body_cur).*;
        }
    }

    const m = try ctx.registry.create(name);

    // Register exports before running body so exports can be validated
    // against body-defined names.
    if (exports_form) |ef| {
        const export_tail = objects.pairCdr(ef).*;
        var cur = export_tail;
        while (!value_mod.isNil(cur)) {
            if (!objects.isPair(cur)) return error.InvalidSpecialForm;
            const nm_v = objects.pairCar(cur).*;
            if (!objects.isSymbol(nm_v)) return error.InvalidSpecialForm;
            try m.markExport(objects.symbolName(nm_v));
            cur = objects.pairCdr(cur).*;
        }
    }

    ctx.enterModule(m);

    // Root body_iter so a GC triggered by evalImport/evalForm (e.g. via
    // tryAutoLoad → evalString) cannot stale the traversal pointer.
    var scope = HandleScope{};
    ctx.gc.roots.pushHandleScope(&scope);
    defer ctx.gc.roots.popHandleScope();
    const iter_slot = scope.push(body_cur);
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
    var it = m.exports.keyIterator();
    while (it.next()) |k| {
        const sym = try ctx.symbols.intern(k.*);
        if (m.env.findEntry(sym) == null) {
            ctx.leaveModule();
            return error.ExportNotDefined;
        }
    }

    ctx.leaveModule();
    return last;
}

/// Evaluate `(package name (version "x") (description "y") (depends a b ...))`.
/// Registers package metadata; does not load any modules.
pub fn evalPackageDecl(ctx: *EvalContext, form: Value) !Value {
    const objs = runtime_objects;
    const rest = objs.pairCdr(form).*;
    if (!objs.isPair(rest)) return error.InvalidSpecialForm;
    const name_v = objs.pairCar(rest).*;
    if (!objs.isSymbol(name_v)) return error.InvalidSpecialForm;
    const name = try ctx.allocator.dupe(u8, objs.symbolName(name_v));
    errdefer ctx.allocator.free(name);

    var version: []const u8 = try ctx.allocator.dupe(u8, "");
    var description: []const u8 = try ctx.allocator.dupe(u8, "");
    var depends: std.ArrayListUnmanaged([]const u8) = .{};

    var cur = objs.pairCdr(rest).*;
    while (!value_mod.isNil(cur)) {
        if (!objs.isPair(cur)) break;
        const clause = objs.pairCar(cur).*;
        if (objs.isPair(clause)) {
            const head = objs.pairCar(clause).*;
            if (objs.isSymbol(head)) {
                const kw = objs.symbolName(head);
                const tail = objs.pairCdr(clause).*;
                if (objs.isPair(tail)) {
                    const val = objs.pairCar(tail).*;
                    if (std.mem.eql(u8, kw, "version") and objs.isString(val)) {
                        ctx.allocator.free(version);
                        version = try ctx.allocator.dupe(u8, objs.stringBytes(val));
                    } else if (std.mem.eql(u8, kw, "description") and objs.isString(val)) {
                        ctx.allocator.free(description);
                        description = try ctx.allocator.dupe(u8, objs.stringBytes(val));
                    } else if (std.mem.eql(u8, kw, "depends")) {
                        var dep = tail;
                        while (!value_mod.isNil(dep)) {
                            if (!objs.isPair(dep)) break;
                            const d = objs.pairCar(dep).*;
                            if (objs.isSymbol(d))
                                try depends.append(ctx.allocator, try ctx.allocator.dupe(u8, objs.symbolName(d)));
                            dep = objs.pairCdr(dep).*;
                        }
                    }
                }
            }
        }
        cur = objs.pairCdr(cur).*;
    }

    const info = PackageInfo{
        .name = name,
        .version = version,
        .description = description,
        .depends = try depends.toOwnedSlice(ctx.allocator),
        .allocator = ctx.allocator,
    };
    try ctx.packages.register(info);
    return value_mod.NIL;
}

/// Evaluate `(include "path")` — reads and evaluates a file in the current env.
pub fn evalInclude(ctx: *EvalContext, form: Value) anyerror!Value {
    const objects = runtime_objects;
    const rest = objects.pairCdr(form).*;
    if (!objects.isPair(rest)) return error.InvalidSpecialForm;
    const path_v = objects.pairCar(rest).*;
    if (!objects.isString(path_v)) return error.InvalidSpecialForm;
    const path = objects.stringBytes(path_v);
    const src = try std.fs.cwd().readFileAlloc(ctx.allocator, path, 16 * 1024 * 1024);
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
    log.put(k, v) catch { ctx.allocator.free(k); ctx.allocator.free(v); };
}

/// Open and read a file by explicit path string. Tries the path as-is (works
/// for both absolute and CWD-relative paths since openat with an absolute path
/// ignores the dirfd on POSIX).
fn readModuleFile(alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, 4 * 1024 * 1024) catch null;
}

pub fn tryAutoLoad(ctx: *EvalContext, name: []const u8) anyerror!void {
    const saved_module = ctx.current_module;
    ctx.current_module = null;
    defer ctx.current_module = saved_module;

    const slash = std.mem.indexOfScalar(u8, name, '/');

    for (ctx.module_path) |dir| {
        if (slash) |idx| {
            const pkg = name[0..idx];
            const mod = name[idx + 1 ..];

            // Try <dir>/<pkg>/<mod>.lisp directly — no package.lisp required for
            // user project modules. Installed lib packages also match this path.
            const full_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/{s}.lisp", .{ dir, pkg, mod }) catch continue;
            defer ctx.allocator.free(full_path);
            const src = readModuleFile(ctx.allocator, full_path) orelse continue;
            defer ctx.allocator.free(src);
            _ = try ctx.evalString(src, full_path);
            logModuleFile(ctx, name, full_path);
        } else {
            // Try <dir>/<name>.lisp
            const file_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.lisp", .{ dir, name }) catch continue;
            defer ctx.allocator.free(file_path);
            if (readModuleFile(ctx.allocator, file_path)) |src| {
                defer ctx.allocator.free(src);
                _ = try ctx.evalString(src, file_path);
                logModuleFile(ctx, name, file_path);
            } else {
                // Try <dir>/<name>/mod.lisp (package entry point)
                const manifest = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/package.lisp", .{ dir, name }) catch continue;
                defer ctx.allocator.free(manifest);
                std.fs.cwd().access(manifest, .{}) catch continue;
                const mod_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}/mod.lisp", .{ dir, name }) catch continue;
                defer ctx.allocator.free(mod_path);
                const src = readModuleFile(ctx.allocator, mod_path) orelse continue;
                defer ctx.allocator.free(src);
                _ = try ctx.evalString(src, mod_path);
                logModuleFile(ctx, name, mod_path);
            }
        }
        if (ctx.registry.get(name) != null) return;
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
    // import all — existing binding wins, silently skip conflicts
    for (target.env.entries.items) |entry| {
        active.importEntry(entry) catch |e| switch (e) {
            error.ImportNameConflict => {},
            else => return e,
        };
    }
}

/// Evaluate an `(import <name>)` or `(import <name> (only <sym>+))` form.
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
    const mod_name = objects.symbolName(name_v); // symbol is old-gen, stable across GC

    // Auto-load from search path if not yet registered.
    if (ctx.registry.get(mod_name) == null) {
        try tryAutoLoad(ctx, mod_name);
    }

    const target = ctx.registry.get(mod_name) orelse {
        const stderr = std.fs.File.stderr();
        var hdr_buf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf, "note: '{s}' not found in search paths:\n", .{mod_name}) catch "";
        stderr.writeAll(hdr) catch {};
        if (ctx.module_path.len == 0) {
            stderr.writeAll("  (no search paths — add paths to project.lisp or set ZEPO_PATH)\n") catch {};
        } else {
            for (ctx.module_path) |dir| {
                var line_buf: [512]u8 = undefined;
                const line = std.fmt.bufPrint(&line_buf, "  {s}/{s}.lisp\n", .{ dir, mod_name }) catch continue;
                stderr.writeAll(line) catch {};
            }
        }
        return error.ModuleNotFound;
    };
    if (!target.initialized) return error.ImportBeforeInitialization;

    const tail = objects.pairCdr(rest_slot.*).*;
    const active = ctx.currentEnv();

    if (value_mod.isNil(tail)) {
        // Full import: bring ALL of the module's env entries into the active
        // env so that closures defined in the module can resolve their
        // internal LOAD_GLOBAL references. Name conflicts are silently skipped
        // — the existing binding wins. This lets stdlib modules re-export
        // primitives without colliding with the globals already present.
        for (target.env.entries.items) |entry| {
            active.importEntry(entry) catch |e| switch (e) {
                error.ImportNameConflict => {},
                else => return e,
            };
        }
        return value_mod.NIL;
    }

    if (!objects.isPair(tail)) return error.InvalidSpecialForm;
    const selector = objects.pairCar(tail).*;
    const after_selector = objects.pairCdr(tail).*;

    // (import name as alias) — defines alias.exported-name for every export.
    if (objects.isSymbol(selector) and std.mem.eql(u8, objects.symbolName(selector), "as")) {
        if (!objects.isPair(after_selector)) return error.InvalidSpecialForm;
        const alias_v = objects.pairCar(after_selector).*;
        if (!objects.isSymbol(alias_v)) return error.InvalidSpecialForm;
        if (!value_mod.isNil(objects.pairCdr(after_selector).*)) return error.InvalidSpecialForm;
        const alias = objects.symbolName(alias_v);
        for (target.env.entries.items) |entry| {
            const nm = runtime_objects.symbolName(entry.sym_slot.*);
            if (!target.isExported(nm)) continue;
            const prefixed = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ alias, nm });
            defer ctx.allocator.free(prefixed);
            const sym = try ctx.symbols.intern(prefixed);
            try active.define(sym, entry.val_slot.*);
        }
        return value_mod.NIL;
    }

    if (!value_mod.isNil(after_selector)) return error.InvalidSpecialForm;
    if (!isHeadSymbol(selector, "only")) return error.InvalidSpecialForm;

    var cur = objects.pairCdr(selector).*;
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
    return value_mod.NIL;
}
