//! HTTP client primitive wrapping std.http.Client.

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

/// (http-request method url headers body) → (:status N :body "...")
/// method  — string: "GET" "POST" "PUT" "DELETE" "HEAD" "PATCH" "OPTIONS"
/// url     — string: "https://..." or "http://..."
/// headers — alist ((name . value) ...) or nil
/// body    — string or nil
pub fn primHttpRequest(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 4) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.ContractViolation;
    if (!objects.isString(args[1])) return error.ContractViolation;

    const method_str = objects.stringBytes(args[0]);
    const url = objects.stringBytes(args[1]);

    const method = std.meta.stringToEnum(std.http.Method, method_str) orelse {
        const msg = std.fmt.allocPrint(vm.allocator, "http-request: unknown method: {s}", .{method_str}) catch
            return error.OutOfMemory;
        if (vm.error_msg) |old| vm.allocator.free(old);
        vm.error_msg = msg;
        return error.UserError;
    };

    const payload: ?[]const u8 = blk: {
        if (value_mod.isNil(args[3])) break :blk null;
        if (objects.isString(args[3])) break :blk objects.stringBytes(args[3]);
        return error.ContractViolation;
    };

    // Build extra_headers from alist — strings must outlive the fetch call.
    var header_buf = std.ArrayListUnmanaged([]u8){};
    defer {
        for (header_buf.items) |s| vm.allocator.free(s);
        header_buf.deinit(vm.allocator);
    }
    var extra_headers = std.ArrayListUnmanaged(std.http.Header){};
    defer extra_headers.deinit(vm.allocator);

    var cur = args[2];
    while (!value_mod.isNil(cur)) {
        if (!objects.isPair(cur)) break;
        const entry = objects.pairCar(cur).*;
        if (objects.isPair(entry)) {
            const k = objects.pairCar(entry).*;
            const v = objects.pairCdr(entry).*;
            if (objects.isString(k) and objects.isString(v)) {
                const name = vm.allocator.dupe(u8, objects.stringBytes(k)) catch return error.OutOfMemory;
                header_buf.append(vm.allocator, name) catch return error.OutOfMemory;
                const val = vm.allocator.dupe(u8, objects.stringBytes(v)) catch return error.OutOfMemory;
                header_buf.append(vm.allocator, val) catch return error.OutOfMemory;
                extra_headers.append(vm.allocator, .{ .name = name, .value = val }) catch return error.OutOfMemory;
            }
        }
        cur = objects.pairCdr(cur).*;
    }

    // Capture response body via Allocating writer.
    var aw = std.Io.Writer.Allocating.init(vm.allocator);
    defer aw.deinit();

    var client = std.http.Client{ .allocator = vm.allocator };
    defer client.deinit();

    const result = client.fetch(.{
        .method = method,
        .location = .{ .url = url },
        .extra_headers = extra_headers.items,
        .payload = payload,
        .response_writer = &aw.writer,
    }) catch |e| {
        const msg = std.fmt.allocPrint(vm.allocator, "http-request: {s}", .{@errorName(e)}) catch
            return error.OutOfMemory;
        if (vm.error_msg) |old| vm.allocator.free(old);
        vm.error_msg = msg;
        return error.UserError;
    };

    const body_bytes = aw.writer.buffered();
    const body_val = objects.makeString(vm.gc, body_bytes) catch return error.OutOfMemory;
    const status_val = value_mod.fixnum(@intCast(@intFromEnum(result.status)));

    const sym_status = vm.symbols.intern(":status") catch return error.OutOfMemory;
    const sym_body = vm.symbols.intern(":body") catch return error.OutOfMemory;

    var plist = value_mod.NIL;
    plist = objects.makePair(vm.gc, body_val, plist) catch return error.OutOfMemory;
    plist = objects.makePair(vm.gc, sym_body, plist) catch return error.OutOfMemory;
    plist = objects.makePair(vm.gc, status_val, plist) catch return error.OutOfMemory;
    plist = objects.makePair(vm.gc, sym_status, plist) catch return error.OutOfMemory;

    return plist;
}
