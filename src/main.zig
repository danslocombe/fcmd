const std = @import("std");
const alloc = @import("alloc.zig");
const Shell = @import("shell.zig").Shell;
const log = @import("log.zig");

const input = @import("input.zig");
const data = @import("data.zig");
const windows = @import("windows.zig");
const test_mp = @import("test_multiprocess.zig");

pub var g_shell: Shell = undefined;

fn printUsage() void {
    const usage =
        \\Fcmd v0.01 - Fast command-line tool
        \\
        \\Usage:
        \\  fcmd                                    Run interactive shell
        \\  fcmd --debug                            Run with debug logging
        \\  fcmd --test-mp <operation> <args...>   Run multi-process test operation
        \\
        \\Multi-process test operations:
        \\  insert <state_file> <string>           Insert string into state file
        \\  search <state_file> <string>           Search for string in state file
        \\  verify <state_file> <string1> ...      Verify all strings are in state file
        \\
    ;
    std.debug.print("{s}\n", .{usage});
}

fn runTestMode(args: []const []const u8) !u8 {
    if (args.len < 3) {
        std.debug.print("Error: --test-mp requires operation and arguments\n", .{});
        printUsage();
        return 1;
    }

    const operation_str = args[2];

    if (std.mem.eql(u8, operation_str, "insert")) {
        if (args.len < 5) {
            std.debug.print("Error: insert requires <state_file> <string>\n", .{});
            return 1;
        }
        const state_file = args[3];
        const string_to_insert = args[4];

        return try runInsertTest(state_file, string_to_insert);
    } else if (std.mem.eql(u8, operation_str, "search")) {
        if (args.len < 5) {
            std.debug.print("Error: search requires <state_file> <string>\n", .{});
            return 1;
        }
        const state_file = args[3];
        const string_to_search = args[4];

        return try runSearchTest(state_file, string_to_search);
    } else if (std.mem.eql(u8, operation_str, "verify")) {
        if (args.len < 4) {
            std.debug.print("Error: verify requires <state_file> <string1> [string2 ...]\n", .{});
            return 1;
        }
        const state_file = args[3];
        const strings_to_verify = args[4..];

        return try runVerifyTest(state_file, strings_to_verify);
    } else {
        std.debug.print("Error: Unknown operation '{s}'\n", .{operation_str});
        printUsage();
        return 1;
    }
}

fn runInsertTest(state_file: []const u8, string: []const u8) !u8 {
    const allocator = alloc.gpa.allocator();

    // Open and load the state file
    const file = std.fs.cwd().openFile(state_file, .{ .mode = .read_write }) catch |err| {
        std.debug.print("Error opening state file '{s}': {}\n", .{ state_file, err });
        return 1;
    };
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;

    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    const bytes_read = try file.preadAll(buffer, 0);
    if (bytes_read != file_size) {
        std.debug.print("Error: could not read entire file\n", .{});
        return 1;
    }

    // Set up trie from buffer
    var len: usize = 0;
    const len_ptr: *usize = @ptrCast(@alignCast(buffer.ptr + 16));
    len = len_ptr.*;

    const start = 16 + @sizeOf(usize);
    const trie_block_count = @divFloor(buffer.len - start, @sizeOf(@import("datastructures/lego_trie.zig").TrieBlock));
    const end = trie_block_count * @sizeOf(@import("datastructures/lego_trie.zig").TrieBlock);
    const trieblock_bytes = buffer[start .. start + end];

    const trie_blocks: []@import("datastructures/lego_trie.zig").TrieBlock = @alignCast(std.mem.bytesAsSlice(@import("datastructures/lego_trie.zig").TrieBlock, trieblock_bytes));

    var blocks_list = data.DumbList(@import("datastructures/lego_trie.zig").TrieBlock){
        .len = &len,
        .map = trie_blocks,
    };

    var trie = @import("datastructures/lego_trie.zig").Trie.init(&blocks_list);
    var view = trie.to_view();

    // Insert the string
    view.insert(string) catch |err| {
        std.debug.print("Error inserting string '{s}': {}\n", .{ string, err });
        return 1;
    };

    // Write len back
    len_ptr.* = len;

    // Write buffer back to file
    try file.seekTo(0);
    try file.writeAll(buffer);

    std.debug.print("Successfully inserted '{s}' into {s}\n", .{ string, state_file });
    return 0;
}

fn runSearchTest(state_file: []const u8, string: []const u8) !u8 {
    const allocator = alloc.gpa.allocator();

    const file = std.fs.cwd().openFile(state_file, .{}) catch |err| {
        std.debug.print("Error opening state file '{s}': {}\n", .{ state_file, err });
        return 1;
    };
    defer file.close();

    const stat = try file.stat();
    const file_size = stat.size;

    const buffer = try allocator.alloc(u8, file_size);
    defer allocator.free(buffer);

    const bytes_read = try file.preadAll(buffer, 0);
    if (bytes_read != file_size) {
        std.debug.print("Error: could not read entire file\n", .{});
        return 1;
    }

    // Set up trie from buffer
    var len: usize = 0;
    const len_ptr: *usize = @ptrCast(@alignCast(buffer.ptr + 16));
    len = len_ptr.*;

    const start = 16 + @sizeOf(usize);
    const trie_block_count = @divFloor(buffer.len - start, @sizeOf(@import("datastructures/lego_trie.zig").TrieBlock));
    const end = trie_block_count * @sizeOf(@import("datastructures/lego_trie.zig").TrieBlock);
    const trieblock_bytes = buffer[start .. start + end];

    const trie_blocks: []@import("datastructures/lego_trie.zig").TrieBlock = @alignCast(std.mem.bytesAsSlice(@import("datastructures/lego_trie.zig").TrieBlock, trieblock_bytes));

    var blocks_list = data.DumbList(@import("datastructures/lego_trie.zig").TrieBlock){
        .len = &len,
        .map = trie_blocks,
    };

    var trie = @import("datastructures/lego_trie.zig").Trie.init(&blocks_list);
    const view = trie.to_view();

    var walker = @import("datastructures/lego_trie.zig").TrieWalker.init(view, string);
    if (walker.walk_to() and walker.char_id == string.len) {
        std.debug.print("Found '{s}' in {s}\n", .{ string, state_file });
        return 0;
    } else {
        std.debug.print("Not found: '{s}' in {s}\n", .{ string, state_file });
        return 1;
    }
}

fn runVerifyTest(state_file: []const u8, strings: []const []const u8) !u8 {
    const allocator = alloc.gpa.allocator();

    const all_found = test_mp.verifyStringsInStateFile(allocator, state_file, strings) catch |err| {
        std.debug.print("Error verifying strings: {}\n", .{err});
        return 1;
    };

    if (all_found) {
        std.debug.print("All {d} strings verified in {s}\n", .{ strings.len, state_file });
        return 0;
    } else {
        std.debug.print("Verification failed for {s}\n", .{state_file});
        return 1;
    }
}

pub fn main() !void {
    var args = std.process.argsAlloc(alloc.gpa.allocator()) catch unreachable;
    defer std.process.argsFree(alloc.gpa.allocator(), args);

    // Check for test mode
    if (args.len > 1 and std.mem.eql(u8, args[1], "--test-mp")) {
        const exit_code = try runTestMode(args);
        std.process.exit(exit_code);
    }

    var state_dir_override: ?[]const u8 = null;
    if (args.len > 1 and std.mem.eql(u8, args[1], "--debug")) {
        std.debug.print("Running in debug mode..\n", .{});
        log.debug_log_enabled = true;
        state_dir_override = std.fs.cwd().realpathAlloc(alloc.gpa.allocator(), ".") catch unreachable;
    }

    windows.setup_console();
    windows.write_console("Fcmd v0.01\n");

    data.BackingData.init(state_dir_override);

    g_shell = Shell.init(&data.g_backing_data.trie_blocks);

    g_shell.draw();

    // Instead of a static buffer we need a resizable list as copy/paste can produce a lot of inputs.
    var buffer = std.ArrayList(input.Input){};
    while (input.read_input(&buffer)) {
        data.acquire_local_mutex();
        for (buffer.items) |in| {
            g_shell.apply_input(in);
        }

        g_shell.draw();
        data.release_local_mutex();

        alloc.clear_temp_alloc();
        buffer.clearRetainingCapacity();
    }
}
