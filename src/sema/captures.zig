//! Free variable and mutation analysis for lambdas.

const std = @import("std");
const ast = @import("../ast/mod.zig");
const Node = ast.Node;
const NodeId = ast.NodeId;
const NodeArena = ast.NodeArena;
const LetBinding = ast.LetBinding;

pub const CaptureAnalyzer = struct {
    arena: *NodeArena,
    allocator: std.mem.Allocator,

    pub fn init(arena: *NodeArena, allocator: std.mem.Allocator) CaptureAnalyzer {
        return .{ .arena = arena, .allocator = allocator };
    }

    pub fn analyze(c: *CaptureAnalyzer, root_id: NodeId) !void {
        // Walk the AST and populate lambda free/mutated sets.
        try c.walk(root_id);
    }

    fn walk(c: *CaptureAnalyzer, id: NodeId) !void {
        const n = c.arena.get(id).*;
        switch (n) {
            .literal, .quote, .sym_ref => {},
            .define => |d| try c.walk(d.value),
            .set_bang => |s| try c.walk(s.value),
            .if_expr => |i| {
                try c.walk(i.cond);
                try c.walk(i.then_);
                if (i.else_) |e| try c.walk(e);
            },
            .cond_expr => |cond| {
                for (cond.clauses) |cl| {
                    try c.walk(cl.test_);
                    for (cl.body) |bid| try c.walk(bid);
                    if (cl.recv) |recv| try c.walk(recv); // zepo-7gpd
                }
            },
            .application => |app| {
                try c.walk(app.func);
                for (app.args) |a| try c.walk(a);
            },
            .sequence => |seq| {
                for (seq.exprs) |e| try c.walk(e);
            },
            .lambda => {
                try c.analyzeLambda(id);
                // Recurse into body so nested lambdas are analysed too.
                const lam = c.arena.get(id).*.lambda;
                for (lam.body) |bid| try c.walk(bid);
            },
            .let_expr => |let| {
                try c.analyzeLet(id);
                for (let.bindings) |b_| try c.walk(b_.value);
                for (let.body) |bid| try c.walk(bid);
            },
            .let_star_expr => |let| {
                try c.analyzeLet(id);
                for (let.bindings) |b_| try c.walk(b_.value);
                for (let.body) |bid| try c.walk(bid);
            },
            .module_decl => unreachable,
            .import_stmt => {}, // no captures — import is a runtime side-effect
            .with_handler => |wh| {
                // zepo-9bi: handler and inlined body both contribute to
                // captures of the enclosing function.
                try c.walk(wh.handler);
                for (wh.body) |bid| try c.walk(bid);
            },
            .parameterize => |pz| {
                // zepo-6o3p: params/inits/body all evaluate in the enclosing
                // scope — parameterize introduces no lexical bindings.
                for (pz.params) |pid| try c.walk(pid);
                for (pz.inits) |iid| try c.walk(iid);
                for (pz.body) |bid| try c.walk(bid);
            },
            .restart_case => |rc| {
                // zepo-g120: body + each clause (a lambda over the enclosing scope).
                for (rc.body) |bid| try c.walk(bid);
                for (rc.clauses) |cid| try c.walk(cid);
            },
        }
    }

    fn analyzeLambda(c: *CaptureAnalyzer, id: NodeId) !void {
        const lam = c.arena.get(id).*.lambda;

        var params_set = std.StringHashMap(void).init(c.allocator);
        defer params_set.deinit();
        for (lam.params) |p| try params_set.put(p, {});
        if (lam.rest_param) |rp| try params_set.put(rp, {});
        for (lam.keyword_params) |kp| try params_set.put(kp.name, {});

        var free_set = std.StringHashMap(void).init(c.allocator);
        defer free_set.deinit();
        var mutated_set = std.StringHashMap(void).init(c.allocator);
        defer mutated_set.deinit();

        for (lam.body) |bid| {
            try c.collectFree(bid, &params_set, &free_set, &mutated_set);
        }

        // Persist.
        var free_names = std.ArrayListUnmanaged([]const u8).empty;
        defer free_names.deinit(c.allocator);
        var it = free_set.keyIterator();
        while (it.next()) |k| try free_names.append(c.allocator, k.*);

        var mut_names = std.ArrayListUnmanaged([]const u8).empty;
        defer mut_names.deinit(c.allocator);
        var it2 = mutated_set.keyIterator();
        while (it2.next()) |k| try mut_names.append(c.allocator, k.*);

        const free_owned = try c.arena.dupNames(free_names.items);
        const mut_owned = try c.arena.dupNames(mut_names.items);

        c.arena.get(id).*.lambda.free_vars = free_owned;
        c.arena.get(id).*.lambda.mutated_vars = mut_owned;
    }

    fn analyzeLet(c: *CaptureAnalyzer, id: NodeId) !void {
        const node = c.arena.get(id).*;
        const bindings = switch (node) {
            .let_expr => |l| l.bindings,
            .let_star_expr => |l| l.bindings,
            else => unreachable,
        };
        const body = switch (node) {
            .let_expr => |l| l.body,
            .let_star_expr => |l| l.body,
            else => unreachable,
        };

        var params_set = std.StringHashMap(void).init(c.allocator);
        defer params_set.deinit();
        for (bindings) |b_| try params_set.put(b_.name, {});

        var free_set = std.StringHashMap(void).init(c.allocator);
        defer free_set.deinit();
        var mutated_set = std.StringHashMap(void).init(c.allocator);
        defer mutated_set.deinit();

        for (body) |bid| {
            try c.collectFree(bid, &params_set, &free_set, &mutated_set);
        }

        var mut_names = std.ArrayListUnmanaged([]const u8).empty;
        defer mut_names.deinit(c.allocator);
        var it = mutated_set.keyIterator();
        while (it.next()) |k| {
            if (params_set.contains(k.*)) {
                try mut_names.append(c.allocator, k.*);
            }
        }

        const mut_owned = try c.arena.dupNames(mut_names.items);
        switch (c.arena.get(id).*) {
            .let_expr => |*l| l.mutated_vars = mut_owned,
            .let_star_expr => |*l| l.mutated_vars = mut_owned,
            else => unreachable,
        }
    }

    fn collectFree(
        c: *CaptureAnalyzer,
        id: NodeId,
        params: *std.StringHashMap(void),
        free: *std.StringHashMap(void),
        mutated: *std.StringHashMap(void),
    ) !void {
        const n = c.arena.get(id).*;
        switch (n) {
            .literal, .quote => {},
            .sym_ref => |sr| {
                if (!params.contains(sr.name)) {
                    try free.put(sr.name, {});
                }
            },
            .define => |d| {
                try c.collectFree(d.value, params, free, mutated);
                // A define inside a lambda shadows (acts like a local). Record it as a param.
                try params.put(d.name, {});
            },
            .set_bang => |s| {
                try c.collectFree(s.value, params, free, mutated);
                try mutated.put(s.name, {});
                if (!params.contains(s.name)) try free.put(s.name, {});
            },
            .if_expr => |i| {
                try c.collectFree(i.cond, params, free, mutated);
                try c.collectFree(i.then_, params, free, mutated);
                if (i.else_) |e| try c.collectFree(e, params, free, mutated);
            },
            .cond_expr => |cond| {
                for (cond.clauses) |cl| {
                    try c.collectFree(cl.test_, params, free, mutated);
                    for (cl.body) |bid| try c.collectFree(bid, params, free, mutated);
                    // zepo-7gpd: a `(test => proc)` clause's receiver expression.
                    if (cl.recv) |recv| try c.collectFree(recv, params, free, mutated);
                }
            },
            .application => |app| {
                try c.collectFree(app.func, params, free, mutated);
                for (app.args) |a| try c.collectFree(a, params, free, mutated);
            },
            .sequence => |seq| {
                for (seq.exprs) |e| try c.collectFree(e, params, free, mutated);
            },
            .lambda => |inner| {
                // Free vars of inner lambda that are not inner.params are free to us
                // (excluding our params).
                var inner_params = std.StringHashMap(void).init(c.allocator);
                defer inner_params.deinit();
                for (inner.params) |p| try inner_params.put(p, {});
                if (inner.rest_param) |rp| try inner_params.put(rp, {});
                for (inner.keyword_params) |kp| try inner_params.put(kp.name, {});

                var inner_free = std.StringHashMap(void).init(c.allocator);
                defer inner_free.deinit();
                var inner_mutated = std.StringHashMap(void).init(c.allocator);
                defer inner_mutated.deinit();

                for (inner.body) |bid| {
                    try c.collectFree(bid, &inner_params, &inner_free, &inner_mutated);
                }

                // Propagate: any name inner_free not in our params is free to us.
                var it = inner_free.keyIterator();
                while (it.next()) |k| {
                    if (!params.contains(k.*)) try free.put(k.*, {});
                }
                // Propagate mutations that target our scope.
                var mit = inner_mutated.keyIterator();
                while (mit.next()) |k| {
                    if (!inner_params.contains(k.*)) {
                        try mutated.put(k.*, {});
                        if (!params.contains(k.*)) try free.put(k.*, {});
                    }
                }
            },
            .let_expr => |let| {
                // Init exprs evaluated in outer scope (simultaneous).
                for (let.bindings) |b_| {
                    try c.collectFree(b_.value, params, free, mutated);
                }
                // Body in inner scope (outer params + let bindings).
                var inner = std.StringHashMap(void).init(c.allocator);
                defer inner.deinit();
                var pit = params.iterator();
                while (pit.next()) |entry| try inner.put(entry.key_ptr.*, {});
                for (let.bindings) |b_| try inner.put(b_.name, {});

                var inner_free = std.StringHashMap(void).init(c.allocator);
                defer inner_free.deinit();
                var inner_mutated = std.StringHashMap(void).init(c.allocator);
                defer inner_mutated.deinit();

                for (let.body) |bid| {
                    try c.collectFree(bid, &inner, &inner_free, &inner_mutated);
                }
                // Propagate free vars not in outer params.
                var fit = inner_free.keyIterator();
                while (fit.next()) |k| {
                    if (!params.contains(k.*)) try free.put(k.*, {});
                }
                // Propagate mutations of non-let-bound vars.
                var mit = inner_mutated.keyIterator();
                while (mit.next()) |k| {
                    const is_bound = blk: {
                        for (let.bindings) |b_| {
                            if (std.mem.eql(u8, b_.name, k.*)) break :blk true;
                        }
                        break :blk false;
                    };
                    if (!is_bound) {
                        try mutated.put(k.*, {});
                        if (!params.contains(k.*)) try free.put(k.*, {});
                    }
                }
            },
            .let_star_expr => |let| {
                // Bindings evaluated sequentially; each visible to the next.
                var inner = std.StringHashMap(void).init(c.allocator);
                defer inner.deinit();
                var pit = params.iterator();
                while (pit.next()) |entry| try inner.put(entry.key_ptr.*, {});

                var inner_free = std.StringHashMap(void).init(c.allocator);
                defer inner_free.deinit();
                var inner_mutated = std.StringHashMap(void).init(c.allocator);
                defer inner_mutated.deinit();

                for (let.bindings) |b_| {
                    try c.collectFree(b_.value, &inner, &inner_free, &inner_mutated);
                    try inner.put(b_.name, {});
                }
                for (let.body) |bid| {
                    try c.collectFree(bid, &inner, &inner_free, &inner_mutated);
                }
                var fit = inner_free.keyIterator();
                while (fit.next()) |k| {
                    if (!params.contains(k.*)) try free.put(k.*, {});
                }
                var mit = inner_mutated.keyIterator();
                while (mit.next()) |k| {
                    const is_bound = blk: {
                        for (let.bindings) |b_| {
                            if (std.mem.eql(u8, b_.name, k.*)) break :blk true;
                        }
                        break :blk false;
                    };
                    if (!is_bound) {
                        try mutated.put(k.*, {});
                        if (!params.contains(k.*)) try free.put(k.*, {});
                    }
                }
            },
            .module_decl => unreachable,
            .import_stmt => {}, // no captures — import is a runtime side-effect
            .with_handler => |wh| {
                // zepo-9bi: handler + inlined body both see the enclosing params.
                try c.collectFree(wh.handler, params, free, mutated);
                for (wh.body) |bid| try c.collectFree(bid, params, free, mutated);
            },
            .parameterize => |pz| {
                // zepo-6o3p: no new lexical scope — everything sees enclosing params.
                for (pz.params) |pid| try c.collectFree(pid, params, free, mutated);
                for (pz.inits) |iid| try c.collectFree(iid, params, free, mutated);
                for (pz.body) |bid| try c.collectFree(bid, params, free, mutated);
            },
            .restart_case => |rc| {
                // zepo-g120: body + clause lambdas; lambda arm propagates their free vars.
                for (rc.body) |bid| try c.collectFree(bid, params, free, mutated);
                for (rc.clauses) |cid| try c.collectFree(cid, params, free, mutated);
            },
        }
    }
};
