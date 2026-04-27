//! GC test: foreign-handle finalizer semantics.
//!
//! Foreign handles allocate directly into old-gen and carry a deinit fn.
//! The fn runs exactly once when the handle is swept during a major GC,
//! and never runs while the handle is reachable from roots.

const std = @import("std");
const zepo = @import("zepo");
const abi = zepo.abi;
const gcmod = zepo.gc;
const runtime = zepo.runtime;
const objects = runtime.objects;

const value_mod = abi.value;

// Shared counter for finalizer invocations. Tests reset before each case.
var finalize_count: usize = 0;

fn countingDeinit(payload: ?*anyopaque) callconv(.c) void {
    _ = payload;
    finalize_count += 1;
}

test "foreign: finalizer runs on major GC for unreachable handle" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    finalize_count = 0;

    // Allocate without rooting — handle is immediately unreachable.
    _ = try objects.makeForeign(&gc, null, &countingDeinit, 0xCAFE);

    try gc.major();
    try std.testing.expectEqual(@as(usize, 1), finalize_count);
}

test "foreign: finalizer does not run while handle is rooted" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    finalize_count = 0;

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const handle = try objects.makeForeign(&gc, null, &countingDeinit, 0xBEEF);
    _ = scope.push(handle);

    try gc.major();
    try std.testing.expectEqual(@as(usize, 0), finalize_count);

    try gc.major();
    try std.testing.expectEqual(@as(usize, 0), finalize_count);
}

test "foreign: finalizer runs once after root is dropped" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    finalize_count = 0;

    {
        var scope = gcmod.HandleScope{};
        gc.roots.pushHandleScope(&scope);
        defer gc.roots.popHandleScope();

        const handle = try objects.makeForeign(&gc, null, &countingDeinit, 0x1234);
        _ = scope.push(handle);

        try gc.major();
        try std.testing.expectEqual(@as(usize, 0), finalize_count);
    }
    // Root scope dropped; next major should reclaim + finalize.
    try gc.major();
    try std.testing.expectEqual(@as(usize, 1), finalize_count);

    // A subsequent major must not re-fire.
    try gc.major();
    try std.testing.expectEqual(@as(usize, 1), finalize_count);
}

test "foreign: null deinit is a no-op" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    finalize_count = 0;

    // No deinit function; reclaim should not crash and counter stays 0.
    _ = try objects.makeForeign(&gc, null, null, 0);

    try gc.major();
    try std.testing.expectEqual(@as(usize, 0), finalize_count);
}

test "foreign: payload round-trips + type tag preserved" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    finalize_count = 0;

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    var owned_int: i64 = 0xDEAD_BEEF;
    const handle = try objects.makeForeign(&gc, @ptrCast(&owned_int), null, 0x9999);
    _ = scope.push(handle);

    try std.testing.expect(objects.isForeign(handle));
    try std.testing.expectEqual(@as(u64, 0x9999), objects.foreignTypeTag(handle));
    const p: *i64 = @ptrCast(@alignCast(objects.foreignPayload(handle).?));
    try std.testing.expectEqual(@as(i64, 0xDEAD_BEEF), p.*);
}

test "foreign: many unreachable handles all finalize" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    finalize_count = 0;

    const N: usize = 50;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        _ = try objects.makeForeign(&gc, null, &countingDeinit, @as(u64, i));
    }

    try gc.major();
    try std.testing.expectEqual(N, finalize_count);
}
