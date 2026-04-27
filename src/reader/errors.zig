//! Reader errors and diagnostics.

const std = @import("std");
const source = @import("source.zig");
const Span = source.Span;

pub const ReaderError = error{
    UnexpectedEof,
    UnexpectedChar,
    UnbalancedParen,
    InvalidEscape,
    InvalidCharName,
    InvalidNumber,
    DotInvalid,
    StringUnterminated,
    OverflowInt,
};

pub const ReaderDiag = struct {
    err: ReaderError,
    span: Span,
    msg: []const u8,
};
