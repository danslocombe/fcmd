// Module to export dependencies for testing
pub const lego_trie = @import("datastructures/lego_trie.zig");
pub const data = @import("data.zig");
pub const alloc = @import("alloc.zig");
pub const log = @import("log.zig");
pub const windows = @import("windows.zig");

const std = @import("std");

// Test helpers for trie validation
const TestHelpers = struct {
    /// Validates the entire trie structure for consistency
    /// Checks: no cycles, valid pointers, proper bounds
    fn validate_trie_structure(trie: *lego_trie.Trie) !void {
        const max_blocks = trie.blocks.len.*;

        // Track visited blocks to detect cycles
        var visited = std.AutoHashMap(usize, bool).init(std.testing.allocator);
        defer visited.deinit();

        // Validate each block
        var i: usize = 0;
        while (i < max_blocks) : (i += 1) {
            const block = trie.blocks.at(i);

            // Check sibling chain
            if (block.metadata.next > 0) {
                // Ensure next pointer is valid
                try std.testing.expect(block.metadata.next < max_blocks);

                // Track for cycle detection
                if (visited.contains(i)) {
                    return error.CycleDetected;
                }
                try visited.put(i, true);
            }

            // Check child data pointers
            const child_size = block.get_child_size();
            var j: usize = 0;
            while (j < child_size) : (j += 1) {
                const child_data = if (block.metadata.wide)
                    block.node_data.wide.data[j]
                else
                    block.node_data.tall.data[j];

                if (child_data.exists and !child_data.is_leaf) {
                    // Ensure child pointer is valid
                    try std.testing.expect(child_data.data < max_blocks);
                }
            }
        }
    }

    /// Counts total number of allocated blocks
    fn count_total_nodes(trie: *lego_trie.Trie) usize {
        return trie.blocks.len.*;
    }

    /// Validates that a string can be found in the trie
    fn validate_can_find(trie: *lego_trie.Trie, needle: []const u8) !void {
        const view = trie.to_view();
        var walker = lego_trie.TrieWalker.init(view, needle);

        const found = walker.walk_to();
        if (!found) {
            std.debug.print("Failed to find: '{s}'\n", .{needle});
            return error.StringNotFound;
        }

        // Verify we consumed the entire prefix
        try std.testing.expectEqual(needle.len, walker.char_id);
    }

    /// Validates that all strings in a list can be found
    fn validate_all_can_find(trie: *lego_trie.Trie, needles: []const []const u8) !void {
        for (needles) |needle| {
            try validate_can_find(trie, needle);
        }
    }

    /// Creates a test trie with a fixed backing buffer
    fn create_test_trie(blocks: *data.DumbList(lego_trie.TrieBlock)) lego_trie.Trie {
        blocks.len.* = 0;
        return lego_trie.Trie.init(blocks);
    }
};

test "basic insertion - insert 10 strings and verify all findable" {
    var backing: [2048]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){
        .len = &len,
        .map = &backing,
    };
    var trie = TestHelpers.create_test_trie(&blocks);

    const strings = [_][]const u8{
        "git status",
        "git log",
        "git commit",
        "cd documents",
        "cd downloads",
        "ls -la",
        "cat readme.md",
        "echo hello",
        "npm install",
        "npm start",
    };

    // Insert all strings
    for (strings) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);

    // Verify all strings can be found
    try TestHelpers.validate_all_can_find(&trie, &strings);
}

test "duplicate insertion - verify cost updates" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

    const test_string = "git status";

    var view = trie.to_view();

    // First insertion
    try view.insert(test_string);
    var walker = lego_trie.TrieWalker.init(view, test_string);
    try std.testing.expect(walker.walk_to());
    const initial_cost = walker.cost;

    // Second insertion - cost should decrease
    view = trie.to_view();
    try view.insert(test_string);
    walker = lego_trie.TrieWalker.init(view, test_string);
    try std.testing.expect(walker.walk_to());
    const second_cost = walker.cost;

    try std.testing.expect(second_cost < initial_cost);

    // Third insertion
    view = trie.to_view();
    try view.insert(test_string);
    walker = lego_trie.TrieWalker.init(view, test_string);
    try std.testing.expect(walker.walk_to());
    const third_cost = walker.cost;

    try std.testing.expect(third_cost < second_cost);
}

test "tall to wide promotion - insert 3 strings with GLOBAL_ prefix" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

    // These strings force a tall->wide promotion based on existing test
    const strings = [_][]const u8{
        "GLOBAL_aaa",
        "GLOBAL_bbb",
        "GLOBAL_ccc",
    };

    for (strings) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);

    // Verify all findable
    try TestHelpers.validate_all_can_find(&trie, &strings);

    // Check that we have multiple blocks (promotion occurred)
    const node_count = TestHelpers.count_total_nodes(&trie);
    try std.testing.expect(node_count > 1);
}

test "node spillover - insert enough strings to cause sibling allocation" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

    // WideNodeLen is 4, so inserting 5+ strings with different prefixes
    // should cause spillover to siblings
    const strings = [_][]const u8{
        "apple",
        "banana",
        "cherry",
        "date",
        "elderberry",
        "fig",
        "grape",
        "honeydew",
    };

    for (strings) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);

    // Verify all findable
    try TestHelpers.validate_all_can_find(&trie, &strings);

    // Check root has a sibling
    const root_block = trie.blocks.at(0);
    try std.testing.expect(root_block.metadata.next > 0);
}

test "long string insertion - strings longer than TallStringLen" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

    // TallStringLen is 22, so these should require multiple blocks
    const strings = [_][]const u8{
        "this_is_a_very_long_command_that_exceeds_tall_string_length",
        "another_extremely_long_string_for_testing_purposes",
        "longlonglonglonglonglongstring", // From existing test
    };

    for (strings) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);

    // Verify all findable
    try TestHelpers.validate_all_can_find(&trie, &strings);

    // Should have created multiple blocks
    const node_count = TestHelpers.count_total_nodes(&trie);
    try std.testing.expect(node_count > 1);
}

test "common prefix handling - deep tree structure" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

    // Strings with long common prefixes create deep trees
    const strings = [_][]const u8{
        "git",
        "git status",
        "git status --short",
        "git status --verbose",
        "git commit",
        "git commit -m",
        "git commit --amend",
    };

    for (strings) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);

    // Verify all findable
    try TestHelpers.validate_all_can_find(&trie, &strings);
}

test "prefix search - partial matches return extensions" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

    var view = trie.to_view();
    try view.insert("testing");

    // Search for prefix
    var walker = lego_trie.TrieWalker.init(view, "test");
    try std.testing.expect(walker.walk_to());

    // Should have consumed "test" and have "ing" as extension
    try std.testing.expectEqual(@as(usize, 4), walker.char_id);
    try std.testing.expectEqualStrings("ing", walker.extension.slice());
}

test "empty trie operations - search in empty trie returns false" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

    const view = trie.to_view();
    var walker = lego_trie.TrieWalker.init(view, "anything");

    // Should not find anything in empty trie
    try std.testing.expect(!walker.walk_to());
}

test "single character strings" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

    const strings = [_][]const u8{ "a", "b", "c", "d", "e" };

    for (strings) |s| {
        var view = trie.to_view();
        try view.insert(s);
    }

    // Validate structure
    try TestHelpers.validate_trie_structure(&trie);

    // Verify all findable
    try TestHelpers.validate_all_can_find(&trie, &strings);
}

test "stress test - insert 100 varied strings" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

    var strings: std.ArrayList([]const u8) = .empty;
    defer strings.deinit(std.testing.allocator);

    // Generate varied strings
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const s = try std.fmt.allocPrint(std.testing.allocator, "command_{d}_test", .{i});
        try strings.append(std.testing.allocator, s);
    }
    defer {
        for (strings.items) |s| {
            std.testing.allocator.free(s);
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

    std.debug.print("Stress test: inserted {d} strings, using {d} blocks\n", .{
        strings.items.len,
        TestHelpers.count_total_nodes(&trie),
    });
}

// ============================================================================
// PHASE 1: Single-Process Stress Tests
// ============================================================================

test "Phase 1: heavy insertion - 1000 commands" {
    var backing: [2048]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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

test "Phase 1: very long strings - 100+ character paths" {
    var backing: [2048]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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

test "Phase 1: alternating tall/wide promotions" {
    var backing: [1024]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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

test "Phase 1: deep trie - long common prefixes" {
    var backing: [1024]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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

test "Phase 1: wide trie - diverse first characters" {
    var backing: [1024]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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
// PHASE 2: Data Integrity Tests
// ============================================================================

test "Phase 2: round-trip verification - exact data recovery" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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
// PHASE 3: Edge Cases & Boundary Conditions
// ============================================================================

test "Phase 3: empty string handling" {
    var backing: [256]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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

test "Phase 3: maximum string length boundaries (TallStringLen = 22)" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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

test "Phase 3: node capacity boundaries - WideNodeLen (4) and TallNodeLen (1)" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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

test "Phase 3: special characters - unicode, spaces, symbols" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

    const special_strings = [_][]const u8{
        "hello world", // spaces
        "file.txt", // dot
        "path/to/file", // slashes
        "arg=\"value\"", // quotes
        "tab\there", // tab
        "café", // unicode
        "emoji🎉test", // emoji
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

test "Phase 3: identical prefix stress" {
    var backing: [1024]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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

test "Phase 3: single character differences" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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

test "Phase 3: case sensitivity" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(lego_trie.TrieBlock){ .len = &len, .map = &backing };
    var trie = TestHelpers.create_test_trie(&blocks);

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
// PHASE 4: Multi-Process Concurrency Tests
// ============================================================================

const test_mp = @import("test_multiprocess.zig");

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
        512,
    );
    defer state_file.deinit();

    // Start with empty trie
    const initial_strings: []const []const u8 = &.{};
    try state_file.populate(initial_strings);

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    const exe_path = "zig-out\\bin\\fcmd.exe";

    // Spawn 3 writer processes, each inserting 20 unique strings
    // Writer 0: writer0_0 ... writer0_19
    // Writer 1: writer1_0 ... writer1_19
    // Writer 2: writer2_0 ... writer2_19
    const num_writers = 3;
    const strings_per_writer = 20;

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

    // Verify all 60 strings (3 writers × 20 strings) are present
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

// ============================================================================
// PHASE 5: Additional Multi-Process Scenarios
// ============================================================================

test "Phase 5: rapid insert stress - 5 processes × 50 inserts" {
    const test_state_path = "test_state_rapid_stress.frog";

    // Clean up
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create state file with 10 initial strings
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        1024, // Need larger capacity for 260 strings
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

    // Spawn 5 processes, each inserting 50 strings rapidly
    const num_processes = 5;
    const inserts_per_process = 50;

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

    // Verify all strings present: 10 initial + 250 inserted = 260 total
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

// ============================================================================
// Phase 6: File System Integration Tests
// ============================================================================

test "Phase 6: cold start - load from existing file" {
    const test_state_path = "test_state_cold_start.frog";

    // Clean up
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create state file with known data
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        256,
    );
    defer state_file.deinit();

    const test_strings = [_][]const u8{
        "git status",
        "git commit -m",
        "npm install",
        "cargo build",
        "docker ps",
    };
    try state_file.populate(&test_strings);

    // Verify initial population worked
    for (test_strings) |str| {
        const found = try test_mp.verifyStringInStateFile(
            std.testing.allocator,
            test_state_path,
            str,
        );
        try std.testing.expect(found);
    }

    std.debug.print("Phase 6: Created state file with {d} strings\n", .{test_strings.len});

    // Now simulate a "cold start" - close and reopen the state file
    // This tests that data persists correctly after write and can be read back

    const reopened = try test_mp.TestStateFile.open(
        std.testing.allocator,
        test_state_path,
    );
    defer {
        std.testing.allocator.free(reopened.filepath);
    }

    // Verify all strings still present after reopen
    for (test_strings) |str| {
        const found = try test_mp.verifyStringInStateFile(
            std.testing.allocator,
            test_state_path,
            str,
        );
        try std.testing.expect(found);
    }

    std.debug.print("Phase 6: Cold start test passed - all {d} strings survived reopen ✓\n", .{test_strings.len});
}

test "Phase 6: corrupt magic number detection" {
    const test_state_path = "test_state_corrupt_magic.frog";

    // Clean up
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create a valid state file first
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        256,
    );
    defer state_file.deinit();

    const test_strings = [_][]const u8{"test command"};
    try state_file.populate(&test_strings);

    // Now corrupt the magic number
    const file = try std.fs.cwd().openFile(test_state_path, .{ .mode = .read_write });
    defer file.close();

    // Write invalid magic number
    const bad_magic = [_]u8{ 'b', 'a', 'd', '!' };
    try file.pwriteAll(&bad_magic, 0);

    std.debug.print("Phase 6: Corrupted magic number to 'bad!'\n", .{});

    // Attempt to open should fail with InvalidMagicNumber
    const open_result = test_mp.TestStateFile.open(
        std.testing.allocator,
        test_state_path,
    );

    if (open_result) |_| {
        return error.ShouldHaveFailedValidation;
    } else |err| {
        try std.testing.expectEqual(error.InvalidMagicNumber, err);
        std.debug.print("Phase 6: Corrupt magic number correctly detected ✓\n", .{});
    }
}

test "Phase 6: corrupt version detection" {
    const test_state_path = "test_state_corrupt_version.frog";

    // Clean up
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create a valid state file
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        256,
    );
    defer state_file.deinit();

    const test_strings = [_][]const u8{"test command"};
    try state_file.populate(&test_strings);

    // Corrupt the version byte
    const file = try std.fs.cwd().openFile(test_state_path, .{ .mode = .read_write });
    defer file.close();

    // Write invalid version (current is 3, use 99)
    const bad_version: u8 = 99;
    try file.pwriteAll(&[_]u8{bad_version}, 4);

    std.debug.print("Phase 6: Corrupted version to {d}\n", .{bad_version});

    // Attempt to open should fail with InvalidVersion
    const open_result = test_mp.TestStateFile.open(
        std.testing.allocator,
        test_state_path,
    );

    if (open_result) |_| {
        return error.ShouldHaveFailedValidation;
    } else |err| {
        try std.testing.expectEqual(error.InvalidVersion, err);
        std.debug.print("Phase 6: Corrupt version correctly detected ✓\n", .{});
    }
}

test "Phase 6: file size validation" {
    const test_state_path = "test_state_size_validation.frog";

    // Clean up
    std.fs.cwd().deleteFile(test_state_path) catch {};
    defer std.fs.cwd().deleteFile(test_state_path) catch {};

    // Create state file with known capacity
    const initial_blocks: usize = 100;
    var state_file = try test_mp.TestStateFile.create(
        std.testing.allocator,
        test_state_path,
        initial_blocks,
    );
    defer state_file.deinit();

    // Calculate expected size
    const header_size = 16; // magic(4) + version(1) + padding(3) + size(4) + padding(4)
    const len_size = @sizeOf(usize);
    const block_data_size = initial_blocks * @sizeOf(lego_trie.TrieBlock);
    const expected_size = header_size + len_size + block_data_size;

    // Verify file size matches expected
    const file = try std.fs.cwd().openFile(test_state_path, .{});
    defer file.close();

    const stat = try file.stat();
    try std.testing.expectEqual(expected_size, stat.size);

    // Read size_in_bytes from file header
    var size_buffer: [4]u8 = undefined;
    _ = try file.preadAll(&size_buffer, 8);
    const stored_size: i32 = @bitCast(size_buffer);

    try std.testing.expectEqual(@as(i32, @intCast(expected_size)), stored_size);

    std.debug.print("Phase 6: File size validation passed - expected={d}, actual={d}, stored={d} ✓\n", .{
        expected_size,
        stat.size,
        stored_size,
    });
}
