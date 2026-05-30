//! Reader-pass diagnostics for the LSP. Runs the actual Zepo reader against
//! a document and reports span-accurate parse errors.
//!
//! Originally lived in src/cli/lsp_cmd.zig as `checkDocument` — moved here
//! (zepo-vwns) so the new k9hh LSP server can publish reader diagnostics on
//! top of its lightweight byte-level checks.
//!
//! Each call boots a fresh GC + SymbolTable + Parser. That's not free per
//! keystroke, but for ordinary file sizes it's well under the round-trip
//! budget of an LSP didChange. If perf becomes an issue we can throttle.

const std = @import("std");
const gc_mod = @import("../gc/mod.zig");
const runtime = @import("../runtime/mod.zig");
const reader = @import("../reader/mod.zig");
const ast = @import("../ast/mod.zig");
const analysis = @import("analysis.zig");

pub const Diag = struct {
    range: analysis.Range,
    message: []const u8,
    owned: bool,
};

/// Run the reader/parser against `text` and append a diagnostic for the first
/// parse error encountered. The reader stops at the first error (the parser
/// can't reliably recover for follow-ups), so this returns at most one diag.
/// Positions are byte-encoded; the caller converts to the negotiated
/// PositionEncoding via analysis.convertRangeFromBytes.
pub fn check(
    alloc: std.mem.Allocator,
    uri: []const u8,
    text: []const u8,
    out: *std.ArrayListUnmanaged(Diag),
) !void {
    var gc = try gc_mod.GC.init(alloc);
    defer gc.deinit();
    var syms = try runtime.SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = reader.SpanTable.init(alloc);
    defer spans.deinit();
    var arena = ast.NodeArena.init(alloc);
    defer arena.deinit();

    var parser = reader.Parser.init(&gc, &syms, &spans, text, uri, alloc);
    defer parser.deinit();

    var builder = ast.Builder.init(&arena, &syms, alloc);
    builder.span_table = &spans;

    while (true) {
        const form = parser.readOne() catch |e| switch (e) {
            error.Eof => break,
            else => {
                if (parser.last_diag) |diag| {
                    try out.append(alloc, .{
                        .range = spanToRange(diag.span),
                        .message = diag.msg,
                        .owned = false,
                    });
                } else {
                    const msg = try std.fmt.allocPrint(alloc, "read error: {s}", .{@errorName(e)});
                    try out.append(alloc, .{
                        .range = .{
                            .start = .{ .line = 0, .character = 0 },
                            .end = .{ .line = 0, .character = 1 },
                        },
                        .message = msg,
                        .owned = true,
                    });
                }
                return;
            },
        };

        _ = builder.build(form) catch |e| {
            const msg = try std.fmt.allocPrint(alloc, "syntax error: {s}", .{@errorName(e)});
            try out.append(alloc, .{
                .range = spanToRange(builder.current_span),
                .message = msg,
                .owned = true,
            });
            return;
        };
    }
}

fn spanToRange(span: reader.Span) analysis.Range {
    const sl: u32 = if (span.start.line > 0) @intCast(span.start.line - 1) else 0;
    const sc: u32 = if (span.start.col > 0) @intCast(span.start.col - 1) else 0;
    const el: u32 = if (span.end.line > 0) @intCast(span.end.line - 1) else sl;
    const ec: u32 = if (span.end.col > 0) @intCast(span.end.col - 1) else sc;
    return .{
        .start = .{ .line = sl, .character = sc },
        .end = .{ .line = el, .character = ec },
    };
}
