const std = @import("std");
const test_exports = @import("test_exports.zig");
const test_mp = @import("test_multiprocess.zig");

// ============================================================================
// PHASE 5: Multi-Process Scenarios
//
// These tests spawn fcmd.exe subprocesses to exercise the cross-process
// mmap coordination (unload/reload events + semaphore).
//
// NOTE: The initial mmap holds only ~7 TrieBlocks (256 bytes - 24 header / 32
// per block). Tests that need more than ~6 total insertions will trigger a
// resize, and concurrent resizes hit Bug 3 (known limitation: two processes
// racing to resize simultaneously). Tests here are therefore limited to cases
// that stay below the resize threshold.
// ============================================================================

test "simple" {
    const temp_dir = (std.process.Environ{ .block = .global }).getAlloc(std.testing.allocator, "TEMP") catch (std.process.Environ{ .block = .global }).getAlloc(std.testing.allocator, "TMP") catch unreachable;
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
    const temp_dir = (std.process.Environ{ .block = .global }).getAlloc(std.testing.allocator, "TEMP") catch (std.process.Environ{ .block = .global }).getAlloc(std.testing.allocator, "TMP") catch unreachable;
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
    var verify_args = std.ArrayList([]const u8){};
    defer verify_args.deinit(std.testing.allocator);
    try verify_args.append(std.testing.allocator, exe_path);
    try verify_args.append(std.testing.allocator, "--test-mp");
    try verify_args.append(std.testing.allocator, "verify");
    try verify_args.append(std.testing.allocator, test_state_path);
    for (strings) |str| {
        try verify_args.append(std.testing.allocator, str);
    }

    var verify_ctrl = test_mp.ProcessController.init(std.testing.allocator);
    defer verify_ctrl.deinit();
    try verify_ctrl.spawn(verify_args.items);
    const verify_codes = try verify_ctrl.waitAll();
    defer std.testing.allocator.free(verify_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(verify_codes));
}

test "concurrent_reads" {
    // Inserts strings via a single insert_many process, then reads them concurrently
    // from 4 separate processes. Tests that multiple processes can simultaneously read
    // from the same mmap — the primary cross-process use case.
    //
    // insert_many is used instead of 4 separate insert processes because each separate
    // process increments the named semaphore in init_internal and windows.exitProcess
    // kills its background thread before it can decrement. With 4 separate inserts the
    // semaphore count accumulates, and the concurrent search processes' open_map may
    // race to recreate the named mapping while dirty pages are not yet visible in the
    // file, causing spurious magic_all_zero resets. A single insert_many process keeps
    // the count at 1 and ensures the file state is coherent before any reader starts.
    const temp_dir = (std.process.Environ{ .block = .global }).getAlloc(std.testing.allocator, "TEMP") catch (std.process.Environ{ .block = .global }).getAlloc(std.testing.allocator, "TMP") catch unreachable;
    defer std.testing.allocator.free(temp_dir);

    const test_state_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ temp_dir, "test_concurrent_reads" });
    defer std.testing.allocator.free(test_state_path);

    const cleanup_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ test_state_path, "trie.frog" });
    defer std.testing.allocator.free(cleanup_path);
    std.Io.Dir.cwd().deleteFile(std.testing.io, cleanup_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, cleanup_path) catch {};

    const exe_path = "zig-out\\bin\\fcmd.exe";
    const strings = [_][]const u8{ "aaa", "bbb", "ccc", "ddd" };

    // Insert all strings in a single process so the mmap is in a known good state
    // before any concurrent reader starts.
    var insert_args = std.ArrayList([]const u8){};
    defer insert_args.deinit(std.testing.allocator);
    try insert_args.append(std.testing.allocator, exe_path);
    try insert_args.append(std.testing.allocator, "--test-mp");
    try insert_args.append(std.testing.allocator, "insert_many");
    try insert_args.append(std.testing.allocator, test_state_path);
    for (strings) |s| try insert_args.append(std.testing.allocator, s);

    var insert_ctrl = test_mp.ProcessController.init(std.testing.allocator);
    defer insert_ctrl.deinit();
    try insert_ctrl.spawn(insert_args.items);
    const insert_codes = try insert_ctrl.waitAll();
    defer std.testing.allocator.free(insert_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(insert_codes));

    // Now search for each string concurrently from 4 separate processes.
    var read_ctrl = test_mp.ProcessController.init(std.testing.allocator);
    defer read_ctrl.deinit();
    for (strings) |str| {
        const args = [_][]const u8{ exe_path, "--test-mp", "search", test_state_path, str };
        try read_ctrl.spawn(&args);
    }
    const read_codes = try read_ctrl.waitAll();
    defer std.testing.allocator.free(read_codes);
    try std.testing.expect(test_mp.ProcessController.allSucceeded(read_codes));
}
