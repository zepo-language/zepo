//! LSP JSON-RPC framing and tiny JSON encoder helpers.
//!
//! Wire format: each message is prefixed by `Content-Length: N\r\n\r\n`
//! followed by exactly N bytes of UTF-8 JSON.
//!
//! Reading uses byte-at-a-time `std.c.read` because LSP clients can issue
//! several messages back-to-back without flushing; we cannot assume any
//! particular buffer alignment from a higher-level reader.
//!
//! zepo-k9hh.

const std = @import("std");

pub const MAX_MSG_SIZE: usize = 8 * 1024 * 1024;

pub const FrameError = error{
    EndOfStream,
    MessageTooLarge,
    OutOfMemory,
};

pub const Reader = struct {
    read_fn: *const fn (ctx: *anyopaque, buf: []u8) isize,
    ctx: *anyopaque,

    pub fn readByte(r: Reader) ?u8 {
        var b: [1]u8 = undefined;
        const n = r.read_fn(r.ctx, &b);
        if (n <= 0) return null;
        return b[0];
    }

    pub fn readExact(r: Reader, buf: []u8) bool {
        var got: usize = 0;
        while (got < buf.len) {
            const n = r.read_fn(r.ctx, buf[got..]);
            if (n <= 0) return false;
            got += @intCast(n);
        }
        return true;
    }
};

pub const Writer = struct {
    write_fn: *const fn (ctx: *anyopaque, buf: []const u8) void,
    ctx: *anyopaque,

    pub fn writeAll(w: Writer, buf: []const u8) void {
        w.write_fn(w.ctx, buf);
    }
};

/// Read one framed LSP message body. Caller owns the returned slice.
pub fn readMessage(alloc: std.mem.Allocator, reader: Reader) FrameError![]u8 {
    var content_length: usize = 0;
    var line_buf: [4096]u8 = undefined;

    while (true) {
        const line = readLine(reader, &line_buf) orelse return FrameError.EndOfStream;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) break;
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            const val = std.mem.trim(u8, trimmed["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, val, 10) catch continue;
        }
    }

    if (content_length == 0) return FrameError.EndOfStream;
    if (content_length > MAX_MSG_SIZE) return FrameError.MessageTooLarge;

    const body = try alloc.alloc(u8, content_length);
    if (!reader.readExact(body)) {
        alloc.free(body);
        return FrameError.EndOfStream;
    }
    return body;
}

fn readLine(reader: Reader, buf: []u8) ?[]u8 {
    var i: usize = 0;
    while (i < buf.len) {
        const b = reader.readByte() orelse return if (i > 0) buf[0..i] else null;
        buf[i] = b;
        i += 1;
        if (b == '\n') return buf[0..i];
    }
    return buf[0..i];
}

/// Write a framed JSON body to `writer`.
pub fn writeMessage(writer: Writer, body: []const u8) void {
    var hbuf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&hbuf, "Content-Length: {d}\r\n\r\n", .{body.len}) catch return;
    writer.writeAll(header);
    writer.writeAll(body);
}

/// Append `s` to `out` as a JSON-escaped string literal (no surrounding quotes).
pub fn escapeJsonInto(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
            var buf: [8]u8 = undefined;
            const esc = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch continue;
            try out.appendSlice(alloc, esc);
        },
        else => try out.append(alloc, c),
    };
}

pub fn idToJson(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, id: std.json.Value) !void {
    var buf: [64]u8 = undefined;
    switch (id) {
        .integer => |n| {
            const s = try std.fmt.bufPrint(&buf, "{d}", .{n});
            try out.appendSlice(alloc, s);
        },
        .float => |f| {
            const s = try std.fmt.bufPrint(&buf, "{d}", .{f});
            try out.appendSlice(alloc, s);
        },
        .string => |s| {
            try out.append(alloc, '"');
            try escapeJsonInto(out, alloc, s);
            try out.append(alloc, '"');
        },
        else => try out.appendSlice(alloc, "null"),
    }
}

test "frame round-trip" {
    const t = std.testing;
    const alloc = t.allocator;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    const TestWriter = struct {
        list: *std.ArrayListUnmanaged(u8),
        a: std.mem.Allocator,
        fn write(ctx: *anyopaque, b: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.list.appendSlice(self.a, b) catch {};
        }
    };
    var tw = TestWriter{ .list = &buf, .a = alloc };
    const w = Writer{ .write_fn = TestWriter.write, .ctx = &tw };
    writeMessage(w, "{\"hi\":1}");

    try t.expect(std.mem.indexOf(u8, buf.items, "Content-Length: 8") != null);
    try t.expect(std.mem.endsWith(u8, buf.items, "{\"hi\":1}"));
}
