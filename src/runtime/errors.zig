//! Error model for the Zepo runtime.
//!
//! Primitives and the VM return values of `LispError`. The `RuntimeError`
//! struct is a richer companion used when we want to attach a diagnostic
//! message and source span.

const std = @import("std");
const reader_source = @import("../reader/source.zig");
pub const Span = reader_source.Span;

pub const LispError = error{
    UnboundVariable,
    ArityMismatch,
    TypeError,
    InvalidForm,
    ReaderError,
    DivisionByZero,
    ContractViolation,
    StackOverflow,
    OutOfMemory,
    CarOfNonPair,
    CdrOfNonPair,
    NurseryOverflow,
    IOError,
    InvalidSpecialForm,
    ImportNameMustBeSymbol,
    UserError,
    UnknownKeyword,
    ModuleNotFound,
    ImportBeforeInitialization,
    ImportNameConflict,
    ImportNameNotExported,
    ExportNotDefined,
};

pub const RuntimeError = struct {
    kind: LispError,
    msg: []const u8,
    span: ?Span = null,
};

test "error enum exists" {
    const e: LispError = error.TypeError;
    try std.testing.expect(e == error.TypeError);
}
