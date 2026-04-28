//! JSON binding: exposes json-parse, json-stringify, json-null? as prims.
//!
//! Uses std.json internally. Returns fully-reified Lisp values (alists /
//! vectors / strings / numbers / 'null), not FFI handles — this is the
//! application-level shape decided in zepo-2id's design session.
//!
//! Result shape:
//!   (json-parse "<...>")     => (ok . <lisp-value>) | (err <kind-sym> <msg-str>)
//!   (json-stringify <value>) => (ok . "<json>")     | (err <kind-sym> <msg-str>)
//!
//! Value mapping:
//!   null                      => 'null
//!   true / false              => #t / #f
//!   integer (fits i63)        => fixnum
//!   integer (overflow) / float=> float (approximate)
//!   number_string             => float fallback (approximate)
//!   string                    => lisp string
//!   array                     => lisp vector
//!   object                    => alist ( (key . value) ... ), keys as strings

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;

const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;
const HandleScope = gc_mod.HandleScope;

const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;

const errors = @import("../runtime/errors.zig");
const LispError = errors.LispError;

// ───────────────── helpers ─────────────────

fn okResult(vm: *VM, inner: Value) LispError!Value {
    const ok_sym = try vm.symbols.intern("ok");
    return objects.makePair(vm.gc, ok_sym, inner) catch return error.OutOfMemory;
}

fn errResult(vm: *VM, kind: []const u8, message: []const u8) LispError!Value {
    const err_tag = try vm.symbols.intern("err");
    const kind_sym = try vm.symbols.intern(kind);
    const msg_str = objects.makeString(vm.gc, message) catch return error.OutOfMemory;
    const inner2 = objects.makePair(vm.gc, msg_str, value_mod.NIL) catch return error.OutOfMemory;
    const inner1 = objects.makePair(vm.gc, kind_sym, inner2) catch return error.OutOfMemory;
    return objects.makePair(vm.gc, err_tag, inner1) catch return error.OutOfMemory;
}

fn nullSym(vm: *VM) LispError!Value {
    return vm.symbols.intern("null");
}

// ───────────────── std.json.Value → Lisp ─────────────────

fn marshalJson(vm: *VM, jv: std.json.Value) LispError!Value {
    switch (jv) {
        .null => return nullSym(vm),
        .bool => |b| return if (b) value_mod.TRUE else value_mod.FALSE,
        .integer => |n| {
            const max_fixnum: i64 = (1 << 62) - 1;
            const min_fixnum: i64 = -(1 << 62);
            if (n <= max_fixnum and n >= min_fixnum) return value_mod.fixnum(@intCast(n));
            return objects.makeFloat(vm.gc, @floatFromInt(n)) catch return error.OutOfMemory;
        },
        .float => |f| return objects.makeFloat(vm.gc, f) catch return error.OutOfMemory,
        .number_string => |s| {
            // Fallback path: try i64 then f64.
            if (std.fmt.parseInt(i64, s, 10)) |n| {
                const max_fixnum: i64 = (1 << 62) - 1;
                const min_fixnum: i64 = -(1 << 62);
                if (n <= max_fixnum and n >= min_fixnum) return value_mod.fixnum(@intCast(n));
                return objects.makeFloat(vm.gc, @floatFromInt(n)) catch return error.OutOfMemory;
            } else |_| {}
            if (std.fmt.parseFloat(f64, s)) |f| {
                return objects.makeFloat(vm.gc, f) catch return error.OutOfMemory;
            } else |_| {}
            return error.TypeError;
        },
        .string => |s| return objects.makeString(vm.gc, s) catch return error.OutOfMemory,
        .array => |arr| {
            // Build a vector of length arr.items.len.
            const len = arr.items.len;
            const h = vm.gc.alloc(.vector, len + 1) catch return error.OutOfMemory;
            const body: [*]u64 = @ptrFromInt(@intFromPtr(h) + 8);
            body[0] = @as(u64, @intCast(len));
            // Initialize slots to NIL before filling so a mid-fill GC stays consistent.
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const slot: *Value = @ptrFromInt(@intFromPtr(h) + 8 + (i + 1) * 8);
                slot.* = value_mod.NIL;
            }
            const vec = value_mod.fromPtr(h);
            var scope = HandleScope{};
            vm.gc.roots.pushHandleScope(&scope);
            defer vm.gc.roots.popHandleScope();
            const vec_slot = scope.push(vec);
            i = 0;
            while (i < len) : (i += 1) {
                const child = try marshalJson(vm, arr.items[i]);
                const slot: *Value = @ptrFromInt(@intFromPtr(value_mod.ptrVal(vec_slot.*)) + 8 + (i + 1) * 8);
                objects.storeValue(vm.gc, value_mod.ptrVal(vec_slot.*), slot, child);
            }
            return vec_slot.*;
        },
        .object => |obj| {
            const ht = @import("../runtime/hashtable.zig").make(vm.gc) catch return error.OutOfMemory;
            var scope = HandleScope{};
            vm.gc.roots.pushHandleScope(&scope);
            defer vm.gc.roots.popHandleScope();
            const ht_slot = scope.push(ht);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key_str = objects.makeString(vm.gc, entry.key_ptr.*) catch return error.OutOfMemory;
                const key_slot = scope.push(key_str);
                const val = try marshalJson(vm, entry.value_ptr.*);
                const val_slot = scope.push(val);
                _ = @import("../runtime/hashtable.zig").set(vm.gc, vm, ht_slot.*, key_slot.*, val_slot.*) catch return error.OutOfMemory;
            }
            return ht_slot.*;
        },
    }
}

// ───────────────── primitives ─────────────────

pub fn primJsonParse(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    const src = objects.stringBytes(args[0]);

    const a = vm.gc.allocator;
    var parsed = std.json.parseFromSlice(std.json.Value, a, src, .{}) catch |e| {
        return errResult(vm, @errorName(e), @errorName(e));
    };
    defer parsed.deinit();

    const lisp_val = try marshalJson(vm, parsed.value);
    return okResult(vm, lisp_val);
}

pub fn primJsonNullQ(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isSymbol(args[0])) return value_mod.FALSE;
    const name = objects.symbolName(args[0]);
    _ = vm;
    return if (std.mem.eql(u8, name, "null")) value_mod.TRUE else value_mod.FALSE;
}

// ───────────────── Lisp → JSON string ─────────────────

fn writeJson(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: Value) !void {
    // Order of checks matters — check null sym first before generic symbol.
    if (value_mod.isFixnum(v)) {
        try buf.writer(a).print("{d}", .{value_mod.fixnumVal(v)});
        return;
    }
    if (v == value_mod.TRUE) {
        try buf.appendSlice(a, "true");
        return;
    }
    if (v == value_mod.FALSE) {
        try buf.appendSlice(a, "false");
        return;
    }
    if (objects.isSymbol(v) and std.mem.eql(u8, objects.symbolName(v), "null")) {
        try buf.appendSlice(a, "null");
        return;
    }
    if (objects.isFloat(v)) {
        try buf.writer(a).print("{d}", .{objects.floatVal(v)});
        return;
    }
    if (objects.isString(v)) {
        const bytes = objects.stringBytes(v);
        try buf.append(a, '"');
        for (bytes) |c| {
            switch (c) {
                '"' => try buf.appendSlice(a, "\\\""),
                '\\' => try buf.appendSlice(a, "\\\\"),
                '\n' => try buf.appendSlice(a, "\\n"),
                '\r' => try buf.appendSlice(a, "\\r"),
                '\t' => try buf.appendSlice(a, "\\t"),
                else => try buf.append(a, c),
            }
        }
        try buf.append(a, '"');
        return;
    }
    if (objects.isVector(v)) {
        const h = value_mod.ptrVal(v);
        const body: [*]u64 = @ptrFromInt(@intFromPtr(h) + 8);
        const len: usize = @intCast(body[0]);
        try buf.append(a, '[');
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (i > 0) try buf.append(a, ',');
            const slot: *Value = @ptrFromInt(@intFromPtr(h) + 8 + (i + 1) * 8);
            try writeJson(buf, a, slot.*);
        }
        try buf.append(a, ']');
        return;
    }
    const ht_mod = @import("../runtime/hashtable.zig");
    if (ht_mod.isHashTable(v)) {
        try buf.append(a, '{');
        const Ctx = struct { buf: *std.ArrayList(u8), a: std.mem.Allocator, first: bool, err: ?anyerror };
        var ctx2 = Ctx{ .buf = buf, .a = a, .first = true, .err = null };
        ht_mod.forEach(v, &ctx2, struct {
            fn visit(raw: *anyopaque, k: Value, val: Value) void {
                const c: *Ctx = @ptrCast(@alignCast(raw));
                if (c.err != null) return;
                if (!c.first) c.buf.append(c.a, ',') catch { c.err = error.OutOfMemory; return; };
                c.first = false;
                writeJson(c.buf, c.a, k) catch |e| { c.err = e; return; };
                c.buf.append(c.a, ':') catch { c.err = error.OutOfMemory; return; };
                writeJson(c.buf, c.a, val) catch |e| { c.err = e; return; };
            }
        }.visit);
        if (ctx2.err) |e| return e;
        try buf.append(a, '}');
        return;
    }
    if (objects.isPair(v)) {
        // Alist fallback: ((key . val) ...).
        try buf.append(a, '{');
        var cur = v;
        var first = true;
        while (objects.isPair(cur)) {
            const cell = objects.pairCar(cur).*;
            if (!objects.isPair(cell)) return error.UnexpectedShape;
            const key = objects.pairCar(cell).*;
            const val = objects.pairCdr(cell).*;
            if (!objects.isString(key)) return error.UnexpectedShape;
            if (!first) try buf.append(a, ',');
            first = false;
            try writeJson(buf, a, key);
            try buf.append(a, ':');
            try writeJson(buf, a, val);
            cur = objects.pairCdr(cur).*;
        }
        try buf.append(a, '}');
        return;
    }
    return error.UnexpectedShape;
}

pub fn primJsonStringify(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const a = vm.gc.allocator;
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(a);

    writeJson(&buf, a, args[0]) catch |e| {
        return errResult(vm, @errorName(e), @errorName(e));
    };

    const lisp_str = objects.makeString(vm.gc, buf.items) catch return error.OutOfMemory;
    return okResult(vm, lisp_str);
}
