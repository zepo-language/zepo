//! Time primitives: current-time-ms, epoch->date, date->epoch, time-format.

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

pub fn primCurrentTimeMs(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 0) return error.ArityMismatch;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const ms: i63 = @intCast(ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000));
    return value_mod.fixnum(ms);
}

const MONTH_DAYS = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn monthDays(y: i64, m: i64) i64 {
    const md = MONTH_DAYS[@intCast(m - 1)];
    return if (m == 2 and isLeap(y)) md + 1 else md;
}

const Date = struct { year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64 };

fn secsToDate(secs: i64) Date {
    const tod = @mod(secs, 86400);
    var days = @divFloor(secs, 86400);

    const hour = @divFloor(tod, 3600);
    const minute = @divFloor(@mod(tod, 3600), 60);
    const second = @mod(tod, 60);

    var year: i64 = 1970;
    if (days >= 0) {
        while (true) {
            const ylen: i64 = if (isLeap(year)) 366 else 365;
            if (days < ylen) break;
            days -= ylen;
            year += 1;
        }
    } else {
        while (days < 0) {
            year -= 1;
            days += if (isLeap(year)) 366 else 365;
        }
    }

    var month: i64 = 1;
    while (month <= 12) : (month += 1) {
        const md = monthDays(year, month);
        if (days < md) break;
        days -= md;
    }

    return .{
        .year = year,
        .month = month,
        .day = days + 1,
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

fn dateToSecs(year: i64, month: i64, day: i64, hour: i64, minute: i64, second: i64) i64 {
    var days: i64 = 0;
    var y: i64 = 1970;
    if (year >= 1970) {
        while (y < year) : (y += 1) {
            days += if (isLeap(y)) 366 else 365;
        }
    } else {
        while (y > year) {
            y -= 1;
            days -= if (isLeap(y)) 366 else 365;
        }
    }
    var m: i64 = 1;
    while (m < month) : (m += 1) {
        days += monthDays(year, m);
    }
    days += day - 1;
    return days * 86400 + hour * 3600 + minute * 60 + second;
}

pub fn primEpochToDate(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!value_mod.isFixnum(args[0])) return error.ContractViolation;
    const ms = value_mod.fixnumVal(args[0]);
    const d = secsToDate(@divFloor(ms, 1000));

    const fields = [_]struct { name: []const u8, val: i64 }{
        .{ .name = "year", .val = d.year },
        .{ .name = "month", .val = d.month },
        .{ .name = "day", .val = d.day },
        .{ .name = "hour", .val = d.hour },
        .{ .name = "minute", .val = d.minute },
        .{ .name = "second", .val = d.second },
    };

    var alist: Value = value_mod.NIL;
    var i: usize = fields.len;
    while (i > 0) {
        i -= 1;
        const sym = vm.symbols.intern(fields[i].name) catch return error.OutOfMemory;
        const num = value_mod.fixnum(@intCast(fields[i].val));
        const pair = objects.makePair(vm.gc, sym, num) catch return error.OutOfMemory;
        alist = objects.makePair(vm.gc, pair, alist) catch return error.OutOfMemory;
    }
    return alist;
}

pub fn primDateToEpoch(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 6) return error.ArityMismatch;
    for (args) |a| if (!value_mod.isFixnum(a)) return error.ContractViolation;
    const year = value_mod.fixnumVal(args[0]);
    const month = value_mod.fixnumVal(args[1]);
    const day = value_mod.fixnumVal(args[2]);
    const hour = value_mod.fixnumVal(args[3]);
    const minute = value_mod.fixnumVal(args[4]);
    const second = value_mod.fixnumVal(args[5]);
    const secs = dateToSecs(year, month, day, hour, minute, second);
    return value_mod.fixnum(@intCast(secs * 1000));
}

pub fn primTimeFormat(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!value_mod.isFixnum(args[0])) return error.ContractViolation;
    if (!objects.isString(args[1])) return error.ContractViolation;
    const ms = value_mod.fixnumVal(args[0]);
    const fmt = objects.stringBytes(args[1]);
    const d = secsToDate(@divFloor(ms, 1000));

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(vm.allocator);

    var j: usize = 0;
    while (j < fmt.len) : (j += 1) {
        if (fmt[j] == '%' and j + 1 < fmt.len) {
            j += 1;
            var tmp: [20]u8 = undefined;
            switch (fmt[j]) {
                // zepo-wijk: year can be negative (large-negative epochs) — the
                // @intCast to u64 panicked. Handle the sign explicitly so the
                // positive case keeps its unsigned zero-padded form (no stray
                // '+'). month/day/etc. below are always in non-negative ranges.
                'Y' => if (d.year >= 0)
                    try buf.appendSlice(vm.allocator, std.fmt.bufPrint(&tmp, "{d:0>4}", .{@as(u64, @intCast(d.year))}) catch unreachable)
                else
                    try buf.appendSlice(vm.allocator, std.fmt.bufPrint(&tmp, "-{d:0>4}", .{@as(u64, @intCast(-d.year))}) catch unreachable),
                'm' => try buf.appendSlice(vm.allocator, std.fmt.bufPrint(&tmp, "{d:0>2}", .{@as(u64, @intCast(d.month))}) catch unreachable),
                'd' => try buf.appendSlice(vm.allocator, std.fmt.bufPrint(&tmp, "{d:0>2}", .{@as(u64, @intCast(d.day))}) catch unreachable),
                'H' => try buf.appendSlice(vm.allocator, std.fmt.bufPrint(&tmp, "{d:0>2}", .{@as(u64, @intCast(d.hour))}) catch unreachable),
                'M' => try buf.appendSlice(vm.allocator, std.fmt.bufPrint(&tmp, "{d:0>2}", .{@as(u64, @intCast(d.minute))}) catch unreachable),
                'S' => try buf.appendSlice(vm.allocator, std.fmt.bufPrint(&tmp, "{d:0>2}", .{@as(u64, @intCast(d.second))}) catch unreachable),
                '%' => try buf.append(vm.allocator, '%'),
                else => {
                    try buf.append(vm.allocator, '%');
                    try buf.append(vm.allocator, fmt[j]);
                },
            }
        } else {
            try buf.append(vm.allocator, fmt[j]);
        }
    }
    return objects.makeString(vm.gc, buf.items) catch return error.OutOfMemory;
}
