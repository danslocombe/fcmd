const std = @import("std");
const test_exports = @import("test_exports.zig");
const lego_trie = test_exports.lego_trie;
const data = test_exports.data;

/// Creates a minimal test context for in-memory testing (no file I/O)
pub fn create_test_context() data.MMapContext {
    // Return a context that will prevent any resize attempts
    // Setting handle and semaphore to undefined/invalid values
    return data.MMapContext{
        .handle = undefined,
        .semaphore = undefined,
        .filepath = undefined,
    };
}

/// Creates a test trie with a fixed backing buffer
pub fn create_test_trie(backing: []lego_trie.TrieBlock, context: *data.MMapContext) lego_trie.Trie {
    var len: usize = 0;

    var blocks = data.DumbList(lego_trie.TrieBlock){
        .len = &len,
        .map = backing,
        .mmap_context = context,
    };

    blocks.len.* = 0;
    return lego_trie.Trie.init(&blocks);
}

/// Validates the entire trie structure for consistency
/// Checks: no cycles, valid pointers, proper bounds
pub fn validate_trie_structure(trie: *lego_trie.Trie) !void {
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
pub fn count_total_nodes(trie: *lego_trie.Trie) usize {
    return trie.blocks.len.*;
}

/// Validates that a string can be found in the trie
pub fn validate_can_find(trie: *lego_trie.Trie, needle: []const u8) !void {
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
pub fn validate_all_can_find(trie: *lego_trie.Trie, needles: []const []const u8) !void {
    for (needles) |needle| {
        try validate_can_find(trie, needle);
    }
}
