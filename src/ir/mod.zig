//! IR aggregate module.

pub const ops = @import("ops.zig");
pub const build = @import("build.zig");
pub const liveness = @import("liveness.zig");
pub const safepoints = @import("safepoints.zig");
pub const closure_conv = @import("closure_conv.zig");

pub const Op = ops.Op;
pub const Reg = ops.Reg;
pub const Label = ops.Label;
pub const Function = ops.Function;
pub const Program = ops.Program;
pub const Compiler = build.Compiler;

test {
    _ = ops;
    _ = build;
    _ = liveness;
    _ = safepoints;
    _ = closure_conv;
}
