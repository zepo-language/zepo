//! VM aggregate module.

pub const frame = @import("frame.zig");
pub const dispatch = @import("dispatch.zig");
pub const fiber = @import("fiber.zig");

pub const Frame = frame.Frame;
pub const CallStack = frame.CallStack;
pub const VM = dispatch.VM;
pub const PrimFn = dispatch.PrimFn;
pub const FiberState = fiber.FiberState;
pub const FiberStatus = fiber.FiberStatus;

test {
    _ = frame;
    _ = dispatch;
    _ = fiber;
}
