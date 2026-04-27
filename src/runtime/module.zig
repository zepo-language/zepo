//! Module and ModuleRegistry.
//!
//! A Module owns a GlobalEnv (same layout as the top-level env). Each module's
//! env entries are GC-rooted via the same `roots.extra` pathway that
//! `GlobalEnv` uses today — `GlobalEnv.define` registers the slots itself.
//!
//! ModuleRegistry owns *Module allocations and maps name -> *Module. The
//! registry does NOT need its own GC visitor because every module's entry
//! slots already live in `gc.roots.extra` (registered at define-time).

const std = @import("std");
const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;
const globals_mod = @import("globals.zig");
const GlobalEnv = globals_mod.GlobalEnv;

pub const Module = struct {
    name: []u8, // owned
    exports: std.StringHashMap(void),
    env: GlobalEnv,
    initialized: bool,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, gc: *GC, name: []const u8) !Module {
        const name_owned = try alloc.dupe(u8, name);
        errdefer alloc.free(name_owned);
        return .{
            .name = name_owned,
            .exports = std.StringHashMap(void).init(alloc),
            .env = try GlobalEnv.init(gc, alloc),
            .initialized = false,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *Module) void {
        // Free copies of export-name keys.
        var it = self.exports.keyIterator();
        while (it.next()) |k| {
            self.allocator.free(k.*);
        }
        self.exports.deinit();
        self.env.deinit();
        self.allocator.free(self.name);
    }

    pub fn markExport(self: *Module, name: []const u8) !void {
        if (self.exports.contains(name)) return;
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        try self.exports.put(name_owned, {});
    }

    pub fn isExported(self: *const Module, name: []const u8) bool {
        return self.exports.contains(name);
    }
};

pub const ModuleRegistry = struct {
    allocator: std.mem.Allocator,
    gc: *GC,
    table: std.StringHashMap(*Module),

    pub fn init(alloc: std.mem.Allocator, gc: *GC) ModuleRegistry {
        return .{
            .allocator = alloc,
            .gc = gc,
            .table = std.StringHashMap(*Module).init(alloc),
        };
    }

    pub fn deinit(self: *ModuleRegistry) void {
        var it = self.table.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.table.deinit();
    }

    pub fn create(self: *ModuleRegistry, name: []const u8) !*Module {
        if (self.table.contains(name)) return error.ModuleAlreadyDefined;
        const m = try self.allocator.create(Module);
        errdefer self.allocator.destroy(m);
        m.* = try Module.init(self.allocator, self.gc, name);
        errdefer m.deinit();
        // Use the module's owned name as the table key so lifetime is tied to the module.
        try self.table.put(m.name, m);
        return m;
    }

    pub fn get(self: *ModuleRegistry, name: []const u8) ?*Module {
        return self.table.get(name);
    }
};

test "module create/get" {
    var gc = try GC.init(std.testing.allocator);
    defer gc.deinit();
    var reg = ModuleRegistry.init(std.testing.allocator, &gc);
    defer reg.deinit();

    const m = try reg.create("foo");
    try std.testing.expect(!m.initialized);
    try m.markExport("x");
    try std.testing.expect(m.isExported("x"));
    try std.testing.expect(!m.isExported("y"));

    try std.testing.expect(reg.get("foo") == m);
    try std.testing.expect(reg.get("bar") == null);

    // Duplicate create errors.
    try std.testing.expectError(error.ModuleAlreadyDefined, reg.create("foo"));
}
