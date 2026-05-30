//! Lightweight static analysis for the Zepo LSP.
//!
//! We deliberately do NOT instantiate the GC/runtime here. The LSP needs to
//! answer hover / definition / completion fast, on partially broken source,
//! over many open documents. Instead we run a tiny S-expression aware token
//! scan over raw bytes and extract:
//!
//!   - top-level (define NAME ...)            -> Definition
//!   - top-level (module NAME ...)            -> Definition (kind=module)
//!   - (import M)            / :as A          -> Import
//!   - (import M (a b c))                     -> Import + selected names
//!   - every symbol occurrence with its byte/line offsets
//!
//! Diagnostics still go through the real reader (see `lsp_cmd`) so syntax
//! errors stay aligned with what `zepo run` would produce.
//!
//! Resolution rules approximate ADR 0001:
//!   - bare symbol  -> look up local definitions
//!   - prefix.suffix-> if prefix matches an alias from (import M ...)/(:as A),
//!                     treat as qualified access to that namespace.
//!
//! See bead zepo-k9hh.

const std = @import("std");

/// LSP PositionEncodingKind. Per LSP 3.17, `utf-8` means a Position's
/// `character` field counts UTF-8 code units (bytes); `utf-16` counts UTF-16
/// code units. `utf-32` counts Unicode code points. We support utf-8 and
/// utf-16 (zepo-pewz).
pub const PositionEncoding = enum { utf8, utf16, utf32 };

pub const Pos = struct {
    line: u32, // zero-based for LSP
    character: u32, // zero-based, units depend on negotiated encoding.
};

pub const Range = struct {
    start: Pos,
    end: Pos,

    pub fn fromOffsets(text: []const u8, start_off: usize, end_off: usize) Range {
        return .{
            .start = offsetToPos(text, start_off),
            .end = offsetToPos(text, end_off),
        };
    }

    pub fn fromOffsetsEnc(text: []const u8, start_off: usize, end_off: usize, enc: PositionEncoding) Range {
        return .{
            .start = offsetToPosEnc(text, start_off, enc),
            .end = offsetToPosEnc(text, end_off, enc),
        };
    }
};

/// Decode a single UTF-8 sequence starting at `text[i]`. Returns
/// `(code_point, byte_len)`. On invalid bytes treats the lead byte as a single
/// 0xFFFD-equivalent unit (advance 1 byte, code point 0).
fn utf8DecodeAt(text: []const u8, i: usize) struct { cp: u21, len: usize } {
    const c = text[i];
    if (c < 0x80) return .{ .cp = c, .len = 1 };
    const seq_len: usize = if (c < 0xC0) 1 else if (c < 0xE0) 2 else if (c < 0xF0) 3 else 4;
    if (seq_len == 1 or i + seq_len > text.len) return .{ .cp = 0, .len = 1 };
    const slice = text[i .. i + seq_len];
    const cp = std.unicode.utf8Decode(slice) catch return .{ .cp = 0, .len = 1 };
    return .{ .cp = cp, .len = seq_len };
}

/// Number of UTF-16 code units a code point occupies (1 for BMP, 2 for
/// supplementary planes).
fn utf16Units(cp: u21) u32 {
    return if (cp >= 0x10000) 2 else 1;
}

/// Backwards-compatible default: byte offsets (utf-8).
pub fn offsetToPos(text: []const u8, offset: usize) Pos {
    return offsetToPosEnc(text, offset, .utf8);
}

pub fn posToOffset(text: []const u8, p: Pos) usize {
    return posToOffsetEnc(text, p, .utf8);
}

pub fn offsetToPosEnc(text: []const u8, offset: usize, enc: PositionEncoding) Pos {
    var line: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    const limit = @min(offset, text.len);
    while (i < limit) {
        if (text[i] == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }
        switch (enc) {
            .utf8 => {
                col += 1;
                i += 1;
            },
            .utf16 => {
                const d = utf8DecodeAt(text, i);
                col += utf16Units(d.cp);
                i += d.len;
            },
            .utf32 => {
                const d = utf8DecodeAt(text, i);
                col += 1;
                i += d.len;
            },
        }
    }
    return .{ .line = line, .character = col };
}

/// Re-encode a byte-encoded Range to the given encoding, given the source text.
pub fn convertRangeFromBytes(text: []const u8, r: Range, enc: PositionEncoding) Range {
    const s_off = posToOffsetEnc(text, r.start, .utf8);
    const e_off = posToOffsetEnc(text, r.end, .utf8);
    return .{
        .start = offsetToPosEnc(text, s_off, enc),
        .end = offsetToPosEnc(text, e_off, enc),
    };
}

pub fn posToOffsetEnc(text: []const u8, p: Pos, enc: PositionEncoding) usize {
    var line: u32 = 0;
    var col: u32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (line == p.line and col == p.character) return i;
        if (text[i] == '\n') {
            line += 1;
            col = 0;
            i += 1;
            continue;
        }
        switch (enc) {
            .utf8 => {
                col += 1;
                i += 1;
            },
            .utf16 => {
                const d = utf8DecodeAt(text, i);
                col += utf16Units(d.cp);
                i += d.len;
            },
            .utf32 => {
                const d = utf8DecodeAt(text, i);
                col += 1;
                i += d.len;
            },
        }
    }
    return text.len;
}

pub const DefKind = enum { define, module };

pub const Definition = struct {
    name: []const u8,
    kind: DefKind,
    /// Range of the NAME symbol (suitable for goto-def target).
    name_range: Range,
    /// Range of the whole form.
    form_range: Range,
};

pub const ImportSelection = union(enum) {
    all, // (import M)
    as_alias: []const u8, // (import M :as A)
    only: []const []const u8, // (import M (a b c))
};

pub const Import = struct {
    module: []const u8,
    module_range: Range,
    selection: ImportSelection,
    /// Range of the whole import form.
    form_range: Range,
};

pub const SymbolHit = struct {
    /// Full text of the symbol token, e.g. "foo" or "t.transpose".
    text: []const u8,
    range: Range,
    /// If the token is qualified ("A.B"), this is the byte offset of the dot
    /// relative to the start of `text`. Otherwise null.
    dot_at: ?usize,
};

pub const Analysis = struct {
    alloc: std.mem.Allocator,
    defines: std.ArrayListUnmanaged(Definition) = .empty,
    imports: std.ArrayListUnmanaged(Import) = .empty,
    /// All symbol tokens in source order.
    symbols: std.ArrayListUnmanaged(SymbolHit) = .empty,
    /// Backing storage for `only` selection slices.
    only_arena: std.ArrayListUnmanaged([][]const u8) = .empty,

    pub fn deinit(a: *Analysis) void {
        a.defines.deinit(a.alloc);
        a.imports.deinit(a.alloc);
        a.symbols.deinit(a.alloc);
        for (a.only_arena.items) |slc| a.alloc.free(slc);
        a.only_arena.deinit(a.alloc);
    }

    /// Find the symbol hit covering byte offset `off`, or null. Ranges stored
    /// in Analysis are always byte-encoded (utf-8), so we round-trip with the
    /// utf-8 conversion to recover byte offsets.
    pub fn symbolAtOffset(a: *const Analysis, text: []const u8, off: usize) ?SymbolHit {
        for (a.symbols.items) |sym| {
            const s_off = posToOffsetEnc(text, sym.range.start, .utf8);
            const e_off = posToOffsetEnc(text, sym.range.end, .utf8);
            if (off >= s_off and off <= e_off) return sym;
        }
        return null;
    }

    pub fn findDefinition(a: *const Analysis, name: []const u8) ?Definition {
        for (a.defines.items) |d| {
            if (std.mem.eql(u8, d.name, name)) return d;
        }
        return null;
    }

    /// Returns the Import whose alias matches `prefix` (either explicit :as
    /// alias, or the module name itself for plain `(import M)`).
    pub fn findImportByAlias(a: *const Analysis, prefix: []const u8) ?Import {
        for (a.imports.items) |imp| {
            switch (imp.selection) {
                .as_alias => |alias| if (std.mem.eql(u8, alias, prefix)) return imp,
                .all => if (std.mem.eql(u8, imp.module, prefix)) return imp,
                .only => if (std.mem.eql(u8, imp.module, prefix)) return imp,
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// Tokenizer: byte-level S-expression scan tracking depth and symbol spans.
// ---------------------------------------------------------------------------

const Tok = struct {
    kind: enum { lparen, rparen, symbol, string, comment, other, eof },
    start: usize,
    end: usize,
};

const Scanner = struct {
    src: []const u8,
    pos: usize = 0,

    fn peek(s: *Scanner) ?u8 {
        if (s.pos >= s.src.len) return null;
        return s.src[s.pos];
    }
    fn adv(s: *Scanner) ?u8 {
        if (s.pos >= s.src.len) return null;
        const c = s.src[s.pos];
        s.pos += 1;
        return c;
    }

    fn next(s: *Scanner) Tok {
        // Skip whitespace and comments.
        while (s.pos < s.src.len) {
            const c = s.src[s.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                s.pos += 1;
            } else if (c == ';') {
                while (s.pos < s.src.len and s.src[s.pos] != '\n') s.pos += 1;
            } else break;
        }

        if (s.pos >= s.src.len) return .{ .kind = .eof, .start = s.pos, .end = s.pos };

        const start = s.pos;
        const c = s.src[s.pos];

        if (c == '(') {
            s.pos += 1;
            return .{ .kind = .lparen, .start = start, .end = s.pos };
        }
        if (c == ')') {
            s.pos += 1;
            return .{ .kind = .rparen, .start = start, .end = s.pos };
        }
        if (c == '"') {
            s.pos += 1;
            while (s.pos < s.src.len) {
                const d = s.src[s.pos];
                if (d == '\\' and s.pos + 1 < s.src.len) {
                    s.pos += 2;
                    continue;
                }
                s.pos += 1;
                if (d == '"') break;
            }
            return .{ .kind = .string, .start = start, .end = s.pos };
        }
        if (c == '\'' or c == '`' or c == ',') {
            s.pos += 1;
            return .{ .kind = .other, .start = start, .end = s.pos };
        }

        // Symbol/number/atom: read until delimiter.
        while (s.pos < s.src.len) {
            const d = s.src[s.pos];
            if (d == ' ' or d == '\t' or d == '\r' or d == '\n' or
                d == '(' or d == ')' or d == '"' or d == ';' or d == '\'' or
                d == '`' or d == ',')
                break;
            s.pos += 1;
        }
        return .{ .kind = .symbol, .start = start, .end = s.pos };
    }
};

fn isNumberLike(s: []const u8) bool {
    if (s.len == 0) return false;
    const c0 = s[0];
    if (c0 == '-' or c0 == '+') {
        if (s.len == 1) return false;
        return std.ascii.isDigit(s[1]);
    }
    return std.ascii.isDigit(c0);
}

fn isKeyword(s: []const u8) bool {
    return s.len >= 1 and s[0] == ':';
}

/// Run analysis on `text`. Caller owns and must `deinit` the returned Analysis.
pub fn analyze(alloc: std.mem.Allocator, text: []const u8) !Analysis {
    var a: Analysis = .{ .alloc = alloc };

    var sc = Scanner{ .src = text };

    // First pass: record every symbol token.
    while (true) {
        const t = sc.next();
        if (t.kind == .eof) break;
        if (t.kind != .symbol) continue;
        const txt = text[t.start..t.end];
        if (isNumberLike(txt)) continue;
        if (std.mem.eql(u8, txt, "#t") or std.mem.eql(u8, txt, "#f") or
            std.mem.eql(u8, txt, ".") or std.mem.eql(u8, txt, "..."))
            continue;
        const dot_at: ?usize = blk: {
            // Find the LAST dot that splits "prefix.suffix" — only treat as
            // qualified if both sides are non-empty.
            if (std.mem.indexOfScalar(u8, txt, '.')) |idx| {
                if (idx > 0 and idx + 1 < txt.len) break :blk idx;
            }
            break :blk null;
        };
        try a.symbols.append(alloc, .{
            .text = txt,
            .range = Range.fromOffsets(text, t.start, t.end),
            .dot_at = dot_at,
        });
    }

    // Second pass: walk forms to detect (define ...), (module ...), (import ...).
    // We re-scan, tracking depth and head-of-list context.
    sc = Scanner{ .src = text };
    try walkForms(alloc, &sc, text, &a);
    return a;
}

const AnalyzeError = error{OutOfMemory};

fn walkForms(alloc: std.mem.Allocator, sc: *Scanner, text: []const u8, a: *Analysis) AnalyzeError!void {
    while (true) {
        const t = sc.next();
        if (t.kind == .eof) return;
        if (t.kind == .lparen) {
            try handleList(alloc, sc, text, a, t.start);
        }
        // skip other tokens at top level
    }
}

/// Called just after an lparen. `lparen_start` is the byte offset of `(`.
fn handleList(alloc: std.mem.Allocator, sc: *Scanner, text: []const u8, a: *Analysis, lparen_start: usize) AnalyzeError!void {
    // Read the head token.
    const head = sc.next();
    if (head.kind == .rparen) return;
    if (head.kind == .eof) return;

    if (head.kind == .symbol) {
        const head_text = text[head.start..head.end];
        if (std.mem.eql(u8, head_text, "define")) {
            try handleDefine(alloc, sc, text, a, lparen_start);
            return;
        }
        if (std.mem.eql(u8, head_text, "module")) {
            try handleModule(alloc, sc, text, a, lparen_start);
            return;
        }
        if (std.mem.eql(u8, head_text, "import")) {
            try handleImport(alloc, sc, text, a, lparen_start);
            return;
        }
    }

    // Generic nested traversal — recurse into nested lists so we still
    // find `(define ...)` inside `(module ...)` bodies.
    if (head.kind == .lparen) {
        try handleList(alloc, sc, text, a, head.start);
    }
    try drainList(alloc, sc, text, a);
}

fn drainList(alloc: std.mem.Allocator, sc: *Scanner, text: []const u8, a: *Analysis) AnalyzeError!void {
    var depth: usize = 1;
    while (depth > 0) {
        const t = sc.next();
        switch (t.kind) {
            .eof => return,
            .lparen => {
                // Try to interpret as a definition/import too.
                try handleList(alloc, sc, text, a, t.start);
                // handleList consumes the whole sub-list.
            },
            .rparen => depth -= 1,
            else => {},
        }
    }
}

fn handleDefine(alloc: std.mem.Allocator, sc: *Scanner, text: []const u8, a: *Analysis, lparen_start: usize) AnalyzeError!void {
    // After "(define" the next interesting thing is either NAME or (NAME args).
    const second = sc.next();
    var name_tok: ?Tok = null;
    if (second.kind == .symbol) {
        name_tok = second;
    } else if (second.kind == .lparen) {
        const fname = sc.next();
        if (fname.kind == .symbol) name_tok = fname;
        // skip rest of the param list
        var d: usize = 1;
        while (d > 0) {
            const t = sc.next();
            if (t.kind == .eof) return;
            if (t.kind == .lparen) d += 1;
            if (t.kind == .rparen) d -= 1;
        }
    }
    const form_end = try skipUntilCloseAndReturnEnd(sc, text);
    if (name_tok) |nt| {
        try a.defines.append(alloc, .{
            .name = text[nt.start..nt.end],
            .kind = .define,
            .name_range = Range.fromOffsets(text, nt.start, nt.end),
            .form_range = Range.fromOffsets(text, lparen_start, form_end),
        });
    }
}

fn handleModule(alloc: std.mem.Allocator, sc: *Scanner, text: []const u8, a: *Analysis, lparen_start: usize) AnalyzeError!void {
    const name = sc.next();
    var name_tok: ?Tok = null;
    if (name.kind == .symbol) name_tok = name;

    // Walk module body, still picking up nested defines.
    var depth: usize = 1;
    var form_end: usize = sc.pos;
    while (depth > 0) {
        const t = sc.next();
        switch (t.kind) {
            .eof => break,
            .lparen => {
                try handleList(alloc, sc, text, a, t.start);
            },
            .rparen => {
                depth -= 1;
                form_end = t.end;
            },
            else => {},
        }
    }

    if (name_tok) |nt| {
        try a.defines.append(alloc, .{
            .name = text[nt.start..nt.end],
            .kind = .module,
            .name_range = Range.fromOffsets(text, nt.start, nt.end),
            .form_range = Range.fromOffsets(text, lparen_start, form_end),
        });
    }
}

fn handleImport(alloc: std.mem.Allocator, sc: *Scanner, text: []const u8, a: *Analysis, lparen_start: usize) AnalyzeError!void {
    const mod = sc.next();
    if (mod.kind != .symbol) {
        _ = try skipUntilCloseAndReturnEnd(sc, text);
        return;
    }
    const mod_text = text[mod.start..mod.end];

    var selection: ImportSelection = .all;

    const peek_tok = sc.next();
    if (peek_tok.kind == .symbol) {
        const pt = text[peek_tok.start..peek_tok.end];
        if (std.mem.eql(u8, pt, ":as")) {
            const alias = sc.next();
            if (alias.kind == .symbol) {
                selection = .{ .as_alias = text[alias.start..alias.end] };
            }
        }
    } else if (peek_tok.kind == .lparen) {
        // (a b c) selective unqualified
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer names.deinit(alloc);
        var d: usize = 1;
        while (d > 0) {
            const t = sc.next();
            switch (t.kind) {
                .eof => break,
                .lparen => d += 1,
                .rparen => d -= 1,
                .symbol => try names.append(alloc, text[t.start..t.end]),
                else => {},
            }
        }
        const owned = try alloc.alloc([]const u8, names.items.len);
        @memcpy(owned, names.items);
        try a.only_arena.append(alloc, owned);
        selection = .{ .only = owned };
    }

    const form_end = try skipUntilCloseAndReturnEnd(sc, text);
    try a.imports.append(alloc, .{
        .module = mod_text,
        .module_range = Range.fromOffsets(text, mod.start, mod.end),
        .selection = selection,
        .form_range = Range.fromOffsets(text, lparen_start, form_end),
    });
}

/// Consume tokens until matching rparen at depth 0, returning the byte
/// offset just past the closing paren.
fn skipUntilCloseAndReturnEnd(sc: *Scanner, text: []const u8) AnalyzeError!usize {
    _ = text;
    var depth: usize = 1;
    var end: usize = sc.pos;
    while (depth > 0) {
        const t = sc.next();
        switch (t.kind) {
            .eof => break,
            .lparen => depth += 1,
            .rparen => {
                depth -= 1;
                end = t.end;
            },
            else => {},
        }
    }
    return end;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "extracts top-level define" {
    const t = std.testing;
    const src = "(define foo 42)\n(define (bar x) (+ x 1))\n";
    var a = try analyze(t.allocator, src);
    defer a.deinit();
    try t.expectEqual(@as(usize, 2), a.defines.items.len);
    try t.expectEqualStrings("foo", a.defines.items[0].name);
    try t.expectEqualStrings("bar", a.defines.items[1].name);
}

test "extracts import with alias" {
    const t = std.testing;
    const src = "(import math/tensor :as t)\n(define m (t.transpose x))\n";
    var a = try analyze(t.allocator, src);
    defer a.deinit();
    try t.expectEqual(@as(usize, 1), a.imports.items.len);
    try t.expectEqualStrings("math/tensor", a.imports.items[0].module);
    switch (a.imports.items[0].selection) {
        .as_alias => |al| try t.expectEqualStrings("t", al),
        else => try t.expect(false),
    }
    // t.transpose should be a qualified symbol.
    var found = false;
    for (a.symbols.items) |s| {
        if (std.mem.eql(u8, s.text, "t.transpose")) {
            try t.expect(s.dot_at != null);
            found = true;
        }
    }
    try t.expect(found);
}

test "extracts selective import" {
    const t = std.testing;
    const src = "(import M (alpha beta gamma))\n";
    var a = try analyze(t.allocator, src);
    defer a.deinit();
    try t.expectEqual(@as(usize, 1), a.imports.items.len);
    switch (a.imports.items[0].selection) {
        .only => |names| {
            try t.expectEqual(@as(usize, 3), names.len);
            try t.expectEqualStrings("alpha", names[0]);
            try t.expectEqualStrings("gamma", names[2]);
        },
        else => try t.expect(false),
    }
}

test "module form is recorded and contains defines" {
    const t = std.testing;
    const src = "(module mymod (define inner 1))\n";
    var a = try analyze(t.allocator, src);
    defer a.deinit();
    // both `mymod` (as module) and `inner` (as define) should appear.
    var have_module = false;
    var have_inner = false;
    for (a.defines.items) |d| {
        if (d.kind == .module and std.mem.eql(u8, d.name, "mymod")) have_module = true;
        if (d.kind == .define and std.mem.eql(u8, d.name, "inner")) have_inner = true;
    }
    try t.expect(have_module);
    try t.expect(have_inner);
}

test "symbolAtOffset finds the right token" {
    const t = std.testing;
    const src = "(define foobar 1)";
    var a = try analyze(t.allocator, src);
    defer a.deinit();
    // offset 10 is inside "foobar"
    const hit = a.symbolAtOffset(src, 10).?;
    try t.expectEqualStrings("foobar", hit.text);
}
