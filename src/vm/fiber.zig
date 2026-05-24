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
const bytecode = @import("../cg/bytecode.zig");
const CompiledFn = bytecode.CompiledFn;

/// zepo-9bi: an installed exception handler. Lives on the fiber so yields
/// preserve it across context switches.
/// - `handler_val` is the closure to invoke with the raised value.
/// - `frame_depth` is `call_stack.frames.items.len` at PUSH_HANDLER time;
///   on raise we pop frames down to this depth before invoking the handler.
/// - `dst_reg` is the register in the resumed frame that should receive
///   either the body's normal result or the handler's return value.
/// - `resume_pc` / `resume_func` is where the frame at `frame_depth - 1`
///   continues after the handler returns.
pub const HandlerFrame = struct {
    handler_val: Value,
    frame_depth: u32,
    dst_reg: u16,
    resume_pc: u32,
    resume_func: *CompiledFn,
};

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
    /// zepo-9bi: per-fiber exception-handler stack. Top = most recent.
    handler_stack: std.ArrayListUnmanaged(HandlerFrame) = .empty,
    status: FiberStatus,
    /// Final value when status == .done.
    result: Value,
    /// Raised value when status == .errored.
    error_val: Value,
    allocator: std.mem.Allocator,
    // zepo-i19: fibers blocked in (fiber-join) waiting for this fiber to finish.
    // Indices are into vm.fibers (or MAIN_FIBER sentinel from sched.zig).
    waiters: std.ArrayListUnmanaged(usize) = .empty,

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
            .waiters = .empty,
        };
        return fs;
    }

    pub fn deinit(fs: *FiberState) void {
        const alloc = fs.allocator;
        fs.call_stack.deinit();
        fs.handler_stack.deinit(alloc);
        fs.waiters.deinit(alloc);
        alloc.destroy(fs);
    }
};
