//! VM aggregate module.

pub const frame = @import("frame.zig");
pub const dispatch = @import("dispatch.zig");

pub const Frame = frame.Frame;
pub const CallStack = frame.CallStack;
pub const VM = dispatch.VM;
pub const PrimFn = dispatch.PrimFn;

test {
    _ = frame;
    _ = dispatch;
}
