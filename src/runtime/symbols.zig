//! Strongly interned symbol table.
//!
//! `intern(name)` always returns the same Value for the same byte sequence.
//! Interned symbols and their name strings are allocated directly in old-gen
//! so they have stable addresses. Each symbol Value slot is stored on the
//! heap (via allocator.create) and registered with the GC RootSet's extra
//! root list — we never resize an array of slots, so slot pointers stay
//! valid for the life of the process.

const std = @import("std");
const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const Kind = abi.Kind;
const value_mod = abi.value;

const objects = @import("objects.zig");

pub const SymbolTable = struct {
    gc: *GC,
    allocator: std.mem.Allocator,
    map: std.StringHashMap(Value),
    /// Heap-allocated individual Value slots so pointer identity is stable
    /// across inserts. These are also registered as GC roots.
    slots: std.ArrayListUnmanaged(*Value),

    pub fn init(gc: *GC, allocator: std.mem.Allocator) !SymbolTable {
        return .{
            .gc = gc,
            .allocator = allocator,
            .map = std.StringHashMap(Value).init(allocator),
            .slots = .{},
        };
    }

    pub fn deinit(st: *SymbolTable) void {
        for (st.slots.items) |slot| {
            st.allocator.destroy(slot);
        }
        st.slots.deinit(st.allocator);
        st.map.deinit();
    }

    /// Allocate a String directly in old-gen so its bytes remain at a stable
    /// address across minor GCs. This is crucial because the hash-map keys
    /// are slices into these strings.
    fn makeStringInOldGen(gc: *GC, bytes: []const u8) !Value {
        const nbytes = bytes.len;
        const tail_words = (nbytes + 8 - 1) / 8;
        const body_words = 1 + tail_words;
        const h = gc.old_gen.alloc(body_words) orelse return error.OutOfMemory;
        h.* = ObjHeader.init(.string, .old_gen, @intFromEnum(Kind.string), @intCast(body_words));
        const len_slot: *u64 = @ptrFromInt(@intFromPtr(h) + 8);
        len_slot.* = @intCast(nbytes);
        if (nbytes != 0) {
            const tail_ptr: [*]u8 = @ptrFromInt(@intFromPtr(h) + 16);
            @memcpy(tail_ptr[0..nbytes], bytes);
            const padded = tail_words * 8;
            if (padded > nbytes) {
                @memset(tail_ptr[nbytes..padded], 0);
            }
        }
        return value_mod.fromPtr(h);
    }

    fn makeSymbolInOldGen(gc: *GC, name_str: Value, hash: u64) !Value {
        const h = gc.old_gen.alloc(2) orelse return error.OutOfMemory;
        h.* = ObjHeader.init(.symbol, .old_gen, @intFromEnum(Kind.symbol), 2);
        const w0: *Value = @ptrFromInt(@intFromPtr(h) + 8);
        const w1: *u64 = @ptrFromInt(@intFromPtr(h) + 16);
        // Store as tagged Value so the GC layout table traces it during mark-sweep.
        w0.* = name_str;
        w1.* = hash;
        return value_mod.fromPtr(h);
    }

    pub fn intern(st: *SymbolTable, name: []const u8) !Value {
        if (st.map.get(name)) |existing| return existing;

        const name_val = try makeStringInOldGen(st.gc, name);
        const hash = std.hash.Wyhash.hash(0, name);
        const sym_val = try makeSymbolInOldGen(st.gc, name_val, hash);

        // Use the interned string body bytes as the hash-map key.
        const stored_name = objects.stringBytes(name_val);

        // Heap-allocate a stable slot for this symbol Value.
        const slot = try st.allocator.create(Value);
        slot.* = sym_val;
        errdefer st.allocator.destroy(slot);

        try st.slots.append(st.allocator, slot);
        errdefer _ = st.slots.pop();

        try st.map.put(stored_name, sym_val);

        // Register as a GC root (permanent).
        try st.gc.roots.addExtra(st.gc.allocator, slot);

        return sym_val;
    }

    pub fn count(st: *const SymbolTable) usize {
        return st.slots.items.len;
    }
};

pub var global_symbols: ?*SymbolTable = null;
