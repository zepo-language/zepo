//! Primitive procedures aggregate.

pub const pairs = @import("pairs.zig");
pub const predicates = @import("predicates.zig");
pub const equality = @import("equality.zig");
pub const arith = @import("arith.zig");
pub const apply = @import("apply.zig");
pub const io = @import("io.zig");
pub const register = @import("register.zig");

pub const registerAll = register.registerAll;

test {
    _ = pairs;
    _ = predicates;
    _ = equality;
    _ = arith;
    _ = apply;
    _ = io;
    _ = register;
}
