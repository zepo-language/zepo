//! Tests for EvalContext.printDiagnostic.
//! zepo-45l: printDiagnostic now accepts anytype writer, enabling these tests.
//! Also covers zepo-zan (error labels) and zepo-7d3 (trace format / truncation).

const std = @import("std");
const zepo = @import("zepo");
const helpers = @import("conformance_helpers");
const Rig = helpers.Rig;

const alloc = std.testing.allocator;

/// Run `src`, catch the error, call printDiagnostic into a buffer, return the output.
fn diagnose(r: *Rig, src: []const u8) ![]const u8 {
    // zepo-04p: std.io removed in Zig 0.16; use inline struct writer instead.
    const FbsWriter = struct {
        buf: *[8192]u8,
        pos: usize = 0,
        pub fn writeAll(self: *@This(), data: []const u8) !void {
            const n = @min(data.len, self.buf.len - self.pos);
            @memcpy(self.buf[self.pos..][0..n], data[0..n]);
            self.pos += n;
        }
        pub fn getWritten(self: *@This()) []const u8 {
            return self.buf[0..self.pos];
        }
    };
    var rawbuf: [8192]u8 = undefined;
    var fbs = FbsWriter{ .buf = &rawbuf };
    r.ctx.last_error_span = null;
    _ = r.ctx.evalString(src, "<test>") catch |e| {
        r.ctx.printDiagnostic(&fbs, e);
        return try alloc.dupe(u8, fbs.getWritten());
    };
    return error.TestExpectedError;
}

// --- zepo-zan: error label mapping ---

test "label: StackOverflow maps to human-readable string" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    r.ctx.vm_max_regs = 256;
    const out = try diagnose(r,
        \\(begin
        \\  (define (f n) (if (= n 0) 0 (+ 1 (f (- n 1)))))
        \\  (f 100000))
    );
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "stack overflow (recursion too deep)") != null);
}

test "label: TypeError uses @errorName" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const out = try diagnose(r, "(+ 1 \"a\")");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "TypeError") != null);
}

test "label: UnboundVariable uses @errorName" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const out = try diagnose(r, "no-such-name");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "UnboundVariable") != null);
}

test "label: DivisionByZero uses @errorName" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const out = try diagnose(r, "(/ 1 0)");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "DivisionByZero") != null);
}

test "label: ArityMismatch uses @errorName" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    _ = try r.ctx.evalString("(define (f x) x)", "<test>");
    const out = try diagnose(r, "(f 1 2)");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "ArityMismatch") != null);
}

// --- zepo-0dj: span accuracy ---

test "span: error header contains file, line, col" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const out = try diagnose(r, "(+ 1 \"bad\")");
    defer alloc.free(out);
    // format: "<test>:1:1: error: TypeError"
    try std.testing.expect(std.mem.indexOf(u8, out, "<test>:") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ": error: ") != null);
}

test "span: source line and caret appear in output" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const out = try diagnose(r, "(/ 42 0)");
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "^") != null);
}

// --- zepo-7d3: call stack trace and truncation ---

test "trace: appears for errors inside recursive calls" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    const out = try diagnose(r,
        \\(begin
        \\  (define (boom n)
        \\    (if (= n 0) (+ 1 "oops") (+ 0 (boom (- n 1)))))
        \\  (boom 5))
    );
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "call stack (innermost first):") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "boom") != null);
}

test "trace: truncation message appears when frames exceed 20" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // 25 non-tail frames -> shows 20, truncates 5
    const out = try diagnose(r,
        \\(begin
        \\  (define (boom n)
        \\    (if (= n 0) (+ 1 "oops") (+ 0 (boom (- n 1)))))
        \\  (boom 25))
    );
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "more frames") != null);
}

test "trace: no truncation message when frames are 20 or fewer" {
    const r = try Rig.init(alloc);
    defer r.deinit();
    // 10 non-tail frames -> no truncation
    const out = try diagnose(r,
        \\(begin
        \\  (define (boom n)
        \\    (if (= n 0) (+ 1 "oops") (+ 0 (boom (- n 1)))))
        \\  (boom 10))
    );
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "more frames") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "call stack (innermost first):") != null);
}
