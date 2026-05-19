//! Conservative liveness at safepoints.

const std = @import("std");
const ops = @import("ops.zig");
const Op = ops.Op;
const Reg = ops.Reg;
const Function = ops.Function;

/// Conservative: every reg that has been written before a safepoint and
/// hasn't been (definitively) clobbered is considered live. For now we
/// simply record every reg written so far at each safepoint.
pub fn computeLiveness(func: *Function) !void {
    // Clear prior root maps.
    func.root_maps.clearRetainingCapacity();
    for (func.reg_lists.items) |l| func.allocator.free(l);
    func.reg_lists.clearRetainingCapacity();

    var written = std.ArrayListUnmanaged(Reg).empty;
    defer written.deinit(func.allocator);

    for (func.ops.items) |op| {
        switch (op) {
            .safepoint => |sp| {
                try func.recordRootMap(sp.id, written.items);
            },
            .call => |c| {
                try func.recordRootMap(c.safepoint, written.items);
            },
            .alloc_pair => |ap| {
                try func.recordRootMap(ap.safepoint, written.items);
            },
            .prim_call => |p| {
                try func.recordRootMap(p.safepoint, written.items);
            },
            else => {},
        }
        // Track writes.
        if (writeDst(op)) |r| {
            if (!contains(written.items, r)) try written.append(func.allocator, r);
        }
    }
}

fn writeDst(op: Op) ?Reg {
    return switch (op) {
        .load_const => |x| x.dst,
        .load_string => |x| x.dst,
        .load_float => |x| x.dst,
        .load_nil => |x| x.dst,
        .load_true => |x| x.dst,
        .load_false => |x| x.dst,
        .load_local => |x| x.dst,
        .load_global => |x| x.dst,
        .alloc_box => |x| x.dst,
        .load_box => |x| x.dst,
        .cons => |x| x.dst,
        .car => |x| x.dst,
        .cdr => |x| x.dst,
        .make_closure => |x| x.dst,
        .load_capture => |x| x.dst,
        .call => |x| x.dst,
        .alloc_pair => |x| x.dst,
        .prim_call => |x| x.dst,
        else => null,
    };
}

fn contains(list: []const Reg, r: Reg) bool {
    for (list) |x| if (x == r) return true;
    return false;
}
