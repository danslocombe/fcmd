const std = @import("std");
const test_exports = @import("test_exports.zig");
const lego_trie = test_exports.lego_trie;
const data = test_exports.data;
const TestHelpers = @import("test_helpers.zig");

// ============================================================================
// PHASE 2: Data Integrity Tests
// ============================================================================

test "Phase 2: round-trip verification - exact data recovery" {
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

test "Phase 2: walker consistency - deterministic results" {
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

test "Phase 2: cost consistency - monotonic decrease on duplicates" {
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

test "Phase 2: sibling chain validation - no cycles or dangles" {
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

    while (current_idx < trie.blocks.len.*) {
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
        try std.testing.expect(block.metadata.next < trie.blocks.len.*);
        current_idx = block.metadata.next;
    }
}

test "Phase 2: prefix extension accuracy" {
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

test "Phase 2: duplicate handling preserves integrity" {
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

test "Phase 2: mixed operations consistency" {
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
