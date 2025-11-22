const std = @import("std");
const test_exports = @import("test_exports.zig");
const lego_trie = test_exports.lego_trie;
const data = test_exports.data;
const TestHelpers = @import("test_helpers.zig");

// ============================================================================
// PHASE 3: Edge Cases & Boundary Conditions
// ============================================================================

test "Phase 3: empty string handling" {
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

test "Phase 3: maximum string length boundaries (TallStringLen = 22)" {
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

test "Phase 3: node capacity boundaries - WideNodeLen (4) and TallNodeLen (1)" {
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

test "Phase 3: special characters - unicode, spaces, symbols" {
    var backing: [512]lego_trie.TrieBlock = undefined;
    var context = TestHelpers.create_test_context();
    var trie = TestHelpers.create_test_trie(&backing, &context);

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

test "Phase 3: single character differences" {
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

test "Phase 3: case sensitivity" {
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
