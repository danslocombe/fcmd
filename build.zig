const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_model = .baseline },
    });
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "fcmd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.link_libc = true;
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
    basic_tests.root_module.link_libc = true;
    const run_basic_tests = b.addRunArtifact(basic_tests);

    // Extended trie tests (stress, integrity, edge cases)
    const extended_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_trie_extended.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    extended_tests.root_module.link_libc = true;
    const run_extended_tests = b.addRunArtifact(extended_tests);

    // Behavioral tests (mocked filesystem, end-to-end completion scenarios)
    const behavioral_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_behavioral.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    behavioral_tests.root_module.link_libc = true;
    const run_behavioral_tests = b.addRunArtifact(behavioral_tests);
    run_behavioral_tests.step.dependOn(&run_extended_tests.step);

    // Multi-process scenario tests
    const multiprocess_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_multiprocess_scenarios.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    multiprocess_tests.root_module.link_libc = true;
    const run_multiprocess_tests = b.addRunArtifact(multiprocess_tests);

    // Multi-process tests spawn fcmd.exe, so they need the exe to be built first
    run_multiprocess_tests.step.dependOn(b.getInstallStep());

    // Run tests sequentially to avoid Zig 0.16.0-dev IPC hangs under parallel execution
    run_basic_tests.step.dependOn(&run_unit_tests.step);
    run_extended_tests.step.dependOn(&run_basic_tests.step);
    run_multiprocess_tests.step.dependOn(&run_behavioral_tests.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_multiprocess_tests.step);

    // Individual test steps
    const test_basic_step = b.step("test-basic", "Run basic trie tests");
    test_basic_step.dependOn(&run_basic_tests.step);

    const test_extended_step = b.step("test-extended", "Run extended trie tests");
    test_extended_step.dependOn(&run_extended_tests.step);

    const test_behavioral_step = b.step("test-behavioral", "Run behavioral tests");
    test_behavioral_step.dependOn(&run_behavioral_tests.step);

    const test_multiprocess_step = b.step("test-multiprocess", "Run multi-process tests");
    test_multiprocess_step.dependOn(&run_multiprocess_tests.step);

    // Render tests (pure computation, no libc needed)
    const render_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/render.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_render_tests = b.addRunArtifact(render_tests);

    const test_render_step = b.step("test-render", "Run render tests");
    test_render_step.dependOn(&run_render_tests.step);

    const exe_check = b.addExecutable(.{
        .name = "bounce",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe_check.root_module.link_libc = true;
    const check = b.step("check", "Check if project compiles");
    check.dependOn(&exe_check.step);
}
