//! VM call-stack and frames.
//!
//! All Lisp-visible registers live in a single flat `regs` ArrayList so the
//! GC can walk them as a contiguous slice. Each `Frame` owns a window
//! [base, base+num_regs) inside that array. We also keep the active closure
//! Value on the frame so any in-flight closure captures remain rooted.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const bytecode = @import("../cg/bytecode.zig");
const CompiledFn = bytecode.CompiledFn;

pub const Frame = struct {
    func: *CompiledFn,
    pc: u32,
    base: u32,
    caller_base: u32,
    closure_val: Value,
};

pub const CallStack = struct {
    frames: std.ArrayList(Frame),
    regs: std.ArrayList(Value),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) CallStack {
        return .{
            .frames = std.ArrayList(Frame){},
            .regs = std.ArrayList(Value){},
            .allocator = allocator,
        };
    }

    pub fn deinit(cs: *CallStack) void {
        cs.frames.deinit(cs.allocator);
        cs.regs.deinit(cs.allocator);
    }

    pub fn push(cs: *CallStack, frame: Frame, num_regs: u16) !void {
        try cs.regs.ensureUnusedCapacity(cs.allocator, num_regs);
        var i: usize = 0;
        while (i < num_regs) : (i += 1) {
            cs.regs.appendAssumeCapacity(value_mod.NIL);
        }
        try cs.frames.append(cs.allocator, frame);
    }

    pub fn pop(cs: *CallStack) Frame {
        const f = cs.frames.pop().?;
        // Shrink regs back to the frame's base.
        cs.regs.shrinkRetainingCapacity(f.base);
        return f;
    }

    pub fn currentFrame(cs: *CallStack) *Frame {
        return &cs.frames.items[cs.frames.items.len - 1];
    }

    pub fn reg(cs: *CallStack, idx: u16) *Value {
        const f = cs.currentFrame();
        return &cs.regs.items[f.base + idx];
    }

    pub fn depth(cs: *const CallStack) usize {
        return cs.frames.items.len;
    }
};

test "push/pop" {
    const alloc = std.testing.allocator;
    var cs = CallStack.init(alloc);
    defer cs.deinit();

    // Fake CompiledFn (not executed, just for pointer).
    var fake_code = [_]bytecode.Instr{};
    var fake_consts = [_]Value{};
    var fake_names = [_][]const u8{};
    var fake_sps = [_]bytecode.SafepointMap{};
    var cf = CompiledFn{
        .id = 0,
        .arity = 0,
        .has_rest = false,
        .num_regs = 4,
        .code = &fake_code,
        .consts = &fake_consts,
        .names = &fake_names,
        .safepoint_maps = &fake_sps,
        .allocator = alloc,
    };

    try cs.push(.{
        .func = &cf,
        .pc = 0,
        .base = 0,
        .caller_base = 0,
        .closure_val = value_mod.NIL,
    }, 4);
    try std.testing.expectEqual(@as(usize, 1), cs.depth());
    try std.testing.expectEqual(@as(usize, 4), cs.regs.items.len);

    cs.reg(2).* = value_mod.fixnum(42);
    try std.testing.expectEqual(value_mod.fixnum(42), cs.reg(2).*);
    _ = cs.pop();
    try std.testing.expectEqual(@as(usize, 0), cs.depth());
}
