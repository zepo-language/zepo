//! Heap object header (u64 word).
//!
//! Layout:
//!   bit 0 = forward flag
//!     1 => bits 63:1 shifted-left-by-1 are the forwarding pointer target
//!     0 => normal header:
//!       bits  5:1  = Kind          (5 bits)   // zepo-or1d: widened from u4
//!       bits  7:6  = Space         (2 bits)
//!       bits 11:8  = age           (4 bits)
//!       bit  12    = mark
//!       bit  13    = pinned
//!       bits 29:14 = layout_desc_id (16 bits)
//!       bits 63:30 = size_words    (34 bits; body length in words)

const std = @import("std");

pub const Kind = enum(u5) { // zepo-or1d: widened u4->u5 to make room for ratio (slot 16)
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
    parameter = 14, // zepo-6o3p: parameter object — body [default(Value)][converter(Value, NIL=none)]
    bignum = 15, // zepo-nfak: arbitrary-precision exact integer — body[0]=(nlimbs<<1)|neg, body[1..]=limbs (raw, no traced children)
    ratio = 16, // zepo-or1d: exact rational — body[0]=numerator (Value), body[1]=denominator (Value); both fixnum-or-bignum, reduced, den>0, den!=1
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
    // zepo-or1d: Kind widened u4->u5, so every field above layout shifts up 1 bit
    // and size_words loses its top bit (35->34, still 16 Gword = plenty).
    pub const KIND_SHIFT: u6 = 1;
    pub const KIND_MASK: u64 = 0x1F << KIND_SHIFT; // bits 5:1
    pub const SPACE_SHIFT: u6 = 6;
    pub const SPACE_MASK: u64 = 0x3 << SPACE_SHIFT; // bits 7:6
    pub const AGE_SHIFT: u6 = 8;
    pub const AGE_MASK: u64 = 0xF << AGE_SHIFT; // bits 11:8
    pub const MARK_BIT: u64 = 1 << 12;
    pub const PINNED_BIT: u64 = 1 << 13;
    pub const LAYOUT_SHIFT: u6 = 14;
    pub const LAYOUT_MASK: u64 = 0xFFFF << LAYOUT_SHIFT; // bits 29:14
    pub const SIZE_SHIFT: u6 = 30;
    pub const SIZE_MASK: u64 = ((@as(u64, 1) << 34) - 1) << SIZE_SHIFT; // bits 63:30

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
        const bits: u5 = @intCast((h.word & KIND_MASK) >> KIND_SHIFT);
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

    pub inline fn sizeWords(h: ObjHeader) u34 { // zepo-or1d: 34-bit size field
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

    pub fn init(k: Kind, sp: Space, layout_id: u16, sz_words: u34) ObjHeader {
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
    try std.testing.expectEqual(@as(u34, 2), h.sizeWords());
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
