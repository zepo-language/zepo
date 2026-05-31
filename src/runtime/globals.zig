//! Global top-level environment.
//!
//! Flat array of (symbol, value) pairs. All slots are registered with the
//! GC RootSet's extra-root list (same stable-slot technique as SymbolTable).

const std = @import("std");
const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

// zepo-33x2
/// Per-binding metadata. Heap-allocated and shared across import aliases
/// via the pointer (imported entries set owned=false and inherit this ptr).
/// Strings are owned []u8 in the allocator that allocated the EntryMeta.
pub const EntryMeta = struct {
    docstring: ?[]u8 = null,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *EntryMeta) void {
        if (self.docstring) |s| self.allocator.free(s);
    }
};

pub const Entry = struct {
    sym_slot: *Value,
    val_slot: *Value,
    /// false for aliased (imported) entries — their slots are owned by the
    /// source module env and must not be freed by this env on deinit.
    owned: bool = true,
    // zepo-33x2: nullable per-binding metadata; shared with import aliases.
    meta: ?*EntryMeta = null,
};

/// Allocate a new (sym, val) slot pair, initialise it, and register the slots
/// as GC extra-roots. Returned Entry is owned by the caller; on error partially
/// allocated resources are released.
pub fn allocEntry(gc: *GC, allocator: std.mem.Allocator, sym: Value, val: Value) !Entry {
    const sym_slot = try allocator.create(Value);
    errdefer allocator.destroy(sym_slot);
    const val_slot = try allocator.create(Value);
    errdefer allocator.destroy(val_slot);
    sym_slot.* = sym;
    val_slot.* = val;
    try gc.roots.addExtra(gc.allocator, sym_slot);
    errdefer _ = gc.roots.extra.pop();
    try gc.roots.addExtra(gc.allocator, val_slot);
    return .{ .sym_slot = sym_slot, .val_slot = val_slot };
}

/// Free the slots owned by this Entry. Note: we intentionally do NOT remove
/// the slots from `gc.roots.extra` — the RootSet is not per-env, and on env
/// shutdown the GC itself is going down. This matches the current behaviour
/// of GlobalEnv.deinit prior to this refactor.
pub fn freeEntry(allocator: std.mem.Allocator, entry: Entry) void {
    if (!entry.owned) return;
    allocator.destroy(entry.sym_slot);
    allocator.destroy(entry.val_slot);
    // zepo-33x2
    if (entry.meta) |m| {
        m.deinit();
        allocator.destroy(m);
    }
}

pub const GlobalEnv = struct {
    gc: *GC,
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry),

    pub fn init(gc: *GC, allocator: std.mem.Allocator) !GlobalEnv {
        return .{
            .gc = gc,
            .allocator = allocator,
            .entries = .empty,
        };
    }

    pub fn deinit(env: *GlobalEnv) void {
        for (env.entries.items) |e| {
            freeEntry(env.allocator, e);
        }
        env.entries.deinit(env.allocator);
    }

    fn find(env: *GlobalEnv, sym: Value) ?usize {
        for (env.entries.items, 0..) |e, i| {
            if (e.sym_slot.* == sym) return i;
        }
        return null;
    }

    /// Find an entry by symbol and return its stable pointer, or null.
    pub fn findEntry(env: *GlobalEnv, sym: Value) ?Entry {
        if (env.find(sym)) |idx| return env.entries.items[idx];
        return null;
    }

    pub fn define(env: *GlobalEnv, sym: Value, val: Value) !void {
        if (env.find(sym)) |idx| {
            env.entries.items[idx].val_slot.* = val;
            return;
        }
        const entry = try allocEntry(env.gc, env.allocator, sym, val);
        try env.entries.append(env.allocator, entry);
    }

    /// Insert an Entry whose slots are owned by another env (i.e. a shared
    /// alias from `import`). Duplicate symbol with a different slot is an
    /// error; duplicate with the same slot is a no-op.
    pub fn importEntry(env: *GlobalEnv, entry: Entry) !void {
        if (env.find(entry.sym_slot.*)) |idx| {
            const existing = env.entries.items[idx];
            if (existing.sym_slot == entry.sym_slot and existing.val_slot == entry.val_slot) {
                return; // same slot, idempotent
            }
            return error.ImportNameConflict;
        }
        try env.entries.append(env.allocator, .{
            .sym_slot = entry.sym_slot,
            .val_slot = entry.val_slot,
            .owned = false,
            // zepo-33x2: share meta ptr so imported aliases see source docs.
            .meta = entry.meta,
        });
    }

    pub fn lookup(env: *GlobalEnv, sym: Value) ?Value {
        if (env.find(sym)) |idx| return env.entries.items[idx].val_slot.*;
        return null;
    }

    pub fn set(env: *GlobalEnv, sym: Value, val: Value) !void {
        const idx = env.find(sym) orelse return error.Unbound;
        env.entries.items[idx].val_slot.* = val;
    }

    // zepo-33x2
    /// Get or lazily allocate the EntryMeta for a binding. Imported aliases
    /// share the meta with the source module since both Entries refer to it
    /// by pointer; mutating through one is visible through the other.
    pub fn ensureMeta(env: *GlobalEnv, sym: Value) !*EntryMeta {
        const idx = env.find(sym) orelse return error.Unbound;
        var e = &env.entries.items[idx];
        if (e.meta) |m| return m;
        const m = try env.allocator.create(EntryMeta);
        m.* = .{ .allocator = env.allocator };
        e.meta = m;
        return m;
    }

    /// Read the EntryMeta for a binding, or null if none was attached.
    pub fn getMeta(env: *GlobalEnv, sym: Value) ?*EntryMeta {
        const idx = env.find(sym) orelse return null;
        return env.entries.items[idx].meta;
    }

    /// Convenience: attach (or replace) the docstring on a binding.
    /// Takes ownership of an internally duped copy.
    pub fn setDocstring(env: *GlobalEnv, sym: Value, doc: []const u8) !void {
        const m = try env.ensureMeta(sym);
        if (m.docstring) |old| m.allocator.free(old);
        m.docstring = try m.allocator.dupe(u8, doc);
    }

    /// Convenience: read the docstring, or null.
    pub fn getDocstring(env: *GlobalEnv, sym: Value) ?[]const u8 {
        const m = env.getMeta(sym) orelse return null;
        return m.docstring;
    }
};

// zepo-33x2
test "EntryMeta: docstring round-trip + import alias shares + set! preserves" {
    const SymbolTable = @import("symbols.zig").SymbolTable;
    var gc = try GC.init(std.testing.allocator);
    defer gc.deinit();
    var st = try SymbolTable.init(&gc, std.testing.allocator);
    defer st.deinit();

    var src_env = try GlobalEnv.init(&gc, std.testing.allocator);
    defer src_env.deinit();
    var dst_env = try GlobalEnv.init(&gc, std.testing.allocator);
    defer dst_env.deinit();

    const sym = try st.intern("doc-me");
    const v1 = value_mod.NIL;
    const v2 = value_mod.TRUE;

    try src_env.define(sym, v1);
    try src_env.setDocstring(sym, "adds one to its argument");

    // Round-trip
    try std.testing.expectEqualStrings(
        "adds one to its argument",
        src_env.getDocstring(sym).?,
    );

    // Import alias shares meta
    const e = src_env.findEntry(sym).?;
    try dst_env.importEntry(e);
    try std.testing.expectEqualStrings(
        "adds one to its argument",
        dst_env.getDocstring(sym).?,
    );

    // set! on the value preserves the docstring
    try src_env.set(sym, v2);
    try std.testing.expectEqual(v2, src_env.lookup(sym).?);
    try std.testing.expectEqualStrings(
        "adds one to its argument",
        src_env.getDocstring(sym).?,
    );

    // Replacing the docstring frees the old one (no leak under testing allocator)
    try src_env.setDocstring(sym, "replaced");
    try std.testing.expectEqualStrings("replaced", src_env.getDocstring(sym).?);
    // Alias sees the replacement (shared ptr).
    try std.testing.expectEqualStrings("replaced", dst_env.getDocstring(sym).?);

    // Undocumented binding returns null
    const sym2 = try st.intern("undocumented");
    try src_env.define(sym2, v1);
    try std.testing.expect(src_env.getDocstring(sym2) == null);
}
