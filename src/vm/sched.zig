// zepo-0bo: cooperative fiber scheduler with poll(2) backing
// zepo-8ou: incremental major GC steps run between fiber switches
//! Drives round-robin execution of fibers. When all fibers are blocked on I/O,
//! calls poll(2) to sleep until an fd is ready. Context-switches are O(1)
//! struct swaps — no heap copies of call stacks.
//!
//! Invariant: vm.call_stack is EMPTY (zero items, valid allocator) between
//! scheduler steps. loadFiber restores a saved call stack; saveCurrent saves
//! the active one and replaces vm.call_stack with an empty placeholder.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const frame_mod = @import("frame.zig");
const CallStack = frame_mod.CallStack;
const dispatch_mod = @import("dispatch.zig");
const VM = dispatch_mod.VM;
const FiberStatus = dispatch_mod.FiberStatus;
const runtime = @import("../runtime/mod.zig");
const LispError = runtime.LispError;

// ── POSIX poll(2) ─────────────────────────────────────────────────────────────

const PollFd = extern struct {
    fd: c_int,
    events: c_short,
    revents: c_short,
};

extern "c" fn poll(fds: [*]PollFd, nfds: c_uint, timeout: c_int) c_int;
extern "c" fn pipe(fds: *[2]c_int) c_int;
extern "c" fn fcntl(fd: c_int, cmd: c_int, arg: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

pub const POLLIN: c_short = 0x0001;
pub const POLLOUT: c_short = 0x0004;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = 0x0004;

// zepo-8pc: monotonic millisecond timestamp
pub fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

// ── Scheduler ─────────────────────────────────────────────────────────────────

pub const MAIN_FIBER: usize = std.math.maxInt(usize);

pub const BlockedFiber = struct {
    fiber_idx: usize, // MAIN_FIBER or index into vm.fibers
    fd: c_int,
    events: c_short,
};

// zepo-8pc: fiber parked until an absolute monotonic deadline (ms)
pub const SleepingFiber = struct {
    fiber_idx: usize,
    wake_ms: i64,
};

pub const Scheduler = struct {
    vm: *VM,
    allocator: std.mem.Allocator,
    run_queue: std.ArrayListUnmanaged(usize),
    blocked: std.ArrayListUnmanaged(BlockedFiber),
    sleeping: std.ArrayListUnmanaged(SleepingFiber), // zepo-8pc
    // zepo-1aw: inter-thread wakeup pipe. wakeup_read_fd is in every poll call.
    // Another thread writes one byte to wakeup_write_fd to interrupt poll.
    wakeup_read_fd: c_int = -1,
    wakeup_write_fd: c_int = -1,
    // zepo-1aw: fibers to re-enqueue on next scheduler tick; written by other
    // threads via enqueueFromThread, protected by pending_mu.
    pending_mu: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    pending_wakeups: std.ArrayListUnmanaged(usize) = .empty,

    pub fn init(vm: *VM) Scheduler {
        return .{
            .vm = vm,
            .allocator = vm.allocator,
            .run_queue = .empty,
            .blocked = .empty,
            .sleeping = .empty,
        };
    }

    pub fn deinit(sched: *Scheduler) void {
        sched.run_queue.deinit(sched.allocator);
        sched.blocked.deinit(sched.allocator);
        sched.sleeping.deinit(sched.allocator);
        sched.pending_wakeups.deinit(sched.allocator);
        if (sched.wakeup_read_fd >= 0) {
            _ = std.c.close(sched.wakeup_read_fd);
            _ = std.c.close(sched.wakeup_write_fd);
        }
    }

    // zepo-1aw: create the wakeup pipe and set both ends non-blocking.
    // Called once before runMain; idempotent (safe to call multiple times).
    pub fn initWakeupFd(sched: *Scheduler) !void {
        if (sched.wakeup_read_fd >= 0) return;
        var fds: [2]c_int = undefined;
        if (pipe(&fds) != 0) return error.SystemResources;
        _ = fcntl(fds[0], F_SETFL, O_NONBLOCK);
        _ = fcntl(fds[1], F_SETFL, O_NONBLOCK);
        sched.wakeup_read_fd = fds[0];
        sched.wakeup_write_fd = fds[1];
    }

    // zepo-1aw: write one byte to the wakeup pipe, interrupting poll.
    // Safe to call from any thread. No-op if the pipe is not initialized.
    pub fn wake(sched: *Scheduler) void {
        if (sched.wakeup_write_fd < 0) return;
        const one: [1]u8 = .{1};
        _ = write(sched.wakeup_write_fd, &one, 1);
    }

    // zepo-1aw: thread-safe enqueue for cross-worker channel wakeups.
    // Appends fiber_idx to pending_wakeups and writes to the wakeup pipe.
    pub fn enqueueFromThread(sched: *Scheduler, fiber_idx: usize) !void {
        _ = std.c.pthread_mutex_lock(&sched.pending_mu);
        defer _ = std.c.pthread_mutex_unlock(&sched.pending_mu);
        try sched.pending_wakeups.append(sched.allocator, fiber_idx);
        sched.wake();
    }

    // ── Context switching ────────────────────────────────────────────────────
    // After saveCurrent: vm.call_stack is empty (valid allocator, zero items).
    // After loadFiber:   vm.call_stack holds the target fiber's live call stack.

    fn saveCurrent(sched: *Scheduler, active_idx: usize) void {
        const vm = sched.vm;
        if (active_idx == MAIN_FIBER) {
            vm.main_cs_snapshot = vm.call_stack;
        } else {
            vm.fibers.items[active_idx].call_stack = vm.call_stack;
        }
        vm.call_stack = CallStack.init(vm.allocator);
    }

    fn loadFiber(sched: *Scheduler, target_idx: usize) void {
        const vm = sched.vm;
        // Free the empty placeholder sitting in vm.call_stack.
        vm.call_stack.deinit();
        if (target_idx == MAIN_FIBER) {
            vm.call_stack = vm.main_cs_snapshot;
            vm.main_cs_snapshot = CallStack.init(vm.allocator);
        } else {
            vm.call_stack = vm.fibers.items[target_idx].call_stack;
            vm.fibers.items[target_idx].call_stack = CallStack.init(vm.allocator);
        }
        vm.current_fiber_idx = if (target_idx == MAIN_FIBER) 0 else target_idx + 1;
    }

    // ── Public helpers for spawn/block primitives ────────────────────────────

    pub fn enqueue(sched: *Scheduler, fiber_idx: usize) !void {
        try sched.run_queue.append(sched.allocator, fiber_idx);
    }

    /// Register a fiber as blocked on fd; the fiber should (yield) immediately
    /// after calling this so the scheduler can poll.
    pub fn blockFiberOnFd(sched: *Scheduler, fiber_idx: usize, fd: c_int, events: c_short) !void {
        try sched.blocked.append(sched.allocator, .{
            .fiber_idx = fiber_idx,
            .fd = fd,
            .events = events,
        });
    }

    // zepo-8pc: park a fiber until wake_ms (absolute nowMs()).
    pub fn sleepFiber(sched: *Scheduler, fiber_idx: usize, wake_ms: i64) !void {
        try sched.sleeping.append(sched.allocator, .{
            .fiber_idx = fiber_idx,
            .wake_ms = wake_ms,
        });
    }

    // ── poll(2) + sleep timer ─────────────────────────────────────────────────

    fn pollAndWake(sched: *Scheduler) !void {
        const now = nowMs();

        // Compute poll timeout from the earliest sleeping fiber.
        var timeout: c_int = -1; // infinite (no sleepers)
        for (sched.sleeping.items) |s| {
            const rem = s.wake_ms - now;
            const t: c_int = if (rem <= 0) 0 else @intCast(@min(rem, std.math.maxInt(c_int)));
            if (timeout == -1 or t < timeout) timeout = t;
        }

        // zepo-1aw: include the wakeup fd as an extra slot at the front.
        const has_wakeup = sched.wakeup_read_fd >= 0;
        const n = sched.blocked.items.len;
        const total = n + @intFromBool(has_wakeup);
        const pfds = try sched.allocator.alloc(PollFd, total);
        defer sched.allocator.free(pfds);

        // Wakeup fd occupies pfds[0] when present; blocked fds follow.
        const base: usize = @intFromBool(has_wakeup);
        if (has_wakeup)
            pfds[0] = .{ .fd = sched.wakeup_read_fd, .events = POLLIN, .revents = 0 };
        for (sched.blocked.items, 0..) |b, i|
            pfds[base + i] = .{ .fd = b.fd, .events = b.events, .revents = 0 };

        if (total > 0) {
            _ = poll(pfds.ptr, @intCast(total), timeout);
        } else {
            // Sleep-only: poll with no fds just for the timer.
            var dummy: [0]PollFd = .{};
            _ = poll(&dummy, 0, timeout);
        }

        // zepo-1aw: drain wakeup pipe and flush pending_wakeups into run_queue.
        if (has_wakeup and pfds[0].revents != 0) {
            var buf: [64]u8 = undefined;
            while (read(sched.wakeup_read_fd, &buf, buf.len) > 0) {}
            _ = std.c.pthread_mutex_lock(&sched.pending_mu);
            for (sched.pending_wakeups.items) |idx| try sched.run_queue.append(sched.allocator, idx);
            sched.pending_wakeups.clearRetainingCapacity();
            _ = std.c.pthread_mutex_unlock(&sched.pending_mu);
        }

        // Wake fd-ready fibers.
        var i: usize = 0;
        while (i < sched.blocked.items.len) {
            if (pfds[base + i].revents != 0) {
                const b = sched.blocked.swapRemove(i);
                try sched.run_queue.append(sched.allocator, b.fiber_idx);
            } else {
                i += 1;
            }
        }

        // Wake sleeping fibers whose deadline has passed.
        const now2 = nowMs();
        var j: usize = 0;
        while (j < sched.sleeping.items.len) {
            if (sched.sleeping.items[j].wake_ms <= now2) {
                const s = sched.sleeping.swapRemove(j);
                try sched.run_queue.append(sched.allocator, s.fiber_idx);
            } else {
                j += 1;
            }
        }
    }

    // ── Main entry ───────────────────────────────────────────────────────────

    pub fn runMain(sched: *Scheduler, fn_id: u32, initial_args: []const Value) LispError!Value {
        const vm = sched.vm;
        if (fn_id >= vm.compiled_fns.len) return error.ContractViolation;
        const func = &vm.compiled_fns[fn_id];
        vm.current_fiber_idx = 0;
        vm.scheduler = sched;
        defer vm.scheduler = null;
        // zepo-1aw: ensure wakeup pipe is ready before entering the event loop.
        sched.initWakeupFd() catch {};
        // zepo-oav: re-enqueue runnable fibers from prior run() calls so fibers
        // spawned in a previous top-level form get dispatched this run.
        for (vm.fibers.items, 0..) |fs, i| {
            if (fs.status == .runnable) try sched.run_queue.append(sched.allocator, i);
        }

        // Run main fiber. If it never yields, we're done immediately.
        const first: ?Value = vm.execFn(func, value_mod.NIL, initial_args) catch |e| blk: {
            if (e != error.FiberYielded) return e;
            sched.saveCurrent(MAIN_FIBER);
            if (!vm.block_on_yield) try sched.run_queue.append(sched.allocator, MAIN_FIBER);
            vm.block_on_yield = false;
            vm.park_on_yield = false; // zepo-8pc
            break :blk null;
        };
        if (first) |v| return v;

        var main_result: Value = value_mod.NIL;
        var main_done = false;

        // Invariant at loop top: vm.call_stack is empty (saved by saveCurrent).
        while (!main_done or sched.run_queue.items.len > 0 or sched.blocked.items.len > 0 or sched.sleeping.items.len > 0) {
            if (sched.run_queue.items.len == 0) {
                if (sched.blocked.items.len == 0 and sched.sleeping.items.len == 0) break;
                try sched.pollAndWake();
                continue;
            }

            const next = sched.run_queue.orderedRemove(0);
            sched.loadFiber(next); // vm.call_stack ← fiber's saved call stack

            const step: ?Value = vm.resumeExecFn() catch |e| blk: {
                if (e == error.FiberYielded) {
                    sched.saveCurrent(next);
                    if (!vm.block_on_yield) try sched.run_queue.append(sched.allocator, next);
                    vm.block_on_yield = false;
                    vm.park_on_yield = false; // zepo-8pc
                    break :blk null;
                }
                // Real error.
                std.debug.print("[sched] fiber {} error: {}\n", .{ next, e });
                if (next == MAIN_FIBER) return e;
                const fs_err = vm.fibers.items[next];
                fs_err.status = .errored;
                fs_err.error_val = vm.raised_val;
                // zepo-i19: wake fibers blocked in (fiber-join) on this one
                for (fs_err.waiters.items) |w| try sched.run_queue.append(sched.allocator, w);
                fs_err.waiters.clearRetainingCapacity();
                vm.call_stack.frames.clearRetainingCapacity();
                vm.call_stack.regs.shrinkRetainingCapacity(0);
                break :blk null;
            };

            if (step) |v| {
                if (next == MAIN_FIBER) {
                    main_result = v;
                    main_done = true;
                } else {
                    const fs = vm.fibers.items[next];
                    fs.status = .done;
                    fs.result = v;
                    // zepo-i19: wake fibers blocked in (fiber-join) on this one
                    for (fs.waiters.items) |w| try sched.run_queue.append(sched.allocator, w);
                    fs.waiters.clearRetainingCapacity();
                }
            }

            // zepo-8ou: incremental major GC step between fiber switches.
            // vm.call_stack is empty here (scheduler invariant), so no
            // live Values are on the call stack — a safe point for marking.
            if (vm.gc.needsMajor()) {
                vm.gc.markBegin() catch {};
            } else if (vm.gc.mark_phase == .marking) {
                if (vm.gc.markStep(256)) {
                    vm.gc.sweepAndFinish();
                }
            }
        }

        return main_result;
    }
};
