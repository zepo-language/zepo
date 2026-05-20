//! Minimal LSP server: textDocument/publishDiagnostics only.
//! Communicates over stdin/stdout using JSON-RPC 2.0 with Content-Length framing.
//! Handles: initialize, shutdown, exit, textDocument/didOpen, textDocument/didChange.
// zepo-n3h: Zig 0.16 removed std.Io.File; stdin read via std.c.read(0,...),
// stdout write via std.c.write(1,...).

const std = @import("std");
const zepo = @import("zepo");

const MAX_MSG_SIZE = 4 * 1024 * 1024;

pub const LspDiag = struct {
    start_line: u32,
    start_char: u32,
    end_line: u32,
    end_char: u32,
    message: []const u8,
    msg_owned: bool = false,
};

// Read exactly `n` bytes from stdin into `buf`. Returns false on EOF/error.
fn readExact(buf: []u8) bool {
    var got: usize = 0;
    while (got < buf.len) {
        const n = std.c.read(0, buf[got..].ptr, buf.len - got);
        if (n <= 0) return false;
        got += @intCast(n);
    }
    return true;
}

// Read one line from stdin into `buf` (including newline). Returns slice, or null on EOF.
fn readLine(buf: []u8) ?[]u8 {
    var i: usize = 0;
    while (i < buf.len) {
        const n = std.c.read(0, buf[i..].ptr, 1);
        if (n <= 0) return if (i > 0) buf[0..i] else null;
        i += 1;
        if (buf[i - 1] == '\n') return buf[0..i];
    }
    return buf[0..i];
}

fn lspWrite(s: []const u8) void {
    _ = std.c.write(1, s.ptr, s.len);
}

pub fn runLsp(alloc: std.mem.Allocator) !void {
    while (true) {
        const body = readMessage(alloc) catch |e| switch (e) {
            error.EndOfStream => return,
            else => return e,
        };
        defer alloc.free(body);

        const exit = try handleMessage(alloc, body);
        if (exit) return;
    }
}

fn readMessage(alloc: std.mem.Allocator) ![]u8 {
    var content_length: usize = 0;
    var line_buf: [4096]u8 = undefined;

    while (true) {
        const line = readLine(&line_buf) orelse return error.EndOfStream;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) break;
        if (std.mem.startsWith(u8, trimmed, "Content-Length:")) {
            const val = std.mem.trim(u8, trimmed["Content-Length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, val, 10) catch continue;
        }
    }

    if (content_length == 0) return error.EndOfStream;
    if (content_length > MAX_MSG_SIZE) return error.MessageTooLarge;

    const body = try alloc.alloc(u8, content_length);
    if (!readExact(body)) {
        alloc.free(body);
        return error.EndOfStream;
    }
    return body;
}

fn handleMessage(alloc: std.mem.Allocator, body: []const u8) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch return false;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return false,
    };

    const method_val = obj.get("method") orelse return false;
    const method = switch (method_val) {
        .string => |s| s,
        else => return false,
    };

    if (std.mem.eql(u8, method, "initialize")) {
        const id = obj.get("id") orelse std.json.Value{ .null = {} };
        try sendResponse(alloc, id, "{\"capabilities\":{\"textDocumentSync\":1}}");
        return false;
    }

    if (std.mem.eql(u8, method, "shutdown")) {
        const id = obj.get("id") orelse std.json.Value{ .null = {} };
        try sendResponse(alloc, id, "null");
        return false;
    }

    if (std.mem.eql(u8, method, "exit")) return true;

    const params_val = obj.get("params") orelse return false;
    const params = switch (params_val) {
        .object => |o| o,
        else => return false,
    };

    if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        const td = getObject(params, "textDocument") orelse return false;
        const uri = getString(td, "uri") orelse return false;
        const text = getString(td, "text") orelse return false;
        try diagnoseAndPublish(alloc, uri, text);
        return false;
    }

    if (std.mem.eql(u8, method, "textDocument/didChange")) {
        const td = getObject(params, "textDocument") orelse return false;
        const uri = getString(td, "uri") orelse return false;
        const changes_val = params.get("contentChanges") orelse return false;
        const changes = switch (changes_val) {
            .array => |a| a,
            else => return false,
        };
        if (changes.items.len == 0) return false;
        const first = switch (changes.items[0]) {
            .object => |o| o,
            else => return false,
        };
        const text = getString(first, "text") orelse return false;
        try diagnoseAndPublish(alloc, uri, text);
        return false;
    }

    return false;
}

fn diagnoseAndPublish(alloc: std.mem.Allocator, uri: []const u8, text: []const u8) !void {
    var diags = try checkDocument(alloc, uri, text);
    defer {
        for (diags.items) |d| if (d.msg_owned) alloc.free(d.message);
        diags.deinit(alloc);
    }
    try sendDiagnostics(alloc, uri, diags.items);
}

pub fn checkDocument(alloc: std.mem.Allocator, uri: []const u8, src: []const u8) !std.ArrayListUnmanaged(LspDiag) {
    var diags: std.ArrayListUnmanaged(LspDiag) = .empty;

    var gc = try zepo.GC.init(alloc);
    defer gc.deinit();
    var syms = try zepo.runtime.SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = zepo.reader.SpanTable.init(alloc);
    defer spans.deinit();
    var arena = zepo.ast.NodeArena.init(alloc);
    defer arena.deinit();

    var parser = zepo.reader.Parser.init(&gc, &syms, &spans, src, uri, alloc);
    defer parser.deinit();

    var builder = zepo.ast.Builder.init(&arena, &syms, alloc);
    builder.span_table = &spans;

    while (true) {
        const form = parser.readOne() catch |e| switch (e) {
            error.Eof => break,
            else => {
                if (parser.last_diag) |diag| {
                    try diags.append(alloc, spanToDiag(diag.span, diag.msg, false));
                } else {
                    const msg = try std.fmt.allocPrint(alloc, "read error: {}", .{e});
                    try diags.append(alloc, .{ .start_line = 0, .start_char = 0, .end_line = 0, .end_char = 1, .message = msg, .msg_owned = true });
                }
                break;
            },
        };

        if (isTopLevelSpecial(form)) {
            if (validateTopLevelSpecial(form)) |msg| {
                const span = spans.get(form) orelse zepo.reader.Span{
                    .start = .{ .line = 1, .col = 1, .offset = 0 },
                    .end = .{ .line = 1, .col = 1, .offset = 0 },
                    .file = uri,
                };
                try diags.append(alloc, spanToDiag(span, msg, false));
            }
            continue;
        }

        _ = builder.build(form) catch |e| {
            const msg = try std.fmt.allocPrint(alloc, "syntax error: {}", .{e});
            try diags.append(alloc, spanToDiag(builder.current_span, msg, true));
        };
    }

    return diags;
}

fn spanToDiag(span: zepo.reader.Span, msg: []const u8, owned: bool) LspDiag {
    const sl: u32 = if (span.start.line > 0) @intCast(span.start.line - 1) else 0;
    const sc: u32 = if (span.start.col > 0) @intCast(span.start.col - 1) else 0;
    const el: u32 = if (span.end.line > 0) @intCast(span.end.line - 1) else sl;
    const ec: u32 = if (span.end.col > 0) @intCast(span.end.col) else sc + 1;
    return .{ .start_line = sl, .start_char = sc, .end_line = el, .end_char = ec, .message = msg, .msg_owned = owned };
}

fn sendResponse(alloc: std.mem.Allocator, id: std.json.Value, result_json: []const u8) !void {
    var id_buf: [128]u8 = undefined;
    const id_str: []const u8 = switch (id) {
        .integer => |n| try std.fmt.bufPrint(&id_buf, "{d}", .{n}),
        .string => |s| try std.fmt.bufPrint(&id_buf, "\"{s}\"", .{s}),
        else => "null",
    };
    const body = try std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id_str, result_json });
    defer alloc.free(body);
    sendRaw(alloc, body);
}

fn sendDiagnostics(alloc: std.mem.Allocator, uri: []const u8, diags: []const LspDiag) !void {
    var arr: std.ArrayListUnmanaged(u8) = .empty;
    defer arr.deinit(alloc);

    try arr.append(alloc, '[');
    for (diags, 0..) |d, i| {
        if (i > 0) try arr.append(alloc, ',');
        var hbuf: [256]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hbuf,
            "{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":1,\"message\":\"",
            .{ d.start_line, d.start_char, d.end_line, d.end_char },
        ) catch continue;
        try arr.appendSlice(alloc, hdr);
        for (d.message) |c| switch (c) {
            '"' => try arr.appendSlice(alloc, "\\\""),
            '\\' => try arr.appendSlice(alloc, "\\\\"),
            '\n' => try arr.appendSlice(alloc, "\\n"),
            '\r' => try arr.appendSlice(alloc, "\\r"),
            '\t' => try arr.appendSlice(alloc, "\\t"),
            else => try arr.append(alloc, c),
        };
        try arr.appendSlice(alloc, "\"}");
    }
    try arr.append(alloc, ']');

    const body = try std.fmt.allocPrint(alloc,
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":\"{s}\",\"diagnostics\":{s}}}}}",
        .{ uri, arr.items });
    defer alloc.free(body);
    sendRaw(alloc, body);
}

fn sendRaw(alloc: std.mem.Allocator, body: []const u8) void {
    var hbuf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&hbuf, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return;
    lspWrite(header);
    lspWrite(body);
    _ = alloc;
}

fn getObject(obj: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    return switch (obj.get(key) orelse return null) {
        .object => |o| o,
        else => null,
    };
}

fn isTopLevelSpecial(v: zepo.Value) bool {
    const objects = zepo.runtime.objects;
    const value_mod = zepo.abi.value;
    if (!value_mod.isPtr(v)) return false;
    if (!objects.isPair(v)) return false;
    const head = objects.pairCar(v).*;
    if (!objects.isSymbol(head)) return false;
    const name = objects.symbolName(head);
    const heads = [_][]const u8{ "module", "import", "export", "include", "package", "defmacro" };
    for (heads) |h| if (std.mem.eql(u8, name, h)) return true;
    return false;
}

fn validateTopLevelSpecial(v: zepo.Value) ?[]const u8 {
    const objects = zepo.runtime.objects;
    const value_mod = zepo.abi.value;
    const rest = objects.pairCdr(v).*;
    if (value_mod.isNil(rest)) return "missing arguments";
    if (!objects.isPair(rest)) return "invalid form structure";
    const head = objects.pairCar(v).*;
    const head_name = objects.symbolName(head);
    const needs_symbol = [_][]const u8{ "module", "import", "package", "defmacro" };
    for (needs_symbol) |n| {
        if (std.mem.eql(u8, head_name, n)) {
            const arg = objects.pairCar(rest).*;
            if (!objects.isSymbol(arg)) return "name must be a symbol";
            return null;
        }
    }
    return null;
}

fn getString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (obj.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}
