const std = @import("std");
const test_exports = @import("test_exports.zig");
const lego_trie = test_exports.lego_trie;
const test_mp = @import("test_multiprocess.zig");

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
