// zepo-b5h: spawn-worker, worker-alive?, worker-stop, worker-stopping? primitives
//
// Workers are OS threads with isolated VM instances (own GC, symbol table,
// globals, fiber scheduler). The entry thunk is supplied as a Lisp source
// string that is evaluated in the worker's fresh stdlib context. Pre-shared
// Channel objects (system-allocated, mutex-protected) are passed as
// arguments to the evaluated callable.
//
// Worker lifetime: WorkerState is GC-managed in the spawning VM. The GC
// finalizer joins the OS thread and frees the state. Channels passed to
// a worker are owned by the spawning VM; the worker wraps them with null
// finalizers so its GC does not free them.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const LispError = runtime.LispError;
const vm_mod = @import("../vm/dispatch.zig");
const VM = vm_mod.VM;
const GC = @import("../gc/collector.zig").GC;
const channel_prims = @import("channel_prims.zig");
const Channel = channel_prims.Channel;
const register = @import("register.zig");
const Scheduler = @import("../vm/sched.zig").Scheduler;
const portable = @import("../runtime/portable_value.zig");

pub const TAG_WORKER: u64 = 0xB57_0000_0001;

pub const WorkerState = struct {
    allocator: std.mem.Allocator,
    thread: std.Thread,
    done: std.atomic.Value(u32) = .init(0),
    stop_requested: std.atomic.Value(u32) = .init(0),
    // zepo-p5b: write side of the worker scheduler's wakeup pipe. Published
    // by workerThread before entering runMain; -1 once the scheduler exits.
    wakeup_fd: std.atomic.Value(c_int) = .init(-1),
    // zepo-p5b: ensures stopAndJoin runs exactly once even when both the
    // explicit shutdown hook and the GC finalizer fire on the same worker.
    joined: std.atomic.Value(u32) = .init(0),
};

// zepo-p5b: idempotent stop + join. Safe to call multiple times from any
// context (shutdown hook, GC finalizer, or both — the first wins).
fn stopAndJoin(ws: *WorkerState) void {
    if (ws.joined.swap(1, .acq_rel) != 0) return;
    ws.stop_requested.store(1, .release);
    const fd = ws.wakeup_fd.load(.acquire);
    if (fd >= 0) {
        const one: [1]u8 = .{1};
        _ = std.c.write(fd, &one, 1);
    }
    ws.thread.join();
}

// zepo-p5b: shutdown-hook entry point — invoked by VM.deinit before any
// other resource teardown. Joins the worker thread but does NOT free the
// WorkerState (the GC finalizer does that).
fn workerShutdownHook(ptr: *anyopaque) void {
    const ws: *WorkerState = @ptrCast(@alignCast(ptr));
    stopAndJoin(ws);
}

const WorkerStart = struct {
    code: ?[]const u8, // zepo-ebd: string entry (back-compat), or null
    form: ?*portable.ChannelValue, // zepo-ebd: serialized form entry, or null
    channel_ptrs: []*Channel,
    n_channels: usize,
    allocator: std.mem.Allocator,
    worker: *WorkerState,
};

// zepo-b5h: worker OS thread entry. Creates an isolated VM, loads stdlib,
// wraps the pre-shared channels as foreign values, evaluates `code` to a
// callable, then invokes it with the channels as arguments.
fn workerThread(start: *WorkerStart) void {
    const alloc = start.allocator;
    const worker = start.worker;
    const start_code = start.code; // zepo-ebd
    const start_form = start.form; // zepo-ebd
    const channel_ptrs = start.channel_ptrs;
    const n_channels = start.n_channels;
    alloc.destroy(start);
    defer worker.done.store(1, .release);

    // Isolated runtime — separate GC heap from spawning VM.
    var gc = GC.init(alloc) catch return;
    defer gc.deinit();
    var syms = runtime.SymbolTable.init(&gc, alloc) catch return;
    defer syms.deinit();
    var globals = runtime.GlobalEnv.init(&gc, alloc) catch return;
    defer globals.deinit();
    register.registerAll(&gc, &globals, &syms) catch return;
    var ctx = runtime.EvalContext.init(&gc, &syms, &globals, alloc) catch return;
    defer ctx.deinit();
    ctx.installRootVisitor();
    runtime.loadStdlib(&ctx) catch return;

    // zepo-ebd: evaluate the entry — a source string or a portable form.
    const fn_val = blk: {
        if (start_code) |c| {
            const v = ctx.evalString(c, "<worker>") catch {
                alloc.free(c);
                return;
            };
            alloc.free(c);
            break :blk v;
        } else if (start_form) |f| {
            defer portable.freeChannelValue(f, alloc);
            const entry_form = portable.deserializeFromChannel(f, ctx.gc, ctx.symbols) catch return;
            // Root the freshly-deserialized form across evalForm (defensive;
            // matches the codebase's careful rooting style).
            var scope = @import("../gc/collector.zig").HandleScope{};
            ctx.gc.roots.pushHandleScope(&scope);
            defer ctx.gc.roots.popHandleScope();
            const form_slot = scope.push(entry_form);
            break :blk ctx.evalForm(form_slot.*) catch return;
        } else return;
    };

    if (!objects.isClosure(fn_val) and !objects.isPrim(fn_val)) return;
    const arity = if (objects.isClosure(fn_val))
        @as(usize, @intCast(objects.closureArity(fn_val)))
    else
        @as(usize, @intCast(objects.primArity(fn_val)));
    if (arity != n_channels) return;

    // Wrap channels as foreign values with null finalizer — owned by parent VM.
    const chan_vals = alloc.alloc(Value, n_channels) catch return;
    defer alloc.free(chan_vals);
    for (channel_ptrs, 0..) |ch, i| {
        chan_vals[i] = objects.makeForeign(ctx.vm.?.gc, ch, null, channel_prims.TAG_CHANNEL) catch return;
    }
    alloc.free(channel_ptrs);

    if (objects.isClosure(fn_val)) {
        const fn_id: u32 = @intCast(objects.closureCodePtr(fn_val));
        // zepo-b5h: expose the stop flag so (worker-stopping?) needs no handle.
        ctx.vm.?.stop_flag = &worker.stop_requested;
        // zepo-p5b: run our own scheduler so we can publish the wakeup fd
        // before entering the event loop. The parent's shutdown hook writes
        // to this fd to break us out of poll(), then sets stop_flag so
        // runMain returns at the top of the next loop iteration.
        var sched = Scheduler.init(&ctx.vm.?);
        defer sched.deinit();
        sched.initWakeupFd() catch return;
        worker.wakeup_fd.store(sched.wakeup_write_fd, .release);
        defer worker.wakeup_fd.store(-1, .release);
        _ = sched.runMain(fn_id, chan_vals) catch {};
    }
}

fn workerDeinit(ptr: ?*anyopaque) callconv(.c) void {
    const ws: *WorkerState = @ptrCast(@alignCast(ptr orelse return));
    // zepo-p5b: stopAndJoin is idempotent — if the VM's shutdown hook already
    // joined this worker, this just falls through to free.
    stopAndJoin(ws);
    ws.allocator.destroy(ws);
}

fn getWorker(v: Value) LispError!*WorkerState {
    if (!objects.isForeign(v)) return error.TypeError;
    if (objects.foreignTypeTag(v) != TAG_WORKER) return error.TypeError;
    return @ptrCast(@alignCast(objects.foreignPayload(v) orelse return error.ContractViolation));
}

// ── (spawn-worker code-string channel...) → worker-handle ────────────────────
pub fn primSpawnWorker(vm: *VM, args: []const Value) LispError!Value {
    if (args.len < 1) return error.ArityMismatch;

    const n_channels = args.len - 1;
    // zepo-b5h: use c_allocator for cross-thread allocations (DebugAllocator
    // is single-threaded; the worker thread owns WorkerStart and frees it).
    const alloc = std.heap.c_allocator;

    // zepo-ebd: entry may be a source string (back-compat) or a portable form.
    var code: ?[]const u8 = null;
    var form: ?*portable.ChannelValue = null;
    if (objects.isString(args[0])) {
        code = alloc.dupe(u8, objects.stringBytes(args[0])) catch return error.OutOfMemory;
    } else {
        form = portable.serializeToChannel(args[0], alloc) catch |e| switch (e) {
            error.NonPortableValue => return error.NonPortableValue,
            else => return error.OutOfMemory,
        };
    }
    errdefer {
        if (code) |c| alloc.free(c);
        if (form) |f| portable.freeChannelValue(f, alloc);
    }

    const channel_ptrs = alloc.alloc(*Channel, n_channels) catch return error.OutOfMemory;
    errdefer alloc.free(channel_ptrs);
    for (args[1..], 0..) |arg, i| {
        if (!objects.isForeign(arg)) return error.TypeError;
        if (objects.foreignTypeTag(arg) != channel_prims.TAG_CHANNEL) return error.TypeError;
        channel_ptrs[i] = @ptrCast(@alignCast(objects.foreignPayload(arg) orelse return error.ContractViolation));
    }

    const ws = alloc.create(WorkerState) catch return error.OutOfMemory;
    errdefer alloc.destroy(ws);
    ws.* = .{ .allocator = alloc, .thread = undefined };

    const start = alloc.create(WorkerStart) catch return error.OutOfMemory;
    errdefer alloc.destroy(start);
    start.* = .{
        .code = code,
        .form = form, // zepo-ebd
        .channel_ptrs = channel_ptrs,
        .n_channels = n_channels,
        .allocator = alloc,
        .worker = ws,
    };

    ws.thread = std.Thread.spawn(.{}, workerThread, .{start}) catch return error.OutOfMemory;

    // zepo-p5b: register a shutdown hook so VM.deinit joins this worker
    // before GC finalizers free channels the worker may still be using.
    vm.registerShutdownHook(.{
        .ctx = ws,
        .func = workerShutdownHook,
    }) catch return error.OutOfMemory;

    return objects.makeForeign(vm.gc, ws, workerDeinit, TAG_WORKER);
}

// ── (worker? v) → bool ───────────────────────────────────────────────────────
pub fn primWorkerQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const is = objects.isForeign(args[0]) and objects.foreignTypeTag(args[0]) == TAG_WORKER;
    return if (is) value_mod.TRUE else value_mod.FALSE;
}

// ── (worker-alive? handle) → bool ────────────────────────────────────────────
pub fn primWorkerAliveQ(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const ws = try getWorker(args[0]);
    return if (ws.done.load(.acquire) == 0) value_mod.TRUE else value_mod.FALSE;
}

// ── (worker-stop handle) → #void ─────────────────────────────────────────────
// Sets the stop flag. Worker code should call (worker-stopping?) to check it.
pub fn primWorkerStop(_: *VM, args: []const Value) LispError!Value {
    if (args.len != 1) return error.ArityMismatch;
    const ws = try getWorker(args[0]);
    ws.stop_requested.store(1, .release);
    return value_mod.NIL;
}

// ── (worker-stopping?) → bool ────────────────────────────────────────────────
// 0-arg: checks the current worker's stop flag via vm.stop_flag.
// Returns #f in non-worker contexts (stop_flag is null).
pub fn primWorkerStoppingQ(vm: *VM, args: []const Value) LispError!Value {
    if (args.len != 0) return error.ArityMismatch;
    const flag = vm.stop_flag orelse return value_mod.FALSE;
    return if (flag.load(.acquire) != 0) value_mod.TRUE else value_mod.FALSE;
}
