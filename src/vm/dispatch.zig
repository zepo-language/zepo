//! Bytecode dispatch loop.
//!
//! `run(fn_id, args)` enters the top-level function, pushes a frame, and
//! executes until a RETURN. CALL recurses via `execFn`; TAIL_CALL rewrites
//! the current frame in place and restarts dispatch without growing the
//! Zig call stack.
//!
//! Primitives are values of Kind.prim whose body holds a raw function
//! pointer. When CALL encounters a prim, it calls the function directly —
//! no frame push.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const ObjHeader = abi.ObjHeader;

const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const SymbolTable = runtime.SymbolTable;
const GlobalEnv = runtime.GlobalEnv;

const errs = @import("../runtime/errors.zig");
const LispError = errs.LispError;

const bytecode = @import("../cg/bytecode.zig");
const Opcode = bytecode.Opcode;
const Instr = bytecode.Instr;
const CompiledFn = bytecode.CompiledFn;

const frame_mod = @import("frame.zig");
const CallStack = frame_mod.CallStack;
const Frame = frame_mod.Frame;

pub const PrimFn = *const fn (vm: *VM, args: []const Value) LispError!Value;

pub const VM = struct {
    gc: *GC,
    globals: *GlobalEnv,
    /// Optional fallback env consulted on read-miss in `globals`. Used by the
    /// module system: when executing a module body, `globals` points at the
    /// module's env and this points at the top-level env so module code can
    /// still call prims/prelude (read-fallback only — writes always go to the
    /// primary env).
    fallback_globals: ?*GlobalEnv = null,
    symbols: *SymbolTable,
    compiled_fns: []CompiledFn,
    call_stack: CallStack,
    allocator: std.mem.Allocator,
    gc_needed: bool = false,
    /// Callback for IMPORT opcode inside compiled function bodies.
    do_import: ?*const fn (*anyopaque, []const u8, ?[]const u8, ?[]const []const u8) LispError!void = null,
    do_import_ctx: ?*anyopaque = null,
    /// Message from the most recent `(error msg)` call, owned by allocator.
    error_msg: ?[]u8 = null,
    /// Lisp value being propagated by `raise` or `error`. NIL when no exception
    /// is in flight. Visited as a GC root so it survives stack unwind.
    raised_val: Value = value_mod.NIL,
    /// The GC is informed of live VM registers via a root-visitor callback
    /// registered in `installAsRoot`. The callback (`vmRootVisit`) walks only
    /// the active frame windows in `call_stack.regs`. We pre-reserve
    /// MAX_REGS capacity so the ArrayList backing slice never reallocates
    /// during a minor GC, keeping all `*Value` pointers into it stable.
    pub const MAX_REGS: usize = 64 * 1024;

    pub fn init(
        gc: *GC,
        globals: *GlobalEnv,
        symbols: *SymbolTable,
        compiled_fns: []CompiledFn,
        allocator: std.mem.Allocator,
    ) !VM {
        var cs = CallStack.init(allocator);
        try cs.regs.ensureTotalCapacity(allocator, MAX_REGS);
        return .{
            .gc = gc,
            .globals = globals,
            .symbols = symbols,
            .compiled_fns = compiled_fns,
            .call_stack = cs,
            .allocator = allocator,
        };
    }

    pub fn deinit(vm: *VM) void {
        if (vm.gc.roots.visit_ctx) |ctx| {
            if (ctx == @as(*anyopaque, @ptrCast(vm))) {
                vm.gc.roots.visit_fn = null;
                vm.gc.roots.visit_ctx = null;
            }
        }
        if (vm.error_msg) |m| {
            vm.allocator.free(m);
            vm.error_msg = null;
        }
        vm.call_stack.deinit();
    }

    /// Register the VM's register stack and frame closures as GC roots.
    /// Call this after VM.init so minor collections triggered from inside
    /// bytecode preserve live Values held in regs.
    pub fn installAsRoot(vm: *VM) void {
        vm.gc.roots.visit_fn = vmRootVisit;
        vm.gc.roots.visit_ctx = @ptrCast(vm);
    }

    fn vmRootVisit(ctx: *anyopaque, visitor: @import("../gc/roots.zig").RootVisitor, visitor_ctx: *anyopaque) void {
        const vm: *VM = @ptrCast(@alignCast(ctx));
        // Only visit regs within active frame windows; stale slots above the
        // current frame's top (if any) must not be treated as roots.
        const regs = vm.call_stack.regs.items;
        for (vm.call_stack.frames.items) |*f| {
            const start: usize = f.base;
            const end: usize = @min(regs.len, start + f.func.num_regs);
            if (start >= end) continue;
            for (regs[start..end]) |*slot| visitor(visitor_ctx, slot);
        }
        for (vm.call_stack.frames.items) |*f| visitor(visitor_ctx, &f.closure_val);
        visitor(visitor_ctx, &vm.raised_val);
        // Compiled-function constant pools hold heap Values (strings, symbols,
        // etc.) that are not referenced by any register while dormant. Without
        // tracing them the GC can collect a constant the moment it leaves the
        // last register that held it, making future LOAD_CONST unsafe.
        for (vm.compiled_fns) |*cf| {
            for (cf.consts) |*v| visitor(visitor_ctx, v);
            for (cf.keyword_params) |*kp| visitor(visitor_ctx, &kp.default_value);
        }
    }

    /// Push live register slots as GC roots. Returns the count pushed so
    /// the caller can pop them back off via `unrootSafepoint`.
    fn rootSafepoint(vm: *VM) !usize {
        const n_before = vm.gc.roots.extra.items.len;
        const live = vm.call_stack.regs.items.len;
        try vm.gc.roots.extra.ensureUnusedCapacity(vm.gc.allocator, live);
        var i: usize = 0;
        while (i < live) : (i += 1) {
            vm.gc.roots.extra.appendAssumeCapacity(&vm.call_stack.regs.items[i]);
        }
        return n_before;
    }

    fn unrootSafepoint(vm: *VM, prev_len: usize) void {
        vm.gc.roots.extra.shrinkRetainingCapacity(prev_len);
    }

    /// Entry: run the function with given fn_id, passing `args`.
    pub fn run(vm: *VM, fn_id: u32, args: []const Value) LispError!Value {
        if (fn_id >= vm.compiled_fns.len) return error.InvalidForm;
        const func = &vm.compiled_fns[fn_id];
        return vm.execFn(func, value_mod.NIL, args);
    }

    /// Execute a CompiledFn. Supports tail calls via a trampoline loop.
    pub fn execFn(vm: *VM, initial_func: *CompiledFn, initial_closure: Value, initial_args: []const Value) LispError!Value {
        var func = initial_func;
        var closure_val = initial_closure;

        // Budget args into a local buffer so tail-calls can swap the backing.
        var args_buf: [256]Value = undefined;
        if (initial_args.len > args_buf.len) return error.ArityMismatch;
        @memcpy(args_buf[0..initial_args.len], initial_args);
        var args_len: usize = initial_args.len;

        trampoline: while (true) {
            // Arity check.
            if (func.keyword_params.len > 0) {
                if (args_len < func.arity) return error.ArityMismatch;
                const extra = args_len - func.arity;
                if (extra % 2 != 0) return error.ArityMismatch;
            } else if (func.has_rest) {
                if (args_len < func.arity) return error.ArityMismatch;
            } else {
                if (args_len != func.arity) return error.ArityMismatch;
            }

            // Push frame.
            const base: u32 = @intCast(vm.call_stack.regs.items.len);
            vm.call_stack.push(.{
                .func = func,
                .pc = 0,
                .base = base,
                .caller_base = base,
                .closure_val = closure_val,
            }, func.num_regs) catch return error.OutOfMemory;

            // Place arguments into regs[0..arity]. If has_rest, stuff the
            // remaining args into a list in regs[arity].
            var i: usize = 0;
            while (i < func.arity) : (i += 1) {
                vm.call_stack.regs.items[base + i] = args_buf[i];
            }
            if (func.keyword_params.len > 0) {
                // Fill keyword param slots with defaults first.
                for (func.keyword_params) |kp| {
                    vm.call_stack.regs.items[base + kp.slot] = kp.default_value;
                }
                // Then override with caller-provided keyword args.
                var ki: usize = func.arity;
                while (ki < args_len) : (ki += 2) {
                    const key_sym = args_buf[ki];
                    if (!objects.isSymbol(key_sym)) return error.TypeError;
                    const key_name = objects.symbolName(key_sym);
                    const bare = if (key_name.len > 0 and key_name[0] == ':') key_name[1..] else key_name;
                    var found = false;
                    for (func.keyword_params) |kp| {
                        if (std.mem.eql(u8, bare, kp.name)) {
                            vm.call_stack.regs.items[base + kp.slot] = args_buf[ki + 1];
                            found = true;
                            break;
                        }
                    }
                    if (!found) return error.UnknownKeyword;
                }
            } else if (func.has_rest) {
                // Reserve nursery capacity up-front so no GC can fire during
                // the loop; args_buf lives on the C stack and is not a GC root.
                const rest_count = args_len - func.arity;
                const pair_bytes: usize = 24; // 8 header + 2 body words
                vm.gc.reserveNursery(pair_bytes * rest_count) catch return error.OutOfMemory;

                // Build rest-list from args_buf[func.arity..args_len].
                var rest: Value = value_mod.NIL;
                var k: usize = args_len;
                while (k > func.arity) {
                    k -= 1;
                    rest = objects.makePair(vm.gc, args_buf[k], rest) catch return error.OutOfMemory;
                }
                vm.call_stack.regs.items[base + func.arity] = rest;
            }

            const result = vm.dispatch(func) catch |e| {
                // Leave frame on stack — printDiagnostic walks them for traces.
                // VM is always torn down by EvalContext after an error.
                return e;
            };

            if (result == .tail_call) {
                // Pop current frame then restart with new func/args.
                _ = vm.call_stack.pop();
                func = result.tail_call.func;
                closure_val = result.tail_call.closure_val;
                if (result.tail_call.args.len > args_buf.len) return error.ArityMismatch;
                args_len = result.tail_call.args.len;
                @memcpy(args_buf[0..args_len], result.tail_call.args);
                continue :trampoline;
            }

            _ = vm.call_stack.pop();
            return result.value;
        }
    }

    const DispatchResult = union(enum) {
        value: Value,
        tail_call: struct {
            func: *CompiledFn,
            closure_val: Value,
            args: []const Value,
        },
    };

    /// Tail-call out-buffer. Using a thread-local-ish static buffer would be
    /// simpler but Zig lacks thread locals; we put it on the VM struct.
    var tc_args_buf: [256]Value = undefined;

    fn dispatch(vm: *VM, func: *CompiledFn) LispError!DispatchResult {
        var pc: u32 = 0;
        const code = func.code;
        while (true) {
            if (pc >= code.len) return error.ContractViolation;
            const instr = code[pc];
            pc += 1;

            const op = bytecode.decodeOp(instr);
            switch (op) {
                .LOAD_CONST => {
                    const a = bytecode.decodeA(instr);
                    const ci = bytecode.decodeBC(instr);
                    vm.call_stack.reg(a).* = func.consts[ci];
                },
                .LOAD_NIL => {
                    const a = bytecode.decodeA(instr);
                    vm.call_stack.reg(a).* = value_mod.NIL;
                },
                .LOAD_TRUE => {
                    const a = bytecode.decodeA(instr);
                    vm.call_stack.reg(a).* = value_mod.TRUE;
                },
                .LOAD_FALSE => {
                    const a = bytecode.decodeA(instr);
                    vm.call_stack.reg(a).* = value_mod.FALSE;
                },
                .LOAD_LOCAL => {
                    // A=dst, B=slot. Locals share the register space in this
                    // model: slot N === reg N.
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    vm.call_stack.reg(a).* = vm.call_stack.reg(b).*;
                },
                .STORE_LOCAL => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    vm.call_stack.reg(a).* = vm.call_stack.reg(b).*;
                },
                .LOAD_GLOBAL => {
                    const a = bytecode.decodeA(instr);
                    const ni = bytecode.decodeBC(instr);
                    const name = func.names[ni];
                    const sym = vm.symbols.intern(name) catch return error.OutOfMemory;
                    // Keyword symbols (starting with ':') are self-evaluating.
                    const val = if (name.len > 0 and name[0] == ':') sym else vm.globals.lookup(sym) orelse blk: {
                        if (vm.fallback_globals) |fb| {
                            if (fb.lookup(sym)) |v| break :blk v;
                        }
                        // Last resort: the closure's home env (the module env
                        // where this function was compiled). Allows module-defined
                        // functions to resolve their imports when called outside
                        // their original module context.
                        const frame_closure = vm.call_stack.currentFrame().closure_val;
                        if (objects.isClosure(frame_closure)) {
                            const home_ptr = objects.closureHomeEnvPtr(frame_closure);
                            if (home_ptr != 0 and home_ptr != @intFromPtr(vm.globals)) {
                                const home: *GlobalEnv = @ptrFromInt(home_ptr);
                                if (home.lookup(sym)) |v| break :blk v;
                            }
                        }
                        std.debug.print("error: unbound variable: {s}\n", .{name});
                        return error.UnboundVariable;
                    };
                    vm.call_stack.reg(a).* = val;
                },
                .STORE_GLOBAL => {
                    const a = bytecode.decodeA(instr);
                    const ni = bytecode.decodeBC(instr);
                    const name = func.names[ni];
                    const sym = vm.symbols.intern(name) catch return error.OutOfMemory;
                    const v = vm.call_stack.reg(a).*;
                    vm.globals.define(sym, v) catch return error.OutOfMemory;
                },
                .ALLOC_BOX => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const box = objects.makeBoxFromSlot(vm.gc, vm.call_stack.reg(b)) catch return error.OutOfMemory;
                    vm.call_stack.reg(a).* = box;
                },
                .LOAD_BOX => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const box = vm.call_stack.reg(b).*;
                    if (!objects.isBox(box)) return error.TypeError;
                    vm.call_stack.reg(a).* = objects.boxGet(box);
                },
                .STORE_BOX => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const box = vm.call_stack.reg(a).*;
                    if (!objects.isBox(box)) return error.TypeError;
                    objects.boxSet(vm.gc, box, vm.call_stack.reg(b).*);
                },
                .CONS => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const c = bytecode.decodeC(instr);
                    // Pass register *pointers* so that if gc.alloc triggers a
                    // minor GC (via vmRootVisit), the Values are read from the
                    // already-updated register slots after the collection.
                    const p = objects.makePairFromSlots(vm.gc, vm.call_stack.reg(b), vm.call_stack.reg(c)) catch return error.OutOfMemory;
                    vm.call_stack.reg(a).* = p;
                },
                .CAR => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const p = vm.call_stack.reg(b).*;
                    if (!objects.isPair(p)) return error.CarOfNonPair;
                    vm.call_stack.reg(a).* = objects.pairCar(p).*;
                },
                .CDR => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const p = vm.call_stack.reg(b).*;
                    if (!objects.isPair(p)) return error.CdrOfNonPair;
                    vm.call_stack.reg(a).* = objects.pairCdr(p).*;
                },
                .MAKE_CLOSURE => {
                    const a = bytecode.decodeA(instr);
                    const bc = bytecode.decodeBC(instr);
                    // Consume following CAPTURE instructions.
                    var caps: [64]Value = undefined;
                    var ncaps: usize = 0;
                    while (pc < code.len and bytecode.decodeOp(code[pc]) == .CAPTURE) {
                        const cap_instr = code[pc];
                        pc += 1;
                        const creg = bytecode.decodeA(cap_instr);
                        if (ncaps >= caps.len) return error.ContractViolation;
                        caps[ncaps] = vm.call_stack.reg(creg).*;
                        ncaps += 1;
                    }
                    if (bc >= vm.compiled_fns.len) return error.ContractViolation;
                    const target_fn = &vm.compiled_fns[bc];
                    // Root caps[] so that if gc.alloc triggers a minor GC the
                    // GC can update the on-stack capture Values via the extra-
                    // roots scan before makeClosure copies them into the object.
                    const prev_extra = vm.gc.roots.extra.items.len;
                    vm.gc.roots.extra.ensureUnusedCapacity(vm.gc.allocator, ncaps) catch return error.OutOfMemory;
                    for (0..ncaps) |ci| vm.gc.roots.extra.appendAssumeCapacity(&caps[ci]);
                    // Store fn_id in code_ptr so closures survive re-emission
                    // of the compiled_fns array. (The VM resolves id→ptr at
                    // call time.)
                    // Inherit home_env from the enclosing frame's closure so
                    // nested closures (e.g. named-let loops) can resolve sibling
                    // module-level bindings via LOAD_GLOBAL's home-env fallback.
                    const inherited_home: u64 = blk: {
                        const frame_closure = vm.call_stack.currentFrame().closure_val;
                        if (objects.isClosure(frame_closure)) {
                            const h = objects.closureHomeEnvPtr(frame_closure);
                            if (h != 0) break :blk h;
                        }
                        break :blk @intFromPtr(vm.globals);
                    };
                    const closure = objects.makeClosure(
                        vm.gc,
                        @intCast(bc),
                        @intCast(target_fn.arity),
                        inherited_home,
                        caps[0..ncaps],
                    ) catch {
                        vm.gc.roots.extra.shrinkRetainingCapacity(prev_extra);
                        return error.OutOfMemory;
                    };
                    vm.gc.roots.extra.shrinkRetainingCapacity(prev_extra);
                    vm.call_stack.reg(a).* = closure;
                },
                .CAPTURE => {
                    // CAPTURE should be consumed by MAKE_CLOSURE; encountering
                    // it standalone indicates a codegen bug.
                    return error.ContractViolation;
                },
                .LOAD_CAPTURE => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const closure = vm.call_stack.currentFrame().closure_val;
                    if (!objects.isClosure(closure)) return error.ContractViolation;
                    const caps = objects.closureCaptures(closure);
                    if (b >= caps.len) return error.ContractViolation;
                    vm.call_stack.reg(a).* = caps[b];
                },
                .JUMP => {
                    const target = bytecode.decodeBC(instr);
                    pc = target;
                },
                .JUMP_IF_FALSE => {
                    const a = bytecode.decodeA(instr);
                    const target = bytecode.decodeBC(instr);
                    const v = vm.call_stack.reg(a).*;
                    if (value_mod.isFalsy(v)) pc = target;
                },
                .MOVE => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    vm.call_stack.reg(a).* = vm.call_stack.reg(b).*;
                },
                .CALL => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const c = bytecode.decodeC(instr);
                    const fn_val = vm.call_stack.reg(b).*;
                    const base_frame = vm.call_stack.currentFrame().base;
                    const args_start = base_frame + @as(u32, b) + 1;
                    const args_end = args_start + @as(u32, c);
                    const args_slice = vm.call_stack.regs.items[args_start..args_end];

                    const result = try vm.callValue(fn_val, args_slice);
                    vm.call_stack.reg(a).* = result;
                },
                .TAIL_CALL => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const fn_val = vm.call_stack.reg(a).*;
                    const base_frame = vm.call_stack.currentFrame().base;
                    const args_start = base_frame + @as(u32, a) + 1;
                    const args_end = args_start + @as(u32, b);

                    // Snapshot args into the TC buffer (since we're about to
                    // pop the frame).
                    if (b > tc_args_buf.len) return error.ArityMismatch;
                    @memcpy(tc_args_buf[0..b], vm.call_stack.regs.items[args_start..args_end]);

                    if (objects.isClosure(fn_val)) {
                        const fn_id = objects.closureCodePtr(fn_val);
                        if (fn_id >= vm.compiled_fns.len) return error.ContractViolation;
                        const tgt = &vm.compiled_fns[@intCast(fn_id)];
                        return DispatchResult{ .tail_call = .{
                            .func = tgt,
                            .closure_val = fn_val,
                            .args = tc_args_buf[0..b],
                        } };
                    }
                    if (objects.isPrim(fn_val)) {
                        const raw = objects.primFnPtr(fn_val);
                        const pfn: PrimFn = @ptrFromInt(@as(usize, @intCast(raw)));
                        // tc_args_buf is on the C-stack, not in the register file.
                        // Root each slot so vmRootVisit can update them if the prim triggers GC.
                        const prev_extra = vm.gc.roots.extra.items.len;
                        vm.gc.roots.extra.ensureUnusedCapacity(vm.gc.allocator, b) catch return error.OutOfMemory;
                        for (0..b) |i| vm.gc.roots.extra.appendAssumeCapacity(&tc_args_buf[i]);
                        const v = pfn(vm, tc_args_buf[0..b]) catch |e| {
                            vm.gc.roots.extra.shrinkRetainingCapacity(prev_extra);
                            return e;
                        };
                        vm.gc.roots.extra.shrinkRetainingCapacity(prev_extra);
                        return DispatchResult{ .value = v };
                    }
                    return error.TypeError;
                },
                .RETURN => {
                    const a = bytecode.decodeA(instr);
                    const v = vm.call_stack.reg(a).*;
                    return DispatchResult{ .value = v };
                },
                .SAFEPOINT => {
                    // Register current register stack as roots for the
                    // duration of this collection. We have no explicit
                    // "allocator low" signal yet; just run minor if asked.
                    if (vm.gc_needed) {
                        const prev = try vm.rootSafepoint();
                        defer vm.unrootSafepoint(prev);
                        vm.gc.minor() catch return error.OutOfMemory;
                        vm.gc_needed = false;
                    }
                },
                .PRIM => {
                    // Unused — primitive applications currently flow through
                    // CALL. Kept in the opcode space for future fast-path.
                    return error.ContractViolation;
                },
                .IMPORT => {
                    const a = bytecode.decodeA(instr);
                    const bc_idx = bytecode.decodeBC(instr);
                    if (bc_idx >= func.consts.len) return error.ContractViolation;
                    const spec = func.consts[bc_idx];
                    const cb = vm.do_import orelse return error.ContractViolation;
                    const ctx_ptr = vm.do_import_ctx orelse return error.ContractViolation;
                    if (objects.isSymbol(spec)) {
                        try cb(ctx_ptr, objects.symbolName(spec), null, null);
                    } else if (objects.isPair(spec)) {
                        const car = objects.pairCar(spec).*;
                        const cdr = objects.pairCdr(spec).*;
                        const mod_name = objects.symbolName(car);
                        if (objects.isSymbol(cdr)) {
                            // (import name as alias)
                            try cb(ctx_ptr, mod_name, objects.symbolName(cdr), null);
                        } else {
                            // (import name (only sym...))
                            var only_buf: [64][]const u8 = undefined;
                            var n: usize = 0;
                            var cur = cdr;
                            while (!value_mod.isNil(cur)) : (cur = objects.pairCdr(cur).*) {
                                if (n >= only_buf.len) return error.ContractViolation;
                                only_buf[n] = objects.symbolName(objects.pairCar(cur).*);
                                n += 1;
                            }
                            try cb(ctx_ptr, mod_name, null, only_buf[0..n]);
                        }
                    } else return error.ContractViolation;
                    vm.call_stack.reg(a).* = value_mod.NIL;
                },
            }
        }
    }

    /// Invoke a callable Value (closure or prim) with the given args.
    pub fn callValue(vm: *VM, fn_val: Value, args: []const Value) LispError!Value {
        if (objects.isClosure(fn_val)) {
            const fn_id = objects.closureCodePtr(fn_val);
            if (fn_id >= vm.compiled_fns.len) return error.ContractViolation;
            const tgt = &vm.compiled_fns[@intCast(fn_id)];
            return vm.execFn(tgt, fn_val, args);
        }
        if (objects.isPrim(fn_val)) {
            const raw = objects.primFnPtr(fn_val);
            const pfn: PrimFn = @ptrFromInt(@as(usize, @intCast(raw)));
            return pfn(vm, args);
        }
        return error.TypeError;
    }
};
