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
const SymbolTable = symbols_mod.SymbolTable;
const GlobalEnv = globals_mod.GlobalEnv;
const Module = module_mod.Module;
const ModuleRegistry = module_mod.ModuleRegistry;

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

const register_mod = @import("../prims/register.zig");

pub const EvalContext = struct {
    gc: *GC,
    symbols: *SymbolTable,
    globals: *GlobalEnv,
    allocator: std.mem.Allocator,

    // Module system.
    registry: ModuleRegistry,
    current_module: ?*Module = null,
    /// Project-local module search paths (project.lisp dirs, ZEPO_PATH).
    module_path: []const []const u8 = &.{},
    /// Installed library search paths (~/.local/lib/zepo/<pkg>/).
    lib_path: []const []const u8 = &.{},
    /// Installed package root paths (~/.local/lib/zepo/).
    package_path: []const []const u8 = &.{},

    // Persistent across calls: AST arena and IR program accumulate.
    arena: NodeArena,
    program: Program,
    emitter: Emitter,
    spans: SpanTable,

    // Accumulated compiled bytecode; grows incrementally across evals.
    compiled: std.ArrayListUnmanaged(CompiledFn),
    vm: ?VM,
    vm_max_regs: usize = VM.MAX_REGS,

    // Macro transformer registry. Keys are owned slices; values are closure
    // Values also stored in globals (so GC can reach them).
    macro_names: std.StringHashMap(void),

    // When non-null, records module_name → file_path for every module loaded
    // from disk via tryAutoLoad. Used by `zepo build` for bundling.
    module_file_log: ?*std.StringHashMap([]const u8) = null,
    // Insertion-ordered list of module names (parallel to module_file_log map).
    module_file_order: ?*std.ArrayListUnmanaged([]const u8) = null,
    // When non-null, each top-level fn_id is appended here before the VM runs
    // it. Used by `zepo install` to record which fns are top-level thunks.
    toplevel_fn_ids: ?*std.ArrayListUnmanaged(u32) = null,
    // Owns the name-string buffers deserialized from .zbc files. Each entry
    // is a contiguous block that backs CompiledFn.names slices.
    zbc_name_bufs: std.ArrayListUnmanaged([]u8) = .empty,
    /// Heap-allocated module_path slice headers (from tryImportPackage extensions).
    owned_module_path_slices: std.ArrayListUnmanaged([][]const u8) = .empty,
    /// Individual strings owned by tryImportPackage (src_dir allocations).
    owned_module_path_dirs: std.ArrayListUnmanaged([]const u8) = .empty,

    // Error diagnostics — populated on the first error, used by CLI formatters.
    last_error_span: ?errs.Span = null,
    current_src: []const u8 = "",
    // Maps file path → source text so printDiagnostic can show the right line
    // even when the error span points to a different file than current_src.
    source_map: std.StringHashMap([]const u8),

    // When true, evalFormInner skips non-structural forms (define, applications,
    // etc.) and only processes import/module/load/include. Used by `zepo build`
    // to discover module dependencies without running user code.
    discovery_mode: bool = false,

    pub fn init(
        gc: *GC,
        symbols: *SymbolTable,
        globals: *GlobalEnv,
        allocator: std.mem.Allocator,
    ) !EvalContext {
        return EvalContext{
            .gc = gc,
            .symbols = symbols,
            .globals = globals,
            .allocator = allocator,
            .registry = ModuleRegistry.init(allocator, gc),
            .current_module = null,
            .arena = NodeArena.init(allocator),
            .program = Program.init(allocator),
            .emitter = Emitter.init(allocator, symbols, gc),
            .spans = SpanTable.init(allocator),
            .compiled = .empty,
            .vm = null,
            .macro_names = std.StringHashMap(void).init(allocator),
            .source_map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    /// Register compiled fn consts as a GC root. Must be called once the
    /// EvalContext is at its final address (after init returns to the caller).
    /// Keeps quoted literals in compiled closures alive across VM teardown.
    pub fn installRootVisitor(ctx: *EvalContext) void {
        ctx.gc.roots.visit_fn2 = compiledConstsVisit;
        ctx.gc.roots.visit_ctx2 = ctx;
    }

    fn compiledConstsVisit(ctx_opaque: *anyopaque, visitor: @import("../gc/roots.zig").RootVisitor, visitor_ctx: *anyopaque) void {
        const ctx: *EvalContext = @ptrCast(@alignCast(ctx_opaque));
        for (ctx.compiled.items) |*cf| {
            for (cf.consts) |*v| visitor(visitor_ctx, v);
            for (cf.keyword_params) |*kp| visitor(visitor_ctx, &kp.default_value);
        }
    }

    pub fn deinit(ctx: *EvalContext) void {
        if (ctx.gc.roots.visit_ctx2 == @as(?*anyopaque, ctx)) {
            ctx.gc.roots.visit_fn2 = null;
            ctx.gc.roots.visit_ctx2 = null;
        }
        if (ctx.vm) |*v| v.deinit();
        for (ctx.compiled.items) |*cf| cf.deinit(ctx.allocator);
        ctx.compiled.deinit(ctx.allocator);
        ctx.emitter.deinit();
        ctx.program.deinit();
        ctx.arena.deinit();
        ctx.spans.deinit();
        ctx.registry.deinit();
        var kit = ctx.macro_names.keyIterator();
        while (kit.next()) |k| ctx.allocator.free(k.*);
        ctx.macro_names.deinit();
        var smit = ctx.source_map.iterator();
        while (smit.next()) |e| {
            ctx.allocator.free(e.key_ptr.*);
            ctx.allocator.free(e.value_ptr.*);
        }
        ctx.source_map.deinit();
        for (ctx.zbc_name_bufs.items) |buf| ctx.allocator.free(buf);
        ctx.zbc_name_bufs.deinit(ctx.allocator);
        for (ctx.owned_module_path_dirs.items) |d| ctx.allocator.free(d);
        ctx.owned_module_path_dirs.deinit(ctx.allocator);
        for (ctx.owned_module_path_slices.items) |s| ctx.allocator.free(s);
        ctx.owned_module_path_slices.deinit(ctx.allocator);
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
        ctx.current_src = src;
        ctx.last_error_span = null;
        // Store file→src so printDiagnostic can find the right source even
        // after current_src has been overwritten by a nested evalString call.
        if (!ctx.source_map.contains(file)) {
            if (ctx.allocator.dupe(u8, file)) |fk| {
                if (ctx.allocator.dupe(u8, src)) |fv| {
                    ctx.source_map.put(fk, fv) catch {
                        ctx.allocator.free(fk);
                        ctx.allocator.free(fv);
                    };
                } else |_| ctx.allocator.free(fk);
            } else |_| {}
        }
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
        const result = ctx.evalFormInner(form);
        return result catch |e| {
            // Record the span of the failing form if not already set by a
            // more-specific inner handler (inner wins → most precise location).
            if (ctx.last_error_span == null) {
                ctx.last_error_span = ctx.spans.get(form);
            }
            return e;
        };
    }

    fn evalFormInner(ctx: *EvalContext, form: Value) !Value {
        // Discovery mode: only process module-system forms that reveal dependencies.
        if (ctx.discovery_mode) {
            if (isHeadSymbol(form, "module")) return mod_loader.evalModuleDecl(ctx, form);
            if (isHeadSymbol(form, "lib")) return mod_loader.evalLibDecl(ctx, form);
            if (isHeadSymbol(form, "import")) return mod_loader.evalImport(ctx, form);
            if (isHeadSymbol(form, "include") or isHeadSymbol(form, "load")) return mod_loader.evalInclude(ctx, form);
            if (isHeadSymbol(form, "package")) return mod_loader.evalPackageDecl(ctx, form);
            return value_mod.NIL;
        }

        if (isHeadSymbol(form, "lib")) return mod_loader.evalLibDecl(ctx, form);
        if (isHeadSymbol(form, "module")) {
            return mod_loader.evalModuleDecl(ctx, form);
        }
        if (isHeadSymbol(form, "import")) {
            return mod_loader.evalImport(ctx, form);
        }
        if (isHeadSymbol(form, "export")) {
            return error.ExportOutsideModule;
        }
        if (isHeadSymbol(form, "include") or isHeadSymbol(form, "load")) {
            return mod_loader.evalInclude(ctx, form);
        }
        if (isHeadSymbol(form, "package")) {
            return mod_loader.evalPackageDecl(ctx, form);
        }
        if (isHeadSymbol(form, "defmacro")) {
            return macros.evalDefmacro(ctx, form);
        }
        if (isHeadSymbol(form, "define-syntax")) { // zepo-ajf
            return macros.evalDefineSyntax(ctx, form);
        }

        return ctx.evalNonModuleForm(form);
    }

    /// Print a caught error with file/line/col and source excerpt to `writer`.
    /// Pass `std.Io.File.stderr()` for CLI output; pass a buffer writer in tests.
    pub fn printDiagnostic(ctx: *const EvalContext, writer: anytype, err: anyerror) void {
        // zepo-45l
        var buf: [512]u8 = undefined;
        // For UserError, prefer the message stored in the VM over the bare name.
        const err_label: []const u8 = blk: {
            if (err == error.StackOverflow) break :blk "stack overflow (recursion too deep)";
            if (err == error.UserError) {
                if (ctx.vm) |vm| {
                    if (vm.error_msg) |msg| break :blk msg;
                }
            }
            break :blk @errorName(err);
        };
        if (ctx.last_error_span) |span| {
            const src_for_file = ctx.source_map.get(span.file) orelse ctx.current_src;
            const line_text = extractSourceLine(src_for_file, span.start.offset);
            const header = std.fmt.bufPrint(&buf, "{s}:{d}:{d}: error: {s}\n", .{
                span.file,
                span.start.line,
                span.start.col,
                err_label,
            }) catch "";
            writer.writeAll(header) catch {};
            if (line_text.len > 0) {
                var line_buf: [1024]u8 = undefined;
                const line_out = std.fmt.bufPrint(&line_buf, "  {s}\n", .{line_text}) catch "";
                writer.writeAll(line_out) catch {};
                const col: usize = if (span.start.col > 0) span.start.col - 1 else 0;
                var caret_buf: [256]u8 = undefined;
                const spaces = @min(col + 2, caret_buf.len - 2);
                @memset(caret_buf[0..spaces], ' ');
                caret_buf[spaces] = '^';
                caret_buf[spaces + 1] = '\n';
                writer.writeAll(caret_buf[0 .. spaces + 2]) catch {};
            }
        } else {
            const msg = std.fmt.bufPrint(&buf, "error: {s}\n", .{err_label}) catch "";
            writer.writeAll(msg) catch {};
        }
        // Print call stack from VM frames (innermost first).
        if (ctx.vm) |*vm| {
            const frames = vm.call_stack.frames.items;
            if (frames.len > 0) {
                writer.writeAll("call stack (innermost first):\n") catch {};
                const max_frames: usize = 20;
                const shown = @min(frames.len, max_frames);
                var fi: usize = frames.len;
                while (fi > frames.len - shown) {
                    fi -= 1;
                    const frame = frames[fi];
                    const fname = if (frame.func.src_name.len > 0) frame.func.src_name else "<anonymous>";
                    var fbuf: [256]u8 = undefined;
                    const fline = std.fmt.bufPrint(&fbuf, "  {s}\n", .{fname}) catch continue;
                    writer.writeAll(fline) catch {};
                }
                if (frames.len > max_frames) {
                    var tbuf: [64]u8 = undefined;
                    const tnote = std.fmt.bufPrint(&tbuf, "  ... ({d} more frames)\n", .{frames.len - max_frames}) catch "";
                    writer.writeAll(tnote) catch {};
                }
            }
        }
    }

    // zepo-ksw
    // Compile a single (already module/macro-dispatched) form into a top-level
    // thunk and return its index in ctx.compiled. Performs the delicate
    // no-GC/rooting dance and keeps ctx.vm.compiled_fns/globals in sync. The
    // caller chooses how to execute the thunk (run vs execFn).
    fn compileFormToFnId(ctx: *EvalContext, form: Value) !u32 {
        if (ctx.gc.trace.eval) {
            if (ctx.spans.get(form)) |span| {
                std.debug.print("[eval] {s}:{d}:{d}\n", .{ span.file, span.start.line, span.start.col });
            } else {
                std.debug.print("[eval] <unknown location>\n", .{});
            }
        }

        // Root all intermediate Values across any GC-triggering call so the
        // collector does not move them while they live only in local variables.
        var scope = HandleScope{};
        ctx.gc.roots.pushHandleScope(&scope);
        defer ctx.gc.roots.popHandleScope();

        // Phase 1: quasiquote desugaring.
        const qq_slot = scope.push(try expand_mod.expand(form, ctx.symbols, ctx.gc));
        // Phase 2: macro expansion (requires VM to exist for transformer calls).
        const expanded_slot = scope.push(if (ctx.vm != null)
            try macros.macroExpand(ctx, qq_slot.*)
        else
            qq_slot.*);

        // Reserve nursery space so no GC fires while quote datum Values live in
        // AST nodes or IR load_const ops — those are plain Zig struct fields, not
        // GC roots.  expanded_slot is rooted above so reserveNursery's GC is safe.
        try ctx.gc.reserveNursery(16 * 1024);

        // In debug builds, assert no collection fires from here through emitAppend.
        // Any GC in this window would stale the unrooted quote datums in AST/IR.
        // Released explicitly before vm.run so the VM can allocate freely.
        var no_gc = ctx.gc.noCollect();

        var builder = Builder.init(&ctx.arena, ctx.symbols, ctx.allocator);
        builder.span_table = &ctx.spans;
        const root_id = try builder.build(expanded_slot.*);

        var analyzer = sema_mod.CaptureAnalyzer.init(&ctx.arena, ctx.allocator);
        try analyzer.analyze(root_id);

        var compiler = Compiler.initWithGc(&ctx.arena, &ctx.program, ctx.symbols, ctx.gc, ctx.allocator);
        const fn_id = try compiler.compileExpr(root_id);

        // Save positions before emitAppend so we can compute the actual
        // ctx.compiled index for fn_id. When .zbc fns have been appended
        // directly to ctx.compiled (bypassing the IR program), ctx.compiled
        // is ahead of emitter.emitted_count, so the emitted fn lands at a
        // higher position than fn_id alone would suggest.
        const compiled_base = ctx.compiled.items.len;
        const emitted_base = ctx.emitter.emitted_count;
        try ctx.emitter.emitAppend(&ctx.program, &ctx.compiled);
        no_gc.release(); // AST/IR pipeline done; VM may now allocate freely.
        // zepo-oav: update compiled_fns in-place to preserve live fibers across
        // forms. Recreating via VM.deinit()+VM.init() frees all FiberStates,
        // invalidating foreign handles stored in globals from prior forms.
        if (ctx.vm) |*v| {
            v.compiled_fns = ctx.compiled.items;
            v.globals = ctx.currentEnv();
            if (ctx.current_module != null) {
                v.fallback_globals = ctx.globals;
            }
        } else {
            // The VM always sees the currently-active env — if we're inside a
            // module, that's the module's env; the top-level globals become the
            // read-only fallback so the module body can call prims/prelude.
            ctx.vm = try VM.init(ctx.gc, ctx.currentEnv(), ctx.symbols, ctx.compiled.items, ctx.allocator, ctx.vm_max_regs);
            if (ctx.current_module != null) {
                ctx.vm.?.fallback_globals = ctx.globals;
            }
            ctx.vm.?.do_import = vmImportCallback;
            ctx.vm.?.do_import_ctx = ctx;
            ctx.vm.?.installAsRoot();
        }

        // Actual index in ctx.compiled where the thunk was emitted.
        const actual_fn_id: u32 = @intCast(compiled_base + (fn_id - emitted_base));

        if (ctx.toplevel_fn_ids) |log| {
            log.append(ctx.allocator, actual_fn_id) catch {};
        }

        return actual_fn_id;
    }

    pub fn evalNonModuleForm(ctx: *EvalContext, form: Value) !Value {
        const actual_fn_id = try ctx.compileFormToFnId(form);
        return ctx.vm.?.run(actual_fn_id, &.{});
    }

    // zepo-ksw
    // Compile and run a form on the CURRENT call stack via execFn, so it is safe
    // to call from inside a running dispatch loop (unlike `run`, which spins up a
    // fresh Scheduler). v1 limitation: the form must run synchronously — if it
    // yields or spawns a fiber, execFn returns error.FiberYielded which we surface
    // as an error (there is no scheduler at this nested level to resume it).
    pub fn evalFormNested(ctx: *EvalContext, form: Value) !Value {
        const inner = ctx.evalFormNestedInner(form);
        return inner catch |e| {
            if (ctx.last_error_span == null) ctx.last_error_span = ctx.spans.get(form);
            return e;
        };
    }

    fn evalFormNestedInner(ctx: *EvalContext, form: Value) !Value {
        if (isCompileTimeHead(form)) {
            return ctx.evalFormInner(form);
        }
        const actual_fn_id = try ctx.compileFormToFnId(form);
        return ctx.vm.?.execFn(&ctx.vm.?.compiled_fns[actual_fn_id], value_mod.NIL, &.{});
    }
};

pub fn vmImportCallback(ctx_opaque: *anyopaque, name: []const u8, alias: ?[]const u8, only: ?[]const []const u8) errs.LispError!void {
    const ctx: *EvalContext = @ptrCast(@alignCast(ctx_opaque));
    return mod_loader.doImportByName(ctx, name, alias, only);
}

fn extractSourceLine(src: []const u8, offset: u32) []const u8 {
    const off: usize = @min(@as(usize, offset), src.len);
    var start: usize = off;
    while (start > 0 and src[start - 1] != '\n') : (start -= 1) {}
    var end: usize = off;
    while (end < src.len and src[end] != '\n') : (end += 1) {}
    return src[start..end];
}

// zepo-ksw
// Heads handled at compile time (module system + macro declarations) — these
// never lower to a runnable thunk, so nested eval must route them through
// evalFormInner rather than compile+execFn.
fn isCompileTimeHead(form: Value) bool {
    return isHeadSymbol(form, "module") or isHeadSymbol(form, "lib") or
        isHeadSymbol(form, "import") or isHeadSymbol(form, "export") or
        isHeadSymbol(form, "include") or isHeadSymbol(form, "load") or
        isHeadSymbol(form, "package") or isHeadSymbol(form, "defmacro") or
        isHeadSymbol(form, "define-syntax");
}

pub fn isHeadSymbol(v: Value, expected: []const u8) bool {
    const objects = runtime_objects;
    if (!value_mod.isPtr(v)) return false;
    if (!objects.isPair(v)) return false;
    const head = objects.pairCar(v).*;
    if (!objects.isSymbol(head)) return false;
    return std.mem.eql(u8, objects.symbolName(head), expected);
}

test "evalFormNested: compiles and runs a form via execFn" {
    const alloc = std.testing.allocator;
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var globals = try GlobalEnv.init(&gc, alloc);
    defer globals.deinit();
    try register_mod.registerAll(&gc, &globals, &syms);
    var ctx = try EvalContext.init(&gc, &syms, &globals, alloc);
    defer ctx.deinit();
    ctx.installRootVisitor();

    _ = try ctx.evalString("(+ 1 1)", "<test>"); // bootstrap the VM

    var parser = Parser.init(ctx.gc, ctx.symbols, &ctx.spans, "(+ 40 2)", "<form>", ctx.allocator);
    defer parser.deinit();
    const form = try parser.readOne();
    const result = try ctx.evalFormNested(form);
    try std.testing.expectEqual(value_mod.fixnum(42), result);
}

test "evalFormNested: yielding form errors rather than corrupting" {
    const alloc = std.testing.allocator;
    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var globals = try GlobalEnv.init(&gc, alloc);
    defer globals.deinit();
    try register_mod.registerAll(&gc, &globals, &syms);
    var ctx = try EvalContext.init(&gc, &syms, &globals, alloc);
    defer ctx.deinit();
    ctx.installRootVisitor();
    _ = try ctx.evalString("(+ 1 1)", "<test>");

    // (yield) sets vm.yield_requested with no block/park, so the dispatch loop
    // returns .yielded and execFn surfaces error.FiberYielded. There is no
    // scheduler at this nested level to resume it. (spawn ...) is NOT used here:
    // it returns error.ContractViolation when vm.scheduler is null, which is a
    // different invariant than "yielded form surfaces an error".
    var parser = Parser.init(ctx.gc, ctx.symbols, &ctx.spans, "(yield)", "<form>", ctx.allocator);
    defer parser.deinit();
    const form = try parser.readOne();
    const res = ctx.evalFormNested(form);
    try std.testing.expectError(error.FiberYielded, res);
}
