//! zepo-wh3e — the "real pipeline" side of the hybrid analyzer specified in
//! docs/adr/0003-lsp-unified-analysis-strategy.md.
//!
//! When a document parses cleanly, we run reader → ast/Builder over it and
//! collect binding-kind information that the scanner-based Analysis can't
//! provide. When parsing fails at any stage, the result is null and callers
//! fall back to scanner output unchanged.
//!
//! This first cut surfaces top-level binding kinds only — enough to make
//! hover say "this is a primitive" or "this is a macro". Per-occurrence
//! local/capture resolution is filed as a follow-on; that needs the sema
//! resolver to expose its results.

const std = @import("std");
const gc_mod = @import("../gc/mod.zig");
const runtime = @import("../runtime/mod.zig");
const reader = @import("../reader/mod.zig");
const ast = @import("../ast/mod.zig");
const prims_register = @import("../prims/register.zig");

pub const Kind = enum {
    primitive,
    macro,
    module,
    /// Top-level (define NAME ...) — the value is a procedure (lambda).
    global_proc,
    /// Top-level (define NAME ...) — the value is a non-procedure expression.
    global_value,
    /// Top-level (define-syntax NAME ...) — local macro
    local_macro,
    /// zepo-ri9g: lexically bound in the enclosing lambda/let.
    local,
    /// zepo-ri9g: bound in an outer lambda, captured by closure.
    captured,
    /// zepo-ri9g: resolved at top level via the global scope or import.
    global,
};

// zepo-ri9g: A lexical scope range. Built one per lambda/let, marking the
// byte range of its body and the names it locally binds. Hover lookups
// walk these innermost-out to determine if a hovered name is local /
// captured / global.
//
// We use byte ranges rather than per-symbol-occurrence offsets because the
// reader does not span-tag interned symbol values (they're shared across
// all uses); only enclosing pairs get spans. Range lookup on the cursor
// offset sidesteps that constraint.
pub const ScopeRange = struct {
    body_start: u32,
    body_end: u32,
    /// True for lambdas; false for let-style bindings (no closure boundary).
    is_lambda: bool,
    /// Names locally bound in this scope. Keys are owned []u8.
    locals: std.StringHashMapUnmanaged(void) = .empty,
};

pub const RealAnalysis = struct {
    alloc: std.mem.Allocator,
    /// Maps top-level NAME -> Kind. Keys are owned []u8 copies so the
    /// RealAnalysis is independent of the underlying document buffer's
    /// lifetime — when the doc gets re-analyzed the old RealAnalysis can
    /// be deinit'd safely.
    top_level: std.StringHashMapUnmanaged(Kind) = .empty,
    /// zepo-ri9g: lexical scopes recorded in source order. Innermost
    /// scopes appear after their enclosing scopes in this list.
    scopes: std.ArrayListUnmanaged(ScopeRange) = .empty,

    pub fn deinit(self: *RealAnalysis) void {
        var it = self.top_level.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
        }
        self.top_level.deinit(self.alloc);
        for (self.scopes.items) |*sc| {
            var lit = sc.locals.iterator();
            while (lit.next()) |entry| self.alloc.free(entry.key_ptr.*);
            sc.locals.deinit(self.alloc);
        }
        self.scopes.deinit(self.alloc);
    }

    pub fn kindOf(self: *const RealAnalysis, name: []const u8) ?Kind {
        if (self.top_level.get(name)) |k| return k;
        if (prims_register.isPrimitive(name)) return .primitive;
        return null;
    }

    // zepo-ri9g: classify a hovered `name` at byte `offset`. Walk scopes
    // from outermost-to-innermost looking for ones whose body covers the
    // offset. The deepest match that binds `name` decides local vs captured.
    pub fn classifyAt(self: *const RealAnalysis, name: []const u8, offset: u32) ?Kind {
        var deepest_binding: ?usize = null;
        var deepest_containing: ?usize = null;
        for (self.scopes.items, 0..) |sc, i| {
            if (offset < sc.body_start or offset > sc.body_end) continue;
            deepest_containing = i;
            if (sc.locals.contains(name)) deepest_binding = i;
        }
        if (deepest_binding) |bi| {
            // If a lambda scope sits strictly between the binding and the
            // use, it's captured. Otherwise local.
            const containing = deepest_containing.?;
            var j = bi + 1;
            while (j <= containing) : (j += 1) {
                const s = self.scopes.items[j];
                if (s.is_lambda and offset >= s.body_start and offset <= s.body_end and !s.locals.contains(name))
                    return .captured;
            }
            return .local;
        }
        if (self.top_level.get(name)) |k| return k;
        if (prims_register.isPrimitive(name)) return .primitive;
        return .global;
    }
};

/// Attempt the full reader+ast pass over `text`. Returns null on any
/// parse/build error — caller falls back to scanner Analysis.
pub fn tryAnalyze(alloc: std.mem.Allocator, uri: []const u8, text: []const u8) ?RealAnalysis {
    var gc = gc_mod.GC.init(alloc) catch return null;
    defer gc.deinit();
    var syms = runtime.SymbolTable.init(&gc, alloc) catch return null;
    defer syms.deinit();
    var spans = reader.SpanTable.init(alloc);
    defer spans.deinit();
    var arena = ast.NodeArena.init(alloc);
    defer arena.deinit();

    var parser = reader.Parser.init(&gc, &syms, &spans, text, uri, alloc);
    defer parser.deinit();

    var builder = ast.Builder.init(&arena, &syms, alloc);
    builder.span_table = &spans;

    var result = RealAnalysis{ .alloc = alloc };
    errdefer result.deinit();

    // zepo-ri9g: collect every top-level node so we can do both passes
    // (top-level kinds, then occurrence resolution).
    var top_nodes = std.ArrayListUnmanaged(ast.NodeId).empty;
    defer top_nodes.deinit(alloc);

    while (true) {
        const form = parser.readOne() catch |e| switch (e) {
            error.Eof => break,
            else => {
                result.deinit();
                return null;
            },
        };

        const node_id = builder.build(form) catch {
            result.deinit();
            return null;
        };

        top_nodes.append(alloc, node_id) catch {
            result.deinit();
            return null;
        };

        recordTopLevel(&arena, node_id, &result) catch {
            result.deinit();
            return null;
        };
    }

    // zepo-ri9g: second pass — record lexical scope ranges and the names
    // bound in each. Hover later uses ranges-by-cursor-offset to classify
    // a name as local / captured / global. Failures are non-fatal.
    var scope_walker = ScopeWalker{
        .alloc = alloc,
        .arena = &arena,
        .out = &result,
    };
    for (top_nodes.items) |nid| {
        // zepo-rmcp: a partial scope walk yields WRONG classifications (a local
        // reported as global, missed shadows). Better to have no real analysis
        // than incorrect data — return null so the caller falls back to the
        // simpler classifier, consistent with the other error paths above.
        scope_walker.walk(nid) catch {
            result.deinit();
            return null;
        };
    }

    return result;
}

// zepo-ri9g: scope walker. For each lambda/let encountered, append a
// ScopeRange to the result. Sym_refs themselves aren't recorded — hover
// classifies them lazily by name lookup against the ranges (via
// RealAnalysis.classifyAt).
const ScopeWalker = struct {
    alloc: std.mem.Allocator,
    arena: *ast.NodeArena,
    out: *RealAnalysis,

    fn walk(self: *ScopeWalker, id: ast.NodeId) anyerror!void {
        const node = self.arena.get(id).*;
        switch (node) {
            .literal, .quote, .sym_ref => {},
            .define => |d| try self.walk(d.value),
            .set_bang => |sb| try self.walk(sb.value),
            .if_expr => |ie| {
                try self.walk(ie.cond);
                try self.walk(ie.then_);
                if (ie.else_) |e| try self.walk(e);
            },
            .cond_expr => |c| {
                for (c.clauses) |cl| {
                    try self.walk(cl.test_);
                    for (cl.body) |bid| try self.walk(bid);
                }
            },
            .application => |app| {
                try self.walk(app.func);
                for (app.args) |aid| try self.walk(aid);
            },
            .sequence => |seq| {
                for (seq.exprs) |eid| try self.walk(eid);
            },
            .with_handler => |wh| {
                try self.walk(wh.handler);
                for (wh.body) |bid| try self.walk(bid);
            },
            .parameterize => |pz| { // zepo-6o3p
                for (pz.params) |pid| try self.walk(pid);
                for (pz.inits) |iid| try self.walk(iid);
                for (pz.body) |bid| try self.walk(bid);
            },
            .restart_case => |rc| { // zepo-g120
                for (rc.body) |bid| try self.walk(bid);
                for (rc.clauses) |cid| try self.walk(cid);
            },
            .lambda => |la| {
                var range: ScopeRange = .{
                    .body_start = la.span.start.offset,
                    .body_end = la.span.end.offset,
                    .is_lambda = true,
                };
                for (la.params) |p| try self.putOwnedKey(&range.locals, p);
                if (la.rest_param) |rp| try self.putOwnedKey(&range.locals, rp);
                for (la.keyword_params) |kp| try self.putOwnedKey(&range.locals, kp.name);
                try self.out.scopes.append(self.alloc, range);
                for (la.body) |bid| try self.walk(bid);
            },
            .let_expr => |le| {
                for (le.bindings) |b| try self.walk(b.value);
                var range: ScopeRange = .{
                    .body_start = le.span.start.offset,
                    .body_end = le.span.end.offset,
                    .is_lambda = false,
                };
                for (le.bindings) |b| try self.putOwnedKey(&range.locals, b.name);
                try self.out.scopes.append(self.alloc, range);
                for (le.body) |bid| try self.walk(bid);
            },
            .let_star_expr => |le| {
                var range: ScopeRange = .{
                    .body_start = le.span.start.offset,
                    .body_end = le.span.end.offset,
                    .is_lambda = false,
                };
                for (le.bindings) |b| {
                    try self.walk(b.value);
                    try self.putOwnedKey(&range.locals, b.name);
                }
                try self.out.scopes.append(self.alloc, range);
                for (le.body) |bid| try self.walk(bid);
            },
            .module_decl => |m| {
                for (m.body) |bid| try self.walk(bid);
            },
            .import_stmt => {},
        }
    }

    fn putOwnedKey(self: *ScopeWalker, map: *std.StringHashMapUnmanaged(void), name: []const u8) !void {
        if (map.contains(name)) return;
        const k = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(k);
        try map.put(self.alloc, k, {});
    }
};

fn recordTopLevel(
    arena: *ast.NodeArena,
    node_id: ast.NodeId,
    out: *RealAnalysis,
) !void {
    const node = arena.get(node_id).*;
    switch (node) {
        .define => |d| {
            const child = arena.get(d.value).*;
            const kind: Kind = switch (child) {
                .lambda => .global_proc,
                else => .global_value,
            };
            try insertKind(out, d.name, kind);
        },
        .sequence => |seq| {
            // The :documentation desugaring (zepo-uney) wraps defines in a
            // sequence: (begin (define ...) (%set-binding-doc! ...)). Walk
            // the children so the wrapped define is still captured.
            for (seq.exprs) |child_id| try recordTopLevel(arena, child_id, out);
        },
        .module_decl => |m| {
            try insertKind(out, m.name, .module);
            for (m.body) |child_id| try recordTopLevel(arena, child_id, out);
        },
        else => {},
    }
}

fn insertKind(out: *RealAnalysis, name: []const u8, kind: Kind) !void {
    if (out.top_level.contains(name)) return; // first define wins
    const key = try out.alloc.dupe(u8, name);
    errdefer out.alloc.free(key);
    try out.top_level.put(out.alloc, key, kind);
}

test "tryAnalyze: top-level kinds" {
    const t = std.testing;
    const a = t.allocator;
    const src =
        \\(define foo 1)
        \\(define bar (lambda (x) x))
        \\(define baz :documentation "doc" 42)
    ;
    var r = tryAnalyze(a, "test.lisp", src) orelse return error.TestUnexpectedResult;
    defer r.deinit();
    try t.expectEqual(Kind.global_value, r.kindOf("foo").?);
    try t.expectEqual(Kind.global_proc, r.kindOf("bar").?);
    try t.expectEqual(Kind.global_value, r.kindOf("baz").?);
    try t.expectEqual(Kind.primitive, r.kindOf("cons").?);
    try t.expect(r.kindOf("not-a-thing") == null);
}

test "tryAnalyze: classifyAt reports local for a lambda parameter use" {
    const t = std.testing;
    const a = t.allocator;
    // (define foo (lambda (x) (cons x 1)))
    //  0         1         2         3
    //  0123456789012345678901234567890123456
    //                                 ^ `x` use inside cons is at byte 30
    const src = "(define foo (lambda (x) (cons x 1)))";
    var r = tryAnalyze(a, "test.lisp", src) orelse return error.TestUnexpectedResult;
    defer r.deinit();
    try t.expectEqual(@as(?Kind, .local), r.classifyAt("x", 30));
    try t.expectEqual(@as(?Kind, .primitive), r.classifyAt("cons", 25));
}

test "tryAnalyze: classifyAt reports captured for a closure-captured name" {
    const t = std.testing;
    const a = t.allocator;
    // (define adder (lambda (n) (lambda (x) (+ n x))))
    // `n` inside (+ n x) is at byte 41 — it's bound in the outer lambda
    // (param) but used inside the inner lambda, so it's captured.
    const src = "(define adder (lambda (n) (lambda (x) (+ n x))))";
    var r = tryAnalyze(a, "test.lisp", src) orelse return error.TestUnexpectedResult;
    defer r.deinit();
    try t.expectEqual(@as(?Kind, .captured), r.classifyAt("n", 41));
}

test "tryAnalyze: classifyAt reports global for an unbound name" {
    const t = std.testing;
    const a = t.allocator;
    const src = "(define foo (bar))";
    var r = tryAnalyze(a, "test.lisp", src) orelse return error.TestUnexpectedResult;
    defer r.deinit();
    // `bar` is unbound — should classify as global (not primitive, not local).
    try t.expectEqual(@as(?Kind, .global), r.classifyAt("bar", 13));
}

test "tryAnalyze: returns null on parse error" {
    const t = std.testing;
    const a = t.allocator;
    const src = "(define foo (lambda (x"; // unterminated
    const result = tryAnalyze(a, "test.lisp", src);
    try t.expect(result == null);
}
