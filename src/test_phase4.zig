const std = @import("std");
const test_exports = @import("test_exports.zig");
const test_mp = @import("test_multiprocess.zig");

// ============================================================================
// PHASE 4 & 4.5: Multi-Process Concurrency Tests
// ============================================================================

test "Phase 4: create and populate test state file" {
    const test_state_path = "test_state_phase4.frog";

    // Clean up any previous test file
    std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create a new test state file
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        256, // initial blocks
    );
    defer state_file.deinit();
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Populate with test data
    const test_strings = [_][]const u8{
        "git status",
        "git commit",
        "git push",
        "npm install",
        "npm start",
        "cargo build",
        "cargo test",
        "make clean",
        "make all",
        "docker build",
    };

    try state_file.populate(&test_strings);

    // Verify all strings are in the file
    const all_found = try test_mp.verifyStringsInStateFile(
        std.testing.allocator,
        test_state_path,
        &test_strings,
    );
    try std.testing.expect(all_found);

    std.debug.print("Phase 4: Successfully created and verified state file with {d} strings\n", .{test_strings.len});
}

test "Phase 4.5: simultaneous readers - 5 processes searching" {
    const test_state_path = "test_state_concurrent_readers.frog";

    // Clean up any previous test file
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create and populate test state file with 100 strings
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        512,
    );
    defer state_file.deinit();

    // Create 100 test strings
    var test_strings_list = std.ArrayList([]const u8){};
    defer test_strings_list.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const str = try std.fmt.allocPrint(std.testing.allocator, "command_{d}", .{i});
        try test_strings_list.append(std.testing.allocator, str);
    }
    defer {
        for (test_strings_list.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    try state_file.populate(test_strings_list.items);

    // Verify initial state
    const all_found = try test_mp.verifyStringsInStateFile(
        std.testing.allocator,
        test_state_path,
        test_strings_list.items,
    );
    try std.testing.expect(all_found);

    // Spawn 5 processes to search for different strings concurrently
    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    // Get the executable path - it should be zig-out/bin/fcmd.exe
    const exe_path = "zig-out\\bin\\fcmd.exe";

    // Each process searches for a different string
    const search_indices = [_]usize{ 10, 25, 50, 75, 90 };

    for (search_indices) |idx| {
        const search_str = test_strings_list.items[idx];

        const args = [_][]const u8{
            exe_path,
            "--test-mp",
            "search",
            test_state_path,
            search_str,
        };

        try controller.spawn(&args);
    }

    std.debug.print("Phase 4.5: Spawned 5 reader processes, waiting for completion...\n", .{});

    // Wait for all processes to complete
    const exit_codes = try controller.waitAll();
    defer std.testing.allocator.free(exit_codes);

    // Verify all processes succeeded
    const all_succeeded = test_mp.ProcessController.allSucceeded(exit_codes);

    if (!all_succeeded) {
        std.debug.print("Exit codes: ", .{});
        for (exit_codes, 0..) |code, j| {
            std.debug.print("{d} ", .{code});
            if (code != 0) {
                std.debug.print("(Process {d} failed) ", .{j});
            }
        }
        std.debug.print("\n", .{});
    }

    try std.testing.expect(all_succeeded);

    // Verify state file is still intact after concurrent reads
    const still_all_found = try test_mp.verifyStringsInStateFile(
        std.testing.allocator,
        test_state_path,
        test_strings_list.items,
    );
    try std.testing.expect(still_all_found);

    std.debug.print("Phase 4.5: All 5 reader processes succeeded, state file intact ✓\n", .{});
}

test "Phase 4.5: concurrent readers + 1 writer" {
    const test_state_path = "test_state_readers_writer.frog";

    // Clean up
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create state file with 50 initial strings
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        512,
    );
    defer state_file.deinit();

    var initial_strings = std.ArrayList([]const u8){};
    defer initial_strings.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const str = try std.fmt.allocPrint(std.testing.allocator, "initial_{d}", .{i});
        try initial_strings.append(std.testing.allocator, str);
    }
    defer {
        for (initial_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    try state_file.populate(initial_strings.items);

    // Verify initial state
    const all_found = try test_mp.verifyStringsInStateFile(
        std.testing.allocator,
        test_state_path,
        initial_strings.items,
    );
    try std.testing.expect(all_found);

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    const exe_path = "zig-out\\bin\\fcmd.exe";

    // Spawn 4 reader processes searching for different initial strings
    const reader_indices = [_]usize{ 5, 15, 25, 40 };

    for (reader_indices) |idx| {
        const search_str = initial_strings.items[idx];

        const args = [_][]const u8{
            exe_path,
            "--test-mp",
            "search",
            test_state_path,
            search_str,
        };

        try controller.spawn(&args);
    }

    // Spawn 1 writer process that inserts 10 new strings
    i = 0;
    while (i < 10) : (i += 1) {
        const new_str = try std.fmt.allocPrint(std.testing.allocator, "new_{d}", .{i});
        defer std.testing.allocator.free(new_str);

        const args = [_][]const u8{
            exe_path,
            "--test-mp",
            "insert",
            test_state_path,
            new_str,
        };

        try controller.spawn(&args);
    }

    std.debug.print("Phase 4.5: Spawned 4 readers + 10 writer operations, waiting...\n", .{});

    // Wait for all processes
    const exit_codes = try controller.waitAll();
    defer std.testing.allocator.free(exit_codes);

    const all_succeeded = test_mp.ProcessController.allSucceeded(exit_codes);

    if (!all_succeeded) {
        std.debug.print("Exit codes: ", .{});
        for (exit_codes, 0..) |code, j| {
            std.debug.print("{d} ", .{code});
            if (code != 0) {
                std.debug.print("(Process {d} failed) ", .{j});
            }
        }
        std.debug.print("\n", .{});
    }

    try std.testing.expect(all_succeeded);

    // Verify all original strings still findable
    const originals_intact = try test_mp.verifyStringsInStateFile(
        std.testing.allocator,
        test_state_path,
        initial_strings.items,
    );
    try std.testing.expect(originals_intact);

    // Verify all new strings are present
    var new_strings = std.ArrayList([]const u8){};
    defer new_strings.deinit(std.testing.allocator);

    i = 0;
    while (i < 10) : (i += 1) {
        const str = try std.fmt.allocPrint(std.testing.allocator, "new_{d}", .{i});
        try new_strings.append(std.testing.allocator, str);
    }
    defer {
        for (new_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    const new_found = try test_mp.verifyStringsInStateFile(
        std.testing.allocator,
        test_state_path,
        new_strings.items,
    );
    try std.testing.expect(new_found);

    std.debug.print("Phase 4.5: Readers + writer test passed, all 60 strings present ✓\n", .{});
}

test "Phase 4.5: multiple writers - semaphore stress test" {
    const test_state_path = "test_state_multi_writer.frog";

    // Clean up
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create empty state file
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        512 * 16,
    );
    defer state_file.deinit();

    // Start with empty trie
    const initial_strings: []const []const u8 = &.{};
    try state_file.populate(initial_strings);

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    const exe_path = "zig-out\\bin\\fcmd.exe";

    // Spawn 8 writer processes, each inserting 60 unique strings
    // Writer 0: writer0_0 ... writer0_59
    // Writer 1: writer1_0 ... writer1_59
    // ...
    // Writer 7: writer7_0 ... writer7_59
    const num_writers = 8;
    const strings_per_writer = 60;

    var writer_id: usize = 0;
    while (writer_id < num_writers) : (writer_id += 1) {
        var str_id: usize = 0;
        while (str_id < strings_per_writer) : (str_id += 1) {
            const new_str = try std.fmt.allocPrint(
                std.testing.allocator,
                "writer{d}_{d}",
                .{ writer_id, str_id },
            );
            defer std.testing.allocator.free(new_str);

            const args = [_][]const u8{
                exe_path,
                "--test-mp",
                "insert",
                test_state_path,
                new_str,
            };

            try controller.spawn(&args);
        }
    }

    std.debug.print("Phase 4.5: Spawned {d} writer processes ({d} inserts total), waiting...\n", .{ num_writers * strings_per_writer, num_writers * strings_per_writer });

    // Wait for all processes
    const exit_codes = try controller.waitAll();
    defer std.testing.allocator.free(exit_codes);

    const all_succeeded = test_mp.ProcessController.allSucceeded(exit_codes);

    if (!all_succeeded) {
        std.debug.print("Exit codes summary: ", .{});
        var failures: usize = 0;
        for (exit_codes) |code| {
            if (code != 0) failures += 1;
        }
        std.debug.print("{d}/{d} failed\n", .{ failures, exit_codes.len });
    }

    try std.testing.expect(all_succeeded);

    // Verify all strings (8 writers × 60 strings) are present
    var all_strings = std.ArrayList([]const u8){};
    defer all_strings.deinit(std.testing.allocator);

    writer_id = 0;
    while (writer_id < num_writers) : (writer_id += 1) {
        var str_id: usize = 0;
        while (str_id < strings_per_writer) : (str_id += 1) {
            const str = try std.fmt.allocPrint(
                std.testing.allocator,
                "writer{d}_{d}",
                .{ writer_id, str_id },
            );
            try all_strings.append(std.testing.allocator, str);
        }
    }
    defer {
        for (all_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    const all_found = try test_mp.verifyStringsInStateFile(
        std.testing.allocator,
        test_state_path,
        all_strings.items,
    );
    try std.testing.expect(all_found);

    std.debug.print("Phase 4.5: Multiple writers test passed, all {d} strings present ✓\n", .{all_strings.items.len});
}

test "Phase 4: CLI test mode - insert operation" {
    const test_state_path = "test_state_cli_insert.frog";

    // Clean up
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create empty state file
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        256,
    );
    defer state_file.deinit();

    // Initially empty
    const initial_strings: []const []const u8 = &.{};
    try state_file.populate(initial_strings);

    // Now test that we could spawn a process to insert
    // fcmd --test-mp insert test_state_cli_insert.frog "new command"
    // For now, just verify the file exists and is ready

    const file_exists = blk: {
        const f = std.fs.cwd().openFile(test_state_path, .{}) catch break :blk false;
        f.close();
        break :blk true;
    };
    try std.testing.expect(file_exists);

    std.debug.print("Phase 4: CLI test mode infrastructure ready for process spawning\n", .{});
}
