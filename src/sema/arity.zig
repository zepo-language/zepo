//! Compile-time arity checks for direct applications of known lambdas.

const std = @import("std");
const ast = @import("../ast/mod.zig");
const Node = ast.Node;
const NodeId = ast.NodeId;
const NodeArena = ast.NodeArena;

pub const ArityDiag = struct {
    expected: u16,
    has_rest: bool,
    actual: u16,
};

pub const ArityChecker = struct {
    arena: *NodeArena,
    allocator: std.mem.Allocator,
    diagnostics: std.ArrayList(ArityDiag),

    pub fn init(arena: *NodeArena, allocator: std.mem.Allocator) ArityChecker {
        return .{
            .arena = arena,
            .allocator = allocator,
            .diagnostics = std.ArrayList(ArityDiag){},
        };
    }

    pub fn deinit(a: *ArityChecker) void {
        a.diagnostics.deinit(a.allocator);
    }

    pub fn check(a: *ArityChecker, root_id: NodeId) !void {
        try a.walk(root_id);
    }

    fn walk(a: *ArityChecker, id: NodeId) !void {
        const n = a.arena.get(id).*;
        switch (n) {
            .literal, .quote, .sym_ref => {},
            .define => |d| try a.walk(d.value),
            .set_bang => |s| try a.walk(s.value),
            .if_expr => |i| {
                try a.walk(i.cond);
                try a.walk(i.then_);
                if (i.else_) |e| try a.walk(e);
            },
            .cond_expr => |c| {
                for (c.clauses) |cl| {
                    try a.walk(cl.test_);
                    for (cl.body) |bid| try a.walk(bid);
                }
            },
            .application => |app| {
                try a.walk(app.func);
                for (app.args) |ar| try a.walk(ar);
                // If the func is a direct lambda literal we can check.
                const func_n = a.arena.get(app.func).*;
                if (func_n == .lambda) {
                    const lam = func_n.lambda;
                    const expected: u16 = @intCast(lam.params.len);
                    const actual: u16 = @intCast(app.args.len);
                    if (lam.rest_param) |_| {
                        if (actual < expected) {
                            try a.diagnostics.append(a.allocator, .{ .expected = expected, .has_rest = true, .actual = actual });
                        }
                    } else {
                        if (actual != expected) {
                            try a.diagnostics.append(a.allocator, .{ .expected = expected, .has_rest = false, .actual = actual });
                        }
                    }
                }
            },
            .sequence => |seq| {
                for (seq.exprs) |e| try a.walk(e);
            },
            .lambda => |lam| {
                for (lam.body) |bid| try a.walk(bid);
            },
            .let_expr => |let| {
                for (let.bindings) |b_| try a.walk(b_.value);
                for (let.body) |bid| try a.walk(bid);
            },
            .let_star_expr => |let| {
                for (let.bindings) |b_| try a.walk(b_.value);
                for (let.body) |bid| try a.walk(bid);
            },
            .module_decl => unreachable,
            .import_stmt => {}, // no arity to check — handled at runtime
        }
    }
};
