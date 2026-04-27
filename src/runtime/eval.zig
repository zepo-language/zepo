//! End-to-end evaluation context.
//!
//! Wires parser → expander → AST builder → sema → IR compiler → emitter → VM
//! into a single reusable harness. Each `evalString` call re-emits the full
//! Program (cheap: the IR Program and NodeArena persist across calls so
//! previously-compiled functions stay at stable indexes, and closures stored
//! in globals that reference by `code_id` remain valid after re-emission).

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;
const HandleScope = gc_mod.HandleScope;

const objects_mod = @import("objects.zig");
const symbols_mod = @import("symbols.zig");
const globals_mod = @import("globals.zig");
const module_mod = @import("module.zig");
const package_mod = @import("package.zig");
const SymbolTable = symbols_mod.SymbolTable;
const GlobalEnv = globals_mod.GlobalEnv;
const Module = module_mod.Module;
const ModuleRegistry = module_mod.ModuleRegistry;
const PackageRegistry = package_mod.PackageRegistry;
const PackageInfo = package_mod.PackageInfo;

const reader_mod = @import("../reader/mod.zig");
const Parser = reader_mod.Parser;
const SpanTable = reader_mod.SpanTable;

const expand_mod = @import("../expand/mod.zig");

const ast_mod = @import("../ast/mod.zig");
const NodeArena = ast_mod.NodeArena;
const Builder = ast_mod.Builder;

const sema_mod = @import("../sema/mod.zig");

const ir_mod = @import("../ir/mod.zig");
const Program = ir_mod.Program;
const Compiler = ir_mod.Compiler;

const cg_mod = @import("../cg/mod.zig");
const Emitter = cg_mod.Emitter;
const CompiledFn = cg_mod.CompiledFn;

const vm_mod = @import("../vm/mod.zig");
const VM = vm_mod.VM;

const runtime_objects = @import("objects.zig");
const macros = @import("macros.zig");
const mod_loader = @import("module_loader.zig");
const errs = @import("errors.zig");

pub const EvalContext = struct {
    gc: *GC,
    symbols: *SymbolTable,
    globals: *GlobalEnv,
    allocator: std.mem.Allocator,

    // Module system.
    registry: ModuleRegistry,
    packages: PackageRegistry,
    current_module: ?*Module = null,
    module_path: []const []const u8 = &.{},

    // Persistent across calls: AST arena and IR program accumulate.
    arena: NodeArena,
    program: Program,
    emitter: Emitter,
    spans: SpanTable,

    // Current compiled bytecode (re-emitted each eval), owned by this context.
    compiled: ?[]CompiledFn,
    vm: ?VM,

    // Macro transformer registry. Keys are owned slices; values are closure
    // Values also stored in globals (so GC can reach them).
    macro_names: std.StringHashMap(void),

    // When non-null, records module_name → file_path for every module loaded
    // from disk via tryAutoLoad. Used by `zepo build` for bundling.
    module_file_log: ?*std.StringHashMap([]const u8) = null,

    pub fn init(
        gc: *GC,
        symbols: *SymbolTable,
        globals: *GlobalEnv,
        allocator: std.mem.Allocator,
    ) !EvalContext {
        return .{
            .gc = gc,
            .symbols = symbols,
            .globals = globals,
            .allocator = allocator,
            .registry = ModuleRegistry.init(allocator, gc),
            .packages = PackageRegistry.init(allocator),
            .current_module = null,
            .arena = NodeArena.init(allocator),
            .program = Program.init(allocator),
            .emitter = Emitter.init(allocator, symbols, gc),
            .spans = SpanTable.init(allocator),
            .compiled = null,
            .vm = null,
            .macro_names = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(ctx: *EvalContext) void {
        if (ctx.vm) |*v| v.deinit();
        if (ctx.compiled) |cs| {
            for (cs) |*cf| cf.deinit(ctx.allocator);
            ctx.allocator.free(cs);
        }
        ctx.emitter.deinit();
        ctx.program.deinit();
        ctx.arena.deinit();
        ctx.spans.deinit();
        ctx.registry.deinit();
        ctx.packages.deinit();
        var kit = ctx.macro_names.keyIterator();
        while (kit.next()) |k| ctx.allocator.free(k.*);
        ctx.macro_names.deinit();
    }

    /// Returns the currently-active global environment: the current module's
    /// env if inside a `(module ...)` body, else the top-level `globals`.
    pub fn currentEnv(ctx: *EvalContext) *GlobalEnv {
        if (ctx.current_module) |m| return &m.env;
        return ctx.globals;
    }

    /// Enter a module's scope. All subsequent define/set!/lookup against the
    /// active env target this module until `leaveModule` is called.
    pub fn enterModule(ctx: *EvalContext, m: *Module) void {
        std.debug.assert(ctx.current_module == null);
        ctx.current_module = m;
    }

    /// Leave the module's scope and mark it fully initialised.
    pub fn leaveModule(ctx: *EvalContext) void {
        if (ctx.current_module) |m| {
            m.initialized = true;
        }
        ctx.current_module = null;
    }

    /// Evaluate all expressions in `src` and return the value of the last one
    /// (or NIL for an empty source).
    pub fn evalString(ctx: *EvalContext, src: []const u8, file: []const u8) !Value {
        var parser = Parser.init(ctx.gc, ctx.symbols, &ctx.spans, src, file, ctx.allocator);
        defer parser.deinit();

        var last: Value = value_mod.NIL;

        while (true) {
            const form = parser.readOne() catch |err| switch (err) {
                error.Eof => break,
                else => return err,
            };
            last = try ctx.evalForm(form);
        }
        return last;
    }

    /// Evaluate one already-parsed S-expression Value. Re-emits and runs via VM.
    pub fn evalForm(ctx: *EvalContext, form: Value) !Value {
        // Top-level module/import/export recognition. These are strictly
        // compile-time forms and never lower to IR directly.
        if (isHeadSymbol(form, "module")) {
            return mod_loader.evalModuleDecl(ctx, form);
        }
        if (isHeadSymbol(form, "import")) {
            return mod_loader.evalImport(ctx, form);
        }
        if (isHeadSymbol(form, "export")) {
            // `export` is only meaningful inside `(module ...)`. The module
            // handler consumes it; seeing it here means it leaked.
            return error.ExportOutsideModule;
        }
        if (isHeadSymbol(form, "include")) {
            return mod_loader.evalInclude(ctx, form);
        }
        if (isHeadSymbol(form, "package")) {
            return mod_loader.evalPackageDecl(ctx, form);
        }
        if (isHeadSymbol(form, "defmacro")) {
            return macros.evalDefmacro(ctx, form);
        }

        return ctx.evalNonModuleForm(form);
    }

    pub fn evalNonModuleForm(ctx: *EvalContext, form: Value) !Value {
        // Phase 1: quasiquote desugaring.
        const qq_expanded = try expand_mod.expand(form, ctx.symbols, ctx.gc);
        // Phase 2: macro expansion (requires VM to exist for transformer calls).
        const expanded = if (ctx.vm != null)
            try macros.macroExpand(ctx, qq_expanded)
        else
            qq_expanded;

        var builder = Builder.init(&ctx.arena, ctx.symbols, ctx.allocator);
        builder.span_table = &ctx.spans;
        const root_id = try builder.build(expanded);

        var analyzer = sema_mod.CaptureAnalyzer.init(&ctx.arena, ctx.allocator);
        try analyzer.analyze(root_id);

        var compiler = Compiler.initWithGc(&ctx.arena, &ctx.program, ctx.symbols, ctx.gc, ctx.allocator);
        const fn_id = try compiler.compileExpr(root_id);

        // Reserve nursery space BEFORE tearing down the old VM so that the
        // minor GC (if triggered) still has a live root visitor.  The emitter
        // allocates fresh GC strings/floats for every load_string/load_float op;
        // without reserved space a GC could fire mid-emit with no root visitor.
        try ctx.gc.reserveNursery(16 * 1024);

        // Re-emit the full program (including new functions appended above).
        if (ctx.compiled) |old| {
            for (old) |*cf| cf.deinit(ctx.allocator);
            ctx.allocator.free(old);
            ctx.compiled = null;
        }
        if (ctx.vm) |*v| {
            v.deinit();
            ctx.vm = null;
        }
        ctx.compiled = try ctx.emitter.emit(&ctx.program);
        // The VM always sees the currently-active env — if we're inside a
        // module, that's the module's env; the top-level globals become the
        // read-only fallback so the module body can call prims/prelude.
        ctx.vm = try VM.init(ctx.gc, ctx.currentEnv(), ctx.symbols, ctx.compiled.?, ctx.allocator);
        if (ctx.current_module != null) {
            ctx.vm.?.fallback_globals = ctx.globals;
        }
        ctx.vm.?.do_import = vmImportCallback;
        ctx.vm.?.do_import_ctx = ctx;
        ctx.vm.?.installAsRoot();

        return ctx.vm.?.run(fn_id, &.{});
    }
};

fn vmImportCallback(ctx_opaque: *anyopaque, name: []const u8, alias: ?[]const u8, only: ?[]const []const u8) errs.LispError!void {
    const ctx: *EvalContext = @ptrCast(@alignCast(ctx_opaque));
    return mod_loader.doImportByName(ctx, name, alias, only);
}

pub fn isHeadSymbol(v: Value, expected: []const u8) bool {
    const objects = runtime_objects;
    if (!value_mod.isPtr(v)) return false;
    if (!objects.isPair(v)) return false;
    const head = objects.pairCar(v).*;
    if (!objects.isSymbol(head)) return false;
    return std.mem.eql(u8, objects.symbolName(head), expected);
}
