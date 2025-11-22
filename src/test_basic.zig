const std = @import("std");
const test_exports = @import("test_exports.zig");
const lego_trie = test_exports.lego_trie;
const data = test_exports.data;
const TestHelpers = @import("test_helpers.zig");

test "basic insertion - insert 10 strings and verify all findable" {
    var backing: [2048]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

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
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

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
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

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
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

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
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

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
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

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
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

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
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

    const view = trie.to_view();
    var walker = lego_trie.TrieWalker.init(view, "anything");

    // Should not find anything in empty trie
    try std.testing.expect(!walker.walk_to());
}

test "single character strings" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

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
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

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
