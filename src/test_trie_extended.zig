const std = @import("std");
const test_exports = @import("test_exports.zig");
const lego_trie = test_exports.lego_trie;
const data = test_exports.data;
const TestHelpers = @import("test_helpers.zig");

// ============================================================================
// Stress Tests
// ============================================================================

test "heavy insertion - 1000 commands" {
    var backing: [2048]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    var strings: std.ArrayList([]const u8) = .empty;
    defer strings.deinit(std.testing.allocator);
    defer {
        for (strings.items) |s| {
            std.testing.allocator.free(s);
        }
    }

    // Generate 1000 varied command strings
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const s = try std.fmt.allocPrint(std.testing.allocator, "cmd_{d}_operation", .{i});
        try strings.append(std.testing.allocator, s);
    }

    // Insert all strings
    for (strings.items) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Validate structure integrity
    try TestHelpers.validate_trie_structure(&trie);

    // Verify all strings are findable
    try TestHelpers.validate_all_can_find(&trie, strings.items);

    std.debug.print("Heavy insertion: {d} strings, {d} blocks\n", .{
        strings.items.len,
        TestHelpers.count_total_nodes(&trie),
    });
}

test "very long strings - 100+ character paths" {
    var backing: [2048]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    var strings: std.ArrayList([]const u8) = .empty;
    defer strings.deinit(std.testing.allocator);
    defer {
        for (strings.items) |s| {
            std.testing.allocator.free(s);
        }
    }

    // Create very long path-like strings
    const long_prefixes = [_][]const u8{
        "C:\\Users\\Developer\\Documents\\Projects\\MyApplication\\src\\components\\authentication\\",
        "/home/user/development/projects/backend/services/microservices/api/controllers/",
        "D:\\workspace\\enterprise\\legacy\\refactored\\modules\\core\\utilities\\helpers\\",
    };

    for (long_prefixes) |prefix| {
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const s = try std.fmt.allocPrint(std.testing.allocator, "{s}file_{d}.txt", .{ prefix, i });
            try strings.append(std.testing.allocator, s);
        }
    }

    // Insert all long strings
    for (strings.items) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);

    // Verify all findable
    try TestHelpers.validate_all_can_find(&trie, strings.items);

    std.debug.print("Long strings: {d} strings (avg len ~{d}), {d} blocks\n", .{
        strings.items.len,
        strings.items[0].len,
        TestHelpers.count_total_nodes(&trie),
    });
}

test "alternating tall/wide promotions" {
    var backing: [1024]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    var strings: std.ArrayList([]const u8) = .empty;
    defer strings.deinit(std.testing.allocator);
    defer {
        for (strings.items) |s| {
            std.testing.allocator.free(s);
        }
    }

    // Create groups of strings that share common prefixes
    // This forces tall node creation, then wide promotion when siblings fill
    const prefixes = [_][]const u8{
        "git_",
        "npm_",
        "cargo_",
        "make_",
        "docker_",
        "kubectl_",
    };

    for (prefixes) |prefix| {
        var i: usize = 0;
        while (i < 10) : (i += 1) {
            const s = try std.fmt.allocPrint(std.testing.allocator, "{s}command_{d}", .{ prefix, i });
            try strings.append(std.testing.allocator, s);
        }
    }

    // Insert in a pattern that encourages promotions
    for (strings.items) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);

    // Verify all findable
    try TestHelpers.validate_all_can_find(&trie, strings.items);

    std.debug.print("Tall/wide promotion: {d} strings, {d} blocks\n", .{
        strings.items.len,
        TestHelpers.count_total_nodes(&trie),
    });
}

test "deep trie - long common prefixes" {
    var backing: [1024]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    var strings: std.ArrayList([]const u8) = .empty;
    defer strings.deinit(std.testing.allocator);
    defer {
        for (strings.items) |s| {
            std.testing.allocator.free(s);
        }
    }

    // Create deeply nested command structures
    // Format: base_level1_level2_level3_...
    const bases = [_][]const u8{ "system", "user", "admin" };
    const level1s = [_][]const u8{ "config", "settings", "preferences" };
    const level2s = [_][]const u8{ "display", "network", "security" };
    const level3s = [_][]const u8{ "advanced", "basic", "custom" };

    for (bases) |base| {
        for (level1s) |l1| {
            for (level2s) |l2| {
                for (level3s) |l3| {
                    const s = try std.fmt.allocPrint(
                        std.testing.allocator,
                        "{s}_{s}_{s}_{s}",
                        .{ base, l1, l2, l3 },
                    );
                    try strings.append(std.testing.allocator, s);
                }
            }
        }
    }

    // Insert all
    for (strings.items) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);

    // Verify all findable
    try TestHelpers.validate_all_can_find(&trie, strings.items);

    std.debug.print("Deep trie: {d} strings, {d} blocks\n", .{
        strings.items.len,
        TestHelpers.count_total_nodes(&trie),
    });
}

test "wide trie - diverse first characters" {
    var backing: [1024]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    var strings: std.ArrayList([]const u8) = .empty;
    defer strings.deinit(std.testing.allocator);
    defer {
        for (strings.items) |s| {
            std.testing.allocator.free(s);
        }
    }

    // Create strings starting with many different characters
    // This creates wide fan-out at the root
    const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var i: usize = 0;
    while (i < chars.len) : (i += 1) {
        const c = chars[i];
        var j: usize = 0;
        while (j < 5) : (j += 1) {
            const s = try std.fmt.allocPrint(
                std.testing.allocator,
                "{c}_command_{d}",
                .{ c, j },
            );
            try strings.append(std.testing.allocator, s);
        }
    }

    // Insert all
    for (strings.items) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);

    // Verify all findable
    try TestHelpers.validate_all_can_find(&trie, strings.items);

    std.debug.print("Wide trie: {d} strings, {d} blocks\n", .{
        strings.items.len,
        TestHelpers.count_total_nodes(&trie),
    });
}

// ============================================================================
// Data Integrity Tests
// ============================================================================

test "round-trip verification - exact data recovery" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    const test_data = [_][]const u8{
        "exact_string_1",
        "exact_string_2_with_longer_name",
        "short",
        "a",
        "verylongstringwithoutspacestotest",
        "has spaces in it",
        "numbers123456789",
        "symbols!@#$%",
    };

    // Insert all test data
    for (test_data) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Verify exact retrieval for each string
    for (test_data) |s| {
        const view = trie.to_view();
        var walker = lego_trie.TrieWalker.init(view, s);

        // Should find exact match
        try std.testing.expect(walker.walk_to());

        // Should have consumed entire string
        try std.testing.expectEqual(s.len, walker.char_id);

        // Should have no extension (exact match)
        try std.testing.expectEqual(@as(usize, 0), walker.extension.len());
    }
}

test "walker consistency - deterministic results" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    var view = trie.to_view();
    try view.insert("deterministic_test");

    // Walk the same path multiple times
    const iterations = 100;
    var first_cost: usize = 0;
    var first_char_id: usize = 0;
    var i: usize = 0;

    while (i < iterations) : (i += 1) {
        const v = trie.to_view();
        var walker = lego_trie.TrieWalker.init(v, "deterministic_test");

        try std.testing.expect(walker.walk_to());

        if (i == 0) {
            first_cost = walker.cost;
            first_char_id = walker.char_id;
        } else {
            // Every walk should produce identical results
            try std.testing.expectEqual(first_cost, walker.cost);
            try std.testing.expectEqual(first_char_id, walker.char_id);
        }
    }
}

test "cost consistency - monotonic decrease on duplicates" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    const test_string = "cost_test_string";
    var previous_cost: usize = std.math.maxInt(usize);

    // Insert same string 10 times
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var view = trie.to_view();
        try view.insert(test_string);

        // Check cost decreased
        var walker = lego_trie.TrieWalker.init(view, test_string);
        try std.testing.expect(walker.walk_to());

        // Cost should strictly decrease
        try std.testing.expect(walker.cost < previous_cost);
        previous_cost = walker.cost;
    }
}

test "sibling chain validation - no cycles or dangles" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    // Insert enough to cause sibling chains
    const strings = [_][]const u8{
        "alpha",   "bravo", "charlie", "delta", "echo",
        "foxtrot", "golf",  "hotel",   "india", "juliet",
    };

    for (strings) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Walk sibling chains starting from root
    var visited = std.AutoHashMap(usize, bool).init(std.testing.allocator);
    defer visited.deinit();

    var current_idx: usize = 0;
    var count: usize = 0;
    const max_siblings = 100; // Safety limit

    while (current_idx < trie.blocks.len.load(.monotonic)) {
        const block = trie.blocks.at(current_idx);

        // Check for cycles
        if (visited.contains(current_idx)) {
            return error.CycleDetected;
        }
        try visited.put(current_idx, true);

        count += 1;
        if (count > max_siblings) {
            return error.TooManySiblings;
        }

        // Move to next sibling
        if (block.metadata.next == 0) {
            break;
        }

        // Validate next pointer is in bounds
        try std.testing.expect(block.metadata.next < trie.blocks.len.load(.monotonic));
        current_idx = block.metadata.next;
    }
}

test "prefix extension accuracy" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    const test_cases = [_]struct {
        full: []const u8,
        prefix: []const u8,
        expected_ext: []const u8,
    }{
        .{ .full = "testing", .prefix = "test", .expected_ext = "ing" },
        .{ .full = "hello_world", .prefix = "hello", .expected_ext = "_world" },
        .{ .full = "application", .prefix = "app", .expected_ext = "lication" },
    };

    for (test_cases) |tc| {
        var view = trie.to_view();
        try view.insert(tc.full);

        var walker = lego_trie.TrieWalker.init(view, tc.prefix);
        try std.testing.expect(walker.walk_to());

        // Verify prefix consumed
        try std.testing.expectEqual(tc.prefix.len, walker.char_id);

        // Verify extension is correct
        try std.testing.expectEqualStrings(tc.expected_ext, walker.extension.slice());
    }
}

test "duplicate handling preserves integrity" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    const test_string = "duplicate_test";
    const initial_block_count = TestHelpers.count_total_nodes(&trie);

    // Insert same string 50 times
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var view = trie.to_view();
        try view.insert(test_string);
    }

    // Block count should not grow significantly (no duplicate storage)
    const final_block_count = TestHelpers.count_total_nodes(&trie);
    try std.testing.expect(final_block_count <= initial_block_count + 10);

    // Should still be findable
    try TestHelpers.validate_can_find(&trie, test_string);

    // Structure should still be valid
    try TestHelpers.validate_trie_structure(&trie);
}

test "mixed operations consistency" {
    var backing: [1024]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    var inserted: std.ArrayList([]const u8) = .empty;
    defer inserted.deinit(std.testing.allocator);

    // Interleave insertions and searches
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        // Insert a new string
        const s = try std.fmt.allocPrint(std.testing.allocator, "mixed_{d}", .{i});
        var view = trie.to_view();
        try view.insert(s);
        try inserted.append(std.testing.allocator, s);

        // Verify all previously inserted strings are still findable
        try TestHelpers.validate_all_can_find(&trie, inserted.items);
    }

    // Cleanup
    for (inserted.items) |s| {
        std.testing.allocator.free(s);
    }

    // Final structure check
    try TestHelpers.validate_trie_structure(&trie);
}

// ============================================================================
// Edge Cases & Boundary Conditions
// ============================================================================

test "empty string handling" {
    var backing: [256]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    // Insert empty string
    var view = trie.to_view();
    try view.insert("");

    // Try to search for it
    var walker = lego_trie.TrieWalker.init(view, "");
    const found = walker.walk_to();

    // Verify structure is still valid
    try TestHelpers.validate_trie_structure(&trie);

    // Note: Empty string behavior depends on implementation
    // This test documents current behavior
    std.debug.print("Empty string found: {}\n", .{found});
}

test "maximum string length boundaries (TallStringLen = 22)" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    // Test strings at boundary: 21, 22, 23 characters
    const str_21 = "a" ** 21; // Just under
    const str_22 = "b" ** 22; // Exactly at boundary
    const str_23 = "c" ** 23; // Just over

    const strings = [_][]const u8{ str_21, str_22, str_23 };

    for (strings) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Verify all findable
    try TestHelpers.validate_all_can_find(&trie, &strings);

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);
}

test "node capacity boundaries - WideNodeLen (4) and TallNodeLen (1)" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    // Test exactly WideNodeLen (4) insertions with different prefixes
    const wide_test = [_][]const u8{ "w1", "w2", "w3", "w4" };

    for (wide_test) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    try TestHelpers.validate_all_can_find(&trie, &wide_test);

    // Add one more to force spillover
    var view = trie.to_view();
    try view.insert("w5");

    const all_wide = [_][]const u8{ "w1", "w2", "w3", "w4", "w5" };
    try TestHelpers.validate_all_can_find(&trie, &all_wide);

    // Validate structure after spillover
    try TestHelpers.validate_trie_structure(&trie);
}

test "special characters - unicode, spaces, symbols" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    const special_strings = [_][]const u8{
        "hello world", // spaces
        "file.txt", // dot
        "path/to/file", // slashes
        "arg=\"value\"", // quotes
        "tab\there", // tab
        "caf\xc3\xa9", // unicode
        "emoji\xf0\x9f\x8e\x89test", // emoji
        "a|b|c", // pipes
        "test@example.com", // at sign
        "100%complete", // percent
    };

    for (special_strings) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Verify all findable
    try TestHelpers.validate_all_can_find(&trie, &special_strings);

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);
}

test "identical prefix stress" {
    var backing: [1024]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    var strings: std.ArrayList([]const u8) = .empty;
    defer strings.deinit(std.testing.allocator);
    defer {
        for (strings.items) |s| {
            std.testing.allocator.free(s);
        }
    }

    // Create many strings with same long prefix
    const common_prefix = "very_long_common_prefix_for_testing_";
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const s = try std.fmt.allocPrint(
            std.testing.allocator,
            "{s}{d}",
            .{ common_prefix, i },
        );
        try strings.append(std.testing.allocator, s);
    }

    // Insert all
    for (strings.items) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Verify all findable
    try TestHelpers.validate_all_can_find(&trie, strings.items);

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);
}

test "single character differences" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    // Strings differing by one character at various positions
    const strings = [_][]const u8{
        "test_a_string",
        "test_b_string",
        "test_c_string",
        "test_string_a",
        "test_string_b",
        "test_string_c",
        "a_test_string",
        "b_test_string",
        "c_test_string",
    };

    for (strings) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Verify all findable and distinguishable
    try TestHelpers.validate_all_can_find(&trie, &strings);

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);
}

test "case sensitivity" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    // Test case variations
    const strings = [_][]const u8{
        "lowercase",
        "UPPERCASE",
        "MixedCase",
        "camelCase",
        "PascalCase",
        "snake_case",
        "SCREAMING_SNAKE_CASE",
    };

    for (strings) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Verify all findable (trie should be case-sensitive)
    try TestHelpers.validate_all_can_find(&trie, &strings);

    // Verify that searching for different case doesn't match
    const v = trie.to_view();
    var walker = lego_trie.TrieWalker.init(v, "LOWERCASE");
    const found = walker.walk_to();

    // Should not find "LOWERCASE" when only "lowercase" was inserted
    // (unless they happen to share a prefix, which they might)
    // This tests case sensitivity
    if (found) {
        // If found, should not be an exact match
        try std.testing.expect(walker.char_id < "LOWERCASE".len or walker.extension.len() > 0);
    }

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);
}

// ============================================================================
// Insertion Code Path Coverage
// ============================================================================

test "insert prefix of existing leaf - triggers split with empty recurse_key" {
    // Exercises try_insert_along's `recurse_key.len == 0` early return.
    // Insert "testing" as a leaf, then "test" — the split produces "test" + "ing"
    // with nothing left to recurse on for the second insert.
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    var view = trie.to_view();
    try view.insert("testing");
    view = trie.to_view();
    try view.insert("test");

    // Both the full string and the prefix must be findable
    try TestHelpers.validate_can_find(&trie, "testing");
    try TestHelpers.validate_can_find(&trie, "test");

    // "test" should be an exact match (no extension)
    var walker = lego_trie.TrieWalker.init(trie.to_view(), "test");
    try std.testing.expect(walker.walk_to());
    try std.testing.expectEqual(@as(usize, 4), walker.char_id);

    // "testing" should still resolve fully
    walker = lego_trie.TrieWalker.init(trie.to_view(), "testing");
    try std.testing.expect(walker.walk_to());
    try std.testing.expectEqual(@as(usize, 7), walker.char_id);

    try TestHelpers.validate_trie_structure(&trie);
}

test "insert prefix of existing leaf - multiple depths" {
    // Same pattern but at various depths to stress the split logic.
    var backing: [1024]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    // Insert long strings first, then their prefixes
    const pairs = [_][2][]const u8{
        .{ "application", "app" },
        .{ "configuration", "config" },
        .{ "development", "dev" },
        .{ "git status --verbose", "git status" },
        .{ "git status", "git" },
    };

    for (pairs) |pair| {
        var view = trie.to_view();
        try view.insert(pair[0]);
        view = trie.to_view();
        try view.insert(pair[1]);
    }

    // All strings (both full and prefix) must be findable
    for (pairs) |pair| {
        try TestHelpers.validate_can_find(&trie, pair[0]);
        try TestHelpers.validate_can_find(&trie, pair[1]);
    }

    try TestHelpers.validate_trie_structure(&trie);
}

test "reinsert interior node string - common_len == child_slice.len with non-leaf" {
    // After "abc" and "abd" are inserted, "ab" becomes an interior node.
    // Reinserting "ab" should follow the existing interior node path and
    // hit the recurse_key.len == 0 return in the non-leaf branch.
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    var view = trie.to_view();
    try view.insert("abc");
    view = trie.to_view();
    try view.insert("abd");
    view = trie.to_view();
    try view.insert("ab");

    try TestHelpers.validate_can_find(&trie, "abc");
    try TestHelpers.validate_can_find(&trie, "abd");
    try TestHelpers.validate_can_find(&trie, "ab");

    // Insert "ab" again — should not corrupt anything
    view = trie.to_view();
    try view.insert("ab");

    try TestHelpers.validate_can_find(&trie, "abc");
    try TestHelpers.validate_can_find(&trie, "abd");
    try TestHelpers.validate_can_find(&trie, "ab");

    try TestHelpers.validate_trie_structure(&trie);
}

test "sort correctness across sibling chain boundaries" {
    // Insert enough strings with distinct first chars to force multiple wide sibling
    // blocks at the root (WideNodeLen=4, so 9+ strings = 3 blocks). Then reinsert
    // the last string many times so its cost drops, and verify that after sorting
    // it appears as the first child in iteration order.
    var backing: [64]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    const strings = [_][]const u8{ "aa", "bb", "cc", "dd", "ee", "ff", "gg", "hh", "ii" };

    // Insert each once
    for (strings) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Reinsert "ii" many times to make it lowest-cost (highest priority)
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var view = trie.to_view();
        try view.insert("ii");
    }

    // All strings still findable after sorting
    try TestHelpers.validate_all_can_find(&trie, &strings);

    // The first child in iteration order should be "ii" (lowest cost = highest priority)
    const root = trie.blocks.at(0);
    var iter = lego_trie.ChildIterator{ .block = root, .trie = &trie };
    try std.testing.expect(iter.next());
    const first_str = if (root.metadata.wide)
        root.node_data.wide.nodes[iter.i.?].slice()
    else
        root.node_data.tall.nodes[iter.i.?].slice();

    try std.testing.expectEqualStrings("i", first_str);

    try TestHelpers.validate_trie_structure(&trie);
}

// ============================================================================
// Empty-leaf bug investigation
// ----------------------------------------------------------------------------
// When a string S that is also a prefix of another stored string S' has been
// split into a node, S itself is represented by a child with an empty-string
// edge ("") inside that node's child block. The hypothesis is that re-inserting
// S does NOT decrement that empty-leaf's cost, and instead duplicate "" entries
// get appended, because try_insert_along skips entries where common_prefix_len
// is zero, and common_prefix_len(anything, "") is always 0.
// ============================================================================

// Counts children whose edge string is exactly empty across a block's sibling
// chain. Used to detect duplicate empty-leaf entries.
fn count_empty_edges(block: *lego_trie.TrieBlock, trie: *lego_trie.Trie) usize {
    var count: usize = 0;
    var iter = lego_trie.ChildIterator{ .block = block, .trie = trie };
    while (iter.next()) {
        const node_slice = if (iter.block.metadata.wide)
            iter.block.node_data.wide.nodes[iter.i.?].slice()
        else
            iter.block.node_data.tall.nodes[iter.i.?].slice();
        if (node_slice.len == 0) count += 1;
    }
    return count;
}

// Counts total children (any edge) across a block's sibling chain.
fn count_children(block: *lego_trie.TrieBlock, trie: *lego_trie.Trie) usize {
    var count: usize = 0;
    var iter = lego_trie.ChildIterator{ .block = block, .trie = trie };
    while (iter.next()) count += 1;
    return count;
}

// Returns the lowest cost among empty-edge children across the sibling chain,
// or null if no empty edges exist.
fn min_empty_edge_cost(block: *lego_trie.TrieBlock, trie: *lego_trie.Trie) ?u16 {
    var min: ?u16 = null;
    var iter = lego_trie.ChildIterator{ .block = block, .trie = trie };
    while (iter.next()) {
        const node_slice = if (iter.block.metadata.wide)
            iter.block.node_data.wide.nodes[iter.i.?].slice()
        else
            iter.block.node_data.tall.nodes[iter.i.?].slice();
        if (node_slice.len != 0) continue;
        const c = if (iter.block.metadata.wide)
            iter.block.node_data.wide.costs[iter.i.?]
        else
            iter.block.node_data.tall.costs[iter.i.?];
        if (min == null or c < min.?) min = c;
    }
    return min;
}

test "empty-leaf bug - re-inserting a prefix-of-another string should not duplicate the empty leaf" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    // After "ab" + "abc": root has "ab" as a node whose child block contains
    // exactly two leaves: "" (representing "ab") and "c" (representing "abc").
    {
        var view = trie.to_view();
        try view.insert("ab");
    }
    {
        var view = trie.to_view();
        try view.insert("abc");
    }

    {
        const view = trie.to_view();
        var walker = lego_trie.TrieWalker.init(view, "ab");
        try std.testing.expect(walker.walk_to());
        const child_block = trie.blocks.at(walker.trie_view.current_block);

        try std.testing.expectEqual(@as(usize, 2), count_children(child_block, &trie));
        try std.testing.expectEqual(@as(usize, 1), count_empty_edges(child_block, &trie));
    }

    // Re-insert "ab" five more times. Each re-insertion should logically just
    // bump the existing "" leaf's count - not create new entries.
    for (0..5) |_| {
        var view = trie.to_view();
        try view.insert("ab");
    }

    const view = trie.to_view();
    var walker = lego_trie.TrieWalker.init(view, "ab");
    try std.testing.expect(walker.walk_to());
    const child_block = trie.blocks.at(walker.trie_view.current_block);

    // Should still be just 2 children. With the bug, this grows by one per re-insert.
    try std.testing.expectEqual(@as(usize, 2), count_children(child_block, &trie));
    try std.testing.expectEqual(@as(usize, 1), count_empty_edges(child_block, &trie));
}

test "empty-leaf bug - re-inserting a prefix should decrement the empty leaf's cost" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    {
        var view = trie.to_view();
        try view.insert("ab");
    }
    {
        var view = trie.to_view();
        try view.insert("abc");
    }

    const initial_empty_cost = blk: {
        const view = trie.to_view();
        var walker = lego_trie.TrieWalker.init(view, "ab");
        try std.testing.expect(walker.walk_to());
        const child_block = trie.blocks.at(walker.trie_view.current_block);
        break :blk min_empty_edge_cost(child_block, &trie).?;
    };

    for (0..5) |_| {
        var view = trie.to_view();
        try view.insert("ab");
    }

    const view = trie.to_view();
    var walker = lego_trie.TrieWalker.init(view, "ab");
    try std.testing.expect(walker.walk_to());
    const child_block = trie.blocks.at(walker.trie_view.current_block);
    const post_empty_cost = min_empty_edge_cost(child_block, &trie).?;

    // Cost is BaseCost minus number-of-uses; more uses -> lower cost.
    // After 5 extra "ab" inserts, the "" leaf's cost should be strictly lower.
    try std.testing.expect(post_empty_cost < initial_empty_cost);
}

test "ranking inversion - more frequent prefix-only string should rank first" {
    // Mirrors the user's reported scenario:
    //   "cd Q:\\Sydney" is typed often, "cd Q:\\Sydney-MCPSwitch" rarely.
    // The SubtreeIterator at the "cd Q:\\Sydney" junction should yield the
    // empty-leaf (representing "Sydney" itself) first, because it's more common.
    var backing: [2048]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    for (0..10) |_| {
        var view = trie.to_view();
        try view.insert("cd Q:\\Sydney");
    }
    {
        var view = trie.to_view();
        try view.insert("cd Q:\\Sydney-MCPSwitch");
    }

    const view = trie.to_view();
    var walker = lego_trie.TrieWalker.init(view, "cd Q:\\Syd");
    try std.testing.expect(walker.walk_to());
    try std.testing.expect(!walker.reached_leaf);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var iter = lego_trie.SubtreeIterator{
        .trie = &trie,
        .root_block = @intCast(walker.trie_view.current_block),
    };

    // SubtreeIterator.build_result skips empty edges in components, so the
    // "Sydney" completion comes back as "" (the walker's extension already
    // covers "ney"). The "-MCPSwitch" completion comes back as "-MCPSwitch".
    const first = iter.next(arena.allocator()).?;
    try std.testing.expectEqualSlices(u8, "", first);
}
