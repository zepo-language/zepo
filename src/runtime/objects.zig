//! Typed constructors and accessors for heap objects.
//!
//! All constructors allocate via the GC. makePair roots its arguments
//! internally so callers do not need to pre-root car/cdr; all other
//! constructors still require callers to hold HandleScope roots across
//! any call that may allocate.

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
    // Root car/cdr so a GC triggered by gc.alloc sees updated addresses.
    var scope = gc_mod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const car_slot = scope.push(car);
    const cdr_slot = scope.push(cdr);
    const h = try gc.alloc(.pair, 2);
    storeValue(gc, h, bodyValueSlot(h, 0), car_slot.*);
    storeValue(gc, h, bodyValueSlot(h, 1), cdr_slot.*);
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

// zepo-asu1: in-place pair mutation. storeValue applies the generational write
// barrier, so mutating an old-gen pair to point at a young value records the
// old->young edge in the card table (same path as vectorSet). This is what
// makes set-car!/set-cdr! — and cyclic structures like (set-cdr! x x) — safe.
pub fn pairSetCar(gc: *GC, p: Value, new_val: Value) void {
    const h = value_mod.ptrVal(p);
    storeValue(gc, h, bodyValueSlot(h, 0), new_val);
}

pub fn pairSetCdr(gc: *GC, p: Value, new_val: Value) void {
    const h = value_mod.ptrVal(p);
    storeValue(gc, h, bodyValueSlot(h, 1), new_val);
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

/// zepo-mckx: render an f64 in R7RS external form into `buf`. An inexact real
/// always carries a decimal point (or exponent) so it reads back as inexact and
/// is not mistaken for an integer (`1.0` not `1`); non-finite values use the
/// R7RS `+inf.0` / `-inf.0` / `+nan.0` syntax. `buf` should be at least 32 bytes.
pub fn formatFloat(buf: []u8, f: f64) []const u8 {
    if (std.math.isNan(f)) return "+nan.0";
    if (std.math.isPositiveInf(f)) return "+inf.0";
    if (std.math.isNegativeInf(f)) return "-inf.0";
    const s = std.fmt.bufPrint(buf, "{d}", .{f}) catch return "?";
    // {d} prints 1.0 as "1"; make sure a '.' or exponent is present so the value
    // round-trips as inexact.
    for (s) |c| {
        if (c == '.' or c == 'e' or c == 'E') return s;
    }
    if (s.len + 2 <= buf.len) {
        buf[s.len] = '.';
        buf[s.len + 1] = '0';
        return buf[0 .. s.len + 2];
    }
    return s;
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

// -------------------- Parameter --------------------
// zepo-6o3p: R7RS parameter object. Body: [default(Value)][converter(Value, NIL=none)].
// The current dynamic value never lives here — it lives on the per-fiber
// dynamic_stack so parameters are fiber-local. This object holds only the
// fallback default and the optional converter procedure.

pub fn makeParameter(gc: *GC, default_val: Value, converter: Value) !Value {
    var scope = gc_mod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const dv = scope.push(default_val);
    const cv = scope.push(converter);
    const h = try gc.alloc(.parameter, 2);
    storeValue(gc, h, bodyValueSlot(h, 0), dv.*);
    storeValue(gc, h, bodyValueSlot(h, 1), cv.*);
    return value_mod.fromPtr(h);
}

pub fn parameterDefault(v: Value) Value {
    return bodyValueSlot(value_mod.ptrVal(v), 0).*;
}

pub fn parameterConverter(v: Value) Value {
    return bodyValueSlot(value_mod.ptrVal(v), 1).*;
}

pub fn setParameterDefault(gc: *GC, v: Value, new_val: Value) void {
    const h = value_mod.ptrVal(v);
    const slot = bodyValueSlot(h, 0);
    gc.writeBarrier(h, slot, new_val);
    slot.* = new_val;
}

// -------------------- String --------------------
// Body: [len: u64][bytes padded to word boundary]

// zepo-1meg: the top bit of the length word flags a MUTABLE string (created by
// make-string/string-copy). Literals and every other makeString result are
// immutable, so string-set!/string-fill! can reject them. zepo strings are
// byte-indexed (string-ref returns a byte), so a mutable string is a mutable
// byte buffer; the length never changes. The GC sizes objects from the header
// (sizeWords), not this word, so the flag bit is invisible to it.
const STRING_MUTABLE_BIT: u64 = @as(u64, 1) << 63;

fn allocString(gc: *GC, bytes: []const u8, mutable: bool) !Value {
    const nbytes = bytes.len;
    const tail_words = (nbytes + WORD - 1) / WORD;
    const body_words = 1 + tail_words; // length word + byte tail
    const h = try gc.alloc(.string, body_words);
    bodyPtr(u64, h, 0).* = @as(u64, @intCast(nbytes)) | (if (mutable) STRING_MUTABLE_BIT else 0);
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

pub fn makeString(gc: *GC, bytes: []const u8) !Value {
    return allocString(gc, bytes, false);
}

/// zepo-1meg: a mutable byte-string copy of `bytes` (string-set!/-fill! allowed).
pub fn makeMutableString(gc: *GC, bytes: []const u8) !Value {
    return allocString(gc, bytes, true);
}

/// zepo-1meg: a mutable string of `len` bytes all set to `fill` (make-string).
pub fn makeMutableStringFill(gc: *GC, len: usize, fill: u8) !Value {
    const tail_words = (len + WORD - 1) / WORD;
    const h = try gc.alloc(.string, 1 + tail_words);
    bodyPtr(u64, h, 0).* = @as(u64, @intCast(len)) | STRING_MUTABLE_BIT;
    if (len != 0) {
        const tail_ptr: [*]u8 = @ptrCast(bodyPtr(u8, h, 1));
        @memset(tail_ptr[0 .. tail_words * WORD], 0); // pad
        @memset(tail_ptr[0..len], fill);
    }
    return value_mod.fromPtr(h);
}

pub fn stringLen(v: Value) usize {
    const h = value_mod.ptrVal(v);
    return @intCast(bodyPtr(u64, h, 0).* & ~STRING_MUTABLE_BIT);
}

pub fn stringIsMutable(v: Value) bool {
    const h = value_mod.ptrVal(v);
    return (bodyPtr(u64, h, 0).* & STRING_MUTABLE_BIT) != 0;
}

pub fn stringBytes(v: Value) []const u8 {
    const n = stringLen(v);
    if (n == 0) return &.{};
    const h = value_mod.ptrVal(v);
    const tail_ptr: [*]const u8 = @ptrCast(bodyPtr(u8, h, 1));
    return tail_ptr[0..n];
}

/// zepo-1meg: a MUTABLE view of a mutable string's bytes, for string-set!/-fill!.
/// The caller must have checked stringIsMutable. Read it fresh after any alloc
/// (a GC may move the object).
pub fn stringBytesMut(v: Value) []u8 {
    const n = stringLen(v);
    if (n == 0) return &.{};
    const h = value_mod.ptrVal(v);
    const tail_ptr: [*]u8 = @ptrCast(bodyPtr(u8, h, 1));
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

// -------------------- Bytevector --------------------
// zepo-9qg: Body: [len: u64][bytes padded to word boundary]
// Mutable raw byte array; same GC layout as string but distinct Kind.

pub fn makeBytevector(gc: *GC, len: usize, fill: u8) !Value {
    const tail_words = (len + WORD - 1) / WORD;
    const body_words = 1 + tail_words;
    const h = try gc.alloc(.bytevector, body_words);
    bodyPtr(u64, h, 0).* = @intCast(len);
    if (len != 0) {
        const tail_ptr: [*]u8 = @ptrCast(bodyPtr(u8, h, 1));
        @memset(tail_ptr[0 .. tail_words * WORD], fill);
    }
    return value_mod.fromPtr(h);
}

pub fn bytevectorLen(v: Value) usize {
    const h = value_mod.ptrVal(v);
    return @intCast(bodyPtr(u64, h, 0).*);
}

pub fn bytevectorBytes(v: Value) []u8 {
    const h = value_mod.ptrVal(v);
    const n: usize = @intCast(bodyPtr(u64, h, 0).*);
    if (n == 0) return &.{};
    const tail_ptr: [*]u8 = @ptrCast(bodyPtr(u8, h, 1));
    return tail_ptr[0..n];
}

// -------------------- Bignum (zepo-nfak) --------------------
// Body: body[0] = (nlimbs << 1) | (negative ? 1 : 0); body[1..1+nlimbs] = limbs
// (std.math.big.int.Limb = usize each). Raw — no traced Value children.
const Limb = std.math.big.Limb;

pub fn isBignum(v: Value) bool {
    return isKind(v, .bignum);
}

/// Allocate a bignum from canonical big-int limbs (no leading-zero limbs). The
/// caller must have already normalized fixnum-range values to a fixnum.
pub fn makeBignum(gc: *GC, positive: bool, limbs: []const Limb) !Value {
    const h = try gc.alloc(.bignum, 1 + limbs.len);
    bodyPtr(u64, h, 0).* = (@as(u64, @intCast(limbs.len)) << 1) | (if (positive) @as(u64, 0) else 1);
    const dst: [*]Limb = @ptrCast(@alignCast(bodyPtr(Limb, h, 1)));
    for (limbs, 0..) |limb, i| dst[i] = limb;
    return value_mod.fromPtr(h);
}

/// A read-only big-int view over a bignum's inline limbs. Valid until the next
/// GC that could move the object — read it before any allocation.
pub fn bignumConst(v: Value) std.math.big.int.Const {
    const h = value_mod.ptrVal(v);
    const meta = bodyPtr(u64, h, 0).*;
    const n: usize = @intCast(meta >> 1);
    const limbs: [*]Limb = @ptrCast(@alignCast(bodyPtr(Limb, h, 1)));
    return .{ .limbs = limbs[0..n], .positive = (meta & 1) == 0 };
}

// -------------------- Ratio (zepo-or1d) --------------------
// Body: body[0] = numerator (Value), body[1] = denominator (Value). Both are
// exact integers (fixnum or bignum). A well-formed ratio is always reduced,
// has denominator > 0, and denominator != 1 (den==1 normalizes to an integer).
// Both children are traced.

pub fn isRatio(v: Value) bool {
    return isKind(v, .ratio);
}

/// Raw constructor — stores num/den as given. Callers MUST have already
/// normalized (reduced via gcd, den>0, den!=1). See runtime/ratio.zig make().
pub fn makeRatio(gc: *GC, num: Value, den: Value) !Value {
    var scope = gc_mod.HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const nv = scope.push(num);
    const dv = scope.push(den);
    const h = try gc.alloc(.ratio, 2);
    storeValue(gc, h, bodyValueSlot(h, 0), nv.*);
    storeValue(gc, h, bodyValueSlot(h, 1), dv.*);
    return value_mod.fromPtr(h);
}

pub fn ratioNum(v: Value) Value {
    return bodyValueSlot(value_mod.ptrVal(v), 0).*;
}

pub fn ratioDen(v: Value) Value {
    return bodyValueSlot(value_mod.ptrVal(v), 1).*;
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

// -------------------- Fiber handle (zepo-4d6) --------------------
// A fiber handle is its own GC kind (.fiber), allocated in old-gen. Body:
//   body[0] = status (raw): FIBER_RUNNING | FIBER_DONE | FIBER_ERRORED
//   body[1] = result (Value): NIL while running; on completion the fiber's
//             return value (done) or raised value (errored). Traced as a GC
//             child via the layout table, so it stays live while the handle is.
//   body[2] = FiberState pointer (raw): valid while running, 0 once reaped.
// The terminal status+result live in the handle (not the FiberState) so the
// FiberState can be freed the moment the fiber completes — keeping the GC root
// scan proportional to the number of *active* fibers, not all ever spawned.

pub const FIBER_RUNNING: u64 = 0;
pub const FIBER_DONE: u64 = 1;
pub const FIBER_ERRORED: u64 = 2;

pub fn makeFiber(gc: *GC, fs_ptr: *anyopaque) !Value {
    // Allocate in the nursery (not old-gen like foreign): a spawn-then-join
    // handle is short-lived garbage that minor GC reclaims cheaply. It has no
    // finalizer, so the nursery's lack of a dead-object walk is fine. A handle
    // that outlives a minor is promoted to old-gen by the normal copying path.
    const h = try gc.alloc(.fiber, 3);
    const body: [*]u64 = @ptrFromInt(@intFromPtr(h) + WORD);
    body[0] = FIBER_RUNNING;
    body[1] = @bitCast(value_mod.NIL);
    body[2] = @intFromPtr(fs_ptr);
    return value_mod.fromPtr(h);
}

pub fn isFiber(v: Value) bool {
    return isKind(v, .fiber);
}

inline fn fiberBody(v: Value) [*]u64 {
    const h = value_mod.ptrVal(v);
    return @ptrFromInt(@intFromPtr(h) + WORD);
}

pub fn fiberStatus(v: Value) u64 {
    return fiberBody(v)[0];
}

pub fn fiberResult(v: Value) Value {
    return @bitCast(fiberBody(v)[1]);
}

pub fn fiberFsPtr(v: Value) ?*anyopaque {
    const raw = fiberBody(v)[2];
    return if (raw == 0) null else @ptrFromInt(@as(usize, @intCast(raw)));
}

/// Record terminal state on the handle. Writes the result through the GC write
/// barrier (the handle is an old-gen object that may now point at a young
/// result), sets the status, and clears the FiberState pointer.
pub fn fiberComplete(gc: *GC, v: Value, status: u64, result: Value) void {
    const body = fiberBody(v);
    const result_slot: *Value = @ptrCast(@alignCast(&body[1]));
    gc.writeBarrier(value_mod.ptrVal(v), result_slot, result);
    body[0] = status;
    result_slot.* = result;
    body[2] = 0;
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
pub fn isBytevector(v: Value) bool { // zepo-9qg
    return isKind(v, .bytevector);
}
pub fn isParameter(v: Value) bool { // zepo-6o3p
    return isKind(v, .parameter);
}

pub fn isNumber(v: Value) bool {
    return value_mod.isFixnum(v) or isFloat(v) or isBignum(v) or isRatio(v); // zepo-nfak, zepo-or1d
}

pub fn isProcedure(v: Value) bool {
    return isClosure(v) or isPrim(v) or isParameter(v); // zepo-6o3p: parameters are callable
}
