//! TUI primitives: raw terminal, event loop, tui-run.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;

const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const errs = @import("../runtime/errors.zig");
const LispError = errs.LispError;

// ── Terminal size ─────────────────────────────────────────────────────────────

const WinSize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

const TIOCGWINSZ: u32 = switch (builtin.os.tag) {
    .macos => 0x40087468,
    else => 0x5413,
};

fn getTermSize() struct { w: u16, h: u16 } {
    var ws: WinSize = std.mem.zeroes(WinSize);
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, TIOCGWINSZ, @intFromPtr(&ws));
    if (rc != 0) return .{ .w = 80, .h = 24 };
    return .{ .w = if (ws.ws_col == 0) 80 else ws.ws_col, .h = if (ws.ws_row == 0) 24 else ws.ws_row };
}

// ── Raw mode ──────────────────────────────────────────────────────────────────

fn enterRawMode(orig: *std.posix.termios) !void {
    orig.* = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    var raw = orig.*;
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, raw);
}

fn exitRawMode(orig: *const std.posix.termios) void {
    std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, orig.*) catch {};
}

// ── Key reading ───────────────────────────────────────────────────────────────

fn readByte() !u8 {
    var b: [1]u8 = undefined;
    const n = try std.posix.read(std.posix.STDIN_FILENO, &b);
    if (n == 0) return error.EndOfStream;
    return b[0];
}

fn readKey(buf: *[16]u8) []const u8 {
    const b = readByte() catch return "ctrl-d";

    if (b == 27) {
        const next = readByte() catch return "escape";
        if (next != '[' and next != 'O') return "escape";
        const third = readByte() catch return "escape";

        if (next == '[') {
            switch (third) {
                'A' => return "up",
                'B' => return "down",
                'C' => return "right",
                'D' => return "left",
                'H' => return "home",
                'F' => return "end",
                '1' => { _ = readByte() catch {}; return "home"; },
                '4' => { _ = readByte() catch {}; return "end"; },
                '5' => { _ = readByte() catch {}; return "page-up"; },
                '6' => { _ = readByte() catch {}; return "page-down"; },
                else => return "unknown",
            }
        } else if (next == 'O') {
            switch (third) {
                'P' => return "f1",
                'Q' => return "f2",
                'R' => return "f3",
                'S' => return "f4",
                else => return "unknown",
            }
        }
        return "escape";
    }

    switch (b) {
        13  => return "enter",
        9   => return "tab",
        127 => return "backspace",
        8   => return "backspace",
        1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26 => {
            buf[0] = 'c'; buf[1] = 't'; buf[2] = 'r'; buf[3] = 'l';
            buf[4] = '-'; buf[5] = 'a' + b - 1;
            return buf[0..6];
        },
        else => {
            buf[0] = b;
            return buf[0..1];
        },
    }
}

// ── Event Value construction ──────────────────────────────────────────────────

fn makeKeyEvent(vm: *VM, key: []const u8) LispError!Value {
    const tag = vm.symbols.intern(":key") catch return error.OutOfMemory;
    const key_str = objects.makeString(vm.gc, key) catch return error.OutOfMemory;
    const inner = objects.makePair(vm.gc, key_str, value_mod.NIL) catch return error.OutOfMemory;
    return objects.makePair(vm.gc, tag, inner) catch return error.OutOfMemory;
}

fn makeResizeEvent(vm: *VM, w: u16, h: u16) LispError!Value {
    const tag = vm.symbols.intern(":resize") catch return error.OutOfMemory;
    const wv = value_mod.fixnum(@intCast(w));
    const hv = value_mod.fixnum(@intCast(h));
    const tail2 = objects.makePair(vm.gc, hv, value_mod.NIL) catch return error.OutOfMemory;
    const tail1 = objects.makePair(vm.gc, wv, tail2) catch return error.OutOfMemory;
    return objects.makePair(vm.gc, tag, tail1) catch return error.OutOfMemory;
}

fn isQuit(v: Value) bool {
    if (!objects.isSymbol(v)) return false;
    return std.mem.eql(u8, objects.symbolName(v), ":quit");
}

// ── Screen output ─────────────────────────────────────────────────────────────

const ALT_ENTER  = "\x1b[?1049h\x1b[?25l";
const ALT_EXIT   = "\x1b[?1049l\x1b[?25h";
const CLEAR      = "\x1b[2J\x1b[H";

fn render(alloc: std.mem.Allocator, screen: []const u8) void {
    const stdout = std.fs.File.stdout();
    stdout.writeAll(CLEAR) catch {};
    // In raw mode \n is LF only — replace with CRLF so lines align left.
    const crlf = std.mem.replaceOwned(u8, alloc, screen, "\n", "\r\n") catch {
        stdout.writeAll(screen) catch {};
        return;
    };
    defer alloc.free(crlf);
    stdout.writeAll(crlf) catch {};
}

// ── Primitives ────────────────────────────────────────────────────────────────

/// (tui-run initial-model update-fn view-fn)
pub fn primTuiRun(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 3) return error.ArityMismatch;

    var model = args[0];
    const update_fn = args[1];
    const view_fn   = args[2];

    if (!objects.isClosure(update_fn) and !objects.isPrim(update_fn)) return error.TypeError;
    if (!objects.isClosure(view_fn)   and !objects.isPrim(view_fn))   return error.TypeError;

    var orig: std.posix.termios = undefined;
    enterRawMode(&orig) catch return error.IOError;
    defer exitRawMode(&orig);

    const stdout = std.fs.File.stdout();
    stdout.writeAll(ALT_ENTER) catch return error.IOError;
    defer stdout.writeAll(ALT_EXIT) catch {};

    var key_buf: [16]u8 = undefined;

    while (true) {
        // Render current model.
        const view_result = vm.callValue(view_fn, &.{model}) catch |e| {
            _ = stdout.writeAll(ALT_EXIT) catch {};
            exitRawMode(&orig);
            return e;
        };
        if (isQuit(view_result)) break;
        if (objects.isString(view_result)) {
            render(vm.allocator, objects.stringBytes(view_result));
        }

        // Read next event.
        const key = readKey(&key_buf);
        const event = try makeKeyEvent(vm, key);

        // Dispatch update.
        const new_model = vm.callValue(update_fn, &.{ model, event }) catch |e| {
            return e;
        };
        if (isQuit(new_model)) break;
        model = new_model;
    }

    return model;
}

/// (tui-screen-size) → (list width height)
pub fn primTuiScreenSize(vm: *VM, args: []const Value) LispError!Value {
    _ = args;
    const sz = getTermSize();
    return makeResizeEvent(vm, sz.w, sz.h);
}
