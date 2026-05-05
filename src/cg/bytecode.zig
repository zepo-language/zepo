//! Bytecode format.
//!
//! Instructions are 32-bit words encoded as [opcode:8][A:8][B:8][C:8].
//! B and C can also be combined as a 16-bit immediate (B is the high byte).
//!
//! A `CompiledFn` holds the lowered code plus a constant pool and a global
//! name pool, and a list of safepoint maps that describe which registers are
//! live GC roots at each safepoint PC. The VM uses those maps to walk the
//! call-stack register windows precisely during collection.

const std = @import("std");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;

pub const Opcode = enum(u8) {
    // Loads
    LOAD_CONST,
    LOAD_NIL,
    LOAD_TRUE,
    LOAD_FALSE,
    LOAD_LOCAL,
    STORE_LOCAL,
    LOAD_GLOBAL,
    STORE_GLOBAL,
    // Box cells
    ALLOC_BOX,
    LOAD_BOX,
    STORE_BOX,
    // Pairs
    CONS,
    CAR,
    CDR,
    // Closures
    MAKE_CLOSURE,
    CAPTURE,
    LOAD_CAPTURE,
    // Control
    JUMP,
    JUMP_IF_FALSE,
    // Calls
    CALL,
    TAIL_CALL,
    RETURN,
    // GC poll
    SAFEPOINT,
    // Primitive direct dispatch (unused for now; calls are routed through CALL)
    PRIM,
    // Move a register (needed when assembling TAIL_CALL arg windows).
    MOVE,
    // Runtime import: IMPORT dst const_idx  (const encodes module spec)
    IMPORT,
    // zepo-abd: specialized 2-arg arithmetic. A=dst, B=src1, C=src2.
    // Fixnum fast path inline in dispatch; non-fixnum falls back to the
    // corresponding prim (primAdd/primSub/...). Bypasses CALL machinery.
    ADD2,
    SUB2,
    MUL2,
    NUM_EQ2,
    NUM_LT2,
    NUM_GT2,
    // zepo-w19: 1-arg / 2-arg predicate opcodes. Result is TRUE/FALSE in dst.
    NULL_P, // A=dst, B=src
    PAIR_P, // A=dst, B=src
    EQ_P,   // A=dst, B=src1, C=src2
    // zepo-28f: fused compare+branch — branch to target when predicate is FALSE,
    // mirroring JUMP_IF_FALSE semantics. Encoding: A=src, BC=target.
    BR_IF_NOT_NULL, // branch to BC if src is NOT nil
    BR_IF_NOT_PAIR, // branch to BC if src is NOT pair
    // zepo-lpj: 2-arg compare+branch fusion. Emitted as a 2-word pair: the
    // BR opcode (A=src1, B=src2) followed immediately by a regular JUMP whose
    // BC field carries the else target. Dispatch reads BOTH words atomically:
    // when the predicate fails, jumps to that target; otherwise falls through
    // past the JUMP to the THEN code.
    BR_IF_NUM_NEQ, // branch to next_instr.BC if NOT (src1 == src2)
    BR_IF_NUM_NLT, // branch to next_instr.BC if NOT (src1 <  src2)
    BR_IF_NUM_NGT, // branch to next_instr.BC if NOT (src1 >  src2)
    BR_IF_NEQP,    // branch to next_instr.BC if NOT (src1 eq? src2)
    // zepo-i3b: const-operand specialized arithmetic. C is signed i8 imm.
    // (op src imm) with imm in [-128..127]. Falls back to corresponding prim.
    ADDI,      // A=dst, B=src, C=imm_i8 — dst = src + imm
    SUBI,      // A=dst, B=src, C=imm_i8 — dst = src - imm
    NUM_EQ_I,  // A=dst, B=src, C=imm_i8 — dst = (src == imm) ? TRUE : FALSE
    NUM_LT_I,  // A=dst, B=src, C=imm_i8 — dst = (src <  imm) ? TRUE : FALSE
    // zepo-i3b: 2-word fused branch with imm. Word2 is JUMP w/ else target.
    BR_IF_NUM_NEQ_I, // branch to next_instr.BC if NOT (src == imm)
    BR_IF_NUM_NLT_I, // branch to next_instr.BC if NOT (src <  imm)
    // zepo-8tx: 2-arg fixnum modulo. A=dst, B=src1, C=src2.
    MOD2,
};

pub const Instr = u32;

pub inline fn encode(op: Opcode, a: u8, b: u8, c: u8) Instr {
    const ob: u32 = @intFromEnum(op);
    return ob | (@as(u32, a) << 8) | (@as(u32, b) << 16) | (@as(u32, c) << 24);
}

pub inline fn encodeBC(op: Opcode, a: u8, bc: u16) Instr {
    return encode(op, a, @intCast(bc >> 8), @intCast(bc & 0xFF));
}

pub inline fn decodeOp(i: Instr) Opcode {
    return @enumFromInt(@as(u8, @intCast(i & 0xFF)));
}

pub inline fn decodeA(i: Instr) u8 {
    return @intCast((i >> 8) & 0xFF);
}

pub inline fn decodeB(i: Instr) u8 {
    return @intCast((i >> 16) & 0xFF);
}

pub inline fn decodeC(i: Instr) u8 {
    return @intCast((i >> 24) & 0xFF);
}

pub inline fn decodeBC(i: Instr) u16 {
    return (@as(u16, decodeB(i)) << 8) | @as(u16, decodeC(i));
}

pub const SafepointMap = struct {
    pc: u32,
    live_reg_mask: u64,
};

pub const KeywordParam = struct {
    /// Bare keyword name, e.g. "tol". Owned by emitter name store; do not free.
    name: []const u8,
    slot: u16,
    /// GC-traced. Immediate for nil/bool/fixnum, heap allocation for float.
    default_value: Value,
};

pub const CompiledFn = struct {
    id: u32,
    arity: u16,
    has_rest: bool,
    num_regs: u16,
    code: []Instr,
    consts: []Value,
    names: [][]const u8,
    // zepo-aer: pre-interned symbol Values parallel to `names`, so LOAD_GLOBAL
    // can avoid a hash lookup per instruction. Symbols live in old-gen which
    // never moves — these Values stay valid for the lifetime of the CompiledFn.
    name_syms: []Value,
    // zepo-5qc: inline cache of resolved val_slot pointers parallel to `names`.
    // Initialised to null; populated lazily by LOAD_GLOBAL on first lookup.
    // val_slot pointers are heap-stable (GlobalEnv allocates and never moves
    // them), so once cached the slow path is skipped permanently.
    name_caches: []?*Value,
    safepoint_maps: []SafepointMap,
    keyword_params: []KeywordParam = &.{},
    src_name: []const u8 = "",  // function name for stack traces
    allocator: std.mem.Allocator,

    pub fn deinit(f: *CompiledFn, allocator: std.mem.Allocator) void {
        allocator.free(f.code);
        allocator.free(f.consts);
        if (f.src_name.len > 0) allocator.free(f.src_name);
        // `names` slices are owned by the emitter's global_names store; do
        // not free the underlying bytes here. We only own the outer slice.
        allocator.free(f.names);
        allocator.free(f.name_syms);
        allocator.free(f.name_caches);
        allocator.free(f.safepoint_maps);
        // Keyword param `name` slices owned by emitter; only free outer slice.
        if (f.keyword_params.len > 0) allocator.free(f.keyword_params);
    }
};

test "encode/decode round-trip" {
    const i = encode(.CALL, 3, 5, 7);
    try std.testing.expectEqual(Opcode.CALL, decodeOp(i));
    try std.testing.expectEqual(@as(u8, 3), decodeA(i));
    try std.testing.expectEqual(@as(u8, 5), decodeB(i));
    try std.testing.expectEqual(@as(u8, 7), decodeC(i));
}

test "encodeBC packs into B<<8|C" {
    const i = encodeBC(.LOAD_CONST, 1, 0x1234);
    try std.testing.expectEqual(@as(u16, 0x1234), decodeBC(i));
    try std.testing.expectEqual(@as(u8, 1), decodeA(i));
}
