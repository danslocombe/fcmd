const std = @import("std");
const test_mp = @import("test_multiprocess.zig");

// ============================================================================
// PHASE 6: Resize Behaviour
//
// These tests exercise the mmap resize path. They use the `insert_many`
// --test-mp operation, which inserts all strings inside a single process.
// This is necessary because each process increments the named semaphore by 1
// in init_internal, and windows.exitProcess kills the background thread before
// it can decrement via the unload flow. With separate processes the count
// accumulates, and ensure_other_processes_have_released_handle spins forever
// waiting for a count of 0 that never arrives. A single insert_many process
// keeps the count at 1, so the resize spin resolves immediately.
//
// Resize thresholds (TrieBlock = 32 bytes, header = 24 bytes):
//   Initial mapping:  256 bytes → 7 blocks
//   After 1st resize: 256 + 7*2*32 = 704 bytes → 21 blocks
//   After 2nd resize: 256 + 21*2*32 = 1600 bytes → 49 blocks
//
// ~6 short unique-prefix strings fills the initial 7 blocks. 10 strings
// reliably triggers the first resize; 25 strings triggers the second.
// ============================================================================

fn getTempDir(allocator: std.mem.Allocator) []const u8 {
    return (std.process.Environ{ .block = .global }).getAlloc(allocator, "TEMP") catch
        (std.process.Environ{ .block = .global }).getAlloc(allocator, "TMP") catch unreachable;
}

fn buildVerifyArgs(
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    state_path: []const u8,
    strings: []const []const u8,
) !std.ArrayList([]const u8) {
    var args = std.ArrayList([]const u8){};
    try args.append(allocator, exe_path);
    try args.append(allocator, "--test-mp");
    try args.append(allocator, "verify");
    try args.append(allocator, state_path);
    for (strings) |s| {
        try args.append(allocator, s);
    }
    return args;
}

test "resize_basic" {
    // A single insert_many process inserts 10 strings, crossing the 7-block
    // initial threshold. Verifies that the resize path preserves all data.
    const allocator = std.testing.allocator;
    const temp_dir = getTempDir(allocator);
    defer allocator.free(temp_dir);

    const state_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "test_resize_basic" });
    defer allocator.free(state_path);
    const cleanup = try std.fs.path.join(allocator, &[_][]const u8{ state_path, "trie.frog" });
    defer allocator.free(cleanup);
    std.Io.Dir.cwd().deleteFile(std.testing.io, cleanup) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cleanup) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";
    const strings = [_][]const u8{
        "aa", "bb", "cc", "dd", "ee",
        "ff", "gg", "hh", "ii", "jj",
    };

    // All 10 inserts happen inside one process — semaphore count stays at 1.
    var insert_args = std.ArrayList([]const u8){};
    defer insert_args.deinit(allocator);
    try insert_args.append(allocator, exe_path);
    try insert_args.append(allocator, "--test-mp");
    try insert_args.append(allocator, "insert_many");
    try insert_args.append(allocator, state_path);
    for (strings) |s| try insert_args.append(allocator, s);

    var insert_ctrl = test_mp.ProcessController.init(allocator);
    defer insert_ctrl.deinit();
    try insert_ctrl.spawn(insert_args.items);
    const insert_codes = try insert_ctrl.waitAll();
    defer allocator.free(insert_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(insert_codes));

    // Verify all strings survived the resize.
    var verify_args = try buildVerifyArgs(allocator, exe_path, state_path, &strings);
    defer verify_args.deinit(allocator);

    var verify_ctrl = test_mp.ProcessController.init(allocator);
    defer verify_ctrl.deinit();
    try verify_ctrl.spawn(verify_args.items);
    const verify_codes = try verify_ctrl.waitAll();
    defer allocator.free(verify_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(verify_codes));
}

test "resize_multiple_rounds" {
    // 25 strings crosses the resize threshold twice:
    //   7 → 21 blocks (first resize)
    //   21 → 49 blocks (second resize)
    // Verifies the resize protocol handles cascading growth correctly.
    const allocator = std.testing.allocator;
    const temp_dir = getTempDir(allocator);
    defer allocator.free(temp_dir);

    const state_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "test_resize_multi" });
    defer allocator.free(state_path);
    const cleanup = try std.fs.path.join(allocator, &[_][]const u8{ state_path, "trie.frog" });
    defer allocator.free(cleanup);
    std.Io.Dir.cwd().deleteFile(std.testing.io, cleanup) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cleanup) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";
    const strings = [_][]const u8{
        "aa", "bb", "cc", "dd", "ee", "ff", "gg", "hh", "ii", "jj",
        "kk", "ll", "mm", "nn", "oo", "pp", "qq", "rr", "ss", "tt",
        "uu", "vv", "ww", "xx", "yy",
    };

    var insert_args = std.ArrayList([]const u8){};
    defer insert_args.deinit(allocator);
    try insert_args.append(allocator, exe_path);
    try insert_args.append(allocator, "--test-mp");
    try insert_args.append(allocator, "insert_many");
    try insert_args.append(allocator, state_path);
    for (strings) |s| try insert_args.append(allocator, s);

    var insert_ctrl = test_mp.ProcessController.init(allocator);
    defer insert_ctrl.deinit();
    try insert_ctrl.spawn(insert_args.items);
    const insert_codes = try insert_ctrl.waitAll();
    defer allocator.free(insert_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(insert_codes));

    var verify_args = try buildVerifyArgs(allocator, exe_path, state_path, &strings);
    defer verify_args.deinit(allocator);

    var verify_ctrl = test_mp.ProcessController.init(allocator);
    defer verify_ctrl.deinit();
    try verify_ctrl.spawn(verify_args.items);
    const verify_codes = try verify_ctrl.waitAll();
    defer allocator.free(verify_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(verify_codes));
}

test "resize_then_concurrent_reads" {
    // Inserts enough strings to trigger a resize in a single process, then reads
    // them back concurrently from 4 separate processes. Verifies that:
    //   1. The resize path preserves all data (same as resize_basic).
    //   2. Multiple processes can simultaneously open and read a post-resize mmap.
    //
    // The concurrent readers start AFTER the writer has exited. This avoids the
    // concurrent-initialization race that occurs when multiple processes all open
    // a fresh mmap simultaneously while a resize is in flight.
    const allocator = std.testing.allocator;
    const temp_dir = getTempDir(allocator);
    defer allocator.free(temp_dir);

    const state_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "test_resize_reads" });
    defer allocator.free(state_path);
    const cleanup = try std.fs.path.join(allocator, &[_][]const u8{ state_path, "trie.frog" });
    defer allocator.free(cleanup);
    std.Io.Dir.cwd().deleteFile(std.testing.io, cleanup) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cleanup) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";
    const strings = [_][]const u8{
        "aa", "bb", "cc", "dd", "ee",
        "ff", "gg", "hh", "ii", "jj",
    };

    // Phase 1: single insert_many process crosses the resize threshold.
    {
        var insert_args = std.ArrayList([]const u8){};
        defer insert_args.deinit(allocator);
        try insert_args.append(allocator, exe_path);
        try insert_args.append(allocator, "--test-mp");
        try insert_args.append(allocator, "insert_many");
        try insert_args.append(allocator, state_path);
        for (strings) |s| try insert_args.append(allocator, s);

        var ctrl = test_mp.ProcessController.init(allocator);
        defer ctrl.deinit();
        try ctrl.spawn(insert_args.items);
        const codes = try ctrl.waitAll();
        defer allocator.free(codes);
        try std.testing.expect(test_mp.ProcessController.allSucceeded(codes));
    }

    // Phase 2: 4 concurrent search processes all open the post-resize mmap.
    var read_ctrl = test_mp.ProcessController.init(allocator);
    defer read_ctrl.deinit();
    // Search for 4 of the strings concurrently (one per process).
    for (strings[0..4]) |s| {
        const search_args = [_][]const u8{ exe_path, "--test-mp", "search", state_path, s };
        try read_ctrl.spawn(&search_args);
    }
    const read_codes = try read_ctrl.waitAll();
    defer allocator.free(read_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(read_codes));

    // Final verify: all 10 strings present.
    var verify_args = try buildVerifyArgs(allocator, exe_path, state_path, &strings);
    defer verify_args.deinit(allocator);

    var verify_ctrl = test_mp.ProcessController.init(allocator);
    defer verify_ctrl.deinit();
    try verify_ctrl.spawn(verify_args.items);
    const verify_codes = try verify_ctrl.waitAll();
    defer allocator.free(verify_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(verify_codes));
}
