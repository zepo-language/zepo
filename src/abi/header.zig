//! Heap object header (u64 word).
//!
//! Layout:
//!   bit 0 = forward flag
//!     1 => bits 63:1 shifted-left-by-1 are the forwarding pointer target
//!     0 => normal header:
//!       bits  4:1  = Kind          (4 bits)
//!       bits  6:5  = Space         (2 bits)
//!       bits 10:7  = age           (4 bits)
//!       bit  11    = mark
//!       bit  12    = pinned
//!       bits 28:13 = layout_desc_id (16 bits)
//!       bits 63:29 = size_words    (35 bits; body length in words)

const std = @import("std");

pub const Kind = enum(u4) {
    pair = 1,
    string = 2,
    symbol = 3,
    closure = 4,
    prim = 5,
    vector = 6,
    box = 7,
    float = 8,
    env_frame = 9,
    foreign = 10,
    hash_table = 11,
    bytevector = 12, // zepo-9qg
    fiber = 13, // zepo-4d6: fiber handle — body [status][result][fs_ptr]
    _,
};

pub const Space = enum(u2) {
    nursery_from = 0,
    nursery_to = 1,
    old_gen = 2,
    large_obj = 3,
};

pub const ObjHeader = extern struct {
    word: u64,

    // --- Bit field constants ---
    pub const KIND_SHIFT: u6 = 1;
    pub const KIND_MASK: u64 = 0xF << KIND_SHIFT; // bits 4:1
    pub const SPACE_SHIFT: u6 = 5;
    pub const SPACE_MASK: u64 = 0x3 << SPACE_SHIFT; // bits 6:5
    pub const AGE_SHIFT: u6 = 7;
    pub const AGE_MASK: u64 = 0xF << AGE_SHIFT; // bits 10:7
    pub const MARK_BIT: u64 = 1 << 11;
    pub const PINNED_BIT: u64 = 1 << 12;
    pub const LAYOUT_SHIFT: u6 = 13;
    pub const LAYOUT_MASK: u64 = 0xFFFF << LAYOUT_SHIFT; // bits 28:13
    pub const SIZE_SHIFT: u6 = 29;
    pub const SIZE_MASK: u64 = ((@as(u64, 1) << 35) - 1) << SIZE_SHIFT; // bits 63:29

    pub inline fn isForward(h: ObjHeader) bool {
        return (h.word & 1) == 1;
    }

    pub inline fn forwardTo(h: ObjHeader) *ObjHeader {
        // Clear forward bit and treat rest as pointer. Pointer was aligned to 8 bytes
        // so we stored it directly with bit 0 used as the forward flag.
        const addr: usize = @intCast(h.word & ~@as(u64, 1));
        return @ptrFromInt(addr);
    }

    pub inline fn setForward(h: *ObjHeader, target: *ObjHeader) void {
        const addr: usize = @intFromPtr(target);
        std.debug.assert(addr & 1 == 0); // 8-byte aligned => low 3 bits are 0
        h.word = @as(u64, addr) | 1;
    }

    pub inline fn kind(h: ObjHeader) Kind {
        const bits: u4 = @intCast((h.word & KIND_MASK) >> KIND_SHIFT);
        return @enumFromInt(bits);
    }

    pub inline fn space(h: ObjHeader) Space {
        const bits: u2 = @intCast((h.word & SPACE_MASK) >> SPACE_SHIFT);
        return @enumFromInt(bits);
    }

    pub inline fn age(h: ObjHeader) u4 {
        return @intCast((h.word & AGE_MASK) >> AGE_SHIFT);
    }

    pub inline fn marked(h: ObjHeader) bool {
        return (h.word & MARK_BIT) != 0;
    }

    pub inline fn pinned(h: ObjHeader) bool {
        return (h.word & PINNED_BIT) != 0;
    }

    pub inline fn layoutDescId(h: ObjHeader) u16 {
        return @intCast((h.word & LAYOUT_MASK) >> LAYOUT_SHIFT);
    }

    pub inline fn sizeWords(h: ObjHeader) u35 {
        return @intCast((h.word & SIZE_MASK) >> SIZE_SHIFT);
    }

    pub inline fn setMark(h: *ObjHeader) void {
        h.word |= MARK_BIT;
    }

    pub inline fn clearMark(h: *ObjHeader) void {
        h.word &= ~MARK_BIT;
    }

    pub inline fn setSpace(h: *ObjHeader, s: Space) void {
        h.word = (h.word & ~SPACE_MASK) | (@as(u64, @intFromEnum(s)) << SPACE_SHIFT);
    }

    pub inline fn setAge(h: *ObjHeader, a: u4) void {
        h.word = (h.word & ~AGE_MASK) | (@as(u64, a) << AGE_SHIFT);
    }

    pub inline fn incAge(h: *ObjHeader) void {
        const cur = h.age();
        const next: u4 = if (cur == 15) 15 else cur + 1;
        h.setAge(next);
    }

    pub fn init(k: Kind, sp: Space, layout_id: u16, sz_words: u35) ObjHeader {
        var w: u64 = 0;
        w |= (@as(u64, @intFromEnum(k)) << KIND_SHIFT);
        w |= (@as(u64, @intFromEnum(sp)) << SPACE_SHIFT);
        w |= (@as(u64, layout_id) << LAYOUT_SHIFT);
        w |= (@as(u64, sz_words) << SIZE_SHIFT);
        return .{ .word = w };
    }
};

test "header round-trip" {
    var h = ObjHeader.init(.pair, .nursery_from, 0, 2);
    try std.testing.expect(!h.isForward());
    try std.testing.expectEqual(Kind.pair, h.kind());
    try std.testing.expectEqual(Space.nursery_from, h.space());
    try std.testing.expectEqual(@as(u16, 0), h.layoutDescId());
    try std.testing.expectEqual(@as(u35, 2), h.sizeWords());
    try std.testing.expectEqual(@as(u4, 0), h.age());
    try std.testing.expect(!h.marked());

    h.setMark();
    try std.testing.expect(h.marked());
    h.clearMark();
    try std.testing.expect(!h.marked());

    h.setSpace(.old_gen);
    try std.testing.expectEqual(Space.old_gen, h.space());

    h.incAge();
    h.incAge();
    try std.testing.expectEqual(@as(u4, 2), h.age());
}

test "header forward pointer" {
    var a = ObjHeader.init(.pair, .nursery_from, 0, 2);
    var b = ObjHeader.init(.pair, .nursery_to, 0, 2);
    a.setForward(&b);
    try std.testing.expect(a.isForward());
    try std.testing.expectEqual(&b, a.forwardTo());
}
