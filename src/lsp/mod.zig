//! Zepo Language Server Protocol — aggregate module.
//!
//! Implements an LSP over stdio JSON-RPC for Zepo Lisp:
//!  - initialize / shutdown / exit lifecycle
//!  - textDocument/{didOpen, didChange, didClose}
//!  - textDocument/hover            -> binding kind + :documentation docstring
//!  - textDocument/definition       -> same-file + cross-file goto-def
//!  - textDocument/completion       -> qualified-name completion after `.`
//!  - textDocument/references       -> scope-aware: locals limited to enclosing
//!                                     lambda body; globals span workspace
//!  - textDocument/{prepareRename, rename} -> WorkspaceEdit; refuses primitives
//!  - textDocument/documentSymbol   -> per-file outline
//!  - workspace/symbol              -> substring search across the workspace
//!  - textDocument/semanticTokens/full -> function/macro/variable/parameter/namespace
//!  - textDocument/formatting       -> uses src/format/mod.zig
//!  - textDocument/publishDiagnostics — reader/parser + linter rules
//!    (redefinition, unused-define, unused-import, dead-export, shadowing)
//!
//! Architecture: hybrid analyzer per docs/adr/0003 — real reader+ast pipeline
//! when the document parses cleanly, scanner-based fallback otherwise.
//! Analysis is cached per-URI (zepo-wwh7) and reused across hover/completion/
//! definition until the document version changes.
//!
//! Roadmap: bead zepo-893h.

pub const protocol = @import("protocol.zig");
pub const documents = @import("documents.zig");
pub const analysis = @import("analysis.zig");
pub const real_analysis = @import("real_analysis.zig"); // zepo-wh3e
pub const resolver = @import("resolver.zig");
pub const reader_check = @import("reader_check.zig");
pub const server = @import("server.zig");

pub const Server = server.Server;
pub const runStdio = server.runStdio;

test {
    _ = protocol;
    _ = documents;
    _ = analysis;
    _ = real_analysis; // zepo-wh3e
    _ = resolver;
    _ = reader_check;
    _ = server;
}
