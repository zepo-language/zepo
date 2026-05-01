//! Package registry — stores metadata from evaluated package.lisp manifests.

const std = @import("std");

pub const PackageInfo = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    depends: []const []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PackageInfo) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        self.allocator.free(self.description);
        for (self.depends) |d| self.allocator.free(d);
        self.allocator.free(self.depends);
    }
};

pub const PackageRegistry = struct {
    map: std.StringHashMap(PackageInfo),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PackageRegistry {
        return .{ .map = std.StringHashMap(PackageInfo).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *PackageRegistry) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.map.deinit();
    }

    pub fn register(self: *PackageRegistry, info: PackageInfo) !void {
        const key = try self.allocator.dupe(u8, info.name);
        try self.map.put(key, info);
    }

    pub fn get(self: *PackageRegistry, name: []const u8) ?*PackageInfo {
        return self.map.getPtr(name);
    }
};
