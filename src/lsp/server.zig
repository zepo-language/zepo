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

pub const Server = struct {
    alloc: std.mem.Allocator,
    store: docs_mod.Store,
    reader: proto.Reader,
    writer: proto.Writer,
    shutdown_received: bool = false,

    pub fn init(alloc: std.mem.Allocator, reader: proto.Reader, writer: proto.Writer) Server {
        return .{
            .alloc = alloc,
            .store = docs_mod.Store.init(alloc),
            .reader = reader,
            .writer = writer,
        };
    }

    pub fn deinit(s: *Server) void {
        s.store.deinit();
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
            try s.sendResult(id,
                \\{"capabilities":{"textDocumentSync":1,"hoverProvider":true,"definitionProvider":true,"completionProvider":{"triggerCharacters":["."]}},"serverInfo":{"name":"zepo-lsp","version":"0.1.0"}}
            );
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
        // We advertised TextDocumentSyncKind.Full (1), so take the last full text.
        const last = changes.items[changes.items.len - 1];
        const obj = switch (last) {
            .object => |o| o,
            else => return false,
        };
        const text = getString(obj, "text") orelse return false;
        try s.store.replace(uri, text, version);
        try s.publishDiagnostics(uri);
        return false;
    }

    fn onDidClose(s: *Server, params: std.json.ObjectMap) !bool {
        const td = getObject(params, "textDocument") orelse return false;
        const uri = getString(td, "uri") orelse return false;
        s.store.close(uri);
        return false;
    }

    // -- Hover --------------------------------------------------------------

    fn onHover(s: *Server, id: std.json.Value, params: std.json.ObjectMap) !bool {
        const td = getObject(params, "textDocument") orelse return s.sendNullResult(id);
        const uri = getString(td, "uri") orelse return s.sendNullResult(id);
        const pos = getPos(params) orelse return s.sendNullResult(id);
        const doc = s.store.get(uri) orelse return s.sendNullResult(id);

        var a = try analysis.analyze(s.alloc, doc.text);
        defer a.deinit();

        const off = analysis.posToOffset(doc.text, pos);
        const sym = a.symbolAtOffset(doc.text, off) orelse return s.sendNullResult(id);

        // Build a hover message describing the symbol.
        var msg: std.ArrayListUnmanaged(u8) = .empty;
        defer msg.deinit(s.alloc);
        try msg.appendSlice(s.alloc, "**");
        try msg.appendSlice(s.alloc, sym.text);
        try msg.appendSlice(s.alloc, "**");

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
            _ = d;
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
        try writeRange(&out, s.alloc, sym.range);
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

        var a = try analysis.analyze(s.alloc, doc.text);
        defer a.deinit();

        const off = analysis.posToOffset(doc.text, pos);
        const sym = a.symbolAtOffset(doc.text, off) orelse return s.sendNullResult(id);

        const lookup_name: []const u8 = if (sym.dot_at) |dot| sym.text[dot + 1 ..] else sym.text;
        const def = a.findDefinition(lookup_name) orelse {
            // Try alias -> module name as a degenerate target (jump to import form).
            if (a.findImportByAlias(sym.text)) |imp| {
                var out: std.ArrayListUnmanaged(u8) = .empty;
                defer out.deinit(s.alloc);
                try out.appendSlice(s.alloc, "{\"uri\":\"");
                try proto.escapeJsonInto(&out, s.alloc, uri);
                try out.appendSlice(s.alloc, "\",\"range\":");
                try writeRange(&out, s.alloc, imp.module_range);
                try out.append(s.alloc, '}');
                try s.sendResult(id, out.items);
                return false;
            }
            return s.sendNullResult(id);
        };

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.alloc);
        try out.appendSlice(s.alloc, "{\"uri\":\"");
        try proto.escapeJsonInto(&out, s.alloc, uri);
        try out.appendSlice(s.alloc, "\",\"range\":");
        try writeRange(&out, s.alloc, def.name_range);
        try out.append(s.alloc, '}');
        try s.sendResult(id, out.items);
        return false;
    }

    // -- Completion ---------------------------------------------------------

    fn onCompletion(s: *Server, id: std.json.Value, params: std.json.ObjectMap) !bool {
        const td = getObject(params, "textDocument") orelse return s.sendNullResult(id);
        const uri = getString(td, "uri") orelse return s.sendNullResult(id);
        const pos = getPos(params) orelse return s.sendNullResult(id);
        const doc = s.store.get(uri) orelse return s.sendNullResult(id);

        var a = try analysis.analyze(s.alloc, doc.text);
        defer a.deinit();

        // Look backwards from the cursor for `<alias>.` qualifier.
        const off = analysis.posToOffset(doc.text, pos);
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

        // Use analysis to find references to qualified symbols whose prefix
        // is not an imported alias — report as "unbound namespace".
        var a = try analysis.analyze(s.alloc, doc.text);
        defer a.deinit();
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

        try s.writeDiagnostics(uri, diags.items);
    }

    fn writeDiagnostics(s: *Server, uri: []const u8, diags: []const Diag) !void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(s.alloc);
        try out.appendSlice(s.alloc, "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{\"uri\":\"");
        try proto.escapeJsonInto(&out, s.alloc, uri);
        try out.appendSlice(s.alloc, "\",\"diagnostics\":[");
        for (diags, 0..) |d, i| {
            if (i > 0) try out.append(s.alloc, ',');
            try out.appendSlice(s.alloc, "{\"range\":");
            try writeRange(&out, s.alloc, d.range);
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

fn writeRange(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, r: analysis.Range) !void {
    var buf: [192]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf,
        "{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}}",
        .{ r.start.line, r.start.character, r.end.line, r.end.character });
    try out.appendSlice(alloc, s);
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
