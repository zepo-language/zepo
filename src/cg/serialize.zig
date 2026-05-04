//! Zepo bytecode serialization (.zbc format).
//!
//! Format:
//!   magic:          [4]u8  = "ZPBC"
//!   version:        u16    = 1
//!   num_fns:        u32
//!   for each fn:
//!     id:           u32
//!     arity:        u16
//!     has_rest:     u8
//!     num_regs:     u16
//!     num_instrs:   u32    (each Instr = u32)
//!     code:         [num_instrs]u32
//!     num_consts:   u32
//!     for each const:
//!       tag:        u8     (see ConstTag)
//!       payload:    ...
//!     num_names:    u32
//!     for each name: u32 len + bytes
//!     num_safepoints: u32
//!     for each safepoint: pc:u32 live_reg_mask:u64
//!     num_kw_params:  u16
//!     for each kw_param: name len+bytes, slot:u16, default_value (tag+payload)
//!     src_name:     u32 len + bytes
//!   num_toplevel:   u32
//!   toplevel_ids:   [num_toplevel]u32
//!   module_name:    u32 len + bytes  (0 = no module declaration)
//!   num_exports:    u32
//!   exports:        [num_exports] u32 len + bytes

const std = @import("std");
const bytecode = @import("bytecode.zig");
const CompiledFn = bytecode.CompiledFn;
const SafepointMap = bytecode.SafepointMap;
const KeywordParam = bytecode.KeywordParam;
const Instr = bytecode.Instr;

const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const objects = @import("../runtime/objects.zig");
const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;
const runtime = @import("../runtime/mod.zig");
const SymbolTable = runtime.SymbolTable;

pub const MAGIC = "ZPBC";
pub const VERSION: u16 = 1;

const ConstTag = enum(u8) {
    nil = 0,
    false_ = 1,
    true_ = 2,
    fixnum = 3,
    float = 4,
    string = 5,
    symbol = 6,
    char = 7,
};

// ── Write ─────────────────────────────────────────────────────────────────────

pub fn write(
    writer: anytype,
    fns: []const CompiledFn,
    toplevel_ids: []const u32,
    module_name: []const u8,
    exports: []const []const u8,
) !void {
    try writer.writeAll(MAGIC);
    try writer.writeInt(u16, VERSION, .little);
    try writer.writeInt(u32, @intCast(fns.len), .little);
    for (fns) |*f| try writeFn(writer, f);
    try writer.writeInt(u32, @intCast(toplevel_ids.len), .little);
    for (toplevel_ids) |id| try writer.writeInt(u32, id, .little);
    try writeBytes(writer, module_name);
    try writer.writeInt(u32, @intCast(exports.len), .little);
    for (exports) |ex| try writeBytes(writer, ex);
}

fn writeFn(writer: anytype, f: *const CompiledFn) !void {
    try writer.writeInt(u32, f.id, .little);
    try writer.writeInt(u16, f.arity, .little);
    try writer.writeInt(u8, if (f.has_rest) 1 else 0, .little);
    try writer.writeInt(u16, f.num_regs, .little);

    try writer.writeInt(u32, @intCast(f.code.len), .little);
    for (f.code) |instr| try writer.writeInt(u32, instr, .little);

    try writer.writeInt(u32, @intCast(f.consts.len), .little);
    for (f.consts) |v| try writeValue(writer, v);

    try writer.writeInt(u32, @intCast(f.names.len), .little);
    for (f.names) |name| try writeBytes(writer, name);

    try writer.writeInt(u32, @intCast(f.safepoint_maps.len), .little);
    for (f.safepoint_maps) |sp| {
        try writer.writeInt(u32, sp.pc, .little);
        try writer.writeInt(u64, sp.live_reg_mask, .little);
    }

    try writer.writeInt(u16, @intCast(f.keyword_params.len), .little);
    for (f.keyword_params) |kp| {
        try writeBytes(writer, kp.name);
        try writer.writeInt(u16, kp.slot, .little);
        try writeValue(writer, kp.default_value);
    }

    try writeBytes(writer, f.src_name);
}

fn writeBytes(writer: anytype, b: []const u8) !void {
    try writer.writeInt(u32, @intCast(b.len), .little);
    try writer.writeAll(b);
}

fn writeValue(writer: anytype, v: Value) !void {
    if (value_mod.isNil(v)) {
        try writer.writeInt(u8, @intFromEnum(ConstTag.nil), .little);
    } else if (v == value_mod.FALSE) {
        try writer.writeInt(u8, @intFromEnum(ConstTag.false_), .little);
    } else if (v == value_mod.TRUE) {
        try writer.writeInt(u8, @intFromEnum(ConstTag.true_), .little);
    } else if (value_mod.isFixnum(v)) {
        try writer.writeInt(u8, @intFromEnum(ConstTag.fixnum), .little);
        try writer.writeInt(i64, value_mod.fixnumVal(v), .little);
    } else if (value_mod.isChar(v)) {
        try writer.writeInt(u8, @intFromEnum(ConstTag.char), .little);
        try writer.writeInt(u32, value_mod.charVal(v), .little);
    } else if (objects.isFloat(v)) {
        try writer.writeInt(u8, @intFromEnum(ConstTag.float), .little);
        try writer.writeInt(u64, @bitCast(objects.floatVal(v)), .little);
    } else if (objects.isString(v)) {
        try writer.writeInt(u8, @intFromEnum(ConstTag.string), .little);
        try writeBytes(writer, objects.stringBytes(v));
    } else if (objects.isSymbol(v)) {
        try writer.writeInt(u8, @intFromEnum(ConstTag.symbol), .little);
        try writeBytes(writer, objects.symbolName(v));
    } else {
        // Unsupported const type — write nil as fallback. Should not happen.
        try writer.writeInt(u8, @intFromEnum(ConstTag.nil), .little);
    }
}

// ── Read ──────────────────────────────────────────────────────────────────────

pub const LoadResult = struct {
    /// Slice of newly deserialized CompiledFns. Caller owns; free each with deinit.
    fns: []CompiledFn,
    /// fn_ids of top-level thunks, already adjusted by base_offset.
    toplevel_ids: []u32,
    /// Module name, or empty if this file has no (module ...) declaration.
    module_name: []u8,
    /// Exported symbol names.
    exports: [][]u8,
    allocator: std.mem.Allocator,

    pub fn deinit(r: *LoadResult) void {
        for (r.fns) |*f| f.deinit(r.allocator);
        r.allocator.free(r.fns);
        r.allocator.free(r.toplevel_ids);
        r.allocator.free(r.module_name);
        for (r.exports) |ex| r.allocator.free(ex);
        r.allocator.free(r.exports);
    }
};

/// Deserialize a .zbc file.
/// `base_offset` is the number of CompiledFns already in the EvalContext so
/// fn_ids in MAKE_CLOSURE instructions are patched to be globally unique.
/// `name_store` is an append-only buffer owned by the caller; deserialized
/// name strings are appended to it so CompiledFn.names slices stay valid.
pub fn read(
    reader: anytype,
    alloc: std.mem.Allocator,
    gc_ptr: *GC,
    syms: *SymbolTable,
    base_offset: u32,
    name_store: *std.ArrayListUnmanaged(u8),
) !LoadResult {
    var magic: [4]u8 = undefined;
    try reader.readNoEof(&magic);
    if (!std.mem.eql(u8, &magic, MAGIC)) return error.InvalidZbc;

    const ver = try reader.readInt(u16, .little);
    if (ver != VERSION) return error.ZbcVersionMismatch;

    const num_fns = try reader.readInt(u32, .little);
    const fns = try alloc.alloc(CompiledFn, num_fns);
    errdefer {
        for (fns) |*f| f.deinit(alloc);
        alloc.free(fns);
    }
    for (fns, 0..) |*f, i| {
        f.* = try readFn(reader, alloc, gc_ptr, syms, base_offset, name_store);
        // Assign globally-unique id.
        f.id = @intCast(base_offset + i);
        // Patch MAKE_CLOSURE bc operands so they reference correct global fn_ids.
        try patchMakeClosure(f.code, base_offset, num_fns);
    }

    const num_toplevel = try reader.readInt(u32, .little);
    const toplevel_ids = try alloc.alloc(u32, num_toplevel);
    errdefer alloc.free(toplevel_ids);
    for (toplevel_ids) |*id| {
        const raw = try reader.readInt(u32, .little);
        const adjusted = base_offset + raw;
        if (adjusted > 0xFFFF) return error.TooManyFunctions;
        id.* = adjusted;
    }

    const module_name = try readBytesOwned(reader, alloc);
    errdefer alloc.free(module_name);

    const num_exports = try reader.readInt(u32, .little);
    const exports = try alloc.alloc([]u8, num_exports);
    errdefer { for (exports[0..]) |ex| alloc.free(ex); alloc.free(exports); }
    for (exports) |*ex| ex.* = try readBytesOwned(reader, alloc);

    return .{
        .fns = fns,
        .toplevel_ids = toplevel_ids,
        .module_name = module_name,
        .exports = exports,
        .allocator = alloc,
    };
}

fn readFn(
    reader: anytype,
    alloc: std.mem.Allocator,
    gc_ptr: *GC,
    syms: *SymbolTable,
    base_offset: u32,
    name_store: *std.ArrayListUnmanaged(u8),
) !CompiledFn {
    _ = base_offset;
    const id = try reader.readInt(u32, .little);
    const arity = try reader.readInt(u16, .little);
    const has_rest: bool = (try reader.readInt(u8, .little)) != 0;
    const num_regs = try reader.readInt(u16, .little);

    const num_instrs = try reader.readInt(u32, .little);
    const code = try alloc.alloc(Instr, num_instrs);
    errdefer alloc.free(code);
    for (code) |*ins| ins.* = try reader.readInt(u32, .little);

    const num_consts = try reader.readInt(u32, .little);
    const consts = try alloc.alloc(Value, num_consts);
    errdefer alloc.free(consts);
    for (consts) |*v| v.* = try readValue(reader, alloc, gc_ptr, syms);

    const num_names = try reader.readInt(u32, .little);
    const names = try alloc.alloc([]const u8, num_names);
    errdefer alloc.free(names);
    for (names) |*n| {
        const bytes = try readBytesOwned(reader, alloc);
        defer alloc.free(bytes);
        const start = name_store.items.len;
        try name_store.appendSlice(alloc, bytes);
        n.* = name_store.items[start..];
    }

    const num_safepoints = try reader.readInt(u32, .little);
    const safepoints = try alloc.alloc(SafepointMap, num_safepoints);
    errdefer alloc.free(safepoints);
    for (safepoints) |*sp| {
        sp.pc = try reader.readInt(u32, .little);
        sp.live_reg_mask = try reader.readInt(u64, .little);
    }

    const num_kw = try reader.readInt(u16, .little);
    const kw_params = try alloc.alloc(KeywordParam, num_kw);
    errdefer alloc.free(kw_params);
    for (kw_params) |*kp| {
        const name_bytes = try readBytesOwned(reader, alloc);
        defer alloc.free(name_bytes);
        const start = name_store.items.len;
        try name_store.appendSlice(alloc, name_bytes);
        kp.name = name_store.items[start..];
        kp.slot = try reader.readInt(u16, .little);
        kp.default_value = try readValue(reader, alloc, gc_ptr, syms);
    }

    const src_name_bytes = try readBytesOwned(reader, alloc);
    const src_name: []const u8 = if (src_name_bytes.len > 0) src_name_bytes else blk: {
        alloc.free(src_name_bytes);
        break :blk "";
    };

    // zepo-aer: pre-intern symbols parallel to names for fast LOAD_GLOBAL.
    const name_syms = try alloc.alloc(Value, names.len);
    errdefer alloc.free(name_syms);
    for (names, 0..) |n, i| name_syms[i] = try syms.intern(n);
    // zepo-5qc: parallel inline-cache slots, populated lazily by LOAD_GLOBAL.
    const name_caches = try alloc.alloc(?*Value, names.len);
    errdefer alloc.free(name_caches);
    @memset(name_caches, null);

    return CompiledFn{
        .id = id,
        .arity = arity,
        .has_rest = has_rest,
        .num_regs = num_regs,
        .code = code,
        .consts = consts,
        .names = names,
        .name_syms = name_syms,
        .name_caches = name_caches,
        .safepoint_maps = safepoints,
        .keyword_params = kw_params,
        .src_name = src_name,
        .allocator = alloc,
    };
}

fn readBytesOwned(reader: anytype, alloc: std.mem.Allocator) ![]u8 {
    const len = try reader.readInt(u32, .little);
    if (len == 0) return alloc.alloc(u8, 0);
    const buf = try alloc.alloc(u8, len);
    try reader.readNoEof(buf);
    return buf;
}

fn readValue(
    reader: anytype,
    alloc: std.mem.Allocator,
    gc_ptr: *GC,
    syms: *SymbolTable,
) !Value {
    const raw_tag = try reader.readInt(u8, .little);
    const ct: ConstTag = @enumFromInt(raw_tag);
    return switch (ct) {
        .nil => value_mod.NIL,
        .false_ => value_mod.FALSE,
        .true_ => value_mod.TRUE,
        .fixnum => blk: {
            const n = try reader.readInt(i64, .little);
            break :blk value_mod.fixnum(@intCast(n));
        },
        .char => blk: {
            const cp = try reader.readInt(u32, .little);
            break :blk value_mod.char(@intCast(cp));
        },
        .float => blk: {
            const bits = try reader.readInt(u64, .little);
            const f: f64 = @bitCast(bits);
            break :blk try objects.makeFloat(gc_ptr, f);
        },
        .string => blk: {
            const bytes = try readBytesOwned(reader, alloc);
            defer alloc.free(bytes);
            break :blk try objects.makeString(gc_ptr, bytes);
        },
        .symbol => blk: {
            const bytes = try readBytesOwned(reader, alloc);
            defer alloc.free(bytes);
            break :blk try syms.intern(bytes);
        },
    };
}

/// Patch MAKE_CLOSURE bc operands: any fn_id < num_fns_in_lib gets base_offset added.
fn patchMakeClosure(code: []Instr, base_offset: u32, num_fns_in_lib: u32) !void {
    const BC_MAKE_CLOSURE = @intFromEnum(bytecode.Opcode.MAKE_CLOSURE);
    for (code) |*ins| {
        const op = bytecode.decodeOp(ins.*);
        if (@intFromEnum(op) == BC_MAKE_CLOSURE) {
            const a = bytecode.decodeA(ins.*);
            const bc_val = bytecode.decodeBC(ins.*);
            if (bc_val < num_fns_in_lib) {
                const patched = base_offset + bc_val;
                if (patched > 0xFFFF) return error.TooManyFunctions;
                ins.* = bytecode.encodeBC(.MAKE_CLOSURE, a, @intCast(patched));
            }
        }
    }
}
