//! FFI phase-6: GC-pressure and finalizer-correctness tests.
//!
//! Validates that finalizers run exactly once per handle regardless of
//! allocation volume, container-level reachability (pair, vector), and
//! across JSON-driven StringPayload churn.

const std = @import("std");
const zepo = @import("zepo");
const abi = zepo.abi;
const gcmod = zepo.gc;
const runtime = zepo.runtime;
const objects = runtime.objects;
const value_mod = abi.value;

var finalize_count: usize = 0;

fn countingDeinit(payload: ?*anyopaque) callconv(.c) void {
    _ = payload;
    finalize_count += 1;
}

test "stress: 1000 unreachable handles all finalize" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    finalize_count = 0;
    const N: usize = 1000;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        _ = try objects.makeForeign(&gc, null, &countingDeinit, @as(u64, i));
    }
    try gc.major();
    try std.testing.expectEqual(N, finalize_count);

    // Second major must not re-fire.
    try gc.major();
    try std.testing.expectEqual(N, finalize_count);
}

test "stress: handles reachable through a rooted pair survive major GC" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    finalize_count = 0;

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const h = try objects.makeForeign(&gc, null, &countingDeinit, 1);
    const pair = try objects.makePair(&gc, h, value_mod.NIL);
    _ = scope.push(pair);

    try gc.major();
    try std.testing.expectEqual(@as(usize, 0), finalize_count);

    try gc.major();
    try std.testing.expectEqual(@as(usize, 0), finalize_count);
}

test "stress: vector of handles — container rooted keeps all alive" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    finalize_count = 0;

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const N: usize = 32;
    const vec = try objects.makeVector(&gc, N, value_mod.NIL);
    const vec_slot = scope.push(vec);

    // Fill with handles (each with its own finalizer side-effect counter).
    var i: usize = 0;
    while (i < N) : (i += 1) {
        const h = try objects.makeForeign(&gc, null, &countingDeinit, @as(u64, i));
        objects.vectorSet(&gc, vec_slot.*, i, h);
    }

    try gc.major();
    try std.testing.expectEqual(@as(usize, 0), finalize_count);
}

test "stress: drop container, all handles finalize" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    finalize_count = 0;

    const N: usize = 32;
    {
        var scope = gcmod.HandleScope{};
        gc.roots.pushHandleScope(&scope);
        defer gc.roots.popHandleScope();

        const vec = try objects.makeVector(&gc, N, value_mod.NIL);
        const vec_slot = scope.push(vec);

        var i: usize = 0;
        while (i < N) : (i += 1) {
            const h = try objects.makeForeign(&gc, null, &countingDeinit, @as(u64, i));
            objects.vectorSet(&gc, vec_slot.*, i, h);
        }

        try gc.major();
        try std.testing.expectEqual(@as(usize, 0), finalize_count);
    }
    // Scope dropped — vector + contained handles unreachable.
    try gc.major();
    try std.testing.expectEqual(N, finalize_count);
}

test "stress: JSON parse churn does not leak StringPayload" {
    // Exercises src/ffi/json.zig's marshalling which allocates no FFI
    // StringPayload (it reifies straight to lisp strings) — but the json
    // primitive itself calls std.json.parseFromSlice which allocates
    // internally and frees via parsed.deinit(). This run confirms the
    // end-to-end path under many iterations has no std-allocator leak.
    const alloc = std.testing.allocator;
    var gc = try zepo.GC.init(alloc);
    defer gc.deinit();
    var syms = try runtime.SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var globals = try runtime.GlobalEnv.init(&gc, alloc);
    defer globals.deinit();
    try zepo.prims.registerAll(&gc, &globals, &syms);
    var ctx = try runtime.EvalContext.init(&gc, &syms, &globals, alloc);
    defer ctx.deinit();
    try runtime.loadStdlib(&ctx);

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        _ = try ctx.evalString(
            \\(json-parse "{\"name\":\"Ada\",\"nums\":[1,2,3,4,5]}")
        , "<stress>");
    }

    try gc.major();
    // If we reach here without the testing allocator complaining, no leak.
}
