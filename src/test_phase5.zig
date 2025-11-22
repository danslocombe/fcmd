const std = @import("std");
const test_exports = @import("test_exports.zig");
const test_mp = @import("test_multiprocess.zig");

// ============================================================================
// PHASE 5: Additional Multi-Process Scenarios
// ============================================================================

test "Phase 5: rapid insert stress - 15 processes × 80 inserts" {
    const test_state_path = "test_state_rapid_stress.frog";

    // Clean up
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create state file with 10 initial strings
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        4096, // Need larger capacity for 2000+ strings
    );
    defer state_file.deinit();

    var initial_strings = std.ArrayList([]const u8){};
    defer initial_strings.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const str = try std.fmt.allocPrint(std.testing.allocator, "initial_{d}", .{i});
        try initial_strings.append(std.testing.allocator, str);
    }
    defer {
        for (initial_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    try state_file.populate(initial_strings.items);

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    const exe_path = "zig-out\\bin\\fcmd.exe";

    // Spawn 15 processes, each inserting 80 strings rapidly
    const num_processes = 15;
    const inserts_per_process = 80;

    var proc_id: usize = 0;
    while (proc_id < num_processes) : (proc_id += 1) {
        var insert_id: usize = 0;
        while (insert_id < inserts_per_process) : (insert_id += 1) {
            const new_str = try std.fmt.allocPrint(
                std.testing.allocator,
                "process{d}_insert{d}",
                .{ proc_id, insert_id },
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

    const total_inserts = num_processes * inserts_per_process;
    std.debug.print("Phase 5: Spawned {d} rapid insert operations...\n", .{total_inserts});

    // Wait for all processes
    const exit_codes = try controller.waitAll();
    defer std.testing.allocator.free(exit_codes);

    const all_succeeded = test_mp.ProcessController.allSucceeded(exit_codes);

    if (!all_succeeded) {
        var failures: usize = 0;
        for (exit_codes) |code| {
            if (code != 0) failures += 1;
        }
        std.debug.print("Failures: {d}/{d}\n", .{ failures, exit_codes.len });
    }

    try std.testing.expect(all_succeeded);

    // Verify all strings present: 10 initial + inserts
    var all_strings = std.ArrayList([]const u8){};
    defer all_strings.deinit(std.testing.allocator);

    // Add initial strings
    for (initial_strings.items) |str| {
        const copy = try std.testing.allocator.dupe(u8, str);
        try all_strings.append(std.testing.allocator, copy);
    }

    // Add inserted strings
    proc_id = 0;
    while (proc_id < num_processes) : (proc_id += 1) {
        var insert_id: usize = 0;
        while (insert_id < inserts_per_process) : (insert_id += 1) {
            const str = try std.fmt.allocPrint(
                std.testing.allocator,
                "process{d}_insert{d}",
                .{ proc_id, insert_id },
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

    std.debug.print("Phase 5: Rapid stress test passed, all {d} strings present ✓\n", .{all_strings.items.len});
}

test "Phase 5: search during concurrent inserts" {
    const test_state_path = "test_state_search_during_insert.frog";

    // Clean up
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create state file with 100 initial strings
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        1024,
    );
    defer state_file.deinit();

    var initial_strings = std.ArrayList([]const u8){};
    defer initial_strings.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const str = try std.fmt.allocPrint(std.testing.allocator, "original_{d}", .{i});
        try initial_strings.append(std.testing.allocator, str);
    }
    defer {
        for (initial_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    try state_file.populate(initial_strings.items);

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    const exe_path = "zig-out\\bin\\fcmd.exe";

    // Spawn 3 reader processes searching for original strings
    const search_indices = [_]usize{ 10, 40, 70 };
    for (search_indices) |idx| {
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

    // Spawn 3 writer processes inserting new strings
    const num_writers = 3;
    const inserts_per_writer = 20;

    var writer_id: usize = 0;
    while (writer_id < num_writers) : (writer_id += 1) {
        var insert_id: usize = 0;
        while (insert_id < inserts_per_writer) : (insert_id += 1) {
            const new_str = try std.fmt.allocPrint(
                std.testing.allocator,
                "new_writer{d}_{d}",
                .{ writer_id, insert_id },
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

    std.debug.print("Phase 5: Spawned {d} readers + {d} writers, waiting...\n", .{ search_indices.len, num_writers * inserts_per_writer });

    // Wait for all processes
    const exit_codes = try controller.waitAll();
    defer std.testing.allocator.free(exit_codes);

    const all_succeeded = test_mp.ProcessController.allSucceeded(exit_codes);

    if (!all_succeeded) {
        var failures: usize = 0;
        for (exit_codes) |code| {
            if (code != 0) failures += 1;
        }
        std.debug.print("Failures: {d}/{d}\n", .{ failures, exit_codes.len });
    }

    try std.testing.expect(all_succeeded);

    // Verify all original strings still present
    const originals_intact = try test_mp.verifyStringsInStateFile(
        std.testing.allocator,
        test_state_path,
        initial_strings.items,
    );
    try std.testing.expect(originals_intact);

    // Verify all new strings present
    var new_strings = std.ArrayList([]const u8){};
    defer new_strings.deinit(std.testing.allocator);

    writer_id = 0;
    while (writer_id < num_writers) : (writer_id += 1) {
        var insert_id: usize = 0;
        while (insert_id < inserts_per_writer) : (insert_id += 1) {
            const str = try std.fmt.allocPrint(
                std.testing.allocator,
                "new_writer{d}_{d}",
                .{ writer_id, insert_id },
            );
            try new_strings.append(std.testing.allocator, str);
        }
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

    const total_strings = initial_strings.items.len + new_strings.items.len;
    std.debug.print("Phase 5: Search during inserts passed, all {d} strings present ✓\n", .{total_strings});
}

test "Phase 5: shared prefix stress - concurrent tall→wide promotions" {
    const test_state_path = "test_state_shared_prefix.frog";

    // Clean up
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create empty state file
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        1024,
    );
    defer state_file.deinit();

    const initial_strings: []const []const u8 = &.{};
    try state_file.populate(initial_strings);

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    const exe_path = "zig-out\\bin\\fcmd.exe";

    // Spawn 4 processes inserting strings with common prefixes
    // This will cause tall→wide promotions under concurrent access
    const common_prefix = "SHARED_PREFIX_TESTING_";
    const num_processes = 4;
    const inserts_per_process = 15;

    var proc_id: usize = 0;
    while (proc_id < num_processes) : (proc_id += 1) {
        var insert_id: usize = 0;
        while (insert_id < inserts_per_process) : (insert_id += 1) {
            const new_str = try std.fmt.allocPrint(
                std.testing.allocator,
                "{s}proc{d}_item{d}",
                .{ common_prefix, proc_id, insert_id },
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

    const total_inserts = num_processes * inserts_per_process;
    std.debug.print("Phase 5: Spawned {d} inserts with shared prefix...\n", .{total_inserts});

    // Wait for all processes
    const exit_codes = try controller.waitAll();
    defer std.testing.allocator.free(exit_codes);

    const all_succeeded = test_mp.ProcessController.allSucceeded(exit_codes);

    if (!all_succeeded) {
        var failures: usize = 0;
        for (exit_codes) |code| {
            if (code != 0) failures += 1;
        }
        std.debug.print("Failures: {d}/{d}\n", .{ failures, exit_codes.len });
    }

    try std.testing.expect(all_succeeded);

    // Verify all strings with shared prefix are present
    var all_strings = std.ArrayList([]const u8){};
    defer all_strings.deinit(std.testing.allocator);

    proc_id = 0;
    while (proc_id < num_processes) : (proc_id += 1) {
        var insert_id: usize = 0;
        while (insert_id < inserts_per_process) : (insert_id += 1) {
            const str = try std.fmt.allocPrint(
                std.testing.allocator,
                "{s}proc{d}_item{d}",
                .{ common_prefix, proc_id, insert_id },
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

    std.debug.print("Phase 5: Shared prefix stress passed, all {d} strings present ✓\n", .{all_strings.items.len});
}

test "Phase 5: score updates - duplicate inserts decrease cost" {
    const test_state_path = "test_state_score_updates.frog";

    // Clean up
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create state file with a single string
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        256,
    );
    defer state_file.deinit();

    const test_string = "git status";
    const initial_strings = [_][]const u8{test_string};
    try state_file.populate(&initial_strings);

    // Get initial cost (should be BaseCost = 65535 for new insertion)
    const initial_cost = try test_mp.getStringCost(
        std.testing.allocator,
        test_state_path,
        test_string,
    );
    try std.testing.expect(initial_cost != null);

    // BaseCost is 65535 in lego_trie.zig
    const expected_initial_cost: u16 = 65535;
    try std.testing.expectEqual(expected_initial_cost, initial_cost.?);

    std.debug.print("Phase 5: Initial cost for '{s}': {d}\n", .{ test_string, initial_cost.? });

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    const exe_path = "zig-out\\bin\\fcmd.exe";

    // Insert the same string 10 times
    const num_duplicates = 10;
    var i: usize = 0;
    while (i < num_duplicates) : (i += 1) {
        const args = [_][]const u8{
            exe_path,
            "--test-mp",
            "insert",
            test_state_path,
            test_string,
        };

        try controller.spawn(&args);
    }

    std.debug.print("Phase 5: Spawned {d} duplicate inserts...\n", .{num_duplicates});

    // Wait for all processes
    const exit_codes = try controller.waitAll();
    defer std.testing.allocator.free(exit_codes);

    const all_succeeded = test_mp.ProcessController.allSucceeded(exit_codes);
    try std.testing.expect(all_succeeded);

    // Get final cost - should be lower (each duplicate insert decreases cost by 1)
    const final_cost = try test_mp.getStringCost(
        std.testing.allocator,
        test_state_path,
        test_string,
    );
    try std.testing.expect(final_cost != null);

    std.debug.print("Phase 5: Final cost after {d} duplicates: {d}\n", .{ num_duplicates, final_cost.? });

    // Cost should have decreased (lower cost = higher priority)
    // Each duplicate insert should decrease cost by 1
    const expected_final_cost = expected_initial_cost - num_duplicates;
    try std.testing.expectEqual(expected_final_cost, final_cost.?);

    // Verify cost decreased
    try std.testing.expect(final_cost.? < initial_cost.?);

    std.debug.print("Phase 5: Score update test passed, cost decreased from {d} to {d} ✓\n", .{ initial_cost.?, final_cost.? });
}

test "Phase 5: concurrent score updates - multiple commands" {
    const test_state_path = "test_state_concurrent_scores.frog";

    // Clean up
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create state file with multiple commands
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        512,
    );
    defer state_file.deinit();

    const commands = [_][]const u8{
        "git status",
        "git commit",
        "git push",
        "npm install",
        "cargo build",
    };
    try state_file.populate(&commands);

    // Record initial costs
    var initial_costs: [commands.len]u16 = undefined;
    for (commands, 0..) |cmd, i| {
        const cost = try test_mp.getStringCost(
            std.testing.allocator,
            test_state_path,
            cmd,
        );
        try std.testing.expect(cost != null);
        initial_costs[i] = cost.?;
        std.debug.print("Phase 5: Initial cost for '{s}': {d}\n", .{ cmd, cost.? });
    }

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    const exe_path = "zig-out\\bin\\fcmd.exe";

    // Simulate different usage patterns:
    // "git status" - used 20 times (should have lowest cost = highest priority)
    // "git commit" - used 10 times
    // "git push" - used 5 times
    // "npm install" - used 2 times
    // "cargo build" - used 1 time (should have highest cost = lowest priority)

    const usage_counts = [_]usize{ 20, 10, 5, 2, 1 };

    for (commands, usage_counts) |cmd, count| {
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const args = [_][]const u8{
                exe_path,
                "--test-mp",
                "insert",
                test_state_path,
                cmd,
            };

            try controller.spawn(&args);
        }
    }

    const total_inserts = 20 + 10 + 5 + 2 + 1;
    std.debug.print("Phase 5: Spawned {d} inserts with varying frequencies...\n", .{total_inserts});

    // Wait for all processes
    const exit_codes = try controller.waitAll();
    defer std.testing.allocator.free(exit_codes);

    const all_succeeded = test_mp.ProcessController.allSucceeded(exit_codes);
    try std.testing.expect(all_succeeded);

    // Verify costs updated correctly
    var final_costs: [commands.len]u16 = undefined;
    for (commands, 0..) |cmd, i| {
        const cost = try test_mp.getStringCost(
            std.testing.allocator,
            test_state_path,
            cmd,
        );
        try std.testing.expect(cost != null);
        final_costs[i] = cost.?;

        const expected_cost = initial_costs[i] - @as(u16, @intCast(usage_counts[i]));
        try std.testing.expectEqual(expected_cost, final_costs[i]);

        std.debug.print("Phase 5: '{s}' used {d} times, cost: {d} -> {d}\n", .{
            cmd,
            usage_counts[i],
            initial_costs[i],
            final_costs[i],
        });
    }

    // Verify ordering: most-used should have lowest cost
    try std.testing.expect(final_costs[0] < final_costs[1]); // git status < git commit
    try std.testing.expect(final_costs[1] < final_costs[2]); // git commit < git push
    try std.testing.expect(final_costs[2] < final_costs[3]); // git push < npm install
    try std.testing.expect(final_costs[3] < final_costs[4]); // npm install < cargo build

    std.debug.print("Phase 5: Concurrent score updates passed, all costs correct and properly ordered ✓\n", .{});
}
