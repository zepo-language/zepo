//! Safepoint insertion and loop-backedge analysis.

const std = @import("std");
const ops = @import("ops.zig");
const Op = ops.Op;
const Label = ops.Label;
const Function = ops.Function;
const SafepointId = @import("../abi/mod.zig").safepoint.SafepointId;

/// Ensure that every call and allocation op has a preceding `safepoint`.
/// If the immediate predecessor is not a safepoint, insert one.
pub fn insertSafepoints(func: *Function) !void {
    var new_ops = std.ArrayListUnmanaged(Op).empty;
    errdefer new_ops.deinit(func.allocator);

    var last_was_sp = false;
    var next_id: SafepointId = 1_000_000; // distinct id space for late insertion

    for (func.ops.items) |op| {
        const needs_sp = switch (op) {
            .call, .alloc_pair, .make_closure, .alloc_box, .prim_call => true,
            else => false,
        };
        if (needs_sp and !last_was_sp) {
            try new_ops.append(func.allocator, .{ .safepoint = .{ .id = next_id } });
            next_id += 1;
        }
        try new_ops.append(func.allocator, op);
        last_was_sp = switch (op) {
            .safepoint => true,
            else => false,
        };
    }

    func.ops.deinit(func.allocator);
    func.ops = new_ops;
}

/// Identify backedges: for each `branch` to a previously-placed label, that
/// branch is a loop backedge.
pub const Backedge = struct {
    branch_index: usize,
    target: Label,
};

pub fn identifyBackedges(func: *Function) !std.ArrayList(Backedge) {
    var label_positions = std.AutoHashMap(Label, usize).init(func.allocator);
    defer label_positions.deinit();

    // First pass: record label positions.
    for (func.ops.items, 0..) |op, i| {
        if (op == .label) try label_positions.put(op.label.id, i);
    }

    var result = std.ArrayListUnmanaged(Backedge).empty;
    for (func.ops.items, 0..) |op, i| {
        if (op == .branch) {
            if (label_positions.get(op.branch.label)) |pos| {
                if (pos < i) {
                    try result.append(func.allocator, .{ .branch_index = i, .target = op.branch.label });
                }
            }
        }
    }
    return result;
}
