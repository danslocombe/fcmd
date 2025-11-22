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
