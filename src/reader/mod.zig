//! Reader aggregate module.

pub const source = @import("source.zig");
pub const errors = @import("errors.zig");
pub const lex = @import("lex.zig");
pub const parse = @import("parse.zig");

pub const Lexer = lex.Lexer;
pub const Token = lex.Token;
pub const TokenKind = lex.TokenKind;
pub const Parser = parse.Parser;
pub const SpanTable = source.SpanTable;
pub const Span = source.Span;
pub const Pos = source.Pos;
pub const ReaderError = errors.ReaderError;
pub const ReaderDiag = errors.ReaderDiag;

test {
    _ = source;
    _ = errors;
    _ = lex;
    _ = parse;
}
