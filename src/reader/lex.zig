//! Zepo tokenizer.

const std = @import("std");
const source = @import("source.zig");
const errors = @import("errors.zig");
const ReaderError = errors.ReaderError;
const Pos = source.Pos;
const Span = source.Span;

pub const TokenKind = enum {
    lparen,
    rparen,
    dot,
    quote,
    quasiquote,
    unquote,
    unquote_splicing,
    boolean,
    integer,
    float,
    string,
    character,
    symbol,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    span: Span,
    int_val: i64 = 0,
    float_val: f64 = 0,
    bool_val: bool = false,
    char_val: u21 = 0,
    /// For strings: a decoded-bytes slice owned by the Lexer's string_buf
    /// when the string contained escapes, or a sub-slice of `src` when raw.
    /// For symbols: sub-slice of `src`.
    payload: []const u8 = &.{},
};

pub const Lexer = struct {
    src: []const u8,
    pos: usize,
    line: u32,
    col: u32,
    file: []const u8,
    peeked: ?Token = null,
    /// Scratch buffer for decoded string escapes. Each successful string
    /// token appends onto this buffer and records its slice. The parser
    /// must copy before the next call to `next` if it needs the bytes to
    /// survive, but since we append (never shrink), earlier slices stay
    /// valid through the lexer's lifetime unless we reset.
    string_buf: std.ArrayListUnmanaged(u8) = .{},
    allocator: std.mem.Allocator,

    pub fn init(src: []const u8, file: []const u8, allocator: std.mem.Allocator) Lexer {
        return .{
            .src = src,
            .pos = 0,
            .line = 1,
            .col = 1,
            .file = file,
            .allocator = allocator,
        };
    }

    pub fn deinit(l: *Lexer) void {
        l.string_buf.deinit(l.allocator);
    }

    fn curPos(l: *const Lexer) Pos {
        return .{ .line = l.line, .col = l.col, .offset = @intCast(l.pos) };
    }

    fn atEnd(l: *const Lexer) bool {
        return l.pos >= l.src.len;
    }

    fn peekChar(l: *const Lexer) ?u8 {
        if (l.atEnd()) return null;
        return l.src[l.pos];
    }

    fn peekChar2(l: *const Lexer) ?u8 {
        if (l.pos + 1 >= l.src.len) return null;
        return l.src[l.pos + 1];
    }

    fn advance(l: *Lexer) u8 {
        const c = l.src[l.pos];
        l.pos += 1;
        if (c == '\n') {
            l.line += 1;
            l.col = 1;
        } else {
            l.col += 1;
        }
        return c;
    }

    fn skipWhitespaceAndComments(l: *Lexer) void {
        while (!l.atEnd()) {
            const c = l.src[l.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                _ = l.advance();
            } else if (c == ';') {
                while (!l.atEnd() and l.src[l.pos] != '\n') _ = l.advance();
            } else if (c == '#' and l.pos + 1 < l.src.len and l.src[l.pos + 1] == '|') {
                _ = l.advance(); // #
                _ = l.advance(); // |
                while (!l.atEnd()) {
                    if (l.src[l.pos] == '|' and l.pos + 1 < l.src.len and l.src[l.pos + 1] == '#') {
                        _ = l.advance(); // |
                        _ = l.advance(); // #
                        break;
                    }
                    _ = l.advance();
                }
            } else break;
        }
    }

    fn isDelimiter(c: u8) bool {
        return c == '(' or c == ')' or c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == ';' or c == '"' or c == '\'' or c == '`' or c == ',';
    }

    fn isSymbolStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '!' or c == '$' or c == '%' or c == '&' or
            c == '*' or c == '/' or c == ':' or c == '<' or c == '=' or c == '>' or
            c == '?' or c == '^' or c == '_' or c == '~';
    }

    fn isSymbolCont(c: u8) bool {
        return isSymbolStart(c) or std.ascii.isDigit(c) or c == '+' or c == '-' or c == '.' or c == '@';
    }

    pub fn peek(l: *Lexer) !Token {
        if (l.peeked) |t| return t;
        const t = try l.nextImpl();
        l.peeked = t;
        return t;
    }

    pub fn next(l: *Lexer) !Token {
        if (l.peeked) |t| {
            l.peeked = null;
            return t;
        }
        return l.nextImpl();
    }

    fn nextImpl(l: *Lexer) !Token {
        l.skipWhitespaceAndComments();
        const start_pos = l.curPos();
        const start_off = l.pos;

        if (l.atEnd()) {
            return .{
                .kind = .eof,
                .text = l.src[start_off..start_off],
                .span = .{ .start = start_pos, .end = start_pos, .file = l.file },
            };
        }

        const c = l.src[l.pos];
        switch (c) {
            '(' => {
                _ = l.advance();
                return l.mkTok(.lparen, start_off, start_pos);
            },
            ')' => {
                _ = l.advance();
                return l.mkTok(.rparen, start_off, start_pos);
            },
            '\'' => {
                _ = l.advance();
                return l.mkTok(.quote, start_off, start_pos);
            },
            '`' => {
                _ = l.advance();
                return l.mkTok(.quasiquote, start_off, start_pos);
            },
            ',' => {
                _ = l.advance();
                if (!l.atEnd() and l.src[l.pos] == '@') {
                    _ = l.advance();
                    return l.mkTok(.unquote_splicing, start_off, start_pos);
                }
                return l.mkTok(.unquote, start_off, start_pos);
            },
            '"' => return l.readString(start_off, start_pos),
            '#' => return l.readHash(start_off, start_pos),
            '+', '-' => {
                // Could be the standalone symbol '+' / '-' or sign of a number.
                const next_c = l.peekChar2();
                if (next_c == null or isDelimiter(next_c.?)) {
                    _ = l.advance();
                    return l.mkSymbolTok(start_off, start_pos);
                }
                if (std.ascii.isDigit(next_c.?) or next_c.? == '.') {
                    return l.readNumber(start_off, start_pos);
                }
                // Fall through to symbol (e.g. "->foo")
                return l.readSymbol(start_off, start_pos);
            },
            '.' => {
                const next_c = l.peekChar2();
                if (next_c == null or isDelimiter(next_c.?)) {
                    _ = l.advance();
                    return l.mkTok(.dot, start_off, start_pos);
                }
                if (std.ascii.isDigit(next_c.?)) {
                    return l.readNumber(start_off, start_pos);
                }
                // ...  or .foo => symbol
                return l.readSymbol(start_off, start_pos);
            },
            else => {
                if (std.ascii.isDigit(c)) return l.readNumber(start_off, start_pos);
                if (isSymbolStart(c)) return l.readSymbol(start_off, start_pos);
                return ReaderError.UnexpectedChar;
            },
        }
    }

    fn mkTok(l: *Lexer, kind: TokenKind, start_off: usize, start_pos: Pos) Token {
        const end_pos = l.curPos();
        return .{
            .kind = kind,
            .text = l.src[start_off..l.pos],
            .span = .{ .start = start_pos, .end = end_pos, .file = l.file },
        };
    }

    fn mkSymbolTok(l: *Lexer, start_off: usize, start_pos: Pos) Token {
        const end_pos = l.curPos();
        const text = l.src[start_off..l.pos];
        return .{
            .kind = .symbol,
            .text = text,
            .span = .{ .start = start_pos, .end = end_pos, .file = l.file },
            .payload = text,
        };
    }

    fn readSymbol(l: *Lexer, start_off: usize, start_pos: Pos) !Token {
        while (!l.atEnd()) {
            const c = l.src[l.pos];
            if (isSymbolCont(c)) {
                _ = l.advance();
            } else break;
        }
        return l.mkSymbolTok(start_off, start_pos);
    }

    fn readNumber(l: *Lexer, start_off: usize, start_pos: Pos) !Token {
        var is_float = false;
        // Optional sign
        if (l.src[l.pos] == '+' or l.src[l.pos] == '-') _ = l.advance();
        // Int part
        while (!l.atEnd() and std.ascii.isDigit(l.src[l.pos])) _ = l.advance();
        // Fraction
        if (!l.atEnd() and l.src[l.pos] == '.') {
            is_float = true;
            _ = l.advance();
            while (!l.atEnd() and std.ascii.isDigit(l.src[l.pos])) _ = l.advance();
        }
        // Exponent
        if (!l.atEnd() and (l.src[l.pos] == 'e' or l.src[l.pos] == 'E')) {
            is_float = true;
            _ = l.advance();
            if (!l.atEnd() and (l.src[l.pos] == '+' or l.src[l.pos] == '-')) _ = l.advance();
            if (l.atEnd() or !std.ascii.isDigit(l.src[l.pos])) return ReaderError.InvalidNumber;
            while (!l.atEnd() and std.ascii.isDigit(l.src[l.pos])) _ = l.advance();
        }

        const text = l.src[start_off..l.pos];
        const end_pos = l.curPos();

        // Must be followed by delimiter or EOF.
        if (!l.atEnd()) {
            const after = l.src[l.pos];
            if (!isDelimiter(after)) return ReaderError.InvalidNumber;
        }

        if (is_float) {
            const f = std.fmt.parseFloat(f64, text) catch return ReaderError.InvalidNumber;
            return .{
                .kind = .float,
                .text = text,
                .span = .{ .start = start_pos, .end = end_pos, .file = l.file },
                .float_val = f,
            };
        } else {
            const n = std.fmt.parseInt(i64, text, 10) catch return ReaderError.OverflowInt;
            return .{
                .kind = .integer,
                .text = text,
                .span = .{ .start = start_pos, .end = end_pos, .file = l.file },
                .int_val = n,
            };
        }
    }

    fn readString(l: *Lexer, start_off: usize, start_pos: Pos) !Token {
        _ = l.advance(); // opening "
        const buf_start = l.string_buf.items.len;
        while (true) {
            if (l.atEnd()) return ReaderError.StringUnterminated;
            const c = l.src[l.pos];
            if (c == '"') {
                _ = l.advance();
                break;
            } else if (c == '\\') {
                _ = l.advance();
                if (l.atEnd()) return ReaderError.StringUnterminated;
                const esc = l.src[l.pos];
                _ = l.advance();
                switch (esc) {
                    '"' => try l.string_buf.append(l.allocator, '"'),
                    '\\' => try l.string_buf.append(l.allocator, '\\'),
                    'n' => try l.string_buf.append(l.allocator, '\n'),
                    'r' => try l.string_buf.append(l.allocator, '\r'),
                    't' => try l.string_buf.append(l.allocator, '\t'),
                    '0' => try l.string_buf.append(l.allocator, 0),
                    'u' => {
                        // \uXXXX  (4 hex digits)
                        if (l.pos + 4 > l.src.len) return ReaderError.InvalidEscape;
                        const hex = l.src[l.pos .. l.pos + 4];
                        var i: usize = 0;
                        while (i < 4) : (i += 1) _ = l.advance();
                        const cp = std.fmt.parseInt(u21, hex, 16) catch return ReaderError.InvalidEscape;
                        var utf8_buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &utf8_buf) catch return ReaderError.InvalidEscape;
                        try l.string_buf.appendSlice(l.allocator, utf8_buf[0..n]);
                    },
                    else => return ReaderError.InvalidEscape,
                }
            } else {
                try l.string_buf.append(l.allocator, c);
                _ = l.advance();
            }
        }
        const end_pos = l.curPos();
        const payload = l.string_buf.items[buf_start..];
        return .{
            .kind = .string,
            .text = l.src[start_off..l.pos],
            .span = .{ .start = start_pos, .end = end_pos, .file = l.file },
            .payload = payload,
        };
    }

    fn readHash(l: *Lexer, start_off: usize, start_pos: Pos) !Token {
        _ = l.advance(); // #
        if (l.atEnd()) return ReaderError.UnexpectedEof;
        const c = l.src[l.pos];
        switch (c) {
            't' => {
                _ = l.advance();
                return .{
                    .kind = .boolean,
                    .text = l.src[start_off..l.pos],
                    .span = .{ .start = start_pos, .end = l.curPos(), .file = l.file },
                    .bool_val = true,
                };
            },
            'f' => {
                _ = l.advance();
                return .{
                    .kind = .boolean,
                    .text = l.src[start_off..l.pos],
                    .span = .{ .start = start_pos, .end = l.curPos(), .file = l.file },
                    .bool_val = false,
                };
            },
            '\\' => return l.readCharacter(start_off, start_pos),
            else => return ReaderError.UnexpectedChar,
        }
    }

    fn readCharacter(l: *Lexer, start_off: usize, start_pos: Pos) !Token {
        _ = l.advance(); // '\\'
        if (l.atEnd()) return ReaderError.UnexpectedEof;

        // Collect char name: first char always consumed; then while symbol-cont
        // (so "#\space" works; "#\a)" stops at ')').
        const name_start = l.pos;
        _ = l.advance();
        while (!l.atEnd()) {
            const c = l.src[l.pos];
            if (std.ascii.isAlphanumeric(c)) {
                _ = l.advance();
            } else break;
        }
        const name = l.src[name_start..l.pos];

        var cp: u21 = undefined;
        if (name.len == 1) {
            cp = name[0];
        } else if (std.mem.eql(u8, name, "space")) {
            cp = ' ';
        } else if (std.mem.eql(u8, name, "newline")) {
            cp = '\n';
        } else if (std.mem.eql(u8, name, "tab")) {
            cp = '\t';
        } else if (std.mem.eql(u8, name, "return")) {
            cp = '\r';
        } else if (name.len >= 2 and name[0] == 'u') {
            // uXXXX hex
            const hex = name[1..];
            if (hex.len == 0 or hex.len > 6) return ReaderError.InvalidCharName;
            cp = std.fmt.parseInt(u21, hex, 16) catch return ReaderError.InvalidCharName;
        } else {
            return ReaderError.InvalidCharName;
        }

        return .{
            .kind = .character,
            .text = l.src[start_off..l.pos],
            .span = .{ .start = start_pos, .end = l.curPos(), .file = l.file },
            .char_val = cp,
        };
    }
};
