// zepo-s64: channel primitives for fiber-to-fiber communication
// zepo-oju: thread-safe cross-worker channels with ChannelValue staging
//
// Channels are FIFO queues with optional buffer. Values in transit are
// serialized to ChannelValue (GC-free staging) so they can cross VM
// heap boundaries safely. Senders park when full; receivers park when
// empty and re-execute on wake (finding the value in buf).

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const portable = runtime.portable_value;
const ChannelValue = portable.ChannelValue;
const LispError = runtime.LispError;
const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const sched_mod = @import("../vm/sched.zig");
const Scheduler = sched_mod.Scheduler;

pub const TAG_CHANNEL: u64 = 0xC4A8_0000_0001;

// Fiber waiting to receive: identified by its scheduler + fiber index.
pub const RecvWaiter = struct {
    sched: *Scheduler,
    fiber_idx: usize,
};

// Fiber waiting to send: its serialized value + location.
pub const SendWaiter = struct {
    sched: *Scheduler,
    fiber_idx: usize,
    cv: *ChannelValue, // caller-allocated; freed when delivered or on channel deinit
};

pub const Channel = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    mu: std.c.pthread_mutex_t,
    buf: std.ArrayListUnmanaged(*ChannelValue),
    recv_waiters: std.ArrayListUnmanaged(RecvWaiter),
    send_waiters: std.ArrayListUnmanaged(SendWaiter),
    closed: bool,

    pub fn init(alloc: std.mem.Allocator, capacity: usize) Channel {
        return .{
            .allocator = alloc,
            .capacity = capacity,
            .mu = std.c.PTHREAD_MUTEX_INITIALIZER,
            .buf = .empty,
            .recv_waiters = .empty,
            .send_waiters = .empty,
            .closed = false,
        };
    }

    pub fn deinit(ch: *Channel) void {
        for (ch.buf.items) |cv| portable.freeChannelValue(cv, ch.allocator);
        ch.buf.deinit(ch.allocator);
        for (ch.send_waiters.items) |sw| portable.freeChannelValue(sw.cv, ch.allocator);
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

fn mySched(vm: *VM) LispError!*Scheduler {
    return vm.scheduler orelse error.ContractViolation;
}

// Wake a fiber: use enqueueFromThread if cross-scheduler, enqueue if same.
fn wakeFiber(my_sched: *Scheduler, target_sched: *Scheduler, fiber_idx: usize) !void {
    if (target_sched == my_sched) {
        try my_sched.enqueue(fiber_idx);
    } else {
        try target_sched.enqueueFromThread(fiber_idx);
    }
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

    // zepo-b5h: channels may be shared with worker OS threads; use c_allocator
    // so cross-thread serialization/deserialization is safe (vm.allocator is
    // a single-threaded DebugAllocator that must not be used from other threads).
    const ch_alloc = std.heap.c_allocator;
    const ch = try ch_alloc.create(Channel);
    ch.* = Channel.init(ch_alloc, capacity);
    errdefer { ch.deinit(); ch_alloc.destroy(ch); }

    return objects.makeForeign(vm.gc, ch, channelDeinit, TAG_CHANNEL);
}

// ── (channel? v) → bool ──────────────────────────────────────────────────────
pub fn primChannelQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const is = objects.isForeign(args[0]) and objects.foreignTypeTag(args[0]) == TAG_CHANNEL;
    return if (is) value_mod.TRUE else value_mod.FALSE;
}

// ── (channel-send! ch val) → #void ───────────────────────────────────────────
pub fn primChannelSend(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const ch = try getChannel(args[0]);
    const sched = try mySched(vm);

    // Serialize before acquiring the lock (avoids holding lock during alloc).
    const cv = portable.serializeToChannel(args[1], ch.allocator) catch |e| switch (e) {
        error.NonPortableValue => return error.NonPortableValue,
        else => return error.OutOfMemory,
    };

    _ = std.c.pthread_mutex_lock(&ch.mu);

    if (ch.closed) {
        _ = std.c.pthread_mutex_unlock(&ch.mu);
        portable.freeChannelValue(cv, ch.allocator);
        return error.ContractViolation;
    }

    // Wake a waiting receiver.
    if (ch.recv_waiters.items.len > 0) {
        const waiter = ch.recv_waiters.orderedRemove(0);
        ch.buf.append(ch.allocator, cv) catch {
            _ = std.c.pthread_mutex_unlock(&ch.mu);
            portable.freeChannelValue(cv, ch.allocator);
            return error.OutOfMemory;
        };
        _ = std.c.pthread_mutex_unlock(&ch.mu);
        try wakeFiber(sched, waiter.sched, waiter.fiber_idx);
        return value_mod.NIL;
    }

    // Buffer has space.
    if (ch.capacity == 0 or ch.buf.items.len < ch.capacity) {
        ch.buf.append(ch.allocator, cv) catch {
            _ = std.c.pthread_mutex_unlock(&ch.mu);
            portable.freeChannelValue(cv, ch.allocator);
            return error.OutOfMemory;
        };
        _ = std.c.pthread_mutex_unlock(&ch.mu);
        return value_mod.NIL;
    }

    // Buffer full: park sender.
    ch.send_waiters.append(ch.allocator, .{
        .sched = sched,
        .fiber_idx = myFiberIdx(vm),
        .cv = cv,
    }) catch {
        _ = std.c.pthread_mutex_unlock(&ch.mu);
        portable.freeChannelValue(cv, ch.allocator);
        return error.OutOfMemory;
    };
    _ = std.c.pthread_mutex_unlock(&ch.mu);
    vm.yield_requested = true;
    vm.block_on_yield = true;
    vm.park_on_yield = true;
    return value_mod.NIL;
}

// ── (channel-try-send! ch val) → #t | #f ─────────────────────────────────────
pub fn primChannelTrySend(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    const ch = try getChannel(args[0]);
    const sched = try mySched(vm);

    const cv = portable.serializeToChannel(args[1], ch.allocator) catch |e| switch (e) {
        error.NonPortableValue => return error.NonPortableValue,
        else => return error.OutOfMemory,
    };

    _ = std.c.pthread_mutex_lock(&ch.mu);

    if (ch.closed) {
        _ = std.c.pthread_mutex_unlock(&ch.mu);
        portable.freeChannelValue(cv, ch.allocator);
        return error.ContractViolation;
    }

    if (ch.recv_waiters.items.len > 0) {
        const waiter = ch.recv_waiters.orderedRemove(0);
        ch.buf.append(ch.allocator, cv) catch {
            _ = std.c.pthread_mutex_unlock(&ch.mu);
            portable.freeChannelValue(cv, ch.allocator);
            return error.OutOfMemory;
        };
        _ = std.c.pthread_mutex_unlock(&ch.mu);
        try wakeFiber(sched, waiter.sched, waiter.fiber_idx);
        return value_mod.TRUE;
    }

    if (ch.capacity == 0 or ch.buf.items.len < ch.capacity) {
        ch.buf.append(ch.allocator, cv) catch {
            _ = std.c.pthread_mutex_unlock(&ch.mu);
            portable.freeChannelValue(cv, ch.allocator);
            return error.OutOfMemory;
        };
        _ = std.c.pthread_mutex_unlock(&ch.mu);
        return value_mod.TRUE;
    }

    _ = std.c.pthread_mutex_unlock(&ch.mu);
    portable.freeChannelValue(cv, ch.allocator);
    return value_mod.FALSE;
}

// ── (channel-recv! ch) → value ───────────────────────────────────────────────
pub fn primChannelRecv(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const ch = try getChannel(args[0]);
    const sched = try mySched(vm);

    _ = std.c.pthread_mutex_lock(&ch.mu);

    if (ch.buf.items.len > 0) {
        const cv = ch.buf.orderedRemove(0);
        // Wake a parked sender to refill the buffer.
        if (ch.send_waiters.items.len > 0) {
            const sw = ch.send_waiters.orderedRemove(0);
            ch.buf.append(ch.allocator, sw.cv) catch {};
            _ = std.c.pthread_mutex_unlock(&ch.mu);
            try wakeFiber(sched, sw.sched, sw.fiber_idx);
        } else {
            _ = std.c.pthread_mutex_unlock(&ch.mu);
        }
        // Deserialize into this VM's heap.
        const val = portable.deserializeFromChannel(cv, vm.gc, vm.symbols) catch return error.OutOfMemory;
        portable.freeChannelValue(cv, ch.allocator);
        return val;
    }

    if (ch.closed) {
        _ = std.c.pthread_mutex_unlock(&ch.mu);
        return error.ContractViolation;
    }

    // Park: re-execute on wake (pc not advanced).
    ch.recv_waiters.append(ch.allocator, .{
        .sched = sched,
        .fiber_idx = myFiberIdx(vm),
    }) catch {
        _ = std.c.pthread_mutex_unlock(&ch.mu);
        return error.OutOfMemory;
    };
    _ = std.c.pthread_mutex_unlock(&ch.mu);
    vm.yield_requested = true;
    vm.block_on_yield = true;
    // park_on_yield stays false → re-executes channel-recv! on wake.
    return value_mod.NIL;
}

// ── (channel-try-recv! ch) → value | #f ──────────────────────────────────────
pub fn primChannelTryRecv(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const ch = try getChannel(args[0]);
    const sched = try mySched(vm);

    _ = std.c.pthread_mutex_lock(&ch.mu);

    if (ch.buf.items.len > 0) {
        const cv = ch.buf.orderedRemove(0);
        if (ch.send_waiters.items.len > 0) {
            const sw = ch.send_waiters.orderedRemove(0);
            ch.buf.append(ch.allocator, sw.cv) catch {};
            _ = std.c.pthread_mutex_unlock(&ch.mu);
            try wakeFiber(sched, sw.sched, sw.fiber_idx);
        } else {
            _ = std.c.pthread_mutex_unlock(&ch.mu);
        }
        const val = portable.deserializeFromChannel(cv, vm.gc, vm.symbols) catch return error.OutOfMemory;
        portable.freeChannelValue(cv, ch.allocator);
        return val;
    }

    _ = std.c.pthread_mutex_unlock(&ch.mu);
    return value_mod.FALSE;
}

// ── (channel-close ch) → unspecified ─────────────────────────────────────────
pub fn primChannelClose(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const ch = try getChannel(args[0]);
    const sched = try mySched(vm);

    _ = std.c.pthread_mutex_lock(&ch.mu);
    ch.closed = true;
    // Wake all waiting receivers (they will see closed + empty and error).
    var waiters = ch.recv_waiters;
    ch.recv_waiters = .empty;
    _ = std.c.pthread_mutex_unlock(&ch.mu);

    for (waiters.items) |w| try wakeFiber(sched, w.sched, w.fiber_idx);
    waiters.deinit(ch.allocator);
    return value_mod.NIL;
}

// ── (channel-empty? ch) → bool ───────────────────────────────────────────────
pub fn primChannelEmptyQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const ch = try getChannel(args[0]);
    _ = std.c.pthread_mutex_lock(&ch.mu);
    const empty = ch.buf.items.len == 0 and ch.send_waiters.items.len == 0;
    _ = std.c.pthread_mutex_unlock(&ch.mu);
    return if (empty) value_mod.TRUE else value_mod.FALSE;
}
