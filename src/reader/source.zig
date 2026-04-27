//! Source position tracking and per-object span side table.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

pub const Pos = struct {
    line: u32,
    col: u32,
    offset: u32,
};

pub const Span = struct {
    start: Pos,
    end: Pos,
    file: []const u8,
};

/// Maps object identity (raw pointer bits) to its originating Span.
pub const SpanTable = struct {
    map: std.AutoHashMap(usize, Span),

    pub fn init(allocator: std.mem.Allocator) SpanTable {
        return .{ .map = std.AutoHashMap(usize, Span).init(allocator) };
    }

    pub fn deinit(st: *SpanTable) void {
        st.map.deinit();
    }

    pub fn record(st: *SpanTable, val: Value, span: Span) !void {
        if (!value_mod.isPtr(val)) return;
        const key: usize = @intCast(val);
        try st.map.put(key, span);
    }

    pub fn get(st: *SpanTable, val: Value) ?Span {
        if (!value_mod.isPtr(val)) return null;
        const key: usize = @intCast(val);
        return st.map.get(key);
    }
};
