//! I/O primitives: display, newline.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const hashtable = runtime.hashtable; // zepo-fa3a

const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const errs = @import("../runtime/errors.zig");
const net_prims = @import("net.zig");
const regex_prims = @import("regex.zig");
const process_prims = @import("process.zig"); // zepo-wgt
const LispError = errs.LispError;

// zepo-s2o4: bounds recursion when rendering cyclic or pathologically deep
// structures, so a self-referential value (e.g. a vector holding itself, made
// via vector-set!/hash-set!) cannot overflow the native stack and crash the
// VM. Tracks the chain of container pointers currently being rendered — the
// ancestors on the recursion path; revisiting one is a cycle. A full stack is
// treated as "too deep". No allocation. List/vector spines are already
// iterated, so this only bounds nesting depth, not element count.
pub const RENDER_MAX_DEPTH = 256;
pub const RenderGuard = struct {
    ancestors: [RENDER_MAX_DEPTH]Value = undefined,
    depth: usize = 0,

    /// True if `v` is already an ancestor (cycle) or the depth cap is reached —
    /// the caller emits a marker and does NOT recurse. Otherwise pushes `v`;
    /// caller must pair a successful push with pop().
    pub fn push(g: *RenderGuard, v: Value) bool {
        if (g.depth >= RENDER_MAX_DEPTH) return true;
        var i: usize = 0;
        while (i < g.depth) : (i += 1) {
            if (g.ancestors[i] == v) return true;
        }
        g.ancestors[g.depth] = v;
        g.depth += 1;
        return false;
    }
    pub fn pop(g: *RenderGuard) void {
        g.depth -= 1;
    }
};

const CYCLE_MARKER = "...";

/// Render `v` into `out` as an appendable stream of bytes.
pub fn displayValue(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: Value) !void {
    var guard = RenderGuard{};
    return displayInner(out, allocator, v, &guard);
}

fn displayInner(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: Value, guard: *RenderGuard) !void {
    if (value_mod.isNil(v)) {
        try out.appendSlice(allocator, "()");
        return;
    }
    // zepo-s4p
    if (value_mod.isEof(v)) {
        try out.appendSlice(allocator, "#<eof>");
        return;
    }
    if (v == value_mod.TRUE) {
        try out.appendSlice(allocator, "#t");
        return;
    }
    if (v == value_mod.FALSE) {
        try out.appendSlice(allocator, "#f");
        return;
    }
    if (value_mod.isFixnum(v)) {
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "{d}", .{value_mod.fixnumVal(v)});
        try out.appendSlice(allocator, s);
        return;
    }
    if (value_mod.isChar(v)) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(value_mod.charVal(v), &buf) catch 1;
        try out.appendSlice(allocator, buf[0..n]);
        return;
    }
    if (value_mod.isPtr(v)) {
        if (objects.isFloat(v)) {
            var buf: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{objects.floatVal(v)});
            try out.appendSlice(allocator, s);
            return;
        }
        if (objects.isString(v)) {
            try out.appendSlice(allocator, objects.stringBytes(v));
            return;
        }
        if (objects.isSymbol(v)) {
            try out.appendSlice(allocator, objects.symbolName(v));
            return;
        }
        if (objects.isPair(v)) {
            if (guard.push(v)) { // zepo-s2o4
                try out.appendSlice(allocator, CYCLE_MARKER);
                return;
            }
            defer guard.pop();
            try out.appendSlice(allocator, "(");
            var cur = v;
            var first = true;
            while (true) {
                if (!first) try out.appendSlice(allocator, " ");
                first = false;
                try displayInner(out, allocator, objects.pairCar(cur).*, guard);
                const rest = objects.pairCdr(cur).*;
                if (value_mod.isNil(rest)) break;
                if (!objects.isPair(rest)) {
                    try out.appendSlice(allocator, " . ");
                    try displayInner(out, allocator, rest, guard);
                    break;
                }
                cur = rest;
            }
            try out.appendSlice(allocator, ")");
            return;
        }
        if (objects.isVector(v)) {
            if (guard.push(v)) { // zepo-s2o4
                try out.appendSlice(allocator, CYCLE_MARKER);
                return;
            }
            defer guard.pop();
            try out.appendSlice(allocator, "#(");
            const len = objects.vectorLen(v);
            for (0..len) |i| {
                if (i > 0) try out.append(allocator, ' ');
                try displayInner(out, allocator, objects.vectorGet(v, i), guard);
            }
            try out.append(allocator, ')');
            return;
        }
        if (objects.isClosure(v)) {
            try out.appendSlice(allocator, "#<closure>");
            return;
        }
        if (objects.isPrim(v)) {
            try out.appendSlice(allocator, "#<primitive>");
            return;
        }
        if (objects.isParameter(v)) { // zepo-6o3p
            try out.appendSlice(allocator, "#<parameter>");
            return;
        }
        // zepo-fa3a: render the remaining heap kinds instead of #<unknown>.
        if (hashtable.isHashTable(v)) {
            var b: [40]u8 = undefined;
            const s = try std.fmt.bufPrint(&b, "#<hash-table {d}>", .{hashtable.size(v)});
            try out.appendSlice(allocator, s);
            return;
        }
        if (objects.isBytevector(v)) {
            try out.appendSlice(allocator, "#u8(");
            const bytes = objects.bytevectorBytes(v);
            for (bytes, 0..) |byte, i| {
                if (i > 0) try out.append(allocator, ' ');
                var nb: [3]u8 = undefined;
                const s = try std.fmt.bufPrint(&nb, "{d}", .{byte});
                try out.appendSlice(allocator, s);
            }
            try out.append(allocator, ')');
            return;
        }
        if (objects.isFiber(v)) {
            const label = switch (objects.fiberStatus(v)) {
                objects.FIBER_RUNNING => "#<fiber running>",
                objects.FIBER_DONE => "#<fiber done>",
                objects.FIBER_ERRORED => "#<fiber errored>",
                else => "#<fiber>",
            };
            try out.appendSlice(allocator, label);
            return;
        }
        if (objects.isBox(v)) {
            try out.appendSlice(allocator, "#<box>");
            return;
        }
        if (objects.isEnvFrame(v)) {
            try out.appendSlice(allocator, "#<env-frame>");
            return;
        }
        // isForeign already guards isPtr (isKind), so the outer isPtr test above
        // is the only one needed — no redundant re-check.
        if (objects.isForeign(v)) {
            const tag = objects.foreignTypeTag(v);
            if (tag == net_prims.TAG_TCP_CONN) {
                try out.appendSlice(allocator, "#<tcp-socket>");
                return;
            }
            if (tag == net_prims.TAG_TCP_SERVER) {
                try out.appendSlice(allocator, "#<tcp-server>");
                return;
            }
            if (tag == regex_prims.TAG_REGEX) {
                try out.appendSlice(allocator, "#<regex>");
                return;
            }
            if (tag == TAG_STRING_PORT) {
                try out.appendSlice(allocator, "#<string-port>");
                return;
            }
            // zepo-s4p
            if (tag == TAG_INPUT_PORT) {
                try out.appendSlice(allocator, "#<input-port>");
                return;
            }
            // zepo-wgt
            if (tag == process_prims.TAG_PROCESS) {
                const pp: *process_prims.ProcessPayload = @alignCast(@ptrCast(objects.foreignPayload(v)));
                const s = try std.fmt.allocPrint(allocator, "#<process:{d}>", .{pp.pid});
                defer allocator.free(s);
                try out.appendSlice(allocator, s);
                return;
            }
            try out.appendSlice(allocator, "#<foreign>");
            return;
        }
    }
    try out.appendSlice(allocator, "#<unknown>");
}

fn writeToStdout(bytes: []const u8) void {
    _ = std.c.write(1, bytes.ptr, bytes.len);
}

pub fn primDisplay(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(vm.allocator);
    displayValue(&buf, vm.allocator, args[0]) catch return error.OutOfMemory;
    writeToStdout(buf.items);
    return value_mod.NIL;
}

pub fn primNewline(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 0) return error.ArityMismatch;
    writeToStdout("\n");
    return value_mod.NIL;
}

pub fn writeValue(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: Value) !void {
    var guard = RenderGuard{};
    return writeInner(out, allocator, v, &guard);
}

fn writeInner(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: Value, guard: *RenderGuard) !void {
    if (value_mod.isChar(v)) {
        const cp = value_mod.charVal(v);
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch 1;
        try out.appendSlice(allocator, "#\\");
        try out.appendSlice(allocator, buf[0..n]);
        return;
    }
    if (value_mod.isPtr(v) and objects.isString(v)) {
        try out.append(allocator, '"');
        for (objects.stringBytes(v)) |b| {
            if (b == '"' or b == '\\') try out.append(allocator, '\\');
            try out.append(allocator, b);
        }
        try out.append(allocator, '"');
        return;
    }
    if (value_mod.isPtr(v) and objects.isPair(v)) {
        if (guard.push(v)) { // zepo-s2o4
            try out.appendSlice(allocator, CYCLE_MARKER);
            return;
        }
        defer guard.pop();
        try out.append(allocator, '(');
        var cur = v;
        var first = true;
        while (true) {
            if (!first) try out.append(allocator, ' ');
            first = false;
            try writeInner(out, allocator, objects.pairCar(cur).*, guard);
            const rest = objects.pairCdr(cur).*;
            if (value_mod.isNil(rest)) break;
            if (!objects.isPair(rest)) {
                try out.appendSlice(allocator, " . ");
                try writeInner(out, allocator, rest, guard);
                break;
            }
            cur = rest;
        }
        try out.append(allocator, ')');
        return;
    }
    if (value_mod.isPtr(v) and objects.isVector(v)) {
        if (guard.push(v)) { // zepo-s2o4
            try out.appendSlice(allocator, CYCLE_MARKER);
            return;
        }
        defer guard.pop();
        try out.appendSlice(allocator, "#(");
        const len = objects.vectorLen(v);
        for (0..len) |i| {
            if (i > 0) try out.append(allocator, ' ');
            try writeInner(out, allocator, objects.vectorGet(v, i), guard);
        }
        try out.append(allocator, ')');
        return;
    }
    // zepo-s2o4: leaves (symbols, numbers, hashtables rendered non-recursively)
    // — share the guard so depth accounting is continuous across write→display.
    try displayInner(out, allocator, v, guard);
}

pub fn primWrite(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(vm.allocator);
    writeValue(&buf, vm.allocator, args[0]) catch return error.OutOfMemory;
    writeToStdout(buf.items);
    return value_mod.NIL;
}

pub fn primDisplayToString(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(vm.allocator);
    displayValue(&buf, vm.allocator, args[0]) catch return error.OutOfMemory;
    return objects.makeString(vm.gc, buf.items) catch return error.OutOfMemory;
}

pub fn primWriteToString(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(vm.allocator);
    writeValue(&buf, vm.allocator, args[0]) catch return error.OutOfMemory;
    return objects.makeString(vm.gc, buf.items) catch return error.OutOfMemory;
}

/// zepo-axm: native (format fmt . args). Mirrors the Lisp module impl
/// but writes directly into one buffer — no per-char cons, no reverse,
/// no string-append. Directives:
///   ~a → display   ~s → write   ~% → newline   ~~ → literal tilde
pub fn primFormat(vm: *VM, args: []const Value) LispError!Value {
    if (args.len < 1) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    const fmt = objects.stringBytes(args[0]);

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(vm.allocator);
    buf.ensureUnusedCapacity(vm.allocator, fmt.len) catch return error.OutOfMemory;

    var ai: usize = 1; // index into args (skip fmt)
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        const c = fmt[i];
        if (c != '~') {
            buf.append(vm.allocator, c) catch return error.OutOfMemory;
            continue;
        }
        i += 1;
        if (i >= fmt.len) {
            std.debug.print("error: format: incomplete directive at end of string\n", .{});
            return error.InvalidForm;
        }
        switch (fmt[i]) {
            'a' => {
                if (ai >= args.len) {
                    std.debug.print("error: format: not enough arguments for ~a\n", .{});
                    return error.ArityMismatch;
                }
                displayValue(&buf, vm.allocator, args[ai]) catch return error.OutOfMemory;
                ai += 1;
            },
            's' => {
                if (ai >= args.len) {
                    std.debug.print("error: format: not enough arguments for ~s\n", .{});
                    return error.ArityMismatch;
                }
                writeValue(&buf, vm.allocator, args[ai]) catch return error.OutOfMemory;
                ai += 1;
            },
            '%' => buf.append(vm.allocator, '\n') catch return error.OutOfMemory,
            '~' => buf.append(vm.allocator, '~') catch return error.OutOfMemory,
            else => {
                std.debug.print("error: format: unknown directive ~{c}\n", .{fmt[i]});
                return error.InvalidForm;
            },
        }
    }
    return objects.makeString(vm.gc, buf.items) catch return error.OutOfMemory;
}

// zepo-8e6: read a line from stdin; returns the line as a string (newline stripped),
// or #f on EOF.
// zepo-s4p: extended to accept optional port argument.
pub fn primReadLine(vm: *VM, args: []const Value) LispError!Value {
    if (args.len > 1) return error.ArityMismatch;
    if (args.len == 1) {
        // Port variant
        const port = args[0];
        if (!isInputPort(port)) return error.TypeError;
        const file = inputPortFile(port);
        return readLineFromFile(vm, file);
    }
    // Stdin variant (original behaviour)
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(vm.allocator);
    var b: u8 = 0;
    while (true) {
        const n = std.c.read(0, @as([*]u8, @ptrCast(&b)), 1);
        if (n <= 0) {
            if (buf.items.len == 0) return value_mod.EOF_VAL;
            break;
        }
        if (b == '\n') break;
        buf.append(vm.allocator, b) catch return error.OutOfMemory;
    }
    return objects.makeString(vm.gc, buf.items) catch return error.OutOfMemory;
}

pub fn primExit(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    const code: u8 = if (args.len >= 1 and value_mod.isFixnum(args[0]))
        @intCast(@max(0, @min(255, value_mod.fixnumVal(args[0]))))
    else
        0;
    std.process.exit(code);
}

/// Set by main.zig before running user code so (argv) returns program-level
/// args rather than the raw zepo invocation (strips "zepo", "run", "--repl" etc).
pub var program_argv: ?[]const []const u8 = null;

pub fn primArgv(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 0) return error.ArityMismatch;
    if (program_argv) |pargs| {
        var result: Value = value_mod.NIL;
        var i: usize = pargs.len;
        while (i > 0) {
            i -= 1;
            const sv = objects.makeString(vm.gc, pargs[i]) catch return error.OutOfMemory;
            result = objects.makePair(vm.gc, sv, result) catch return error.OutOfMemory;
        }
        return result;
    }
    return value_mod.NIL; // no argv available outside program_argv path
}

// ── String output ports ───────────────────────────────────────────────────────

pub const TAG_STRING_PORT: u64 = 0x73747270; // "strp"

const StringPort = struct {
    buf: std.ArrayList(u8),
    allocator: std.mem.Allocator,
};

fn deinitStringPort(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const sp: *StringPort = @alignCast(@ptrCast(p));
        sp.buf.deinit(sp.allocator);
        sp.allocator.destroy(sp);
    }
}

fn isStringPort(v: Value) bool {
    return value_mod.isPtr(v) and objects.isForeign(v) and
        objects.foreignTypeTag(v) == TAG_STRING_PORT;
}

pub fn primOpenOutputString(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 0) return error.ArityMismatch;
    const sp = vm.allocator.create(StringPort) catch return error.OutOfMemory;
    sp.* = .{ .buf = .empty, .allocator = vm.allocator };
    return objects.makeForeign(vm.gc, sp, deinitStringPort, TAG_STRING_PORT) catch return error.OutOfMemory;
}

pub fn primStringPortQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    return if (isStringPort(args[0])) value_mod.TRUE else value_mod.FALSE;
}

pub fn primGetOutputString(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isStringPort(args[0])) return error.TypeError;
    const sp: *StringPort = @alignCast(@ptrCast(objects.foreignPayload(args[0])));
    return objects.makeString(vm.gc, sp.buf.items) catch return error.OutOfMemory;
}

pub fn primPortDisplay(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!isStringPort(args[0])) return error.TypeError;
    const sp: *StringPort = @alignCast(@ptrCast(objects.foreignPayload(args[0])));
    displayValue(&sp.buf, sp.allocator, args[1]) catch return error.OutOfMemory;
    return value_mod.NIL;
}

pub fn primPortWrite(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 2) return error.ArityMismatch;
    if (!isStringPort(args[0])) return error.TypeError;
    const sp: *StringPort = @alignCast(@ptrCast(objects.foreignPayload(args[0])));
    writeValue(&sp.buf, sp.allocator, args[1]) catch return error.OutOfMemory;
    return value_mod.NIL;
}

// ── Input Ports ───────────────────────────────────────────────────────────────
// zepo-s4p

pub const TAG_INPUT_PORT: u64 = 0x696E7074; // "inpt"

extern "c" fn fgets(s: [*]u8, n: c_int, stream: *std.c.FILE) ?[*:0]u8;
extern "c" fn fgetc(stream: *std.c.FILE) c_int;
extern "c" fn ungetc(c: c_int, stream: *std.c.FILE) c_int;

const EOF_C: c_int = -1;

const InputPortPayload = struct {
    file: *std.c.FILE,
    owned: bool,
    allocator: std.mem.Allocator,
};

fn deinitInputPortFull(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const pd: *InputPortPayload = @alignCast(@ptrCast(p));
        if (pd.owned) {
            _ = std.c.fclose(pd.file);
        }
        pd.allocator.destroy(pd);
    }
}

pub fn isInputPort(v: Value) bool {
    return value_mod.isPtr(v) and objects.isForeign(v) and
        objects.foreignTypeTag(v) == TAG_INPUT_PORT;
}

pub fn inputPortFile(v: Value) *std.c.FILE {
    const pd: *InputPortPayload = @alignCast(@ptrCast(objects.foreignPayload(v)));
    return pd.file;
}

fn readLineFromFile(vm: *VM, file: *std.c.FILE) LispError!Value {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(vm.allocator);
    var tmp: [256]u8 = undefined;
    var got_any = false;
    while (true) {
        const result = fgets(&tmp, @intCast(tmp.len), file);
        if (result == null) {
            if (!got_any) return value_mod.EOF_VAL;
            break;
        }
        got_any = true;
        const slice = std.mem.sliceTo(@as([*:0]u8, @ptrCast(&tmp)), 0);
        if (slice.len > 0 and slice[slice.len - 1] == '\n') {
            buf.appendSlice(vm.allocator, slice[0 .. slice.len - 1]) catch return error.OutOfMemory;
            break;
        }
        buf.appendSlice(vm.allocator, slice) catch return error.OutOfMemory;
    }
    return objects.makeString(vm.gc, buf.items) catch return error.OutOfMemory;
}

pub fn primOpenInputFile(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    const path_bytes = objects.stringBytes(args[0]);
    // Need null-terminated path
    const path_z = vm.allocator.dupeZ(u8, path_bytes) catch return error.OutOfMemory;
    defer vm.allocator.free(path_z);
    const file = std.c.fopen(path_z.ptr, "r") orelse return error.IOError;
    const pd = vm.allocator.create(InputPortPayload) catch {
        _ = std.c.fclose(file);
        return error.OutOfMemory;
    };
    pd.* = .{ .file = file, .owned = true, .allocator = vm.allocator };
    return objects.makeForeign(vm.gc, pd, deinitInputPortFull, TAG_INPUT_PORT) catch return error.OutOfMemory;
}

pub fn primCloseInputPort(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isInputPort(args[0])) return error.TypeError;
    const pd: *InputPortPayload = @alignCast(@ptrCast(objects.foreignPayload(args[0])));
    if (pd.owned) {
        _ = std.c.fclose(pd.file);
        // Null out the pointer and mark not-owned so double-close is safe.
        pd.owned = false;
    }
    return value_mod.NIL;
}

extern "c" fn fdopen(fd: c_int, mode: [*:0]const u8) ?*std.c.FILE;

pub fn primCurrentInputPort(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 0) return error.ArityMismatch;
    // fdopen(0, "r") gives us a FILE* wrapping stdin; not owned (do not fclose).
    const file = fdopen(0, "r") orelse return error.IOError;
    const pd = vm.allocator.create(InputPortPayload) catch return error.OutOfMemory;
    pd.* = .{ .file = file, .owned = false, .allocator = vm.allocator };
    return objects.makeForeign(vm.gc, pd, deinitInputPortFull, TAG_INPUT_PORT) catch return error.OutOfMemory;
}

pub fn primReadChar(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isInputPort(args[0])) return error.TypeError;
    const file = inputPortFile(args[0]);
    _ = vm;
    const c = fgetc(file);
    if (c == EOF_C) return value_mod.EOF_VAL;
    return value_mod.char(@intCast(c & 0xFF));
}

pub fn primPeekChar(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!isInputPort(args[0])) return error.TypeError;
    const file = inputPortFile(args[0]);
    _ = vm;
    const c = fgetc(file);
    if (c == EOF_C) return value_mod.EOF_VAL;
    _ = ungetc(c, file);
    return value_mod.char(@intCast(c & 0xFF));
}

pub fn primEofObjectQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    return if (value_mod.isEof(args[0])) value_mod.TRUE else value_mod.FALSE;
}

pub fn primEofObject(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 0) return error.ArityMismatch;
    return value_mod.EOF_VAL;
}

pub fn primInputPortQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    return if (isInputPort(args[0])) value_mod.TRUE else value_mod.FALSE;
}

// zepo-9qg: binary file I/O ──────────────────────────────────────────────────

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

/// (file-read-bytes path) → bytevector
pub fn primFileReadBytes(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    const path = objects.stringBytes(args[0]);
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return error.InvalidForm;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const f = std.c.fopen(@ptrCast(&pbuf), "rb") orelse return error.IOError;
    defer _ = std.c.fclose(f);
    _ = fseek(f, 0, 2); // SEEK_END
    const size: usize = @intCast(@max(0, ftell(f)));
    _ = fseek(f, 0, 0); // SEEK_SET
    const bv = objects.makeBytevector(vm.gc, size, 0) catch return error.OutOfMemory;
    if (size > 0) {
        const dst = objects.bytevectorBytes(bv);
        _ = std.c.fread(dst.ptr, 1, size, f);
    }
    return bv;
}

/// (file-write-bytes path bv) — write bytevector to file (truncate)
pub fn primFileWriteBytes(vm: *VM, args: []const Value) LispError!Value {
    _ = vm;
    if (args.len != 2) return error.ArityMismatch;
    if (!objects.isString(args[0])) return error.TypeError;
    if (!objects.isBytevector(args[1])) return error.TypeError;
    const path = objects.stringBytes(args[0]);
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return error.InvalidForm;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const f = std.c.fopen(@ptrCast(&pbuf), "wb") orelse return error.IOError;
    defer _ = std.c.fclose(f);
    const bytes = objects.bytevectorBytes(args[1]);
    if (bytes.len > 0) {
        _ = std.c.fwrite(bytes.ptr, 1, bytes.len, f);
    }
    return value_mod.NIL;
}
