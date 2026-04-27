//! Typed constructors and accessors for heap objects.
//!
//! All constructors allocate via the GC. Callers that pass unrooted heap
//! Values across a call that may allocate must push them onto a HandleScope
//! first; a GC can trigger at any alloc.

const std = @import("std");
const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const ObjHeader = abi.ObjHeader;
const Kind = abi.Kind;
const value_mod = abi.value;

pub const WORD: usize = 8;

/// Returns a typed pointer to the `word_offset`-th word of the object body.
pub fn bodyPtr(comptime T: type, hdr: *ObjHeader, word_offset: usize) *T {
    const base = @intFromPtr(hdr) + @sizeOf(ObjHeader);
    return @ptrFromInt(base + word_offset * WORD);
}

fn bodyValueSlot(hdr: *ObjHeader, word_offset: usize) *Value {
    return bodyPtr(Value, hdr, word_offset);
}

/// Store `val` into `slot` inside `container`, applying the generational
/// write barrier. Use for any body-slot write where the container may have
/// been allocated directly in old-gen (e.g. nursery-full fallback path).
pub inline fn storeValue(gc: *GC, container: *ObjHeader, slot: *Value, val: Value) void {
    gc.writeBarrier(container, slot, val);
    slot.* = val;
}

// -------------------- Pair --------------------

pub fn makePair(gc: *GC, car: Value, cdr: Value) !Value {
    const h = try gc.alloc(.pair, 2);
    storeValue(gc, h, bodyValueSlot(h, 0), car);
    storeValue(gc, h, bodyValueSlot(h, 1), cdr);
    return value_mod.fromPtr(h);
}

/// Like makePair but reads car/cdr from register-like slots AFTER gc.alloc so
/// that any GC triggered by the allocation sees the updated Values via the
/// normal root-scan path (vmRootVisit updates register arrays in place).
pub fn makePairFromSlots(gc: *GC, car_slot: *const Value, cdr_slot: *const Value) !Value {
    const h = try gc.alloc(.pair, 2);
    storeValue(gc, h, bodyValueSlot(h, 0), car_slot.*);
    storeValue(gc, h, bodyValueSlot(h, 1), cdr_slot.*);
    return value_mod.fromPtr(h);
}

pub fn pairCar(p: Value) *Value {
    const h = value_mod.ptrVal(p);
    return bodyValueSlot(h, 0);
}

pub fn pairCdr(p: Value) *Value {
    const h = value_mod.ptrVal(p);
    return bodyValueSlot(h, 1);
}

// -------------------- Float --------------------

pub fn makeFloat(gc: *GC, f: f64) !Value {
    const h = try gc.alloc(.float, 1);
    const bits: u64 = @bitCast(f);
    bodyPtr(u64, h, 0).* = bits;
    return value_mod.fromPtr(h);
}

pub fn floatVal(v: Value) f64 {
    const h = value_mod.ptrVal(v);
    const bits = bodyPtr(u64, h, 0).*;
    return @bitCast(bits);
}

// -------------------- Box --------------------

pub fn makeBox(gc: *GC, val: Value) !Value {
    const h = try gc.alloc(.box, 1);
    storeValue(gc, h, bodyValueSlot(h, 0), val);
    return value_mod.fromPtr(h);
}

/// Like makeBox but reads val from a register slot AFTER gc.alloc.
pub fn makeBoxFromSlot(gc: *GC, val_slot: *const Value) !Value {
    const h = try gc.alloc(.box, 1);
    storeValue(gc, h, bodyValueSlot(h, 0), val_slot.*);
    return value_mod.fromPtr(h);
}

pub fn boxGet(v: Value) Value {
    const h = value_mod.ptrVal(v);
    return bodyValueSlot(h, 0).*;
}

pub fn boxSet(gc: *GC, v: Value, new_val: Value) void {
    const h = value_mod.ptrVal(v);
    const slot = bodyValueSlot(h, 0);
    gc.writeBarrier(h, slot, new_val);
    slot.* = new_val;
}

// -------------------- String --------------------
// Body: [len: u64][bytes padded to word boundary]

pub fn makeString(gc: *GC, bytes: []const u8) !Value {
    const nbytes = bytes.len;
    const tail_words = (nbytes + WORD - 1) / WORD;
    const body_words = 1 + tail_words; // length word + byte tail
    const h = try gc.alloc(.string, body_words);
    bodyPtr(u64, h, 0).* = @intCast(nbytes);
    if (nbytes != 0) {
        const tail_ptr: [*]u8 = @ptrCast(bodyPtr(u8, h, 1));
        @memcpy(tail_ptr[0..nbytes], bytes);
        // Pad remaining bytes with zero so the tail is deterministic.
        const padded = tail_words * WORD;
        if (padded > nbytes) {
            @memset(tail_ptr[nbytes..padded], 0);
        }
    }
    return value_mod.fromPtr(h);
}

pub fn stringLen(v: Value) usize {
    const h = value_mod.ptrVal(v);
    return @intCast(bodyPtr(u64, h, 0).*);
}

pub fn stringBytes(v: Value) []const u8 {
    const h = value_mod.ptrVal(v);
    const n: usize = @intCast(bodyPtr(u64, h, 0).*);
    if (n == 0) return &.{};
    const tail_ptr: [*]const u8 = @ptrCast(bodyPtr(u8, h, 1));
    return tail_ptr[0..n];
}

// -------------------- Symbol --------------------
// Body: [name: *String as raw u64][hash: u64]

pub fn makeSymbol(gc: *GC, name_str: Value, hash: u64) !Value {
    std.debug.assert(isString(name_str));
    const h = try gc.alloc(.symbol, 2);
    // Store name string as tagged Value so the GC layout table can trace it.
    bodyPtr(Value, h, 0).* = name_str;
    bodyPtr(u64, h, 1).* = hash;
    return value_mod.fromPtr(h);
}

pub fn symbolNameStringHdr(v: Value) *ObjHeader {
    const h = value_mod.ptrVal(v);
    const name_val = bodyPtr(Value, h, 0).*;
    return value_mod.ptrVal(name_val);
}

pub fn symbolName(v: Value) []const u8 {
    const name_hdr = symbolNameStringHdr(v);
    const name_val = value_mod.fromPtr(name_hdr);
    return stringBytes(name_val);
}

pub fn symbolHash(v: Value) u64 {
    const h = value_mod.ptrVal(v);
    return bodyPtr(u64, h, 1).*;
}

// -------------------- Vector --------------------
// Body: [len: u64][slot0: Value]...[slotN: Value]

pub fn makeVector(gc: *GC, len: usize, fill: Value) !Value {
    const body_words = 1 + len;
    const h = try gc.alloc(.vector, body_words);
    bodyPtr(u64, h, 0).* = @intCast(len);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        storeValue(gc, h, bodyValueSlot(h, 1 + i), fill);
    }
    return value_mod.fromPtr(h);
}

pub fn vectorLen(v: Value) usize {
    const h = value_mod.ptrVal(v);
    return @intCast(bodyPtr(u64, h, 0).*);
}

pub fn vectorGet(v: Value, idx: usize) Value {
    const h = value_mod.ptrVal(v);
    std.debug.assert(idx < vectorLen(v));
    return bodyValueSlot(h, 1 + idx).*;
}

pub fn vectorSet(gc: *GC, v: Value, idx: usize, new_val: Value) void {
    const h = value_mod.ptrVal(v);
    std.debug.assert(idx < vectorLen(v));
    const slot = bodyValueSlot(h, 1 + idx);
    gc.writeBarrier(h, slot, new_val);
    slot.* = new_val;
}

// -------------------- Closure --------------------
// Body: [code_ptr: u64][arity: u64][cap0: Value]...[capN: Value]

pub fn makeClosure(gc: *GC, code_ptr: u64, arity: u64, home_env: u64, captures: []const Value) !Value {
    const body_words = 3 + captures.len;
    const h = try gc.alloc(.closure, body_words);
    bodyPtr(u64, h, 0).* = code_ptr;
    bodyPtr(u64, h, 1).* = arity;
    bodyPtr(u64, h, 2).* = home_env; // raw ptr to GlobalEnv; not traced by GC
    var i: usize = 0;
    while (i < captures.len) : (i += 1) {
        storeValue(gc, h, bodyValueSlot(h, 3 + i), captures[i]);
    }
    return value_mod.fromPtr(h);
}

pub fn closureHomeEnvPtr(v: Value) u64 {
    const h = value_mod.ptrVal(v);
    return bodyPtr(u64, h, 2).*;
}

pub fn closureCodePtr(v: Value) u64 {
    const h = value_mod.ptrVal(v);
    return bodyPtr(u64, h, 0).*;
}

pub fn closureArity(v: Value) u64 {
    const h = value_mod.ptrVal(v);
    return bodyPtr(u64, h, 1).*;
}

pub fn closureCaptures(v: Value) []Value {
    const h = value_mod.ptrVal(v);
    const body_words: usize = @intCast(h.sizeWords());
    if (body_words <= 3) return &.{};
    const n = body_words - 3;
    const first: [*]Value = @ptrCast(bodyValueSlot(h, 3));
    return first[0..n];
}

// -------------------- Prim --------------------
// Body: [fn_ptr: u64][arity: i64]

pub fn makePrim(gc: *GC, fn_ptr: u64, arity: i64) !Value {
    const h = try gc.alloc(.prim, 2);
    bodyPtr(u64, h, 0).* = fn_ptr;
    bodyPtr(i64, h, 1).* = arity;
    return value_mod.fromPtr(h);
}

pub fn primFnPtr(v: Value) u64 {
    const h = value_mod.ptrVal(v);
    return bodyPtr(u64, h, 0).*;
}

pub fn primArity(v: Value) i64 {
    const h = value_mod.ptrVal(v);
    return bodyPtr(i64, h, 1).*;
}

// -------------------- EnvFrame --------------------
// Body: [parent: Value][slot0: Value]...[slotN: Value]

pub fn makeEnvFrame(gc: *GC, parent: Value, num_slots: usize) !Value {
    const body_words = 1 + num_slots;
    const h = try gc.alloc(.env_frame, body_words);
    storeValue(gc, h, bodyValueSlot(h, 0), parent);
    var i: usize = 0;
    while (i < num_slots) : (i += 1) {
        storeValue(gc, h, bodyValueSlot(h, 1 + i), value_mod.NIL);
    }
    return value_mod.fromPtr(h);
}

pub fn envParent(v: Value) Value {
    const h = value_mod.ptrVal(v);
    return bodyValueSlot(h, 0).*;
}

pub fn envSlot(v: Value, idx: usize) *Value {
    const h = value_mod.ptrVal(v);
    return bodyValueSlot(h, 1 + idx);
}

pub fn envSlotCount(v: Value) usize {
    const h = value_mod.ptrVal(v);
    const body_words: usize = @intCast(h.sizeWords());
    return body_words - 1;
}

pub fn envSet(gc: *GC, v: Value, idx: usize, new_val: Value) void {
    const h = value_mod.ptrVal(v);
    const slot = bodyValueSlot(h, 1 + idx);
    gc.writeBarrier(h, slot, new_val);
    slot.* = new_val;
}

// -------------------- Type predicates --------------------

pub inline fn isKind(v: Value, k: Kind) bool {
    if (!value_mod.isPtr(v)) return false;
    const h = value_mod.ptrVal(v);
    return h.kind() == k;
}

// -------------------- Foreign --------------------
// Body: [payload_raw: u64][deinit_raw: u64][type_tag: u64]
// payload_raw and deinit_raw are raw pointer bit-patterns (0 = null/none).
// type_tag is a caller-defined u64 discriminator used by FFI accessors to
// type-check handles at runtime.

pub const ForeignDeinit = *const fn (?*anyopaque) callconv(.c) void;

pub fn makeForeign(
    gc: *GC,
    payload: ?*anyopaque,
    deinit_fn: ?ForeignDeinit,
    type_tag: u64,
) !Value {
    const h = try gc.allocForeign(payload, deinit_fn, type_tag);
    return value_mod.fromPtr(h);
}

pub fn foreignPayload(v: Value) ?*anyopaque {
    const h = value_mod.ptrVal(v);
    const body: [*]u64 = @ptrFromInt(@intFromPtr(h) + WORD);
    const raw = body[0];
    return if (raw == 0) null else @ptrFromInt(@as(usize, @intCast(raw)));
}

pub fn foreignPayloadRaw(v: Value) u64 {
    const h = value_mod.ptrVal(v);
    const body: [*]u64 = @ptrFromInt(@intFromPtr(h) + WORD);
    return body[0];
}

pub fn foreignTypeTag(v: Value) u64 {
    const h = value_mod.ptrVal(v);
    const body: [*]u64 = @ptrFromInt(@intFromPtr(h) + WORD);
    return body[2];
}

pub fn makeForeignRaw(
    gc: *GC,
    payload_bits: u64,
    deinit_fn: ?ForeignDeinit,
    type_tag: u64,
) !Value {
    const h = try gc.allocForeignRaw(payload_bits, deinit_fn, type_tag);
    return value_mod.fromPtr(h);
}

pub fn isForeign(v: Value) bool {
    return isKind(v, .foreign);
}

pub fn isPair(v: Value) bool {
    return isKind(v, .pair);
}
pub fn isFloat(v: Value) bool {
    return isKind(v, .float);
}
pub fn isBox(v: Value) bool {
    return isKind(v, .box);
}
pub fn isString(v: Value) bool {
    return isKind(v, .string);
}
pub fn isSymbol(v: Value) bool {
    return isKind(v, .symbol);
}
pub fn isVector(v: Value) bool {
    return isKind(v, .vector);
}
pub fn isClosure(v: Value) bool {
    return isKind(v, .closure);
}
pub fn isPrim(v: Value) bool {
    return isKind(v, .prim);
}
pub fn isEnvFrame(v: Value) bool {
    return isKind(v, .env_frame);
}

pub fn isNumber(v: Value) bool {
    return value_mod.isFixnum(v) or isFloat(v);
}

pub fn isProcedure(v: Value) bool {
    return isClosure(v) or isPrim(v);
}
