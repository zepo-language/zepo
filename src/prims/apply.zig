//! `apply`, `not`, `values`, `call-with-values` primitives.

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

pub fn primNot(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    return if (value_mod.isFalsy(args[0])) value_mod.TRUE else value_mod.FALSE;
}

pub fn primApply(vm: *VM, args: []const Value) LispError!Value {
    if (args.len < 2) return error.ArityMismatch;
    const proc = args[0];
    if (!objects.isProcedure(proc)) return error.TypeError;
    const middle = args[1 .. args.len - 1];
    const tail_list = args[args.len - 1];

    // Flatten.
    var buf: [256]Value = undefined;
    var n: usize = 0;
    for (middle) |a| {
        if (n >= buf.len) return error.ArityMismatch;
        buf[n] = a;
        n += 1;
    }
    var cur = tail_list;
    while (!value_mod.isNil(cur)) {
        if (!objects.isPair(cur)) return error.TypeError;
        if (n >= buf.len) return error.ArityMismatch;
        buf[n] = objects.pairCar(cur).*;
        n += 1;
        cur = objects.pairCdr(cur).*;
    }

    // Dispatch on proc kind.
    if (objects.isClosure(proc)) {
        const fn_id = objects.closureCodePtr(proc);
        if (fn_id >= vm.compiled_fns.len) return error.ContractViolation;
        const tgt = vm.compiled_fns[@intCast(fn_id)]; // zepo-nhl
        return vm.execFn(tgt, proc, buf[0..n]);
    }
    // Prim.
    const raw = objects.primFnPtr(proc);
    const pfn: vm_mod.PrimFn = @ptrFromInt(@as(usize, @intCast(raw)));
    return pfn(vm, buf[0..n]);
}

// ── Multiple values ───────────────────────────────────────────────────────────

const VALUES_TAG = "#values";

fn isValuesBox(v: Value) bool {
    if (!objects.isPair(v)) return false;
    const head = objects.pairCar(v).*;
    if (!objects.isSymbol(head)) return false;
    return std.mem.eql(u8, objects.symbolName(head), VALUES_TAG);
}

fn callProc(vm: *VM, proc: Value, call_args: []const Value) LispError!Value {
    if (objects.isClosure(proc)) {
        const fn_id = objects.closureCodePtr(proc);
        if (fn_id >= vm.compiled_fns.len) return error.ContractViolation;
        const tgt = vm.compiled_fns[@intCast(fn_id)]; // zepo-nhl
        return vm.execFn(tgt, proc, call_args);
    }
    const raw = objects.primFnPtr(proc);
    const pfn: vm_mod.PrimFn = @ptrFromInt(@as(usize, @intCast(raw)));
    return pfn(vm, call_args);
}

pub fn primValues(vm: *VM, args: []const Value) LispError!Value {
    if (args.len == 1) return args[0];
    var result: Value = value_mod.NIL;
    var i: usize = args.len;
    while (i > 0) {
        i -= 1;
        result = objects.makePair(vm.gc, args[i], result) catch return error.OutOfMemory;
    }
    const tag = vm.symbols.intern(VALUES_TAG) catch return error.OutOfMemory;
    return objects.makePair(vm.gc, tag, result) catch return error.OutOfMemory;
}

pub fn primCallWithValues(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const producer = args[0];
    const consumer = args[1];
    if (!objects.isProcedure(producer) or !objects.isProcedure(consumer)) return error.TypeError;

    const result = try callProc(vm, producer, &[_]Value{});

    var call_args: [256]Value = undefined;
    var n: usize = 0;
    if (isValuesBox(result)) {
        var cur = objects.pairCdr(result).*;
        while (!value_mod.isNil(cur)) {
            if (!objects.isPair(cur)) break;
            if (n >= call_args.len) return error.ArityMismatch;
            call_args[n] = objects.pairCar(cur).*;
            n += 1;
            cur = objects.pairCdr(cur).*;
        }
    } else {
        call_args[0] = result;
        n = 1;
    }

    return callProc(vm, consumer, call_args[0..n]);
}
