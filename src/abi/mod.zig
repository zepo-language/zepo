//! ABI aggregate module.

pub const header = @import("header.zig");
pub const value = @import("value.zig");
pub const layout = @import("layout.zig");
pub const safepoint = @import("safepoint.zig");

pub const Value = value.Value;
pub const ObjHeader = header.ObjHeader;
pub const Kind = header.Kind;
pub const Space = header.Space;

test {
    _ = header;
    _ = value;
    _ = layout;
    _ = safepoint;
}
