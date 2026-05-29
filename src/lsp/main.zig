//! Standalone `zepo-lsp` binary. Speaks LSP over stdin/stdout.
//!
//! Editors can launch this directly without going through the multi-command
//! `zepo` driver. Equivalent to `zepo lsp`.
//!
//! See bead zepo-k9hh.

const std = @import("std");
const zepo = @import("zepo");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    try zepo.lsp.runStdio(gpa.allocator());
}
