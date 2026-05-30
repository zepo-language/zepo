//! Zepo Language Server Protocol — aggregate module.
//!
//! Implements a minimal LSP over stdio JSON-RPC for Zepo Lisp:
//!  - initialize / shutdown / exit lifecycle
//!  - textDocument/{didOpen, didChange, didClose}
//!  - textDocument/hover            -> symbol info + module origin (if imported)
//!  - textDocument/definition       -> goto-def within current file's
//!                                     (module ...) / (define ...) forms
//!  - textDocument/publishDiagnostics from the reader/parser
//!  - textDocument/completion       -> names after `<alias>.` qualifier
//!
//! See bead zepo-k9hh.

pub const protocol = @import("protocol.zig");
pub const documents = @import("documents.zig");
pub const analysis = @import("analysis.zig");
pub const resolver = @import("resolver.zig");
pub const reader_check = @import("reader_check.zig");
pub const server = @import("server.zig");

pub const Server = server.Server;
pub const runStdio = server.runStdio;

test {
    _ = protocol;
    _ = documents;
    _ = analysis;
    _ = resolver;
    _ = reader_check;
    _ = server;
}
