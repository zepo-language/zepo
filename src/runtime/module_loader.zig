//! Module-loading operations on EvalContext: (module ...), (package ...),
//! (include ...), (import ...) forms plus search-path resolution.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

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
    // Evaluate body forms in the module's env.
    var body_iter = body_cur;
    var last: Value = value_mod.NIL;
    while (!value_mod.isNil(body_iter)) {
        if (!objects.isPair(body_iter)) {
            ctx.leaveModule();
            return error.InvalidSpecialForm;
        }
        const body_form = objects.pairCar(body_iter).*;
        // Nested module declarations are not allowed.
        if (isHeadSymbol(body_form, "module")) {
            ctx.leaveModule();
            return error.ModuleNotAtTopLevel;
        }
        // `import` at module-body top level is fine; route through evalImport
        // so currentEnv() targets the module's env.
        if (isHeadSymbol(body_form, "import")) {
            last = evalImport(ctx, body_form) catch |e| {
                ctx.leaveModule();
                return e;
            };
            body_iter = objects.pairCdr(body_iter).*;
            continue;
        }
        last = ctx.evalForm(body_form) catch |e| {
            std.debug.print("Module body form failed: {}\n", .{e});
            ctx.leaveModule();
            return e;
        };
        body_iter = objects.pairCdr(body_iter).*;
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

pub fn tryAutoLoad(ctx: *EvalContext, name: []const u8) anyerror!void {
    // If called from inside a module body, temporarily suspend that context
    // so nested module files can call enterModule without hitting the assert.
    const saved_module = ctx.current_module;
    ctx.current_module = null;
    defer ctx.current_module = saved_module;

    const slash = std.mem.indexOfScalar(u8, name, '/');

    for (ctx.module_path) |dir| {
        if (slash) |idx| {
            // pkg/mod style
            const pkg = name[0..idx];
            const mod = name[idx + 1 ..];

            const pkg_dir = std.fs.path.join(ctx.allocator, &.{ dir, pkg }) catch continue;
            defer ctx.allocator.free(pkg_dir);
            const manifest = std.fs.path.join(ctx.allocator, &.{ pkg_dir, "package.lisp" }) catch continue;
            defer ctx.allocator.free(manifest);
            std.fs.cwd().access(manifest, .{}) catch continue;

            const mod_file = std.fmt.allocPrint(ctx.allocator, "{s}.lisp", .{mod}) catch continue;
            defer ctx.allocator.free(mod_file);
            const full_path = std.fs.path.join(ctx.allocator, &.{ pkg_dir, mod_file }) catch continue;
            defer ctx.allocator.free(full_path);
            const src = std.fs.cwd().readFileAlloc(ctx.allocator, full_path, 4 * 1024 * 1024) catch continue;
            defer ctx.allocator.free(src);
            _ = try ctx.evalString(src, full_path);
            logModuleFile(ctx, name, full_path);
        } else {
            // Bare name: try <dir>/<name>.lisp first
            const mod_file = std.fmt.allocPrint(ctx.allocator, "{s}.lisp", .{name}) catch continue;
            defer ctx.allocator.free(mod_file);
            const file_path = std.fs.path.join(ctx.allocator, &.{ dir, mod_file }) catch continue;
            defer ctx.allocator.free(file_path);
            if (std.fs.cwd().readFileAlloc(ctx.allocator, file_path, 4 * 1024 * 1024)) |src| {
                defer ctx.allocator.free(src);
                _ = try ctx.evalString(src, file_path);
                logModuleFile(ctx, name, file_path);
            } else |_| {
                // Then try <dir>/<name>/mod.lisp (package entry point)
                const pkg_dir = std.fs.path.join(ctx.allocator, &.{ dir, name }) catch continue;
                defer ctx.allocator.free(pkg_dir);
                const manifest = std.fs.path.join(ctx.allocator, &.{ pkg_dir, "package.lisp" }) catch continue;
                defer ctx.allocator.free(manifest);
                std.fs.cwd().access(manifest, .{}) catch continue;
                const mod_path = std.fs.path.join(ctx.allocator, &.{ pkg_dir, "mod.lisp" }) catch continue;
                defer ctx.allocator.free(mod_path);
                const src = std.fs.cwd().readFileAlloc(ctx.allocator, mod_path, 4 * 1024 * 1024) catch continue;
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
    // import all
    for (target.env.entries.items) |entry| {
        const is_exported = target.isExported(runtime_objects.symbolName(entry.sym_slot.*));
        active.importEntry(entry) catch |e| switch (e) {
            error.ImportNameConflict => {
                if (is_exported) {
                    if (active.findEntry(entry.sym_slot.*)) |existing| {
                        if (existing.val_slot.* == entry.val_slot.*) continue;
                    }
                    return error.ImportNameConflict;
                }
            },
            else => return e,
        };
    }
}

/// Evaluate an `(import <name>)` or `(import <name> (only <sym>+))` form.
pub fn evalImport(ctx: *EvalContext, form: Value) !Value {
    const objects = runtime_objects;

    const rest = objects.pairCdr(form).*;
    if (!objects.isPair(rest)) return error.InvalidSpecialForm;
    const name_v = objects.pairCar(rest).*;
    if (!objects.isSymbol(name_v)) return error.ImportNameMustBeSymbol;
    const mod_name = objects.symbolName(name_v);

    // Auto-load from search path if not yet registered.
    if (ctx.registry.get(mod_name) == null) {
        try tryAutoLoad(ctx, mod_name);
    }

    const target = ctx.registry.get(mod_name) orelse return error.ModuleNotFound;
    if (!target.initialized) return error.ImportBeforeInitialization;

    const tail = objects.pairCdr(rest).*;
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
