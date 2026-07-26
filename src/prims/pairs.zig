//! Pair primitives: cons, car, cdr, pair?, null?.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const io = @import("io.zig"); // zepo-nwaw: render a raised payload for diagnostics

const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const errs = @import("../runtime/errors.zig");
const LispError = errs.LispError;

pub fn primCons(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    // args[] lives in the register file; read AFTER gc.alloc so vmRootVisit can update them
    return objects.makePairFromSlots(vm.gc, &args[0], &args[1]) catch error.OutOfMemory;
}

pub fn primCar(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const p = args[0];
    if (!objects.isPair(p)) return error.CarOfNonPair;
    return objects.pairCar(p).*;
}

pub fn primCdr(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    const p = args[0];
    if (!objects.isPair(p)) return error.CdrOfNonPair;
    return objects.pairCdr(p).*;
}

// zepo-asu1: (set-car! pair obj) / (set-cdr! pair obj) — in-place mutation via
// the generational write barrier (see objects.pairSetCar/pairSetCdr).
pub fn primSetCar(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!objects.isPair(args[0])) return error.TypeError;
    objects.pairSetCar(vm.gc, args[0], args[1]);
    return value_mod.NIL;
}

pub fn primSetCdr(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!objects.isPair(args[0])) return error.TypeError;
    objects.pairSetCdr(vm.gc, args[0], args[1]);
    return value_mod.NIL;
}

pub fn primPairQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    return if (objects.isPair(args[0])) value_mod.TRUE else value_mod.FALSE;
}

pub fn primNullQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    return if (value_mod.isNil(args[0])) value_mod.TRUE else value_mod.FALSE;
}

pub fn primList(vm: *VM, args: []const Value) LispError!Value {
    // (list a b c ...) => (a b c ...)
    // Root 'result' so GC can update it in-place if a minor collection triggers during construction.
    var result: Value = value_mod.NIL;
    vm.gc.roots.extra.append(vm.gc.allocator, &result) catch return error.OutOfMemory;
    const extra_base = vm.gc.roots.extra.items.len - 1;
    var i: usize = args.len;
    while (i > 0) {
        i -= 1;
        // args[i] lives in the register file (updated by vmRootVisit); result is an extra root.
        result = objects.makePairFromSlots(vm.gc, &args[i], &result) catch {
            vm.gc.roots.extra.shrinkRetainingCapacity(extra_base);
            return error.OutOfMemory;
        };
    }
    vm.gc.roots.extra.shrinkRetainingCapacity(extra_base);
    return result;
}

pub fn primVector(vm: *VM, args: []const Value) LispError!Value {
    const v = objects.makeVector(vm.gc, args.len, value_mod.NIL) catch return error.OutOfMemory;
    for (args, 0..) |a, i| objects.vectorSet(vm.gc, v, i, a);
    return v;
}

pub fn primMakeVector(vm: *VM, args: []const Value) LispError!Value {
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    if (!value_mod.isFixnum(args[0])) return error.TypeError;
    const n_i = value_mod.fixnumVal(args[0]);
    if (n_i < 0) return error.ContractViolation;
    const n: usize = @intCast(n_i);
    const fill = if (args.len == 2) args[1] else value_mod.NIL;
    return objects.makeVector(vm.gc, n, fill) catch error.OutOfMemory;
}

pub fn primVectorRef(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 2) return error.ArityMismatch;
    if (!objects.isVector(args[0])) return error.TypeError;
    if (!value_mod.isFixnum(args[1])) return error.TypeError;
    const idx_i = value_mod.fixnumVal(args[1]);
    if (idx_i < 0) return error.ContractViolation;
    const idx: usize = @intCast(idx_i);
    if (idx >= objects.vectorLen(args[0])) return error.ContractViolation;
    return objects.vectorGet(args[0], idx);
}

pub fn primVectorSet(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 3) return error.ArityMismatch;
    if (!objects.isVector(args[0])) return error.TypeError;
    if (!value_mod.isFixnum(args[1])) return error.TypeError;
    const idx_i = value_mod.fixnumVal(args[1]);
    if (idx_i < 0) return error.ContractViolation;
    const idx: usize = @intCast(idx_i);
    if (idx >= objects.vectorLen(args[0])) return error.ContractViolation;
    objects.vectorSet(vm.gc, args[0], idx, args[2]);
    return value_mod.NIL;
}

pub fn primVectorLength(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isVector(args[0])) return error.TypeError;
    return value_mod.fixnum(@intCast(objects.vectorLen(args[0])));
}

pub fn primVectorQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    return if (objects.isVector(args[0])) value_mod.TRUE else value_mod.FALSE;
}

// (vector-copy vec)  (vector-copy vec start)  (vector-copy vec start end)
pub fn primVectorCopy(vm: *VM, args: []const Value) LispError!Value {
    if (args.len < 1 or args.len > 3) return error.ArityMismatch;
    if (!objects.isVector(args[0])) return error.TypeError;
    const src = args[0];
    const len = objects.vectorLen(src);
    const start: usize = if (args.len >= 2) blk: {
        if (!value_mod.isFixnum(args[1])) return error.TypeError;
        const s = value_mod.fixnumVal(args[1]);
        if (s < 0 or @as(usize, @intCast(s)) > len) return error.ContractViolation;
        break :blk @intCast(s);
    } else 0;
    const end: usize = if (args.len >= 3) blk: {
        if (!value_mod.isFixnum(args[2])) return error.TypeError;
        const e = value_mod.fixnumVal(args[2]);
        if (e < 0 or @as(usize, @intCast(e)) > len or @as(usize, @intCast(e)) < start) return error.ContractViolation;
        break :blk @intCast(e);
    } else len;
    const new_len = end - start;
    const dst = objects.makeVector(vm.gc, new_len, value_mod.NIL) catch return error.OutOfMemory;
    var i: usize = 0;
    while (i < new_len) : (i += 1)
        objects.vectorSet(vm.gc, dst, i, objects.vectorGet(src, start + i));
    return dst;
}

// (vector-copy! to at from)  (vector-copy! to at from start)  (vector-copy! to at from start end)
pub fn primVectorCopyBang(vm: *VM, args: []const Value) LispError!Value {
    if (args.len < 3 or args.len > 5) return error.ArityMismatch;
    if (!objects.isVector(args[0])) return error.TypeError;
    if (!value_mod.isFixnum(args[1])) return error.TypeError;
    if (!objects.isVector(args[2])) return error.TypeError;
    const dst = args[0];
    const at_i = value_mod.fixnumVal(args[1]);
    if (at_i < 0) return error.ContractViolation;
    const at: usize = @intCast(at_i);
    const src = args[2];
    const src_len = objects.vectorLen(src);
    const start: usize = if (args.len >= 4) blk: {
        if (!value_mod.isFixnum(args[3])) return error.TypeError;
        const s = value_mod.fixnumVal(args[3]);
        if (s < 0) return error.ContractViolation;
        break :blk @intCast(s);
    } else 0;
    const end: usize = if (args.len >= 5) blk: {
        if (!value_mod.isFixnum(args[4])) return error.TypeError;
        const e = value_mod.fixnumVal(args[4]);
        if (e < 0) return error.ContractViolation;
        break :blk @intCast(e);
    } else src_len;
    const count = end - start;
    if (at + count > objects.vectorLen(dst)) return error.ContractViolation;
    var i: usize = 0;
    while (i < count) : (i += 1)
        objects.vectorSet(vm.gc, dst, at + i, objects.vectorGet(src, start + i));
    return value_mod.NIL;
}

// (vector-fill! vec val)  (vector-fill! vec val start)  (vector-fill! vec val start end)
pub fn primVectorFillBang(vm: *VM, args: []const Value) LispError!Value {
    if (args.len < 2 or args.len > 4) return error.ArityMismatch;
    if (!objects.isVector(args[0])) return error.TypeError;
    const vec = args[0];
    const val = args[1];
    const len = objects.vectorLen(vec);
    const start: usize = if (args.len >= 3) blk: {
        if (!value_mod.isFixnum(args[2])) return error.TypeError;
        const s = value_mod.fixnumVal(args[2]);
        if (s < 0) return error.ContractViolation;
        break :blk @intCast(s);
    } else 0;
    const end: usize = if (args.len >= 4) blk: {
        if (!value_mod.isFixnum(args[3])) return error.TypeError;
        const e = value_mod.fixnumVal(args[3]);
        if (e < 0) return error.ContractViolation;
        break :blk @intCast(e);
    } else len;
    if (start > end or end > len) return error.ContractViolation;
    var i: usize = start;
    while (i < end) : (i += 1)
        objects.vectorSet(vm.gc, vec, i, val);
    return value_mod.NIL;
}

// (vector-append vec ...)
pub fn primVectorAppend(vm: *VM, args: []const Value) LispError!Value {
    var total: usize = 0;
    for (args) |a| {
        if (!objects.isVector(a)) return error.TypeError;
        total += objects.vectorLen(a);
    }
    const dst = objects.makeVector(vm.gc, total, value_mod.NIL) catch return error.OutOfMemory;
    var at: usize = 0;
    for (args) |a| {
        const n = objects.vectorLen(a);
        var i: usize = 0;
        while (i < n) : (i += 1)
            objects.vectorSet(vm.gc, dst, at + i, objects.vectorGet(a, i));
        at += n;
    }
    return dst;
}

pub fn primStringLength(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    return value_mod.fixnum(@intCast(objects.stringLen(args[0])));
}

pub fn primStringAppend(vm: *VM, args: []const Value) LispError!Value {
    var total: usize = 0;
    for (args) |a| {
        if (!objects.isString(a)) return error.TypeError;
        total += objects.stringLen(a);
    }
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(vm.allocator);
    buf.ensureTotalCapacity(vm.allocator, total) catch return error.OutOfMemory;
    for (args) |a| {
        buf.appendSlice(vm.allocator, objects.stringBytes(a)) catch return error.OutOfMemory;
    }
    return objects.makeString(vm.gc, buf.items) catch error.OutOfMemory;
}

pub fn primNumberToString(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    var buf: [64]u8 = undefined;
    if (value_mod.isFixnum(args[0])) {
        const s = std.fmt.bufPrint(&buf, "{d}", .{value_mod.fixnumVal(args[0])}) catch return error.ContractViolation;
        return objects.makeString(vm.gc, s) catch error.OutOfMemory;
    }
    if (objects.isFloat(args[0])) {
        // zepo-mckx: R7RS float form (1.0 not 1; +inf.0/+nan.0 for non-finite).
        const s = objects.formatFloat(&buf, objects.floatVal(args[0]));
        return objects.makeString(vm.gc, s) catch error.OutOfMemory;
    }
    if (objects.isBignum(args[0])) { // zepo-nfak
        const s = runtime.bignum.toString(vm.gc.allocator, args[0]) catch return error.OutOfMemory;
        defer vm.gc.allocator.free(s);
        return objects.makeString(vm.gc, s) catch error.OutOfMemory;
    }
    return error.TypeError;
}

pub fn primError(vm: *VM, args: []const Value) LispError!Value {
    // Build a condition object: (list "error-object" message irritant...)
    // Irritants are the args after the message.
    const msg_val = if (args.len >= 1 and objects.isString(args[0]))
        args[0]
    else
        objects.makeString(vm.gc, "error") catch return error.OutOfMemory;

    var irritants: Value = value_mod.NIL;
    var i = args.len;
    while (i > 1) {
        i -= 1;
        irritants = objects.makePair(vm.gc, args[i], irritants) catch return error.OutOfMemory;
    }
    const tag = objects.makeString(vm.gc, "error-object") catch return error.OutOfMemory;
    const with_irritants = objects.makePair(vm.gc, irritants, value_mod.NIL) catch return error.OutOfMemory;
    const with_msg = objects.makePair(vm.gc, msg_val, with_irritants) catch return error.OutOfMemory;
    const condition = objects.makePair(vm.gc, tag, with_msg) catch return error.OutOfMemory;
    vm.raised_val = condition;

    // Keep error_msg for backwards-compat with any Zig-side error_msg checks.
    if (objects.isString(msg_val)) {
        if (vm.error_msg) |old| vm.allocator.free(old);
        vm.error_msg = vm.allocator.dupe(u8, objects.stringBytes(msg_val)) catch null;
    }
    // zepo-g120: run handler-bind (non-unwinding) handlers in place first; a
    // transfer (invoke-restart / inner unwinding handler) escapes here. If they
    // all decline, fall through to the unwinding-handler path via UserError.
    // Do NOT reset signal_floor here — a raise from inside a running handler is
    // a nested signal and must skip the active handler (signal saves/restores
    // the floor; tryHandle resets it to 0 when it finally consumes the error).
    try vm.signal(condition);
    return error.UserError;
}

pub fn primRaise(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    vm.raised_val = args[0];
    // zepo-nwaw: render the raised object into error_msg so an UNHANDLED raise —
    // at top level or in a fiber — reports the payload instead of a bare
    // "UserError". A caught raise ignores this (with-exception-handler prefers
    // raised_val and frees error_msg), so it only surfaces when nothing handles.
    if (!objects.isString(args[0])) {
        var msgbuf = std.ArrayListUnmanaged(u8).empty;
        defer msgbuf.deinit(vm.allocator);
        io.displayValue(&msgbuf, vm.allocator, args[0]) catch {};
        if (msgbuf.items.len > 0) {
            if (vm.error_msg) |old| vm.allocator.free(old);
            vm.error_msg = vm.allocator.dupe(u8, msgbuf.items) catch null;
        }
    } else {
        if (vm.error_msg) |old| vm.allocator.free(old);
        vm.error_msg = vm.allocator.dupe(u8, objects.stringBytes(args[0])) catch null;
    }
    try vm.signal(args[0]); // run handler-bind handlers in place (see primError)
    return error.UserError;
}

pub fn primWithExceptionHandler(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const handler = args[0];
    const thunk = args[1];
    // Record depth so we can unwind stale frames left by execFn on error.
    const depth_before = vm.call_stack.frames.items.len;
    const result = vm.callValue(thunk, &[_]Value{}) catch |err| {
        // zepo-ewdc: FiberYielded is a scheduler control-flow signal, not a
        // user error. Letting the handler catch it breaks the sleep/spawn/
        // channel-recv protocol — the scheduler needs to see this so it can
        // resume the fiber later. Re-raise without invoking the handler.
        // (Earlier observation 23748 noted a previous attempt at this fix
        // was reverted as a band-aid; this version keeps the depth-unwind
        // logic ONLY for actual user errors, so the scheduler sees its
        // own signal cleanly.)
        if (err == error.FiberYielded) return err;
        // zepo-g120: RestartInvoked is an internal restart transfer — must
        // reach the dispatch trampoline untouched, never invoke this handler.
        if (err == error.RestartInvoked) return err;
        // execFn leaves the failed frame on the call stack for diagnostics;
        // unwind back to the pre-thunk depth before invoking the handler so
        // that currentFrame() points at the correct outer frame.
        while (vm.call_stack.frames.items.len > depth_before) {
            _ = vm.call_stack.pop();
        }
        // Pass the raised value if set, otherwise wrap the Zig error name.
        const exc_val = if (!value_mod.isNil(vm.raised_val))
            vm.raised_val
        else blk: {
            const raw_msg: []const u8 = if (vm.error_msg) |m| m else @errorName(err);
            break :blk objects.makeString(vm.gc, raw_msg) catch return error.OutOfMemory;
        };
        vm.raised_val = value_mod.NIL;
        if (vm.error_msg) |m| {
            vm.allocator.free(m);
            vm.error_msg = null;
        }
        return vm.callValue(handler, &[_]Value{exc_val});
    };
    return result;
}

pub fn primErrorObjectQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const v = args[0];
    if (!objects.isPair(v)) return value_mod.FALSE;
    const tag = objects.pairCar(v).*;
    if (!objects.isString(tag)) return value_mod.FALSE;
    return if (std.mem.eql(u8, objects.stringBytes(tag), "error-object"))
        value_mod.TRUE
    else
        value_mod.FALSE;
}

pub fn primErrorObjectMessage(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const v = args[0];
    if (!objects.isPair(v)) return error.TypeError;
    const rest = objects.pairCdr(v).*;
    if (!objects.isPair(rest)) return error.TypeError;
    return objects.pairCar(rest).*;
}

pub fn primErrorObjectIrritants(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const v = args[0];
    if (!objects.isPair(v)) return error.TypeError;
    const rest = objects.pairCdr(v).*;
    if (!objects.isPair(rest)) return error.TypeError;
    const after_msg = objects.pairCdr(rest).*;
    if (!objects.isPair(after_msg)) return error.TypeError;
    return objects.pairCar(after_msg).*;
}

pub fn primStringRef(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 2) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    if (!value_mod.isFixnum(args[1])) return error.TypeError;
    const idx: usize = @intCast(value_mod.fixnumVal(args[1]));
    const bytes = objects.stringBytes(args[0]);
    if (idx >= bytes.len) return error.ContractViolation;
    return value_mod.char(@intCast(bytes[idx]));
}

pub fn primSubstring(vm: *VM, args: []const Value) LispError!Value {
    if (args.len < 2 or args.len > 3) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    if (!value_mod.isFixnum(args[1])) return error.TypeError;
    const bytes = objects.stringBytes(args[0]);
    const start: usize = @intCast(value_mod.fixnumVal(args[1]));
    const end: usize = if (args.len == 3) blk: {
        if (!value_mod.isFixnum(args[2])) return error.TypeError;
        break :blk @intCast(value_mod.fixnumVal(args[2]));
    } else bytes.len;
    if (start > end or end > bytes.len) return error.ContractViolation;
    // Copy to non-GC buffer before calling makeString: makeString calls gc.alloc
    // which can trigger a minor GC that moves the source string, leaving bytes stale.
    const slice = bytes[start..end];
    const copy = vm.allocator.dupe(u8, slice) catch return error.OutOfMemory;
    defer vm.allocator.free(copy);
    return objects.makeString(vm.gc, copy) catch error.OutOfMemory;
}

pub fn primStringToNumber(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    const s = objects.stringBytes(args[0]);
    if (std.fmt.parseInt(i63, s, 10)) |n| {
        return value_mod.fixnum(n);
    } else |_| {}
    // zepo-nfak: a whole-number string too big for a fixnum becomes an exact
    // bignum (not an imprecise float).
    if (isIntegerString(s)) {
        return runtime.bignum.fromDecimal(vm.gc, s) catch return error.OutOfMemory;
    }
    if (std.fmt.parseFloat(f64, s)) |f| {
        return objects.makeFloat(vm.gc, f) catch error.OutOfMemory;
    } else |_| {}
    return value_mod.FALSE;
}

// zepo-nfak: optional sign followed by one-or-more decimal digits.
fn isIntegerString(s: []const u8) bool {
    if (s.len == 0) return false;
    const digits = if (s[0] == '+' or s[0] == '-') s[1..] else s;
    if (digits.len == 0) return false;
    for (digits) |c| if (c < '0' or c > '9') return false;
    return true;
}

pub fn primSymbolToString(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isSymbol(args[0])) return error.TypeError;
    const name = objects.symbolName(args[0]);
    return objects.makeString(vm.gc, name) catch error.OutOfMemory;
}

pub fn primStringToSymbol(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    const name = objects.stringBytes(args[0]);
    return vm.symbols.intern(name) catch error.OutOfMemory;
}

// zepo-voc: (gensym) or (gensym prefix-string) — returns a fresh unique symbol.
// Names use the #: prefix which the reader never produces, preventing collisions.
pub fn primGensym(vm: *VM, args: []const Value) LispError!Value {
    if (args.len > 1) return error.ArityMismatch;
    const prefix: ?[]const u8 = if (args.len == 1) blk: {
        if (objects.isString(args[0])) break :blk objects.stringBytes(args[0]);
        if (objects.isSymbol(args[0])) break :blk objects.symbolName(args[0]);
        return error.TypeError;
    } else null;
    return vm.symbols.gensym(prefix) catch error.OutOfMemory;
}

pub fn primCharToInteger(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    if (!value_mod.isChar(args[0])) return error.TypeError;
    return value_mod.fixnum(@intCast(value_mod.charVal(args[0])));
}

pub fn primIntegerToChar(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    if (!value_mod.isFixnum(args[0])) return error.TypeError;
    const n = value_mod.fixnumVal(args[0]);
    if (n < 0 or n > 0x10FFFF) return error.ContractViolation;
    return value_mod.char(@intCast(n));
}

pub fn primStringUpcase(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    const bytes = objects.stringBytes(args[0]);
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(vm.allocator);
    for (bytes) |b| {
        buf.append(vm.allocator, if (b >= 'a' and b <= 'z') b - 32 else b) catch return error.OutOfMemory;
    }
    return objects.makeString(vm.gc, buf.items) catch error.OutOfMemory;
}

pub fn primStringDowncase(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    const bytes = objects.stringBytes(args[0]);
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(vm.allocator);
    for (bytes) |b| {
        buf.append(vm.allocator, if (b >= 'A' and b <= 'Z') b + 32 else b) catch return error.OutOfMemory;
    }
    return objects.makeString(vm.gc, buf.items) catch error.OutOfMemory;
}

pub fn primCharToString(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!value_mod.isChar(args[0])) return error.TypeError;
    const cp = value_mod.charVal(args[0]);
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return error.ContractViolation;
    return objects.makeString(vm.gc, buf[0..n]) catch error.OutOfMemory;
}

/// (getkey lst key default)
/// Walk a flat keyword-value list (:k1 v1 :k2 v2 ...) and return the value
/// paired with `key`, or `default` if not found.  Symbols are interned so
/// identity comparison is correct.
pub fn primGetkey(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 3) return error.ArityMismatch;
    var cur = args[0];
    const key = args[1];
    const default = args[2];
    while (!value_mod.isNil(cur)) {
        if (!objects.isPair(cur)) return error.TypeError;
        const k = objects.pairCar(cur).*;
        const rest = objects.pairCdr(cur).*;
        if (!objects.isPair(rest)) return error.TypeError;
        if (k == key) return objects.pairCar(rest).*;
        cur = objects.pairCdr(rest).*;
    }
    return default;
}
