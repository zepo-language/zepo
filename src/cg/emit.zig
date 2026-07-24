//! Lower `ir.Program` into `[]CompiledFn`.
//!
//! The IR has an unbounded register space (u16) with no contiguity guarantees.
//! The bytecode CALL/TAIL_CALL opcodes require args to sit in a contiguous
//! window of registers starting at B+1 (for CALL) or A+1 (for TAIL_CALL).
//! So before every call we allocate a fresh arg window and MOVE the arg
//! values into it.
//!
//! Lowering is a two-pass process per function:
//!   pass 1: walk IR and emit placeholder bytecode with IR-level jump targets
//!           (encoded as labels), collecting label positions.
//!   pass 2: patch JUMP and JUMP_IF_FALSE instructions with their resolved PCs.
//!
//! The register count is conservative: we use `func.next_reg` from the IR as
//! a starting point and then add room for the arg windows we allocate.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;

const runtime = @import("../runtime/mod.zig");
const SymbolTable = runtime.SymbolTable;
const objects = runtime.objects;
const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;

const ir = @import("../ir/mod.zig");
const Op = ir.Op;
const Program = ir.Program;
const Function = ir.Function;
const Reg = ir.Reg;
const Label = ir.Label;

const bytecode = @import("bytecode.zig");
const Opcode = bytecode.Opcode;
const Instr = bytecode.Instr;
const CompiledFn = bytecode.CompiledFn;
const SafepointMap = bytecode.SafepointMap;

pub const Emitter = struct {
    allocator: std.mem.Allocator,
    symbols: *SymbolTable,
    gc: *GC,
    /// Owns the backing storage for all names referenced by CompiledFn.names
    /// across the program. We keep one per-emitter pool for simplicity.
    names_pool: std.ArrayList([]const u8),
    /// Number of functions already emitted; emitAppend only emits beyond this.
    emitted_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, symbols: *SymbolTable, gc: *GC) Emitter {
        return .{
            .allocator = allocator,
            .symbols = symbols,
            .gc = gc,
            .names_pool = std.ArrayListUnmanaged([]const u8).empty,
        };
    }

    pub fn deinit(e: *Emitter) void {
        for (e.names_pool.items) |s| e.allocator.free(s);
        e.names_pool.deinit(e.allocator);
    }

    pub fn emit(e: *Emitter, program: *Program) ![]CompiledFn {
        const funcs = try e.allocator.alloc(CompiledFn, program.functions.items.len);
        errdefer e.allocator.free(funcs);
        for (program.functions.items, 0..) |*f, i| {
            funcs[i] = try e.emitOne(f);
        }
        return funcs;
    }

    /// Append newly-compiled functions to `list`. Only emits functions added
    /// to `program` since the last call. O(new) instead of O(total).
    // zepo-nhl: store *CompiledFn so each boxed fn has a stable address even
    // when this pointer-list reallocates. Live frames / cached dispatch locals
    // hold *CompiledFn into the boxes, which must never move.
    pub fn emitAppend(e: *Emitter, program: *Program, list: *std.ArrayListUnmanaged(*CompiledFn)) !void {
        const new_count = program.functions.items.len;
        if (new_count <= e.emitted_count) return;
        try list.ensureTotalCapacity(e.allocator, new_count);
        for (e.emitted_count..new_count) |i| {
            // zepo-nhl: emit the value first, then box it. If create() fails,
            // free cf's internal allocations so they don't leak. ensureTotalCapacity
            // above guarantees appendAssumeCapacity cannot fail here.
            var cf = try e.emitOne(&program.functions.items[i]);
            errdefer cf.deinit(e.allocator);
            const boxed = try e.allocator.create(CompiledFn);
            boxed.* = cf;
            list.appendAssumeCapacity(boxed);
        }
        e.emitted_count = new_count;
    }

    fn emitOne(e: *Emitter, f: *Function) !CompiledFn {
        var ctx = FnEmit.init(e);
        defer ctx.deinit();

        // Layout: physical regs [0..num_locals) hold local-slot values (which
        // doubles as parameter storage), then [num_locals..num_locals+max_ir_reg+1)
        // hold IR virtual registers.
        ctx.local_base = 0;
        ctx.reg_base = f.num_locals;
        ctx.next_phys_reg = @as(Reg, f.num_locals) + computeMaxReg(f) + 1;
        ctx.call_temp_base = ctx.next_phys_reg;
        ctx.peak_phys_reg = ctx.next_phys_reg;

        // Pass 1: emit instructions, tracking label positions.
        // Detect tail-call pattern: a `.call` followed (ignoring labels) by
        // `.ret { .src = call.dst }`. Such calls become TAIL_CALL so recursion
        // doesn't grow the Zig stack.
        var i: usize = 0;
        while (i < f.ops.items.len) : (i += 1) {
            const op = f.ops.items[i];
            if (op == .call) {
                const c = op.call;
                var j = i + 1;
                while (j < f.ops.items.len and f.ops.items[j] == .label) : (j += 1) {}
                if (j < f.ops.items.len and f.ops.items[j] == .ret and f.ops.items[j].ret.src == c.dst) {
                    try ctx.emitTailCall(c.func, c.args);
                    var k = i + 1;
                    while (k < j) : (k += 1) {
                        try ctx.emitOp(f.ops.items[k]);
                    }
                    i = j;
                    continue;
                }
            }
            try ctx.emitOp(op);
        }

        // Pass 2: patch jumps.
        try ctx.patchJumps();

        // Build CompiledFn.
        const code = try ctx.code.toOwnedSlice(e.allocator);
        errdefer e.allocator.free(code);
        const consts = try ctx.consts.toOwnedSlice(e.allocator);
        errdefer e.allocator.free(consts);
        const names = try ctx.names.toOwnedSlice(e.allocator);
        errdefer e.allocator.free(names);
        const name_syms = try ctx.name_syms.toOwnedSlice(e.allocator);
        errdefer e.allocator.free(name_syms);
        // zepo-5qc: parallel cache, all slots null initially.
        const name_caches = try e.allocator.alloc(?*Value, name_syms.len);
        errdefer e.allocator.free(name_caches);
        @memset(name_caches, null);
        const safepoints = try ctx.safepoint_maps.toOwnedSlice(e.allocator);

        // Build compiled keyword param table.
        var kw_compiled = try e.allocator.alloc(bytecode.KeywordParam, f.keyword_params.items.len);
        errdefer e.allocator.free(kw_compiled);
        for (f.keyword_params.items, 0..) |kp, kp_i| {
            const default_val: Value = switch (kp.default) {
                .nil => value_mod.NIL,
                .boolean => |bv| if (bv) value_mod.TRUE else value_mod.FALSE,
                .fixnum => |n| value_mod.fixnum(@intCast(n)),
                .float => |fv| try objects.makeFloat(e.gc, fv),
                .string => |s| try objects.makeString(e.gc, s),
            };
            const owned_name = try e.internName(kp.name);
            kw_compiled[kp_i] = .{
                .name = owned_name,
                .slot = kp.slot,
                .default_value = default_val,
            };
        }

        const src_name = if (f.name) |n| e.allocator.dupe(u8, n) catch "" else "";
        return CompiledFn{
            .id = f.id,
            .arity = f.arity,
            .has_rest = f.has_rest,
            .num_regs = @intCast(ctx.peak_phys_reg),
            .code = code,
            .consts = consts,
            .names = names,
            .name_syms = name_syms,
            .name_caches = name_caches,
            .safepoint_maps = safepoints,
            .keyword_params = kw_compiled,
            .src_name = src_name,
            .allocator = e.allocator,
        };
    }

    pub fn internName(e: *Emitter, name: []const u8) ![]const u8 {
        // De-dup.
        for (e.names_pool.items) |s| {
            if (std.mem.eql(u8, s, name)) return s;
        }
        const copy = try e.allocator.dupe(u8, name);
        try e.names_pool.append(e.allocator, copy);
        return copy;
    }
};

fn computeMaxReg(f: *Function) Reg {
    var max_r: Reg = 0;
    const upd = struct {
        fn go(r: Reg, m: *Reg) void {
            if (r > m.*) m.* = r;
        }
    };
    for (f.ops.items) |op| {
        switch (op) {
            .load_const => |x| upd.go(x.dst, &max_r),
            .load_string => |x| upd.go(x.dst, &max_r),
            .load_float => |x| upd.go(x.dst, &max_r),
            .load_nil => |x| upd.go(x.dst, &max_r),
            .load_true => |x| upd.go(x.dst, &max_r),
            .load_false => |x| upd.go(x.dst, &max_r),
            .load_local => |x| upd.go(x.dst, &max_r),
            .store_local => |x| upd.go(x.src, &max_r),
            .load_global => |x| upd.go(x.dst, &max_r),
            .store_global => |x| upd.go(x.src, &max_r),
            .set_global => |x| upd.go(x.src, &max_r),
            .alloc_box => |x| {
                upd.go(x.dst, &max_r);
                upd.go(x.init, &max_r);
            },
            .load_box => |x| {
                upd.go(x.dst, &max_r);
                upd.go(x.box, &max_r);
            },
            .store_box => |x| {
                upd.go(x.box, &max_r);
                upd.go(x.src, &max_r);
            },
            .cons => |x| {
                upd.go(x.dst, &max_r);
                upd.go(x.car, &max_r);
                upd.go(x.cdr, &max_r);
            },
            .car => |x| {
                upd.go(x.dst, &max_r);
                upd.go(x.src, &max_r);
            },
            .cdr => |x| {
                upd.go(x.dst, &max_r);
                upd.go(x.src, &max_r);
            },
            .make_closure => |x| {
                upd.go(x.dst, &max_r);
                for (x.captures) |c| upd.go(c, &max_r);
            },
            .load_capture => |x| upd.go(x.dst, &max_r),
            .branch_if => |x| upd.go(x.cond, &max_r),
            .branch_if_not_null => |x| upd.go(x.src, &max_r),
            .branch_if_not_pair => |x| upd.go(x.src, &max_r),
            .branch_if_num_neq => |x| { upd.go(x.src1, &max_r); upd.go(x.src2, &max_r); },
            .branch_if_num_nlt => |x| { upd.go(x.src1, &max_r); upd.go(x.src2, &max_r); },
            .branch_if_num_ngt => |x| { upd.go(x.src1, &max_r); upd.go(x.src2, &max_r); },
            .branch_if_neqp => |x| { upd.go(x.src1, &max_r); upd.go(x.src2, &max_r); },
            .addi => |x| { upd.go(x.dst, &max_r); upd.go(x.src, &max_r); },
            .subi => |x| { upd.go(x.dst, &max_r); upd.go(x.src, &max_r); },
            .num_eq_i => |x| { upd.go(x.dst, &max_r); upd.go(x.src, &max_r); },
            .num_lt_i => |x| { upd.go(x.dst, &max_r); upd.go(x.src, &max_r); },
            .branch_if_num_neq_i => |x| upd.go(x.src, &max_r),
            .branch_if_num_nlt_i => |x| upd.go(x.src, &max_r),
            .mod2 => |x| { upd.go(x.dst, &max_r); upd.go(x.src1, &max_r); upd.go(x.src2, &max_r); },
            .call => |x| {
                upd.go(x.dst, &max_r);
                upd.go(x.func, &max_r);
                for (x.args) |a| upd.go(a, &max_r);
            },
            .tail_call => |x| {
                upd.go(x.func, &max_r);
                for (x.args) |a| upd.go(a, &max_r);
            },
            .ret => |x| upd.go(x.src, &max_r),
            .alloc_pair => |x| upd.go(x.dst, &max_r),
            .prim_call => |x| {
                upd.go(x.dst, &max_r);
                for (x.args) |a| upd.go(a, &max_r);
            },
            .do_import => |x| upd.go(x.dst, &max_r),
            // zepo-abd: 2-arg arithmetic register usage.
            .add2 => |x| { upd.go(x.dst, &max_r); upd.go(x.src1, &max_r); upd.go(x.src2, &max_r); },
            .sub2 => |x| { upd.go(x.dst, &max_r); upd.go(x.src1, &max_r); upd.go(x.src2, &max_r); },
            .mul2 => |x| { upd.go(x.dst, &max_r); upd.go(x.src1, &max_r); upd.go(x.src2, &max_r); },
            .num_eq2 => |x| { upd.go(x.dst, &max_r); upd.go(x.src1, &max_r); upd.go(x.src2, &max_r); },
            .num_lt2 => |x| { upd.go(x.dst, &max_r); upd.go(x.src1, &max_r); upd.go(x.src2, &max_r); },
            .num_gt2 => |x| { upd.go(x.dst, &max_r); upd.go(x.src1, &max_r); upd.go(x.src2, &max_r); },
            .null_p => |x| { upd.go(x.dst, &max_r); upd.go(x.src, &max_r); },
            .pair_p => |x| { upd.go(x.dst, &max_r); upd.go(x.src, &max_r); },
            .eq_p => |x| { upd.go(x.dst, &max_r); upd.go(x.src1, &max_r); upd.go(x.src2, &max_r); },
            .push_handler => |x| { upd.go(x.handler, &max_r); upd.go(x.dst, &max_r); },
            .pop_handler => {},
            .push_param => |x| { upd.go(x.param, &max_r); upd.go(x.value, &max_r); }, // zepo-6o3p
            .pop_params => {}, // zepo-6o3p
            .push_restart => |x| { upd.go(x.name, &max_r); upd.go(x.clause_fn, &max_r); upd.go(x.report, &max_r); upd.go(x.dst, &max_r); }, // zepo-g120
            .pop_restarts => {}, // zepo-g120
            .move => |x| { upd.go(x.dst, &max_r); upd.go(x.src, &max_r); },
            .branch, .label, .safepoint => {},
        }
    }
    return max_r;
}

const JumpFixup = struct {
    instr_index: u32,
    label: Label,
    /// zepo-9bi: bc means "patch as JUMP-style 16-bit BC field"; raw_u32
    /// means "overwrite the entire instruction word with the resolved pc
    /// as a u32" — used for PUSH_HANDLER's resume_pc word2.
    kind: enum { bc, raw_u32 } = .bc,
};

const FnEmit = struct {
    e: *Emitter,
    code: std.ArrayList(Instr),
    consts: std.ArrayList(Value),
    names: std.ArrayList([]const u8),
    // zepo-aer: parallel to `names`, holds pre-interned symbol Values.
    name_syms: std.ArrayList(Value),
    safepoint_maps: std.ArrayList(SafepointMap),
    label_positions: std.AutoHashMap(Label, u32),
    fixups: std.ArrayList(JumpFixup),
    next_phys_reg: Reg,
    /// Where the call-window temp region starts. Reset here after each call so
    /// sequential calls share the same register slots instead of accumulating.
    call_temp_base: Reg = 0,
    /// High-water mark across all allocations; used for num_regs.
    peak_phys_reg: Reg = 0,
    local_base: u16 = 0,
    reg_base: u16 = 0,

    fn init(e: *Emitter) FnEmit {
        return .{
            .e = e,
            .code = std.ArrayListUnmanaged(Instr).empty,
            .consts = std.ArrayListUnmanaged(Value).empty,
            .names = std.ArrayListUnmanaged([]const u8).empty,
            .name_syms = std.ArrayListUnmanaged(Value).empty,
            .safepoint_maps = std.ArrayListUnmanaged(SafepointMap).empty,
            .label_positions = std.AutoHashMap(Label, u32).init(e.allocator),
            .fixups = std.ArrayListUnmanaged(JumpFixup).empty,
            .next_phys_reg = 0,
        };
    }

    fn deinit(c: *FnEmit) void {
        c.code.deinit(c.e.allocator);
        c.consts.deinit(c.e.allocator);
        c.names.deinit(c.e.allocator);
        c.name_syms.deinit(c.e.allocator);
        c.safepoint_maps.deinit(c.e.allocator);
        c.label_positions.deinit();
        c.fixups.deinit(c.e.allocator);
    }

    fn allocPhysReg(c: *FnEmit) !u8 {
        const r = c.next_phys_reg;
        if (r >= 255) return error.TooManyRegisters;
        c.next_phys_reg += 1;
        return @intCast(r);
    }

    fn allocArgWindow(c: *FnEmit, nargs: usize) !u8 {
        // Reset to call_temp_base so sequential calls share the same window space.
        c.next_phys_reg = c.call_temp_base;
        if (nargs == 0) {
            const r = c.next_phys_reg;
            if (r + 1 > 255) return error.TooManyRegisters;
            c.next_phys_reg += 1;
            if (c.next_phys_reg > c.peak_phys_reg) c.peak_phys_reg = c.next_phys_reg;
            return @intCast(r);
        }
        const base = c.next_phys_reg;
        const need = nargs;
        if (base + need > 255) return error.TooManyRegisters;
        c.next_phys_reg += @intCast(need);
        if (c.next_phys_reg > c.peak_phys_reg) c.peak_phys_reg = c.next_phys_reg;
        return @intCast(base);
    }

    /// Cast an IR register index to a physical u8, asserting range.
    /// Map an IR virtual register to a physical byte-sized register index.
    fn phys(c: *FnEmit, r: Reg) u8 {
        const p: u32 = @as(u32, c.reg_base) + @as(u32, r);
        std.debug.assert(p < 255);
        return @intCast(p);
    }

    /// Map a local slot to a physical register index.
    fn localPhys(c: *FnEmit, slot: u16) u8 {
        const p: u32 = @as(u32, c.local_base) + @as(u32, slot);
        std.debug.assert(p < 255);
        return @intCast(p);
    }

    fn emitInstr(c: *FnEmit, i: Instr) !void {
        try c.code.append(c.e.allocator, i);
    }

    fn currentPc(c: *FnEmit) u32 {
        return @intCast(c.code.items.len);
    }

    fn addConst(c: *FnEmit, v: Value) !u16 {
        // De-dup constants by raw bit equality.
        for (c.consts.items, 0..) |existing, idx| {
            if (existing == v) return @intCast(idx);
        }
        const idx = c.consts.items.len;
        if (idx >= 0xFFFF) return error.TooManyConstants;
        try c.consts.append(c.e.allocator, v);
        return @intCast(idx);
    }

    fn addName(c: *FnEmit, name: []const u8) !u16 {
        const interned = try c.e.internName(name);
        for (c.names.items, 0..) |existing, idx| {
            if (existing.ptr == interned.ptr) return @intCast(idx);
        }
        const idx = c.names.items.len;
        if (idx >= 0xFFFF) return error.TooManyNames;
        // zepo-aer: pre-intern the symbol so dispatch can skip the hash lookup.
        const sym = try c.e.symbols.intern(name);
        try c.names.append(c.e.allocator, interned);
        try c.name_syms.append(c.e.allocator, sym);
        return @intCast(idx);
    }

    fn emitJumpFixup(c: *FnEmit, op: Opcode, a: u8, label: Label) !void {
        const pc = c.currentPc();
        try c.fixups.append(c.e.allocator, .{ .instr_index = pc, .label = label });
        // Encode a placeholder with BC = 0. We'll patch it.
        try c.emitInstr(bytecode.encodeBC(op, a, 0));
    }

    fn emitOp(c: *FnEmit, op: Op) !void {
        switch (op) {
            .load_const => |x| {
                const ci = try c.addConst(x.val);
                try c.emitInstr(bytecode.encodeBC(.LOAD_CONST, c.phys(x.dst), ci));
            },
            .load_string => |x| {
                const v = try objects.makeString(c.e.gc, x.bytes);
                const ci = try c.addConst(v);
                try c.emitInstr(bytecode.encodeBC(.LOAD_CONST, c.phys(x.dst), ci));
            },
            .load_float => |x| {
                const v = try objects.makeFloat(c.e.gc, x.f);
                const ci = try c.addConst(v);
                try c.emitInstr(bytecode.encodeBC(.LOAD_CONST, c.phys(x.dst), ci));
            },
            .load_nil => |x| try c.emitInstr(bytecode.encode(.LOAD_NIL, c.phys(x.dst), 0, 0)),
            .load_true => |x| try c.emitInstr(bytecode.encode(.LOAD_TRUE, c.phys(x.dst), 0, 0)),
            .load_false => |x| try c.emitInstr(bytecode.encode(.LOAD_FALSE, c.phys(x.dst), 0, 0)),
            .load_local => |x| try c.emitInstr(bytecode.encode(.LOAD_LOCAL, c.phys(x.dst), c.localPhys(x.slot), 0)),
            .store_local => |x| try c.emitInstr(bytecode.encode(.STORE_LOCAL, c.localPhys(x.slot), c.phys(x.src), 0)),
            .load_global => |x| {
                const ni = try c.addName(x.name);
                try c.emitInstr(bytecode.encodeBC(.LOAD_GLOBAL, c.phys(x.dst), ni));
            },
            .store_global => |x| {
                const ni = try c.addName(x.name);
                // STORE_GLOBAL A=src_reg, BC=name_idx.
                try c.emitInstr(bytecode.encodeBC(.STORE_GLOBAL, c.phys(x.src), ni));
            },
            .set_global => |x| {
                const ni = try c.addName(x.name);
                try c.emitInstr(bytecode.encodeBC(.SET_GLOBAL, c.phys(x.src), ni));
            },
            .alloc_box => |x| try c.emitInstr(bytecode.encode(.ALLOC_BOX, c.phys(x.dst), c.phys(x.init), 0)),
            .load_box => |x| try c.emitInstr(bytecode.encode(.LOAD_BOX, c.phys(x.dst), c.phys(x.box), 0)),
            .store_box => |x| try c.emitInstr(bytecode.encode(.STORE_BOX, c.phys(x.box), c.phys(x.src), 0)),
            .cons => |x| try c.emitInstr(bytecode.encode(.CONS, c.phys(x.dst), c.phys(x.car), c.phys(x.cdr))),
            .car => |x| try c.emitInstr(bytecode.encode(.CAR, c.phys(x.dst), c.phys(x.src), 0)),
            .cdr => |x| try c.emitInstr(bytecode.encode(.CDR, c.phys(x.dst), c.phys(x.src), 0)),

            // zepo-abd: 2-arg arithmetic specialized opcodes.
            .add2 => |x| try c.emitInstr(bytecode.encode(.ADD2, c.phys(x.dst), c.phys(x.src1), c.phys(x.src2))),
            .sub2 => |x| try c.emitInstr(bytecode.encode(.SUB2, c.phys(x.dst), c.phys(x.src1), c.phys(x.src2))),
            .mul2 => |x| try c.emitInstr(bytecode.encode(.MUL2, c.phys(x.dst), c.phys(x.src1), c.phys(x.src2))),
            .num_eq2 => |x| try c.emitInstr(bytecode.encode(.NUM_EQ2, c.phys(x.dst), c.phys(x.src1), c.phys(x.src2))),
            .num_lt2 => |x| try c.emitInstr(bytecode.encode(.NUM_LT2, c.phys(x.dst), c.phys(x.src1), c.phys(x.src2))),
            .num_gt2 => |x| try c.emitInstr(bytecode.encode(.NUM_GT2, c.phys(x.dst), c.phys(x.src1), c.phys(x.src2))),
            // zepo-w19: predicate opcodes.
            .null_p => |x| try c.emitInstr(bytecode.encode(.NULL_P, c.phys(x.dst), c.phys(x.src), 0)),
            .pair_p => |x| try c.emitInstr(bytecode.encode(.PAIR_P, c.phys(x.dst), c.phys(x.src), 0)),
            .eq_p => |x| try c.emitInstr(bytecode.encode(.EQ_P, c.phys(x.dst), c.phys(x.src1), c.phys(x.src2))),

            .make_closure => |x| {
                if (x.code_id > 0xFFFF) return error.FnIdTooLarge;
                try c.emitInstr(bytecode.encodeBC(.MAKE_CLOSURE, c.phys(x.dst), @intCast(x.code_id)));
                for (x.captures) |cap| {
                    try c.emitInstr(bytecode.encode(.CAPTURE, c.phys(cap), 0, 0));
                }
            },
            .load_capture => |x| try c.emitInstr(bytecode.encode(.LOAD_CAPTURE, c.phys(x.dst), @intCast(x.idx), 0)),

            .branch => |x| try c.emitJumpFixup(.JUMP, 0, x.label),
            .branch_if => |x| {
                // JUMP_IF_FALSE cond then fallthrough to then_label; so we
                // emit JUMP_IF_FALSE with else_label target, then JUMP to
                // then_label. The IR places the then_label right after.
                try c.emitJumpFixup(.JUMP_IF_FALSE, c.phys(x.cond), x.else_label);
                try c.emitJumpFixup(.JUMP, 0, x.then_label);
            },
            // zepo-28f: fused predicate-and-branch — A=src, BC=else target,
            // followed by an unconditional JUMP to then_label.
            .branch_if_not_null => |x| {
                try c.emitJumpFixup(.BR_IF_NOT_NULL, c.phys(x.src), x.else_label);
                try c.emitJumpFixup(.JUMP, 0, x.then_label);
            },
            .branch_if_not_pair => |x| {
                try c.emitJumpFixup(.BR_IF_NOT_PAIR, c.phys(x.src), x.else_label);
                try c.emitJumpFixup(.JUMP, 0, x.then_label);
            },
            // zepo-lpj: 2-arg fused. Emits the predicate opcode (with both
            // source regs in A and B) followed by a JUMP carrying the else
            // target in BC. Dispatch reads both words. The IR builder places
            // then_label immediately after.
            .branch_if_num_neq => |x| {
                try c.emitInstr(bytecode.encode(.BR_IF_NUM_NEQ, c.phys(x.src1), c.phys(x.src2), 0));
                try c.emitJumpFixup(.JUMP, 0, x.else_label);
            },
            .branch_if_num_nlt => |x| {
                try c.emitInstr(bytecode.encode(.BR_IF_NUM_NLT, c.phys(x.src1), c.phys(x.src2), 0));
                try c.emitJumpFixup(.JUMP, 0, x.else_label);
            },
            .branch_if_num_ngt => |x| {
                try c.emitInstr(bytecode.encode(.BR_IF_NUM_NGT, c.phys(x.src1), c.phys(x.src2), 0));
                try c.emitJumpFixup(.JUMP, 0, x.else_label);
            },
            .branch_if_neqp => |x| {
                try c.emitInstr(bytecode.encode(.BR_IF_NEQP, c.phys(x.src1), c.phys(x.src2), 0));
                try c.emitJumpFixup(.JUMP, 0, x.else_label);
            },
            // zepo-i3b: imm-operand arithmetic + branches. Encode i8 → u8.
            .addi => |x| try c.emitInstr(bytecode.encode(.ADDI, c.phys(x.dst), c.phys(x.src), @bitCast(x.imm))),
            .subi => |x| try c.emitInstr(bytecode.encode(.SUBI, c.phys(x.dst), c.phys(x.src), @bitCast(x.imm))),
            .num_eq_i => |x| try c.emitInstr(bytecode.encode(.NUM_EQ_I, c.phys(x.dst), c.phys(x.src), @bitCast(x.imm))),
            .num_lt_i => |x| try c.emitInstr(bytecode.encode(.NUM_LT_I, c.phys(x.dst), c.phys(x.src), @bitCast(x.imm))),
            .branch_if_num_neq_i => |x| {
                try c.emitInstr(bytecode.encode(.BR_IF_NUM_NEQ_I, c.phys(x.src), @bitCast(x.imm), 0));
                try c.emitJumpFixup(.JUMP, 0, x.else_label);
            },
            .branch_if_num_nlt_i => |x| {
                try c.emitInstr(bytecode.encode(.BR_IF_NUM_NLT_I, c.phys(x.src), @bitCast(x.imm), 0));
                try c.emitJumpFixup(.JUMP, 0, x.else_label);
            },
            .mod2 => |x| try c.emitInstr(bytecode.encode(.MOD2, c.phys(x.dst), c.phys(x.src1), c.phys(x.src2))),
            // zepo-9bi: 2-word PUSH_HANDLER. Word1 carries handler_reg and
            // dst_reg; word2 is the absolute resume pc (patched after layout).
            .push_handler => |x| {
                // zepo-g120: C operand carries the binding flag (1 = handler-bind).
                try c.emitInstr(bytecode.encode(.PUSH_HANDLER, c.phys(x.handler), c.phys(x.dst), @intFromBool(x.binding)));
                // word2 placeholder; patched to the resolved resume_pc.
                try c.fixups.append(c.e.allocator, .{
                    .instr_index = c.currentPc(),
                    .label = x.resume_label,
                    .kind = .raw_u32,
                });
                try c.emitInstr(0);
            },
            .pop_handler => try c.emitInstr(bytecode.encode(.POP_HANDLER, 0, 0, 0)),
            // zepo-6o3p: dynamic binding push/pop.
            .push_param => |x| try c.emitInstr(bytecode.encode(.PUSH_PARAM, c.phys(x.param), c.phys(x.value), 0)),
            .pop_params => |x| try c.emitInstr(bytecode.encodeBC(.POP_PARAMS, 0, x.count)),
            // zepo-g120: 3-word PUSH_RESTART (see bytecode.zig). word2 resume_pc
            // is patched after layout; word3 packs name_reg | report_reg<<8.
            .push_restart => |x| {
                try c.emitInstr(bytecode.encode(.PUSH_RESTART, c.phys(x.clause_fn), c.phys(x.dst), 0));
                try c.fixups.append(c.e.allocator, .{
                    .instr_index = c.currentPc(),
                    .label = x.resume_label,
                    .kind = .raw_u32,
                });
                try c.emitInstr(0);
                const packed_regs: u32 = @as(u32, c.phys(x.name)) | (@as(u32, c.phys(x.report)) << 8) | (@as(u32, x.clause_index) << 16);
                try c.emitInstr(packed_regs);
            },
            .pop_restarts => |x| try c.emitInstr(bytecode.encodeBC(.POP_RESTARTS, 0, x.count)),
            .move => |x| try c.emitInstr(bytecode.encode(.MOVE, c.phys(x.dst), c.phys(x.src), 0)),
            .label => |x| {
                try c.label_positions.put(x.id, c.currentPc());
            },

            .call => |x| {
                // Allocate contiguous arg window: [func_reg, arg0, arg1, ...]
                // CALL encoding: A=dst, B=base, C=nargs; args are at B+1..B+nargs.
                // So base reg B holds the function value.
                const base = try c.allocArgWindow(1 + x.args.len);
                // MOVE func -> base
                try c.emitInstr(bytecode.encode(.MOVE, base, c.phys(x.func), 0));
                // MOVE each arg -> base+1+i
                for (x.args, 0..) |a, i| {
                    const slot: u8 = base + 1 + @as(u8, @intCast(i));
                    try c.emitInstr(bytecode.encode(.MOVE, slot, c.phys(a), 0));
                }
                if (x.args.len > 255) return error.TooManyArgs;
                try c.emitInstr(bytecode.encode(.CALL, c.phys(x.dst), base, @intCast(x.args.len)));
                c.next_phys_reg = c.call_temp_base;
            },
            .tail_call => |x| {
                // TAIL_CALL encoding: A=base (=func), B=nargs; args at A+1..A+nargs.
                const base = try c.allocArgWindow(1 + x.args.len);
                try c.emitInstr(bytecode.encode(.MOVE, base, c.phys(x.func), 0));
                for (x.args, 0..) |a, i| {
                    const slot: u8 = base + 1 + @as(u8, @intCast(i));
                    try c.emitInstr(bytecode.encode(.MOVE, slot, c.phys(a), 0));
                }
                if (x.args.len > 255) return error.TooManyArgs;
                try c.emitInstr(bytecode.encode(.TAIL_CALL, base, @intCast(x.args.len), 0));
                // zepo-s64: synthetic RETURN so park-yield can resume here.
                // Dead in normal execution; reached only when a prim in tail
                // position parks and the scheduler resumes this fiber.
                try c.emitInstr(bytecode.encode(.RETURN, base, 0, 0));
                c.next_phys_reg = c.call_temp_base;
            },
            .ret => |x| try c.emitInstr(bytecode.encode(.RETURN, c.phys(x.src), 0, 0)),

            .safepoint => {
                // Emit SAFEPOINT and record a map. We use a conservative mask
                // of all currently-allocated regs — the VM doesn't strictly
                // need precise masks because registers hold Values from the
                // allocator, and any dead register just traces through a
                // stale-but-valid Value. We still record pc for future use.
                const pc = c.currentPc();
                try c.emitInstr(bytecode.encode(.SAFEPOINT, 0, 0, 0));
                const n = c.next_phys_reg;
                const mask: u64 = if (n >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(n)) - 1;
                try c.safepoint_maps.append(c.e.allocator, .{ .pc = pc, .live_reg_mask = mask });
            },
            .alloc_pair => {
                // Not used in current lowering path; emit as nop-like.
            },
            .prim_call => {
                // Not used — IR builder routes primitive applications through
                // regular .call ops and the VM dispatches on the Value kind.
            },
            .do_import => |imp| {
                // Build a spec Value in the const pool:
                //   symbol name          → (import name)
                //   pair (name . alias)  → (import name as alias)
                //   pair (name sym ...)  → (import name (only sym...)) as proper list
                const name_sym = try c.e.symbols.intern(imp.name);
                var spec: Value = name_sym;
                if (imp.alias) |al| {
                    const alias_sym = try c.e.symbols.intern(al);
                    spec = try objects.makePair(c.e.gc, name_sym, alias_sym);
                } else if (imp.only) |names| {
                    var tail = value_mod.NIL;
                    var i: usize = names.len;
                    while (i > 0) {
                        i -= 1;
                        const s = try c.e.symbols.intern(names[i]);
                        tail = try objects.makePair(c.e.gc, s, tail);
                    }
                    spec = try objects.makePair(c.e.gc, name_sym, tail);
                }
                const ci = try c.addConst(spec);
                // zepo-okom: map the IR dst through phys() like every other
                // emit — the raw IR register aliased physical register 0, so an
                // in-function (import M) overwrote the first param/local with NIL
                // (the import's discarded result), corrupting a live variable.
                try c.emitInstr(bytecode.encodeBC(.IMPORT, c.phys(imp.dst), ci));
            },
        }
    }

    /// Helper for tail-call synthesis at the outer pass: emit the MOVE + TAIL_CALL
    /// sequence for an IR `call` op that we've detected as a tail call.
    fn emitTailCall(c: *FnEmit, func_reg: Reg, arg_regs: []const Reg) !void {
        const base = try c.allocArgWindow(1 + arg_regs.len);
        try c.emitInstr(bytecode.encode(.MOVE, base, c.phys(func_reg), 0));
        for (arg_regs, 0..) |a, i| {
            const slot: u8 = base + 1 + @as(u8, @intCast(i));
            try c.emitInstr(bytecode.encode(.MOVE, slot, c.phys(a), 0));
        }
        if (arg_regs.len > 255) return error.TooManyArgs;
        try c.emitInstr(bytecode.encode(.TAIL_CALL, base, @intCast(arg_regs.len), 0));
        // zepo-s64: synthetic RETURN for park-yield resume (see tail_call emission above).
        try c.emitInstr(bytecode.encode(.RETURN, base, 0, 0));
        c.next_phys_reg = c.call_temp_base;
    }

    fn patchJumps(c: *FnEmit) !void {
        for (c.fixups.items) |fx| {
            const pos = c.label_positions.get(fx.label) orelse return error.UnresolvedLabel;
            switch (fx.kind) {
                .bc => {
                    const instr = c.code.items[fx.instr_index];
                    const op = bytecode.decodeOp(instr);
                    const a = bytecode.decodeA(instr);
                    if (pos > 0xFFFF) return error.JumpTargetTooFar;
                    c.code.items[fx.instr_index] = bytecode.encodeBC(op, a, @intCast(pos));
                },
                .raw_u32 => {
                    // zepo-9bi: PUSH_HANDLER word2 holds the resume pc as
                    // a full u32 absolute address within the current func.
                    c.code.items[fx.instr_index] = pos;
                },
            }
        }
    }
};

test "emit simple literal returns compiled fn" {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var program = Program.init(alloc);
    defer program.deinit();

    var f = Function.init(0, null, 0, false, alloc);
    const r = 0;
    try f.emit(.{ .load_const = .{ .dst = r, .val = value_mod.fixnum(42) } });
    try f.emit(.{ .ret = .{ .src = r } });
    _ = try program.addFunction(f);

    var gc = try GC.init(alloc);
    defer gc.deinit();
    var syms = try SymbolTable.init(&gc, alloc);
    defer syms.deinit();

    var e = Emitter.init(alloc, &syms, &gc);
    defer e.deinit();
    const fns = try e.emit(&program);
    defer {
        for (fns) |*cf| cf.deinit(alloc);
        alloc.free(fns);
    }

    try std.testing.expectEqual(@as(usize, 1), fns.len);
    try std.testing.expect(fns[0].code.len >= 2);
    try std.testing.expectEqual(@as(u16, 0), fns[0].arity);
}
