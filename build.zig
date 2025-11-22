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

    // Phase 4: Multi-process concurrency tests
    const phase4_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_phase4.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    phase4_tests.linkLibC();
    const run_phase4_tests = b.addRunArtifact(phase4_tests);

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

    // Phase 6: File system integration tests
    const phase6_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_phase6.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    phase6_tests.linkLibC();
    const run_phase6_tests = b.addRunArtifact(phase6_tests);

    // Phase 7: Fuzzing and chaos engineering tests
    const phase7_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_phase7.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    phase7_tests.linkLibC();
    const run_phase7_tests = b.addRunArtifact(phase7_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_basic_tests.step);
    test_step.dependOn(&run_phase1_tests.step);
    test_step.dependOn(&run_phase2_tests.step);
    test_step.dependOn(&run_phase3_tests.step);
    test_step.dependOn(&run_phase4_tests.step);
    test_step.dependOn(&run_phase5_tests.step);
    test_step.dependOn(&run_phase6_tests.step);
    test_step.dependOn(&run_phase7_tests.step);

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
