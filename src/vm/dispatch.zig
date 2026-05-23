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

// zepo-abd: arith prims used as slow-path fallback for ADD2/SUB2/etc.
const arith_prims = @import("../prims/arith.zig");
// zepo-6qx
const signal_mod = @import("../prims/signal.zig");

const bytecode = @import("../cg/bytecode.zig");
const Opcode = bytecode.Opcode;
const Instr = bytecode.Instr;
const CompiledFn = bytecode.CompiledFn;

const frame_mod = @import("frame.zig");
const CallStack = frame_mod.CallStack;
const Frame = frame_mod.Frame;
const fiber_mod = @import("fiber.zig");
pub const FiberState = fiber_mod.FiberState;
pub const FiberStatus = fiber_mod.FiberStatus;
const sched_mod = @import("sched.zig");
const channel_mod = @import("../prims/channel_prims.zig"); // zepo-s64
pub const Scheduler = sched_mod.Scheduler;

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
    /// zepo-6qx: countdown to next signal poll. Decrements each opcode;
    /// when it reaches zero pollSignals() is called and it resets to SIGNAL_POLL_INTERVAL.
    signal_poll_counter: u32 = SIGNAL_POLL_INTERVAL,
    // zepo-4yr: spawned fiber states (not including the main fiber's call_stack,
    // which lives directly in vm.call_stack). current_fiber_idx == 0 means the
    // main execution context is running; >= 1 means a spawned fiber is active.
    fibers: std.ArrayListUnmanaged(*FiberState) = .empty,
    current_fiber_idx: usize = 0,
    // zepo-0bo: when the main fiber is suspended (a spawned fiber is active),
    // its call stack is snapshotted here so GC can still walk its roots.
    main_cs_snapshot: CallStack = .{ .frames = .empty, .regs = .empty, .allocator = undefined },
    // zepo-0bo: set by the (yield) primitive; dispatch returns .yielded on the
    // next iteration boundary, leaving the frame intact for resumption.
    yield_requested: bool = false,
    // zepo-i19: blocking yield — save but do not re-enqueue (fiber-join)
    block_on_yield: bool = false,
    // zepo-8pc: park yield — block_on_yield=true but advance pc (no re-execute)
    park_on_yield: bool = false,
    // zepo-i19: active scheduler pointer, set by Scheduler.runMain
    scheduler: ?*sched_mod.Scheduler = null,
    // zepo-s64: live channels — GC traces Values inside them via vmRootVisit.
    channels: std.ArrayListUnmanaged(*channel_mod.Channel) = .empty,
    /// The GC is informed of live VM registers via a root-visitor callback
    /// registered in `installAsRoot`. The callback (`vmRootVisit`) walks only
    /// the active frame windows in `call_stack.regs`. We pre-reserve
    /// MAX_REGS capacity so the ArrayList backing slice never reallocates
    /// during a minor GC, keeping all `*Value` pointers into it stable.
    // zepo-op7: pool of register slots shared across all live frames. Each
    // recursion level consumes num_regs slots (typically 4–16). 64K slots
    // capped recursion at ~5K levels regardless of C-stack size; bumped
    // to 4M so deep non-tail recursion works (4M slots × 8B = 32MB virtual,
    // pages only fault in as the stack grows).
    pub const MAX_REGS: usize = 4 * 1024 * 1024;
    // zepo-6qx: poll signal handlers every N opcodes.
    const SIGNAL_POLL_INTERVAL: u32 = 1000;

    pub fn init(
        gc: *GC,
        globals: *GlobalEnv,
        symbols: *SymbolTable,
        compiled_fns: []CompiledFn,
        allocator: std.mem.Allocator,
        max_regs: usize,
    ) !VM {
        var cs = CallStack.init(allocator);
        try cs.regs.ensureTotalCapacity(allocator, max_regs);
        // zepo-dv2: pre-reserve frames so push hot path can use appendAssumeCapacity.
        try cs.frames.ensureTotalCapacity(allocator, 4096);
        return .{
            .gc = gc,
            .globals = globals,
            .symbols = symbols,
            .compiled_fns = compiled_fns,
            .call_stack = cs,
            .allocator = allocator,
            // zepo-0bo: empty snapshot; allocator must be valid for safe deinit.
            .main_cs_snapshot = CallStack.init(allocator),
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
        // zepo-0bo: free main fiber snapshot if it holds a saved call stack.
        vm.main_cs_snapshot.deinit();
        // zepo-4yr: free all spawned fiber states.
        for (vm.fibers.items) |fs| fs.deinit();
        vm.fibers.deinit(vm.allocator);
        // zepo-s64: channel list (channel memory freed by GC finalizers).
        vm.channels.deinit(vm.allocator);
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

        // Walk a single CallStack's live registers and closure values.
        const visitCallStack = struct {
            fn call(cs: *const CallStack, vis: @import("../gc/roots.zig").RootVisitor, vis_ctx: *anyopaque) void {
                const regs = cs.regs.items;
                for (cs.frames.items) |*f| {
                    const start: usize = f.base;
                    const end: usize = @min(regs.len, start + f.func.num_regs);
                    if (start >= end) continue;
                    for (regs[start..end]) |*slot| vis(vis_ctx, slot);
                }
                for (cs.frames.items) |*f| vis(vis_ctx, &f.closure_val);
            }
        }.call;

        // Active fiber's call stack (mirrors vm.call_stack for the running fiber).
        visitCallStack(&vm.call_stack, visitor, visitor_ctx);
        // zepo-0bo: main fiber's snapshot (non-empty only when a spawned fiber runs).
        visitCallStack(&vm.main_cs_snapshot, visitor, visitor_ctx);
        // zepo-4yr: suspended fibers — their registers must also be GC roots.
        for (vm.fibers.items) |fs| {
            visitCallStack(&fs.call_stack, visitor, visitor_ctx);
            visitor(visitor_ctx, &fs.result);
            visitor(visitor_ctx, &fs.error_val);
        }
        visitor(visitor_ctx, &vm.raised_val);
        // zepo-oju: channel buf/send_waiters hold ChannelValue (non-GC) — no tracing needed.
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

    // zepo-0bo: resume a fiber whose frame is already on vm.call_stack.
    // Runs the trampoline without pushing a new frame. Used by the scheduler
    // after a context switch to continue a previously-yielded fiber.
    pub fn resumeExecFn(vm: *VM) LispError!Value {
        trampoline: while (true) {
            const result = vm.dispatch() catch |e| return e;
            switch (result) {
                .value => |v| {
                    _ = vm.call_stack.pop();
                    return v;
                },
                .tail_call => |tc| {
                    _ = vm.call_stack.pop();
                    const base: u32 = @intCast(vm.call_stack.regs.items.len);
                    try vm.call_stack.pushFast(.{
                        .func = tc.func,
                        .pc = 0,
                        .base = base,
                        .caller_base = base,
                        .closure_val = tc.closure_val,
                        .dst_reg = frame_mod.outermost_sentinel,
                    }, tc.func.num_regs);
                    try vm.setupCallArgs(tc.func, tc.args, base, false);
                    continue :trampoline;
                },
                .yielded => return error.FiberYielded,
            }
        }
    }

    // zepo-4yr: allocate a new FiberState and register it with the VM.
    // Returns its index into vm.fibers (0-based). The caller (spawn primitive,
    // zepo-i19) is responsible for pushing an initial frame before resuming.
    // Context-switching logic lives in the scheduler (zepo-0bo).
    pub fn addFiber(vm: *VM) !usize {
        const fs = try FiberState.init(vm.allocator, VM.MAX_REGS);
        const idx = vm.fibers.items.len;
        try vm.fibers.append(vm.allocator, fs);
        return idx;
    }

    // zepo-5wg: place args from args_src into the new frame at `base`.
    // args_in_regs=true when args_src is a slice into call_stack.regs (already
    // GC-rooted); false when pointing at tc_args_buf (C-static, needs extra roots).
    fn setupCallArgs(
        vm: *VM,
        tgt: *CompiledFn,
        args_src: []const Value,
        base: u32,
        args_in_regs: bool,
    ) LispError!void {
        const args_len = args_src.len;
        var i: usize = 0;
        while (i < tgt.arity) : (i += 1) {
            vm.call_stack.regs.items[base + i] = args_src[i];
        }
        if (tgt.keyword_params.len > 0) {
            for (tgt.keyword_params) |kp| {
                vm.call_stack.regs.items[base + kp.slot] = kp.default_value;
            }
            var ki: usize = tgt.arity;
            while (ki < args_len) : (ki += 2) {
                const key_sym = args_src[ki];
                if (!objects.isSymbol(key_sym)) return error.TypeError;
                const key_name = objects.symbolName(key_sym);
                const bare = if (key_name.len > 0 and key_name[0] == ':') key_name[1..] else key_name;
                var found = false;
                for (tgt.keyword_params) |kp| {
                    if (std.mem.eql(u8, bare, kp.name)) {
                        vm.call_stack.regs.items[base + kp.slot] = args_src[ki + 1];
                        found = true;
                        break;
                    }
                }
                if (!found) return error.UnknownKeyword;
            }
        } else if (tgt.has_rest) {
            const rest_count = args_len - tgt.arity;
            const pair_bytes: usize = 24;
            if (!args_in_regs) {
                const mut: [*]Value = @constCast(args_src.ptr);
                const prev_extra = vm.gc.roots.extra.items.len;
                vm.gc.roots.extra.ensureUnusedCapacity(vm.gc.allocator, rest_count) catch return error.OutOfMemory;
                for (tgt.arity..args_len) |ri| vm.gc.roots.extra.appendAssumeCapacity(&mut[ri]);
                vm.gc.reserveNursery(pair_bytes * rest_count) catch {
                    vm.gc.roots.extra.shrinkRetainingCapacity(prev_extra);
                    return error.OutOfMemory;
                };
                vm.gc.roots.extra.shrinkRetainingCapacity(prev_extra);
            } else {
                vm.gc.reserveNursery(pair_bytes * rest_count) catch return error.OutOfMemory;
            }
            var rest: Value = value_mod.NIL;
            var k: usize = args_len;
            while (k > tgt.arity) {
                k -= 1;
                rest = objects.makePair(vm.gc, args_src[k], rest) catch return error.OutOfMemory;
            }
            vm.call_stack.regs.items[base + tgt.arity] = rest;
        }
    }

    /// Entry: run the function with given fn_id, passing `args`.
    pub fn run(vm: *VM, fn_id: u32, args: []const Value) LispError!Value {
        if (fn_id >= vm.compiled_fns.len) return error.InvalidForm;
        // zepo-0bo: route through scheduler so spawned fibers work.
        var sched = sched_mod.Scheduler.init(vm);
        defer sched.deinit();
        return sched.runMain(fn_id, args);
    }

    /// Execute a CompiledFn. Supports tail calls via a trampoline loop.
    pub fn execFn(vm: *VM, initial_func: *CompiledFn, initial_closure: Value, initial_args: []const Value) LispError!Value {
        var func = initial_func;
        var closure_val = initial_closure;

        // zepo-1p4: skip the initial memcpy. For the first trampoline
        // iteration `args_src` points at the caller's reg window directly;
        // on tail-call iterations it points into the file-static tc_args_buf
        // (already populated by the TAIL_CALL handler). The previous code
        // copied caller-args → args_buf → callee regs (two copies) and
        // tc_args_buf → args_buf → callee regs on tail-call (two copies).
        // Removing both memcpys saves ~134M copies per 24game run.
        var args_src: []const Value = initial_args;
        var args_in_regs: bool = true;
        if (initial_args.len > tc_args_buf.len) return error.ArityMismatch;
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
            // zepo-dv2: regs has MAX_REGS pre-reserved capacity; skip the
            // ensureUnusedCapacity call in the hot path.
            // zepo-5wg: outermost_sentinel marks this as the entry frame.
            try vm.call_stack.pushFast(.{
                .func = func,
                .pc = 0,
                .base = base,
                .caller_base = base,
                .closure_val = closure_val,
                .dst_reg = frame_mod.outermost_sentinel,
            }, func.num_regs);

            try vm.setupCallArgs(func, args_src, base, args_in_regs);

            const result = vm.dispatch() catch |e| {
                // Leave frame on stack — printDiagnostic walks them for traces.
                // VM is always torn down by EvalContext after an error.
                return e;
            };

            switch (result) {
                .tail_call => |tc| {
                    // Pop current frame then restart with new func/args.
                    // zepo-1p4: args already live in tc_args_buf — just point
                    // args_src at it. The next trampoline iteration places them
                    // into the new frame's regs before re-entering dispatch, so
                    // a subsequent TAIL_CALL overwriting tc_args_buf is safe.
                    _ = vm.call_stack.pop();
                    func = tc.func;
                    closure_val = tc.closure_val;
                    args_src = tc.args;
                    args_len = args_src.len;
                    args_in_regs = false;
                    continue :trampoline;
                },
                .value => |v| {
                    _ = vm.call_stack.pop();
                    return v;
                },
                // zepo-0bo: fiber yielded — frame stays on stack for resumption.
                .yielded => return error.FiberYielded,
            }
        }
    }

    const DispatchResult = union(enum) {
        value: Value,
        tail_call: struct {
            func: *CompiledFn,
            closure_val: Value,
            args: []const Value,
        },
        // zepo-0bo: fiber requested a cooperative yield; frame is left intact.
        yielded,
    };

    /// Tail-call out-buffer. Using a thread-local-ish static buffer would be
    /// simpler but Zig lacks thread locals; we put it on the VM struct.
    // zepo-op7: shrunk from [256] to [64] (see args_buf comment in execFn).
    var tc_args_buf: [64]Value = undefined;

    // zepo-5wg: dispatch drives the full multi-frame lifecycle. CALL on a closure
    // pushes a logical frame and continues in the same C stack frame instead of
    // recursing via execFn. RETURN and TAIL_CALL at non-outermost frames are
    // handled here; at the outermost frame they signal execFn via DispatchResult.
    fn dispatch(vm: *VM) LispError!DispatchResult {
        // zepo-0bo: in a resume path, inner CALL frames may already be on the
        // stack above the entry frame. Scan from the top to find the nearest
        // frame marked outermost_sentinel (always the execFn/resumeExecFn entry).
        const outermost_idx: usize = blk: {
            const frames = vm.call_stack.frames.items;
            std.debug.assert(frames.len > 0);
            var i = frames.len;
            while (i > 0) {
                i -= 1;
                if (frames[i].dst_reg == frame_mod.outermost_sentinel) break :blk i;
            }
            break :blk frames.len - 1;
        };
        var func = vm.call_stack.currentFrame().func;
        var pc: u32 = vm.call_stack.currentFrame().pc;
        var code = func.code;
        while (true) {
            // zepo-6qx: periodically poll OS signal handlers.
            vm.signal_poll_counter -= 1;
            if (vm.signal_poll_counter == 0) {
                vm.signal_poll_counter = SIGNAL_POLL_INTERVAL;
                try signal_mod.pollSignals(vm);
            }
            if (pc >= code.len) return error.ContractViolation;
            const instr = code[pc];
            pc += 1;

            const op = bytecode.decodeOp(instr);
            if (vm.gc.trace.opcodes) {
                std.debug.print("[op] {s}:{d}  {s}\n", .{
                    func.src_name, pc - 1, @tagName(op),
                });
            }
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
                    // zepo-5qc: inline-cache fast path — once a slot is resolved
                    // we just deref it. val_slot pointers are heap-stable.
                    if (func.name_caches[ni]) |slot| {
                        vm.call_stack.reg(a).* = slot.*;
                        continue;
                    }
                    // Slow path: resolve and populate cache.
                    const sym = func.name_syms[ni];
                    const name = func.names[ni];
                    // Keyword symbols (starting with ':') are self-evaluating.
                    if (name.len > 0 and name[0] == ':') {
                        vm.call_stack.reg(a).* = sym;
                        continue;
                    }
                    const slot: *Value = blk: {
                        if (vm.globals.findEntry(sym)) |e| break :blk e.val_slot;
                        if (vm.fallback_globals) |fb| {
                            if (fb.findEntry(sym)) |e| break :blk e.val_slot;
                        }
                        const frame_closure = vm.call_stack.currentFrame().closure_val;
                        if (objects.isClosure(frame_closure)) {
                            const home_ptr = objects.closureHomeEnvPtr(frame_closure);
                            if (home_ptr != 0 and home_ptr != @intFromPtr(vm.globals)) {
                                const home: *GlobalEnv = @ptrFromInt(home_ptr);
                                if (home.findEntry(sym)) |e| break :blk e.val_slot;
                            }
                        }
                        std.debug.print("error: unbound variable: {s}\n", .{name});
                        return error.UnboundVariable;
                    };
                    func.name_caches[ni] = slot;
                    vm.call_stack.reg(a).* = slot.*;
                },
                .STORE_GLOBAL => {
                    const a = bytecode.decodeA(instr);
                    const ni = bytecode.decodeBC(instr);
                    // zepo-aer: use pre-interned symbol from CompiledFn.
                    const sym = func.name_syms[ni];
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
                    const caller_base = vm.call_stack.currentFrame().base;
                    const args_start = caller_base + @as(u32, b) + 1;
                    const args_end = args_start + @as(u32, c);
                    const args_slice = vm.call_stack.regs.items[args_start..args_end];

                    if (objects.isPrim(fn_val)) {
                        const raw = objects.primFnPtr(fn_val);
                        const pfn: PrimFn = @ptrFromInt(@as(usize, @intCast(raw)));
                        const prim_val = try pfn(vm, args_slice);
                        // zepo-0bo: (yield) sets this flag; save PC and return yielded.
                        if (vm.yield_requested) {
                            vm.yield_requested = false;
                            if (vm.block_on_yield and !vm.park_on_yield) {
                                // zepo-i19: blocking prim (fiber-join) — re-execute
                                // this CALL on resume so it can return the real result.
                                vm.call_stack.currentFrame().pc = pc - 1;
                            } else {
                                // Cooperative yield or park (sleep) — advance past CALL.
                                vm.call_stack.reg(a).* = prim_val;
                                vm.call_stack.currentFrame().pc = pc;
                                vm.park_on_yield = false; // zepo-8pc
                            }
                            return DispatchResult.yielded;
                        }
                        vm.call_stack.reg(a).* = prim_val;
                    } else if (objects.isClosure(fn_val)) {
                        // zepo-5wg: push logical frame, continue in same C frame.
                        const fn_id = objects.closureCodePtr(fn_val);
                        if (fn_id >= vm.compiled_fns.len) return error.ContractViolation;
                        const tgt = &vm.compiled_fns[@intCast(fn_id)];
                        const args_len = args_slice.len;
                        if (tgt.keyword_params.len > 0) {
                            if (args_len < tgt.arity) return error.ArityMismatch;
                            if ((args_len - tgt.arity) % 2 != 0) return error.ArityMismatch;
                        } else if (tgt.has_rest) {
                            if (args_len < tgt.arity) return error.ArityMismatch;
                        } else {
                            if (args_len != tgt.arity) return error.ArityMismatch;
                        }
                        vm.call_stack.currentFrame().pc = pc;
                        const new_base: u32 = @intCast(vm.call_stack.regs.items.len);
                        try vm.call_stack.pushFast(.{
                            .func = tgt,
                            .pc = 0,
                            .base = new_base,
                            .caller_base = caller_base,
                            .closure_val = fn_val,
                            .dst_reg = a,
                        }, tgt.num_regs);
                        try vm.setupCallArgs(tgt, args_slice, new_base, true);
                        func = tgt;
                        pc = 0;
                        code = func.code;
                    } else {
                        return error.TypeError;
                    }
                },
                .TAIL_CALL => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const fn_val = vm.call_stack.reg(a).*;
                    const tc_base = vm.call_stack.currentFrame().base;
                    const args_start = tc_base + @as(u32, a) + 1;
                    const args_end = args_start + @as(u32, b);

                    if (b > tc_args_buf.len) return error.ArityMismatch;
                    @memcpy(tc_args_buf[0..b], vm.call_stack.regs.items[args_start..args_end]);

                    const at_outermost = vm.call_stack.frames.items.len - 1 == outermost_idx;

                    if (objects.isClosure(fn_val)) {
                        const fn_id = objects.closureCodePtr(fn_val);
                        if (fn_id >= vm.compiled_fns.len) return error.ContractViolation;
                        const tgt = &vm.compiled_fns[@intCast(fn_id)];
                        if (at_outermost) {
                            return DispatchResult{ .tail_call = .{
                                .func = tgt,
                                .closure_val = fn_val,
                                .args = tc_args_buf[0..b],
                            } };
                        }
                        // zepo-5wg: non-outermost tail call — inherit dst_reg from
                        // current frame and reuse the logical call slot.
                        const args_len = @as(usize, b);
                        if (tgt.keyword_params.len > 0) {
                            if (args_len < tgt.arity) return error.ArityMismatch;
                            if ((args_len - tgt.arity) % 2 != 0) return error.ArityMismatch;
                        } else if (tgt.has_rest) {
                            if (args_len < tgt.arity) return error.ArityMismatch;
                        } else {
                            if (args_len != tgt.arity) return error.ArityMismatch;
                        }
                        const dst = vm.call_stack.currentFrame().dst_reg;
                        const parent_base = vm.call_stack.frames.items[vm.call_stack.frames.items.len - 2].base;
                        _ = vm.call_stack.pop();
                        const new_base: u32 = @intCast(vm.call_stack.regs.items.len);
                        try vm.call_stack.pushFast(.{
                            .func = tgt,
                            .pc = 0,
                            .base = new_base,
                            .caller_base = parent_base,
                            .closure_val = fn_val,
                            .dst_reg = dst,
                        }, tgt.num_regs);
                        try vm.setupCallArgs(tgt, tc_args_buf[0..b], new_base, false);
                        func = tgt;
                        pc = 0;
                        code = func.code;
                        continue;
                    }
                    if (objects.isPrim(fn_val)) {
                        const raw = objects.primFnPtr(fn_val);
                        const pfn: PrimFn = @ptrFromInt(@as(usize, @intCast(raw)));
                        const prev_extra = vm.gc.roots.extra.items.len;
                        vm.gc.roots.extra.ensureUnusedCapacity(vm.gc.allocator, b) catch return error.OutOfMemory;
                        for (0..b) |i| vm.gc.roots.extra.appendAssumeCapacity(&tc_args_buf[i]);
                        const v = pfn(vm, tc_args_buf[0..b]) catch |e| {
                            vm.gc.roots.extra.shrinkRetainingCapacity(prev_extra);
                            return e;
                        };
                        vm.gc.roots.extra.shrinkRetainingCapacity(prev_extra);
                        // zepo-s64: prim in tail position may park/block-yield.
                        // Handle before returning .value so the fiber isn't
                        // falsely marked done. On park-resume, the synthetic
                        // RETURN emitted after TAIL_CALL delivers reg[a]=v.
                        if (vm.yield_requested) {
                            vm.yield_requested = false;
                            if (vm.block_on_yield and !vm.park_on_yield) {
                                vm.call_stack.currentFrame().pc = pc - 1;
                            } else {
                                vm.call_stack.reg(a).* = v;
                                vm.call_stack.currentFrame().pc = pc;
                                vm.park_on_yield = false;
                            }
                            return DispatchResult.yielded;
                        }
                        if (at_outermost) return DispatchResult{ .value = v };
                        // zepo-5wg: non-outermost prim tail call — pop, write result.
                        const dst = vm.call_stack.currentFrame().dst_reg;
                        _ = vm.call_stack.pop();
                        func = vm.call_stack.currentFrame().func;
                        pc = vm.call_stack.currentFrame().pc;
                        code = func.code;
                        vm.call_stack.reg(dst).* = v;
                        continue;
                    }
                    return error.TypeError;
                },
                .RETURN => {
                    const a = bytecode.decodeA(instr);
                    const v = vm.call_stack.reg(a).*;
                    if (vm.call_stack.frames.items.len - 1 == outermost_idx) {
                        return DispatchResult{ .value = v };
                    }
                    // zepo-5wg: non-outermost return — pop frame, write result
                    // into caller's dst_reg, resume caller's dispatch context.
                    const dst = vm.call_stack.currentFrame().dst_reg;
                    _ = vm.call_stack.pop();
                    func = vm.call_stack.currentFrame().func;
                    pc = vm.call_stack.currentFrame().pc;
                    code = func.code;
                    vm.call_stack.reg(dst).* = v;
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

                // zepo-abd: 2-arg specialized arithmetic.
                .ADD2 => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const c = bytecode.decodeC(instr);
                    const va = vm.call_stack.reg(b).*;
                    const vb = vm.call_stack.reg(c).*;
                    if (((va ^ 1) | (vb ^ 1)) & 7 == 0) {
                        const r = @addWithOverflow(va, vb);
                        if (r[1] == 0) {
                            vm.call_stack.reg(a).* = r[0] - 1;
                            continue;
                        }
                    }
                    var args = [_]Value{ va, vb };
                    vm.call_stack.reg(a).* = try arith_prims.primAdd(vm, args[0..]);
                },
                .SUB2 => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const c = bytecode.decodeC(instr);
                    const va = vm.call_stack.reg(b).*;
                    const vb = vm.call_stack.reg(c).*;
                    if (((va ^ 1) | (vb ^ 1)) & 7 == 0) {
                        const r = @subWithOverflow(va, vb);
                        if (r[1] == 0) {
                            vm.call_stack.reg(a).* = r[0] + 1;
                            continue;
                        }
                    }
                    var args = [_]Value{ va, vb };
                    vm.call_stack.reg(a).* = try arith_prims.primSub(vm, args[0..]);
                },
                .MUL2 => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const c = bytecode.decodeC(instr);
                    const va = vm.call_stack.reg(b).*;
                    const vb = vm.call_stack.reg(c).*;
                    if (((va ^ 1) | (vb ^ 1)) & 7 == 0) {
                        const av: i64 = @as(i64, @bitCast(va)) >> 3;
                        const bv: i64 = @as(i64, @bitCast(vb)) >> 3;
                        const r = @mulWithOverflow(av, bv);
                        if (r[1] == 0) {
                            const max_i63: i64 = (@as(i64, 1) << 62) - 1;
                            const min_i63: i64 = -(@as(i64, 1) << 62);
                            if (r[0] <= max_i63 and r[0] >= min_i63) {
                                vm.call_stack.reg(a).* = value_mod.fixnum(@intCast(r[0]));
                                continue;
                            }
                        }
                    }
                    var args = [_]Value{ va, vb };
                    vm.call_stack.reg(a).* = try arith_prims.primMul(vm, args[0..]);
                },
                .NUM_EQ2 => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const c = bytecode.decodeC(instr);
                    const va = vm.call_stack.reg(b).*;
                    const vb = vm.call_stack.reg(c).*;
                    if (((va ^ 1) | (vb ^ 1)) & 7 == 0) {
                        vm.call_stack.reg(a).* = if (va == vb) value_mod.TRUE else value_mod.FALSE;
                        continue;
                    }
                    var args = [_]Value{ va, vb };
                    vm.call_stack.reg(a).* = try arith_prims.primNumEq(vm, args[0..]);
                },
                .NUM_LT2 => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const c = bytecode.decodeC(instr);
                    const va = vm.call_stack.reg(b).*;
                    const vb = vm.call_stack.reg(c).*;
                    if (((va ^ 1) | (vb ^ 1)) & 7 == 0) {
                        const ai: i64 = @bitCast(va);
                        const bi: i64 = @bitCast(vb);
                        vm.call_stack.reg(a).* = if (ai < bi) value_mod.TRUE else value_mod.FALSE;
                        continue;
                    }
                    var args = [_]Value{ va, vb };
                    vm.call_stack.reg(a).* = try arith_prims.primLt(vm, args[0..]);
                },
                .NUM_GT2 => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const c = bytecode.decodeC(instr);
                    const va = vm.call_stack.reg(b).*;
                    const vb = vm.call_stack.reg(c).*;
                    if (((va ^ 1) | (vb ^ 1)) & 7 == 0) {
                        const ai: i64 = @bitCast(va);
                        const bi: i64 = @bitCast(vb);
                        vm.call_stack.reg(a).* = if (ai > bi) value_mod.TRUE else value_mod.FALSE;
                        continue;
                    }
                    var args = [_]Value{ va, vb };
                    vm.call_stack.reg(a).* = try arith_prims.primGt(vm, args[0..]);
                },
                // zepo-w19: predicate opcodes — direct inline tests.
                .NULL_P => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const v = vm.call_stack.reg(b).*;
                    vm.call_stack.reg(a).* = if (value_mod.isNil(v)) value_mod.TRUE else value_mod.FALSE;
                },
                .PAIR_P => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const v = vm.call_stack.reg(b).*;
                    vm.call_stack.reg(a).* = if (objects.isPair(v)) value_mod.TRUE else value_mod.FALSE;
                },
                .EQ_P => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const c = bytecode.decodeC(instr);
                    const va = vm.call_stack.reg(b).*;
                    const vb = vm.call_stack.reg(c).*;
                    vm.call_stack.reg(a).* = if (va == vb) value_mod.TRUE else value_mod.FALSE;
                },
                // zepo-28f: fused predicate+branch. Branch to BC when predicate
                // is FALSE — matches JUMP_IF_FALSE so the fall-through JUMP to
                // the then-label still works.
                .BR_IF_NOT_NULL => {
                    const a = bytecode.decodeA(instr);
                    const target = bytecode.decodeBC(instr);
                    const v = vm.call_stack.reg(a).*;
                    if (!value_mod.isNil(v)) pc = target;
                },
                .BR_IF_NOT_PAIR => {
                    const a = bytecode.decodeA(instr);
                    const target = bytecode.decodeBC(instr);
                    const v = vm.call_stack.reg(a).*;
                    if (!objects.isPair(v)) pc = target;
                },
                // zepo-lpj: 2-word fused 2-arg compare+branch. Reads the
                // following JUMP instruction for the else target.
                .BR_IF_NUM_NEQ => {
                    const a_reg = bytecode.decodeA(instr);
                    const b_reg = bytecode.decodeB(instr);
                    const va = vm.call_stack.reg(a_reg).*;
                    const vb = vm.call_stack.reg(b_reg).*;
                    const next_instr = code[pc];
                    pc += 1;
                    var pred_true: bool = undefined;
                    if (((va ^ 1) | (vb ^ 1)) & 7 == 0) {
                        pred_true = (va == vb);
                    } else {
                        var args = [_]Value{ va, vb };
                        const r = try arith_prims.primNumEq(vm, args[0..]);
                        pred_true = !value_mod.isFalsy(r);
                    }
                    if (!pred_true) pc = bytecode.decodeBC(next_instr);
                },
                .BR_IF_NUM_NLT => {
                    const a_reg = bytecode.decodeA(instr);
                    const b_reg = bytecode.decodeB(instr);
                    const va = vm.call_stack.reg(a_reg).*;
                    const vb = vm.call_stack.reg(b_reg).*;
                    const next_instr = code[pc];
                    pc += 1;
                    var pred_true: bool = undefined;
                    if (((va ^ 1) | (vb ^ 1)) & 7 == 0) {
                        const ai: i64 = @bitCast(va);
                        const bi: i64 = @bitCast(vb);
                        pred_true = (ai < bi);
                    } else {
                        var args = [_]Value{ va, vb };
                        const r = try arith_prims.primLt(vm, args[0..]);
                        pred_true = !value_mod.isFalsy(r);
                    }
                    if (!pred_true) pc = bytecode.decodeBC(next_instr);
                },
                .BR_IF_NUM_NGT => {
                    const a_reg = bytecode.decodeA(instr);
                    const b_reg = bytecode.decodeB(instr);
                    const va = vm.call_stack.reg(a_reg).*;
                    const vb = vm.call_stack.reg(b_reg).*;
                    const next_instr = code[pc];
                    pc += 1;
                    var pred_true: bool = undefined;
                    if (((va ^ 1) | (vb ^ 1)) & 7 == 0) {
                        const ai: i64 = @bitCast(va);
                        const bi: i64 = @bitCast(vb);
                        pred_true = (ai > bi);
                    } else {
                        var args = [_]Value{ va, vb };
                        const r = try arith_prims.primGt(vm, args[0..]);
                        pred_true = !value_mod.isFalsy(r);
                    }
                    if (!pred_true) pc = bytecode.decodeBC(next_instr);
                },
                .BR_IF_NEQP => {
                    const a_reg = bytecode.decodeA(instr);
                    const b_reg = bytecode.decodeB(instr);
                    const va = vm.call_stack.reg(a_reg).*;
                    const vb = vm.call_stack.reg(b_reg).*;
                    const next_instr = code[pc];
                    pc += 1;
                    if (va != vb) pc = bytecode.decodeBC(next_instr);
                },
                // zepo-i3b: const-operand arithmetic & comparisons.
                .ADDI => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const c_raw = bytecode.decodeC(instr);
                    const imm: i8 = @bitCast(c_raw);
                    const v = vm.call_stack.reg(b).*;
                    if ((v & 7) == 1) {
                        const sv = value_mod.fixnumVal(v);
                        const r = std.math.add(i64, @as(i64, sv), @as(i64, imm)) catch {
                            var args = [_]Value{ v, value_mod.fixnum(@intCast(imm)) };
                            vm.call_stack.reg(a).* = try arith_prims.primAdd(vm, args[0..]);
                            continue;
                        };
                        const max_i63: i64 = (@as(i64, 1) << 62) - 1;
                        const min_i63: i64 = -(@as(i64, 1) << 62);
                        if (r <= max_i63 and r >= min_i63) {
                            vm.call_stack.reg(a).* = value_mod.fixnum(@intCast(r));
                            continue;
                        }
                    }
                    var args = [_]Value{ v, value_mod.fixnum(@intCast(imm)) };
                    vm.call_stack.reg(a).* = try arith_prims.primAdd(vm, args[0..]);
                },
                .SUBI => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const c_raw = bytecode.decodeC(instr);
                    const imm: i8 = @bitCast(c_raw);
                    const v = vm.call_stack.reg(b).*;
                    if ((v & 7) == 1) {
                        const sv = value_mod.fixnumVal(v);
                        const r = std.math.sub(i64, @as(i64, sv), @as(i64, imm)) catch {
                            var args = [_]Value{ v, value_mod.fixnum(@intCast(imm)) };
                            vm.call_stack.reg(a).* = try arith_prims.primSub(vm, args[0..]);
                            continue;
                        };
                        const max_i63: i64 = (@as(i64, 1) << 62) - 1;
                        const min_i63: i64 = -(@as(i64, 1) << 62);
                        if (r <= max_i63 and r >= min_i63) {
                            vm.call_stack.reg(a).* = value_mod.fixnum(@intCast(r));
                            continue;
                        }
                    }
                    var args = [_]Value{ v, value_mod.fixnum(@intCast(imm)) };
                    vm.call_stack.reg(a).* = try arith_prims.primSub(vm, args[0..]);
                },
                .NUM_EQ_I => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const c_raw = bytecode.decodeC(instr);
                    const imm: i8 = @bitCast(c_raw);
                    const v = vm.call_stack.reg(b).*;
                    if ((v & 7) == 1) {
                        const enc_imm = value_mod.fixnum(@intCast(imm));
                        vm.call_stack.reg(a).* = if (v == enc_imm) value_mod.TRUE else value_mod.FALSE;
                        continue;
                    }
                    var args = [_]Value{ v, value_mod.fixnum(@intCast(imm)) };
                    vm.call_stack.reg(a).* = try arith_prims.primNumEq(vm, args[0..]);
                },
                .NUM_LT_I => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const c_raw = bytecode.decodeC(instr);
                    const imm: i8 = @bitCast(c_raw);
                    const v = vm.call_stack.reg(b).*;
                    if ((v & 7) == 1) {
                        const sv = value_mod.fixnumVal(v);
                        vm.call_stack.reg(a).* = if (@as(i64, sv) < @as(i64, imm)) value_mod.TRUE else value_mod.FALSE;
                        continue;
                    }
                    var args = [_]Value{ v, value_mod.fixnum(@intCast(imm)) };
                    vm.call_stack.reg(a).* = try arith_prims.primLt(vm, args[0..]);
                },
                .BR_IF_NUM_NEQ_I => {
                    const a_reg = bytecode.decodeA(instr);
                    const b_raw = bytecode.decodeB(instr);
                    const imm: i8 = @bitCast(b_raw);
                    const v = vm.call_stack.reg(a_reg).*;
                    const next_instr = code[pc];
                    pc += 1;
                    var pred_true: bool = undefined;
                    if ((v & 7) == 1) {
                        const enc_imm = value_mod.fixnum(@intCast(imm));
                        pred_true = (v == enc_imm);
                    } else {
                        var args = [_]Value{ v, value_mod.fixnum(@intCast(imm)) };
                        const r = try arith_prims.primNumEq(vm, args[0..]);
                        pred_true = !value_mod.isFalsy(r);
                    }
                    if (!pred_true) pc = bytecode.decodeBC(next_instr);
                },
                // zepo-8tx: 2-arg fixnum modulo with Scheme sign-of-divisor.
                .MOD2 => {
                    const a = bytecode.decodeA(instr);
                    const b = bytecode.decodeB(instr);
                    const c = bytecode.decodeC(instr);
                    const va = vm.call_stack.reg(b).*;
                    const vb = vm.call_stack.reg(c).*;
                    if (((va ^ 1) | (vb ^ 1)) & 7 == 0) {
                        const av: i64 = value_mod.fixnumVal(va);
                        const bv: i64 = value_mod.fixnumVal(vb);
                        if (bv != 0) {
                            const r = @rem(av, bv);
                            const result: i64 = if (r == 0) 0 else if ((r > 0) == (bv > 0)) r else r + bv;
                            vm.call_stack.reg(a).* = value_mod.fixnum(@intCast(result));
                            continue;
                        }
                    }
                    var args = [_]Value{ va, vb };
                    vm.call_stack.reg(a).* = try arith_prims.primModulo(vm, args[0..]);
                },
                .BR_IF_NUM_NLT_I => {
                    const a_reg = bytecode.decodeA(instr);
                    const b_raw = bytecode.decodeB(instr);
                    const imm: i8 = @bitCast(b_raw);
                    const v = vm.call_stack.reg(a_reg).*;
                    const next_instr = code[pc];
                    pc += 1;
                    var pred_true: bool = undefined;
                    if ((v & 7) == 1) {
                        const sv = value_mod.fixnumVal(v);
                        pred_true = (@as(i64, sv) < @as(i64, imm));
                    } else {
                        var args = [_]Value{ v, value_mod.fixnum(@intCast(imm)) };
                        const r = try arith_prims.primLt(vm, args[0..]);
                        pred_true = !value_mod.isFalsy(r);
                    }
                    if (!pred_true) pc = bytecode.decodeBC(next_instr);
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
