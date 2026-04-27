//! Card table for the generational write barrier.
//!
//! Each byte in `table` covers CARD_SIZE bytes of the old-gen address space.
//! 0 = clean, 1 = dirty (may contain old->young edges).

const std = @import("std");

pub const CARD_SIZE: usize = 4096;

pub const CardTable = struct {
    table: []u8,
    heap_base: usize,
    heap_size: usize,

    pub fn init(allocator: std.mem.Allocator, heap_base: usize, heap_size: usize) !CardTable {
        const n_cards = (heap_size + CARD_SIZE - 1) / CARD_SIZE;
        const t = try allocator.alloc(u8, n_cards);
        @memset(t, 0);
        return .{ .table = t, .heap_base = heap_base, .heap_size = heap_size };
    }

    pub fn deinit(ct: *CardTable, allocator: std.mem.Allocator) void {
        allocator.free(ct.table);
        ct.* = undefined;
    }

    pub inline fn cardIndexFor(ct: *const CardTable, obj_addr: usize) usize {
        std.debug.assert(obj_addr >= ct.heap_base);
        return (obj_addr - ct.heap_base) / CARD_SIZE;
    }

    pub inline fn markCard(ct: *CardTable, obj_addr: usize) void {
        if (obj_addr < ct.heap_base or obj_addr >= ct.heap_base + ct.heap_size) return;
        const idx = (obj_addr - ct.heap_base) / CARD_SIZE;
        if (idx < ct.table.len) ct.table[idx] = 1;
    }

    pub inline fn isCardDirty(ct: *const CardTable, card_idx: usize) bool {
        return ct.table[card_idx] != 0;
    }

    pub fn clearAll(ct: *CardTable) void {
        @memset(ct.table, 0);
    }

    pub fn cardStart(ct: *const CardTable, idx: usize) usize {
        return ct.heap_base + idx * CARD_SIZE;
    }

    pub fn cardEnd(ct: *const CardTable, idx: usize) usize {
        return @min(ct.heap_base + (idx + 1) * CARD_SIZE, ct.heap_base + ct.heap_size);
    }
};

test "card table basic" {
    const alloc = std.testing.allocator;
    var ct = try CardTable.init(alloc, 0x10000, 16 * 1024);
    defer ct.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 4), ct.table.len);
    try std.testing.expect(!ct.isCardDirty(0));

    ct.markCard(0x10000);
    try std.testing.expect(ct.isCardDirty(0));

    ct.markCard(0x10000 + CARD_SIZE + 8);
    try std.testing.expect(ct.isCardDirty(1));

    // Out-of-range marks are ignored.
    ct.markCard(0x10000 + 1_000_000);

    ct.clearAll();
    try std.testing.expect(!ct.isCardDirty(0));
    try std.testing.expect(!ct.isCardDirty(1));
}
