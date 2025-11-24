const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "fcmd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.linkLibC();
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Unit tests from main.zig
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Basic trie tests
    const basic_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_basic.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    basic_tests.linkLibC();
    const run_basic_tests = b.addRunArtifact(basic_tests);

    // Phase 1: Single-process stress tests
    const phase1_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_phase1.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    phase1_tests.linkLibC();
    const run_phase1_tests = b.addRunArtifact(phase1_tests);

    // Phase 2: Data integrity tests
    const phase2_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_phase2.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    phase2_tests.linkLibC();
    const run_phase2_tests = b.addRunArtifact(phase2_tests);

    // Phase 3: Edge cases tests
    const phase3_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_phase3.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    phase3_tests.linkLibC();
    const run_phase3_tests = b.addRunArtifact(phase3_tests);

    // Phase 5: Additional multi-process scenarios
    const phase5_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_phase5.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    phase5_tests.linkLibC();
    const run_phase5_tests = b.addRunArtifact(phase5_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_basic_tests.step);
    test_step.dependOn(&run_phase1_tests.step);
    test_step.dependOn(&run_phase2_tests.step);
    test_step.dependOn(&run_phase3_tests.step);
    test_step.dependOn(&run_phase5_tests.step);

    // Individual test steps
    const test_basic_step = b.step("test-basic", "Run basic trie tests");
    test_basic_step.dependOn(&run_basic_tests.step);

    const test_phase1_step = b.step("test-phase1", "Run phase 1 tests");
    test_phase1_step.dependOn(&run_phase1_tests.step);

    const test_phase2_step = b.step("test-phase2", "Run phase 2 tests");
    test_phase2_step.dependOn(&run_phase2_tests.step);

    const test_phase3_step = b.step("test-phase3", "Run phase 3 tests");
    test_phase3_step.dependOn(&run_phase3_tests.step);

    const test_phase5_step = b.step("test-phase5", "Run phase 5 tests");
    test_phase5_step.dependOn(&run_phase5_tests.step);

    const exe_check = b.addExecutable(.{
        .name = "bounce",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe_check.linkLibC();
    const check = b.step("check", "Check if project compiles");
    check.dependOn(&exe_check.step);
}
