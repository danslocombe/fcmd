const std = @import("std");
const test_exports = @import("test_exports.zig");
const lego_trie = test_exports.lego_trie;
const data = test_exports.data;
const TestHelpers = @import("test_helpers.zig");

// ============================================================================
// PHASE 1: Single-Process Stress Tests
// ============================================================================

test "Phase 1: heavy insertion - 1000 commands" {
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

test "Phase 1: very long strings - 100+ character paths" {
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

test "Phase 1: alternating tall/wide promotions" {
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

test "Phase 1: deep trie - long common prefixes" {
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

test "Phase 1: wide trie - diverse first characters" {
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
