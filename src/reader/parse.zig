//! S-expression parser producing GC-allocated Values.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;
const HandleScope = gc_mod.HandleScope;

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const SymbolTable = runtime.SymbolTable;

const source = @import("source.zig");
const SpanTable = source.SpanTable;
const Span = source.Span;
const Pos = source.Pos;

const lex = @import("lex.zig");
const Lexer = lex.Lexer;
const Token = lex.Token;
const TokenKind = lex.TokenKind;

const errors = @import("errors.zig");
const ReaderError = errors.ReaderError;
const ReaderDiag = errors.ReaderDiag;

pub const EofError = error{Eof};

pub const Parser = struct {
    lexer: Lexer,
    gc: *GC,
    symbols: *SymbolTable,
    spans: *SpanTable,
    allocator: std.mem.Allocator,
    last_diag: ?ReaderDiag = null,
    // zepo-vhh6: datum-label table, scoped to one top-level datum. Each value is
    // an allocator-boxed Value slot registered in gc.roots.extra so the GC keeps
    // it live (and updates it on a move) across the nested reads that follow a
    // `#N=`. #N# reads the current slot value (a placeholder mid-read, the real
    // datum after). Cleared + un-rooted after each top-level datum.
    labels: std.AutoHashMapUnmanaged(u64, *Value) = .empty,

    pub fn init(
        gc: *GC,
        symbols: *SymbolTable,
        spans: *SpanTable,
        src: []const u8,
        file: []const u8,
        allocator: std.mem.Allocator,
    ) Parser {
        return .{
            .lexer = Lexer.init(src, file, allocator),
            .gc = gc,
            .symbols = symbols,
            .spans = spans,
            .allocator = allocator,
        };
    }

    pub fn deinit(p: *Parser) void {
        p.lexer.deinit();
        // zepo-vhh6: free any label boxes still around (clearLabels normally
        // empties this after each top-level datum; this is defensive).
        var it = p.labels.valueIterator();
        while (it.next()) |box| p.allocator.destroy(box.*);
        p.labels.deinit(p.allocator);
    }

    // zepo-vhh6: parse ONE top-level datum with a fresh datum-label scope. Labels
    // (#N=/#N#) are scoped to a single datum; this snapshots gc.roots.extra and
    // clears + un-roots the label table afterward.
    fn parseTopLevel(p: *Parser, tok: Token) anyerror!Value {
        const extra_base = p.gc.roots.extra.items.len;
        defer p.clearLabels(extra_base);
        return p.parseToken(tok);
    }

    fn setDiag(p: *Parser, err: ReaderError, span: Span) ReaderError {
        const msg: []const u8 = switch (err) {
            error.UnbalancedParen => "unbalanced parenthesis",
            error.DotInvalid => "invalid dot form",
            error.UnexpectedEof => "unexpected end of input",
            error.OverflowInt => "integer overflow",
            error.UnexpectedChar => "unexpected character",
            error.InvalidEscape => "invalid escape sequence",
            error.InvalidCharName => "invalid character name",
            error.InvalidNumber => "invalid number",
            error.StringUnterminated => "unterminated string",
        };
        p.last_diag = .{ .err = err, .span = span, .msg = msg };
        return err;
    }

    fn recordSpan(p: *Parser, v: Value, start: Pos, end: Pos) !void {
        try p.spans.record(v, .{ .start = start, .end = end, .file = p.lexer.file });
    }

    /// Read a single expression. Returns error.Eof when the input is
    /// exhausted (no more non-whitespace tokens).
    // zepo-aqwc: `#;` comments out the FULL datum that follows. Discard any run
    // of them wherever a datum is about to be read.
    fn skipDatumComments(p: *Parser) anyerror!void {
        while ((try p.lexer.peek()).kind == .datum_comment) {
            _ = try p.lexer.next(); // consume `#;`
            try p.discardDatum();
        }
    }

    fn discardDatum(p: *Parser) anyerror!void {
        try p.skipDatumComments(); // handles `#;#;a b`
        const tok = try p.lexer.next();
        if (tok.kind == .eof) return p.setDiag(error.UnexpectedEof, tok.span);
        _ = try p.parseTopLevel(tok); // fully parse (and discard) one datum (zepo-vhh6)
    }

    pub fn readOne(p: *Parser) !Value {
        try p.skipDatumComments(); // top-level leading `#;` datums
        const tok = p.lexer.next() catch |e| {
            const here = Span{
                .start = .{ .line = p.lexer.line, .col = p.lexer.col, .offset = @intCast(p.lexer.pos) },
                .end = .{ .line = p.lexer.line, .col = p.lexer.col, .offset = @intCast(p.lexer.pos) },
                .file = p.lexer.file,
            };
            const re: ReaderError = switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnexpectedChar => error.UnexpectedChar,
                error.InvalidEscape => error.InvalidEscape,
                error.InvalidCharName => error.InvalidCharName,
                error.InvalidNumber => error.InvalidNumber,
                error.StringUnterminated => error.StringUnterminated,
                error.OverflowInt => error.OverflowInt,
                error.UnexpectedEof => error.UnexpectedEof,
                error.UnbalancedParen => error.UnbalancedParen,
                error.DotInvalid => error.DotInvalid,
            };
            return p.setDiag(re, here);
        };
        if (tok.kind == .eof) return EofError.Eof;
        return p.parseTopLevel(tok);
    }

    /// Read every expression and return them as a proper list.
    pub fn readAll(p: *Parser) !Value {
        var scope = HandleScope{};
        p.gc.roots.pushHandleScope(&scope);
        defer p.gc.roots.popHandleScope();

        // Collect into a list built in reverse, then reverse at the end.
        const head_slot = scope.push(value_mod.NIL);

        while (true) {
            try p.skipDatumComments(); // zepo-aqwc
            const tok = try p.lexer.next();
            if (tok.kind == .eof) break;
            const v = try p.parseTopLevel(tok);
            const v_slot = scope.push(v);
            head_slot.* = try objects.makePairFromSlots(p.gc, v_slot, head_slot);
        }

        // Reverse — use rooted slots so a GC inside makePairFromSlots cannot
        // invalidate the traversal pointer or the accumulator.
        const result_slot = scope.push(value_mod.NIL);
        const cur_slot = scope.push(head_slot.*);
        const car_slot = scope.push(value_mod.NIL);
        while (!value_mod.isNil(cur_slot.*)) {
            car_slot.* = objects.pairCar(cur_slot.*).*;
            cur_slot.* = objects.pairCdr(cur_slot.*).*;
            result_slot.* = try objects.makePairFromSlots(p.gc, car_slot, result_slot);
        }
        return result_slot.*;
    }

    fn parseToken(p: *Parser, tok: Token) anyerror!Value {
        switch (tok.kind) {
            .lparen => return p.parseList(tok),
            .vector_open => return p.parseVector(tok), // zepo-aqwc
            .bytevector_open => return p.parseBytevector(tok), // zepo-vhh6
            .datum_label_def => return p.parseLabelDef(tok), // zepo-vhh6
            .datum_label_ref => { // zepo-vhh6
                const box = p.labels.get(@intCast(tok.int_val)) orelse
                    return p.setDiag(error.InvalidNumber, tok.span); // undefined label
                return box.*;
            },
            // zepo-aqwc: `#;` in a datum position (e.g. `'#;a b`, top level) —
            // discard the commented datum and parse the next real one.
            .datum_comment => {
                try p.discardDatum();
                try p.skipDatumComments();
                const next_tok = try p.lexer.next();
                if (next_tok.kind == .eof) return p.setDiag(error.UnexpectedEof, next_tok.span);
                return p.parseToken(next_tok);
            },
            .rparen => return p.setDiag(error.UnbalancedParen, tok.span),
            .dot => return p.setDiag(error.DotInvalid, tok.span),
            .quote => return p.parseQuote(tok),
            .quasiquote => return p.parseReaderAbbrev("quasiquote", tok),
            .unquote => return p.parseReaderAbbrev("unquote", tok),
            .unquote_splicing => return p.parseReaderAbbrev("unquote-splicing", tok),
            .boolean => return if (tok.bool_val) value_mod.TRUE else value_mod.FALSE,
            .integer => {
                // zepo-nfak: a literal outside the fixnum range (either wider
                // than i64, flagged by the lexer, or in [2^60, 2^63)) is an
                // exact bignum, parsed from the source text.
                if (tok.int_overflow or !value_mod.fixnumFits(tok.int_val)) {
                    const v = runtime.bignum.fromDecimal(p.gc, tok.text) catch |e| switch (e) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return p.setDiag(error.InvalidNumber, tok.span),
                    };
                    try p.recordSpan(v, tok.span.start, tok.span.end);
                    return v;
                }
                return value_mod.fixnum(@intCast(tok.int_val));
            },
            .ratio => {
                // zepo-or1d: `num/den` rational literal. Parse each part as an
                // exact integer, then reduce via ratio.make (a denominator of 0
                // is an invalid literal; a reducible ratio may become an integer).
                const slash = std.mem.indexOfScalar(u8, tok.text, '/').?;
                const num_v = runtime.bignum.fromDecimal(p.gc, tok.text[0..slash]) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return p.setDiag(error.InvalidNumber, tok.span),
                };
                var scope = HandleScope{};
                p.gc.roots.pushHandleScope(&scope);
                defer p.gc.roots.popHandleScope();
                const num_slot = scope.push(num_v);
                const den_v = runtime.bignum.fromDecimal(p.gc, tok.text[slash + 1 ..]) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return p.setDiag(error.InvalidNumber, tok.span),
                };
                const v = runtime.ratio.make(p.gc, num_slot.*, den_v) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return p.setDiag(error.InvalidNumber, tok.span), // e.g. den 0
                };
                try p.recordSpan(v, tok.span.start, tok.span.end);
                return v;
            },
            .exact_decimal => {
                // zepo-or1d: `#e<decimal>` — the exact rational value of the
                // decimal as written (e.g. #e0.1 => 1/10).
                const v = runtime.ratio.fromDecimalExact(p.gc, tok.text) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return p.setDiag(error.InvalidNumber, tok.span),
                };
                try p.recordSpan(v, tok.span.start, tok.span.end);
                return v;
            },
            .float => {
                const v = try objects.makeFloat(p.gc, tok.float_val);
                try p.recordSpan(v, tok.span.start, tok.span.end);
                return v;
            },
            .string => {
                const v = try objects.makeString(p.gc, tok.payload);
                try p.recordSpan(v, tok.span.start, tok.span.end);
                return v;
            },
            .character => return value_mod.char(tok.char_val),
            .symbol => {
                const v = try p.symbols.intern(tok.payload);
                // Do NOT record span on interned symbol — they're shared.
                return v;
            },
            .eof => return EofError.Eof,
        }
    }

    fn parseReaderAbbrev(p: *Parser, sym_name: []const u8, tok: Token) anyerror!Value {
        var scope = HandleScope{};
        p.gc.roots.pushHandleScope(&scope);
        defer p.gc.roots.popHandleScope();

        const sym = try p.symbols.intern(sym_name);
        const sym_slot = scope.push(sym);

        const inner_tok = try p.lexer.next();
        if (inner_tok.kind == .eof) return p.setDiag(error.UnexpectedEof, inner_tok.span);
        const inner = try p.parseToken(inner_tok);
        const inner_slot = scope.push(inner);

        const nil_slot = scope.push(value_mod.NIL);
        const inner_cons_slot = scope.push(try objects.makePairFromSlots(p.gc, inner_slot, nil_slot));
        const result = try objects.makePairFromSlots(p.gc, sym_slot, inner_cons_slot);
        try p.recordSpan(result, tok.span.start, tok.span.end);
        return result;
    }

    fn parseQuote(p: *Parser, quote_tok: Token) anyerror!Value {
        var scope = HandleScope{};
        p.gc.roots.pushHandleScope(&scope);
        defer p.gc.roots.popHandleScope();

        const quote_sym = try p.symbols.intern("quote");
        const quote_slot = scope.push(quote_sym);

        const inner_tok = try p.lexer.next();
        if (inner_tok.kind == .eof) return p.setDiag(error.UnexpectedEof, inner_tok.span);
        const inner = try p.parseToken(inner_tok);
        const inner_slot = scope.push(inner);

        // Build (quote inner) = (cons quote (cons inner NIL))
        const nil_slot = scope.push(value_mod.NIL);
        const inner_cons_slot = scope.push(try objects.makePairFromSlots(p.gc, inner_slot, nil_slot));
        const result = try objects.makePairFromSlots(p.gc, quote_slot, inner_cons_slot);
        try p.recordSpan(result, quote_tok.span.start, quote_tok.span.end);
        return result;
    }

    // zepo-aqwc: `#( datum ... )` → a vector Value. Elements are collected into
    // a rooted reversed cons list (GC-safe: each parseToken may allocate), then
    // copied into a freshly-allocated vector. The vector self-quotes in the AST
    // builder, so its elements are data, not evaluated.
    fn parseVector(p: *Parser, open_tok: Token) anyerror!Value {
        var scope = HandleScope{};
        p.gc.roots.pushHandleScope(&scope);
        defer p.gc.roots.popHandleScope();

        const reversed_slot = scope.push(value_mod.NIL);
        const v_slot = scope.push(value_mod.NIL);
        var count: usize = 0;
        while (true) {
            try p.skipDatumComments(); // zepo-aqwc
            const tok = try p.lexer.peek();
            if (tok.kind == .eof) return p.setDiag(error.UnbalancedParen, tok.span);
            if (tok.kind == .rparen) {
                _ = try p.lexer.next();
                break;
            }
            // A vector has no dotted tail; `.` is not special inside it.
            const next_tok = try p.lexer.next();
            v_slot.* = try p.parseToken(next_tok);
            reversed_slot.* = try objects.makePairFromSlots(p.gc, v_slot, reversed_slot);
            count += 1;
        }

        const vec_slot = scope.push(try objects.makeVector(p.gc, count, value_mod.NIL));
        // reversed list is last-to-first; walk it filling indices high→low. No
        // allocation here, so the reversed-list Values stay stable.
        var i: usize = count;
        var cur = reversed_slot.*;
        while (objects.isPair(cur)) {
            i -= 1;
            objects.vectorSet(p.gc, vec_slot.*, i, objects.pairCar(cur).*);
            cur = objects.pairCdr(cur).*;
        }
        try p.recordSpan(vec_slot.*, open_tok.span.start, open_tok.span.end);
        return vec_slot.*;
    }

    // zepo-vhh6: `#u8( byte ... )` — a bytevector literal. Each element must be
    // an exact integer in 0..255. Bytes are collected in a host buffer (no GC
    // roots needed), then one makeBytevector fills them.
    fn parseBytevector(p: *Parser, open_tok: Token) anyerror!Value {
        var bytes = std.ArrayListUnmanaged(u8).empty;
        defer bytes.deinit(p.allocator);
        while (true) {
            try p.skipDatumComments();
            const tok = try p.lexer.peek();
            if (tok.kind == .eof) return p.setDiag(error.UnbalancedParen, tok.span);
            if (tok.kind == .rparen) {
                _ = try p.lexer.next();
                break;
            }
            const next_tok = try p.lexer.next();
            const v = try p.parseToken(next_tok);
            if (!value_mod.isFixnum(v)) return p.setDiag(error.InvalidNumber, next_tok.span);
            const n = value_mod.fixnumVal(v);
            if (n < 0 or n > 255) return p.setDiag(error.InvalidNumber, next_tok.span);
            bytes.append(p.allocator, @intCast(n)) catch return error.OutOfMemory;
        }
        const bv = try objects.makeBytevector(p.gc, bytes.items.len, 0);
        if (bytes.items.len > 0) @memcpy(objects.bytevectorBytes(bv)[0..bytes.items.len], bytes.items);
        try p.recordSpan(bv, open_tok.span.start, open_tok.span.end);
        return bv;
    }

    // zepo-vhh6: `#N= <datum>` binds label N to the datum, allowing `#N#` back-
    // references (including cyclic ones, e.g. `#0=(a . #0#)`). A placeholder is
    // registered for N first; after the datum is read its self-references (which
    // read the placeholder) are patched to the datum, tying the knot via mutable
    // pairs/vectors (zepo-asu1).
    fn parseLabelDef(p: *Parser, tok: Token) anyerror!Value {
        const label: u64 = @intCast(tok.int_val);
        if (p.labels.contains(label)) return p.setDiag(error.InvalidNumber, tok.span); // duplicate

        // Box a placeholder slot and root it (GC may move it during the read).
        const box = p.allocator.create(Value) catch return error.OutOfMemory;
        box.* = value_mod.NIL; // placeholder is the box's identity; NIL is fine
        // A unique placeholder object so self-references are recognizable when
        // patching. A fresh pair is pointer-unique; store it in the box.
        box.* = objects.makePair(p.gc, value_mod.NIL, value_mod.NIL) catch |e| {
            p.allocator.destroy(box);
            return e;
        };
        const placeholder = box.*;
        p.labels.put(p.allocator, label, box) catch {
            p.allocator.destroy(box);
            return error.OutOfMemory;
        };
        p.gc.roots.extra.append(p.allocator, box) catch return error.OutOfMemory;

        // Read the labelled datum. #N# encountered inside returns the placeholder.
        const inner_tok = try p.lexer.next();
        if (inner_tok.kind == .eof) return p.setDiag(error.UnexpectedEof, inner_tok.span);
        const datum = try p.parseToken(inner_tok);

        // The box now names the real datum, so later #N# siblings share it.
        box.* = datum;
        // Tie any self-references: replace the placeholder inside `datum`.
        if (datum != placeholder) {
            var seen: std.AutoHashMapUnmanaged(Value, void) = .empty;
            defer seen.deinit(p.allocator);
            try p.patchLabel(datum, placeholder, datum, &seen);
        }
        return datum;
    }

    // Replace every occurrence of `placeholder` reachable from `node` with
    // `datum` (in mutable pair/vector slots), tying a self-referential label.
    // `seen` bounds the walk over shared/already-cyclic sub-structure.
    fn patchLabel(p: *Parser, node: Value, placeholder: Value, datum: Value, seen: *std.AutoHashMapUnmanaged(Value, void)) anyerror!void {
        if (!value_mod.isPtr(node)) return;
        if (objects.isPair(node)) {
            if (seen.contains(node)) return;
            seen.put(p.allocator, node, {}) catch return error.OutOfMemory;
            const car = objects.pairCar(node).*;
            if (car == placeholder) {
                objects.pairSetCar(p.gc, node, datum);
            } else try p.patchLabel(car, placeholder, datum, seen);
            const cdr = objects.pairCdr(node).*;
            if (cdr == placeholder) {
                objects.pairSetCdr(p.gc, node, datum);
            } else try p.patchLabel(cdr, placeholder, datum, seen);
        } else if (objects.isVector(node)) {
            if (seen.contains(node)) return;
            seen.put(p.allocator, node, {}) catch return error.OutOfMemory;
            const len = objects.vectorLen(node);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const el = objects.vectorGet(node, i);
                if (el == placeholder) {
                    objects.vectorSet(p.gc, node, i, datum);
                } else try p.patchLabel(el, placeholder, datum, seen);
            }
        }
    }

    // Clear the datum-label table and un-root its boxes, back to `extra_base`.
    fn clearLabels(p: *Parser, extra_base: usize) void {
        var it = p.labels.valueIterator();
        while (it.next()) |box| p.allocator.destroy(box.*);
        p.labels.clearRetainingCapacity();
        p.gc.roots.extra.shrinkRetainingCapacity(extra_base);
    }

    fn parseList(p: *Parser, open_tok: Token) anyerror!Value {
        var scope = HandleScope{};
        p.gc.roots.pushHandleScope(&scope);
        defer p.gc.roots.popHandleScope();

        // Three stable slots — never more, regardless of list length.
        // After each element is consed into reversed_slot, the element is
        // reachable through that pair; v_slot can be reused next iteration.
        const reversed_slot = scope.push(value_mod.NIL);
        const tail_slot = scope.push(value_mod.NIL);
        const v_slot = scope.push(value_mod.NIL);
        var has_tail = false;

        // zepo-ri9g: track the close-paren's end offset so the recorded
        // pair span covers the WHOLE form, not just the open paren.
        var close_end_pos = open_tok.span.end;
        while (true) {
            try p.skipDatumComments(); // zepo-aqwc
            const tok = try p.lexer.peek();
            if (tok.kind == .eof) return p.setDiag(error.UnbalancedParen, tok.span);
            if (tok.kind == .rparen) {
                const rp = try p.lexer.next();
                close_end_pos = rp.span.end;
                break;
            }
            if (tok.kind == .dot) {
                const dot_tok = try p.lexer.next();
                // Must have read at least one element, and must read exactly one more.
                if (value_mod.isNil(reversed_slot.*)) return p.setDiag(error.DotInvalid, dot_tok.span);
                const after_tok = try p.lexer.next();
                if (after_tok.kind == .eof) return p.setDiag(error.UnexpectedEof, after_tok.span);
                if (after_tok.kind == .rparen) return p.setDiag(error.DotInvalid, after_tok.span);
                v_slot.* = try p.parseToken(after_tok);
                tail_slot.* = v_slot.*;
                has_tail = true;
                const closing = try p.lexer.next();
                if (closing.kind != .rparen) return p.setDiag(error.DotInvalid, closing.span);
                close_end_pos = closing.span.end;
                break;
            }
            const next_tok = try p.lexer.next();
            v_slot.* = try p.parseToken(next_tok);
            reversed_slot.* = try objects.makePairFromSlots(p.gc, v_slot, reversed_slot);
        }

        // Build the final list in correct order — rooted slots guard against
        // a GC triggered inside makePairFromSlots invalidating the traversal.
        const result_slot = scope.push(if (has_tail) tail_slot.* else value_mod.NIL);
        const cur_slot = scope.push(reversed_slot.*);
        const car_slot = scope.push(value_mod.NIL);
        while (!value_mod.isNil(cur_slot.*)) {
            car_slot.* = objects.pairCar(cur_slot.*).*;
            cur_slot.* = objects.pairCdr(cur_slot.*).*;
            result_slot.* = try objects.makePairFromSlots(p.gc, car_slot, result_slot);
        }
        const result = result_slot.*;

        // An empty list () must return NIL, not a freshly allocated pair.
        if (value_mod.isNil(result)) return value_mod.NIL;

        try p.recordSpan(result, open_tok.span.start, close_end_pos);
        return result;
    }
};
