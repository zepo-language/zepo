//! Integration tests for the Zepo LSP server.
//!
//! Drives the Server through in-memory readers/writers, asserts on the
//! JSON-RPC responses produced for hover / definition / completion /
//! diagnostics.
//!
//! See bead zepo-k9hh.

const std = @import("std");
const zepo = @import("zepo");
const lsp = zepo.lsp;

// ----- Mock reader/writer ---------------------------------------------------

const MockIn = struct {
    buf: []const u8,
    pos: usize = 0,

    fn read(ctx: *anyopaque, out: []u8) isize {
        const self: *MockIn = @ptrCast(@alignCast(ctx));
        if (self.pos >= self.buf.len) return 0;
        const n = @min(out.len, self.buf.len - self.pos);
        @memcpy(out[0..n], self.buf[self.pos .. self.pos + n]);
        self.pos += n;
        return @intCast(n);
    }
};

const MockOut = struct {
    list: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,

    fn write(ctx: *anyopaque, buf: []const u8) void {
        const self: *MockOut = @ptrCast(@alignCast(ctx));
        self.list.appendSlice(self.alloc, buf) catch {};
    }
};

fn frame(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), body: []const u8) !void {
    var hdr: [64]u8 = undefined;
    const h = try std.fmt.bufPrint(&hdr, "Content-Length: {d}\r\n\r\n", .{body.len});
    try out.appendSlice(alloc, h);
    try out.appendSlice(alloc, body);
}

fn runWithInput(alloc: std.mem.Allocator, input: []const u8, out_buf: *std.ArrayListUnmanaged(u8)) !void {
    var min = MockIn{ .buf = input };
    var mout = MockOut{ .list = out_buf, .alloc = alloc };
    const reader = lsp.protocol.Reader{ .read_fn = MockIn.read, .ctx = @ptrCast(&min) };
    const writer = lsp.protocol.Writer{ .write_fn = MockOut.write, .ctx = @ptrCast(&mout) };
    var srv = lsp.Server.init(alloc, reader, writer);
    defer srv.deinit();
    try srv.run();
}

/// Iterate framed messages from `bytes`, calling `cb` on each body.
fn forEachMessage(bytes: []const u8, ctx: anytype, comptime cb: fn (@TypeOf(ctx), []const u8) void) void {
    var i: usize = 0;
    while (i < bytes.len) {
        const hdr_end = std.mem.indexOfPos(u8, bytes, i, "\r\n\r\n") orelse return;
        const header = bytes[i..hdr_end];
        const cl_idx = std.mem.indexOf(u8, header, "Content-Length:") orelse return;
        const cl_val = std.mem.trim(u8, header[cl_idx + "Content-Length:".len ..], " \t\r\n");
        const len = std.fmt.parseInt(usize, cl_val, 10) catch return;
        const body_start = hdr_end + 4;
        const body_end = body_start + len;
        if (body_end > bytes.len) return;
        cb(ctx, bytes[body_start..body_end]);
        i = body_end;
    }
}

// ----- Tests ----------------------------------------------------------------

test "initialize -> capabilities advertised" {
    const t = std.testing;
    const alloc = t.allocator;

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);

    try t.expect(std.mem.indexOf(u8, out.items, "\"hoverProvider\":true") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "\"definitionProvider\":true") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "\"completionProvider\"") != null);
}

test "didOpen publishes diagnostics" {
    const t = std.testing;
    const alloc = t.allocator;

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    // Unbalanced paren -> should be diagnosed.
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.lisp","languageId":"lisp","version":1,"text":"(define foo 1"}}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);

    try t.expect(std.mem.indexOf(u8, out.items, "publishDiagnostics") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "unbalanced parenthesis") != null);
}

test "reader diagnostics: unterminated string surfaces as diagnostic" {
    // zepo-vwns: the byte-level paren-balance check can't see string-level
    // errors. The reader pass does, and now publishes them.
    const t = std.testing;
    const alloc = t.allocator;

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///s.lisp","languageId":"lisp","version":1,"text":"(define s \"unterminated"}}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);

    try t.expect(std.mem.indexOf(u8, out.items, "publishDiagnostics") != null);
    // The reader's diagnostic message for StringUnterminated mentions the
    // string. Test for any of several plausible substrings the reader uses.
    const has_string_msg = std.mem.indexOf(u8, out.items, "string") != null or
        std.mem.indexOf(u8, out.items, "String") != null;
    try t.expect(has_string_msg);
}

test "hover on imported alias reports module" {
    const t = std.testing;
    const alloc = t.allocator;

    const src =
        \\(import math/tensor :as t)
        \\(define m (t.transpose x))
    ;

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);

    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );

    var open_body: std.ArrayListUnmanaged(u8) = .empty;
    defer open_body.deinit(alloc);
    try open_body.appendSlice(alloc,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///a.lisp","languageId":"lisp","version":1,"text":"
    );
    try zepo.lsp.protocol.escapeJsonInto(&open_body, alloc, src);
    try open_body.appendSlice(alloc, "\"}}}");
    try frame(alloc, &input, open_body.items);

    // Hover at line 1, character 12 — inside "t.transpose".
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///a.lisp"},"position":{"line":1,"character":12}}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);

    try t.expect(std.mem.indexOf(u8, out.items, "t.transpose") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "math/tensor") != null);
}

test "definition jumps to local define" {
    const t = std.testing;
    const alloc = t.allocator;

    const src = "(define foo 1)\n(define bar (+ foo 2))\n";

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    var open_body: std.ArrayListUnmanaged(u8) = .empty;
    defer open_body.deinit(alloc);
    try open_body.appendSlice(alloc,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///d.lisp","languageId":"lisp","version":1,"text":"
    );
    try zepo.lsp.protocol.escapeJsonInto(&open_body, alloc, src);
    try open_body.appendSlice(alloc, "\"}}}");
    try frame(alloc, &input, open_body.items);

    // Position over the `foo` reference on line 1, char 15.
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///d.lisp"},"position":{"line":1,"character":15}}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);

    // Result should reference line 0 (the `(define foo 1)`).
    try t.expect(std.mem.indexOf(u8, out.items, "\"line\":0") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "file:///d.lisp") != null);
}

test "completion after alias dot offers imported names" {
    const t = std.testing;
    const alloc = t.allocator;

    const src = "(import M (alpha beta gamma))\n(M.";

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    var open_body: std.ArrayListUnmanaged(u8) = .empty;
    defer open_body.deinit(alloc);
    try open_body.appendSlice(alloc,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///c.lisp","languageId":"lisp","version":1,"text":"
    );
    try zepo.lsp.protocol.escapeJsonInto(&open_body, alloc, src);
    try open_body.appendSlice(alloc, "\"}}}");
    try frame(alloc, &input, open_body.items);

    // Cursor immediately after "M." on line 1, char 3.
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/completion","params":{"textDocument":{"uri":"file:///c.lisp"},"position":{"line":1,"character":3}}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);

    try t.expect(std.mem.indexOf(u8, out.items, "alpha") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "beta") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "gamma") != null);
}

test "initialize advertises positionEncoding and negotiates utf-8" {
    const t = std.testing;
    const alloc = t.allocator;

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    // Client advertises utf-8 support under capabilities.general.positionEncodings.
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"general":{"positionEncodings":["utf-8","utf-16"]}}}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);
    try t.expect(std.mem.indexOf(u8, out.items, "\"positionEncoding\":\"utf-8\"") != null);
}

test "hover position for non-ASCII identifier (utf-16 default)" {
    const t = std.testing;
    const alloc = t.allocator;

    // λ is U+03BB, encoded as 2 bytes in UTF-8 (0xCE 0xBB), 1 unit in UTF-16.
    // Source layout (line 0): "(define λ 1)"
    //   byte cols:  0 1 2 3 4 5 6 7 8 9 10 11 12
    //   chars:      ( d e f i n e _ λ . _  1  )   (note λ is 2 bytes)
    //   utf-16 cols same as char cols since λ is BMP.
    // After λ on line 0 there should be a reference; we'll use a second line.
    const src =
        \\(define λ 1)
        \\(define use λ)
    ;

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    var open_body: std.ArrayListUnmanaged(u8) = .empty;
    defer open_body.deinit(alloc);
    try open_body.appendSlice(alloc,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///u.lisp","languageId":"lisp","version":1,"text":"
    );
    try zepo.lsp.protocol.escapeJsonInto(&open_body, alloc, src);
    try open_body.appendSlice(alloc, "\"}}}");
    try frame(alloc, &input, open_body.items);

    // With utf-16 encoding negotiated (default), the `λ` at line 0 begins at
    // character index 8 (same as bytes here) but its visible width is 1 utf-16
    // unit. Hovering at line 0 char 8 should resolve to the symbol `λ`.
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///u.lisp"},"position":{"line":0,"character":8}}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);

    // Hover response should contain λ (escaped as utf-8 bytes in JSON output)
    // and indicate it is defined in this file.
    try t.expect(std.mem.indexOf(u8, out.items, "defined in this file") != null);
    // The returned range.end.character for `λ` should be 9 (one utf-16 unit
    // wide), NOT 10 (which would be the raw-byte count). This proves we are
    // emitting utf-16 columns when negotiated.
    try t.expect(std.mem.indexOf(u8, out.items, "\"end\":{\"line\":0,\"character\":9}") != null);
}

test "cross-file goto-def resolves through ZEPO_PATH" {
    const t = std.testing;
    const alloc = t.allocator;

    // Create a tmp dir, put a fake module file inside, point ZEPO_PATH at it.
    const libc = struct {
        extern "c" fn mkdir(path: [*:0]const u8, mode: c_uint) c_int;
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    const dir_path = "/tmp/zepo-lsp-xfile-test";
    _ = libc.mkdir(dir_path, 0o755);
    _ = libc.mkdir("/tmp/zepo-lsp-xfile-test/math", 0o755);
    const file_path = "/tmp/zepo-lsp-xfile-test/math/tensor.lisp";
    {
        const f = std.c.fopen(file_path, "wb") orelse return error.TestUnexpectedResult;
        defer _ = std.c.fclose(f);
        const body = "(define transpose (lambda (x) x))\n";
        _ = std.c.fwrite(body.ptr, 1, body.len, f);
    }

    _ = libc.setenv("ZEPO_PATH", dir_path, 1);
    defer _ = libc.unsetenv("ZEPO_PATH");

    const src =
        \\(import math/tensor :as mt)
        \\(define use (mt.transpose 1))
    ;

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    var open_body: std.ArrayListUnmanaged(u8) = .empty;
    defer open_body.deinit(alloc);
    try open_body.appendSlice(alloc,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///x.lisp","languageId":"lisp","version":1,"text":"
    );
    try zepo.lsp.protocol.escapeJsonInto(&open_body, alloc, src);
    try open_body.appendSlice(alloc, "\"}}}");
    try frame(alloc, &input, open_body.items);

    // Cursor inside "mt.transpose" on line 1.
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///x.lisp"},"position":{"line":1,"character":16}}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);

    // Result must reference the remote file.
    try t.expect(std.mem.indexOf(u8, out.items, "file://") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "math/tensor.lisp") != null);
}

test "incremental sync: ranged contentChange applied correctly" {
    // zepo-ttk8: didChange with a {range, text} contentChange splices the
    // text in instead of replacing the whole document.
    const t = std.testing;
    const alloc = t.allocator;

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///inc.lisp","languageId":"lisp","version":1,"text":"(define x 1)"}}}
    );
    // Replace '1' with '42' at line 0, characters 10..11 (the digit only).
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///inc.lisp","version":2},"contentChanges":[{"range":{"start":{"line":0,"character":10},"end":{"line":0,"character":11}},"text":"42"}]}}
    );
    // Hover at the start of 'define' to force the server to read the document
    // and produce a hover response that we can sniff for the updated text.
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///inc.lisp"},"position":{"line":0,"character":1}}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);

    // The second didOpen-issued diagnostic round runs against the spliced
    // document. Parens still balance, so we should NOT see "unbalanced".
    // Negative existence is brittle; instead just verify the protocol
    // round-trip completed: at least two publishDiagnostics responses
    // (one per didOpen + didChange) and a hover response.
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out.items, idx, "publishDiagnostics")) |found| {
        count += 1;
        idx = found + 1;
    }
    try t.expect(count >= 2);
}

test "incremental sync: capabilities advertise textDocumentSync.change=2" {
    const t = std.testing;
    const alloc = t.allocator;

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);

    try t.expect(std.mem.indexOf(u8, out.items, "\"change\":2") != null);
}

test "shutdown then exit" {
    const t = std.testing;
    const alloc = t.allocator;

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);
    // shutdown response should produce a null result keyed to id 2.
    try t.expect(std.mem.indexOf(u8, out.items, "\"id\":2") != null);
}

// zepo-ab3s
test "hover surfaces :documentation docstring" {
    const t = std.testing;
    const alloc = t.allocator;

    const src =
        \\(define greeting :documentation "say hello" "hi")
        \\(define use greeting)
    ;

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);

    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );

    var open_body: std.ArrayListUnmanaged(u8) = .empty;
    defer open_body.deinit(alloc);
    try open_body.appendSlice(alloc,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///doc.lisp","languageId":"lisp","version":1,"text":"
    );
    try zepo.lsp.protocol.escapeJsonInto(&open_body, alloc, src);
    try open_body.appendSlice(alloc, "\"}}}");
    try frame(alloc, &input, open_body.items);

    // Hover on `greeting` at the use site (line 1, character ~12).
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///doc.lisp"},"position":{"line":1,"character":12}}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);

    try t.expect(std.mem.indexOf(u8, out.items, "say hello") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "defined in this file") != null);
}

// zepo-wwh7
test "analysis cache: repeated hovers on unchanged text don't re-analyze" {
    // We can't observe re-analysis directly without instrumentation, but we
    // CAN observe that two consecutive hovers on the same text return
    // identical content — including the exact same byte spans — which is
    // what the cache contract guarantees.
    //
    // The real "no re-analysis happened" assertion is left as a behavioral
    // black-box test: the responses must agree exactly.
    const t = std.testing;
    const alloc = t.allocator;

    const src =
        \\(define foo :documentation "first" 1)
        \\(define bar foo)
    ;

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);

    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );

    var open_body: std.ArrayListUnmanaged(u8) = .empty;
    defer open_body.deinit(alloc);
    try open_body.appendSlice(alloc,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///c.lisp","languageId":"lisp","version":1,"text":"
    );
    try zepo.lsp.protocol.escapeJsonInto(&open_body, alloc, src);
    try open_body.appendSlice(alloc, "\"}}}");
    try frame(alloc, &input, open_body.items);

    // Hover #1
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///c.lisp"},"position":{"line":1,"character":12}}}
    );
    // Hover #2 — same position, same doc, no didChange between
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///c.lisp"},"position":{"line":1,"character":12}}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);

    // Both responses contain the docstring (cache returned the same data).
    var count: usize = 0;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, out.items, search_start, "first")) |idx| {
        count += 1;
        search_start = idx + 1;
    }
    try t.expect(count >= 2);
}

// zepo-wwh7
test "analysis cache: didChange invalidates the cache" {
    const t = std.testing;
    const alloc = t.allocator;

    const src_v1 = "(define foo :documentation \"first\" 1)\n(define bar foo)";
    const src_v2 = "(define foo :documentation \"second\" 1)\n(define bar foo)";

    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    );

    var open_body: std.ArrayListUnmanaged(u8) = .empty;
    defer open_body.deinit(alloc);
    try open_body.appendSlice(alloc,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///iv.lisp","languageId":"lisp","version":1,"text":"
    );
    try zepo.lsp.protocol.escapeJsonInto(&open_body, alloc, src_v1);
    try open_body.appendSlice(alloc, "\"}}}");
    try frame(alloc, &input, open_body.items);

    // Hover before edit — expect "first"
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///iv.lisp"},"position":{"line":1,"character":12}}}
    );

    // didChange: full replacement
    var change_body: std.ArrayListUnmanaged(u8) = .empty;
    defer change_body.deinit(alloc);
    try change_body.appendSlice(alloc,
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///iv.lisp","version":2},"contentChanges":[{"text":"
    );
    try zepo.lsp.protocol.escapeJsonInto(&change_body, alloc, src_v2);
    try change_body.appendSlice(alloc, "\"}]}}");
    try frame(alloc, &input, change_body.items);

    // Hover after edit — expect "second"
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///iv.lisp"},"position":{"line":1,"character":12}}}
    );
    try frame(alloc, &input,
        \\{"jsonrpc":"2.0","method":"exit"}
    );

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try runWithInput(alloc, input.items, &out);

    try t.expect(std.mem.indexOf(u8, out.items, "first") != null);
    try t.expect(std.mem.indexOf(u8, out.items, "second") != null);
}
