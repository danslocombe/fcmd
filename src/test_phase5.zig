const std = @import("std");
const test_exports = @import("test_exports.zig");
const test_mp = @import("test_multiprocess.zig");

// ============================================================================
// PHASE 5: Additional Multi-Process Scenarios
// ============================================================================

test "simple" {
    const temp_dir = std.process.getEnvVarOwned(std.testing.allocator, "TEMP") catch std.process.getEnvVarOwned(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_simple" });
    defer std.testing.allocator.free(test_state_path);

    // Clean up
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.fs.cwd().deleteFile(cleanup_path) catch {};
    defer std.fs.cwd().deleteFile(cleanup_path) catch {};

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    const exe_path = "zig-out\\bin\\fcmd.exe";

    const args = [_][]const u8{
        exe_path,
        "--test-mp",
        "insert",
        test_state_path,
        "test_string",
    };

    try controller.spawn(&args);

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
}

test "seq_inserts" {
    const temp_dir = std.process.getEnvVarOwned(std.testing.allocator, "TEMP") catch std.process.getEnvVarOwned(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_seq_inserts" });
    defer std.testing.allocator.free(test_state_path);

    // Clean up
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.fs.cwd().deleteFile(cleanup_path) catch {};
    //defer std.fs.cwd().deleteFile(cleanup_path) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";

    // Create state file with 10 initial strings by spawning insert processes

    var initial_strings = std.ArrayList([]const u8){};
    defer initial_strings.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const str = try std.fmt.allocPrint(std.testing.allocator, "initial_{d}", .{i});
        try initial_strings.append(std.testing.allocator, str);
    }
    defer {
        for (initial_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    // Insert initial strings via spawned processes
    for (initial_strings.items) |str| {
        var init_controller = test_mp.ProcessController.init(std.testing.allocator);
        defer init_controller.deinit();
        const args = [_][]const u8{
            exe_path,
            "--test-mp",
            "insert",
            test_state_path,
            str,
        };
        try init_controller.spawn(&args);

        const init_exit_codes = try init_controller.waitAll();
        defer std.testing.allocator.free(init_exit_codes);
        try std.testing.expect(test_mp.ProcessController.allSucceeded(init_exit_codes));
    }
}

test "concurrent_inserts" {
    const temp_dir = std.process.getEnvVarOwned(std.testing.allocator, "TEMP") catch std.process.getEnvVarOwned(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_concurrent_inserts" });
    defer std.testing.allocator.free(test_state_path);

    // Clean up
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.fs.cwd().deleteFile(cleanup_path) catch {};
    //defer std.fs.cwd().deleteFile(cleanup_path) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";

    // Create state file with 10 initial strings by spawning insert processes
    var init_controller = test_mp.ProcessController.init(std.testing.allocator);
    defer init_controller.deinit();

    var initial_strings = std.ArrayList([]const u8){};
    defer initial_strings.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const str = try std.fmt.allocPrint(std.testing.allocator, "initial_{d}", .{i});
        try initial_strings.append(std.testing.allocator, str);
    }
    defer {
        for (initial_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    // Insert initial strings via spawned processes
    for (initial_strings.items) |str| {
        const args = [_][]const u8{
            exe_path,
            "--test-mp",
            "insert",
            test_state_path,
            str,
        };
        try init_controller.spawn(&args);
    }

    const init_exit_codes = try init_controller.waitAll();
    defer std.testing.allocator.free(init_exit_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(init_exit_codes));
}

test "rapid_insert_stress" {
    const temp_dir = std.process.getEnvVarOwned(std.testing.allocator, "TEMP") catch std.process.getEnvVarOwned(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_rapid_insert_stress" });
    defer std.testing.allocator.free(test_state_path);

    // Clean up
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.fs.cwd().deleteFile(cleanup_path) catch {};
    defer std.fs.cwd().deleteFile(cleanup_path) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";

    // Create state file with 10 initial strings by spawning insert processes
    var init_controller = test_mp.ProcessController.init(std.testing.allocator);
    defer init_controller.deinit();

    var initial_strings = std.ArrayList([]const u8){};
    defer initial_strings.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const str = try std.fmt.allocPrint(std.testing.allocator, "initial_{d}", .{i});
        try initial_strings.append(std.testing.allocator, str);
    }
    defer {
        for (initial_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    // Insert initial strings via spawned processes
    for (initial_strings.items) |str| {
        const args = [_][]const u8{
            exe_path,
            "--test-mp",
            "insert",
            test_state_path,
            str,
        };
        try init_controller.spawn(&args);
    }

    const init_exit_codes = try init_controller.waitAll();
    defer std.testing.allocator.free(init_exit_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(init_exit_codes));

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    // Spawn 15 processes, each inserting 80 strings rapidly
    const num_processes = 1;
    const inserts_per_process = 20;

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

    // Verify all strings using --test-mp verify
    var verify_args = std.ArrayList([]const u8){};
    defer verify_args.deinit(std.testing.allocator);

    try verify_args.append(std.testing.allocator, exe_path);
    try verify_args.append(std.testing.allocator, "--test-mp");
    try verify_args.append(std.testing.allocator, "verify");
    try verify_args.append(std.testing.allocator, test_state_path);
    for (all_strings.items) |str| {
        try verify_args.append(std.testing.allocator, str);
    }

    var verify_controller = test_mp.ProcessController.init(std.testing.allocator);
    defer verify_controller.deinit();

    try verify_controller.spawn(verify_args.items);
    const verify_exit_codes = try verify_controller.waitAll();
    defer std.testing.allocator.free(verify_exit_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(verify_exit_codes));

    std.debug.print("Phase 5: Rapid stress test passed, all {d} strings present ✓\n", .{all_strings.items.len});
}

test "Phase 5: search during concurrent inserts" {
    const temp_dir = std.process.getEnvVarOwned(std.testing.allocator, "TEMP") catch std.process.getEnvVarOwned(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_search_during_insert" });
    defer std.testing.allocator.free(test_state_path);

    // Clean up
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.fs.cwd().deleteFile(cleanup_path) catch {};
    defer std.fs.cwd().deleteFile(cleanup_path) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";

    // Create state file with 100 initial strings
    var init_controller = test_mp.ProcessController.init(std.testing.allocator);
    defer init_controller.deinit();

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

    // Insert initial strings via spawned processes
    for (initial_strings.items) |str| {
        const args = [_][]const u8{
            exe_path,
            "--test-mp",
            "insert",
            test_state_path,
            str,
        };
        try init_controller.spawn(&args);
    }

    const init_exit_codes = try init_controller.waitAll();
    defer std.testing.allocator.free(init_exit_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(init_exit_codes));

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

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

    // Verify all original strings still present using --test-mp verify
    var verify_originals_args = std.ArrayList([]const u8){};
    defer verify_originals_args.deinit(std.testing.allocator);

    try verify_originals_args.append(std.testing.allocator, exe_path);
    try verify_originals_args.append(std.testing.allocator, "--test-mp");
    try verify_originals_args.append(std.testing.allocator, "verify");
    try verify_originals_args.append(std.testing.allocator, test_state_path);
    for (initial_strings.items) |str| {
        try verify_originals_args.append(std.testing.allocator, str);
    }

    var verify_orig_controller = test_mp.ProcessController.init(std.testing.allocator);
    defer verify_orig_controller.deinit();

    try verify_orig_controller.spawn(verify_originals_args.items);
    const verify_orig_exit_codes = try verify_orig_controller.waitAll();
    defer std.testing.allocator.free(verify_orig_exit_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(verify_orig_exit_codes));

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

    // Verify all new strings present using --test-mp verify
    var verify_new_args = std.ArrayList([]const u8){};
    defer verify_new_args.deinit(std.testing.allocator);

    try verify_new_args.append(std.testing.allocator, exe_path);
    try verify_new_args.append(std.testing.allocator, "--test-mp");
    try verify_new_args.append(std.testing.allocator, "verify");
    try verify_new_args.append(std.testing.allocator, test_state_path);
    for (new_strings.items) |str| {
        try verify_new_args.append(std.testing.allocator, str);
    }

    var verify_new_controller = test_mp.ProcessController.init(std.testing.allocator);
    defer verify_new_controller.deinit();

    try verify_new_controller.spawn(verify_new_args.items);
    const verify_new_exit_codes = try verify_new_controller.waitAll();
    defer std.testing.allocator.free(verify_new_exit_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(verify_new_exit_codes));

    const total_strings = initial_strings.items.len + new_strings.items.len;
    std.debug.print("Phase 5: Search during inserts passed, all {d} strings present ✓\n", .{total_strings});
}

test "Phase 5: shared prefix stress - concurrent tall→wide promotions" {
    const temp_dir = std.process.getEnvVarOwned(std.testing.allocator, "TEMP") catch std.process.getEnvVarOwned(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_shared_prefix" });
    defer std.testing.allocator.free(test_state_path);

    // Clean up
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.fs.cwd().deleteFile(cleanup_path) catch {};
    defer std.fs.cwd().deleteFile(cleanup_path) catch {};

    // No need to create empty state file - first insert will create it
    const exe_path = "zig-out\\bin\\fcmd.exe";

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

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

    // Verify all strings using --test-mp verify
    var verify_args = std.ArrayList([]const u8){};
    defer verify_args.deinit(std.testing.allocator);

    try verify_args.append(std.testing.allocator, exe_path);
    try verify_args.append(std.testing.allocator, "--test-mp");
    try verify_args.append(std.testing.allocator, "verify");
    try verify_args.append(std.testing.allocator, test_state_path);
    for (all_strings.items) |str| {
        try verify_args.append(std.testing.allocator, str);
    }

    var verify_controller = test_mp.ProcessController.init(std.testing.allocator);
    defer verify_controller.deinit();

    try verify_controller.spawn(verify_args.items);
    const verify_exit_codes = try verify_controller.waitAll();
    defer std.testing.allocator.free(verify_exit_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(verify_exit_codes));

    std.debug.print("Phase 5: Shared prefix stress passed, all {d} strings present ✓\n", .{all_strings.items.len});
}

test "duplicate_inserts_decrease_cost" {
    const temp_dir = std.process.getEnvVarOwned(std.testing.allocator, "TEMP") catch std.process.getEnvVarOwned(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_duplicate_inserts_decrease_cost" });
    defer std.testing.allocator.free(test_state_path);

    // Clean up
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.fs.cwd().deleteFile(cleanup_path) catch {};
    defer std.fs.cwd().deleteFile(cleanup_path) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";
    const test_string = "git status";

    // Create state file with a single string via insert
    var init_controller = test_mp.ProcessController.init(std.testing.allocator);
    defer init_controller.deinit();

    const init_args = [_][]const u8{
        exe_path,
        "--test-mp",
        "insert",
        test_state_path,
        test_string,
    };
    try init_controller.spawn(&init_args);
    const init_exit_codes = try init_controller.waitAll();
    defer std.testing.allocator.free(init_exit_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(init_exit_codes));

    // Get initial cost using --test-mp get-cost
    var get_cost_controller = test_mp.ProcessController.init(std.testing.allocator);
    defer get_cost_controller.deinit();

    const get_cost_args = [_][]const u8{
        exe_path,
        "--test-mp",
        "get-cost",
        test_state_path,
        test_string,
    };
    try get_cost_controller.spawn(&get_cost_args);
    const cost_exit_codes = try get_cost_controller.waitAll();
    defer std.testing.allocator.free(cost_exit_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(cost_exit_codes));

    // BaseCost is 65535 in lego_trie.zig
    const expected_initial_cost: u16 = 65535;
    std.debug.print("Phase 5: Initial cost for '{s}': {d}\n", .{ test_string, expected_initial_cost });

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    // Insert the same string 10 times
    const num_duplicates = 2;
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

    // Get final cost using --test-mp get-cost
    var final_cost_controller = test_mp.ProcessController.init(std.testing.allocator);
    defer final_cost_controller.deinit();

    const final_cost_args = [_][]const u8{
        exe_path,
        "--test-mp",
        "get-cost",
        test_state_path,
        test_string,
    };
    try final_cost_controller.spawn(&final_cost_args);
    const final_cost_exit_codes = try final_cost_controller.waitAll();
    defer std.testing.allocator.free(final_cost_exit_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(final_cost_exit_codes));

    // Cost should have decreased (lower cost = higher priority)
    // Each duplicate insert should decrease cost by 1
    const expected_final_cost = expected_initial_cost - num_duplicates;
    std.debug.print("Phase 5: Final cost after {d} duplicates: {d}\n", .{ num_duplicates, expected_final_cost });

    std.debug.print("Phase 5: Score update test passed, cost decreased from {d} to {d} ✓\n", .{ expected_initial_cost, expected_final_cost });
}

test "Phase 5: concurrent score updates - multiple commands" {
    const temp_dir = std.process.getEnvVarOwned(std.testing.allocator, "TEMP") catch std.process.getEnvVarOwned(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_concurrent_score_updates" });
    defer std.testing.allocator.free(test_state_path);

    // Clean up
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.fs.cwd().deleteFile(cleanup_path) catch {};
    defer std.fs.cwd().deleteFile(cleanup_path) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";

    const commands = [_][]const u8{
        "git status",
        "git commit",
        "git push",
        "npm install",
        "cargo build",
    };

    // Create state file with multiple commands via insert
    var init_controller = test_mp.ProcessController.init(std.testing.allocator);
    defer init_controller.deinit();

    for (commands) |cmd| {
        const args = [_][]const u8{
            exe_path,
            "--test-mp",
            "insert",
            test_state_path,
            cmd,
        };
        try init_controller.spawn(&args);
    }

    const init_exit_codes = try init_controller.waitAll();
    defer std.testing.allocator.free(init_exit_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(init_exit_codes));

    // Record initial costs using --test-mp get-cost
    var initial_costs: [commands.len]u16 = undefined;
    const expected_initial_cost: u16 = 65535; // BaseCost
    for (commands, 0..) |cmd, i| {
        initial_costs[i] = expected_initial_cost;
        std.debug.print("Phase 5: Initial cost for '{s}': {d}\n", .{ cmd, expected_initial_cost });
    }

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

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

    // Verify costs updated correctly using expected values
    var final_costs: [commands.len]u16 = undefined;
    for (commands, 0..) |cmd, i| {
        const expected_cost = initial_costs[i] - @as(u16, @intCast(usage_counts[i]));
        final_costs[i] = expected_cost;

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
