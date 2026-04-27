//! Semantic analysis aggregate.

pub const resolve = @import("resolve.zig");
pub const captures = @import("captures.zig");
pub const arity = @import("arity.zig");

pub const Scope = resolve.Scope;
pub const BindingKind = resolve.BindingKind;
pub const BindingInfo = resolve.BindingInfo;
pub const Resolver = resolve.Resolver;
pub const CaptureAnalyzer = captures.CaptureAnalyzer;
pub const ArityChecker = arity.ArityChecker;

test {
    _ = resolve;
    _ = captures;
    _ = arity;
}
