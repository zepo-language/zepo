//! Layout descriptor table.
//!
//! Each Kind has exactly one LayoutDesc telling the GC which word-offsets in the
//! object body hold Value references. This is the source of truth for tracing.

const std = @import("std");
const hdr = @import("header.zig");
const Kind = hdr.Kind;

pub const FieldKind = enum { value, raw_bytes, length_prefix };

pub const LayoutDesc = struct {
    kind: Kind,
    /// Fixed body size in words. 0 indicates variable (consult length slot).
    body_words: u16,
    /// Word offsets (within the body, 0 = first body word) that hold tagged Values.
    value_offsets: []const u16,
    /// True for objects with a raw byte tail after a length prefix (e.g. string).
    has_raw_tail: bool,
    /// Word offset of the length field within the body (for variable layouts).
    /// Undefined if body_words != 0.
    length_offset: u16,
    /// For variable-length Value-carrying objects (vector, env_frame) the
    /// "header" words before the Value slots. Traced slots are at
    /// `value_slots_start .. value_slots_start + length`.
    value_slots_start: u16 = 0,
    /// True => every slot from value_slots_start to end is a Value.
    all_slots_are_values: bool = false,
};

// Pre-declared singletons (kept outside the function for stable pointers).
const pair_offsets = [_]u16{ 0, 1 };
const closure_offsets = [_]u16{}; // closure captures are variable; traced via value_slots_start
const box_offsets = [_]u16{0};
const env_offsets = [_]u16{}; // env_frame slots traced via value_slots_start
const no_offsets = [_]u16{};
// Symbol body[0] = name string as tagged Value so mark-sweep traces it.
const symbol_offsets = [_]u16{0};
// Hash table body[1] = backing vector (Value). body[0] = len (raw).
const hash_table_offsets = [_]u16{1};

pub const LAYOUT_TABLE: [16]LayoutDesc = blk: {
    var t: [16]LayoutDesc = undefined;
    for (&t, 0..) |*slot, i| {
        slot.* = .{
            .kind = @enumFromInt(@as(u4, @intCast(i))),
            .body_words = 0,
            .value_offsets = &no_offsets,
            .has_raw_tail = false,
            .length_offset = 0,
        };
    }

    t[@intFromEnum(Kind.pair)] = .{
        .kind = .pair,
        .body_words = 2,
        .value_offsets = &pair_offsets,
        .has_raw_tail = false,
        .length_offset = 0,
    };

    t[@intFromEnum(Kind.string)] = .{
        .kind = .string,
        .body_words = 0, // variable (length stored in body[0])
        .value_offsets = &no_offsets,
        .has_raw_tail = true,
        .length_offset = 0,
    };

    t[@intFromEnum(Kind.symbol)] = .{
        .kind = .symbol,
        .body_words = 2, // body[0] = name string as tagged Value, body[1] = hash (raw)
        .value_offsets = &symbol_offsets,
        .has_raw_tail = false,
        .length_offset = 0,
    };

    t[@intFromEnum(Kind.closure)] = .{
        .kind = .closure,
        .body_words = 0, // variable
        .value_offsets = &closure_offsets,
        .has_raw_tail = false,
        .length_offset = 3, // body[0]=code_ptr raw, body[1]=arity, body[2]=home_env_ptr raw, captures follow
        .value_slots_start = 3,
        .all_slots_are_values = true,
    };

    t[@intFromEnum(Kind.prim)] = .{
        .kind = .prim,
        .body_words = 2, // fn_ptr, arity
        .value_offsets = &no_offsets,
        .has_raw_tail = false,
        .length_offset = 0,
    };

    t[@intFromEnum(Kind.vector)] = .{
        .kind = .vector,
        .body_words = 0, // variable
        .value_offsets = &no_offsets,
        .has_raw_tail = false,
        .length_offset = 0, // body[0] = length
        .value_slots_start = 1,
        .all_slots_are_values = true,
    };

    t[@intFromEnum(Kind.box)] = .{
        .kind = .box,
        .body_words = 1,
        .value_offsets = &box_offsets,
        .has_raw_tail = false,
        .length_offset = 0,
    };

    t[@intFromEnum(Kind.float)] = .{
        .kind = .float,
        .body_words = 1, // f64 payload (raw)
        .value_offsets = &no_offsets,
        .has_raw_tail = false,
        .length_offset = 0,
    };

    t[@intFromEnum(Kind.env_frame)] = .{
        .kind = .env_frame,
        .body_words = 0, // variable
        .value_offsets = &env_offsets,
        .has_raw_tail = false,
        .length_offset = 0, // body[0] = parent Value (or NIL)
        .value_slots_start = 0, // parent + slots all Values
        .all_slots_are_values = true,
    };

    t[@intFromEnum(Kind.foreign)] = .{
        .kind = .foreign,
        // body[0] = payload pointer (raw)
        // body[1] = deinit fn pointer (raw, 0 = none)
        // body[2] = type tag (raw u64)
        .body_words = 3,
        .value_offsets = &no_offsets,
        .has_raw_tail = false,
        .length_offset = 0,
    };

    t[@intFromEnum(Kind.hash_table)] = .{
        .kind = .hash_table,
        // body[0] = len (raw), body[1] = backing vector (Value of alternating k,v).
        .body_words = 2,
        .value_offsets = &hash_table_offsets,
        .has_raw_tail = false,
        .length_offset = 0,
    };

    break :blk t;
};

pub fn getLayout(id: u16) LayoutDesc {
    return LAYOUT_TABLE[id];
}

pub fn layoutForKind(k: Kind) LayoutDesc {
    return LAYOUT_TABLE[@intFromEnum(k)];
}

test "layout table sanity" {
    const p = getLayout(@intFromEnum(Kind.pair));
    try std.testing.expectEqual(Kind.pair, p.kind);
    try std.testing.expectEqual(@as(u16, 2), p.body_words);
    try std.testing.expectEqual(@as(usize, 2), p.value_offsets.len);

    const s = getLayout(@intFromEnum(Kind.string));
    try std.testing.expect(s.has_raw_tail);

    const v = getLayout(@intFromEnum(Kind.vector));
    try std.testing.expect(v.all_slots_are_values);
    try std.testing.expectEqual(@as(u16, 1), v.value_slots_start);
}
