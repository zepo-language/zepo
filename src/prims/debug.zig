//! Debug primitives — registered only in Debug builds.
//! zepo/debug-value: inspect a Value's raw representation without crashing.
//! zepo/gc-stats:    return a plist of live GC metrics.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const gc_mod = @import("../gc/collector.zig");
const HandleScope = gc_mod.HandleScope;
const nursery_mod = @import("../gc/nursery.zig");

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const SymbolTable = runtime.SymbolTable;

const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const errs = @import("../runtime/errors.zig");
const LispError = errs.LispError;

/// (zepo/debug-value v) → v
/// Prints a one-line description of v to stderr (raw bits, tag, kind if a
/// pointer, forwarding status) then returns v unchanged so it can be wrapped
/// around any expression without changing evaluation order.
pub fn primDebugValue(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const v = args[0];
    const stderr = std.fs.File.stderr();
    var buf: [256]u8 = undefined;

    if (!value_mod.isPtr(v)) {
        // Non-pointer: print tag class and raw bits.
        const tag_name = switch (value_mod.tag(v)) {
            .ptr => "ptr",
            .fixnum => "fixnum",
            .special => "special",
            .char => "char",
            _ => "unknown-tag",
        };
        const msg = std.fmt.bufPrint(&buf, "[debug-value] bits=0x{x:0>16} tag={s}\n", .{
            @as(u64, @bitCast(v)), tag_name,
        }) catch "[debug-value] fmt error\n";
        stderr.writeAll(msg) catch {};
    } else {
        const obj = value_mod.ptrVal(v);
        if (obj.isForward()) {
            const fwd = obj.forwardTo();
            const msg = std.fmt.bufPrint(&buf,
                "[debug-value] bits=0x{x:0>16} → FORWARDED to 0x{x} (header=0x{x})\n", .{
                    @as(u64, @bitCast(v)), @intFromPtr(fwd), obj.word,
                }) catch "[debug-value] fmt error\n";
            stderr.writeAll(msg) catch {};
        } else {
            _ = vm;
            const obj_kind = obj.kind();
            const space = obj.space();
            const msg = std.fmt.bufPrint(&buf,
                "[debug-value] bits=0x{x:0>16} ptr=0x{x} kind={s} space={s} header=0x{x}\n", .{
                    @as(u64, @bitCast(v)), @intFromPtr(obj),
                    @tagName(obj_kind), @tagName(space), obj.word,
                }) catch "[debug-value] fmt error\n";
            stderr.writeAll(msg) catch {};
        }
    }
    return v;
}

/// (zepo/gc-stats) → plist
/// Returns a flat keyword plist of current GC metrics:
///   :nursery-used  :nursery-free  :nursery-size
///   :minor-count   :major-count
///   :old-gen-used  :old-gen-size
pub fn primGcStats(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 0) return error.ArityMismatch;
    const gc = vm.gc;
    const nursery_used = gc.nursery.used();
    const nursery_size = nursery_mod.NURSERY_SIZE;
    const nursery_free = nursery_size - nursery_used;
    const old_used = gc.old_gen.usedBytes();
    const old_size = gc.old_gen.heapSize();

    // Build plist tail-first: result = (k1 v1 k2 v2 ...) as a proper list.
    const syms = vm.symbols;
    const knu = try syms.intern(":nursery-used");
    const knf = try syms.intern(":nursery-free");
    const kns = try syms.intern(":nursery-size");
    const kminor = try syms.intern(":minor-count");
    const kmajor = try syms.intern(":major-count");
    const kou = try syms.intern(":old-gen-used");
    const kos = try syms.intern(":old-gen-size");

    const fix = value_mod.fixnum;

    // Root lst across each makePair — each allocation can trigger a minor GC.
    var scope = HandleScope{};
    gc.roots.pushHandleScope(&scope);
    defer gc.roots.popHandleScope();
    const lst = scope.push(value_mod.NIL);

    // Build back-to-front: result will be (:nursery-used N :nursery-free N ...)
    inline for (.{
        .{ kos,    fix(@as(i63, @intCast(old_size)))         },
        .{ kou,    fix(@as(i63, @intCast(old_used)))         },
        .{ kmajor, fix(@as(i63, @intCast(gc.major_count)))   },
        .{ kminor, fix(@as(i63, @intCast(gc.minor_count)))   },
        .{ kns,    fix(@as(i63, @intCast(nursery_size)))     },
        .{ knf,    fix(@as(i63, @intCast(nursery_free)))     },
        .{ knu,    fix(@as(i63, @intCast(nursery_used)))     },
    }) |pair| {
        // Prepend value then key so final list reads (key value key value ...).
        lst.* = objects.makePair(gc, pair[1], lst.*) catch return error.OutOfMemory;
        lst.* = objects.makePair(gc, pair[0], lst.*) catch return error.OutOfMemory;
    }
    return lst.*;
}
