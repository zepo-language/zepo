//! Reader-pass diagnostics for the LSP. Runs the actual Zepo reader against
//! a document and reports span-accurate parse errors.
//!
//! Originally lived in src/cli/lsp_cmd.zig as `checkDocument` — moved here
//! (zepo-vwns) so the new k9hh LSP server can publish reader diagnostics on
//! top of its lightweight byte-level checks. zepo-017z made this the single
//! source of truth: the old lsp_cmd.checkDocument copy (which had diverged, and
//! alone carried the top-level-special validation folded in below) was deleted
//! and `zepo lint` now calls this too.
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
const objects = runtime.objects;
const value_mod = @import("../abi/value.zig");
const Value = @import("../abi/mod.zig").Value;

pub const Diag = struct {
    range: analysis.Range,
    message: []const u8,
    owned: bool,
};

/// Run the reader/parser against `text` and append diagnostics. A *read* error
/// is terminal — the parser can't reliably recover, so reading stops after the
/// first one. Per-form *build* errors and top-level-special validation errors
/// (zepo-017z, folded in from the old lsp_cmd copy) do not stop the pass, so a
/// clean-reading document can surface several. Positions are byte-encoded; the
/// caller converts to the negotiated PositionEncoding via
/// analysis.convertRangeFromBytes.
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

        // zepo-017z: module/import/export/… are not lowered as ordinary AST;
        // validate their surface shape here (this check previously existed only
        // in the now-deleted lsp_cmd.checkDocument) and skip the builder.
        if (isTopLevelSpecial(form)) {
            if (validateTopLevelSpecial(form)) |msg| {
                const span = spans.get(form) orelse reader.Span{
                    .start = .{ .line = 1, .col = 1, .offset = 0 },
                    .end = .{ .line = 1, .col = 1, .offset = 0 },
                    .file = uri,
                };
                try out.append(alloc, .{
                    .range = spanToRange(span),
                    .message = msg,
                    .owned = false,
                });
            }
            continue;
        }

        _ = builder.build(form) catch |e| {
            const msg = try std.fmt.allocPrint(alloc, "syntax error: {s}", .{@errorName(e)});
            try out.append(alloc, .{
                .range = spanToRange(builder.current_span),
                .message = msg,
                .owned = true,
            });
            // Not terminal — keep checking the remaining top-level forms.
        };
    }
}

/// zepo-017z: true for top-level forms handled specially by the compiler
/// (module system + defmacro) rather than lowered as ordinary expressions.
fn isTopLevelSpecial(v: Value) bool {
    if (!value_mod.isPtr(v)) return false;
    if (!objects.isPair(v)) return false;
    const head = objects.pairCar(v).*;
    if (!objects.isSymbol(head)) return false;
    const name = objects.symbolName(head);
    const heads = [_][]const u8{ "module", "import", "export", "include", "package", "defmacro" };
    for (heads) |h| if (std.mem.eql(u8, name, h)) return true;
    return false;
}

/// zepo-017z: minimal surface-shape validation for the special forms above.
/// Returns a static diagnostic message, or null if the form looks well-formed.
fn validateTopLevelSpecial(v: Value) ?[]const u8 {
    const rest = objects.pairCdr(v).*;
    if (value_mod.isNil(rest)) return "missing arguments";
    if (!objects.isPair(rest)) return "invalid form structure";
    const head_name = objects.symbolName(objects.pairCar(v).*);
    const needs_symbol = [_][]const u8{ "module", "import", "package", "defmacro" };
    for (needs_symbol) |n| {
        if (std.mem.eql(u8, head_name, n)) {
            if (!objects.isSymbol(objects.pairCar(rest).*)) return "name must be a symbol";
            return null;
        }
    }
    return null;
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
