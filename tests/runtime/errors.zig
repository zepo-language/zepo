//! Runtime error tests.

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

const Rig = struct {
    gc: GC,
    syms: SymbolTable,
    globals: GlobalEnv,
    spans: SpanTable,
    arena: NodeArena,
    program: Program,
    emitter: cg.Emitter,
    compiled: ?[]cg.CompiledFn = null,
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

    pub fn deinit(r: *Rig) void {
        if (r.vm) |*v| v.deinit();
        if (r.compiled) |cs| {
            for (cs) |*cf| cf.deinit(alloc);
            alloc.free(cs);
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

    pub fn runWithMaxRegs(r: *Rig, src: []const u8, max_regs: usize) !abi.Value {
        var p = Parser.init(&r.gc, &r.syms, &r.spans, src, "<test>", alloc);
        defer p.deinit();
        const v = try p.readOne();
        var b = Builder.init(&r.arena, &r.syms, alloc);
        const root_id = try b.build(v);
        var analyzer = sema_mod.CaptureAnalyzer.init(&r.arena, alloc);
        try analyzer.analyze(root_id);
        var compiler = Compiler.init(&r.arena, &r.program, &r.syms, alloc);
        const fn_id = try compiler.compileExpr(root_id);

        if (r.compiled) |old| {
            for (old) |*cf| cf.deinit(alloc);
            alloc.free(old);
            r.compiled = null;
        }
        if (r.vm) |*v2| v2.deinit();
        r.vm = null;

        r.compiled = try r.emitter.emit(&r.program);
        r.vm = try vm_mod.VM.init(&r.gc, &r.globals, &r.syms, r.compiled.?, alloc, max_regs);
        r.vm.?.installAsRoot();
        return try r.vm.?.run(fn_id, &.{});
    }

    pub fn run(r: *Rig, src: []const u8) !abi.Value {
        var p = Parser.init(&r.gc, &r.syms, &r.spans, src, "<test>", alloc);
        defer p.deinit();
        const v = try p.readOne();
        var b = Builder.init(&r.arena, &r.syms, alloc);
        const root_id = try b.build(v);
        var analyzer = sema_mod.CaptureAnalyzer.init(&r.arena, alloc);
        try analyzer.analyze(root_id);
        var compiler = Compiler.init(&r.arena, &r.program, &r.syms, alloc);
        const fn_id = try compiler.compileExpr(root_id);

        if (r.compiled) |old| {
            for (old) |*cf| cf.deinit(alloc);
            alloc.free(old);
            r.compiled = null;
        }
        if (r.vm) |*v2| v2.deinit();
        r.vm = null;

        r.compiled = try r.emitter.emit(&r.program);
        r.vm = try vm_mod.VM.init(&r.gc, &r.globals, &r.syms, r.compiled.?, alloc, vm_mod.VM.MAX_REGS);
        r.vm.?.installAsRoot();
        return try r.vm.?.run(fn_id, &.{});
    }
};

test "(car 42) raises CarOfNonPair" {
    const r = try Rig.init();
    defer r.deinit();
    try std.testing.expectError(error.CarOfNonPair, r.run("(car 42)"));
}

test "(/ 1 0) raises DivisionByZero" {
    const r = try Rig.init();
    defer r.deinit();
    try std.testing.expectError(error.DivisionByZero, r.run("(/ 1 0)"));
}

test "(+ \"a\" 1) raises TypeError" {
    const r = try Rig.init();
    defer r.deinit();
    try std.testing.expectError(error.TypeError, r.run("(+ \"a\" 1)"));
}

test "unbound variable raises UnboundVariable" {
    const r = try Rig.init();
    defer r.deinit();
    try std.testing.expectError(error.UnboundVariable, r.run("xyzzy-unbound"));
}

// zepo-01r: StackOverflow must propagate as error.StackOverflow, not panic or OutOfMemory.
// Regression classes tested:
//   (a) guard removed from pushFast (zepo-7be dropped it → SIGBUS/panic on CALL path)
//   (b) execFn initial push using `catch return error.OutOfMemory` (→ wrong label on first-frame overflow)
//   (c) CALL dispatch push using `catch return error.OutOfMemory` (→ wrong label on recursive overflow)

test "deep non-tail recursion raises StackOverflow (CALL dispatch path)" {
    const r = try Rig.init();
    defer r.deinit();
    // zepo-01r: overflow happens on recursive CALL, not initial execFn push — covers (a) and (c)
    const src =
        \\(begin
        \\  (define (count-down n)
        \\    (if (= n 0) 0 (+ 1 (count-down (- n 1)))))
        \\  (count-down 100000))
    ;
    try std.testing.expectError(error.StackOverflow, r.runWithMaxRegs(src, 256));
}

test "initial frame too large raises StackOverflow (execFn push path)" {
    const r = try Rig.init();
    defer r.deinit();
    // zepo-01r: zero-capacity pool overflows on any first push — covers (b)
    try std.testing.expectError(error.StackOverflow, r.runWithMaxRegs("(if #t 1 2)", 0));
}
