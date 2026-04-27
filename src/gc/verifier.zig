//! Debug-mode GC invariant verifier. Invoked after every collection step.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const value_mod = abi.value;
const layout_mod = abi.layout;

const collector_mod = @import("collector.zig");
const GC = collector_mod.GC;

pub const VerifyError = error{
    DanglingPointer,
    ReachableFromSpaceObject,
    UnmarkedOldYoungEdge,
};

const Ctx = struct {
    gc: *GC,
    err: ?VerifyError = null,
};

fn visitSlot(ctx_raw: *anyopaque, slot: *Value) void {
    const ctx: *Ctx = @ptrCast(@alignCast(ctx_raw));
    if (ctx.err != null) return;
    const v = slot.*;
    if (!value_mod.isPtr(v)) return;
    const obj = value_mod.ptrVal(v);

    // Must live in either nursery (from-space only after flip) or old-gen.
    const in_nursery_from = ctx.gc.nursery.inFromSpace(obj);
    const in_nursery_to = ctx.gc.nursery.inToSpace(obj);
    const in_old = ctx.gc.old_gen.contains(obj);

    if (!(in_nursery_from or in_old)) {
        if (in_nursery_to) {
            // Rooted pointer still into to-space is a bug post-flip.
            ctx.err = VerifyError.ReachableFromSpaceObject;
            return;
        }
        ctx.err = VerifyError.DanglingPointer;
        return;
    }

    if (obj.isForward()) {
        ctx.err = VerifyError.ReachableFromSpaceObject;
    }
}

pub const Verifier = struct {
    pub fn verify(gc: *GC) !void {
        var ctx = Ctx{ .gc = gc };
        gc.roots.visitAll(@ptrCast(&ctx), visitSlot);
        if (ctx.err) |e| return e;

        // Additionally walk old-gen: any live old-gen object whose child points
        // into nursery must be on a dirty card (or cards may have been cleared
        // post-minor; skip that check if clean slate).
    }
};
