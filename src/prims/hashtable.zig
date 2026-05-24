//! Primitive wrappers for first-class hash tables.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const hashtable = @import("../runtime/hashtable.zig");
const HandleScope = @import("../gc/collector.zig").HandleScope;

const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;

const errors = @import("../runtime/errors.zig");
const LispError = errors.LispError;

pub fn primMakeHashTable(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 0) return error.ArityMismatch;
    return hashtable.make(vm.gc) catch return error.OutOfMemory;
}

pub fn primHashTableQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    return if (hashtable.isHashTable(args[0])) value_mod.TRUE else value_mod.FALSE;
}

pub fn primHashSet(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 3) return error.ArityMismatch;
    _ = try hashtable.set(vm.gc, vm, args[0], args[1], args[2]);
    return value_mod.NIL;
}

pub fn primHashGet(vm: *VM, args: []const Value) LispError!Value {
    const default_val: Value = switch (args.len) {
        2 => value_mod.FALSE,
        3 => args[2],
        else => return error.ArityMismatch,
    };
    return hashtable.get(vm, args[0], args[1], default_val);
}

pub fn primHashContainsQ(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const found = try hashtable.contains(vm, args[0], args[1]);
    return if (found) value_mod.TRUE else value_mod.FALSE;
}

pub fn primHashDelete(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const removed = try hashtable.delete(vm.gc, vm, args[0], args[1]);
    return if (removed) value_mod.TRUE else value_mod.FALSE;
}

pub fn primHashSize(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    if (!hashtable.isHashTable(args[0])) return error.TypeError;
    return value_mod.fixnum(@intCast(hashtable.size(args[0])));
}

// ───────── iteration helpers ─────────

const CollectCtx = struct {
    vec: Value,
    idx: usize,
    want_keys: bool,
};

fn collectVisit(ctx_raw: *anyopaque, k: Value, v: Value) void {
    const c: *CollectCtx = @ptrCast(@alignCast(ctx_raw));
    const val = if (c.want_keys) k else v;
    const h = value_mod.ptrVal(c.vec);
    const slot: *Value = @ptrFromInt(@intFromPtr(h) + 8 + (c.idx + 1) * 8);
    slot.* = val;
    c.idx += 1;
}

fn collectInto(vm: *VM, ht: Value, want_keys: bool) !Value {
    if (!hashtable.isHashTable(ht)) return error.TypeError;
    const len = hashtable.size(ht);
    var scope = HandleScope{};
    vm.gc.roots.pushHandleScope(&scope);
    defer vm.gc.roots.popHandleScope();
    const ht_slot = scope.push(ht);
    const vec = objects.makeVector(vm.gc, len, value_mod.NIL) catch return error.OutOfMemory;
    const vec_slot = scope.push(vec);
    var ctx = CollectCtx{ .vec = vec_slot.*, .idx = 0, .want_keys = want_keys };
    hashtable.forEach(ht_slot, @ptrCast(&ctx), collectVisit);
    return vec_slot.*;
}

pub fn primHashKeys(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    return collectInto(vm, args[0], true);
}

pub fn primHashValues(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    return collectInto(vm, args[0], false);
}

// ───────── hash->alist / alist->hash ─────────

const AlistCtx = struct {
    vm: *VM,
    acc: Value, // built up via Handles from outside
    err: ?LispError = null,
};

fn alistVisit(ctx_raw: *anyopaque, k: Value, v: Value) void {
    const c: *AlistCtx = @ptrCast(@alignCast(ctx_raw));
    if (c.err != null) return;
    const cell = objects.makePair(c.vm.gc, k, v) catch |e| {
        c.err = switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.OutOfMemory,
        };
        return;
    };
    c.acc = objects.makePair(c.vm.gc, cell, c.acc) catch |e| {
        c.err = switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.OutOfMemory,
        };
        return;
    };
}

pub fn primHashToAlist(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!hashtable.isHashTable(args[0])) return error.TypeError;
    var scope = HandleScope{};
    vm.gc.roots.pushHandleScope(&scope);
    defer vm.gc.roots.popHandleScope();
    const ht_slot = scope.push(args[0]);
    var ctx = AlistCtx{ .vm = vm, .acc = value_mod.NIL };
    hashtable.forEach(ht_slot, @ptrCast(&ctx), alistVisit);
    if (ctx.err) |e| return e;
    return ctx.acc;
}

/// zepo-a72: ctx.f_slot points into a GC root (a HandleScope slot) so the
/// callback closure survives any allocation the callback triggers. Without
/// rooting, the slot in this struct would go stale after the first
/// callback that GCs and subsequent iterations would see a forwarded
/// pointer where they expect a closure, producing a confusing TypeError.
const ForEachCtx = struct {
    vm: *VM,
    f_slot: *Value,
    err: ?LispError = null,
};

fn forEachVisit(ctx_raw: *anyopaque, k: Value, v: Value) void {
    const c: *ForEachCtx = @ptrCast(@alignCast(ctx_raw));
    if (c.err != null) return;
    // zepo-a72: k and v come from the hash-table walker and live in
    // foreign C-stack memory; push them as additional roots so the
    // callback's allocations don't strand them either.
    var scope = HandleScope{};
    c.vm.gc.roots.pushHandleScope(&scope);
    defer c.vm.gc.roots.popHandleScope();
    const k_slot = scope.push(k);
    const v_slot = scope.push(v);
    const args = [_]Value{ k_slot.*, v_slot.* };
    _ = c.vm.callValue(c.f_slot.*, &args) catch |e| {
        c.err = e;
    };
}

pub fn primHashForEach(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!hashtable.isHashTable(args[1])) return error.TypeError;
    // zepo-a72: root the callback closure across the walk so allocations
    // inside the callback can't strand the f value (it lives in our ctx
    // struct on the C stack, which isn't a GC root).
    var scope = HandleScope{};
    vm.gc.roots.pushHandleScope(&scope);
    defer vm.gc.roots.popHandleScope();
    const f_slot = scope.push(args[0]);
    const ht_slot = scope.push(args[1]);
    var ctx = ForEachCtx{ .vm = vm, .f_slot = f_slot };
    hashtable.forEach(ht_slot, @ptrCast(&ctx), forEachVisit);
    if (ctx.err) |e| return e;
    return value_mod.NIL;
}

pub fn primAlistToHash(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const ht = hashtable.make(vm.gc) catch return error.OutOfMemory;

    var scope = HandleScope{};
    vm.gc.roots.pushHandleScope(&scope);
    defer vm.gc.roots.popHandleScope();
    const ht_slot = scope.push(ht);

    var cur = args[0];
    while (objects.isPair(cur)) {
        const cell = objects.pairCar(cur).*;
        if (!objects.isPair(cell)) return error.ContractViolation;
        const k = objects.pairCar(cell).*;
        const v = objects.pairCdr(cell).*;
        _ = try hashtable.set(vm.gc, vm, ht_slot.*, k, v);
        cur = objects.pairCdr(cur).*;
    }
    return ht_slot.*;
}
