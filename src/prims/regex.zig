//! POSIX ERE regex primitives via @cImport(<regex.h>).

const std = @import("std");
const c = @cImport({
    @cInclude("regex.h");
});
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const errs = @import("../runtime/errors.zig");
const LispError = errs.LispError;

pub const TAG_REGEX: u64 = 0x72656778; // "regx"

const MAX_GROUPS: usize = 32;

const CompiledRegex = struct {
    re: c.regex_t,
    allocator: std.mem.Allocator,
};

fn deinitRegex(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const rx: *CompiledRegex = @alignCast(@ptrCast(p));
        c.regfree(&rx.re);
        rx.allocator.destroy(rx);
    }
}

fn isRegex(v: Value) bool {
    return objects.isForeign(v) and objects.foreignTypeTag(v) == TAG_REGEX;
}

pub fn primRegexCompile(vm: *VM, args: []const Value) LispError!Value {
    if (args.len < 1 or args.len > 2) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.ContractViolation;
    const pattern = objects.stringBytes(args[0]);

    var flags: c_int = c.REG_EXTENDED;
    if (args.len == 2 and objects.isString(args[1])) {
        for (objects.stringBytes(args[1])) |ch| {
            if (ch == 'i') flags |= c.REG_ICASE;
            if (ch == 'n') flags |= c.REG_NEWLINE;
        }
    }

    const patz = vm.allocator.dupeZ(u8, pattern) catch return error.OutOfMemory;
    defer vm.allocator.free(patz);

    const rx = vm.allocator.create(CompiledRegex) catch return error.OutOfMemory;
    const ret = c.regcomp(&rx.re, patz.ptr, flags);
    if (ret != 0) {
        vm.allocator.destroy(rx);
        var errbuf: [256]u8 = undefined;
        _ = c.regerror(ret, null, &errbuf, errbuf.len);
        const msg = std.fmt.allocPrint(vm.allocator, "regex-compile: {s}", .{
            std.mem.sliceTo(&errbuf, 0),
        }) catch return error.OutOfMemory;
        if (vm.error_msg) |old| vm.allocator.free(old);
        vm.error_msg = msg;
        return error.UserError;
    }
    rx.allocator = vm.allocator;
    return objects.makeForeign(vm.gc, rx, deinitRegex, TAG_REGEX) catch return error.OutOfMemory;
}

pub fn primRegexExec(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!isRegex(args[0])) return error.ContractViolation;
    if (!objects.isString(args[1])) return error.ContractViolation;

    const rx: *CompiledRegex = @alignCast(@ptrCast(objects.foreignPayload(args[0]).?));
    const subject = objects.stringBytes(args[1]);
    const subz = vm.allocator.dupeZ(u8, subject) catch return error.OutOfMemory;
    defer vm.allocator.free(subz);

    var matches: [MAX_GROUPS]c.regmatch_t = undefined;
    const ret = c.regexec(&rx.re, subz.ptr, MAX_GROUPS, &matches, 0);
    if (ret != 0) return value_mod.FALSE;

    // Build result alist: ((match . "...") (start . N) (end . N) (groups . (...)))
    const m0 = matches[0];
    const start: i63 = @intCast(m0.rm_so);
    const end: i63 = @intCast(m0.rm_eo);
    const match_str = subject[@intCast(m0.rm_so)..@intCast(m0.rm_eo)];
    const match_val = objects.makeString(vm.gc, match_str) catch return error.OutOfMemory;

    // Collect capture groups (indices 1..N where rm_so != -1)
    var groups = value_mod.NIL;
    var gi: usize = MAX_GROUPS - 1;
    while (gi >= 1) : (gi -= 1) {
        const gm = matches[gi];
        if (gm.rm_so == -1) continue;
        const gs = subject[@intCast(gm.rm_so)..@intCast(gm.rm_eo)];
        const gv = objects.makeString(vm.gc, gs) catch return error.OutOfMemory;
        groups = objects.makePair(vm.gc, gv, groups) catch return error.OutOfMemory;
    }

    // Build alist in reverse
    const sym_groups = vm.symbols.intern("groups") catch return error.OutOfMemory;
    const sym_end = vm.symbols.intern("end") catch return error.OutOfMemory;
    const sym_start = vm.symbols.intern("start") catch return error.OutOfMemory;
    const sym_match = vm.symbols.intern("match") catch return error.OutOfMemory;

    var alist = value_mod.NIL;
    const groups_pair = objects.makePair(vm.gc, sym_groups, groups) catch return error.OutOfMemory;
    alist = objects.makePair(vm.gc, groups_pair, alist) catch return error.OutOfMemory;
    const end_pair = objects.makePair(vm.gc, sym_end, value_mod.fixnum(end)) catch return error.OutOfMemory;
    alist = objects.makePair(vm.gc, end_pair, alist) catch return error.OutOfMemory;
    const start_pair = objects.makePair(vm.gc, sym_start, value_mod.fixnum(start)) catch return error.OutOfMemory;
    alist = objects.makePair(vm.gc, start_pair, alist) catch return error.OutOfMemory;
    const match_pair = objects.makePair(vm.gc, sym_match, match_val) catch return error.OutOfMemory;
    alist = objects.makePair(vm.gc, match_pair, alist) catch return error.OutOfMemory;

    return alist;
}

pub fn primRegexQ(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 1) return error.ArityMismatch;
    return if (isRegex(args[0])) value_mod.TRUE else value_mod.FALSE;
}
