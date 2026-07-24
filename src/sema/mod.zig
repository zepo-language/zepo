//! Semantic analysis aggregate.

// zepo-6aaf: resolve.zig (name/scope Resolver) and arity.zig (compile-time
// ArityChecker) were never wired into the compile pipeline — eval.zig runs
// only the CaptureAnalyzer, and the LSP uses its own lsp/resolver.zig — and
// resolve.zig was incomplete (missing node kinds). They were deleted rather
// than resurrected: the runtime already reports arity mismatches with source
// locations, so compile-time arity checking added little for a dynamic Lisp.

pub const captures = @import("captures.zig");

pub const CaptureAnalyzer = captures.CaptureAnalyzer;

test {
    _ = captures;
}
