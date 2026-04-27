//! Tagged u64 Value representation.
//!
//! Low 3 bits tag:
//!   000 = heap pointer (8-byte aligned, low 3 bits are zero)
//!   001 = fixnum (shifted by 1; i63)
//!   010 = character (Unicode codepoint in bits 23:3)
//!   011 = special immediate (nil, #t, #f)
//!
//! Floats are heap-allocated (Kind.float).

const std = @import("std");
const header = @import("header.zig");
const ObjHeader = header.ObjHeader;

pub const Value = u64;

pub const NIL: Value = 0x03;
pub const FALSE: Value = 0x0B;
pub const TRUE: Value = 0x13;

pub const Tag = enum(u3) {
    ptr = 0,
    fixnum = 1,
    char = 2,
    special = 3,
    _,
};

pub const TAG_MASK: u64 = 0b111;

pub inline fn tag(v: Value) Tag {
    return @enumFromInt(@as(u3, @intCast(v & TAG_MASK)));
}

pub inline fn isNil(v: Value) bool {
    return v == NIL;
}

/// Per spec, only `#f` and `()` are falsy.
pub inline fn isFalse(v: Value) bool {
    return v == FALSE or v == NIL;
}

pub inline fn isFalsy(v: Value) bool {
    return v == FALSE or v == NIL;
}

pub inline fn isTruthy(v: Value) bool {
    return !isFalsy(v);
}

pub inline fn isPtr(v: Value) bool {
    // A heap pointer has low 3 bits = 000 AND is nonzero.
    return (v & TAG_MASK) == 0 and v != 0;
}

pub inline fn isFixnum(v: Value) bool {
    return (v & TAG_MASK) == @intFromEnum(Tag.fixnum);
}

pub inline fn isChar(v: Value) bool {
    return (v & TAG_MASK) == @intFromEnum(Tag.char);
}

pub inline fn isSpecial(v: Value) bool {
    return (v & TAG_MASK) == @intFromEnum(Tag.special);
}

pub inline fn fixnum(n: i63) Value {
    // Encode i63 into bits 63:3. Low 3 bits are the fixnum tag (001).
    const u: u63 = @bitCast(n);
    const wide: u64 = @as(u64, u);
    return (wide << 3) | @intFromEnum(Tag.fixnum);
}

pub inline fn fixnumVal(v: Value) i63 {
    std.debug.assert(isFixnum(v));
    // Arithmetic shift to preserve sign: interpret as i64, shift by 3.
    const as_i64: i64 = @bitCast(v);
    const shifted: i64 = as_i64 >> 3;
    return @intCast(shifted);
}

pub inline fn char(cp: u21) Value {
    return (@as(u64, cp) << 3) | @intFromEnum(Tag.char);
}

pub inline fn charVal(v: Value) u21 {
    std.debug.assert(isChar(v));
    return @intCast((v >> 3) & 0x1FFFFF);
}

pub inline fn ptrVal(v: Value) *ObjHeader {
    std.debug.assert(isPtr(v));
    const addr: usize = @intCast(v);
    return @ptrFromInt(addr);
}

pub inline fn fromPtr(p: *ObjHeader) Value {
    const addr: usize = @intFromPtr(p);
    std.debug.assert(addr & TAG_MASK == 0);
    return @as(Value, addr);
}

test "immediates" {
    try std.testing.expect(isNil(NIL));
    try std.testing.expect(isFalse(FALSE));
    try std.testing.expect(isFalsy(NIL));
    try std.testing.expect(isFalsy(FALSE));
    try std.testing.expect(!isFalsy(TRUE));
    try std.testing.expect(isTruthy(TRUE));
    try std.testing.expect(isSpecial(NIL));
    try std.testing.expect(isSpecial(TRUE));
}

test "fixnums" {
    const nums = [_]i63{ 0, 1, -1, 42, -42, 1 << 30, -(1 << 30) };
    for (nums) |n| {
        const v = fixnum(n);
        try std.testing.expect(isFixnum(v));
        try std.testing.expectEqual(n, fixnumVal(v));
    }
}

test "chars" {
    const cps = [_]u21{ 0, 'A', 'z', 0x1F600, 0x10FFFF };
    for (cps) |c| {
        const v = char(c);
        try std.testing.expect(isChar(v));
        try std.testing.expectEqual(c, charVal(v));
    }
}

test "pointers" {
    var h = header.ObjHeader.init(.pair, .nursery_from, 0, 2);
    const v = fromPtr(&h);
    try std.testing.expect(isPtr(v));
    try std.testing.expectEqual(&h, ptrVal(v));
}
