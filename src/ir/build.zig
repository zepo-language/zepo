//! Lower AST into IR.

const std = @import("std");
const ast = @import("../ast/mod.zig");
const Node = ast.Node;
const NodeId = ast.NodeId;
const NodeArena = ast.NodeArena;
const LiteralKind = ast.LiteralKind;

const abi = @import("../abi/mod.zig");
const Value = abi.Value;
const value_mod = abi.value;
const SafepointId = abi.safepoint.SafepointId;

const runtime = @import("../runtime/mod.zig");
const SymbolTable = runtime.SymbolTable;
const objects = runtime.objects;

const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;

const ops = @import("ops.zig");
const Op = ops.Op;
const Reg = ops.Reg;
const Label = ops.Label;
const Function = ops.Function;
const Program = ops.Program;

const ast_node = @import("../ast/node.zig");
const LetBinding = ast_node.LetBinding;

const sema = @import("../sema/mod.zig");

const LocalKind = enum { plain, boxed };

const LocalInfo = struct {
    slot: u16,
    kind: LocalKind,
};

const CaptureInfo = struct {
    idx: u16,
    kind: LocalKind,
};

const FnCtx = struct {
    func: Function,
    locals: std.StringHashMap(LocalInfo),
    captures: std.StringHashMap(CaptureInfo),
    next_reg: Reg,
    next_slot: u16,
    allocator: std.mem.Allocator,
    /// Parent context for walking up to resolve free vars (pure lexical lookup
    /// — captures are already pre-baked into `captures` for each lambda).
    parent: ?*FnCtx,

    fn init(id: u32, name: ?[]const u8, arity: u16, has_rest: bool, allocator: std.mem.Allocator, parent: ?*FnCtx) FnCtx {
        return .{
            .func = Function.init(id, name, arity, has_rest, allocator),
            .locals = std.StringHashMap(LocalInfo).init(allocator),
            .captures = std.StringHashMap(CaptureInfo).init(allocator),
            .next_reg = 0,
            .next_slot = 0,
            .allocator = allocator,
            .parent = parent,
        };
    }

    fn deinit(c: *FnCtx) void {
        c.locals.deinit();
        c.captures.deinit();
    }

    fn freshReg(c: *FnCtx) Reg {
        const r = c.next_reg;
        c.next_reg += 1;
        return r;
    }

    fn allocSlot(c: *FnCtx) u16 {
        const s = c.next_slot;
        c.next_slot += 1;
        c.func.num_locals = c.next_slot;
        return s;
    }
};

pub const Compiler = struct {
    arena: *NodeArena,
    program: *Program,
    symbols: *SymbolTable,
    allocator: std.mem.Allocator,
    next_sp: SafepointId,
    /// Optional GC. Required to lower float/string literals into heap Values.
    /// If null, such literals are emitted as NIL placeholders (test-only path).
    gc: ?*GC = null,

    pub fn init(arena: *NodeArena, program: *Program, symbols: *SymbolTable, allocator: std.mem.Allocator) Compiler {
        return .{
            .arena = arena,
            .program = program,
            .symbols = symbols,
            .allocator = allocator,
            .next_sp = 1,
            .gc = null,
        };
    }

    pub fn initWithGc(arena: *NodeArena, program: *Program, symbols: *SymbolTable, gc: *GC, allocator: std.mem.Allocator) Compiler {
        return .{
            .arena = arena,
            .program = program,
            .symbols = symbols,
            .allocator = allocator,
            .next_sp = 1,
            .gc = gc,
        };
    }

    fn freshSp(c: *Compiler) SafepointId {
        const id = c.next_sp;
        c.next_sp += 1;
        return id;
    }

    /// Compile a single top-level expression into a new function. The function
    /// has arity 0 and returns the expression's value.
    pub fn compileExpr(c: *Compiler, node_id: NodeId) !u32 {
        const fn_id = c.program.nextFunctionId();
        // Reserve our slot up front by pushing an empty placeholder. Any
        // nested lambdas lowered during body compilation will therefore be
        // appended *after* our slot.
        _ = try c.program.addFunction(Function.init(fn_id, null, 0, false, c.allocator));
        var ctx = FnCtx.init(fn_id, null, 0, false, c.allocator, null);

        const r = try c.lowerNode(&ctx, node_id);
        try ctx.func.emit(.{ .ret = .{ .src = r } });

        // Swap finalized func into reserved slot, freeing the placeholder.
        var placeholder = c.program.functions.items[fn_id];
        placeholder.deinit();
        c.program.functions.items[fn_id] = ctx.func;
        ctx.func = undefined;
        ctx.deinit();

        return fn_id;
    }

    fn lowerNode(c: *Compiler, ctx: *FnCtx, id: NodeId) anyerror!Reg {
        return c.lowerNodeTail(ctx, id, false);
    }

    fn lowerNodeTail(c: *Compiler, ctx: *FnCtx, id: NodeId, tail: bool) anyerror!Reg {
        const node = c.arena.get(id).*;
        return switch (node) {
            .literal => |lit| c.lowerLiteral(ctx, lit.val),
            .sym_ref => |sr| c.lowerSymRef(ctx, sr.name),
            .quote => |q| c.lowerQuote(ctx, q.datum),
            .define => |d| c.lowerDefine(ctx, d.name, d.value),
            .set_bang => |s| c.lowerSetBang(ctx, s.name, s.value),
            .if_expr => |i| c.lowerIfTail(ctx, i.cond, i.then_, i.else_, tail),
            .cond_expr => |co| c.lowerCondTail(ctx, co.clauses, tail),
            .application => |app| c.lowerApplicationTail(ctx, app.func, app.args, tail),
            .sequence => |seq| c.lowerSequenceTail(ctx, seq.exprs, tail),
            .lambda => c.lowerLambda(ctx, id),
            .let_expr => c.lowerLet(ctx, id, tail),
            .let_star_expr => c.lowerLetStar(ctx, id, tail),
            .module_decl => unreachable,
            .import_stmt => |imp| blk: {
                const r = ctx.freshReg();
                const alias: ?[]const u8 = switch (imp.selection) {
                    .as_alias => |a| a,
                    else => null,
                };
                const only: ?[]const []const u8 = switch (imp.selection) {
                    .only => |names| names,
                    else => null,
                };
                try ctx.func.emit(.{ .do_import = .{ .dst = r, .name = imp.name, .alias = alias, .only = only } });
                break :blk r;
            },
        };
    }

    fn lowerLiteral(_: *Compiler, ctx: *FnCtx, lit: LiteralKind) anyerror!Reg {
        const r = ctx.freshReg();
        switch (lit) {
            .nil => try ctx.func.emit(.{ .load_nil = .{ .dst = r } }),
            .boolean => |b| try ctx.func.emit(if (b) Op{ .load_true = .{ .dst = r } } else Op{ .load_false = .{ .dst = r } }),
            .fixnum => |n| try ctx.func.emit(.{ .load_const = .{ .dst = r, .val = value_mod.fixnum(n) } }),
            .character => |cp| try ctx.func.emit(.{ .load_const = .{ .dst = r, .val = value_mod.char(cp) } }),
            .float => |f| try ctx.func.emit(.{ .load_float = .{ .dst = r, .f = f } }),
            .string => |s| try ctx.func.emit(.{ .load_string = .{ .dst = r, .bytes = s } }),
        }
        return r;
    }

    fn lowerSymRef(c: *Compiler, ctx: *FnCtx, name: []const u8) anyerror!Reg {
        _ = c;
        const r = ctx.freshReg();
        if (ctx.locals.get(name)) |info| {
            if (info.kind == .boxed) {
                const box_r = ctx.freshReg();
                try ctx.func.emit(.{ .load_local = .{ .dst = box_r, .slot = info.slot } });
                try ctx.func.emit(.{ .load_box = .{ .dst = r, .box = box_r } });
            } else {
                try ctx.func.emit(.{ .load_local = .{ .dst = r, .slot = info.slot } });
            }
            return r;
        }
        if (ctx.captures.get(name)) |cap| {
            if (cap.kind == .boxed) {
                const box_r = ctx.freshReg();
                try ctx.func.emit(.{ .load_capture = .{ .dst = box_r, .idx = cap.idx } });
                try ctx.func.emit(.{ .load_box = .{ .dst = r, .box = box_r } });
            } else {
                try ctx.func.emit(.{ .load_capture = .{ .dst = r, .idx = cap.idx } });
            }
            return r;
        }
        // Fallback: global.
        try ctx.func.emit(.{ .load_global = .{ .dst = r, .name = name } });
        return r;
    }

    fn lowerQuote(c: *Compiler, ctx: *FnCtx, datum: Value) anyerror!Reg {
        _ = c;
        const r = ctx.freshReg();
        try ctx.func.emit(.{ .load_const = .{ .dst = r, .val = datum } });
        return r;
    }

    fn lowerDefine(c: *Compiler, ctx: *FnCtx, name: []const u8, value_id: NodeId) anyerror!Reg {
        const v = switch (c.arena.get(value_id).*) {
            .lambda => try c.lowerLambdaNamed(ctx, value_id, name),
            else => try c.lowerNode(ctx, value_id),
        };
        try ctx.func.emit(.{ .store_global = .{ .name = name, .src = v } });
        return v;
    }

    fn lowerSetBang(c: *Compiler, ctx: *FnCtx, name: []const u8, value_id: NodeId) anyerror!Reg {
        const v = try c.lowerNode(ctx, value_id);
        if (ctx.locals.get(name)) |info| {
            if (info.kind == .boxed) {
                const box_r = ctx.freshReg();
                try ctx.func.emit(.{ .load_local = .{ .dst = box_r, .slot = info.slot } });
                try ctx.func.emit(.{ .store_box = .{ .box = box_r, .src = v } });
            } else {
                try ctx.func.emit(.{ .store_local = .{ .slot = info.slot, .src = v } });
            }
            return v;
        }
        if (ctx.captures.get(name)) |cap| {
            if (cap.kind == .boxed) {
                const box_r = ctx.freshReg();
                try ctx.func.emit(.{ .load_capture = .{ .dst = box_r, .idx = cap.idx } });
                try ctx.func.emit(.{ .store_box = .{ .box = box_r, .src = v } });
            } else {
                // Unexpected: capturing a non-boxed mutable var. Treat as global set.
                try ctx.func.emit(.{ .store_global = .{ .name = name, .src = v } });
            }
            return v;
        }
        try ctx.func.emit(.{ .store_global = .{ .name = name, .src = v } });
        return v;
    }

    fn lowerIf(c: *Compiler, ctx: *FnCtx, cond_id: NodeId, then_id: NodeId, else_id: ?NodeId) anyerror!Reg {
        return c.lowerIfTail(ctx, cond_id, then_id, else_id, false);
    }

    fn lowerIfTail(c: *Compiler, ctx: *FnCtx, cond_id: NodeId, then_id: NodeId, else_id: ?NodeId, tail: bool) anyerror!Reg {
        const saved_reg = ctx.next_reg;

        // zepo-28f: fuse `(if (null? x) ...)` and `(if (pair? x) ...)` —
        // skip the bool-write/bool-read by branching directly on the predicate.
        const cond_node = c.arena.get(cond_id).*;
        const FusedPred = enum { null_p, pair_p };
        var fused: ?FusedPred = null;
        var fused_arg: NodeId = 0;
        if (cond_node == .application and cond_node.application.args.len == 1) {
            const fn_node = c.arena.get(cond_node.application.func).*;
            if (fn_node == .sym_ref) {
                const name = fn_node.sym_ref.name;
                if (std.mem.eql(u8, name, "null?")) {
                    fused = .null_p;
                    fused_arg = cond_node.application.args[0];
                } else if (std.mem.eql(u8, name, "pair?")) {
                    fused = .pair_p;
                    fused_arg = cond_node.application.args[0];
                }
            }
        }
        if (fused) |fp| {
            const r1 = try c.lowerNode(ctx, fused_arg);
            const then_lbl_f = ctx.func.newLabel();
            const else_lbl_f = ctx.func.newLabel();
            const end_lbl_f = ctx.func.newLabel();
            switch (fp) {
                .null_p => try ctx.func.emit(.{ .branch_if_not_null = .{ .src = r1, .then_label = then_lbl_f, .else_label = else_lbl_f } }),
                .pair_p => try ctx.func.emit(.{ .branch_if_not_pair = .{ .src = r1, .then_label = then_lbl_f, .else_label = else_lbl_f } }),
            }
            ctx.next_reg = saved_reg;

            const result_slot_f = ctx.allocSlot();
            try ctx.func.placeLabel(then_lbl_f);
            const then_r_f = try c.lowerNodeTail(ctx, then_id, tail);
            try ctx.func.emit(.{ .store_local = .{ .slot = result_slot_f, .src = then_r_f } });
            try ctx.func.emit(.{ .branch = .{ .label = end_lbl_f } });
            ctx.next_reg = saved_reg;

            try ctx.func.placeLabel(else_lbl_f);
            if (else_id) |eid| {
                const else_r_f = try c.lowerNodeTail(ctx, eid, tail);
                try ctx.func.emit(.{ .store_local = .{ .slot = result_slot_f, .src = else_r_f } });
            } else {
                const nil_r_f = ctx.freshReg();
                try ctx.func.emit(.{ .load_nil = .{ .dst = nil_r_f } });
                try ctx.func.emit(.{ .store_local = .{ .slot = result_slot_f, .src = nil_r_f } });
            }
            try ctx.func.emit(.{ .branch = .{ .label = end_lbl_f } });
            ctx.next_reg = saved_reg;

            try ctx.func.placeLabel(end_lbl_f);
            const result_r_f = ctx.freshReg();
            try ctx.func.emit(.{ .load_local = .{ .dst = result_r_f, .slot = result_slot_f } });
            return result_r_f;
        }

        const cond_r = try c.lowerNode(ctx, cond_id);
        const then_lbl = ctx.func.newLabel();
        const else_lbl = ctx.func.newLabel();
        const end_lbl = ctx.func.newLabel();
        try ctx.func.emit(.{ .branch_if = .{ .cond = cond_r, .then_label = then_lbl, .else_label = else_lbl } });
        ctx.next_reg = saved_reg; // cond_r consumed by branch_if

        const result_slot = ctx.allocSlot();

        try ctx.func.placeLabel(then_lbl);
        const then_r = try c.lowerNodeTail(ctx, then_id, tail);
        try ctx.func.emit(.{ .store_local = .{ .slot = result_slot, .src = then_r } });
        try ctx.func.emit(.{ .branch = .{ .label = end_lbl } });
        ctx.next_reg = saved_reg;

        try ctx.func.placeLabel(else_lbl);
        if (else_id) |eid| {
            const else_r = try c.lowerNodeTail(ctx, eid, tail);
            try ctx.func.emit(.{ .store_local = .{ .slot = result_slot, .src = else_r } });
        } else {
            const nil_r = ctx.freshReg();
            try ctx.func.emit(.{ .load_nil = .{ .dst = nil_r } });
            try ctx.func.emit(.{ .store_local = .{ .slot = result_slot, .src = nil_r } });
        }
        try ctx.func.emit(.{ .branch = .{ .label = end_lbl } });
        ctx.next_reg = saved_reg;

        try ctx.func.placeLabel(end_lbl);
        const result_r = ctx.freshReg();
        try ctx.func.emit(.{ .load_local = .{ .dst = result_r, .slot = result_slot } });
        return result_r;
    }

    fn lowerCondTail(c: *Compiler, ctx: *FnCtx, clauses: []const ast.CondClause, tail: bool) anyerror!Reg {
        return c.lowerCond(ctx, clauses, tail);
    }

    fn lowerSequenceTail(c: *Compiler, ctx: *FnCtx, exprs: []const NodeId, tail: bool) anyerror!Reg {
        if (exprs.len == 0) {
            const r = ctx.freshReg();
            try ctx.func.emit(.{ .load_nil = .{ .dst = r } });
            return r;
        }
        const saved_reg = ctx.next_reg;
        var last: Reg = 0;
        for (exprs, 0..) |eid, i| {
            const is_last = i + 1 == exprs.len;
            last = try c.lowerNodeTail(ctx, eid, tail and is_last);
            // Reclaim non-last results — they are discarded (sequence evaluates
            // for side effects; only the final value matters).
            if (!is_last) ctx.next_reg = saved_reg;
        }
        return last;
    }

    fn lowerCond(c: *Compiler, ctx: *FnCtx, clauses: []const ast.CondClause, tail: bool) anyerror!Reg {
        const end_lbl = ctx.func.newLabel();
        const result_slot = ctx.allocSlot();
        const saved_reg = ctx.next_reg;

        // Initialize result to NIL so fall-through case returns NIL.
        const nil_r0 = ctx.freshReg();
        try ctx.func.emit(.{ .load_nil = .{ .dst = nil_r0 } });
        try ctx.func.emit(.{ .store_local = .{ .slot = result_slot, .src = nil_r0 } });
        ctx.next_reg = saved_reg;

        for (clauses) |cl| {
            // Each clause reuses the same register space — clauses are mutually exclusive.
            ctx.next_reg = saved_reg;
            const test_r = try c.lowerNode(ctx, cl.test_);
            const body_lbl = ctx.func.newLabel();
            const next_lbl = ctx.func.newLabel();
            try ctx.func.emit(.{ .branch_if = .{ .cond = test_r, .then_label = body_lbl, .else_label = next_lbl } });
            ctx.next_reg = saved_reg;

            try ctx.func.placeLabel(body_lbl);
            var last_r: Reg = test_r;
            if (cl.body.len > 0) {
                for (cl.body, 0..) |bid, i| {
                    const is_last = i + 1 == cl.body.len;
                    last_r = try c.lowerNodeTail(ctx, bid, tail and is_last);
                    if (!is_last) ctx.next_reg = saved_reg;
                }
            }
            // store_local + branch to end are dead code after a tail_call, but
            // harmless — the tail_call transfers control before reaching them.
            try ctx.func.emit(.{ .store_local = .{ .slot = result_slot, .src = last_r } });
            try ctx.func.emit(.{ .branch = .{ .label = end_lbl } });

            try ctx.func.placeLabel(next_lbl);
        }
        ctx.next_reg = saved_reg;
        try ctx.func.emit(.{ .branch = .{ .label = end_lbl } });
        try ctx.func.placeLabel(end_lbl);

        const r = ctx.freshReg();
        try ctx.func.emit(.{ .load_local = .{ .dst = r, .slot = result_slot } });
        return r;
    }

    fn lowerSequence(c: *Compiler, ctx: *FnCtx, exprs: []const NodeId) anyerror!Reg {
        if (exprs.len == 0) {
            const r = ctx.freshReg();
            try ctx.func.emit(.{ .load_nil = .{ .dst = r } });
            return r;
        }
        const saved_reg = ctx.next_reg;
        var last: Reg = 0;
        for (exprs, 0..) |eid, i| {
            last = try c.lowerNode(ctx, eid);
            if (i + 1 < exprs.len) ctx.next_reg = saved_reg;
        }
        return last;
    }

    fn lowerApplication(c: *Compiler, ctx: *FnCtx, func_id: NodeId, arg_ids: []const NodeId) anyerror!Reg {
        return c.lowerApplicationTail(ctx, func_id, arg_ids, false);
    }

    fn lowerApplicationTail(c: *Compiler, ctx: *FnCtx, func_id: NodeId, arg_ids: []const NodeId, tail: bool) anyerror!Reg {
        // zepo-abd / zepo-1xz: specialize calls to known builtins directly
        // into dedicated bytecode, bypassing the CALL machinery.
        const fn_node = c.arena.get(func_id).*;
        if (fn_node == .sym_ref) {
            const name = fn_node.sym_ref.name;
            // 2-arg specializations.
            if (arg_ids.len == 2) {
                const SpecOp = enum { add, sub, mul, num_eq, num_lt, num_gt, cons, eq_p };
                const which: ?SpecOp = if (std.mem.eql(u8, name, "+")) .add
                    else if (std.mem.eql(u8, name, "-")) .sub
                    else if (std.mem.eql(u8, name, "*")) .mul
                    else if (std.mem.eql(u8, name, "=")) .num_eq
                    else if (std.mem.eql(u8, name, "<")) .num_lt
                    else if (std.mem.eql(u8, name, ">")) .num_gt
                    else if (std.mem.eql(u8, name, "cons")) .cons
                    else if (std.mem.eql(u8, name, "eq?")) .eq_p
                    else null;
                if (which) |w| {
                    const saved = ctx.next_reg;
                    const r1 = try c.lowerNode(ctx, arg_ids[0]);
                    const r2 = try c.lowerNode(ctx, arg_ids[1]);
                    ctx.next_reg = saved;
                    const dst = ctx.freshReg();
                    switch (w) {
                        .add => try ctx.func.emit(.{ .add2 = .{ .dst = dst, .src1 = r1, .src2 = r2 } }),
                        .sub => try ctx.func.emit(.{ .sub2 = .{ .dst = dst, .src1 = r1, .src2 = r2 } }),
                        .mul => try ctx.func.emit(.{ .mul2 = .{ .dst = dst, .src1 = r1, .src2 = r2 } }),
                        .num_eq => try ctx.func.emit(.{ .num_eq2 = .{ .dst = dst, .src1 = r1, .src2 = r2 } }),
                        .num_lt => try ctx.func.emit(.{ .num_lt2 = .{ .dst = dst, .src1 = r1, .src2 = r2 } }),
                        .num_gt => try ctx.func.emit(.{ .num_gt2 = .{ .dst = dst, .src1 = r1, .src2 = r2 } }),
                        .cons => try ctx.func.emit(.{ .cons = .{ .dst = dst, .car = r1, .cdr = r2 } }),
                        .eq_p => try ctx.func.emit(.{ .eq_p = .{ .dst = dst, .src1 = r1, .src2 = r2 } }),
                    }
                    return dst;
                }
            }
            // 1-arg specializations: car, cdr, null?, pair?.
            if (arg_ids.len == 1) {
                const SpecOp1 = enum { car, cdr, null_p, pair_p };
                const which: ?SpecOp1 = if (std.mem.eql(u8, name, "car")) .car
                    else if (std.mem.eql(u8, name, "cdr")) .cdr
                    else if (std.mem.eql(u8, name, "null?")) .null_p
                    else if (std.mem.eql(u8, name, "pair?")) .pair_p
                    else null;
                if (which) |w| {
                    const saved = ctx.next_reg;
                    const r1 = try c.lowerNode(ctx, arg_ids[0]);
                    ctx.next_reg = saved;
                    const dst = ctx.freshReg();
                    switch (w) {
                        .car => try ctx.func.emit(.{ .car = .{ .dst = dst, .src = r1 } }),
                        .cdr => try ctx.func.emit(.{ .cdr = .{ .dst = dst, .src = r1 } }),
                        .null_p => try ctx.func.emit(.{ .null_p = .{ .dst = dst, .src = r1 } }),
                        .pair_p => try ctx.func.emit(.{ .pair_p = .{ .dst = dst, .src = r1 } }),
                    }
                    return dst;
                }
            }
        }
        const saved_reg = ctx.next_reg;
        const func_r = try c.lowerNode(ctx, func_id);
        var arg_regs = std.ArrayList(Reg){};
        defer arg_regs.deinit(ctx.allocator);
        for (arg_ids) |aid| {
            const ar = try c.lowerNode(ctx, aid);
            try arg_regs.append(ctx.allocator, ar);
        }
        const args_owned = try ctx.func.dupRegs(arg_regs.items);
        if (tail) {
            try ctx.func.emit(.{ .tail_call = .{
                .func = func_r,
                .args = args_owned,
            } });
            ctx.next_reg = saved_reg;
            return func_r;
        }
        const sp_id = c.freshSp();
        try ctx.func.emit(.{ .safepoint = .{ .id = sp_id } });
        // Record conservative root map BEFORE reclaiming registers.
        var live = std.ArrayList(Reg){};
        defer live.deinit(ctx.allocator);
        try live.append(ctx.allocator, func_r);
        for (arg_regs.items) |r| try live.append(ctx.allocator, r);
        try ctx.func.recordRootMap(sp_id, live.items);
        // Reclaim func_r and all arg registers — they are consumed by the
        // call and not needed after it. dst gets the first recycled slot.
        ctx.next_reg = saved_reg;
        const dst = ctx.freshReg();
        try ctx.func.emit(.{ .call = .{
            .dst = dst,
            .func = func_r,
            .args = args_owned,
            .safepoint = sp_id,
        } });
        return dst;
    }

    fn lowerLambda(c: *Compiler, outer: *FnCtx, lambda_id: NodeId) anyerror!Reg {
        return c.lowerLambdaNamed(outer, lambda_id, null);
    }

    fn lowerLambdaNamed(c: *Compiler, outer: *FnCtx, lambda_id: NodeId, hint_name: ?[]const u8) anyerror!Reg {
        const lam = c.arena.get(lambda_id).*.lambda;
        const saved_reg = outer.next_reg;

        // Resolve capture sources in outer context.
        var capture_src_regs = std.ArrayList(Reg){};
        defer capture_src_regs.deinit(outer.allocator);
        var capture_kinds = std.ArrayList(LocalKind){};
        defer capture_kinds.deinit(outer.allocator);
        var capture_names = std.ArrayList([]const u8){};
        defer capture_names.deinit(outer.allocator);

        for (lam.free_vars) |fv| {
            // Each free var must be loaded from the outer scope.
            // If it's a boxed local, we want to pass the box itself (so inner
            // lambda shares mutation). If it's a captured-boxed in outer, same.
            // Globals are NOT captured — the inner body falls back to
            // `load_global` for unresolved names, which supports recursive
            // top-level definitions (the global may not exist yet at closure-
            // creation time).
            var box_kind: LocalKind = .plain;
            const src_reg = blk: {
                if (outer.locals.get(fv)) |info| {
                    box_kind = info.kind;
                    const r = outer.freshReg();
                    try outer.func.emit(.{ .load_local = .{ .dst = r, .slot = info.slot } });
                    break :blk r;
                }
                if (outer.captures.get(fv)) |cap| {
                    box_kind = cap.kind;
                    const r = outer.freshReg();
                    try outer.func.emit(.{ .load_capture = .{ .dst = r, .idx = cap.idx } });
                    break :blk r;
                }
                // Skip globals — see note above.
                break :blk null;
            } orelse continue;
            try capture_src_regs.append(outer.allocator, src_reg);
            try capture_kinds.append(outer.allocator, box_kind);
            try capture_names.append(outer.allocator, fv);
        }

        // Build inner function. Reserve slot up front so nested lambdas
        // appended during body compilation go *after* our slot.
        const inner_id = c.program.nextFunctionId();
        _ = try c.program.addFunction(Function.init(inner_id, hint_name, @intCast(lam.params.len), lam.rest_param != null, c.allocator));
        var inner = FnCtx.init(
            inner_id,
            hint_name,
            @intCast(lam.params.len),
            lam.rest_param != null,
            c.allocator,
            outer,
        );

        // Record capture names so the VM can map idx -> name.
        for (capture_names.items, 0..) |nm, i| {
            _ = i;
            try inner.func.capture_names.append(c.allocator, nm);
        }
        // Populate inner.captures — idx matches the order above.
        for (capture_names.items, 0..) |nm, i| {
            try inner.captures.put(nm, .{ .idx = @intCast(i), .kind = capture_kinds.items[i] });
        }

        // Allocate parameter locals.
        var slot: u16 = 0;
        for (lam.params) |pname| {
            const s = slot;
            slot += 1;
            const is_mut = containsName(lam.mutated_vars, pname);
            if (is_mut) {
                // The param arrives in slot `s` as a plain value; on entry we
                // wrap it in a box and store the box into the same slot.
                const param_r = inner.freshReg();
                try inner.func.emit(.{ .load_local = .{ .dst = param_r, .slot = s } });
                const box_r = inner.freshReg();
                try inner.func.emit(.{ .alloc_box = .{ .dst = box_r, .init = param_r } });
                try inner.func.emit(.{ .store_local = .{ .slot = s, .src = box_r } });
                try inner.locals.put(pname, .{ .slot = s, .kind = .boxed });
            } else {
                try inner.locals.put(pname, .{ .slot = s, .kind = .plain });
            }
        }
        if (lam.rest_param) |rp| {
            const s = slot;
            slot += 1;
            const is_mut = containsName(lam.mutated_vars, rp);
            if (is_mut) {
                const param_r = inner.freshReg();
                try inner.func.emit(.{ .load_local = .{ .dst = param_r, .slot = s } });
                const box_r = inner.freshReg();
                try inner.func.emit(.{ .alloc_box = .{ .dst = box_r, .init = param_r } });
                try inner.func.emit(.{ .store_local = .{ .slot = s, .src = box_r } });
                try inner.locals.put(rp, .{ .slot = s, .kind = .boxed });
            } else {
                try inner.locals.put(rp, .{ .slot = s, .kind = .plain });
            }
        }
        // Keyword param slots come after positional + rest. The VM fills them
        // at call dispatch time (defaults first, then caller overrides).
        for (lam.keyword_params) |kp| {
            const s = slot;
            slot += 1;
            const ir_default: ops.KwDefault = switch (kp.default) {
                .nil => ops.KwDefault{ .nil = {} },
                .boolean => |bv| ops.KwDefault{ .boolean = bv },
                .fixnum => |n| ops.KwDefault{ .fixnum = n },
                .float => |f| ops.KwDefault{ .float = f },
                .string => |sv| ops.KwDefault{ .string = sv },
            };
            try inner.func.keyword_params.append(c.allocator, .{
                .name = kp.name,
                .slot = s,
                .default = ir_default,
            });
            const is_mut = containsName(lam.mutated_vars, kp.name);
            if (is_mut) {
                const param_r = inner.freshReg();
                try inner.func.emit(.{ .load_local = .{ .dst = param_r, .slot = s } });
                const box_r = inner.freshReg();
                try inner.func.emit(.{ .alloc_box = .{ .dst = box_r, .init = param_r } });
                try inner.func.emit(.{ .store_local = .{ .slot = s, .src = box_r } });
                try inner.locals.put(kp.name, .{ .slot = s, .kind = .boxed });
            } else {
                try inner.locals.put(kp.name, .{ .slot = s, .kind = .plain });
            }
        }
        inner.next_slot = slot;
        inner.func.num_locals = slot;

        // Lower body. The last expression is in tail position so applications
        // can compile to `.tail_call` rather than `.call`.
        var last_r: Reg = 0;
        if (lam.body.len == 0) {
            last_r = inner.freshReg();
            try inner.func.emit(.{ .load_nil = .{ .dst = last_r } });
        } else {
            for (lam.body, 0..) |bid, i| {
                const is_last = i + 1 == lam.body.len;
                last_r = try c.lowerNodeTail(&inner, bid, is_last);
            }
        }
        try inner.func.emit(.{ .ret = .{ .src = last_r } });

        // Swap finalized inner into its reserved slot.
        var placeholder = c.program.functions.items[inner_id];
        placeholder.deinit();
        c.program.functions.items[inner_id] = inner.func;
        inner.func = undefined;
        inner.deinit();

        // Emit make_closure in outer. Reclaim capture src registers first —
        // they are consumed by make_closure and not needed afterward.
        const captures_owned = try outer.func.dupRegs(capture_src_regs.items);
        outer.next_reg = saved_reg;
        const dst = outer.freshReg();
        try outer.func.emit(.{ .make_closure = .{
            .dst = dst,
            .code_id = inner_id,
            .arity = @intCast(lam.params.len),
            .has_rest = lam.rest_param != null,
            .captures = captures_owned,
        } });
        return dst;
    }

    fn lowerLet(c: *Compiler, ctx: *FnCtx, id: NodeId, tail: bool) anyerror!Reg {
        const let = c.arena.get(id).*.let_expr;

        // Evaluate all init exprs in current scope (before any binding is in scope).
        var init_regs = std.ArrayList(Reg){};
        defer init_regs.deinit(ctx.allocator);
        for (let.bindings) |binding| {
            const r = try c.lowerNode(ctx, binding.value);
            try init_regs.append(ctx.allocator, r);
        }

        // Allocate slots and install bindings.
        // Init registers are all dead after stores — reclaim them.
        const saved_reg = ctx.next_reg;
        const SavedBinding = struct { name: []const u8, old: ?LocalInfo };
        var saved = std.ArrayList(SavedBinding){};
        defer saved.deinit(ctx.allocator);

        for (let.bindings, 0..) |binding, i| {
            const r = init_regs.items[i];
            const slot = ctx.allocSlot();
            const is_mut = containsName(let.mutated_vars, binding.name);
            try saved.append(ctx.allocator, .{ .name = binding.name, .old = ctx.locals.get(binding.name) });
            if (is_mut) {
                const box_r = ctx.freshReg();
                try ctx.func.emit(.{ .alloc_box = .{ .dst = box_r, .init = r } });
                try ctx.func.emit(.{ .store_local = .{ .slot = slot, .src = box_r } });
                try ctx.locals.put(binding.name, .{ .slot = slot, .kind = .boxed });
            } else {
                try ctx.func.emit(.{ .store_local = .{ .slot = slot, .src = r } });
                try ctx.locals.put(binding.name, .{ .slot = slot, .kind = .plain });
            }
        }

        ctx.next_reg = saved_reg;

        var last_r: Reg = 0;
        for (let.body, 0..) |bid, i| {
            const is_last = i + 1 == let.body.len;
            last_r = try c.lowerNodeTail(ctx, bid, tail and is_last);
        }
        if (let.body.len == 0) {
            last_r = ctx.freshReg();
            try ctx.func.emit(.{ .load_nil = .{ .dst = last_r } });
        }

        // Restore shadowed bindings.
        for (saved.items) |sv| {
            if (sv.old) |old_info| {
                try ctx.locals.put(sv.name, old_info);
            } else {
                _ = ctx.locals.remove(sv.name);
            }
        }
        return last_r;
    }

    fn lowerLetStar(c: *Compiler, ctx: *FnCtx, id: NodeId, tail: bool) anyerror!Reg {
        const let = c.arena.get(id).*.let_star_expr;

        const saved_reg = ctx.next_reg;
        const SavedBinding = struct { name: []const u8, old: ?LocalInfo };
        var saved = std.ArrayList(SavedBinding){};
        defer saved.deinit(ctx.allocator);

        for (let.bindings) |binding| {
            // Each init is evaluated with all previous bindings in scope.
            const r = try c.lowerNode(ctx, binding.value);
            const slot = ctx.allocSlot();
            const is_mut = containsName(let.mutated_vars, binding.name);
            try saved.append(ctx.allocator, .{ .name = binding.name, .old = ctx.locals.get(binding.name) });
            if (is_mut) {
                const box_r = ctx.freshReg();
                try ctx.func.emit(.{ .alloc_box = .{ .dst = box_r, .init = r } });
                try ctx.func.emit(.{ .store_local = .{ .slot = slot, .src = box_r } });
                try ctx.locals.put(binding.name, .{ .slot = slot, .kind = .boxed });
            } else {
                try ctx.func.emit(.{ .store_local = .{ .slot = slot, .src = r } });
                try ctx.locals.put(binding.name, .{ .slot = slot, .kind = .plain });
            }
        }

        ctx.next_reg = saved_reg;

        var last_r: Reg = 0;
        for (let.body, 0..) |bid, i| {
            const is_last = i + 1 == let.body.len;
            last_r = try c.lowerNodeTail(ctx, bid, tail and is_last);
        }
        if (let.body.len == 0) {
            last_r = ctx.freshReg();
            try ctx.func.emit(.{ .load_nil = .{ .dst = last_r } });
        }

        for (saved.items) |sv| {
            if (sv.old) |old_info| {
                try ctx.locals.put(sv.name, old_info);
            } else {
                _ = ctx.locals.remove(sv.name);
            }
        }
        return last_r;
    }
};

fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}
