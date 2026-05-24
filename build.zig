const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_opts = b.addOptions();
    const stdlib_src = b.build_root.handle.readFileAlloc(b.graph.io, "lib/stdlib.lisp", b.allocator, .unlimited) catch @panic("lib/stdlib.lisp not found");
    lib_opts.addOption([]const u8, "stdlib_src", stdlib_src);

    // Bake the absolute source-tree path so `zepo build` can locate
    // the zepo runtime when shelling out to `zig build`.
    const main_opts = b.addOptions();
    const zepo_src_dir = b.build_root.path orelse b.pathResolve(&.{"."});
    main_opts.addOption([]const u8, "zepo_src_dir", zepo_src_dir);

    const mod = b.addModule("zepo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });
    mod.addOptions("lib_opts", lib_opts);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zepo", .module = mod },
        },
    });
    exe_mod.addOptions("main_opts", main_opts);

    const exe = b.addExecutable(.{
        .name = "zepo",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // --- Unit tests on the main module ---
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // --- GC tests ---
    const gc_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/gc/basic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zepo", .module = mod },
        },
    });
    const gc_tests = b.addTest(.{ .root_module = gc_test_mod });
    const run_gc_tests = b.addRunArtifact(gc_tests);

    const gc_test_step = b.step("gc_test", "Run GC tests");
    gc_test_step.dependOn(&run_gc_tests.step);

    // Additional GC correctness tests.
    const gc_vm_regs_mod = b.createModule(.{
        .root_source_file = b.path("tests/gc/vm_regs.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const gc_vm_regs_tests = b.addTest(.{ .root_module = gc_vm_regs_mod });
    const run_gc_vm_regs_tests = b.addRunArtifact(gc_vm_regs_tests);
    gc_test_step.dependOn(&run_gc_vm_regs_tests.step);

    const gc_wb_mod = b.createModule(.{
        .root_source_file = b.path("tests/gc/write_barrier.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const gc_wb_tests = b.addTest(.{ .root_module = gc_wb_mod });
    const run_gc_wb_tests = b.addRunArtifact(gc_wb_tests);
    gc_test_step.dependOn(&run_gc_wb_tests.step);

    const gc_foreign_mod = b.createModule(.{
        .root_source_file = b.path("tests/gc/foreign_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const gc_foreign_tests = b.addTest(.{ .root_module = gc_foreign_mod });
    const run_gc_foreign_tests = b.addRunArtifact(gc_foreign_tests);
    gc_test_step.dependOn(&run_gc_foreign_tests.step);

    const gc_foreign_stress_mod = b.createModule(.{
        .root_source_file = b.path("tests/gc/foreign_stress_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const gc_foreign_stress_tests = b.addTest(.{ .root_module = gc_foreign_stress_mod });
    const run_gc_foreign_stress_tests = b.addRunArtifact(gc_foreign_stress_tests);
    gc_test_step.dependOn(&run_gc_foreign_stress_tests.step);

    // --- Runtime object tests ---
    const runtime_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/runtime/objects.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const runtime_tests = b.addTest(.{ .root_module = runtime_test_mod });
    const run_runtime_tests = b.addRunArtifact(runtime_tests);

    // --- Reader tests ---
    const reader_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/reader/basic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const reader_tests = b.addTest(.{ .root_module = reader_test_mod });
    const run_reader_tests = b.addRunArtifact(reader_tests);

    // --- Sema/AST tests ---
    const sema_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/sema/ast.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const sema_tests = b.addTest(.{ .root_module = sema_test_mod });
    const run_sema_tests = b.addRunArtifact(sema_tests);

    // --- Compiler/IR tests ---
    const ir_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/compiler/ir.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const ir_tests = b.addTest(.{ .root_module = ir_test_mod });
    const run_ir_tests = b.addRunArtifact(ir_tests);

    // --- VM end-to-end tests ---
    const vm_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/compiler/vm.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const vm_tests = b.addTest(.{ .root_module = vm_test_mod });
    const run_vm_tests = b.addRunArtifact(vm_tests);

    // --- Runtime error tests ---
    const runtime_errors_mod = b.createModule(.{
        .root_source_file = b.path("tests/runtime/errors.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const runtime_errors_tests = b.addTest(.{ .root_module = runtime_errors_mod });
    const run_runtime_errors_tests = b.addRunArtifact(runtime_errors_tests);

    // --- Diagnostic tests (zepo-45l) ---
    const conformance_helpers_mod = b.createModule(.{
        .root_source_file = b.path("tests/conformance/helpers.zig"),
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const diagnostic_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/runtime/diagnostic_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zepo", .module = mod },
            .{ .name = "conformance_helpers", .module = conformance_helpers_mod },
        },
    });
    const diagnostic_tests = b.addTest(.{ .root_module = diagnostic_test_mod });
    const run_diagnostic_tests = b.addRunArtifact(diagnostic_tests);

    // --- Module tests ---
    const module_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/runtime/module_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const module_tests = b.addTest(.{ .root_module = module_test_mod });
    const run_module_tests = b.addRunArtifact(module_tests);

    const macros_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/runtime/macros_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const macros_tests = b.addTest(.{ .root_module = macros_test_mod });
    const run_macros_tests = b.addRunArtifact(macros_tests);

    // zepo-c18: syntax-rules / define-syntax tests
    const syntax_rules_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/runtime/syntax_rules_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const syntax_rules_tests = b.addTest(.{ .root_module = syntax_rules_test_mod });
    const run_syntax_rules_tests = b.addRunArtifact(syntax_rules_tests);

    const result_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/runtime/result_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const result_tests = b.addTest(.{ .root_module = result_test_mod });
    const run_result_tests = b.addRunArtifact(result_tests);

    const hashtable_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/runtime/hashtable_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const hashtable_tests = b.addTest(.{ .root_module = hashtable_test_mod });
    const run_hashtable_tests = b.addRunArtifact(hashtable_tests);

    const ffi_basic_mod = b.createModule(.{
        .root_source_file = b.path("tests/ffi/basic_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const ffi_basic_tests = b.addTest(.{ .root_module = ffi_basic_mod });
    const run_ffi_basic_tests = b.addRunArtifact(ffi_basic_tests);

    const ffi_json_mod = b.createModule(.{
        .root_source_file = b.path("tests/ffi/json_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const ffi_json_tests = b.addTest(.{ .root_module = ffi_json_mod });
    const run_ffi_json_tests = b.addRunArtifact(ffi_json_tests);

    const module_errors_mod = b.createModule(.{
        .root_source_file = b.path("tests/sema/module_errors_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const module_errors_tests = b.addTest(.{ .root_module = module_errors_mod });
    const run_module_errors_tests = b.addRunArtifact(module_errors_tests);

    const module_roots_mod = b.createModule(.{
        .root_source_file = b.path("tests/gc/module_roots_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zepo", .module = mod }},
    });
    const module_roots_tests = b.addTest(.{ .root_module = module_roots_mod });
    const run_module_roots_tests = b.addRunArtifact(module_roots_tests);
    gc_test_step.dependOn(&run_module_roots_tests.step);

    // --- Conformance tests ---
    const conformance_files = [_][]const u8{
        "tests/conformance/reader.zig",
        "tests/conformance/semantic.zig",
        "tests/conformance/runtime.zig",
        "tests/conformance/primitives.zig",
        "tests/conformance/failures.zig",
        "tests/conformance/clap_test.zig",
    };
    var conformance_steps: [conformance_files.len]*std.Build.Step = undefined;
    for (conformance_files, 0..) |path, i| {
        const tm = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zepo", .module = mod }},
        });
        const t = b.addTest(.{ .root_module = tm });
        const run_t = b.addRunArtifact(t);
        conformance_steps[i] = &run_t.step;
    }

    // --- install-global step ---
    // zepo-299: always build the installed binary with ReleaseFast regardless
    // of the -Doptimize flag, so `zig build install-global` never installs a
    // slow debug binary.
    {
        const install_global = b.step("install-global", "Install zepo binary and libs to ~/.local/{bin,lib/zepo}");
        const home = b.graph.environ_map.get("HOME") orelse @panic("HOME not set");
        const bin_dir = std.fs.path.join(b.allocator, &.{ home, ".local", "bin" }) catch @panic("OOM");
        const lib_dir = std.fs.path.join(b.allocator, &.{ home, ".local", "lib", "zepo" }) catch @panic("OOM");
        const bin_dest = std.fs.path.join(b.allocator, &.{ bin_dir, "zepo" }) catch @panic("OOM");
        const lib_src = std.fs.path.join(b.allocator, &.{ zepo_src_dir, "lib" }) catch @panic("OOM");

        const release_mod = b.addModule("zepo-release", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        });
        release_mod.addOptions("lib_opts", lib_opts);
        const release_exe_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zepo", .module = release_mod },
            },
        });
        release_exe_mod.addOptions("main_opts", main_opts);
        const release_exe = b.addExecutable(.{
            .name = "zepo",
            .root_module = release_exe_mod,
        });

        const mk = b.addSystemCommand(&.{ "mkdir", "-p", bin_dir, lib_dir });

        const cp_bin = b.addSystemCommand(&.{ "cp" });
        cp_bin.addFileArg(release_exe.getEmittedBin());
        cp_bin.addArg(bin_dest);
        cp_bin.step.dependOn(&mk.step);

        const cp_lib_cmd = std.fmt.allocPrint(b.allocator, "cp -r '{s}/.' '{s}'", .{ lib_src, lib_dir }) catch @panic("OOM");
        const cp_lib = b.addSystemCommand(&.{ "sh", "-c", cp_lib_cmd });
        cp_lib.step.dependOn(&mk.step);

        install_global.dependOn(&cp_bin.step);
        install_global.dependOn(&cp_lib.step);
    }

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_gc_tests.step);
    test_step.dependOn(&run_gc_vm_regs_tests.step);
    test_step.dependOn(&run_gc_wb_tests.step);
    test_step.dependOn(&run_gc_foreign_tests.step);
    test_step.dependOn(&run_gc_foreign_stress_tests.step);
    test_step.dependOn(&run_runtime_tests.step);
    test_step.dependOn(&run_reader_tests.step);
    test_step.dependOn(&run_sema_tests.step);
    test_step.dependOn(&run_ir_tests.step);
    test_step.dependOn(&run_vm_tests.step);
    test_step.dependOn(&run_runtime_errors_tests.step);
    test_step.dependOn(&run_diagnostic_tests.step);
    test_step.dependOn(&run_module_tests.step);
    test_step.dependOn(&run_macros_tests.step);
    test_step.dependOn(&run_syntax_rules_tests.step);
    test_step.dependOn(&run_result_tests.step);
    test_step.dependOn(&run_hashtable_tests.step);
    test_step.dependOn(&run_ffi_basic_tests.step);
    test_step.dependOn(&run_ffi_json_tests.step);
    test_step.dependOn(&run_module_errors_tests.step);
    test_step.dependOn(&run_module_roots_tests.step);
    for (conformance_steps) |s| test_step.dependOn(s);
}
