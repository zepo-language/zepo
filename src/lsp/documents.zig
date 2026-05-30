//! In-memory LSP document store keyed by URI.
//!
//! Documents are versioned text buffers. Analysis results (definitions,
//! imports, references) are computed lazily on demand and cached until the
//! next textual change.
//!
//! zepo-k9hh.

const std = @import("std");

pub const Document = struct {
    uri: []u8,
    text: []u8,
    version: i64 = 0,

    pub fn deinit(d: *Document, alloc: std.mem.Allocator) void {
        alloc.free(d.uri);
        alloc.free(d.text);
    }
};

pub const Store = struct {
    alloc: std.mem.Allocator,
    docs: std.StringHashMapUnmanaged(Document) = .empty,

    pub fn init(alloc: std.mem.Allocator) Store {
        return .{ .alloc = alloc };
    }

    pub fn deinit(s: *Store) void {
        var it = s.docs.iterator();
        while (it.next()) |e| {
            var d = e.value_ptr.*;
            d.deinit(s.alloc);
        }
        s.docs.deinit(s.alloc);
    }

    pub fn open(s: *Store, uri: []const u8, text: []const u8, version: i64) !void {
        const uri_copy = try s.alloc.dupe(u8, uri);
        const text_copy = try s.alloc.dupe(u8, text);
        if (s.docs.getPtr(uri)) |existing| {
            s.alloc.free(existing.text);
            existing.text = text_copy;
            existing.version = version;
            s.alloc.free(uri_copy);
            return;
        }
        try s.docs.put(s.alloc, uri_copy, .{ .uri = uri_copy, .text = text_copy, .version = version });
    }

    pub fn replace(s: *Store, uri: []const u8, text: []const u8, version: i64) !void {
        if (s.docs.getPtr(uri)) |existing| {
            const text_copy = try s.alloc.dupe(u8, text);
            s.alloc.free(existing.text);
            existing.text = text_copy;
            existing.version = version;
            return;
        }
        try s.open(uri, text, version);
    }

    /// zepo-ttk8: incremental edit. Splices `new_text` into the cached
    /// document, replacing bytes [start_off, end_off). Caller is responsible
    /// for converting the LSP Range to byte offsets via the negotiated
    /// PositionEncoding before calling this.
    pub fn applyEdit(
        s: *Store,
        uri: []const u8,
        start_off: usize,
        end_off: usize,
        new_text: []const u8,
        version: i64,
    ) !void {
        const doc = s.docs.getPtr(uri) orelse return error.UnknownDocument;
        const old = doc.text;
        if (start_off > old.len or end_off > old.len or start_off > end_off) {
            return error.InvalidRange;
        }
        const new_len = old.len - (end_off - start_off) + new_text.len;
        const buf = try s.alloc.alloc(u8, new_len);
        @memcpy(buf[0..start_off], old[0..start_off]);
        @memcpy(buf[start_off .. start_off + new_text.len], new_text);
        @memcpy(buf[start_off + new_text.len ..], old[end_off..]);
        s.alloc.free(old);
        doc.text = buf;
        doc.version = version;
    }

    pub fn close(s: *Store, uri: []const u8) void {
        if (s.docs.fetchRemove(uri)) |kv| {
            var d = kv.value;
            d.deinit(s.alloc);
        }
    }

    pub fn get(s: *Store, uri: []const u8) ?*Document {
        return s.docs.getPtr(uri);
    }
};

test "open/replace/close" {
    const t = std.testing;
    var store = Store.init(t.allocator);
    defer store.deinit();

    try store.open("file:///a.lisp", "(define x 1)", 1);
    try t.expectEqualStrings("(define x 1)", store.get("file:///a.lisp").?.text);
    try store.replace("file:///a.lisp", "(define x 2)", 2);
    try t.expectEqual(@as(i64, 2), store.get("file:///a.lisp").?.version);
    store.close("file:///a.lisp");
    try t.expect(store.get("file:///a.lisp") == null);
}
