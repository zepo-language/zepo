//! zepo-g44i: shared Lisp formatter. Extracted from src/cli/fmt_cmd.zig
//! so the LSP can call formatSource without pulling cli/ into its module
//! graph. Pure text transformation — no GC, no eval, std-only dependencies.

const std = @import("std");

const TokKind = enum {
    lparen,
    rparen,
    dot,
    quote, // '
    quasiquote, // `
    unquote, // ,
    splice, // ,@
    atom, // symbol / number / #t / #f / #\char
    string, // "..."
    comment, // ; to end of line
    eof,
};

const Token = struct {
    kind: TokKind,
    text: []const u8,
};

const Tokenizer = struct {
    src: []const u8,
    pos: usize,

    fn init(src: []const u8) Tokenizer {
        return .{ .src = src, .pos = 0 };
    }

    fn peek(self: *Tokenizer) u8 {
        if (self.pos >= self.src.len) return 0;
        return self.src[self.pos];
    }

    fn advance(self: *Tokenizer) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        return c;
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    fn next(self: *Tokenizer) Token {
        self.skipWhitespace();
        if (self.pos >= self.src.len) return .{ .kind = .eof, .text = "" };

        const start = self.pos;
        const c = self.src[self.pos];

        switch (c) {
            '(' => {
                self.pos += 1;
                return .{ .kind = .lparen, .text = self.src[start..self.pos] };
            },
            ')' => {
                self.pos += 1;
                return .{ .kind = .rparen, .text = self.src[start..self.pos] };
            },
            '\'' => {
                self.pos += 1;
                return .{ .kind = .quote, .text = self.src[start..self.pos] };
            },
            '`' => {
                self.pos += 1;
                return .{ .kind = .quasiquote, .text = self.src[start..self.pos] };
            },
            ',' => {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '@') {
                    self.pos += 1;
                    return .{ .kind = .splice, .text = self.src[start..self.pos] };
                }
                return .{ .kind = .unquote, .text = self.src[start..self.pos] };
            },
            ';' => {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') {
                    self.pos += 1;
                }
                return .{ .kind = .comment, .text = self.src[start..self.pos] };
            },
            '"' => {
                self.pos += 1;
                while (self.pos < self.src.len) {
                    const ch = self.src[self.pos];
                    if (ch == '\\') {
                        // zepo-hdhl: a lone backslash at EOF must not advance
                        // past the end (that produced an out-of-bounds slice).
                        self.pos = @min(self.pos + 2, self.src.len);
                    } else if (ch == '"') {
                        self.pos += 1;
                        break;
                    } else {
                        self.pos += 1;
                    }
                }
                return .{ .kind = .string, .text = self.src[start..self.pos] };
            },
            else => {
                // zepo-hdhl: a character literal #\<c> takes its next byte
                // verbatim — even a delimiter like ( ) ; " — so consume it
                // before the delimiter scan (otherwise #\( split into the atom
                // "#\" plus a stray '(', corrupting structure). Trailing letters
                // of named chars (#\space, #\newline) are picked up by the loop.
                if (self.pos + 1 < self.src.len and self.src[self.pos] == '#' and self.src[self.pos + 1] == '\\') {
                    self.pos += 2; // past #\
                    if (self.pos < self.src.len) self.pos += 1; // the literal char (any byte)
                }
                // atom: read until delimiter
                while (self.pos < self.src.len) {
                    const ch = self.src[self.pos];
                    if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or
                        ch == '(' or ch == ')' or ch == '"' or ch == ';' or
                        ch == '\'' or ch == '`' or ch == ',')
                    {
                        break;
                    }
                    self.pos += 1;
                }
                const text = self.src[start..self.pos];
                if (std.mem.eql(u8, text, ".")) {
                    return .{ .kind = .dot, .text = text };
                }
                return .{ .kind = .atom, .text = text };
            },
        }
    }
};

// ---------------------------------------------------------------------------
// CST nodes (arena-allocated)
// ---------------------------------------------------------------------------

const NodeTag = enum {
    atom,
    list,
    comment,
    prefixed,
};

const Node = struct {
    tag: NodeTag,
    // atom / comment: text slice
    // prefixed: prefix char text + one child
    text: []const u8,
    children: []Node,

    fn initAtom(text: []const u8) Node {
        return .{ .tag = .atom, .text = text, .children = &.{} };
    }

    fn initComment(text: []const u8) Node {
        return .{ .tag = .comment, .text = text, .children = &.{} };
    }

    fn initList(children: []Node) Node {
        return .{ .tag = .list, .text = "", .children = children };
    }

    fn initPrefixed(prefix: []const u8, child: Node, arena: std.mem.Allocator) !Node {
        const buf = try arena.alloc(Node, 1);
        buf[0] = child;
        return .{ .tag = .prefixed, .text = prefix, .children = buf };
    }
};

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

const Parser = struct {
    tok: Tokenizer,
    arena: std.mem.Allocator,
    // lookahead: one token buffer
    la: ?Token,

    fn init(src: []const u8, arena: std.mem.Allocator) Parser {
        return .{ .tok = Tokenizer.init(src), .arena = arena, .la = null };
    }

    fn peek(self: *Parser) Token {
        if (self.la == null) self.la = self.tok.next();
        return self.la.?;
    }

    fn consume(self: *Parser) Token {
        if (self.la) |t| {
            self.la = null;
            return t;
        }
        return self.tok.next();
    }

    /// Parse a single top-level form (or comment). Returns null at EOF.
    fn parseOne(self: *Parser) !?Node {
        const t = self.peek();
        switch (t.kind) {
            .eof => return null,
            .comment => {
                _ = self.consume();
                return Node.initComment(t.text);
            },
            .lparen => {
                _ = self.consume();
                var children: std.ArrayListUnmanaged(Node) = .empty;
                while (true) {
                    const inner = self.peek();
                    if (inner.kind == .eof) break;
                    if (inner.kind == .rparen) {
                        _ = self.consume();
                        break;
                    }
                    const child = (try self.parseOne()) orelse break;
                    try children.append(self.arena, child);
                }
                const slice = try children.toOwnedSlice(self.arena);
                return Node.initList(slice);
            },
            .rparen => {
                // zepo-hdhl: an unmatched top-level ')' is a syntax error, NOT
                // end-of-input. Returning null here made parseAll stop and
                // silently drop every form after it. Error out so the caller
                // refuses to rewrite the (malformed) file.
                return error.UnmatchedRparen;
            },
            .quote => {
                _ = self.consume();
                const child = (try self.parseOne()) orelse return Node.initAtom("'");
                return try Node.initPrefixed("'", child, self.arena);
            },
            .quasiquote => {
                _ = self.consume();
                const child = (try self.parseOne()) orelse return Node.initAtom("`");
                return try Node.initPrefixed("`", child, self.arena);
            },
            .unquote => {
                _ = self.consume();
                const child = (try self.parseOne()) orelse return Node.initAtom(",");
                return try Node.initPrefixed(",", child, self.arena);
            },
            .splice => {
                _ = self.consume();
                const child = (try self.parseOne()) orelse return Node.initAtom(",@");
                return try Node.initPrefixed(",@", child, self.arena);
            },
            .atom, .string, .dot => {
                _ = self.consume();
                return Node.initAtom(t.text);
            },
        }
    }

    fn parseAll(self: *Parser) ![]Node {
        var forms: std.ArrayListUnmanaged(Node) = .empty;
        while (try self.parseOne()) |node| {
            try forms.append(self.arena, node);
        }
        return forms.toOwnedSlice(self.arena);
    }
};

// ---------------------------------------------------------------------------
// Measure (flat width of a node)
// ---------------------------------------------------------------------------

fn measure(node: Node) usize {
    switch (node.tag) {
        .atom => return node.text.len,
        .comment => return node.text.len,
        .prefixed => {
            const child_w = if (node.children.len > 0) measure(node.children[0]) else 0;
            return node.text.len + child_w;
        },
        .list => {
            var w: usize = 2; // ( )
            var i: usize = 0;
            while (i < node.children.len) : (i += 1) {
                if (i > 0) w += 1; // space
                w += measure(node.children[i]);
            }
            return w;
        },
    }
}

fn hasCommentChild(node: Node) bool {
    for (node.children) |c| {
        if (c.tag == .comment) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Special-form classification
// ---------------------------------------------------------------------------

const FormStyle = enum {
    body2, // (define name ...) / (lambda ...)
    let_style, // (let bindings body...)
    if_style, // (if test then else)
    each_line, // (cond ...) — each arg on its own line
    default, // head + first on line 1, rest aligned
    none, // not a special form
};

fn classifyHead(text: []const u8) FormStyle {
    const body2_forms = [_][]const u8{
        "define", "lambda", "begin", "when", "unless",
        "defmacro", "module",
    };
    const let_forms = [_][]const u8{ "let", "let*", "letrec" };
    const if_forms = [_][]const u8{"if"};
    const each_forms = [_][]const u8{ "cond", "case", "export", "and", "or" };

    for (body2_forms) |s| {
        if (std.mem.eql(u8, text, s)) return .body2;
    }
    for (let_forms) |s| {
        if (std.mem.eql(u8, text, s)) return .let_style;
    }
    for (if_forms) |s| {
        if (std.mem.eql(u8, text, s)) return .if_style;
    }
    for (each_forms) |s| {
        if (std.mem.eql(u8, text, s)) return .each_line;
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Pretty-printer
// ---------------------------------------------------------------------------

const Printer = struct {
    out: std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) Printer {
        return .{ .out = .empty, .alloc = alloc };
    }

    fn toOwnedSlice(self: *Printer) ![]u8 {
        return self.out.toOwnedSlice(self.alloc);
    }

    fn write(self: *Printer, s: []const u8) !void {
        try self.out.appendSlice(self.alloc, s);
    }

    fn writeChar(self: *Printer, c: u8) !void {
        try self.out.append(self.alloc, c);
    }

    fn writeIndent(self: *Printer, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) try self.writeChar(' ');
    }

    fn printNode(self: *Printer, node: Node, col: usize, indent: usize) anyerror!void {
        switch (node.tag) {
            .atom, .comment => try self.write(node.text),
            .prefixed => {
                try self.write(node.text);
                if (node.children.len > 0) {
                    try self.printNode(node.children[0], col + node.text.len, indent);
                }
            },
            .list => try self.printList(node, col, indent),
        }
    }

    fn printList(self: *Printer, node: Node, col: usize, indent: usize) anyerror!void {
        const children = node.children;

        // Empty list
        if (children.len == 0) {
            try self.write("()");
            return;
        }

        // Try inline: fits on line and no comment children
        const w = measure(node);
        if (col + w <= 80 and !hasCommentChild(node)) {
            try self.writeChar('(');
            for (children, 0..) |child, i| {
                if (i > 0) try self.writeChar(' ');
                try self.printNode(child, col + 1, indent);
            }
            try self.writeChar(')');
            return;
        }

        // Expanded — determine style from head
        const head = children[0];
        const style: FormStyle = blk: {
            if (head.tag == .atom) {
                break :blk classifyHead(head.text);
            }
            break :blk .none;
        };

        switch (style) {
            .body2 => try self.printBody2(children, col, indent),
            .let_style => try self.printLetStyle(children, col, indent),
            .if_style => try self.printIfStyle(children, col, indent),
            .each_line => try self.printEachLine(children, col, indent),
            .none, .default => try self.printDefault(children, col, indent),
        }
    }

    /// body-2: (head first-arg\n  body...)
    fn printBody2(self: *Printer, children: []Node, col: usize, indent: usize) !void {
        try self.writeChar('(');
        try self.printNode(children[0], col + 1, indent + 2);

        if (children.len > 1) {
            try self.writeChar(' ');
            try self.printNode(children[1], col + 1 + measure(children[0]) + 1, indent + 2);
        }

        var i: usize = 2;
        while (i < children.len) : (i += 1) {
            try self.writeChar('\n');
            try self.writeIndent(indent + 2);
            try self.printNode(children[i], indent + 2, indent + 2);
        }
        try self.writeChar(')');
    }

    /// let-style: (let BINDINGS\n  body...)
    fn printLetStyle(self: *Printer, children: []Node, col: usize, indent: usize) !void {
        try self.writeChar('(');
        try self.printNode(children[0], col + 1, indent + 2);

        if (children.len > 1) {
            const bindings_col = col + 1 + measure(children[0]) + 1;
            try self.writeChar(' ');
            try self.printNode(children[1], bindings_col, indent + 2);
        }

        var i: usize = 2;
        while (i < children.len) : (i += 1) {
            try self.writeChar('\n');
            try self.writeIndent(indent + 2);
            try self.printNode(children[i], indent + 2, indent + 2);
        }
        try self.writeChar(')');
    }

    /// if-style: (if TEST\n  THEN\n  ELSE)
    fn printIfStyle(self: *Printer, children: []Node, col: usize, indent: usize) !void {
        _ = col;
        try self.writeChar('(');
        try self.printNode(children[0], indent + 1, indent + 2);

        if (children.len > 1) {
            try self.writeChar(' ');
            try self.printNode(children[1], indent + 4, indent + 2);
        }

        var i: usize = 2;
        while (i < children.len) : (i += 1) {
            try self.writeChar('\n');
            try self.writeIndent(indent + 2);
            try self.printNode(children[i], indent + 2, indent + 2);
        }
        try self.writeChar(')');
    }

    /// each-line: (head\n  child1\n  child2...)
    fn printEachLine(self: *Printer, children: []Node, col: usize, indent: usize) !void {
        _ = col;
        try self.writeChar('(');
        try self.printNode(children[0], indent + 1, indent + 2);

        var i: usize = 1;
        while (i < children.len) : (i += 1) {
            try self.writeChar('\n');
            try self.writeIndent(indent + 2);
            try self.printNode(children[i], indent + 2, indent + 2);
        }
        try self.writeChar(')');
    }

    /// default: (head first-arg\n        subsequent-args-aligned)
    fn printDefault(self: *Printer, children: []Node, col: usize, indent: usize) !void {
        _ = indent;
        try self.writeChar('(');
        try self.printNode(children[0], col + 1, col + 1);

        if (children.len <= 1) {
            try self.writeChar(')');
            return;
        }

        try self.writeChar(' ');
        const first_arg_col = col + 1 + measure(children[0]) + 1;
        try self.printNode(children[1], first_arg_col, first_arg_col);

        var i: usize = 2;
        while (i < children.len) : (i += 1) {
            try self.writeChar('\n');
            try self.writeIndent(first_arg_col);
            try self.printNode(children[i], first_arg_col, first_arg_col);
        }
        try self.writeChar(')');
    }

    /// Format a complete file (top-level forms with spacing).
    fn printForms(self: *Printer, forms: []Node) !void {
        var i: usize = 0;
        while (i < forms.len) : (i += 1) {
            const form = forms[i];

            if (i > 0) {
                if (needsBlankLineBefore(forms, i)) {
                    try self.write("\n\n");
                } else {
                    try self.writeChar('\n');
                }
            }

            try self.printNode(form, 0, 0);
        }

        // File ends with exactly one newline.
        if (forms.len > 0) try self.writeChar('\n');
    }
};

fn isFunctionDefine(node: Node) bool {
    if (node.tag != .list) return false;
    if (node.children.len < 2) return false;
    const head = node.children[0];
    if (head.tag != .atom) return false;
    if (!std.mem.eql(u8, head.text, "define")) return false;
    return node.children[1].tag == .list;
}

// Returns true when a blank line should precede forms[i].
// Rules:
//   1. Function-style define gets a blank line, unless immediately preceded
//      by a comment (which serves as its header — blank line goes before that).
//   2. A comment gets a blank line when it leads into a function-style define
//      and is not already part of an ongoing comment block.
fn needsBlankLineBefore(forms: []const Node, i: usize) bool {
    const form = forms[i];
    if (isFunctionDefine(form)) {
        // Comment immediately before is the function header — blank line
        // already belongs before the comment, not here.
        return forms[i - 1].tag != .comment;
    }
    if (form.tag == .comment) {
        // Already in a comment block — no extra blank line.
        if (forms[i - 1].tag == .comment) return false;
        // Look past contiguous comments to see if a function define follows.
        var j = i + 1;
        while (j < forms.len and forms[j].tag == .comment) j += 1;
        return j < forms.len and isFunctionDefine(forms[j]);
    }
    return false;
}

// ---------------------------------------------------------------------------
// Format a single source string
// ---------------------------------------------------------------------------

// zepo-hdhl: a formatter must only ever change whitespace. Tokenize both the
// input and the formatted output and require an identical (kind, text) token
// stream — comments included. This is a hard guarantee that reformatting can
// never silently corrupt or drop code; on any mismatch the caller keeps the
// original file untouched.
fn tokenStreamsMatch(a: []const u8, b: []const u8) bool {
    var ta = Tokenizer.init(a);
    var tb = Tokenizer.init(b);
    while (true) {
        const x = ta.next();
        const y = tb.next();
        if (x.kind != y.kind) return false;
        if (x.kind == .eof) return true;
        if (!std.mem.eql(u8, x.text, y.text)) return false;
    }
}

pub fn formatSource(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parser = Parser.init(src, arena);
    const forms = try parser.parseAll();

    var printer = Printer.init(alloc);
    try printer.printForms(forms);
    const formatted = try printer.toOwnedSlice();

    // zepo-hdhl: refuse to emit output that isn't token-identical to the input.
    if (!tokenStreamsMatch(src, formatted)) {
        alloc.free(formatted);
        return error.FormatWouldCorrupt;
    }
    return formatted;
}

// ---------------------------------------------------------------------------
// File discovery helpers
// ---------------------------------------------------------------------------

// zepo-n3h

// ---------------------------------------------------------------------------
// Tests (zepo-hdhl)
// ---------------------------------------------------------------------------

test "format: char literals incl. delimiters survive verbatim" {
    const a = std.testing.allocator;
    const out = try formatSource(a, "(list #\\( #\\) #\\; #\\\" #\\space #\\newline #\\a)");
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "#\\(") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "#\\)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "#\\;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "#\\space") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "#\\newline") != null);
}

test "format: unmatched close paren errors instead of truncating" {
    const a = std.testing.allocator;
    // (foo)) (bar) used to format to just "(foo)" — dropping (bar).
    try std.testing.expectError(error.UnmatchedRparen, formatSource(a, "(foo)) (bar)"));
}

test "format: unterminated string does not corrupt or panic" {
    const a = std.testing.allocator;
    // trailing lone backslash at EOF inside an unterminated string
    try std.testing.expectError(error.FormatWouldCorrupt, formatSource(a, "(define s \"abc\\"));
}

test "format: valid code is token-preserving and idempotent" {
    const a = std.testing.allocator;
    const src = "(define (f x)\n(if (< x 0) 'neg (list #\\( x)))\n; keep me\n";
    const out1 = try formatSource(a, src);
    defer a.free(out1);
    // token-identical to the input (the round-trip guard would have errored)
    try std.testing.expect(tokenStreamsMatch(src, out1));
    // and stable under a second pass
    const out2 = try formatSource(a, out1);
    defer a.free(out2);
    try std.testing.expectEqualStrings(out1, out2);
}
