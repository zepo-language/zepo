//! Closure conversion pass. For v1 this reuses captures.zig output —
//! the AST walker already populated free_vars/mutated_vars. This file
//! is the public entry for future, more sophisticated conversion work.

const std = @import("std");
const ast = @import("../ast/mod.zig");
const sema = @import("../sema/mod.zig");

pub fn convert(arena: *ast.NodeArena, root_id: ast.NodeId, allocator: std.mem.Allocator) !void {
    var analyzer = sema.CaptureAnalyzer.init(arena, allocator);
    try analyzer.analyze(root_id);
}
