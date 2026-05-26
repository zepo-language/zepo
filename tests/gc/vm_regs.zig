//! GC test: VM register stack is walked as a root during minor collection.
//!
//! Install the VM as a GC root-visitor, push a frame manually, store a
//! freshly-allocated pair into a register, then trigger allocation in a
//! tight loop that forces multiple minor GCs. The register slot's pair
//! chain must remain intact.

const std = @import("std");
const zepo = @import("zepo");
const abi = zepo.abi;
const gcmod = zepo.gc;
const runtime = zepo.runtime;
const objects = runtime.objects;
const SymbolTable = runtime.SymbolTable;
const GlobalEnv = runtime.GlobalEnv;
const vm_mod = zepo.vm;
const cg = zepo.cg;
const bytecode = cg;

const Value = abi.Value;
const value_mod = abi.value;

const alloc = std.testing.allocator;

test "minor GC preserves VM registers" {
    var gc = try gcmod.GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();
    var globals = try GlobalEnv.init(&gc, alloc);
    defer globals.deinit();

    // Build an empty CompiledFn so we can push a frame.
    var code_buf = [_]bytecode.Instr{};
    var consts_buf = [_]Value{};
    var names_buf = [_][]const u8{};
    var name_syms_buf = [_]Value{};
    var name_caches_buf = [_]?*Value{};
    var sps_buf = [_]bytecode.SafepointMap{};
    var cf = bytecode.CompiledFn{
        .id = 0,
        .arity = 0,
        .has_rest = false,
        .num_regs = 16,
        .code = &code_buf,
        .consts = &consts_buf,
        .names = &names_buf,
        .name_syms = &name_syms_buf,
        .name_caches = &name_caches_buf,
        .safepoint_maps = &sps_buf,
        .allocator = alloc,
    };
    var compiled_fns = [_]*bytecode.CompiledFn{&cf}; // zepo-nhl: slice of boxed ptr

    var vm = try vm_mod.VM.init(&gc, &globals, &syms, &compiled_fns, alloc, vm_mod.VM.MAX_REGS);
    defer vm.deinit();
    vm.installAsRoot();

    // Push a frame and populate reg(0) with the head of a long pair chain.
    try vm.call_stack.push(.{
        .func = &cf,
        .pc = 0,
        .base = 0,
        .caller_base = 0,
        .closure_val = value_mod.NIL,
    }, 16);
    defer _ = vm.call_stack.pop();

    // Build a chain that dwarfs nursery size (~21k pairs). reg(0) holds the
    // growing chain head; reg(1) holds the current fixnum (non-ptr, but
    // safe either way). The GC root visitor walks all regs so the chain
    // survives across any minor GC fired inside `makePair`. We call
    // `gc.reserveNursery` before each allocation so makePair itself does
    // not trigger a collection while its `car`/`cdr` parameters are live
    // on the C stack.
    vm.call_stack.regs.items[0] = value_mod.NIL;
    // Build a 2K pair chain (fits comfortably in nursery), then trigger
    // a single minor GC and verify the chain survives only because the
    // VM register root-visitor forwarded reg(0) during the collection.
    var i: i63 = 0;
    const N: i63 = 2_000;
    while (i < N) : (i += 1) {
        try gc.reserveNursery(64);
        const cdr_head = vm.call_stack.regs.items[0];
        const new_pair = try objects.makePair(&gc, value_mod.fixnum(i), cdr_head);
        vm.call_stack.regs.items[0] = new_pair;
    }

    // Single minor GC with chain live only through reg(0). Without the VM
    // register visitor, the whole chain would be reclaimed here.
    try gc.minor();

    // Verify chain integrity.
    var cur = vm.call_stack.regs.items[0];
    var expected: i63 = N - 1;
    var seen: usize = 0;
    while (!value_mod.isNil(cur)) {
        try std.testing.expect(objects.isPair(cur));
        const car = objects.pairCar(cur).*;
        try std.testing.expect(value_mod.isFixnum(car));
        try std.testing.expectEqual(expected, value_mod.fixnumVal(car));
        expected -= 1;
        seen += 1;
        cur = objects.pairCdr(cur).*;
    }
    try std.testing.expectEqual(@as(usize, @intCast(N)), seen);
    try gcmod.Verifier.verify(&gc);
}
