//! Root set management.
//!
//! The runtime reports root locations to the GC through this structure. The
//! GC walks `visitAll`, passing each live Value slot pointer to the visitor,
//! which forwards the slot (copying/promoting) and rewrites it in place.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

pub const RootVisitor = *const fn (ctx: *anyopaque, slot: *Value) void;

// zepo-7fa
/// Panic in debug builds if `v` is a forwarding pointer (moved object not re-rooted).
/// No-op in release. Safe to call from any context — no GC reference needed.
pub fn assertLive(v: Value) void {
    if (builtin.mode != .Debug) return;
    if (!value_mod.isPtr(v)) return;
    const obj = value_mod.ptrVal(v);
    if (obj.isForward()) {
        std.debug.panic(
            "assertLive failed: Value 0x{x} points to a forwarded object " ++
                "(header=0x{x}). The Value was not rooted across a GC collection.",
            .{ @as(u64, @bitCast(v)), obj.word },
        );
    }
}

pub const HANDLE_SCOPE_CAPACITY: usize = 32;

pub const HandleScope = struct {
    prev: ?*HandleScope = null,
    handles: [HANDLE_SCOPE_CAPACITY]Value = @splat(abi.value.NIL),
    count: usize = 0,

    pub fn push(scope: *HandleScope, val: Value) *Value {
        std.debug.assert(scope.count < HANDLE_SCOPE_CAPACITY);
        assertLive(val); // zepo-7fa
        scope.handles[scope.count] = val;
        const slot = &scope.handles[scope.count];
        scope.count += 1;
        return slot;
    }
};

pub const RootSet = struct {
    globals: ?[*]Value = null,
    globals_count: usize = 0,
    intern_table_root: ?*Value = null,
    handle_stack: ?*HandleScope = null,
    /// Extra ad-hoc roots (used by tests and runtime bridges).
    extra: std.ArrayListUnmanaged(*Value) = .empty,
    /// Custom visitor callback (e.g. VM register stack). Invoked during
    /// visitAll with the visitor so the caller can walk arbitrary slot
    /// storage (like a dynamically-sized register array) without copying
    /// slot pointers into `extra`.
    visit_fn: ?*const fn (ctx: *anyopaque, visitor: RootVisitor, visitor_ctx: *anyopaque) void = null,
    visit_ctx: ?*anyopaque = null,
    /// Second custom visitor — used by EvalContext to keep compiled fn consts
    /// rooted even while the VM is torn down between eval steps.
    visit_fn2: ?*const fn (ctx: *anyopaque, visitor: RootVisitor, visitor_ctx: *anyopaque) void = null,
    visit_ctx2: ?*anyopaque = null,

    pub fn deinit(rs: *RootSet, alloc: std.mem.Allocator) void {
        rs.extra.deinit(alloc);
    }

    pub fn setGlobals(rs: *RootSet, ptr: [*]Value, n: usize) void {
        rs.globals = ptr;
        rs.globals_count = n;
    }

    pub fn pushHandleScope(rs: *RootSet, scope: *HandleScope) void {
        scope.prev = rs.handle_stack;
        rs.handle_stack = scope;
    }

    pub fn popHandleScope(rs: *RootSet) void {
        if (rs.handle_stack) |top| rs.handle_stack = top.prev;
    }

    pub fn addExtra(rs: *RootSet, alloc: std.mem.Allocator, slot: *Value) !void {
        try rs.extra.append(alloc, slot);
    }

    pub fn clearExtra(rs: *RootSet) void {
        rs.extra.clearRetainingCapacity();
    }

    pub fn visitAll(rs: *RootSet, ctx: *anyopaque, visitor: RootVisitor) void {
        if (rs.globals) |g| {
            var i: usize = 0;
            while (i < rs.globals_count) : (i += 1) {
                visitor(ctx, &g[i]);
            }
        }
        if (rs.intern_table_root) |r| visitor(ctx, r);

        var scope = rs.handle_stack;
        while (scope) |s| : (scope = s.prev) {
            var i: usize = 0;
            while (i < s.count) : (i += 1) {
                visitor(ctx, &s.handles[i]);
            }
        }

        for (rs.extra.items) |slot| visitor(ctx, slot);

        if (rs.visit_fn) |vfn| {
            if (rs.visit_ctx) |vctx| {
                vfn(vctx, visitor, ctx);
            }
        }
        if (rs.visit_fn2) |vfn| {
            if (rs.visit_ctx2) |vctx| {
                vfn(vctx, visitor, ctx);
            }
        }
    }
};

test "handle scope" {
    var rs = RootSet{};
    defer rs.deinit(std.testing.allocator);

    var scope = HandleScope{};
    rs.pushHandleScope(&scope);
    defer rs.popHandleScope();

    const slot = scope.push(abi.value.fixnum(42));
    try std.testing.expectEqual(abi.value.fixnum(42), slot.*);
    try std.testing.expectEqual(@as(usize, 1), scope.count);
}
