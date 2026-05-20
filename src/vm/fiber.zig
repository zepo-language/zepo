// zepo-4yr: fiber stack infrastructure
//! Per-fiber execution state. Each fiber owns a CallStack (frames + regs).
//! The VM keeps one FiberState per spawned fiber; the currently-running fiber's
//! call stack is mirrored into vm.call_stack for zero-overhead dispatch.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const frame_mod = @import("frame.zig");
const CallStack = frame_mod.CallStack;

pub const FiberStatus = enum {
    /// In the run queue, will be dispatched next round-robin turn.
    runnable,
    /// Waiting on an fd or timer; registered with poll(2) by the scheduler.
    blocked,
    /// Completed normally; result holds the return value.
    done,
    /// Completed with an error; error_val holds the raised value.
    errored,
};

pub const FiberState = struct {
    call_stack: CallStack,
    status: FiberStatus,
    /// Final value when status == .done.
    result: Value,
    /// Raised value when status == .errored.
    error_val: Value,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, max_regs: usize) !*FiberState {
        const fs = try allocator.create(FiberState);
        var cs = CallStack.init(allocator);
        try cs.regs.ensureTotalCapacity(allocator, max_regs);
        try cs.frames.ensureTotalCapacity(allocator, 4096);
        fs.* = .{
            .call_stack = cs,
            .status = .runnable,
            .result = value_mod.NIL,
            .error_val = value_mod.NIL,
            .allocator = allocator,
        };
        return fs;
    }

    pub fn deinit(fs: *FiberState) void {
        const alloc = fs.allocator;
        fs.call_stack.deinit();
        alloc.destroy(fs);
    }
};
