//! End-to-end VM execution tests: parse → AST → sema → IR → bytecode → execute.

const std = @import("std");
const zepo = @import("zepo");
const GC = zepo.GC;
const abi = zepo.abi;
const value_mod = abi.value;
const runtime = zepo.runtime;
const SymbolTable = runtime.SymbolTable;
const GlobalEnv = runtime.GlobalEnv;
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
const cg = zepo.cg;
const vm_mod = zepo.vm;
const prims = zepo.prims;

const alloc = std.testing.allocator;

/// Rig that owns every subsystem needed for one or more expressions.
const Rig = struct {
    gc: GC,
    syms: SymbolTable,
    globals: GlobalEnv,
    spans: SpanTable,
    arena: NodeArena,
    program: Program,
    emitter: cg.Emitter,
    compiled: ?[]*cg.CompiledFn = null, // zepo-nhl: boxed for pointer stability
    vm: ?vm_mod.VM = null,

    pub fn init() !*Rig {
        const r = try alloc.create(Rig);
        errdefer alloc.destroy(r);
        r.compiled = null;
        r.vm = null;
        r.gc = try GC.init(alloc);
        r.syms = try SymbolTable.init(&r.gc, alloc);
        r.globals = try GlobalEnv.init(&r.gc, alloc);
        r.spans = SpanTable.init(alloc);
        r.arena = NodeArena.init(alloc);
        r.program = Program.init(alloc);
        r.emitter = cg.Emitter.init(alloc, &r.syms, &r.gc);
        try prims.registerAll(&r.gc, &r.globals, &r.syms);
        return r;
    }

    // zepo-nhl: emit the program then box each fn so VM.init's []*CompiledFn
    // param is satisfied and pointers stay stable. Caller owns the result.
    fn emitBoxed(r: *Rig) ![]*cg.CompiledFn {
        const vals = try r.emitter.emit(&r.program);
        defer alloc.free(vals);
        const boxed = try alloc.alloc(*cg.CompiledFn, vals.len);
        errdefer alloc.free(boxed);
        for (vals, 0..) |v, i| {
            const b = try alloc.create(cg.CompiledFn);
            b.* = v;
            boxed[i] = b;
        }
        return boxed;
    }

    fn freeBoxed(cs: []*cg.CompiledFn) void {
        for (cs) |cf| {
            cf.deinit(alloc);
            alloc.destroy(cf);
        }
        alloc.free(cs);
    }

    pub fn deinit(r: *Rig) void {
        if (r.vm) |*v| v.deinit();
        if (r.compiled) |cs| {
            freeBoxed(cs); // zepo-nhl
        }
        r.emitter.deinit();
        r.program.deinit();
        r.arena.deinit();
        r.spans.deinit();
        r.globals.deinit();
        r.syms.deinit();
        r.gc.deinit();
        alloc.destroy(r);
    }

    /// Compile a single top-level expression string and run it, returning the
    /// resulting Value.
    pub fn run(r: *Rig, src: []const u8) !abi.Value {
        // Parse.
        var p = Parser.init(&r.gc, &r.syms, &r.spans, src, "<test>", alloc);
        defer p.deinit();
        const v = try p.readOne();
        // AST.
        var b = Builder.init(&r.arena, &r.syms, alloc);
        const root_id = try b.build(v);
        // Sema.
        var analyzer = sema_mod.CaptureAnalyzer.init(&r.arena, alloc);
        try analyzer.analyze(root_id);
        // IR.
        var compiler = Compiler.init(&r.arena, &r.program, &r.syms, alloc);
        const fn_id = try compiler.compileExpr(root_id);

        // Emit fresh bytecode (re-emit whole program — cheap for tests).
        if (r.compiled) |old| {
            freeBoxed(old); // zepo-nhl
            r.compiled = null;
        }
        if (r.vm) |*v2| v2.deinit();
        r.vm = null;

        r.compiled = try r.emitBoxed(); // zepo-nhl
        r.vm = try vm_mod.VM.init(&r.gc, &r.globals, &r.syms, r.compiled.?, alloc, vm_mod.VM.MAX_REGS);
        r.vm.?.installAsRoot();

        return try r.vm.?.run(fn_id, &.{});
    }
};

test "eval fixnum literal" {
    const r = try Rig.init();
    defer r.deinit();
    const v = try r.run("42");
    try std.testing.expect(value_mod.isFixnum(v));
    try std.testing.expectEqual(@as(i63, 42), value_mod.fixnumVal(v));
}

test "eval (+ 1 2)" {
    const r = try Rig.init();
    defer r.deinit();
    const v = try r.run("(+ 1 2)");
    try std.testing.expect(value_mod.isFixnum(v));
    try std.testing.expectEqual(@as(i63, 3), value_mod.fixnumVal(v));
}

test "eval (* 3 4)" {
    const r = try Rig.init();
    defer r.deinit();
    const v = try r.run("(* 3 4)");
    try std.testing.expectEqual(@as(i63, 12), value_mod.fixnumVal(v));
}

test "eval (if #t 1 2)" {
    const r = try Rig.init();
    defer r.deinit();
    const v = try r.run("(if #t 1 2)");
    try std.testing.expectEqual(@as(i63, 1), value_mod.fixnumVal(v));
}

test "eval (if #f 1 2)" {
    const r = try Rig.init();
    defer r.deinit();
    const v = try r.run("(if #f 1 2)");
    try std.testing.expectEqual(@as(i63, 2), value_mod.fixnumVal(v));
}

test "eval (lambda (x) x) produces a closure" {
    const r = try Rig.init();
    defer r.deinit();
    const v = try r.run("(lambda (x) x)");
    try std.testing.expect(runtime.objects.isClosure(v));
}

test "eval ((lambda (x) x) 42)" {
    const r = try Rig.init();
    defer r.deinit();
    const v = try r.run("((lambda (x) x) 42)");
    try std.testing.expectEqual(@as(i63, 42), value_mod.fixnumVal(v));
}

test "eval ((lambda (x y) (+ x y)) 3 4)" {
    const r = try Rig.init();
    defer r.deinit();
    const v = try r.run("((lambda (x y) (+ x y)) 3 4)");
    try std.testing.expectEqual(@as(i63, 7), value_mod.fixnumVal(v));
}

test "define then lookup" {
    const r = try Rig.init();
    defer r.deinit();
    _ = try r.run("(define foo 99)");
    const v = try r.run("foo");
    try std.testing.expectEqual(@as(i63, 99), value_mod.fixnumVal(v));
}

test "car/cdr of cons" {
    const r = try Rig.init();
    defer r.deinit();
    const a = try r.run("(car (cons 1 2))");
    try std.testing.expectEqual(@as(i63, 1), value_mod.fixnumVal(a));
    const b = try r.run("(cdr (cons 1 2))");
    try std.testing.expectEqual(@as(i63, 2), value_mod.fixnumVal(b));
}

test "null? and pair?" {
    const r = try Rig.init();
    defer r.deinit();
    const v1 = try r.run("(null? (quote ()))");
    try std.testing.expectEqual(value_mod.TRUE, v1);
    const v2 = try r.run("(pair? (cons 1 2))");
    try std.testing.expectEqual(value_mod.TRUE, v2);
}

test "(not #f) returns #t" {
    const r = try Rig.init();
    defer r.deinit();
    const v = try r.run("(not #f)");
    try std.testing.expectEqual(value_mod.TRUE, v);
}

test "comparisons" {
    const r = try Rig.init();
    defer r.deinit();
    try std.testing.expectEqual(value_mod.TRUE, try r.run("(< 1 2)"));
    try std.testing.expectEqual(value_mod.FALSE, try r.run("(> 1 2)"));
    try std.testing.expectEqual(value_mod.TRUE, try r.run("(= 3 3)"));
}

test "proper tail calls — deep loop" {
    const r = try Rig.init();
    defer r.deinit();
    _ = try r.run("(define loop (lambda (n) (if (= n 0) #t (loop (- n 1)))))");
    const v = try r.run("(loop 100000)");
    try std.testing.expectEqual(value_mod.TRUE, v);
}

test "closure captures outer" {
    const r = try Rig.init();
    defer r.deinit();
    _ = try r.run("(define make-adder (lambda (n) (lambda (x) (+ x n))))");
    _ = try r.run("(define add5 (make-adder 5))");
    const v = try r.run("(add5 10)");
    try std.testing.expectEqual(@as(i63, 15), value_mod.fixnumVal(v));
}
