//! Lexical binding resolution and scope analysis.

const std = @import("std");
const ast = @import("../ast/mod.zig");
const Node = ast.Node;
const NodeId = ast.NodeId;
const NodeArena = ast.NodeArena;

pub const BindingKind = enum {
    local,
    captured,
    global,
    builtin,
};

pub const BindingInfo = struct {
    kind: BindingKind,
    name: []const u8,
    is_mutated: bool = false,
    capture_idx: u16 = 0,
    local_slot: u16 = 0,
};

pub const Scope = struct {
    parent: ?*Scope,
    bindings: std.StringHashMap(BindingInfo),
    allocator: std.mem.Allocator,

    pub fn init(parent: ?*Scope, allocator: std.mem.Allocator) !Scope {
        return .{
            .parent = parent,
            .bindings = std.StringHashMap(BindingInfo).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(s: *Scope) void {
        s.bindings.deinit();
    }

    pub fn define(s: *Scope, name: []const u8, info: BindingInfo) !void {
        try s.bindings.put(name, info);
    }

    pub fn lookup(s: *Scope, name: []const u8) ?*BindingInfo {
        if (s.bindings.getPtr(name)) |info| return info;
        if (s.parent) |p| return p.lookup(name);
        return null;
    }

    /// Look up a name only in *this* scope — ignore ancestors.
    pub fn lookupLocal(s: *Scope, name: []const u8) ?*BindingInfo {
        return s.bindings.getPtr(name);
    }
};

pub const Resolver = struct {
    arena: *NodeArena,
    allocator: std.mem.Allocator,

    pub fn init(arena: *NodeArena, allocator: std.mem.Allocator) Resolver {
        return .{ .arena = arena, .allocator = allocator };
    }

    /// Walk the node graph under `root_id`, validating references against scope.
    /// Reference resolution is advisory at this pass — it does not rewrite the
    /// AST. Its job is to make sure every sym_ref resolves somewhere.
    pub fn resolve(r: *Resolver, root_id: NodeId, global_scope: *Scope) !void {
        try r.resolveNode(root_id, global_scope);
    }

    fn resolveNode(r: *Resolver, id: NodeId, scope: *Scope) !void {
        const n = r.arena.get(id).*;
        switch (n) {
            .literal, .quote => {},
            .sym_ref => |sr| {
                if (scope.lookup(sr.name) == null) {
                    // Treat as implicit global. Do not error — globals are only
                    // known after all top-level defines.
                }
            },
            .define => |d| {
                try r.resolveNode(d.value, scope);
                // Register as global if we're at the top level (parent-less scope == global).
                const target = r.findGlobalScope(scope);
                if (target.lookupLocal(d.name) == null) {
                    try target.define(d.name, .{ .kind = .global, .name = d.name });
                }
            },
            .set_bang => |s| {
                try r.resolveNode(s.value, scope);
                if (scope.lookup(s.name)) |info| {
                    info.is_mutated = true;
                }
            },
            .if_expr => |i| {
                try r.resolveNode(i.cond, scope);
                try r.resolveNode(i.then_, scope);
                if (i.else_) |e| try r.resolveNode(e, scope);
            },
            .cond_expr => |c| {
                for (c.clauses) |clause| {
                    try r.resolveNode(clause.test_, scope);
                    for (clause.body) |bid| try r.resolveNode(bid, scope);
                }
            },
            .application => |app| {
                try r.resolveNode(app.func, scope);
                for (app.args) |a| try r.resolveNode(a, scope);
            },
            .sequence => |seq| {
                for (seq.exprs) |e| try r.resolveNode(e, scope);
            },
            .module_decl => unreachable,
            .import_stmt => {}, // no new local bindings; handled at runtime
            .lambda => |_| {
                var inner = try Scope.init(scope, r.allocator);
                defer inner.deinit();
                // Re-read since we need current slice data.
                const nl = r.arena.get(id).*.lambda;
                var slot: u16 = 0;
                for (nl.params) |pname| {
                    try inner.define(pname, .{ .kind = .local, .name = pname, .local_slot = slot });
                    slot += 1;
                }
                if (nl.rest_param) |rp| {
                    try inner.define(rp, .{ .kind = .local, .name = rp, .local_slot = slot });
                    slot += 1;
                }
                for (nl.body) |bid| try r.resolveNode(bid, &inner);
            },
            .let_expr => |let| {
                for (let.bindings) |b_| try r.resolveNode(b_.value, scope);
                var inner = try Scope.init(scope, r.allocator);
                defer inner.deinit();
                for (let.bindings) |b_| {
                    try inner.define(b_.name, .{ .kind = .local, .name = b_.name });
                }
                for (let.body) |bid| try r.resolveNode(bid, &inner);
            },
            .let_star_expr => |let| {
                var inner = try Scope.init(scope, r.allocator);
                defer inner.deinit();
                for (let.bindings) |b_| {
                    try r.resolveNode(b_.value, &inner);
                    try inner.define(b_.name, .{ .kind = .local, .name = b_.name });
                }
                for (let.body) |bid| try r.resolveNode(bid, &inner);
            },
        }
    }

    fn findGlobalScope(_: *Resolver, scope: *Scope) *Scope {
        var cur = scope;
        while (cur.parent) |p| cur = p;
        return cur;
    }
};
