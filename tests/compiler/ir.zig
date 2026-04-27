const std = @import("std");
const zepo = @import("zepo");
const GC = zepo.GC;
const abi = zepo.abi;
const value_mod = abi.value;
const runtime = zepo.runtime;
const SymbolTable = runtime.SymbolTable;
const reader_mod = zepo.reader;
const Parser = reader_mod.Parser;
const SpanTable = reader_mod.SpanTable;

const ast_mod = zepo.ast;
const NodeArena = ast_mod.NodeArena;
const Builder = ast_mod.Builder;

const sema_mod = zepo.sema;
const ir_mod = zepo.ir;
const Program = ir_mod.Program;
const Compiler = ir_mod.Compiler;

const alloc = std.testing.allocator;

fn compileSrc(
    gc: *GC,
    syms: *SymbolTable,
    spans: *SpanTable,
    arena: *NodeArena,
    program: *Program,
    src: []const u8,
) !u32 {
    var p = Parser.init(gc, syms, spans, src, "<test>", alloc);
    defer p.deinit();
    const v = try p.readOne();
    var b = Builder.init(arena, syms, alloc);
    const root_id = try b.build(v);

    var analyzer = sema_mod.CaptureAnalyzer.init(arena, alloc);
    try analyzer.analyze(root_id);

    var compiler = Compiler.init(arena, program, syms, alloc);
    return compiler.compileExpr(root_id);
}

fn countOpKind(ops: []const ir_mod.Op, comptime tag: @Type(.enum_literal)) usize {
    var n: usize = 0;
    for (ops) |op| {
        if (op == tag) n += 1;
    }
    return n;
}

fn setupAll() !struct { gc: GC, syms: SymbolTable, spans: SpanTable, arena: NodeArena, program: Program } {
    @compileError("use inline setup in each test");
}

test "compile literal 42" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();
    var program = Program.init(alloc);
    defer program.deinit();

    const fn_id = try compileSrc(&gc, &syms, &spans, &arena, &program, "42");
    const f = &program.functions.items[fn_id];
    try std.testing.expect(countOpKind(f.ops.items, .load_const) >= 1);
    try std.testing.expect(countOpKind(f.ops.items, .ret) == 1);
}

test "compile lambda creates closure" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();
    var program = Program.init(alloc);
    defer program.deinit();

    _ = try compileSrc(&gc, &syms, &spans, &arena, &program, "(lambda (x) x)");
    try std.testing.expect(program.functions.items.len >= 2);
    const outer = &program.functions.items[0];
    try std.testing.expect(countOpKind(outer.ops.items, .make_closure) == 1);
    const inner = &program.functions.items[1];
    try std.testing.expect(countOpKind(inner.ops.items, .load_local) >= 1);
    try std.testing.expect(countOpKind(inner.ops.items, .ret) == 1);
}

test "compile if" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();
    var program = Program.init(alloc);
    defer program.deinit();

    _ = try compileSrc(&gc, &syms, &spans, &arena, &program, "(if #t 1 2)");
    const f = &program.functions.items[0];
    try std.testing.expect(countOpKind(f.ops.items, .branch_if) == 1);
    try std.testing.expect(countOpKind(f.ops.items, .branch) >= 2);
    try std.testing.expect(countOpKind(f.ops.items, .label) >= 3);
}

test "compile define emits store_global" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();
    var program = Program.init(alloc);
    defer program.deinit();

    _ = try compileSrc(&gc, &syms, &spans, &arena, &program, "(define foo 42)");
    const f = &program.functions.items[0];
    try std.testing.expect(countOpKind(f.ops.items, .store_global) == 1);
}

test "compile mutated param introduces box" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();
    var program = Program.init(alloc);
    defer program.deinit();

    _ = try compileSrc(&gc, &syms, &spans, &arena, &program, "(lambda (x) (set! x 5) x)");
    try std.testing.expect(program.functions.items.len >= 2);
    const inner = &program.functions.items[1];
    try std.testing.expect(countOpKind(inner.ops.items, .alloc_box) >= 1);
    try std.testing.expect(countOpKind(inner.ops.items, .store_box) >= 1);
    try std.testing.expect(countOpKind(inner.ops.items, .load_box) >= 1);
}

test "call safepoints have root maps" {
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var spans = SpanTable.init(alloc);
    defer spans.deinit();
    var arena = NodeArena.init(alloc);
    defer arena.deinit();
    var program = Program.init(alloc);
    defer program.deinit();

    _ = try compileSrc(&gc, &syms, &spans, &arena, &program, "(foo 1 2)");
    const f = &program.functions.items[0];
    try std.testing.expect(countOpKind(f.ops.items, .call) == 1);
    try std.testing.expect(countOpKind(f.ops.items, .safepoint) == 1);
    try std.testing.expect(f.root_maps.items.len >= 1);
    const rm = f.root_maps.items[0];
    try std.testing.expect(rm.live_regs.len >= 3);
}
