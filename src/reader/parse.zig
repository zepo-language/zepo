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
    pub fn readOne(p: *Parser) !Value {
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
        return p.parseToken(tok);
    }

    /// Read every expression and return them as a proper list.
    pub fn readAll(p: *Parser) !Value {
        var scope = HandleScope{};
        p.gc.roots.pushHandleScope(&scope);
        defer p.gc.roots.popHandleScope();

        // Collect into a list built in reverse, then reverse at the end.
        const head_slot = scope.push(value_mod.NIL);

        while (true) {
            const tok = try p.lexer.next();
            if (tok.kind == .eof) break;
            const v = try p.parseToken(tok);
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
            .rparen => return p.setDiag(error.UnbalancedParen, tok.span),
            .dot => return p.setDiag(error.DotInvalid, tok.span),
            .quote => return p.parseQuote(tok),
            .quasiquote => return p.parseReaderAbbrev("quasiquote", tok),
            .unquote => return p.parseReaderAbbrev("unquote", tok),
            .unquote_splicing => return p.parseReaderAbbrev("unquote-splicing", tok),
            .boolean => return if (tok.bool_val) value_mod.TRUE else value_mod.FALSE,
            .integer => {
                const n = tok.int_val;
                // zepo-9usm: an integer literal wider than the fixnum range has
                // no exact representation (no bignum tower) — reject it rather
                // than silently wrap into a corrupted fixnum.
                if (!value_mod.fixnumFits(n)) {
                    return p.setDiag(error.OverflowInt, tok.span);
                }
                return value_mod.fixnum(@intCast(n));
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
