const std = @import("std");
const test_mp = @import("test_multiprocess.zig");

// ============================================================================
// Multi-Process Scenarios
//
// These tests spawn fcmd.exe subprocesses to exercise cross-process
// trie operations over a shared fixed-size (16MB) memory-mapped file.
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

test "simple" {
    const temp_dir = getTempDir(std.testing.allocator);
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_simple" });
    defer std.testing.allocator.free(test_state_path);

    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.Io.Dir.cwd().deleteFile(std.testing.io, cleanup_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cleanup_path) catch {};

    var controller = test_mp.ProcessController.init(std.testing.allocator);
    defer controller.deinit();

    const exe_path = "zig-out\\bin\\fcmd.exe";
    const args = [_][]const u8{ exe_path, "--test-mp", "insert", test_state_path, "test_string" };
    try controller.spawn(&args);

    const exit_codes = try controller.waitAll();
    defer std.testing.allocator.free(exit_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(exit_codes));

    // Verify the string is searchable
    var search_ctrl = test_mp.ProcessController.init(std.testing.allocator);
    defer search_ctrl.deinit();
    const search_args = [_][]const u8{ exe_path, "--test-mp", "search", test_state_path, "test_string" };
    try search_ctrl.spawn(&search_args);
    const search_codes = try search_ctrl.waitAll();
    defer std.testing.allocator.free(search_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(search_codes));
}

test "seq_inserts" {
    const temp_dir = getTempDir(std.testing.allocator);
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_seq_inserts" });
    defer std.testing.allocator.free(test_state_path);

    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.Io.Dir.cwd().deleteFile(std.testing.io, cleanup_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cleanup_path) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";
    const strings = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo" };

    // Each insert waits before the next to stay sequential
    for (strings) |str| {
        var ctrl = test_mp.ProcessController.init(std.testing.allocator);
        defer ctrl.deinit();
        const args = [_][]const u8{ exe_path, "--test-mp", "insert", test_state_path, str };
        try ctrl.spawn(&args);
        const codes = try ctrl.waitAll();
        defer std.testing.allocator.free(codes);
        try std.testing.expect(test_mp.ProcessController.allSucceeded(codes));
    }

    // Verify all strings present
    var verify_args = try buildVerifyArgs(std.testing.allocator, exe_path, test_state_path, &strings);
    defer verify_args.deinit(std.testing.allocator);

    var verify_ctrl = test_mp.ProcessController.init(std.testing.allocator);
    defer verify_ctrl.deinit();
    try verify_ctrl.spawn(verify_args.items);
    const verify_codes = try verify_ctrl.waitAll();
    defer std.testing.allocator.free(verify_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(verify_codes));
}

test "bulk_insert" {
    // 25 strings via insert_many exercises the trie under heavier load.
    const allocator = std.testing.allocator;
    const temp_dir = getTempDir(allocator);
    defer allocator.free(temp_dir);

    const state_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "test_bulk_insert" });
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

test "bulk_insert_then_concurrent_reads" {
    // Inserts strings in a single process, then reads them back concurrently
    // from 4 separate processes. Verifies that multiple processes can
    // simultaneously read from the same mmap after bulk writes.
    const allocator = std.testing.allocator;
    const temp_dir = getTempDir(allocator);
    defer allocator.free(temp_dir);

    const state_path = try std.fs.path.join(allocator, &[_][]const u8{ temp_dir, "test_bulk_reads" });
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

    // Phase 1: single insert_many process writes all strings.
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

    // Phase 2: 4 concurrent search processes all read from the mmap.
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
