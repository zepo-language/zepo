//! Conformance tests for the clap Zepo module.

const std = @import("std");
const zepo = @import("zepo");
const helpers = @import("helpers.zig");
const Rig = helpers.Rig;
const value_mod = helpers.value_mod;
const objects = helpers.objects;

const alloc = std.testing.allocator;

extern "c" fn fseek(stream: *std.c.FILE, offset: c_long, whence: c_int) c_int;
extern "c" fn ftell(stream: *std.c.FILE) c_long;

fn readFilePosix(a: std.mem.Allocator, path: []const u8, _: usize) ![]u8 {
    var pbuf: [4096]u8 = undefined;
    if (path.len >= pbuf.len) return error.NameTooLong;
    @memcpy(pbuf[0..path.len], path);
    pbuf[path.len] = 0;
    const path_c: [*:0]const u8 = @ptrCast(&pbuf);
    const f = std.c.fopen(path_c, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);
    _ = fseek(f, 0, 2);
    const sz = ftell(f);
    if (sz < 0) return error.Unexpected;
    _ = fseek(f, 0, 0);
    const buf = try a.alloc(u8, @intCast(sz));
    const n = std.c.fread(buf.ptr, 1, buf.len, f);
    return buf[0..n];
}


fn rigWithClap() !*Rig {
    const r = try Rig.initWithPrelude(alloc);
    errdefer r.deinit();
    const clap_src = try readFilePosix(alloc, "lib/clap.lisp", 1 << 20);
    defer alloc.free(clap_src);
    _ = try r.eval(clap_src);
    _ = try r.eval(
        \\(import clap (make-program make-command make-option make-positional
        \\              opt-set cmd-add-option cmd-add-positional
        \\              parse run parse-result? parse-error?
        \\              render-help render-error render-markdown render-manpage
        \\              result-option result-positional result-command))
    );
    return r;
}

fn expectString(v: helpers.Value, expected: []const u8) !void {
    if (!objects.isString(v)) return error.TestExpectedString;
    try std.testing.expectEqualStrings(expected, objects.stringBytes(v));
}

fn expectTrue(v: helpers.Value) !void {
    try std.testing.expectEqual(value_mod.TRUE, v);
}

fn expectFalse(v: helpers.Value) !void {
    try std.testing.expectEqual(value_mod.FALSE, v);
}

// ── primitive sanity ──────────────────────────────────────────────────────────

test "new prims: string-ref" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    const v = try r.eval(
        \\(char->integer (string-ref "hello" 1))
    );
    try helpers.expectInt(v, @intCast('e'));
}

test "new prims: substring" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    const v = try r.eval(
        \\(substring "hello world" 6 11)
    );
    try expectString(v, "world");
}

test "new prims: string->number integer" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    const v = try r.eval(
        \\(string->number "42")
    );
    try helpers.expectInt(v, 42);
}

test "new prims: string->number invalid returns #f" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    const v = try r.eval(
        \\(string->number "nope")
    );
    try expectFalse(v);
}

test "new prims: symbol->string" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    const v = try r.eval(
        \\(symbol->string (quote hello))
    );
    try expectString(v, "hello");
}

test "new prims: string->symbol" {
    const r = try Rig.initWithPrelude(alloc);
    defer r.deinit();
    const v = try r.eval(
        \\(string->symbol "world")
    );
    const sym = try r.eval("(quote world)");
    try std.testing.expectEqual(sym, v);
}

// ── clap module load ──────────────────────────────────────────────────────────

test "clap: module loads without error" {
    const r = try rigWithClap();
    defer r.deinit();
}

// ── parse-result? / parse-error? ─────────────────────────────────────────────

test "clap: simple flag parse" {
    const r = try rigWithClap();
    defer r.deinit();

    _ = try r.eval(
        \\(define cmd (make-command "tool" "A test tool"))
    );
    _ = try r.eval(
        \\(define verbose-opt
        \\  (opt-set (opt-set (make-option (quote verbose) "Be verbose")
        \\                    :long "verbose")
        \\           :kind (quote flag)))
    );
    _ = try r.eval(
        \\(define cmd (cmd-add-option cmd verbose-opt))
    );
    _ = try r.eval(
        \\(define prog (make-program "tool" "A test tool" "" "1.0" cmd))
    );
    const v = try r.eval(
        \\(parse-result? (parse prog (list "--verbose")))
    );
    try expectTrue(v);
}

test "clap: unknown option returns parse-error" {
    const r = try rigWithClap();
    defer r.deinit();

    _ = try r.eval(
        \\(define cmd (make-command "tool" "A test tool"))
    );
    _ = try r.eval(
        \\(define prog (make-program "tool" "A test tool" "" "1.0" cmd))
    );
    const v = try r.eval(
        \\(parse-error? (parse prog (list "--unknown")))
    );
    try expectTrue(v);
}

test "clap: option value parsed" {
    const r = try rigWithClap();
    defer r.deinit();

    _ = try r.eval(
        \\(define output-opt
        \\  (opt-set (opt-set (make-option (quote output) "Output path")
        \\                    :long "output")
        \\           :kind (quote value)))
    );
    _ = try r.eval(
        \\(define cmd (cmd-add-option (make-command "tool" "test") output-opt))
    );
    _ = try r.eval(
        \\(define prog (make-program "tool" "test" "" "1.0" cmd))
    );
    const v = try r.eval(
        \\(result-option (parse prog (list "--output" "out.bin")) (quote output))
    );
    try expectString(v, "out.bin");
}

test "clap: long assign --name=value" {
    const r = try rigWithClap();
    defer r.deinit();

    _ = try r.eval(
        \\(define opt
        \\  (opt-set (opt-set (make-option (quote name) "Name")
        \\                    :long "name")
        \\           :kind (quote value)))
    );
    _ = try r.eval(
        \\(define cmd (cmd-add-option (make-command "tool" "test") opt))
    );
    _ = try r.eval(
        \\(define prog (make-program "tool" "test" "" "1.0" cmd))
    );
    const v = try r.eval(
        \\(result-option (parse prog (list "--name=alice")) (quote name))
    );
    try expectString(v, "alice");
}

test "clap: integer type coercion" {
    const r = try rigWithClap();
    defer r.deinit();

    _ = try r.eval(
        \\(define port-opt
        \\  (opt-set (opt-set (opt-set (make-option (quote port) "Port")
        \\                             :long "port")
        \\                    :kind (quote value))
        \\           :type (quote integer)))
    );
    _ = try r.eval(
        \\(define cmd (cmd-add-option (make-command "tool" "test") port-opt))
    );
    _ = try r.eval(
        \\(define prog (make-program "tool" "test" "" "1.0" cmd))
    );
    const v = try r.eval(
        \\(result-option (parse prog (list "--port" "8080")) (quote port))
    );
    try helpers.expectInt(v, 8080);
}

test "clap: positional binding" {
    const r = try rigWithClap();
    defer r.deinit();

    _ = try r.eval(
        \\(define target-pos (make-positional (quote target) "Build target"))
    );
    _ = try r.eval(
        \\(define cmd (cmd-add-positional (make-command "build" "Build cmd") target-pos))
    );
    _ = try r.eval(
        \\(define prog (make-program "tool" "test" "" "1.0" cmd))
    );
    const v = try r.eval(
        \\(result-positional (parse prog (list "app")) (quote target))
    );
    try expectString(v, "app");
}

test "clap: option terminator -- passes rest as positionals" {
    const r = try rigWithClap();
    defer r.deinit();

    _ = try r.eval(
        \\(define file-pos (make-positional (quote file) "File"))
    );
    _ = try r.eval(
        \\(define cmd (cmd-add-positional (make-command "tool" "test") file-pos))
    );
    _ = try r.eval(
        \\(define prog (make-program "tool" "test" "" "1.0" cmd))
    );
    const v = try r.eval(
        \\(result-positional (parse prog (list "--" "-literal-name")) (quote file))
    );
    try expectString(v, "-literal-name");
}

test "clap: render-error contains message" {
    const r = try rigWithClap();
    defer r.deinit();

    _ = try r.eval(
        \\(define prog (make-program "tool" "test" "" "1.0" (make-command "tool" "test")))
    );
    const v = try r.eval(
        \\(let ((err (parse prog (list "--bogus"))))
        \\  (render-error err))
    );
    if (!objects.isString(v)) return error.TestExpectedString;
    const s = objects.stringBytes(v);
    try std.testing.expect(std.mem.indexOf(u8, s, "error:") != null);
}

test "clap: counter option increments" {
    const r = try rigWithClap();
    defer r.deinit();

    _ = try r.eval(
        \\(define vopt
        \\  (opt-set (opt-set (make-option (quote verbose) "Verbosity")
        \\                    :short (quote v))
        \\           :kind (quote counter)))
    );
    _ = try r.eval(
        \\(define cmd (cmd-add-option (make-command "tool" "test") vopt))
    );
    _ = try r.eval(
        \\(define prog (make-program "tool" "test" "" "1.0" cmd))
    );
    const v = try r.eval(
        \\(result-option (parse prog (list "-v" "-v" "-v")) (quote verbose))
    );
    try helpers.expectInt(v, 3);
}
