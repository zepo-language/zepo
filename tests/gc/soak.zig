//! Seeded randomized GC soak. Drives a randomized object graph through random
//! allocation / mutation / root-drop / collection, asserting the invariant
//! verifier after every collection. Reproducible: a failure prints its seed.
//!
//! Tunables (env):
//!   ZEPO_GC_SOAK_SEED   default 0x5EED
//!   ZEPO_GC_SOAK_ITERS  default 200_000
//!
//! Run: zig build gc_soak

const std = @import("std");
const zepo = @import("zepo");
const abi = zepo.abi;
const gcmod = zepo.gc;

const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const value_mod = abi.value;
const Kind = abi.Kind;
const WORD: usize = 8;

// zepo-a69
fn bodyP(h: *ObjHeader) [*]Value {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
}

// Match the codebase's env-reading pattern (trace.zig): libc getenv.
fn envU64(name: [*:0]const u8, default: u64) u64 {
    const v = std.c.getenv(name) orelse return default;
    return std.fmt.parseInt(u64, std.mem.span(v), 0) catch default;
}

const POP = 256; // rooted population size

test "soak: randomized graph stays invariant-clean" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    const seed = envU64("ZEPO_GC_SOAK_SEED", 0x5EED);
    const iters = envU64("ZEPO_GC_SOAK_ITERS", 200_000);
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    // Rooted population: a vector of POP slots, each holding an object (or NIL).
    // The vector itself is rooted via a handle, so all slots are reachable.
    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const pop_h = try gc.alloc(.vector, 1 + POP);
    {
        const raw: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(pop_h)) + WORD));
        raw[0] = @as(u64, POP);
        var i: usize = 0;
        while (i < POP) : (i += 1) bodyP(pop_h)[1 + i] = value_mod.NIL;
    }
    const pop = scope.push(value_mod.fromPtr(pop_h));

    var it: u64 = 0;
    while (it < iters) : (it += 1) {
        const slot_idx = rng.uintLessThan(usize, POP);
        const action = rng.uintLessThan(u8, 10);

        // The population vector may have promoted; re-fetch its header each
        // iteration and use the write barrier for every store into it.
        const vh = value_mod.ptrVal(pop.*);

        switch (action) {
            0, 1, 2, 3 => {
                // Allocate a fresh small object and store it into a slot.
                const k = rng.uintLessThan(u8, 3);
                const nv = switch (k) {
                    0 => try makePair(&gc, value_mod.fixnum(@intCast(it & 0xffff)), value_mod.NIL),
                    1 => try makeVecSmall(&gc, rng),
                    else => try makeBox(&gc, value_mod.fixnum(@intCast(slot_idx))),
                };
                const vh2 = value_mod.ptrVal(pop.*); // alloc may have collected/moved
                gc.writeBarrier(vh2, &bodyP(vh2)[1 + slot_idx], nv);
                bodyP(vh2)[1 + slot_idx] = nv;
            },
            4 => {
                // Drop a root.
                gc.writeBarrier(vh, &bodyP(vh)[1 + slot_idx], value_mod.NIL);
                bodyP(vh)[1 + slot_idx] = value_mod.NIL;
            },
            5, 6, 7 => {
                // Mutate: point one slot's pair.cdr at another slot's object.
                const e = bodyP(vh)[1 + slot_idx];
                if (value_mod.isPtr(e) and value_mod.ptrVal(e).kind() == .pair) {
                    const other = bodyP(vh)[1 + rng.uintLessThan(usize, POP)];
                    const eh = value_mod.ptrVal(e);
                    gc.writeBarrier(eh, &bodyP(eh)[1], other);
                    bodyP(eh)[1] = other;
                }
            },
            8 => {
                try gc.minor();
                try gcmod.Verifier.verify(&gc);
            },
            else => {
                try gc.major();
                try gcmod.Verifier.verify(&gc);
            },
        }
    }

    // Final collection + verify.
    try gc.major();
    gcmod.Verifier.verify(&gc) catch |e| {
        std.debug.print("\nSOAK FAILED with seed=0x{x} iters={d}: {s}\n", .{ seed, iters, @errorName(e) });
        return e;
    };
}

fn makePair(gc: *gcmod.GC, car: Value, cdr: Value) !Value {
    const h = try gc.alloc(.pair, 2);
    bodyP(h)[0] = car;
    bodyP(h)[1] = cdr;
    return value_mod.fromPtr(h);
}

fn makeBox(gc: *gcmod.GC, v: Value) !Value {
    const h = try gc.alloc(.box, 1);
    bodyP(h)[0] = v;
    return value_mod.fromPtr(h);
}

fn makeVecSmall(gc: *gcmod.GC, rng: std.Random) !Value {
    const len = 1 + rng.uintLessThan(usize, 8);
    const h = try gc.alloc(.vector, 1 + len);
    const raw: [*]u64 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
    raw[0] = @as(u64, len);
    var i: usize = 0;
    while (i < len) : (i += 1) bodyP(h)[1 + i] = value_mod.NIL;
    return value_mod.fromPtr(h);
}
