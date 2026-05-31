//! Zepo LSP server — wires stdio JSON-RPC to handlers.
//!
//! Methods handled:
//!   initialize, initialized, shutdown, exit
//!   textDocument/didOpen, didChange, didClose
//!   textDocument/hover, definition, completion
//!
//! Diagnostics are computed and published on didOpen/didChange via the
//! existing reader-based `lsp_cmd.checkDocument` helper, which surfaces
//! lex/parse errors with accurate spans.
//!
//! See bead zepo-k9hh.

const std = @import("std");
const proto = @import("protocol.zig");
const docs_mod = @import("documents.zig");
const analysis = @import("analysis.zig");
const resolver_mod = @import("resolver.zig");
const reader_check = @import("reader_check.zig");

// zepo-wwh7: per-document cached Analysis. Keyed by URI; the version field
// is the doc.version this Analysis was computed against. A mismatch on read
// means the cache is stale and must be deinit'd before re-analyzing.
pub const CacheEntry = struct {
    version: i64,
    analysis: analysis.Analysis,
    /// Tracks the (already-freed by the time we look at it) text pointer
    /// that backed the slices in `analysis`. Never dereferenced; only used
    /// to assert in debug builds that we never read stale slices.
    text_ptr: usize,
};

pub const Server = struct {
    alloc: std.mem.Allocator,
    store: docs_mod.Store,
    resolver: resolver_mod.Resolver,
    reader: proto.Reader,
    writer: proto.Writer,
    shutdown_received: bool = false,
    /// Negotiated PositionEncoding. Defaults to LSP spec default (utf-16).
    /// Updated on `initialize` based on client capabilities.
    encoding: analysis.PositionEncoding = .utf16,
    /// zepo-wwh7: cache of per-URI Analysis results.
    analysis_cache: std.StringHashMapUnmanaged(CacheEntry) = .empty,

    pub fn init(alloc: std.mem.Allocator, reader: proto.Reader, writer: proto.Writer) Server {
        return .{
            .alloc = alloc,
            .store = docs_mod.Store.init(alloc),
            .resolver = resolver_mod.Resolver.init(alloc),
            .reader = reader,
            .writer = writer,
        };
    }

    pub fn deinit(s: *Server) void {
        // zepo-wwh7: free cached analyses + the URI keys we duped.
        var it = s.analysis_cache.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.analysis.deinit();
            s.alloc.free(entry.key_ptr.*);
        }
        s.analysis_cache.deinit(s.alloc);
        s.store.deinit();
        s.resolver.deinit();
    }

    // zepo-wwh7: return a borrowed analysis for `uri`, reusing the cached
    // entry when the document version matches. Caller must NOT deinit the
    // returned value — the cache owns it. Caller must NOT retain the pointer
    // across calls that may mutate the document.
    fn getCachedAnalysis(s: *Server, uri: []const u8) !*const analysis.Analysis {
        const doc = s.store.get(uri) orelse return error.UnknownDocument;
        if (s.analysis_cache.getPtr(uri)) |entry| {
            if (entry.version == doc.version and entry.text_ptr == @intFromPtr(doc.text.ptr)) {
                return &entry.analysis;
            }
            // Stale: free the old analysis (its slices may point into a
            // since-freed buffer; we never read them once the version differs)
            // before re-analyzing.
            entry.analysis.deinit();
            entry.analysis = try analysis.analyze(s.alloc, doc.text);
            entry.version = doc.version;
            entry.text_ptr = @intFromPtr(doc.text.ptr);
            return &entry.analysis;
        }
        // First analysis of this URI: dupe the key, insert.
        const a = try analysis.analyze(s.alloc, doc.text);
        const key = try s.alloc.dupe(u8, uri);
        errdefer s.alloc.free(key);
        try s.analysis_cache.put(s.alloc, key, .{
            .version = doc.version,
            .analysis = a,
            .text_ptr = @intFromPtr(doc.text.ptr),
        });
        return &s.analysis_cache.getPtr(key).?.analysis;
    }

    // zepo-wwh7: drop the cached analysis for `uri` (called on close).
    fn dropCachedAnalysis(s: *Server, uri: []const u8) void {
        if (s.analysis_cache.fetchRemove(uri)) |kv| {
            var ent = kv.value;
            ent.analysis.deinit();
            s.alloc.free(kv.key);
        }
    }

    pub fn run(s: *Server) !void {
        while (true) {
            const body = proto.readMessage(s.alloc, s.reader) catch |e| switch (e) {
                error.EndOfStream => return,
                else => return e,
            };
            defer s.alloc.free(body);
            const should_exit = try s.handle(body);
            if (should_exit) return;
        }
    }

    fn handle(s: *Server, body: []const u8) !bool {
        var parsed = std.json.parseFromSlice(std.json.Value, s.alloc, body, .{}) catch return false;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return false,
        };

        const method = switch (obj.get("method") orelse return false) {
            .string => |sv| sv,
            else => return false,
        };

        if (std.mem.eql(u8, method, "initialize")) {
            const id = obj.get("id") orelse std.json.Value{ .null = {} };
            // Negotiate positionEncoding per LSP 3.17 (zepo-pewz).
            // Prefer utf-8 if the client lists it under
            //   clientCapabilities.general.positionEncodings.
            s.encoding = .utf16; // spec default
            if (obj.get("params")) |pv| switch (pv) {
                .object => |po| {
                    if (po.get("capabilities")) |cv| switch (cv) {
                        .object => |co| {
                            if (co.get("general")) |gv| switch (gv) {
                                .object => |go| {
                                    if (go.get("positionEncodings")) |ev| switch (ev) {
                                        .array => |arr| {
                                            for (arr.items) |item| switch (item) {
                                                .string => |sv| {
                                                    if (std.mem.eql(u8, sv, "utf-8")) {
                                                        s.encoding = .utf8;
                                                        break;
                                                    }
                                                },
                                                else => {},
                                            };
                                        },
                                        else => {},
                                    };
                                },
                                else => {},
                            };
                        },
                        else => {},
                    };
                },
                else => {},
            };

            const enc_str: []const u8 = switch (s.encoding) {
                .utf8 => "utf-8",
                .utf16 => "utf-16",
                .utf32 => "utf-32",
            };
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(s.alloc);
            try out.appendSlice(s.alloc, "{\"capabilities\":{\"positionEncoding\":\"");
            try out.appendSlice(s.alloc, enc_str);
            // zepo-ttk8: textDocumentSync.change = 2 (Incremental). We still
            // accept full-text changes (clients may send either based on
            // their own preference).
            // zepo-70qf + zepo-41a2: advertise documentSymbol +
            // workspaceSymbol, references, and rename (with prepareProvider).
            try out.appendSlice(s.alloc, "\",\"textDocumentSync\":{\"openClose\":true,\"change\":2},\"hoverProvider\":true,\"definitionProvider\":true,\"documentSymbolProvider\":true,\"workspaceSymbolProvider\":true,\"referencesProvider\":true,\"renameProvider\":{\"prepareProvider\":true},\"completionProvider\":{\"triggerCharacters\":[\".\"]}},\"serverInfo\":{\"name\":\"zepo-lsp\",\"version\":\"0.1.0\"}}");
            try s.sendResult(id, out.items);
            return false;
        }
        if (std.mem.eql(u8, method, "initialized")) return false;
        if (std.mem.eql(u8, method, "shutdown")) {
            s.shutdown_received = true;
            const id = obj.get("id") orelse std.json.Value{ .null = {} };
            try s.sendResult(id, "null");
            return false;
        }
        if (std.mem.eql(u8, method, "exit")) return true;

        const params = switch (obj.get("params") orelse return false) {
            .object => |o| o,
            else => return false,
        };

        if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            return try s.onDidOpen(params);
        }
        if (std.mem.eql(u8, method, "textDocument/didChange")) {
            return try s.onDidChange(params);
        }
        if (std.mem.eql(u8, method, "textDocument/didClose")) {
            return try s.onDidClose(params);
        }
        if (std.mem.eql(u8, method, "textDocument/hover")) {
            const id = obj.get("id") orelse std.json.Value{ .null = {} };
            return try s.onHover(id, params);
        }
        if (std.mem.eql(u8, method, "textDocument/definition")) {
            const id = obj.get("id") orelse std.json.Value{ .null = {} };
            return try s.onDefinition(id, params);
        }
        if (std.mem.eql(u8, method, "textDocument/completion")) {
            const id = obj.get("id") orelse std.json.Value{ .null = {} };
            return try s.onCompletion(id, params);
        }
        // zepo-70qf
        if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            const id = obj.get("id") orelse std.json.Value{ .null = {} };
            return try s.onDocumentSymbol(id, params);
        }
        if (std.mem.eql(u8, method, "workspace/symbol")) {
            const id = obj.get("id") orelse std.json.Value{ .null = {} };
            return try s.onWorkspaceSymbol(id, params);
        }
        // zepo-41a2
        if (std.mem.eql(u8, method, "textDocument/references")) {
            const id = obj.get("id") orelse std.json.Value{ .null = {} };
            return try s.onReferences(id, params);
        }
        if (std.mem.eql(u8, method, "textDocument/prepareRename")) {
            const id = obj.get("id") orelse std.json.Value{ .null = {} };
            return try s.onPrepareRename(id, params);
        }
        if (std.mem.eql(u8, method, "textDocument/rename")) {
            const id = obj.get("id") orelse std.json.Value{ .null = {} };
            return try s.onRename(id, params);
        }

        // Respond to unknown requests so clients don't hang.
        if (obj.get("id")) |id| {
            try s.sendResult(id, "null");
        }
        return false;
    }

    // -- Document sync ------------------------------------------------------

    fn onDidOpen(s: *Server, params: std.json.ObjectMap) !bool {
        const td = getObject(params, "textDocument") orelse return false;
        const uri = getString(td, "uri") orelse return false;
        const text = getString(td, "text") orelse return false;
        const version: i64 = if (td.get("version")) |v| switch (v) {
            .integer => |n| n,
            else => 0,
        } else 0;
        try s.store.open(uri, text, version);
        try s.publishDiagnostics(uri);
        return false;
    }

    fn onDidChange(s: *Server, params: std.json.ObjectMap) !bool {
        const td = getObject(params, "textDocument") orelse return false;
        const uri = getString(td, "uri") orelse return false;
        const version: i64 = if (td.get("version")) |v| switch (v) {
            .integer => |n| n,
            else => 0,
        } else 0;
        const changes = switch (params.get("contentChanges") orelse return false) {
            .array => |arr| arr,
            else => return false,
        };
        if (changes.items.len == 0) return false;

        // zepo-ttk8: apply each contentChange in order. Each one is either:
        //   { range: {start, end}, text }   — incremental edit
        //   { text }                         — full replacement
        // We advertise change kind 2 (Incremental) but accept either; some
        // clients still send full-text for simplicity.
        for (changes.items) |change| {
            const obj = switch (change) {
                .object => |o| o,
                else => continue,
            };
            const text = getString(obj, "text") orelse continue;
            if (getObject(obj, "range")) |range_obj| {
                const doc = s.store.get(uri) orelse return false;
                const start_pos = parseRangePos(range_obj, "start") orelse continue;
                const end_pos = parseRangePos(range_obj, "end") orelse continue;
                const start_off = analysis.posToOffsetEnc(doc.text, start_pos, s.encoding);
                const end_off = analysis.posToOffsetEnc(doc.text, end_pos, s.encoding);
                s.store.applyEdit(uri, start_off, end_off, text, version) catch {
                    // On malformed range, fall through to full replacement so
                    // we recover instead of leaving the document inconsistent.
                    try s.store.replace(uri, text, version);
                };
            } else {
                try s.store.replace(uri, text, version);
            }
        }
        try s.publishDiagnostics(uri);
        return false;
    }

    fn parseRangePos(range_obj: std.json.ObjectMap, key: []const u8) ?analysis.Pos {
        const pos_obj = switch (range_obj.get(key) orelse return null) {
            .object => |o| o,
            else => return null,
        };
        const line = switch (pos_obj.get("line") orelse return null) {
            .integer => |n| if (n < 0) return null else @as(u32, @intCast(n)),
            else => return null,
        };
        const character = switch (pos_obj.get("character") orelse return null) {
            .integer => |n| if (n < 0) return null else @as(u32, @intCast(n)),
            else => return null,
        };
        return .{ .line = line, .character = character };
    }

    fn onDidClose(s: *Server, params: std.json.ObjectMap) !bool {
        const td = getObject(params, "textDocument") orelse return false;
        const uri = getString(td, "uri") orelse return false;
        s.dropCachedAnalysis(uri); // zepo-wwh7
        s.store.close(uri);
        return false;
    }

    // -- Hover --------------------------------------------------------------

    fn onHover(s: *Server, id: std.json.Value, params: std.json.ObjectMap) !bool {
        const td = getObject(params, "textDocument") orelse return s.sendNullResult(id);
        const uri = getString(td, "uri") orelse return s.sendNullResult(id);
        const pos = getPos(params) orelse return s.sendNullResult(id);
        const doc = s.store.get(uri) orelse return s.sendNullResult(id);

        // zepo-wwh7: borrow the cached analysis instead of re-analyzing.
        const a = try s.getCachedAnalysis(uri);

        const off = analysis.posToOffsetEnc(doc.text, pos, s.encoding);
        const sym = a.symbolAtOffset(doc.text, off) orelse return s.sendNullResult(id);

        // Build a hover message describing the symbol.
        var msg: std.ArrayListUnmanaged(u8) = .empty;
        defer msg.deinit(s.alloc);
        try msg.appendSlice(s.alloc, "**");
        try msg.appendSlice(s.alloc, sym.text);
        try msg.appendSlice(s.alloc, "**");

        // zepo-wh3e + zepo-ri9g: surface the binding kind under the name
        // when real-pipeline analysis is available. Prefer per-occurrence
        // kind (from ri9g) so locals and captures aren't reported as
        // global_value, falling back to the name-level kindOf table.
        if (sym.dot_at == null) {
            if (a.real) |*ra| {
                const sym_off_start: u32 = @intCast(analysis.posToOffsetEnc(doc.text, sym.range.start, s.encoding));
                const eff_kind = ra.classifyAt(sym.text, sym_off_start);
                if (eff_kind) |kind| {
                    const kind_str: []const u8 = switch (kind) {
                        .primitive => " *(primitive)*",
                        .macro => " *(macro)*",
                        .module => " *(module)*",
                        .global_proc => " *(procedure)*",
                        .global_value => " *(value)*",
                        .local_macro => " *(macro)*",
                        .local => " *(local)*",
                        .captured => " *(captured)*",
                        .global => " *(global)*",
                    };
                    try msg.appendSlice(s.alloc, kind_str);
                }
            }
        }

        if (sym.dot_at) |dot| {
            const prefix = sym.text[0..dot];
            const suffix = sym.text[dot + 1 ..];
            if (a.findImportByAlias(prefix)) |imp| {
                try msg.appendSlice(s.alloc, "\\n\\nqualified access: `");
                try msg.appendSlice(s.alloc, suffix);
                try msg.appendSlice(s.alloc, "` from module `");
                try msg.appendSlice(s.alloc, imp.module);
                try msg.appendSlice(s.alloc, "`");
            } else {
                try msg.appendSlice(s.alloc, "\\n\\nqualified access: prefix `");
                try msg.appendSlice(s.alloc, prefix);
                try msg.appendSlice(s.alloc, "` not recognized as an import alias");
            }
        } else if (a.findDefinition(sym.text)) |d| {
            try msg.appendSlice(s.alloc, "\\n\\ndefined in this file");
            // zepo-ab3s: surface :documentation docstring (if any) below
            // the definition note, separated by an hr for readability.
            if (d.docstring) |def_doc| {
                try msg.appendSlice(s.alloc, "\\n\\n---\\n\\n");
                try msg.appendSlice(s.alloc, def_doc);
            }
        } else {
            // Maybe it's an import name.
            for (a.imports.items) |imp| {
                switch (imp.selection) {
                    .only => |names| for (names) |n| {
                        if (std.mem.eql(u8, n, sym.text)) {
                            try msg.appendSlice(s.alloc, "\\n\\nimported from `");
                            try msg.appendSlice(s.alloc, imp.module);
                            try msg.appendSlice(s.alloc, "`");
                            break;
                        }
                    },
                    .all => if (std.mem.eql(u8, imp.module, sym.text)) {
                        try msg.appendSlice(s.alloc, "\\n\\nimport namespace alias for module `");
                        try msg.appendSlice(s.alloc, imp.module);
                        try msg.appendSlice(s.alloc, "`");
                    },
                    .as_alias => |al| if (std.mem.eql(u8, al, sym.text)) {
                        try msg.appendSlice(s.alloc, "\\n\\nalias for module `");
                        try msg.appendSlice(s.alloc, imp.module);
                        try msg.appendSlice(s.alloc, "`");
                    },
                }
            }
        }

        // JSON encode the result.
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.alloc);
        try out.appendSlice(s.alloc, "{\"contents\":{\"kind\":\"markdown\",\"value\":\"");
        try proto.escapeJsonInto(&out, s.alloc, msg.items);
        try out.appendSlice(s.alloc, "\"},\"range\":");
        try writeRangeEnc(&out, s.alloc, doc.text, sym.range, s.encoding);
        try out.append(s.alloc, '}');
        try s.sendResult(id, out.items);
        return false;
    }

    // -- Definition ---------------------------------------------------------

    fn onDefinition(s: *Server, id: std.json.Value, params: std.json.ObjectMap) !bool {
        const td = getObject(params, "textDocument") orelse return s.sendNullResult(id);
        const uri = getString(td, "uri") orelse return s.sendNullResult(id);
        const pos = getPos(params) orelse return s.sendNullResult(id);
        const doc = s.store.get(uri) orelse return s.sendNullResult(id);

        // zepo-wwh7: borrow the cached analysis instead of re-analyzing.
        const a = try s.getCachedAnalysis(uri);

        const off = analysis.posToOffsetEnc(doc.text, pos, s.encoding);
        const sym = a.symbolAtOffset(doc.text, off) orelse return s.sendNullResult(id);

        const lookup_name: []const u8 = if (sym.dot_at) |dot| sym.text[dot + 1 ..] else sym.text;

        // First: try local definition in the current document.
        if (a.findDefinition(lookup_name)) |def| {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(s.alloc);
            try out.appendSlice(s.alloc, "{\"uri\":\"");
            try proto.escapeJsonInto(&out, s.alloc, uri);
            try out.appendSlice(s.alloc, "\",\"range\":");
            try writeRangeEnc(&out, s.alloc, doc.text, def.name_range, s.encoding);
            try out.append(s.alloc, '}');
            try s.sendResult(id, out.items);
            return false;
        }

        // Cross-file fallback (zepo-zoan): qualified symbol whose prefix is an
        // import alias. Resolve the module file via the runtime search-path
        // logic, scan it for `(define NAME ...)`, and return a remote Location.
        if (sym.dot_at) |_| {
            const prefix = sym.text[0..sym.dot_at.?];
            if (a.findImportByAlias(prefix)) |imp| {
                if (try s.crossFileDef(imp.module, lookup_name)) |loc| {
                    defer s.alloc.free(loc.uri);
                    defer s.alloc.free(loc.target_text);
                    var out: std.ArrayListUnmanaged(u8) = .empty;
                    defer out.deinit(s.alloc);
                    try out.appendSlice(s.alloc, "{\"uri\":\"");
                    try proto.escapeJsonInto(&out, s.alloc, loc.uri);
                    try out.appendSlice(s.alloc, "\",\"range\":");
                    try writeRangeEnc(&out, s.alloc, loc.target_text, loc.range, s.encoding);
                    try out.append(s.alloc, '}');
                    try s.sendResult(id, out.items);
                    return false;
                }
            }
        }

        // Degenerate fallback: jump to the import form for an alias hit.
        if (a.findImportByAlias(sym.text)) |imp| {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(s.alloc);
            try out.appendSlice(s.alloc, "{\"uri\":\"");
            try proto.escapeJsonInto(&out, s.alloc, uri);
            try out.appendSlice(s.alloc, "\",\"range\":");
            try writeRangeEnc(&out, s.alloc, doc.text, imp.module_range, s.encoding);
            try out.append(s.alloc, '}');
            try s.sendResult(id, out.items);
            return false;
        }

        return s.sendNullResult(id);
    }

    const CrossFileHit = struct {
        uri: []u8,
        range: analysis.Range,
        target_text: []u8, // dup of cached text for encoding conversion
    };

    /// Resolve `module` to a file on disk and search for `name`'s top-level
    /// (define ...) / (module ...) form. Returns owned uri/text; caller frees.
    fn crossFileDef(s: *Server, module: []const u8, name: []const u8) !?CrossFileHit {
        const path = (try s.resolver.resolveModule(module)) orelse return null;
        defer s.alloc.free(path);
        const result = (try s.resolver.getAnalysis(path)) orelse return null;
        const def = result.an.findDefinition(name) orelse return null;
        // Build file:// uri.
        const uri = try std.fmt.allocPrint(s.alloc, "file://{s}", .{path});
        const text_copy = try s.alloc.dupe(u8, result.text);
        return .{ .uri = uri, .range = def.name_range, .target_text = text_copy };
    }

    // -- Completion ---------------------------------------------------------

    fn onCompletion(s: *Server, id: std.json.Value, params: std.json.ObjectMap) !bool {
        const td = getObject(params, "textDocument") orelse return s.sendNullResult(id);
        const uri = getString(td, "uri") orelse return s.sendNullResult(id);
        const pos = getPos(params) orelse return s.sendNullResult(id);
        const doc = s.store.get(uri) orelse return s.sendNullResult(id);

        // zepo-wwh7: borrow the cached analysis instead of re-analyzing.
        const a = try s.getCachedAnalysis(uri);

        // Look backwards from the cursor for `<alias>.` qualifier.
        const off = analysis.posToOffsetEnc(doc.text, pos, s.encoding);
        var start: usize = off;
        while (start > 0) {
            const c = doc.text[start - 1];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '?' or c == '!' or c == '.' or c == '/' or c == ':' or c == '*' or c == '+' or c == '<' or c == '>' or c == '=') {
                start -= 1;
            } else break;
        }
        const tail = doc.text[start..off];
        const dot_idx = std.mem.lastIndexOfScalar(u8, tail, '.') orelse {
            try s.sendCompletionList(id, &.{});
            return false;
        };
        const prefix = tail[0..dot_idx];
        const partial = tail[dot_idx + 1 ..];

        var items: std.ArrayListUnmanaged([]const u8) = .empty;
        defer items.deinit(s.alloc);

        // Names from imports matching the alias.
        if (a.findImportByAlias(prefix)) |imp| {
            switch (imp.selection) {
                .only => |names| for (names) |n| {
                    if (std.mem.startsWith(u8, n, partial)) try items.append(s.alloc, n);
                },
                else => {},
            }
        }
        // Also offer local defines if the prefix matches no alias — usually we
        // wouldn't but keeps the feature useful while sources are partial.
        if (items.items.len == 0) {
            for (a.defines.items) |d| {
                if (std.mem.startsWith(u8, d.name, partial)) try items.append(s.alloc, d.name);
            }
        }

        try s.sendCompletionList(id, items.items);
        return false;
    }

    fn sendCompletionList(s: *Server, id: std.json.Value, items: []const []const u8) !void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.alloc);
        try out.appendSlice(s.alloc, "{\"isIncomplete\":false,\"items\":[");
        for (items, 0..) |it, i| {
            if (i > 0) try out.append(s.alloc, ',');
            try out.appendSlice(s.alloc, "{\"label\":\"");
            try proto.escapeJsonInto(&out, s.alloc, it);
            try out.appendSlice(s.alloc, "\",\"kind\":6}");
        }
        try out.appendSlice(s.alloc, "]}");
        try s.sendResult(id, out.items);
    }

    // -- Document Symbols (zepo-70qf) ---------------------------------------

    fn onDocumentSymbol(s: *Server, id: std.json.Value, params: std.json.ObjectMap) !bool {
        const td = getObject(params, "textDocument") orelse return s.sendNullResult(id);
        const uri = getString(td, "uri") orelse return s.sendNullResult(id);
        const doc = s.store.get(uri) orelse return s.sendNullResult(id);
        const a = try s.getCachedAnalysis(uri);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.alloc);
        try out.append(s.alloc, '[');
        var first: bool = true;
        for (a.defines.items) |d| {
            if (!first) try out.append(s.alloc, ',');
            first = false;
            // LSP SymbolKind: Module=2, Function=12, Variable=13.
            const kind: u32 = switch (d.kind) {
                .module => 2,
                .define => blk: {
                    // If the real analyzer knows this is a procedure, mark
                    // it as Function; otherwise Variable.
                    if (a.real) |*ra| {
                        if (ra.kindOf(d.name)) |k| switch (k) {
                            .global_proc, .primitive, .local_macro, .macro => break :blk 12,
                            else => {},
                        };
                    }
                    break :blk 13;
                },
            };
            try out.appendSlice(s.alloc, "{\"name\":\"");
            try proto.escapeJsonInto(&out, s.alloc, d.name);
            try out.appendSlice(s.alloc, "\",\"kind\":");
            var kbuf: [16]u8 = undefined;
            try out.appendSlice(s.alloc, try std.fmt.bufPrint(&kbuf, "{d}", .{kind}));
            try out.appendSlice(s.alloc, ",\"range\":");
            try writeRangeEnc(&out, s.alloc, doc.text, d.form_range, s.encoding);
            try out.appendSlice(s.alloc, ",\"selectionRange\":");
            try writeRangeEnc(&out, s.alloc, doc.text, d.name_range, s.encoding);
            try out.append(s.alloc, '}');
        }
        try out.append(s.alloc, ']');
        try s.sendResult(id, out.items);
        return false;
    }

    // -- Workspace Symbol (zepo-70qf) ---------------------------------------

    fn onWorkspaceSymbol(s: *Server, id: std.json.Value, params: std.json.ObjectMap) !bool {
        const query: []const u8 = getString(params, "query") orelse "";

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.alloc);
        try out.append(s.alloc, '[');
        var first: bool = true;

        // Search all open documents first (cheap — already analyzed).
        var doc_it = s.store.docs.iterator();
        while (doc_it.next()) |entry| {
            const uri = entry.key_ptr.*;
            const doc = entry.value_ptr;
            const a = s.getCachedAnalysis(uri) catch continue;
            for (a.defines.items) |d| {
                if (!matchesQuery(d.name, query)) continue;
                if (!first) try out.append(s.alloc, ',');
                first = false;
                try writeWorkspaceSymbol(s, &out, doc.text, uri, d);
            }
        }

        // Also walk resolver paths for .lisp files we haven't opened. Best-
        // effort: silently skip any file that fails to analyze.
        try s.resolver.ensurePaths();
        for (s.resolver.paths.items) |dir| {
            try s.searchWorkspaceDir(dir, query, &out, &first);
        }

        try out.append(s.alloc, ']');
        try s.sendResult(id, out.items);
        return false;
    }

    fn searchWorkspaceDir(
        s: *Server,
        dir_path: []const u8,
        query: []const u8,
        out: *std.ArrayListUnmanaged(u8),
        first: *bool,
    ) !void {
        // zepo-70qf: Zig 0.16 std.Io.Dir API is unwieldy here; use POSIX
        // opendir/readdir directly (same pattern as src/prims/sys.zig).
        var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (dir_path.len >= pbuf.len) return;
        @memcpy(pbuf[0..dir_path.len], dir_path);
        pbuf[dir_path.len] = 0;
        const path_c: [*:0]const u8 = @ptrCast(&pbuf);
        const dp = std.c.opendir(path_c) orelse return;
        defer _ = std.c.closedir(dp);

        while (std.c.readdir(dp)) |entry| {
            const name = std.mem.sliceTo(&entry.name, 0);
            if (name.len < 6 or !std.mem.endsWith(u8, name, ".lisp")) continue;
            const abs = std.fs.path.join(s.alloc, &.{ dir_path, name }) catch continue;
            defer s.alloc.free(abs);
            const got_opt = s.resolver.getAnalysis(abs) catch continue;
            const got = got_opt orelse continue;
            const uri = std.fmt.allocPrint(s.alloc, "file://{s}", .{abs}) catch continue;
            defer s.alloc.free(uri);
            if (s.store.docs.contains(uri)) continue;
            for (got.an.defines.items) |d| {
                if (!matchesQuery(d.name, query)) continue;
                if (!first.*) try out.append(s.alloc, ',');
                first.* = false;
                try writeWorkspaceSymbol(s, out, got.text, uri, d);
            }
        }
    }

    fn writeWorkspaceSymbol(
        s: *Server,
        out: *std.ArrayListUnmanaged(u8),
        text: []const u8,
        uri: []const u8,
        d: analysis.Definition,
    ) !void {
        const kind: u32 = switch (d.kind) {
            .module => 2,
            .define => 13,
        };
        try out.appendSlice(s.alloc, "{\"name\":\"");
        try proto.escapeJsonInto(out, s.alloc, d.name);
        try out.appendSlice(s.alloc, "\",\"kind\":");
        var kbuf2: [16]u8 = undefined;
        try out.appendSlice(s.alloc, try std.fmt.bufPrint(&kbuf2, "{d}", .{kind}));
        try out.appendSlice(s.alloc, ",\"location\":{\"uri\":\"");
        try proto.escapeJsonInto(out, s.alloc, uri);
        try out.appendSlice(s.alloc, "\",\"range\":");
        try writeRangeEnc(out, s.alloc, text, d.name_range, s.encoding);
        try out.appendSlice(s.alloc, "}}");
    }

    // -- References / Rename (zepo-41a2) ------------------------------------

    /// Container for the resolved scope of a refactor: the set of (uri,
    /// range) pairs that name a single binding. For locals, that's the
    /// occurrences inside one lambda body in one file. For globals, that's
    /// every matching occurrence across the workspace (filtered to exclude
    /// shadowed-local uses).
    const RefList = struct {
        alloc: std.mem.Allocator,
        items: std.ArrayListUnmanaged(Ref) = .empty,

        const Ref = struct {
            uri: []u8, // owned
            range: analysis.Range,
            text: []const u8, // borrowed: the doc/file text these ranges index into
        };

        fn deinit(self: *RefList) void {
            for (self.items.items) |it| self.alloc.free(it.uri);
            self.items.deinit(self.alloc);
        }

        fn append(self: *RefList, uri: []const u8, range: analysis.Range, text: []const u8) !void {
            const uri_owned = try self.alloc.dupe(u8, uri);
            errdefer self.alloc.free(uri_owned);
            try self.items.append(self.alloc, .{ .uri = uri_owned, .range = range, .text = text });
        }
    };

    /// Resolve all occurrences for the binding named at (uri, pos). Returns
    /// null when the cursor isn't on a renameable symbol (e.g. on whitespace,
    /// on a qualified part, on a primitive). Returned RefList owns its strings.
    fn collectReferences(
        s: *Server,
        uri: []const u8,
        pos: analysis.Pos,
        include_definition: bool,
    ) !?RefList {
        const doc = s.store.get(uri) orelse return null;
        const a = try s.getCachedAnalysis(uri);
        const off = analysis.posToOffsetEnc(doc.text, pos, s.encoding);
        const sym = a.symbolAtOffset(doc.text, off) orelse return null;
        if (sym.dot_at != null) return null; // qualified — out of scope
        const name = sym.text;

        var refs = RefList{ .alloc = s.alloc };
        errdefer refs.deinit();

        // Determine scope kind from the real analyzer when available.
        var is_local: bool = false;
        var local_scope_start: u32 = 0;
        var local_scope_end: u32 = 0;
        if (a.real) |*ra| {
            const off_u32: u32 = @intCast(off);
            if (ra.classifyAt(name, off_u32)) |k| {
                if (k == .primitive) return null; // refuse to rename primitives
                if (k == .local or k == .captured) {
                    // Find the deepest scope that binds `name` and contains
                    // the cursor offset — that defines the rename scope.
                    var deepest_idx: ?usize = null;
                    for (ra.scopes.items, 0..) |sc, i| {
                        if (off_u32 < sc.body_start or off_u32 > sc.body_end) continue;
                        if (sc.locals.contains(name)) deepest_idx = i;
                    }
                    if (deepest_idx) |di| {
                        is_local = true;
                        local_scope_start = ra.scopes.items[di].body_start;
                        local_scope_end = ra.scopes.items[di].body_end;
                    }
                }
            }
        }

        if (is_local) {
            // Single-file, scoped. Iterate scanner-side symbols within the
            // scope's byte range.
            for (a.symbols.items) |hit| {
                if (hit.dot_at != null) continue;
                if (!std.mem.eql(u8, hit.text, name)) continue;
                const hit_off: u32 = @intCast(analysis.posToOffsetEnc(doc.text, hit.range.start, s.encoding));
                if (hit_off < local_scope_start or hit_off > local_scope_end) continue;
                _ = include_definition; // local: include all occurrences
                try refs.append(uri, hit.range, doc.text);
            }
            return refs;
        }

        // Global scope: walk every open document, then every workspace file
        // not already open. For each, include occurrences whose classifyAt
        // resolves to a non-shadowed global. If real analysis is unavailable
        // for a file, fall back to including all occurrences of the name
        // (best-effort).
        var doc_it = s.store.docs.iterator();
        while (doc_it.next()) |entry| {
            const u = entry.key_ptr.*;
            const d = entry.value_ptr;
            const aa = s.getCachedAnalysis(u) catch continue;
            for (aa.symbols.items) |hit| {
                if (hit.dot_at != null) continue;
                if (!std.mem.eql(u8, hit.text, name)) continue;
                if (aa.real) |*ra| {
                    const h_off: u32 = @intCast(analysis.posToOffsetEnc(d.text, hit.range.start, s.encoding));
                    if (ra.classifyAt(name, h_off)) |k| {
                        if (k == .local or k == .captured) continue; // shadow
                    }
                }
                try refs.append(u, hit.range, d.text);
            }
        }

        try s.resolver.ensurePaths();
        for (s.resolver.paths.items) |dir| {
            try s.collectGlobalRefsInDir(dir, name, &refs);
        }
        _ = include_definition; // global: include all occurrences
        return refs;
    }

    fn collectGlobalRefsInDir(s: *Server, dir_path: []const u8, name: []const u8, refs: *RefList) !void {
        var pbuf: [std.fs.max_path_bytes + 1]u8 = undefined;
        if (dir_path.len >= pbuf.len) return;
        @memcpy(pbuf[0..dir_path.len], dir_path);
        pbuf[dir_path.len] = 0;
        const path_c: [*:0]const u8 = @ptrCast(&pbuf);
        const dp = std.c.opendir(path_c) orelse return;
        defer _ = std.c.closedir(dp);

        while (std.c.readdir(dp)) |entry| {
            const nm = std.mem.sliceTo(&entry.name, 0);
            if (nm.len < 6 or !std.mem.endsWith(u8, nm, ".lisp")) continue;
            const abs = std.fs.path.join(s.alloc, &.{ dir_path, nm }) catch continue;
            defer s.alloc.free(abs);
            const got_opt = s.resolver.getAnalysis(abs) catch continue;
            const got = got_opt orelse continue;
            const uri = std.fmt.allocPrint(s.alloc, "file://{s}", .{abs}) catch continue;
            defer s.alloc.free(uri);
            if (s.store.docs.contains(uri)) continue;
            for (got.an.symbols.items) |hit| {
                if (hit.dot_at != null) continue;
                if (!std.mem.eql(u8, hit.text, name)) continue;
                if (got.an.real) |*ra| {
                    const h_off: u32 = @intCast(analysis.posToOffsetEnc(got.text, hit.range.start, s.encoding));
                    if (ra.classifyAt(name, h_off)) |k| {
                        if (k == .local or k == .captured) continue;
                    }
                }
                try refs.append(uri, hit.range, got.text);
            }
        }
    }

    fn onReferences(s: *Server, id: std.json.Value, params: std.json.ObjectMap) !bool {
        const td = getObject(params, "textDocument") orelse return s.sendNullResult(id);
        const uri = getString(td, "uri") orelse return s.sendNullResult(id);
        const pos = getPos(params) orelse return s.sendNullResult(id);
        const ctx = getObject(params, "context");
        const include_def: bool = if (ctx) |c|
            (if (c.get("includeDeclaration")) |v|
                (v == .bool and v.bool)
            else
                true)
        else
            true;

        var refs_opt = (try s.collectReferences(uri, pos, include_def)) orelse {
            return s.sendNullResult(id);
        };
        defer refs_opt.deinit();

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.alloc);
        try out.append(s.alloc, '[');
        var first: bool = true;
        for (refs_opt.items.items) |ref| {
            if (!first) try out.append(s.alloc, ',');
            first = false;
            try out.appendSlice(s.alloc, "{\"uri\":\"");
            try proto.escapeJsonInto(&out, s.alloc, ref.uri);
            try out.appendSlice(s.alloc, "\",\"range\":");
            try writeRangeEnc(&out, s.alloc, ref.text, ref.range, s.encoding);
            try out.append(s.alloc, '}');
        }
        try out.append(s.alloc, ']');
        try s.sendResult(id, out.items);
        return false;
    }

    fn onPrepareRename(s: *Server, id: std.json.Value, params: std.json.ObjectMap) !bool {
        const td = getObject(params, "textDocument") orelse return s.sendNullResult(id);
        const uri = getString(td, "uri") orelse return s.sendNullResult(id);
        const pos = getPos(params) orelse return s.sendNullResult(id);
        const doc = s.store.get(uri) orelse return s.sendNullResult(id);
        const a = try s.getCachedAnalysis(uri);
        const off = analysis.posToOffsetEnc(doc.text, pos, s.encoding);
        const sym = a.symbolAtOffset(doc.text, off) orelse return s.sendNullResult(id);
        if (sym.dot_at != null) return s.sendNullResult(id);

        // Refuse primitives — return null. (LSP spec: null means "rename
        // not available at this location".)
        if (a.real) |*ra| {
            if (ra.classifyAt(sym.text, @intCast(off))) |k| {
                if (k == .primitive) return s.sendNullResult(id);
            }
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.alloc);
        try writeRangeEnc(&out, s.alloc, doc.text, sym.range, s.encoding);
        try s.sendResult(id, out.items);
        return false;
    }

    fn onRename(s: *Server, id: std.json.Value, params: std.json.ObjectMap) !bool {
        const td = getObject(params, "textDocument") orelse return s.sendNullResult(id);
        const uri = getString(td, "uri") orelse return s.sendNullResult(id);
        const pos = getPos(params) orelse return s.sendNullResult(id);
        const new_name = getString(params, "newName") orelse return s.sendNullResult(id);

        var refs_opt = (try s.collectReferences(uri, pos, true)) orelse {
            return s.sendNullResult(id);
        };
        defer refs_opt.deinit();

        // Build WorkspaceEdit { changes: { uri: [TextEdit, ...] } }.
        // Group refs by URI so each file gets one TextEdit array.
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.alloc);
        try out.appendSlice(s.alloc, "{\"changes\":{");

        // Track which URIs we've already opened in the JSON output.
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(s.alloc);

        var first_uri: bool = true;
        for (refs_opt.items.items) |ref| {
            if (seen.contains(ref.uri)) continue;
            try seen.put(s.alloc, ref.uri, {});
            if (!first_uri) try out.append(s.alloc, ',');
            first_uri = false;
            try out.append(s.alloc, '"');
            try proto.escapeJsonInto(&out, s.alloc, ref.uri);
            try out.appendSlice(s.alloc, "\":[");
            var first_edit: bool = true;
            for (refs_opt.items.items) |r2| {
                if (!std.mem.eql(u8, r2.uri, ref.uri)) continue;
                if (!first_edit) try out.append(s.alloc, ',');
                first_edit = false;
                try out.appendSlice(s.alloc, "{\"range\":");
                try writeRangeEnc(&out, s.alloc, r2.text, r2.range, s.encoding);
                try out.appendSlice(s.alloc, ",\"newText\":\"");
                try proto.escapeJsonInto(&out, s.alloc, new_name);
                try out.appendSlice(s.alloc, "\"}");
            }
            try out.append(s.alloc, ']');
        }
        try out.appendSlice(s.alloc, "}}");
        try s.sendResult(id, out.items);
        return false;
    }

    // -- Diagnostics --------------------------------------------------------

    /// Publish lightweight diagnostics. We compute paren-balance and report
    /// unbound qualified prefixes / missing modules as a static check.
    pub fn publishDiagnostics(s: *Server, uri: []const u8) !void {
        const doc = s.store.get(uri) orelse return;

        var diags: std.ArrayListUnmanaged(Diag) = .empty;
        defer {
            for (diags.items) |d| if (d.owned) s.alloc.free(d.message);
            diags.deinit(s.alloc);
        }

        try checkParens(s.alloc, doc.text, &diags);

        // zepo-vwns: reader-based diagnostics. Boots a Zepo reader + AST
        // builder against the document and reports span-accurate parse and
        // syntax errors with the same precision the CLI would. Ranges are
        // emitted in byte coordinates; converted to the negotiated encoding
        // below alongside the other diagnostics.
        var reader_diags: std.ArrayListUnmanaged(reader_check.Diag) = .empty;
        defer {
            for (reader_diags.items) |d| if (d.owned) s.alloc.free(d.message);
            reader_diags.deinit(s.alloc);
        }
        reader_check.check(s.alloc, uri, doc.text, &reader_diags) catch {};
        for (reader_diags.items) |rd| {
            // Don't free the source message yet — copy so we can transfer
            // ownership semantics. Owned strings get duped; non-owned
            // (parser's static msg) are referenced directly.
            const msg_copy = if (rd.owned)
                try s.alloc.dupe(u8, rd.message)
            else
                rd.message;
            try diags.append(s.alloc, .{ .range = rd.range, .message = msg_copy, .owned = rd.owned });
        }

        // Use analysis to find references to qualified symbols whose prefix
        // is not an imported alias — report as "unbound namespace".
        // zepo-wwh7: borrow the cached analysis instead of re-analyzing.
        const a = try s.getCachedAnalysis(uri);
        for (a.symbols.items) |sym| {
            const dot = sym.dot_at orelse continue;
            const prefix = sym.text[0..dot];
            if (a.findImportByAlias(prefix) != null) continue;
            // Skip if prefix is also a local define.
            if (a.findDefinition(prefix) != null) continue;
            // Skip path-like names (slashes).
            if (std.mem.indexOfScalar(u8, sym.text, '/') != null) continue;
            const msg = try std.fmt.allocPrint(s.alloc, "unknown namespace alias '{s}' — no matching import", .{prefix});
            try diags.append(s.alloc, .{ .range = sym.range, .message = msg, .owned = true });
        }

        try s.writeDiagnostics(uri, doc.text, diags.items);
    }

    fn writeDiagnostics(s: *Server, uri: []const u8, text: []const u8, diags: []const Diag) !void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.alloc);
        try out.appendSlice(s.alloc, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
        try proto.escapeJsonInto(&out, s.alloc, uri);
        try out.appendSlice(s.alloc, "\",\"diagnostics\":[");
        for (diags, 0..) |d, i| {
            if (i > 0) try out.append(s.alloc, ',');
            try out.appendSlice(s.alloc, "{\"range\":");
            try writeRangeEnc(&out, s.alloc, text, d.range, s.encoding);
            try out.appendSlice(s.alloc, ",\"severity\":1,\"source\":\"zepo\",\"message\":\"");
            try proto.escapeJsonInto(&out, s.alloc, d.message);
            try out.appendSlice(s.alloc, "\"}");
        }
        try out.appendSlice(s.alloc, "]}}");
        proto.writeMessage(s.writer, out.items);
    }

    // -- JSON-RPC helpers ---------------------------------------------------

    fn sendResult(s: *Server, id: std.json.Value, result_json: []const u8) !void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.alloc);
        try out.appendSlice(s.alloc, "{\"jsonrpc\":\"2.0\",\"id\":");
        try proto.idToJson(&out, s.alloc, id);
        try out.appendSlice(s.alloc, ",\"result\":");
        try out.appendSlice(s.alloc, result_json);
        try out.append(s.alloc, '}');
        proto.writeMessage(s.writer, out.items);
    }

    fn sendNullResult(s: *Server, id: std.json.Value) !bool {
        try s.sendResult(id, "null");
        return false;
    }
};

const Diag = struct {
    range: analysis.Range,
    message: []const u8,
    owned: bool,
};

fn checkParens(alloc: std.mem.Allocator, text: []const u8, diags: *std.ArrayListUnmanaged(Diag)) !void {
    var depth: isize = 0;
    var i: usize = 0;
    var in_string = false;
    var in_comment = false;
    var last_open: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_comment) {
            if (c == '\n') in_comment = false;
            continue;
        }
        if (in_string) {
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            ';' => in_comment = true,
            '"' => in_string = true,
            '(' => {
                depth += 1;
                last_open = i;
            },
            ')' => {
                depth -= 1;
                if (depth < 0) {
                    const msg = try alloc.dupe(u8, "unmatched closing paren");
                    try diags.append(alloc, .{
                        .range = analysis.Range.fromOffsets(text, i, i + 1),
                        .message = msg,
                        .owned = true,
                    });
                    depth = 0;
                }
            },
            else => {},
        }
    }
    if (depth > 0) {
        const msg = try alloc.dupe(u8, "unbalanced parenthesis: missing closing ')'");
        try diags.append(alloc, .{
            .range = analysis.Range.fromOffsets(text, last_open, last_open + 1),
            .message = msg,
            .owned = true,
        });
    }
}

// zepo-70qf: LSP workspace/symbol uses a fuzzy substring match by spec.
// Empty query matches everything. Case-insensitive substring.
fn matchesQuery(name: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > name.len) return false;
    var i: usize = 0;
    while (i + query.len <= name.len) : (i += 1) {
        var j: usize = 0;
        while (j < query.len) : (j += 1) {
            const nc = std.ascii.toLower(name[i + j]);
            const qc = std.ascii.toLower(query[j]);
            if (nc != qc) break;
        }
        if (j == query.len) return true;
    }
    return false;
}

fn writeRange(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, r: analysis.Range) !void {
    var buf: [192]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf,
        "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ r.start.line, r.start.character, r.end.line, r.end.character });
    try out.appendSlice(alloc, s);
}

/// Like writeRange but converts a byte-encoded internal range to the given
/// encoding using `text` as the source.
fn writeRangeEnc(
    out: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    text: []const u8,
    r: analysis.Range,
    enc: analysis.PositionEncoding,
) !void {
    const wire = analysis.convertRangeFromBytes(text, r, enc);
    try writeRange(out, alloc, wire);
}

fn getObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    return switch (obj.get(key) orelse return null) {
        .object => |o| o,
        else => null,
    };
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

fn getPos(params: std.json.ObjectMap) ?analysis.Pos {
    const p = getObject(params, "position") orelse return null;
    const line = switch (p.get("line") orelse return null) {
        .integer => |n| @as(u32, @intCast(@max(0, n))),
        else => return null,
    };
    const ch = switch (p.get("character") orelse return null) {
        .integer => |n| @as(u32, @intCast(@max(0, n))),
        else => return null,
    };
    return .{ .line = line, .character = ch };
}

// ---------------------------------------------------------------------------
// stdio driver
// ---------------------------------------------------------------------------

const StdioCtx = struct {};

fn stdioRead(_: *anyopaque, buf: []u8) isize {
    return @intCast(std.c.read(0, buf.ptr, buf.len));
}

fn stdioWrite(_: *anyopaque, buf: []const u8) void {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.c.write(1, buf.ptr + off, buf.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

pub fn runStdio(alloc: std.mem.Allocator) !void {
    var ctx = StdioCtx{};
    const r = proto.Reader{ .read_fn = stdioRead, .ctx = @ptrCast(&ctx) };
    const w = proto.Writer{ .write_fn = stdioWrite, .ctx = @ptrCast(&ctx) };
    var srv = Server.init(alloc, r, w);
    defer srv.deinit();
    try srv.run();
}
