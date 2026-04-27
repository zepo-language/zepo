//! Safepoint / root map ABI.
//!
//! The code generator emits a RootMap entry for each safepoint ID describing
//! which stack slots and registers hold live Values. The GC consults these at
//! collection time to discover frame-local roots.

const std = @import("std");

pub const SafepointId = u32;

pub const RootMapEntry = struct {
    sp_id: SafepointId,
    /// Byte offsets from the frame base of live Value slots at this safepoint.
    stack_slot_offsets: []const u16,
    /// Bitmask of registers currently holding live Values.
    reg_mask: u32,
};

pub const RootMap = struct {
    entries: []RootMapEntry,

    pub fn find(rm: *RootMap, sp_id: SafepointId) ?*RootMapEntry {
        // Linear scan; could switch to binary search if sorted.
        for (rm.entries) |*e| {
            if (e.sp_id == sp_id) return e;
        }
        return null;
    }
};

test "root map find" {
    const e1 = RootMapEntry{ .sp_id = 1, .stack_slot_offsets = &.{}, .reg_mask = 0 };
    const e2 = RootMapEntry{ .sp_id = 7, .stack_slot_offsets = &.{}, .reg_mask = 0x3 };
    var entries = [_]RootMapEntry{ e1, e2 };
    var rm = RootMap{ .entries = &entries };
    try std.testing.expect(rm.find(7) != null);
    try std.testing.expect(rm.find(99) == null);
}
