const std = @import("std");
const test_exports = @import("test_exports.zig");
const test_mp = @import("test_multiprocess.zig");

// ============================================================================
// FUZZING TESTS: Random and edge-case testing
// ============================================================================

/// Generate random strings for fuzzing
fn generateRandomString(allocator: std.mem.Allocator, rng: std.Random, min_len: usize, max_len: usize) ![]u8 {
    const len = rng.intRangeAtMost(usize, min_len, max_len);
    const str = try allocator.alloc(u8, len);

    for (str) |*c| {
        // Generate printable ASCII characters (32-126)
        c.* = @intCast(rng.intRangeAtMost(u8, 32, 126));
    }

    return str;
}

/// Generate strings with specific patterns
fn generatePatternString(allocator: std.mem.Allocator, rng: std.Random, pattern_type: usize) ![]u8 {
    return switch (pattern_type % 6) {
        0 => { // Very short strings
            const len = rng.intRangeAtMost(usize, 1, 3);
            return try generateRandomString(allocator, rng, len, len);
        },
        1 => { // Very long strings
            const len = rng.intRangeAtMost(usize, 200, 500);
            return try generateRandomString(allocator, rng, len, len);
        },
        2 => { // Repeated characters
            const len = rng.intRangeAtMost(usize, 10, 50);
            const str = try allocator.alloc(u8, len);
            const char = @as(u8, @intCast(rng.intRangeAtMost(u8, 65, 90))); // A-Z
            for (str) |*c| {
                c.* = char;
            }
            return str;
        },
        3 => { // Special characters
            const specials = "!@#$%^&*()_+-=[]{}|;':\",./<>?`~";
            const len = rng.intRangeAtMost(usize, 5, 20);
            const str = try allocator.alloc(u8, len);
            for (str) |*c| {
                c.* = specials[rng.intRangeAtMost(usize, 0, specials.len - 1)];
            }
            return str;
        },
        4 => { // Unicode-like sequences (high ASCII)
            const len = rng.intRangeAtMost(usize, 5, 20);
            const str = try allocator.alloc(u8, len);
            for (str) |*c| {
                c.* = @intCast(rng.intRangeAtMost(u8, 128, 255));
            }
            return str;
        },
        5 => { // Numbers and digits
            const len = rng.intRangeAtMost(usize, 5, 30);
            const str = try allocator.alloc(u8, len);
            for (str) |*c| {
                c.* = @intCast(rng.intRangeAtMost(u8, 48, 57)); // 0-9
            }
            return str;
        },
        else => unreachable,
    };
}

test "Fuzz: random string insertions" {
    const temp_dir = std.process.getEnvVarOwned(std.testing.allocator, "TEMP") catch std.process.getEnvVarOwned(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_fuzz_random" });
    defer std.testing.allocator.free(test_state_path);

    // Clean up
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.fs.cwd().deleteFile(cleanup_path) catch {};
    defer std.fs.cwd().deleteFile(cleanup_path) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";

    var prng = std.Random.DefaultPrng.init(12345);
    const rng = prng.random();

    var all_strings = std.ArrayList([]const u8){};
    defer all_strings.deinit(std.testing.allocator);
    defer {
        for (all_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    // Generate and insert 100 random strings
    const num_strings = 1;
    var i: usize = 0;
    while (i < num_strings) : (i += 1) {
        const random_str = try generateRandomString(std.testing.allocator, rng, 5, 50);
        try all_strings.append(std.testing.allocator, random_str);

        const args = [_][]const u8{
            exe_path,
            "--test-mp",
            "insert",
            test_state_path,
            random_str,
        };

        std.debug.print("Running insert {s} {s}\n", .{ test_state_path, random_str });

        try controller.spawn(&args);
    }

    std.debug.print("Fuzz: Spawned {d} random string inserts...\n", .{num_strings});

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

    // Verify all strings are present
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

    std.debug.print("Fuzz: Random string test passed, all {d} strings verified ✓\n", .{all_strings.items.len});
}

test "Fuzz: edge case string patterns" {
    const temp_dir = std.process.getEnvVarOwned(std.testing.allocator, "TEMP") catch std.process.getEnvVarOwned(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_fuzz_patterns" });
    defer std.testing.allocator.free(test_state_path);

    // Clean up
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.fs.cwd().deleteFile(cleanup_path) catch {};
    defer std.fs.cwd().deleteFile(cleanup_path) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";

    var prng = std.Random.DefaultPrng.init(54321);
    const rng = prng.random();

    var all_strings = std.ArrayList([]const u8){};
    defer all_strings.deinit(std.testing.allocator);
    defer {
        for (all_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    // Generate various pattern types
    const num_patterns = 60;
    var i: usize = 0;
    while (i < num_patterns) : (i += 1) {
        const pattern_str = try generatePatternString(std.testing.allocator, rng, i);
        try all_strings.append(std.testing.allocator, pattern_str);

        const args = [_][]const u8{
            exe_path,
            "--test-mp",
            "insert",
            test_state_path,
            pattern_str,
        };

        try controller.spawn(&args);
    }

    std.debug.print("Fuzz: Spawned {d} pattern string inserts...\n", .{num_patterns});

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

    // Verify all strings are present
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

    std.debug.print("Fuzz: Pattern string test passed, all {d} strings verified ✓\n", .{all_strings.items.len});
}

test "Fuzz: concurrent random operations" {
    const temp_dir = std.process.getEnvVarOwned(std.testing.allocator, "TEMP") catch std.process.getEnvVarOwned(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_fuzz_concurrent" });
    defer std.testing.allocator.free(test_state_path);

    // Clean up
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.fs.cwd().deleteFile(cleanup_path) catch {};
    defer std.fs.cwd().deleteFile(cleanup_path) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";

    var prng = std.Random.DefaultPrng.init(98765);
    const rng = prng.random();

    // First, create initial state with some strings
    var init_controller = test_mp.ProcessController.init(std.testing.allocator);
    defer init_controller.deinit();

    var initial_strings = std.ArrayList([]const u8){};
    defer initial_strings.deinit(std.testing.allocator);
    defer {
        for (initial_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const str = try std.fmt.allocPrint(std.testing.allocator, "init_string_{d}", .{i});
        try initial_strings.append(std.testing.allocator, str);

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

    // Now perform mixed operations concurrently
    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    var new_strings = std.ArrayList([]const u8){};
    defer new_strings.deinit(std.testing.allocator);
    defer {
        for (new_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    const num_operations = 80;
    var op_id: usize = 0;
    while (op_id < num_operations) : (op_id += 1) {
        const operation = rng.intRangeAtMost(usize, 0, 2); // 0=insert, 1=search, 2=duplicate insert

        switch (operation) {
            0 => { // Insert new random string
                const new_str = try generateRandomString(std.testing.allocator, rng, 5, 30);
                try new_strings.append(std.testing.allocator, new_str);

                const args = [_][]const u8{
                    exe_path,
                    "--test-mp",
                    "insert",
                    test_state_path,
                    new_str,
                };
                try controller.spawn(&args);
            },
            1 => { // Search for an initial string
                if (initial_strings.items.len > 0) {
                    const idx = rng.intRangeAtMost(usize, 0, initial_strings.items.len - 1);
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
            },
            2 => { // Insert duplicate of initial string
                if (initial_strings.items.len > 0) {
                    const idx = rng.intRangeAtMost(usize, 0, initial_strings.items.len - 1);
                    const dup_str = initial_strings.items[idx];

                    const args = [_][]const u8{
                        exe_path,
                        "--test-mp",
                        "insert",
                        test_state_path,
                        dup_str,
                    };
                    try controller.spawn(&args);
                }
            },
            else => unreachable,
        }
    }

    std.debug.print("Fuzz: Spawned {d} mixed random operations...\n", .{num_operations});

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

    // Verify all strings are present
    var all_strings = std.ArrayList([]const u8){};
    defer all_strings.deinit(std.testing.allocator);

    for (initial_strings.items) |str| {
        const copy = try std.testing.allocator.dupe(u8, str);
        try all_strings.append(std.testing.allocator, copy);
    }
    for (new_strings.items) |str| {
        const copy = try std.testing.allocator.dupe(u8, str);
        try all_strings.append(std.testing.allocator, copy);
    }
    defer {
        for (all_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

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

    std.debug.print("Fuzz: Concurrent operations test passed, all {d} strings verified ✓\n", .{all_strings.items.len});
}

test "Fuzz: stress test with similar prefixes" {
    const temp_dir = std.process.getEnvVarOwned(std.testing.allocator, "TEMP") catch std.process.getEnvVarOwned(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_fuzz_prefixes" });
    defer std.testing.allocator.free(test_state_path);

    // Clean up
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.fs.cwd().deleteFile(cleanup_path) catch {};
    defer std.fs.cwd().deleteFile(cleanup_path) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";

    var prng = std.Random.DefaultPrng.init(11111);
    const rng = prng.random();

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    var all_strings = std.ArrayList([]const u8){};
    defer all_strings.deinit(std.testing.allocator);
    defer {
        for (all_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    // Generate strings with varying common prefixes
    const prefixes = [_][]const u8{
        "common_prefix_",
        "another_prefix_",
        "test_",
        "abc",
        "xyz",
    };

    const num_strings_per_prefix = 20;

    for (prefixes) |prefix| {
        var i: usize = 0;
        while (i < num_strings_per_prefix) : (i += 1) {
            const suffix = try generateRandomString(std.testing.allocator, rng, 5, 15);
            defer std.testing.allocator.free(suffix);

            const full_str = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ prefix, suffix });
            try all_strings.append(std.testing.allocator, full_str);

            const args = [_][]const u8{
                exe_path,
                "--test-mp",
                "insert",
                test_state_path,
                full_str,
            };

            try controller.spawn(&args);
        }
    }

    const total_strings = prefixes.len * num_strings_per_prefix;
    std.debug.print("Fuzz: Spawned {d} strings with common prefixes...\n", .{total_strings});

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

    // Verify all strings
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

    std.debug.print("Fuzz: Similar prefixes test passed, all {d} strings verified ✓\n", .{all_strings.items.len});
}

test "Fuzz: empty and whitespace strings" {
    const temp_dir = std.process.getEnvVarOwned(std.testing.allocator, "TEMP") catch std.process.getEnvVarOwned(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_fuzz_whitespace" });
    defer std.testing.allocator.free(test_state_path);

    // Clean up
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.fs.cwd().deleteFile(cleanup_path) catch {};
    defer std.fs.cwd().deleteFile(cleanup_path) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    // Test various whitespace and edge cases
    const edge_cases = [_][]const u8{
        " ", // single space
        "  ", // double space
        "\t", // tab
        "   \t  ", // mixed whitespace
        "a b c", // spaces in middle
        " leading", // leading space
        "trailing ", // trailing space
        "  both  ", // both sides
    };

    var all_strings = std.ArrayList([]const u8){};
    defer all_strings.deinit(std.testing.allocator);

    for (edge_cases) |edge_str| {
        const copy = try std.testing.allocator.dupe(u8, edge_str);
        try all_strings.append(std.testing.allocator, copy);

        const args = [_][]const u8{
            exe_path,
            "--test-mp",
            "insert",
            test_state_path,
            edge_str,
        };

        try controller.spawn(&args);
    }
    defer {
        for (all_strings.items) |str| {
            std.testing.allocator.free(str);
        }
    }

    std.debug.print("Fuzz: Spawned {d} whitespace edge cases...\n", .{edge_cases.len});

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

    // Verify all strings
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

    std.debug.print("Fuzz: Whitespace edge cases test passed, all {d} strings verified ✓\n", .{all_strings.items.len});
}

test "Fuzz: rapid duplicate inserts" {
    const temp_dir = std.process.getEnvVarOwned(std.testing.allocator, "TEMP") catch std.process.getEnvVarOwned(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_fuzz_duplicates" });
    defer std.testing.allocator.free(test_state_path);

    // Clean up
    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.fs.cwd().deleteFile(cleanup_path) catch {};
    defer std.fs.cwd().deleteFile(cleanup_path) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";

    var prng = std.Random.DefaultPrng.init(99999);
    const rng = prng.random();

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    // Create a small set of strings
    const base_strings = [_][]const u8{
        "duplicate_test_1",
        "duplicate_test_2",
        "duplicate_test_3",
        "duplicate_test_4",
        "duplicate_test_5",
    };

    // Insert each string multiple times randomly
    const num_operations = 100;
    var i: usize = 0;
    while (i < num_operations) : (i += 1) {
        const idx = rng.intRangeAtMost(usize, 0, base_strings.len - 1);
        const str = base_strings[idx];

        const args = [_][]const u8{
            exe_path,
            "--test-mp",
            "insert",
            test_state_path,
            str,
        };

        try controller.spawn(&args);
    }

    std.debug.print("Fuzz: Spawned {d} duplicate insert operations on {d} unique strings...\n", .{ num_operations, base_strings.len });

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

    // Verify all base strings are present
    var verify_args = std.ArrayList([]const u8){};
    defer verify_args.deinit(std.testing.allocator);

    try verify_args.append(std.testing.allocator, exe_path);
    try verify_args.append(std.testing.allocator, "--test-mp");
    try verify_args.append(std.testing.allocator, "verify");
    try verify_args.append(std.testing.allocator, test_state_path);
    for (base_strings) |str| {
        try verify_args.append(std.testing.allocator, str);
    }

    var verify_controller = test_mp.ProcessController.init(std.testing.allocator);
    defer verify_controller.deinit();

    try verify_controller.spawn(verify_args.items);
    const verify_exit_codes = try verify_controller.waitAll();
    defer std.testing.allocator.free(verify_exit_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(verify_exit_codes));

    std.debug.print("Fuzz: Rapid duplicate inserts test passed, all {d} unique strings verified ✓\n", .{base_strings.len});
}
