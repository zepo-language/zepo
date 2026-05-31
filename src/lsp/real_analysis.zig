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
};

pub const RealAnalysis = struct {
    alloc: std.mem.Allocator,
    /// Maps top-level NAME -> Kind. Keys are owned []u8 copies so the
    /// RealAnalysis is independent of the underlying document buffer's
    /// lifetime — when the doc gets re-analyzed the old RealAnalysis can
    /// be deinit'd safely.
    top_level: std.StringHashMapUnmanaged(Kind) = .empty,

    pub fn deinit(self: *RealAnalysis) void {
        var it = self.top_level.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
        }
        self.top_level.deinit(self.alloc);
    }

    pub fn kindOf(self: *const RealAnalysis, name: []const u8) ?Kind {
        if (self.top_level.get(name)) |k| return k;
        if (prims_register.isPrimitive(name)) return .primitive;
        return null;
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

        recordTopLevel(&arena, node_id, &result) catch {
            result.deinit();
            return null;
        };
    }

    return result;
}

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

test "tryAnalyze: returns null on parse error" {
    const t = std.testing;
    const a = t.allocator;
    const src = "(define foo (lambda (x"; // unterminated
    const result = tryAnalyze(a, "test.lisp", src);
    try t.expect(result == null);
}
