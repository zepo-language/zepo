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
// zepo-s4p
pub const EOF_VAL: Value = 0x1B; // special immediate for the EOF singleton

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

// zepo-s4p
pub inline fn isEof(v: Value) bool {
    return v == EOF_VAL;
}

// zepo-9usm: the fixnum payload occupies bits 63:3 — a 61-bit two's-complement
// field — so the exact representable range is [-2^60, 2^60-1], NOT the i63 the
// encoder parameter suggests (the i63 type + a since-removed 1-bit-tag design
// left that mismatch behind). Every producer of a fixnum — the encoder below,
// the arithmetic overflow guards, the reader, and the FFI marshallers — MUST
// gate on this range and promote anything outside it to a boxed float. Use
// fixnumFits as the single source of truth for that bound.
pub const FIXNUM_MAX: i64 = (1 << 60) - 1;
pub const FIXNUM_MIN: i64 = -(1 << 60);

pub inline fn fixnumFits(n: i64) bool {
    return n >= FIXNUM_MIN and n <= FIXNUM_MAX;
}

pub inline fn fixnum(n: i63) Value {
    // Encode into bits 63:3. Low 3 bits are the fixnum tag (001).
    std.debug.assert(fixnumFits(@as(i64, n))); // zepo-9usm: out-of-range = producer bug
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
    // zepo-9usm: include the true payload boundaries — the round-trip must hold
    // exactly at FIXNUM_MAX/FIXNUM_MIN, which is the whole range the encoder
    // can represent.
    const nums = [_]i63{ 0, 1, -1, 42, -42, 1 << 30, -(1 << 30), @intCast(FIXNUM_MAX), @intCast(FIXNUM_MIN) };
    for (nums) |n| {
        const v = fixnum(n);
        try std.testing.expect(isFixnum(v));
        try std.testing.expectEqual(n, fixnumVal(v));
    }
}

test "fixnumFits bounds" {
    // zepo-9usm: the guard the whole codebase keys off of.
    try std.testing.expect(fixnumFits(FIXNUM_MAX));
    try std.testing.expect(fixnumFits(FIXNUM_MIN));
    try std.testing.expect(fixnumFits(0));
    try std.testing.expect(!fixnumFits(FIXNUM_MAX + 1));
    try std.testing.expect(!fixnumFits(FIXNUM_MIN - 1));
    try std.testing.expect(!fixnumFits(std.math.maxInt(i64)));
    try std.testing.expect(!fixnumFits(std.math.minInt(i64)));
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
