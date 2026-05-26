//! First-class hash tables. Open-addressed, linear-probing; default key
//! equality is `equal?`. Storage is a two-level structure: the hash_table
//! heap object stores [len, backing] where backing is a lisp vector of
//! length 2*capacity holding alternating (key, value) Value slots.
//!
//! Empty slot sentinel: NIL. Tombstone sentinel: hash.TOMBSTONE.
//! NIL is therefore rejected as a key.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const ObjHeader = abi.ObjHeader;

const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;
const HandleScope = gc_mod.HandleScope;

const objects = @import("objects.zig");
const hash_mod = @import("hash.zig");

const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;

const equality = @import("../prims/equality.zig");

const errors = @import("errors.zig");
const LispError = errors.LispError;

pub const INITIAL_CAPACITY: usize = 8;
const LOAD_NUM: usize = 3;
const LOAD_DEN: usize = 4; // resize when len * LOAD_DEN >= cap * LOAD_NUM

inline fn hdrBody(h: *ObjHeader) [*]u64 {
    return @ptrFromInt(@intFromPtr(h) + 8);
}

pub fn isHashTable(v: Value) bool {
    return objects.isKind(v, .hash_table);
}

/// Read the current length (number of occupied slots).
pub fn size(v: Value) usize {
    const h = value_mod.ptrVal(v);
    return @intCast(hdrBody(h)[0]);
}

fn setLen(v: Value, n: usize) void {
    const h = value_mod.ptrVal(v);
    hdrBody(h)[0] = @as(u64, n);
}

fn backing(v: Value) Value {
    const h = value_mod.ptrVal(v);
    const body: [*]Value = @ptrFromInt(@intFromPtr(h) + 8);
    return body[1];
}

fn setBacking(gc: *GC, v: Value, new_backing: Value) void {
    const h = value_mod.ptrVal(v);
    const body: [*]Value = @ptrFromInt(@intFromPtr(h) + 8);
    objects.storeValue(gc, h, &body[1], new_backing);
}

/// Capacity is half the backing vector's length (since it stores k,v pairs).
pub fn capacity(v: Value) usize {
    const back = backing(v);
    return objects.vectorLen(back) / 2;
}

fn keyAt(back: Value, slot: usize) Value {
    return objects.vectorGet(back, slot * 2);
}
fn valAt(back: Value, slot: usize) Value {
    return objects.vectorGet(back, slot * 2 + 1);
}
fn setKeyAt(gc: *GC, back: Value, slot: usize, k: Value) void {
    objects.vectorSet(gc, back, slot * 2, k);
}
fn setValAt(gc: *GC, back: Value, slot: usize, val: Value) void {
    objects.vectorSet(gc, back, slot * 2 + 1, val);
}

/// Create an empty hash table with INITIAL_CAPACITY slots.
pub fn make(gc: *GC) error{OutOfMemory}!Value {
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const back = objects.makeVector(gc, INITIAL_CAPACITY * 2, value_mod.NIL) catch return error.OutOfMemory;
    const back_slot = scope.push(back);

    const h = gc.alloc(.hash_table, 2) catch return error.OutOfMemory;
    const ht = value_mod.fromPtr(h);
    const body: [*]Value = @ptrFromInt(@intFromPtr(h) + 8);
    body[0] = 0; // len
    body[1] = value_mod.NIL; // temp — replaced with barrier below
    objects.storeValue(gc, h, &body[1], back_slot.*);
    return ht;
}

fn structurallyEqual(vm: *VM, a: Value, b: Value) LispError!bool {
    if (a == b) return true;
    var visited = std.AutoHashMap([2]usize, void).init(vm.allocator);
    defer visited.deinit();
    return equality.structuralEqual(vm, a, b, &visited) catch return error.OutOfMemory;
}

/// Probe for `key` in the backing `back` of capacity `cap`. Returns:
///  - found: { slot = index where key sits, is_insert = false }
///  - not-found: { slot = index where insertion should occur
///                (first tombstone seen, or first NIL), is_insert = true }
const Probe = struct { slot: usize, is_insert: bool };

fn probe(vm: *VM, back: Value, cap: usize, key: Value, key_hash: u64) LispError!Probe {
    var i: usize = @intCast(key_hash % @as(u64, @intCast(cap)));
    var first_tomb: ?usize = null;
    var steps: usize = 0;
    while (steps < cap) : (steps += 1) {
        const k = keyAt(back, i);
        if (k == value_mod.NIL) {
            return .{ .slot = first_tomb orelse i, .is_insert = true };
        }
        if (k == hash_mod.TOMBSTONE) {
            if (first_tomb == null) first_tomb = i;
        } else if (try structurallyEqual(vm, k, key)) {
            return .{ .slot = i, .is_insert = false };
        }
        i = (i + 1) % cap;
    }
    // Table completely full of occupied+tombstone — shouldn't happen if
    // load factor is enforced, but if it does the caller must resize.
    return .{ .slot = first_tomb orelse 0, .is_insert = true };
}

fn resize(gc: *GC, vm: *VM, ht: Value, new_cap: usize) LispError!void {
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();

    const ht_slot = scope.push(ht);
    const new_back = objects.makeVector(gc, new_cap * 2, value_mod.NIL) catch return error.OutOfMemory;
    const new_back_slot = scope.push(new_back);

    const old_back = backing(ht_slot.*);
    const old_cap = objects.vectorLen(old_back) / 2;
    var i: usize = 0;
    while (i < old_cap) : (i += 1) {
        const k = keyAt(old_back, i);
        if (k == value_mod.NIL or k == hash_mod.TOMBSTONE) continue;
        const v = valAt(old_back, i);
        const h = hash_mod.hashValue(k);
        const p = try probe(vm, new_back_slot.*, new_cap, k, h);
        setKeyAt(gc, new_back_slot.*, p.slot, k);
        setValAt(gc, new_back_slot.*, p.slot, v);
    }
    setBacking(gc, ht_slot.*, new_back_slot.*);
}

/// Insert-or-update. Returns true if a new slot was added (len incremented).
pub fn set(gc: *GC, vm: *VM, ht_in: Value, key_in: Value, val_in: Value) LispError!bool {
    if (!isHashTable(ht_in)) return error.TypeError;
    if (key_in == value_mod.NIL) return error.ContractViolation; // nil as key forbidden

    // zepo-jnk: resize() allocates a new backing vector, which can trigger a
    // moving minor GC. Root ht/key/val so the by-value params cannot go stale —
    // otherwise a moved object's pre-GC pointer would be hashed, probed, and
    // written into the table, corrupting it. probe() does not allocate, so the
    // only collection window is resize(); read everything back from the slots.
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const ht_s = scope.push(ht_in);
    const key_s = scope.push(key_in);
    const val_s = scope.push(val_in);

    // Resize check before inserting new entries so probe always has room.
    const cap_now = capacity(ht_s.*);
    const len_now = size(ht_s.*);
    if ((len_now + 1) * LOAD_DEN >= cap_now * LOAD_NUM) {
        try resize(gc, vm, ht_s.*, cap_now * 2);
    }

    const h = hash_mod.hashValue(key_s.*);
    const back = backing(ht_s.*);
    const p = try probe(vm, back, capacity(ht_s.*), key_s.*, h);
    setKeyAt(gc, back, p.slot, key_s.*);
    setValAt(gc, back, p.slot, val_s.*);
    if (p.is_insert) {
        setLen(ht_s.*, size(ht_s.*) + 1);
        return true;
    }
    return false;
}

// zepo-hlz
// Linear-probe to the first NIL/TOMBSTONE slot. No equality compare — caller
// guarantees `key` is not already present. Returns the slot to write.
fn probeDistinct(back: Value, cap: usize, key_hash: u64) usize {
    var i: usize = @intCast(key_hash % @as(u64, @intCast(cap)));
    var steps: usize = 0;
    while (steps < cap) : (steps += 1) {
        const k = keyAt(back, i);
        if (k == value_mod.NIL or k == hash_mod.TOMBSTONE) return i;
        i = (i + 1) % cap;
    }
    return i; // full table — caller resizes before this can happen
}

fn rehashDistinct(gc: *GC, ht: Value, new_cap: usize) error{OutOfMemory}!void {
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const ht_slot = scope.push(ht);
    const new_back = objects.makeVector(gc, new_cap * 2, value_mod.NIL) catch return error.OutOfMemory;
    const new_back_slot = scope.push(new_back);
    const old_back = backing(ht_slot.*);
    const old_cap = objects.vectorLen(old_back) / 2;
    var i: usize = 0;
    while (i < old_cap) : (i += 1) {
        const k = keyAt(old_back, i);
        if (k == value_mod.NIL or k == hash_mod.TOMBSTONE) continue;
        const v = valAt(old_back, i);
        const slot = probeDistinct(new_back_slot.*, new_cap, hash_mod.hashValue(k));
        setKeyAt(gc, new_back_slot.*, slot, k);
        setValAt(gc, new_back_slot.*, slot, v);
    }
    setBacking(gc, ht_slot.*, new_back_slot.*);
}

/// Insert a key known to be absent (e.g. when rebuilding a deduped table).
/// VM-free; never compares keys for equality. The caller must guarantee that
/// `key` is not already present under `equal?`; otherwise a duplicate slot is
/// created.
pub fn putDistinct(gc: *GC, ht_in: Value, key_in: Value, val_in: Value) error{OutOfMemory}!void {
    std.debug.assert(key_in != value_mod.NIL); // NIL is the empty sentinel; a NIL key here is a caller bug
    // zepo-jnk: rehashDistinct() allocates a new backing vector (moving GC
    // possible), so root ht/key/val and read them back from the slots after.
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const ht_s = scope.push(ht_in);
    const key_s = scope.push(key_in);
    const val_s = scope.push(val_in);
    const cap_now = capacity(ht_s.*);
    const len_now = size(ht_s.*);
    if ((len_now + 1) * LOAD_DEN >= cap_now * LOAD_NUM) {
        try rehashDistinct(gc, ht_s.*, cap_now * 2);
    }
    const back = backing(ht_s.*);
    const slot = probeDistinct(back, capacity(ht_s.*), hash_mod.hashValue(key_s.*));
    setKeyAt(gc, back, slot, key_s.*);
    setValAt(gc, back, slot, val_s.*);
    setLen(ht_s.*, size(ht_s.*) + 1);
}

pub fn get(vm: *VM, ht: Value, key: Value, default_val: Value) LispError!Value {
    if (!isHashTable(ht)) return error.TypeError;
    if (key == value_mod.NIL) return default_val;
    const h = hash_mod.hashValue(key);
    const back = backing(ht);
    const p = try probe(vm, back, capacity(ht), key, h);
    if (p.is_insert) return default_val;
    return valAt(back, p.slot);
}

pub fn contains(vm: *VM, ht: Value, key: Value) LispError!bool {
    if (!isHashTable(ht)) return error.TypeError;
    if (key == value_mod.NIL) return false;
    const h = hash_mod.hashValue(key);
    const back = backing(ht);
    const p = try probe(vm, back, capacity(ht), key, h);
    return !p.is_insert;
}

/// Delete: writes TOMBSTONE at the slot. Returns true if an entry was
/// removed. Does NOT compact; tombstones are reclaimed at resize time.
pub fn delete(gc: *GC, vm: *VM, ht: Value, key: Value) LispError!bool {
    if (!isHashTable(ht)) return error.TypeError;
    if (key == value_mod.NIL) return false;
    const h = hash_mod.hashValue(key);
    const back = backing(ht);
    const p = try probe(vm, back, capacity(ht), key, h);
    if (p.is_insert) return false;
    setKeyAt(gc, back, p.slot, hash_mod.TOMBSTONE);
    // Clear value slot too so the GC doesn't retain it.
    setValAt(gc, back, p.slot, value_mod.NIL);
    setLen(ht, size(ht) - 1);
    return true;
}

/// Visitor for iteration. Called once per occupied slot with (key, value).
pub fn forEach(
    ht_slot: *Value,
    ctx: *anyopaque,
    visitor: *const fn (ctx: *anyopaque, k: Value, v: Value) void,
) void {
    // zepo-a72: read ht and backing on every iteration via the caller's
    // rooted slot. The visitor may call back into Lisp and trigger a GC
    // that moves both the hash-table object and its backing vector.
    // A by-value `ht: Value` parameter would go stale after the first
    // GC and `backing(ht)` would return garbage on the next iteration.
    const cap = objects.vectorLen(backing(ht_slot.*)) / 2;
    var i: usize = 0;
    while (i < cap) : (i += 1) {
        const back = backing(ht_slot.*);
        const k = keyAt(back, i);
        if (k == value_mod.NIL or k == hash_mod.TOMBSTONE) continue;
        const v = valAt(back, i);
        visitor(ctx, k, v);
    }
}
