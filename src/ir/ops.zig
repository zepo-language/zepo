//! IR opcodes, Function, Program.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const SafepointId = abi.safepoint.SafepointId;

pub const Reg = u16;
pub const Label = u32;

pub const RootMapEntry = struct {
    sp_id: SafepointId,
    live_regs: []const Reg,
};

pub const MakeClosureOp = struct {
    dst: Reg,
    code_id: u32,
    arity: u16,
    has_rest: bool,
    captures: []const Reg,
};

pub const CallOp = struct {
    dst: Reg,
    func: Reg,
    args: []const Reg,
    safepoint: SafepointId,
};

pub const TailCallOp = struct {
    func: Reg,
    args: []const Reg,
};

pub const PrimCallOp = struct {
    dst: Reg,
    prim_name: []const u8,
    args: []const Reg,
    safepoint: SafepointId,
};

pub const KwDefault = union(enum) {
    nil: void,
    boolean: bool,
    fixnum: i64,
    float: f64,
    string: []const u8,
};

pub const KwParamIR = struct {
    name: []const u8,
    slot: u16,
    default: KwDefault,
};

pub const Op = union(enum) {
    load_const: struct { dst: Reg, val: Value },
    /// String literal: raw bytes stored in IR arena; GC string allocated fresh each emit.
    load_string: struct { dst: Reg, bytes: []const u8 },
    /// Float literal: raw f64 stored in IR; GC float allocated fresh each emit.
    load_float: struct { dst: Reg, f: f64 },
    load_nil: struct { dst: Reg },
    load_true: struct { dst: Reg },
    load_false: struct { dst: Reg },

    load_local: struct { dst: Reg, slot: u16 },
    store_local: struct { slot: u16, src: Reg },

    load_global: struct { dst: Reg, name: []const u8 },
    store_global: struct { name: []const u8, src: Reg },

    alloc_box: struct { dst: Reg, init: Reg },
    load_box: struct { dst: Reg, box: Reg },
    store_box: struct { box: Reg, src: Reg },

    cons: struct { dst: Reg, car: Reg, cdr: Reg },
    car: struct { dst: Reg, src: Reg },
    cdr: struct { dst: Reg, src: Reg },

    make_closure: MakeClosureOp,
    load_capture: struct { dst: Reg, idx: u16 },

    branch: struct { label: Label },
    branch_if: struct { cond: Reg, then_label: Label, else_label: Label },
    label: struct { id: Label },

    call: CallOp,
    tail_call: TailCallOp,
    ret: struct { src: Reg },

    safepoint: struct { id: SafepointId },
    alloc_pair: struct { dst: Reg, safepoint: SafepointId },

    prim_call: PrimCallOp,
    do_import: struct { dst: Reg, name: []const u8, alias: ?[]const u8, only: ?[]const []const u8 },

    // zepo-abd: specialized 2-arg arithmetic. Compiled to dedicated bytecode
    // opcodes (ADD2/SUB2/...) that bypass CALL machinery — fixnum fast path
    // inline in dispatch; non-fixnum falls back to the corresponding prim.
    add2: struct { dst: Reg, src1: Reg, src2: Reg },
    sub2: struct { dst: Reg, src1: Reg, src2: Reg },
    mul2: struct { dst: Reg, src1: Reg, src2: Reg },
    num_eq2: struct { dst: Reg, src1: Reg, src2: Reg },
    num_lt2: struct { dst: Reg, src1: Reg, src2: Reg },
    num_gt2: struct { dst: Reg, src1: Reg, src2: Reg },
    // zepo-w19: predicate ops.
    null_p: struct { dst: Reg, src: Reg },
    pair_p: struct { dst: Reg, src: Reg },
    eq_p: struct { dst: Reg, src1: Reg, src2: Reg },
    // zepo-28f: fused branches. Branch to else_label when predicate is FALSE.
    branch_if_not_null: struct { src: Reg, then_label: Label, else_label: Label },
    branch_if_not_pair: struct { src: Reg, then_label: Label, else_label: Label },
    // zepo-lpj: 2-arg fused compare+branch. Branches to else_label when the
    // predicate is FALSE.
    branch_if_num_neq: struct { src1: Reg, src2: Reg, then_label: Label, else_label: Label },
    branch_if_num_nlt: struct { src1: Reg, src2: Reg, then_label: Label, else_label: Label },
    branch_if_num_ngt: struct { src1: Reg, src2: Reg, then_label: Label, else_label: Label },
    branch_if_neqp: struct { src1: Reg, src2: Reg, then_label: Label, else_label: Label },
    // zepo-i3b: const-operand variants. imm fits in signed i8.
    addi: struct { dst: Reg, src: Reg, imm: i8 },
    subi: struct { dst: Reg, src: Reg, imm: i8 },
    num_eq_i: struct { dst: Reg, src: Reg, imm: i8 },
    num_lt_i: struct { dst: Reg, src: Reg, imm: i8 },
    branch_if_num_neq_i: struct { src: Reg, imm: i8, then_label: Label, else_label: Label },
    branch_if_num_nlt_i: struct { src: Reg, imm: i8, then_label: Label, else_label: Label },
};

pub const Function = struct {
    id: u32,
    name: ?[]const u8,
    arity: u16,
    has_rest: bool,
    num_locals: u16,
    ops: std.ArrayList(Op),
    root_maps: std.ArrayList(RootMapEntry),
    /// Free-var capture slots for this lambda (by source name). Used by
    /// IR builders/VMs that need to correlate capture_idx to source names.
    capture_names: std.ArrayList([]const u8),
    keyword_params: std.ArrayList(KwParamIR),
    allocator: std.mem.Allocator,
    next_label: Label,
    /// Backing storage for small owned slices embedded in ops/root maps.
    reg_lists: std.ArrayList([]Reg),

    pub fn init(id: u32, name: ?[]const u8, arity: u16, has_rest: bool, allocator: std.mem.Allocator) Function {
        return .{
            .id = id,
            .name = name,
            .arity = arity,
            .has_rest = has_rest,
            .num_locals = 0,
            .ops = std.ArrayList(Op){},
            .root_maps = std.ArrayList(RootMapEntry){},
            .capture_names = std.ArrayList([]const u8){},
            .keyword_params = std.ArrayList(KwParamIR){},
            .allocator = allocator,
            .next_label = 0,
            .reg_lists = std.ArrayList([]Reg){},
        };
    }

    pub fn deinit(f: *Function) void {
        for (f.reg_lists.items) |l| f.allocator.free(l);
        f.reg_lists.deinit(f.allocator);
        f.ops.deinit(f.allocator);
        f.root_maps.deinit(f.allocator);
        f.capture_names.deinit(f.allocator);
        f.keyword_params.deinit(f.allocator);
    }

    pub fn emit(f: *Function, op: Op) !void {
        try f.ops.append(f.allocator, op);
    }

    pub fn newLabel(f: *Function) Label {
        const id = f.next_label;
        f.next_label += 1;
        return id;
    }

    pub fn placeLabel(f: *Function, lbl: Label) !void {
        try f.ops.append(f.allocator, .{ .label = .{ .id = lbl } });
    }

    pub fn recordRootMap(f: *Function, sp_id: SafepointId, live_regs: []const Reg) !void {
        const copy = try f.allocator.dupe(Reg, live_regs);
        errdefer f.allocator.free(copy);
        try f.reg_lists.append(f.allocator, copy);
        try f.root_maps.append(f.allocator, .{ .sp_id = sp_id, .live_regs = copy });
    }

    pub fn dupRegs(f: *Function, regs: []const Reg) ![]Reg {
        const copy = try f.allocator.dupe(Reg, regs);
        try f.reg_lists.append(f.allocator, copy);
        return copy;
    }
};

pub const Program = struct {
    functions: std.ArrayList(Function),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Program {
        return .{
            .functions = std.ArrayList(Function){},
            .allocator = allocator,
        };
    }

    pub fn deinit(p: *Program) void {
        for (p.functions.items) |*f| f.deinit();
        p.functions.deinit(p.allocator);
    }

    pub fn addFunction(p: *Program, f: Function) !u32 {
        const id: u32 = @intCast(p.functions.items.len);
        try p.functions.append(p.allocator, f);
        return id;
    }

    pub fn nextFunctionId(p: *Program) u32 {
        return @intCast(p.functions.items.len);
    }
};
