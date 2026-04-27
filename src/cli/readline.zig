//! Minimal line editor: raw-mode input, persistent history, tab completion.
//! Falls back to plain line reading when stdin is not a TTY.

const std = @import("std");
const posix = std.posix;

const HISTORY_MAX = 500;

/// Callback type for tab completion.
/// Given the current word prefix, appends matching completions to `out`.
/// Strings appended to `out` must be valid for the duration of the call;
/// readline will free them with `alloc` after use.
pub const CompleteFn = *const fn (
    prefix: []const u8,
    ctx: ?*anyopaque,
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged([]u8),
) void;

pub const History = struct {
    entries: std.ArrayListUnmanaged([]u8) = .{},
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
        const f = std.fs.openFileAbsolute(path, .{}) catch return;
        defer f.close();
        var buf: [4096]u8 = undefined;
        var fr = f.reader(&buf);
        const r = &fr.interface;
        while (true) {
            const line = r.takeDelimiter('\n') catch break orelse break;
            const t = std.mem.trim(u8, line, "\r\n");
            if (t.len > 0) h.add(t) catch {};
        }
    }

    pub fn save(h: *const History) void {
        const path = h.path orelse return;
        const f = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return;
        defer f.close();
        for (h.entries.items) |line| {
            f.writeAll(line) catch {};
            f.writeAll("\n") catch {};
        }
    }
};

/// Read one line from stdin.
/// Returns null on EOF (Ctrl-D on empty line) or error.Interrupted (Ctrl-C).
/// Returned slice is caller-owned (allocated with `alloc`).
pub fn readLine(
    alloc: std.mem.Allocator,
    prompt: []const u8,
    history: *History,
    complete_ctx: ?*anyopaque,
    complete_fn: ?CompleteFn,
) !?[]u8 {
    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    // Fallback: not a TTY (pipe / file redirect)
    if (!posix.isatty(stdin.handle)) {
        var buf: [4096]u8 = undefined;
        var fr = stdin.reader(&buf);
        const line = (try fr.interface.takeDelimiter('\n')) orelse return null;
        return try alloc.dupe(u8, std.mem.trimRight(u8, line, "\r\n"));
    }

    // Enter raw mode.
    const orig = try posix.tcgetattr(stdin.handle);
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
    try posix.tcsetattr(stdin.handle, .FLUSH, raw);
    defer posix.tcsetattr(stdin.handle, .FLUSH, orig) catch {};

    var line_buf: std.ArrayListUnmanaged(u8) = .{};
    defer line_buf.deinit(alloc);
    var cursor: usize = 0;

    // History navigation: hist_pos == history.entries.len means "current input"
    const hist_base = history.entries.items.len;
    var hist_pos: usize = hist_base;
    var saved_input: std.ArrayListUnmanaged(u8) = .{};
    defer saved_input.deinit(alloc);

    try stdout.writeAll(prompt);

    while (true) {
        var ch: [1]u8 = undefined;
        const n = try stdin.read(&ch);
        if (n == 0) return null;
        const c = ch[0];

        switch (c) {
            '\r', '\n' => {
                try stdout.writeAll("\r\n");
                const result = try alloc.dupe(u8, line_buf.items);
                return result;
            },
            // Ctrl-D
            4 => {
                if (line_buf.items.len == 0) {
                    try stdout.writeAll("\r\n");
                    return null;
                }
                // Delete forward
                if (cursor < line_buf.items.len) {
                    const rest = line_buf.items.len - cursor;
                    std.mem.copyForwards(u8, line_buf.items[cursor..], line_buf.items[cursor + 1 ..]);
                    line_buf.shrinkRetainingCapacity(line_buf.items.len - 1);
                    _ = rest;
                    try refresh(stdout, prompt, line_buf.items, cursor);
                }
            },
            // Ctrl-C
            3 => {
                try stdout.writeAll("^C\r\n");
                return error.Interrupted;
            },
            // Backspace / Ctrl-H
            127, 8 => {
                if (cursor > 0) {
                    std.mem.copyForwards(u8, line_buf.items[cursor - 1 ..], line_buf.items[cursor..]);
                    line_buf.shrinkRetainingCapacity(line_buf.items.len - 1);
                    cursor -= 1;
                    try refresh(stdout, prompt, line_buf.items, cursor);
                }
            },
            // Ctrl-A
            1 => {
                cursor = 0;
                try refresh(stdout, prompt, line_buf.items, cursor);
            },
            // Ctrl-E
            5 => {
                cursor = line_buf.items.len;
                try refresh(stdout, prompt, line_buf.items, cursor);
            },
            // Ctrl-K
            11 => {
                line_buf.shrinkRetainingCapacity(cursor);
                try refresh(stdout, prompt, line_buf.items, cursor);
            },
            // Ctrl-L — clear screen
            12 => {
                try stdout.writeAll("\x1b[2J\x1b[H");
                try refresh(stdout, prompt, line_buf.items, cursor);
            },
            // Tab — completion
            9 => {
                if (complete_fn) |cfn| {
                    const word = currentWord(line_buf.items[0..cursor]);
                    var matches: std.ArrayListUnmanaged([]u8) = .{};
                    defer {
                        for (matches.items) |m| alloc.free(m);
                        matches.deinit(alloc);
                    }
                    cfn(word, complete_ctx, alloc, &matches);
                    if (matches.items.len == 1) {
                        // Single match: complete in place
                        const suffix = matches.items[0][word.len..];
                        const insert_pos = cursor;
                        try line_buf.insertSlice(alloc, insert_pos, suffix);
                        cursor += suffix.len;
                        try refresh(stdout, prompt, line_buf.items, cursor);
                    } else if (matches.items.len > 1) {
                        // Multiple: show list
                        try stdout.writeAll("\r\n");
                        for (matches.items) |m| {
                            try stdout.writeAll(m);
                            try stdout.writeAll("  ");
                        }
                        try stdout.writeAll("\r\n");
                        try refresh(stdout, prompt, line_buf.items, cursor);
                    }
                }
            },
            // Escape sequence
            '\x1b' => {
                var seq: [3]u8 = undefined;
                const sn = stdin.read(seq[0..2]) catch 0;
                if (sn < 2 or seq[0] != '[') continue;
                switch (seq[1]) {
                    'A' => { // Up — history prev
                        if (hist_pos == hist_base) {
                            saved_input.clearRetainingCapacity();
                            try saved_input.appendSlice(alloc, line_buf.items);
                        }
                        if (hist_pos > 0) {
                            hist_pos -= 1;
                            line_buf.clearRetainingCapacity();
                            try line_buf.appendSlice(alloc, history.entries.items[hist_pos]);
                            cursor = line_buf.items.len;
                            try refresh(stdout, prompt, line_buf.items, cursor);
                        }
                    },
                    'B' => { // Down — history next
                        if (hist_pos < hist_base) {
                            hist_pos += 1;
                            line_buf.clearRetainingCapacity();
                            if (hist_pos == hist_base) {
                                try line_buf.appendSlice(alloc, saved_input.items);
                            } else {
                                try line_buf.appendSlice(alloc, history.entries.items[hist_pos]);
                            }
                            cursor = line_buf.items.len;
                            try refresh(stdout, prompt, line_buf.items, cursor);
                        }
                    },
                    'C' => { // Right
                        if (cursor < line_buf.items.len) {
                            cursor += 1;
                            try refresh(stdout, prompt, line_buf.items, cursor);
                        }
                    },
                    'D' => { // Left
                        if (cursor > 0) {
                            cursor -= 1;
                            try refresh(stdout, prompt, line_buf.items, cursor);
                        }
                    },
                    'H' => { // Home
                        cursor = 0;
                        try refresh(stdout, prompt, line_buf.items, cursor);
                    },
                    'F' => { // End
                        cursor = line_buf.items.len;
                        try refresh(stdout, prompt, line_buf.items, cursor);
                    },
                    '3' => { // Delete (3~)
                        _ = stdin.read(seq[2..3]) catch {};
                        if (cursor < line_buf.items.len) {
                            std.mem.copyForwards(u8, line_buf.items[cursor..], line_buf.items[cursor + 1 ..]);
                            line_buf.shrinkRetainingCapacity(line_buf.items.len - 1);
                            try refresh(stdout, prompt, line_buf.items, cursor);
                        }
                    },
                    else => {},
                }
            },
            // Printable characters
            32...126 => {
                try line_buf.insert(alloc, cursor, c);
                cursor += 1;
                try refresh(stdout, prompt, line_buf.items, cursor);
            },
            else => {},
        }
    }
}

fn refresh(stdout: std.fs.File, prompt: []const u8, buf: []const u8, cursor: usize) !void {
    // \r: go to col 0, write prompt + buf, clear to EOL, reposition cursor.
    try stdout.writeAll("\r");
    try stdout.writeAll(prompt);
    try stdout.writeAll(buf);
    try stdout.writeAll("\x1b[K"); // clear to end of line
    // Move cursor left by (buf.len - cursor) positions
    const tail = buf.len - cursor;
    if (tail > 0) {
        var tmp: [32]u8 = undefined;
        const mv = try std.fmt.bufPrint(&tmp, "\x1b[{d}D", .{tail});
        try stdout.writeAll(mv);
    }
}

fn currentWord(s: []const u8) []const u8 {
    // Return the last whitespace-delimited token (the prefix to complete).
    var i = s.len;
    while (i > 0 and s[i - 1] != ' ' and s[i - 1] != '(' and s[i - 1] != '\t') i -= 1;
    return s[i..];
}
