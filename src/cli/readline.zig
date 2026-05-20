//! Minimal line editor: raw-mode input, persistent history, tab completion.
//! Falls back to plain line reading when stdin is not a TTY.
// zepo-n3h: Zig 0.16 removed std.Io.File; all terminal I/O uses std.c.read/write on fd 0/1.

const std = @import("std");
const posix = std.posix;

extern "c" fn fgets(s: [*]u8, n: c_int, stream: *std.c.FILE) ?[*:0]u8;

const HISTORY_MAX = 500;

/// Callback type for tab completion.
pub const CompleteFn = *const fn (
    prefix: []const u8,
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]u8),
) void;

pub const History = struct {
    entries: std.ArrayListUnmanaged([]u8) = .empty,
    alloc: std.mem.Allocator,
    path: ?[]const u8 = null,

    pub fn init(alloc: std.mem.Allocator, path: ?[]const u8) History {
        return .{ .alloc = alloc, .path = if (path) |p| alloc.dupe(u8, p) catch null else null };
    }

    pub fn deinit(h: *History) void {
        for (h.entries.items) |e| h.alloc.free(e);
        h.entries.deinit(h.alloc);
        if (h.path) |p| h.alloc.free(p);
    }

    pub fn add(h: *History, line: []const u8) !void {
        if (line.len == 0) return;
        if (h.entries.items.len > 0 and
            std.mem.eql(u8, h.entries.items[h.entries.items.len - 1], line)) return;
        if (h.entries.items.len >= HISTORY_MAX) {
            h.alloc.free(h.entries.items[0]);
            _ = h.entries.orderedRemove(0);
        }
        try h.entries.append(h.alloc, try h.alloc.dupe(u8, line));
    }

    pub fn load(h: *History) void {
        const path = h.path orelse return;
        var pbuf: [4096]u8 = undefined;
        if (path.len >= pbuf.len) return;
        @memcpy(pbuf[0..path.len], path);
        pbuf[path.len] = 0;
        const f = std.c.fopen(@ptrCast(&pbuf), "r") orelse return;
        defer _ = std.c.fclose(f);
        var line_buf: [4096]u8 = undefined;
        while (fgets(&line_buf, @intCast(line_buf.len), f) != null) {
            const line = std.mem.sliceTo(&line_buf, 0);
            const t = std.mem.trim(u8, line, "\r\n");
            if (t.len > 0) h.add(t) catch {};
        }
    }

    pub fn save(h: *const History) void {
        const path = h.path orelse return;
        var pbuf: [4096]u8 = undefined;
        if (path.len >= pbuf.len) return;
        @memcpy(pbuf[0..path.len], path);
        pbuf[path.len] = 0;
        const f = std.c.fopen(@ptrCast(&pbuf), "w") orelse return;
        defer _ = std.c.fclose(f);
        for (h.entries.items) |line| {
            _ = std.c.fwrite(line.ptr, 1, line.len, f);
            _ = std.c.fwrite("\n", 1, 1, f);
        }
    }
};

fn writeAll(s: []const u8) void {
    _ = std.c.write(1, s.ptr, s.len);
}

fn readByte() ?u8 {
    var b: u8 = 0;
    const n = std.c.read(0, @as([*]u8, @ptrCast(&b)), 1);
    return if (n == 1) b else null;
}

/// Read one line from stdin.
/// Returns null on EOF (Ctrl-D on empty line) or error.Interrupted (Ctrl-C).
pub fn readLine(
    alloc: std.mem.Allocator,
    prompt: []const u8,
    history: *History,
    complete_ctx: ?*anyopaque,
    complete_fn: ?CompleteFn,
) !?[]u8 {
    // Fallback: not a TTY (pipe / file redirect)
    if (std.c.isatty(0) == 0) {
        var line_buf = std.ArrayListUnmanaged(u8).empty;
        defer line_buf.deinit(alloc);
        while (true) {
            const b = readByte() orelse {
                if (line_buf.items.len == 0) return null;
                break;
            };
            if (b == '\n') break;
            if (b == '\r') continue;
            try line_buf.append(alloc, b);
        }
        return try line_buf.toOwnedSlice(alloc);
    }

    // Enter raw mode.
    const orig = try posix.tcgetattr(0);
    var raw = orig;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.oflag.OPOST = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(0, .FLUSH, raw);
    defer posix.tcsetattr(0, .FLUSH, orig) catch {};

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(alloc);
    var cursor: usize = 0;

    const hist_base = history.entries.items.len;
    var hist_pos: usize = hist_base;
    var saved_input: std.ArrayListUnmanaged(u8) = .empty;
    defer saved_input.deinit(alloc);

    writeAll(prompt);

    while (true) {
        const c = readByte() orelse return null;

        switch (c) {
            '\r', '\n' => {
                writeAll("\r\n");
                return try alloc.dupe(u8, line_buf.items);
            },
            // Ctrl-D
            4 => {
                if (line_buf.items.len == 0) {
                    writeAll("\r\n");
                    return null;
                }
                if (cursor < line_buf.items.len) {
                    std.mem.copyForwards(u8, line_buf.items[cursor..], line_buf.items[cursor + 1 ..]);
                    line_buf.shrinkRetainingCapacity(line_buf.items.len - 1);
                    refresh(prompt, line_buf.items, cursor);
                }
            },
            // Ctrl-C
            3 => {
                writeAll("^C\r\n");
                return error.Interrupted;
            },
            // Backspace / Ctrl-H
            127, 8 => {
                if (cursor > 0) {
                    std.mem.copyForwards(u8, line_buf.items[cursor - 1 ..], line_buf.items[cursor..]);
                    line_buf.shrinkRetainingCapacity(line_buf.items.len - 1);
                    cursor -= 1;
                    refresh(prompt, line_buf.items, cursor);
                }
            },
            1 => { cursor = 0; refresh(prompt, line_buf.items, cursor); },           // Ctrl-A
            5 => { cursor = line_buf.items.len; refresh(prompt, line_buf.items, cursor); }, // Ctrl-E
            11 => { line_buf.shrinkRetainingCapacity(cursor); refresh(prompt, line_buf.items, cursor); }, // Ctrl-K
            12 => { writeAll("\x1b[2J\x1b[H"); refresh(prompt, line_buf.items, cursor); }, // Ctrl-L
            // Tab — completion
            9 => {
                if (complete_fn) |cfn| {
                    const word = currentWord(line_buf.items[0..cursor]);
                    var matches: std.ArrayListUnmanaged([]u8) = .empty;
                    defer {
                        for (matches.items) |m| alloc.free(m);
                        matches.deinit(alloc);
                    }
                    cfn(word, complete_ctx, alloc, &matches);
                    if (matches.items.len == 1) {
                        const suffix = matches.items[0][word.len..];
                        try line_buf.insertSlice(alloc, cursor, suffix);
                        cursor += suffix.len;
                        refresh(prompt, line_buf.items, cursor);
                    } else if (matches.items.len > 1) {
                        writeAll("\r\n");
                        for (matches.items) |m| {
                            writeAll(m);
                            writeAll("  ");
                        }
                        writeAll("\r\n");
                        refresh(prompt, line_buf.items, cursor);
                    }
                }
            },
            // Escape sequence
            '\x1b' => {
                var seq: [3]u8 = undefined;
                const sn = std.c.read(0, &seq, 2);
                if (sn < 2 or seq[0] != '[') continue;
                switch (seq[1]) {
                    'A' => { // Up
                        if (hist_pos == hist_base) {
                            saved_input.clearRetainingCapacity();
                            try saved_input.appendSlice(alloc, line_buf.items);
                        }
                        if (hist_pos > 0) {
                            hist_pos -= 1;
                            line_buf.clearRetainingCapacity();
                            try line_buf.appendSlice(alloc, history.entries.items[hist_pos]);
                            cursor = line_buf.items.len;
                            refresh(prompt, line_buf.items, cursor);
                        }
                    },
                    'B' => { // Down
                        if (hist_pos < hist_base) {
                            hist_pos += 1;
                            line_buf.clearRetainingCapacity();
                            if (hist_pos == hist_base) {
                                try line_buf.appendSlice(alloc, saved_input.items);
                            } else {
                                try line_buf.appendSlice(alloc, history.entries.items[hist_pos]);
                            }
                            cursor = line_buf.items.len;
                            refresh(prompt, line_buf.items, cursor);
                        }
                    },
                    'C' => { if (cursor < line_buf.items.len) { cursor += 1; refresh(prompt, line_buf.items, cursor); } },
                    'D' => { if (cursor > 0) { cursor -= 1; refresh(prompt, line_buf.items, cursor); } },
                    'H' => { cursor = 0; refresh(prompt, line_buf.items, cursor); },
                    'F' => { cursor = line_buf.items.len; refresh(prompt, line_buf.items, cursor); },
                    '3' => {
                        _ = std.c.read(0, seq[2..3].ptr, 1);
                        if (cursor < line_buf.items.len) {
                            std.mem.copyForwards(u8, line_buf.items[cursor..], line_buf.items[cursor + 1 ..]);
                            line_buf.shrinkRetainingCapacity(line_buf.items.len - 1);
                            refresh(prompt, line_buf.items, cursor);
                        }
                    },
                    else => {},
                }
            },
            32...126 => {
                try line_buf.insert(alloc, cursor, c);
                cursor += 1;
                refresh(prompt, line_buf.items, cursor);
            },
            else => {},
        }
    }
}

fn refresh(prompt: []const u8, buf: []const u8, cursor: usize) void {
    writeAll("\r");
    writeAll(prompt);
    writeAll(buf);
    writeAll("\x1b[K");
    const tail = buf.len - cursor;
    if (tail > 0) {
        var tmp: [32]u8 = undefined;
        const mv = std.fmt.bufPrint(&tmp, "\x1b[{d}D", .{tail}) catch return;
        writeAll(mv);
    }
}

fn currentWord(s: []const u8) []const u8 {
    var i = s.len;
    while (i > 0 and s[i - 1] != ' ' and s[i - 1] != '(' and s[i - 1] != '\t') i -= 1;
    return s[i..];
}
