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
        \\Fcmd v0.01
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
    const state_file_c = alloc.tmp_for_c_introp(state_file);

    // Open the state file using memory mapping (same as main path)
    var backing_data = data.BackingData.open_test_state_file(state_file_c) catch |err| {
        std.debug.print("Error opening state file '{s}': {}\n", .{ state_file, err });
        return 1;
    };
    defer backing_data.close_test_state_file();

    // Create trie view from memory-mapped data
    var trie = @import("datastructures/lego_trie.zig").Trie.init(&backing_data.trie_blocks);
    var view = trie.to_view();

    // Insert the string
    view.insert(string) catch |err| {
        std.debug.print("Error inserting string '{s}': {}\n", .{ string, err });
        return 1;
    };

    std.debug.print("Successfully inserted '{s}' into {s}\n", .{ string, state_file });
    return 0;
}

fn runSearchTest(state_file: []const u8, string: []const u8) !u8 {
    const state_file_c = alloc.tmp_for_c_introp(state_file);

    // Open the state file using memory mapping (same as main path)
    var backing_data = data.BackingData.open_test_state_file(state_file_c) catch |err| {
        std.debug.print("Error opening state file '{s}': {}\n", .{ state_file, err });
        return 1;
    };
    defer backing_data.close_test_state_file();

    // Create trie view from memory-mapped data
    var trie = @import("datastructures/lego_trie.zig").Trie.init(&backing_data.trie_blocks);
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

    _ = data.init_global_context(state_dir_override);

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
