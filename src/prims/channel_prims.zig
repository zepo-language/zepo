// zepo-s64: channel primitives for fiber-to-fiber communication
//
// Channels are FIFO queues with optional buffer. Senders park when full;
// receivers re-execute (block_on_yield without park) when empty so they
// return the value directly without an extra indirection slot.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const LispError = runtime.LispError;
const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const sched_mod = @import("../vm/sched.zig");

pub const TAG_CHANNEL: u64 = 0xC4A8_0000_0001;

// Fiber index + value waiting to be delivered (sender blocked).
pub const SendWaiter = struct {
    fiber_idx: usize,
    val: Value,
};

pub const Channel = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    buf: std.ArrayListUnmanaged(Value),
    recv_waiters: std.ArrayListUnmanaged(usize),
    send_waiters: std.ArrayListUnmanaged(SendWaiter),

    pub fn init(alloc: std.mem.Allocator, capacity: usize) Channel {
        return .{
            .allocator = alloc,
            .capacity = capacity,
            .buf = .empty,
            .recv_waiters = .empty,
            .send_waiters = .empty,
        };
    }

    pub fn deinit(ch: *Channel) void {
        ch.buf.deinit(ch.allocator);
        ch.recv_waiters.deinit(ch.allocator);
        ch.send_waiters.deinit(ch.allocator);
    }
};

fn channelDeinit(ptr: ?*anyopaque) callconv(.c) void {
    const ch: *Channel = @ptrCast(@alignCast(ptr orelse return));
    ch.deinit();
    ch.allocator.destroy(ch);
}

fn getChannel(v: Value) LispError!*Channel {
    if (!objects.isForeign(v)) return error.TypeError;
    if (objects.foreignTypeTag(v) != TAG_CHANNEL) return error.TypeError;
    return @ptrCast(@alignCast(objects.foreignPayload(v) orelse return error.ContractViolation));
}

fn myFiberIdx(vm: *VM) usize {
    return if (vm.current_fiber_idx == 0) sched_mod.MAIN_FIBER else vm.current_fiber_idx - 1;
}

fn wakeFiber(vm: *VM, fiber_idx: usize) !void {
    const sched = vm.scheduler orelse return error.ContractViolation;
    try sched.enqueue(fiber_idx);
}

// ── (make-channel [capacity]) → channel ──────────────────────────────────────
pub fn primMakeChannel(vm: *VM, args: []const Value) LispError!Value {
    if (args.len > 1) return error.ArityMismatch;
    const capacity: usize = if (args.len == 1) blk: {
        if (!value_mod.isFixnum(args[0])) return error.TypeError;
        const n = value_mod.fixnumVal(args[0]);
        if (n < 0) return error.ContractViolation;
        break :blk @intCast(n);
    } else 0;

    const ch = try vm.allocator.create(Channel);
    ch.* = Channel.init(vm.allocator, capacity);
    errdefer { ch.deinit(); vm.allocator.destroy(ch); }

    const val = try objects.makeForeign(vm.gc, ch, channelDeinit, TAG_CHANNEL);
    // Register with VM so GC can trace Values inside the channel.
    try vm.channels.append(vm.allocator, ch);
    return val;
}

// ── (channel? v) → bool ───────────────────────────────────────────────────────
pub fn primChannelQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const is = objects.isForeign(args[0]) and objects.foreignTypeTag(args[0]) == TAG_CHANNEL;
    return if (is) value_mod.TRUE else value_mod.FALSE;
}

// ── (channel-send! ch val) → #void ───────────────────────────────────────────
// If a receiver is waiting: wake it (it will re-run channel-recv! and get val).
// Else if buffered and space: enqueue val.
// Else: park self in send_waiters until a receiver takes val.
pub fn primChannelSend(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const ch = try getChannel(args[0]);
    const val = args[1];

    // If receiver is waiting, wake it — it will re-execute channel-recv!
    // and pull from buf or send_waiters at that point.
    if (ch.recv_waiters.items.len > 0) {
        const waiter = ch.recv_waiters.orderedRemove(0);
        // Put val in buf so re-executing channel-recv! finds it.
        try ch.buf.append(ch.allocator, val);
        try wakeFiber(vm, waiter);
        return value_mod.NIL;
    }

    // Buffered and space available: enqueue.
    if (ch.buf.items.len < ch.capacity) {
        try ch.buf.append(ch.allocator, val);
        return value_mod.NIL;
    }

    // Must park: add to send_waiters, park yield (advance pc, no re-execute).
    try ch.send_waiters.append(ch.allocator, .{ .fiber_idx = myFiberIdx(vm), .val = val });
    vm.yield_requested = true;
    vm.block_on_yield = true;
    vm.park_on_yield = true;
    return value_mod.NIL;
}

// ── (channel-recv! ch) → value ────────────────────────────────────────────────
// If buf has items: pop front (and maybe wake a blocked sender to refill).
// Else if sender is waiting (unbuffered or buf full): take their val directly.
// Else: add self to recv_waiters and block (re-execute on resume).
pub fn primChannelRecv(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const ch = try getChannel(args[0]);

    // Value available in buffer?
    if (ch.buf.items.len > 0) {
        const v = ch.buf.orderedRemove(0);
        // If a sender was parked waiting for space, wake it and enqueue its val.
        if (ch.send_waiters.items.len > 0) {
            const sw = ch.send_waiters.orderedRemove(0);
            try ch.buf.append(ch.allocator, sw.val);
            try wakeFiber(vm, sw.fiber_idx);
        }
        return v;
    }

    // Sender is parked (unbuffered rendezvous or buf full but sender queued)?
    if (ch.send_waiters.items.len > 0) {
        const sw = ch.send_waiters.orderedRemove(0);
        try wakeFiber(vm, sw.fiber_idx);
        return sw.val;
    }

    // Nothing available: register as waiter, block yield (re-execute on wake).
    try ch.recv_waiters.append(ch.allocator, myFiberIdx(vm));
    vm.yield_requested = true;
    vm.block_on_yield = true;
    // park_on_yield stays false → CALL saves pc-1 → re-executes on resume.
    return value_mod.NIL;
}

// ── (channel-empty? ch) → bool ───────────────────────────────────────────────
pub fn primChannelEmptyQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const ch = try getChannel(args[0]);
    const empty = ch.buf.items.len == 0 and ch.send_waiters.items.len == 0;
    return if (empty) value_mod.TRUE else value_mod.FALSE;
}
