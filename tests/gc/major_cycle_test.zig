//! Regression for zepo-zjb: the major-GC mark phase recursed into nursery
//! survivors without a visited guard (the nursery has no mark bit), so a
//! reachable young->young cycle (e.g. (set-cdr! x x) while x is young) made
//! oldgen.zig markValue/traceChildren recurse forever — a stack-overflow
//! crash during an ordinary major GC. Found by the zepo-a69 soak at high
//! iteration counts.

const std = @import("std");
const zepo = @import("zepo");
const abi = zepo.abi;
const gcmod = zepo.gc;

const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const value_mod = abi.value;
const Kind = abi.Kind;
const WORD: usize = 8;

// zepo-zjb
fn bodyP(h: *ObjHeader) [*]Value {
    return @ptrCast(@alignCast(@as([*]u8, @ptrCast(h)) + WORD));
}

// An old-gen holder pair (body 2 == size class 0 exactly, so its header size
// matches its block — keeps the old-gen heap walkable). car holds the graph
// under test; cdr is NIL.
fn oldHolder(gc: *gcmod.GC) !*ObjHeader {
    const h = gc.old_gen.alloc(2) orelse return error.TestUnexpected;
    h.* = ObjHeader.init(.pair, .old_gen, @intFromEnum(Kind.pair), 2);
    bodyP(h)[0] = value_mod.NIL;
    bodyP(h)[1] = value_mod.NIL;
    return h;
}

test "zepo-zjb: major GC over a young self-cycle reachable from old-gen terminates" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const holder = try oldHolder(&gc);
    _ = scope.push(value_mod.fromPtr(holder));

    // Young pair P with a self-cycle: P.cdr = P.
    const p_h = try gc.alloc(.pair, 2);
    bodyP(p_h)[0] = value_mod.fixnum(1);
    bodyP(p_h)[1] = value_mod.fromPtr(p_h); // self-cycle (young)
    const p_val = value_mod.fromPtr(p_h);

    // Link holder.car -> P via the write barrier (old->young edge).
    gc.writeBarrier(holder, &bodyP(holder)[0], p_val);
    bodyP(holder)[0] = p_val;

    // Major GC must TERMINATE (pre-fix: stack overflow in markValue).
    try gc.major();
    try gcmod.Verifier.verify(&gc);

    // holder.car still points at a live pair whose car is 1, cycle intact.
    const e = bodyP(holder)[0];
    try std.testing.expect(value_mod.isPtr(e));
    try std.testing.expectEqual(@as(i63, 1), value_mod.fixnumVal(bodyP(value_mod.ptrVal(e))[0]));
    try std.testing.expect(value_mod.isPtr(bodyP(value_mod.ptrVal(e))[1])); // P.cdr still a ptr
}

test "zepo-zjb: major GC over a 2-cycle of young pairs reachable from old-gen terminates" {
    const alloc = std.testing.allocator;
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();

    var scope = gcmod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const holder = try oldHolder(&gc);
    _ = scope.push(value_mod.fromPtr(holder));

    // A.cdr = B, B.cdr = A — both young.
    const a = try gc.alloc(.pair, 2);
    const b = try gc.alloc(.pair, 2);
    bodyP(a)[0] = value_mod.fixnum(1);
    bodyP(a)[1] = value_mod.fromPtr(b);
    bodyP(b)[0] = value_mod.fixnum(2);
    bodyP(b)[1] = value_mod.fromPtr(a);

    const a_val = value_mod.fromPtr(a);
    gc.writeBarrier(holder, &bodyP(holder)[0], a_val);
    bodyP(holder)[0] = a_val;

    try gc.major();
    try gcmod.Verifier.verify(&gc);

    const e = bodyP(holder)[0];
    try std.testing.expect(value_mod.isPtr(e));
    try std.testing.expectEqual(@as(i63, 1), value_mod.fixnumVal(bodyP(value_mod.ptrVal(e))[0]));
}
