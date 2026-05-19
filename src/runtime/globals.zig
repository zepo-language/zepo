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

pub const Entry = struct {
    sym_slot: *Value,
    val_slot: *Value,
    /// false for aliased (imported) entries — their slots are owned by the
    /// source module env and must not be freed by this env on deinit.
    owned: bool = true,
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
};
