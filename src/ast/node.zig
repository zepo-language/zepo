//! Typed AST node representation.
//!
//! Nodes live inside a NodeArena and are referenced by NodeId (index).
//! Semantic analysis populates the `free_vars`/`mutated_vars` fields on
//! lambda nodes in place.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;

const reader_source = @import("../reader/source.zig");
pub const Span = reader_source.Span;
pub const Pos = reader_source.Pos;

pub const NodeId = u32;

pub const LiteralKind = union(enum) {
    nil,
    boolean: bool,
    fixnum: i63,
    float: f64,
    character: u21,
    string: []const u8,
};

pub const CondClause = struct {
    test_: NodeId,
    body: []NodeId, // empty means (cond (test) ...) where the test value is the result
};

pub const LetBinding = struct {
    name: []const u8,
    value: NodeId,
};

pub const KwDefault = union(enum) {
    nil: void,
    boolean: bool,
    fixnum: i64,
    float: f64,
    string: []const u8,
};

pub const KwParam = struct {
    name: []const u8,
    default: KwDefault,
};

pub const Node = union(enum) {
    literal: struct { val: LiteralKind, span: Span },
    sym_ref: struct { name: []const u8, span: Span },
    quote: struct { datum: Value, span: Span },
    lambda: struct {
        params: []const []const u8,
        rest_param: ?[]const u8,
        keyword_params: []const KwParam = &.{},
        body: []NodeId,
        span: Span,
        // filled by semantic analysis
        free_vars: []const []const u8 = &.{},
        mutated_vars: []const []const u8 = &.{},
        // zepo-uney: docstring from :documentation keyword, if any
        docstring: ?[]const u8 = null,
    },
    define: struct {
        name: []const u8,
        value: NodeId,
        span: Span,
        // zepo-uney: docstring from :documentation keyword, if any
        docstring: ?[]const u8 = null,
    },
    set_bang: struct { name: []const u8, value: NodeId, span: Span },
    if_expr: struct { cond: NodeId, then_: NodeId, else_: ?NodeId, span: Span },
    cond_expr: struct { clauses: []const CondClause, span: Span },
    application: struct { func: NodeId, args: []const NodeId, span: Span },
    sequence: struct { exprs: []NodeId, span: Span },
    let_expr: struct {
        bindings: []const LetBinding,
        body: []NodeId,
        span: Span,
        mutated_vars: []const []const u8 = &.{},
    },
    let_star_expr: struct {
        bindings: []const LetBinding,
        body: []NodeId,
        span: Span,
        mutated_vars: []const []const u8 = &.{},
    },
    module_decl: struct {
        name: []const u8,
        exports: []const []const u8,
        body: []const NodeId,
        span: Span,
    },
    import_stmt: struct {
        name: []const u8,
        selection: ImportSelection,
        span: Span,
    },
    /// zepo-9bi: (with-exception-handler H (lambda () body...)) — emitted
    /// only when the second arg is a literal 0-arg lambda. handler is the
    /// handler expression; body is the inlined lambda body. Compiles to
    /// PUSH_HANDLER ... POP_HANDLER bytecode so yields inside body don't
    /// destroy the handler frame.
    with_handler: struct {
        handler: NodeId,
        body: []NodeId,
        span: Span,
    },
    /// zepo-6o3p: (parameterize ((p1 v1) (p2 v2) ...) body...). `params` and
    /// `inits` are parallel arrays (same length); each (pi vi) installs a
    /// dynamic binding for the extent of body. Compiles to PUSH_PARAM ...
    /// POP_PARAMS so yields/raises inside body unwind the bindings correctly.
    parameterize: struct {
        params: []NodeId,
        inits: []NodeId,
        body: []NodeId,
        span: Span,
    },
};

pub const ImportSelection = union(enum) {
    all,
    only: []const []const u8,
    as_alias: []const u8,
};

pub const NodeArena = struct {
    nodes: std.ArrayList(Node),
    allocator: std.mem.Allocator,
    /// Backing storage for slices owned by nodes (param names, body ids, etc).
    strings: std.ArrayList([]u8),
    node_id_lists: std.ArrayList([]NodeId),
    name_lists: std.ArrayList([][]const u8),
    clause_lists: std.ArrayList([]CondClause),
    binding_lists: std.ArrayList([]LetBinding),
    kw_param_lists: std.ArrayList([]KwParam),

    pub fn init(allocator: std.mem.Allocator) NodeArena {
        return .{
            .nodes = std.ArrayListUnmanaged(Node).empty,
            .allocator = allocator,
            .strings = std.ArrayListUnmanaged([]u8).empty,
            .node_id_lists = std.ArrayListUnmanaged([]NodeId).empty,
            .name_lists = std.ArrayListUnmanaged([][]const u8).empty,
            .clause_lists = std.ArrayListUnmanaged([]CondClause).empty,
            .binding_lists = std.ArrayListUnmanaged([]LetBinding).empty,
            .kw_param_lists = std.ArrayListUnmanaged([]KwParam).empty,
        };
    }

    pub fn deinit(a: *NodeArena) void {
        for (a.strings.items) |s| a.allocator.free(s);
        a.strings.deinit(a.allocator);
        for (a.node_id_lists.items) |l| a.allocator.free(l);
        a.node_id_lists.deinit(a.allocator);
        for (a.name_lists.items) |l| a.allocator.free(l);
        a.name_lists.deinit(a.allocator);
        for (a.clause_lists.items) |l| a.allocator.free(l);
        a.clause_lists.deinit(a.allocator);
        for (a.binding_lists.items) |l| a.allocator.free(l);
        a.binding_lists.deinit(a.allocator);
        for (a.kw_param_lists.items) |l| a.allocator.free(l);
        a.kw_param_lists.deinit(a.allocator);
        a.nodes.deinit(a.allocator);
    }

    pub fn add(a: *NodeArena, n: Node) !NodeId {
        const id: NodeId = @intCast(a.nodes.items.len);
        try a.nodes.append(a.allocator, n);
        return id;
    }

    pub fn get(a: *NodeArena, id: NodeId) *Node {
        return &a.nodes.items[id];
    }

    /// Duplicate a string into arena-owned memory. Returned slice lives for arena lifetime.
    pub fn dupString(a: *NodeArena, s: []const u8) ![]const u8 {
        const copy = try a.allocator.dupe(u8, s);
        try a.strings.append(a.allocator, copy);
        return copy;
    }

    pub fn dupNodeIds(a: *NodeArena, ids: []const NodeId) ![]NodeId {
        const copy = try a.allocator.dupe(NodeId, ids);
        try a.node_id_lists.append(a.allocator, copy);
        return copy;
    }

    pub fn dupNames(a: *NodeArena, names: []const []const u8) ![][]const u8 {
        const copy = try a.allocator.alloc([]const u8, names.len);
        for (names, 0..) |n, i| copy[i] = n;
        try a.name_lists.append(a.allocator, copy);
        return copy;
    }

    pub fn dupClauses(a: *NodeArena, clauses: []const CondClause) ![]CondClause {
        const copy = try a.allocator.dupe(CondClause, clauses);
        try a.clause_lists.append(a.allocator, copy);
        return copy;
    }

    pub fn dupBindings(a: *NodeArena, bindings: []const LetBinding) ![]LetBinding {
        const copy = try a.allocator.dupe(LetBinding, bindings);
        try a.binding_lists.append(a.allocator, copy);
        return copy;
    }

    pub fn dupKwParams(a: *NodeArena, kps: []const KwParam) ![]KwParam {
        const copy = try a.allocator.dupe(KwParam, kps);
        try a.kw_param_lists.append(a.allocator, copy);
        return copy;
    }
};

pub fn dummySpan() Span {
    return .{
        .start = .{ .line = 0, .col = 0, .offset = 0 },
        .end = .{ .line = 0, .col = 0, .offset = 0 },
        .file = "",
    };
}
