// zepo-9qg: Bytevector primitives (R7RS-compatible) + endian helpers.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;

const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const errs = @import("../runtime/errors.zig");
const LispError = errs.LispError;

// ── Helpers ────────────────────────────────────────────────────────────────

/// Coerce a fixnum Value to a usize index.
inline fn asUsize(v: Value) LispError!usize {
    if (!value_mod.isFixnum(v)) return error.TypeError;
    const i = value_mod.fixnumVal(v);
    if (i < 0) return error.ContractViolation;
    return @intCast(i);
}

/// Coerce a fixnum to a u8 byte value (0..255).
inline fn asByte(v: Value) LispError!u8 {
    if (!value_mod.isFixnum(v)) return error.TypeError;
    const n = value_mod.fixnumVal(v);
    if (n < 0 or n > 255) return error.InvalidForm;
    return @intCast(n);
}

// ── Core constructors ──────────────────────────────────────────────────────

/// (make-bytevector n) or (make-bytevector n fill)
pub fn primMakeBytevector(vm: *VM, args: []const Value) LispError!Value {
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    const n = try asUsize(args[0]);
    const fill: u8 = if (args.len == 2) try asByte(args[1]) else 0;
    return objects.makeBytevector(vm.gc, n, fill) catch return error.OutOfMemory;
}

/// (bytevector b ...) — construct from individual bytes
pub fn primBytevector(vm: *VM, args: []const Value) LispError!Value {
    const bv = objects.makeBytevector(vm.gc, args.len, 0) catch return error.OutOfMemory;
    const bytes = objects.bytevectorBytes(bv);
    for (args, 0..) |a, i| {
        bytes[i] = try asByte(a);
    }
    return bv;
}

// ── Predicates & accessors ─────────────────────────────────────────────────

pub fn primBytevectorQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    return if (objects.isBytevector(args[0])) value_mod.TRUE else value_mod.FALSE;
}

pub fn primBytevectorLength(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isBytevector(args[0])) return error.TypeError;
    const n = objects.bytevectorLen(args[0]);
    return value_mod.fixnum(@intCast(n));
}

pub fn primBytevectorU8Ref(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!objects.isBytevector(args[0])) return error.TypeError;
    const idx = try asUsize(args[1]);
    const bytes = objects.bytevectorBytes(args[0]);
    if (idx >= bytes.len) return error.ContractViolation;
    return value_mod.fixnum(@intCast(bytes[idx]));
}

pub fn primBytevectorU8Set(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 3) return error.ArityMismatch;
    if (!objects.isBytevector(args[0])) return error.TypeError;
    const idx = try asUsize(args[1]);
    const b = try asByte(args[2]);
    const bytes = objects.bytevectorBytes(args[0]);
    if (idx >= bytes.len) return error.ContractViolation;
    bytes[idx] = b;
    return value_mod.NIL;
}

// ── Copy & append ──────────────────────────────────────────────────────────

/// (bytevector-copy bv) or (bytevector-copy bv start) or (bytevector-copy bv start end)
pub fn primBytevectorCopy(vm: *VM, args: []const Value) LispError!Value {
    if (args.len < 1 or args.len > 3) return error.ArityMismatch;
    if (!objects.isBytevector(args[0])) return error.TypeError;
    const src = objects.bytevectorBytes(args[0]);
    const start: usize = if (args.len >= 2) try asUsize(args[1]) else 0;
    const end: usize = if (args.len >= 3) try asUsize(args[2]) else src.len;
    if (start > end or end > src.len) return error.ContractViolation;
    const slice = src[start..end];
    const bv = objects.makeBytevector(vm.gc, slice.len, 0) catch return error.OutOfMemory;
    const dst = objects.bytevectorBytes(bv);
    @memcpy(dst, slice);
    return bv;
}

/// (bytevector-append bv ...) — variadic
pub fn primBytevectorAppend(vm: *VM, args: []const Value) LispError!Value {
    var total: usize = 0;
    for (args) |a| {
        if (!objects.isBytevector(a)) return error.TypeError;
        total += objects.bytevectorLen(a);
    }
    const bv = objects.makeBytevector(vm.gc, total, 0) catch return error.OutOfMemory;
    const dst = objects.bytevectorBytes(bv);
    var off: usize = 0;
    for (args) |a| {
        const src = objects.bytevectorBytes(a);
        @memcpy(dst[off .. off + src.len], src);
        off += src.len;
    }
    return bv;
}

// ── String conversions ─────────────────────────────────────────────────────

/// (bytevector->string bv) — interprets bytes as UTF-8
pub fn primBytevectorToString(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isBytevector(args[0])) return error.TypeError;
    const bytes = objects.bytevectorBytes(args[0]);
    return objects.makeString(vm.gc, bytes) catch return error.OutOfMemory;
}

/// (string->bytevector str) — encodes as UTF-8 bytes
pub fn primStringToBytevector(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    const bytes = objects.stringBytes(args[0]);
    const bv = objects.makeBytevector(vm.gc, bytes.len, 0) catch return error.OutOfMemory;
    const dst = objects.bytevectorBytes(bv);
    @memcpy(dst, bytes);
    return bv;
}

// ── Endian helpers ─────────────────────────────────────────────────────────

pub fn primBytevectorU16BeRef(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!objects.isBytevector(args[0])) return error.TypeError;
    const off = try asUsize(args[1]);
    const bytes = objects.bytevectorBytes(args[0]);
    if (off + 1 >= bytes.len) return error.ContractViolation;
    const v: u16 = (@as(u16, bytes[off]) << 8) | @as(u16, bytes[off + 1]);
    return value_mod.fixnum(@intCast(v));
}

pub fn primBytevectorU16LeRef(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!objects.isBytevector(args[0])) return error.TypeError;
    const off = try asUsize(args[1]);
    const bytes = objects.bytevectorBytes(args[0]);
    if (off + 1 >= bytes.len) return error.ContractViolation;
    const v: u16 = (@as(u16, bytes[off + 1]) << 8) | @as(u16, bytes[off]);
    return value_mod.fixnum(@intCast(v));
}

pub fn primBytevectorU32BeRef(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!objects.isBytevector(args[0])) return error.TypeError;
    const off = try asUsize(args[1]);
    const bytes = objects.bytevectorBytes(args[0]);
    if (off + 3 >= bytes.len) return error.ContractViolation;
    const v: u32 = (@as(u32, bytes[off]) << 24) |
        (@as(u32, bytes[off + 1]) << 16) |
        (@as(u32, bytes[off + 2]) << 8) |
        @as(u32, bytes[off + 3]);
    return value_mod.fixnum(@intCast(v));
}

pub fn primBytevectorU32LeRef(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!objects.isBytevector(args[0])) return error.TypeError;
    const off = try asUsize(args[1]);
    const bytes = objects.bytevectorBytes(args[0]);
    if (off + 3 >= bytes.len) return error.ContractViolation;
    const v: u32 = (@as(u32, bytes[off + 3]) << 24) |
        (@as(u32, bytes[off + 2]) << 16) |
        (@as(u32, bytes[off + 1]) << 8) |
        @as(u32, bytes[off]);
    return value_mod.fixnum(@intCast(v));
}

pub fn primBytevectorU16BeSet(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 3) return error.ArityMismatch;
    if (!objects.isBytevector(args[0])) return error.TypeError;
    const off = try asUsize(args[1]);
    const bytes = objects.bytevectorBytes(args[0]);
    if (off + 1 >= bytes.len) return error.ContractViolation;
    if (!value_mod.isFixnum(args[2])) return error.TypeError;
    const raw: i63 = value_mod.fixnumVal(args[2]);
    const v: u16 = @intCast(@as(u64, @intCast(@mod(raw, 65536))));
    bytes[off] = @intCast(v >> 8);
    bytes[off + 1] = @intCast(v & 0xFF);
    return value_mod.NIL;
}

pub fn primBytevectorU16LeSet(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 3) return error.ArityMismatch;
    if (!objects.isBytevector(args[0])) return error.TypeError;
    const off = try asUsize(args[1]);
    const bytes = objects.bytevectorBytes(args[0]);
    if (off + 1 >= bytes.len) return error.ContractViolation;
    if (!value_mod.isFixnum(args[2])) return error.TypeError;
    const raw: i63 = value_mod.fixnumVal(args[2]);
    const v: u16 = @intCast(@as(u64, @intCast(@mod(raw, 65536))));
    bytes[off] = @intCast(v & 0xFF);
    bytes[off + 1] = @intCast(v >> 8);
    return value_mod.NIL;
}

pub fn primBytevectorU32BeSet(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 3) return error.ArityMismatch;
    if (!objects.isBytevector(args[0])) return error.TypeError;
    const off = try asUsize(args[1]);
    const bytes = objects.bytevectorBytes(args[0]);
    if (off + 3 >= bytes.len) return error.ContractViolation;
    if (!value_mod.isFixnum(args[2])) return error.TypeError;
    const raw: i64 = value_mod.fixnumVal(args[2]);
    const v: u32 = @truncate(@as(u64, @bitCast(raw)));
    bytes[off] = @intCast((v >> 24) & 0xFF);
    bytes[off + 1] = @intCast((v >> 16) & 0xFF);
    bytes[off + 2] = @intCast((v >> 8) & 0xFF);
    bytes[off + 3] = @intCast(v & 0xFF);
    return value_mod.NIL;
}

pub fn primBytevectorU32LeSet(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 3) return error.ArityMismatch;
    if (!objects.isBytevector(args[0])) return error.TypeError;
    const off = try asUsize(args[1]);
    const bytes = objects.bytevectorBytes(args[0]);
    if (off + 3 >= bytes.len) return error.ContractViolation;
    if (!value_mod.isFixnum(args[2])) return error.TypeError;
    const raw: i64 = value_mod.fixnumVal(args[2]);
    const v: u32 = @truncate(@as(u64, @bitCast(raw)));
    bytes[off] = @intCast(v & 0xFF);
    bytes[off + 1] = @intCast((v >> 8) & 0xFF);
    bytes[off + 2] = @intCast((v >> 16) & 0xFF);
    bytes[off + 3] = @intCast((v >> 24) & 0xFF);
    return value_mod.NIL;
}
