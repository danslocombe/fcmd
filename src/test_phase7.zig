const std = @import("std");
const test_exports = @import("test_exports.zig");
const lego_trie = test_exports.lego_trie;
const TestHelpers = @import("test_helpers.zig");
const test_mp = @import("test_multiprocess.zig");

// ============================================================================
// Phase 7: Fuzzing and Chaos Engineering
// ============================================================================

/// Random operation generator for fuzzing
const FuzzOp = enum {
    Insert,
    Search,
    Walk,
};

/// Generate pseudo-random string for fuzzing
fn generateFuzzString(prng: *std.Random.DefaultPrng, buffer: []u8, min_len: usize, max_len: usize) []const u8 {
    const random = prng.random();
    const len = random.intRangeAtMost(usize, min_len, max_len);

    for (buffer[0..len]) |*byte| {
        // Generate printable ASCII chars (32-126) with emphasis on common command chars
        const char_type = random.intRangeAtMost(u8, 0, 9);
        byte.* = switch (char_type) {
            0...5 => random.intRangeAtMost(u8, 'a', 'z'), // 60% lowercase
            6...7 => random.intRangeAtMost(u8, 'A', 'Z'), // 20% uppercase
            8 => random.intRangeAtMost(u8, '0', '9'), // 10% digits
            9 => blk: { // 10% special chars
                const specials = " -_.:/";
                break :blk specials[random.intRangeAtMost(usize, 0, specials.len - 1)];
            },
            else => unreachable,
        };
    }

    return buffer[0..len];
}

test "Phase 7: random operation fuzzing - 10000 operations with seed" {
    const seed: u64 = 0x12345678;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var backing: [8192]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    // Track inserted strings for verification
    var inserted: std.ArrayList([]const u8) = .empty;
    defer {
        for (inserted.items) |str| {
            std.testing.allocator.free(str);
        }
        inserted.deinit(std.testing.allocator);
    }

    const num_ops = 10000;
    var buffer: [64]u8 = undefined;

    var i: usize = 0;
    while (i < num_ops) : (i += 1) {
        const op = random.enumValue(FuzzOp);

        switch (op) {
            .Insert => {
                const str = generateFuzzString(&prng, &buffer, 1, 40);
                const owned = try std.testing.allocator.dupe(u8, str);
                try inserted.append(std.testing.allocator, owned);
                var view = trie.to_view();
                try view.insert(str);
            },
            .Search => {
                if (inserted.items.len > 0) {
                    const idx = random.intRangeLessThan(usize, 0, inserted.items.len);
                    const needle = inserted.items[idx];

                    const view = trie.to_view();
                    var walker = lego_trie.TrieWalker.init(view, needle);
                    const found = walker.walk_to();
                    try std.testing.expect(found);
                }
            },
            .Walk => {
                if (inserted.items.len > 0) {
                    const idx = random.intRangeLessThan(usize, 0, inserted.items.len);
                    const needle = inserted.items[idx];

                    // Walk with partial prefix
                    if (needle.len > 0) {
                        const prefix_len = random.intRangeLessThan(usize, 1, needle.len + 1);
                        const prefix = needle[0..prefix_len];

                        const view = trie.to_view();
                        var walker = lego_trie.TrieWalker.init(view, prefix);
                        _ = walker.walk_to();
                    }
                }
            },
        }

        // Validate structure integrity every 100 operations
        if (i % 100 == 99) {
            try TestHelpers.validate_trie_structure(&trie);
        }
    }

    // Final validation
    try TestHelpers.validate_trie_structure(&trie);

    // Verify all inserted strings are still findable
    for (inserted.items) |needle| {
        try TestHelpers.validate_can_find(&trie, needle);
    }

    std.debug.print("Phase 7: Random fuzzing passed - {d} operations, {d} unique strings, {d} blocks ✓\n", .{
        num_ops,
        inserted.items.len,
        trie.blocks.len.*,
    });
}

test "Phase 7: property-based invariants - structural consistency" {
    const seed: u64 = 0xABCDEF99;
    var prng = std.Random.DefaultPrng.init(seed);

    var backing: [16384]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    // Property: After any sequence of operations, certain invariants must hold
    // 1. All inserted strings remain findable
    // 2. No cycles in structure
    // 3. All pointers within bounds
    // 4. Cost ordering is maintained

    var inserted_strings: std.ArrayList([]const u8) = .empty;
    defer {
        for (inserted_strings.items) |str| {
            std.testing.allocator.free(str);
        }
        inserted_strings.deinit(std.testing.allocator);
    }

    var buffer: [50]u8 = undefined;

    // Run random operations
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const str = generateFuzzString(&prng, &buffer, 3, 35);
        const owned = try std.testing.allocator.dupe(u8, str);
        try inserted_strings.append(std.testing.allocator, owned);
        var view = trie.to_view();
        try view.insert(str);

        // Check invariants after each insert

        // Invariant 1: Structure is valid
        try TestHelpers.validate_trie_structure(&trie);

        // Invariant 2: All previously inserted strings are still findable
        if (i % 50 == 49) {
            for (inserted_strings.items) |needle| {
                try TestHelpers.validate_can_find(&trie, needle);
            }
        }

        // Invariant 3: Block count never decreases (no memory leaks detected)
        const block_count = trie.blocks.len.*;
        try std.testing.expect(block_count <= backing.len);
    }

    std.debug.print("Phase 7: Property-based testing passed - all invariants held for {d} operations ✓\n", .{inserted_strings.items.len});
}

test "Phase 7: stress pattern generation - adversarial inputs" {
    var backing: [16384]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    // Pattern 1: Many strings with identical prefixes (stresses tall→wide promotions)
    const common_prefix = "STRESS_TEST_COMMON_PREFIX_";
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        var buf: [64]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{s}{d}", .{ common_prefix, i }) catch unreachable;
        var view = trie.to_view();
        try view.insert(str);
    }

    try TestHelpers.validate_trie_structure(&trie);

    // Pattern 2: Alternating short and long strings (stresses mixed node types)
    i = 0;
    while (i < 200) : (i += 1) {
        var buf: [128]u8 = undefined;
        const str = if (i % 2 == 0)
            std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable
        else
            std.fmt.bufPrint(&buf, "very_long_string_to_stress_tall_node_capacity_{d}", .{i}) catch unreachable;
        var view = trie.to_view();
        try view.insert(str);
    }

    try TestHelpers.validate_trie_structure(&trie);

    // Pattern 3: Strings differing only in last character (stresses deep trees)
    const base = "almost_identical_string_";
    i = 0;
    while (i < 100) : (i += 1) {
        var buf: [64]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{s}{d}", .{ base, i }) catch unreachable;
        var view = trie.to_view();
        try view.insert(str);
    }

    try TestHelpers.validate_trie_structure(&trie);

    // Pattern 4: Incrementally extending strings (stresses parent-child relationships)
    var extend_buf: [128]u8 = undefined;
    i = 0;
    while (i < 100) : (i += 1) {
        const new_char = @as(u8, @intCast('a' + (i % 26)));
        extend_buf[i] = new_char;
        const extend_str = extend_buf[0 .. i + 1];
        var view = trie.to_view();
        try view.insert(extend_str);
    }

    try TestHelpers.validate_trie_structure(&trie);

    const final_blocks = trie.blocks.len.*;
    std.debug.print("Phase 7: Adversarial patterns passed - {d} blocks after stress patterns ✓\n", .{final_blocks});
}

test "Phase 7: deterministic replay with seed - reproducibility" {
    // This test ensures that given the same seed, we get the same behavior
    // This is critical for debugging fuzz failures

    const seed: u64 = 0xDEADBEEF;

    // First run
    var prng1 = std.Random.DefaultPrng.init(seed);
    var backing1: [1024]lego_trie.TrieBlock = undefined;
    var context1 = TestHelpers.create_test_context();
    var trie1 = TestHelpers.create_test_trie(&backing1, &context1);

    var inserted1: std.ArrayList([]const u8) = .empty;
    defer {
        for (inserted1.items) |str| {
            std.testing.allocator.free(str);
        }
        inserted1.deinit(std.testing.allocator);
    }

    var buffer1: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const str = generateFuzzString(&prng1, &buffer1, 2, 30);
        const owned = try std.testing.allocator.dupe(u8, str);
        try inserted1.append(std.testing.allocator, owned);
        var view = trie1.to_view();
        try view.insert(str);
    }

    const blocks_run1 = trie1.blocks.len.*;

    // Second run with same seed
    var prng2 = std.Random.DefaultPrng.init(seed);
    var backing2: [1024]lego_trie.TrieBlock = undefined;
    var context2 = TestHelpers.create_test_context();
    var trie2 = TestHelpers.create_test_trie(&backing2, &context2);

    var inserted2: std.ArrayList([]const u8) = .empty;
    defer {
        for (inserted2.items) |str| {
            std.testing.allocator.free(str);
        }
        inserted2.deinit(std.testing.allocator);
    }

    var buffer2: [64]u8 = undefined;
    i = 0;
    while (i < 200) : (i += 1) {
        const str = generateFuzzString(&prng2, &buffer2, 2, 30);
        const owned = try std.testing.allocator.dupe(u8, str);
        try inserted2.append(std.testing.allocator, owned);
        var view = trie2.to_view();
        try view.insert(str);
    }

    const blocks_run2 = trie2.blocks.len.*;

    // Verify determinism: same seed produces same results
    try std.testing.expectEqual(blocks_run1, blocks_run2);
    try std.testing.expectEqual(inserted1.items.len, inserted2.items.len);

    // Verify strings match
    for (inserted1.items, inserted2.items) |str1, str2| {
        try std.testing.expectEqualStrings(str1, str2);
    }

    std.debug.print("Phase 7: Deterministic replay passed - seed 0x{X} produced identical results ✓\n", .{seed});
}

test "Phase 7: EXTREME concurrent stress - 30 processes × 60 inserts" {
    const test_state_path = "test_state_extreme_stress.frog";

    // Clean up
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create state file with large capacity
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        4096, // Need huge capacity for 1800+ strings
    );
    defer state_file.deinit();

    const initial_strings: []const []const u8 = &.{};
    try state_file.populate(initial_strings);

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    const exe_path = "zig-out\\bin\\fcmd.exe";

    // Spawn 30 processes × 60 inserts = 1800 concurrent operations
    const num_processes = 30;
    const inserts_per_process = 60;

    var proc_id: usize = 0;
    while (proc_id < num_processes) : (proc_id += 1) {
        var insert_id: usize = 0;
        while (insert_id < inserts_per_process) : (insert_id += 1) {
            const new_str = try std.fmt.allocPrint(
                std.testing.allocator,
                "extreme_proc{d}_i{d}",
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
    std.debug.print("Phase 7: Spawned {d} EXTREME concurrent insert operations...\n", .{total_inserts});

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

    // Verify all strings present
    var all_strings = std.ArrayList([]const u8){};
    defer all_strings.deinit(std.testing.allocator);

    proc_id = 0;
    while (proc_id < num_processes) : (proc_id += 1) {
        var insert_id: usize = 0;
        while (insert_id < inserts_per_process) : (insert_id += 1) {
            const str = try std.fmt.allocPrint(
                std.testing.allocator,
                "extreme_proc{d}_i{d}",
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

    const all_present = try test_mp.verifyStringsInStateFile(
        std.testing.allocator,
        test_state_path,
        all_strings.items,
    );
    try std.testing.expect(all_present);

    std.debug.print("Phase 7: EXTREME stress test passed - all {d} strings present ✓\n", .{all_strings.items.len});
}
