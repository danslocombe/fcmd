const std = @import("std");
const alloc = @import("alloc.zig");
const Shell = @import("shell.zig").Shell;
const log = @import("log.zig");

const input = @import("input.zig");
const data = @import("data.zig");
const windows = @import("windows.zig");
const test_mp = @import("test_multiprocess.zig");
const lego_trie = @import("datastructures/lego_trie.zig");

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
        \\  insert <state_path> <string>           Insert string into state file
        \\  search <state_path> <string>           Search for string in state file
        \\  verify <state_path> <string1> ...      Verify all strings are in state file
        \\
    ;
    std.debug.print("{s}\n", .{usage});
}

fn resolveAndCreateStatePath(state_path: []const u8) ![]const u8 {
    const allocator = alloc.gpa.allocator();

    // Convert to absolute path
    const abs_path = std.fs.cwd().realpathAlloc(allocator, state_path) catch |err| {
        // If path doesn't exist, try to create it
        if (err == error.FileNotFound) {
            // Create the directory
            std.fs.cwd().makePath(state_path) catch |make_err| {
                std.debug.print("Error creating directory '{s}': {}\n", .{ state_path, make_err });
                return make_err;
            };

            // Try to resolve again after creating
            return std.fs.cwd().realpathAlloc(allocator, state_path) catch |realpath_err| {
                std.debug.print("Error resolving path '{s}' after creation: {}\n", .{ state_path, realpath_err });
                return realpath_err;
            };
        }

        std.debug.print("Error resolving path '{s}': {}\n", .{ state_path, err });
        return err;
    };

    return abs_path;
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
            std.debug.print("Error: insert requires <state_path> <string>\n", .{});
            return 1;
        }
        const state_path = args[3];
        const string_to_insert = args[4];

        //std.debug.print("Inserting {s} into {s}", .{ string_to_insert, state_path });
        //std.debug.panic("Inserting {s} into {s}", .{ string_to_insert, state_path });
        return try runInsertTest(state_path, string_to_insert);
    } else if (std.mem.eql(u8, operation_str, "search")) {
        if (args.len < 5) {
            std.debug.print("Error: search requires <state_path> <string>\n", .{});
            return 1;
        }
        const state_path = args[3];
        const string_to_search = args[4];

        return try runSearchTest(state_path, string_to_search);
    } else if (std.mem.eql(u8, operation_str, "verify")) {
        if (args.len < 4) {
            std.debug.print("Error: verify requires <state_path> <string1> [string2 ...]\n", .{});
            return 1;
        }
        const state_path = args[3];
        const strings_to_verify = args[4..];

        return try runVerifyTest(state_path, strings_to_verify);
    } else if (std.mem.eql(u8, operation_str, "get-cost")) {
        if (args.len < 5) {
            std.debug.print("Error: get-cost requires <state_path> <string>\n", .{});
            return 1;
        }
        const state_path = args[3];
        const string_to_check = args[4];

        return try runGetCostTest(state_path, string_to_check);
    } else {
        std.debug.print("Error: Unknown operation '{s}'\n", .{operation_str});
        printUsage();
        return 1;
    }
}

fn runInsertTest(state_path: []const u8, string: []const u8) !u8 {
    const abs_path = resolveAndCreateStatePath(state_path) catch {
        return 1;
    };
    defer alloc.gpa.allocator().free(abs_path);

    // Open the state file using memory mapping (same as main path)
    var context = data.GlobalContext{};
    data.BackingData.init(abs_path, &context);

    // Create trie view from memory-mapped data
    var trie = lego_trie.Trie.init(&context.backing_data.trie_blocks);
    var view = trie.to_view();

    // Insert the string
    view.insert(string) catch |err| {
        std.debug.print("Error inserting string '{s}': {}\n", .{ string, err });
        return 1;
    };

    std.debug.print("Successfully inserted '{s}' into {s}\n", .{ string, state_path });
    return 0;
}

fn runSearchTest(state_path: []const u8, string: []const u8) !u8 {
    const abs_path = resolveAndCreateStatePath(state_path) catch {
        return 1;
    };
    defer alloc.gpa.allocator().free(abs_path);

    // Open the state file using memory mapping (same as main path)
    var context = data.GlobalContext{};
    data.BackingData.init(abs_path, &context);

    // Create trie view from memory-mapped data
    var trie = lego_trie.Trie.init(&context.backing_data.trie_blocks);
    const view = trie.to_view();

    var walker = lego_trie.TrieWalker.init(view, string);
    if (walker.walk_to() and walker.char_id == string.len) {
        std.debug.print("Found '{s}' in {s}\n", .{ string, state_path });
        return 0;
    } else {
        std.debug.print("Not found: '{s}' in {s}\n", .{ string, state_path });
        return 1;
    }
}

fn runVerifyTest(state_path: []const u8, strings: []const []const u8) !u8 {
    const allocator = alloc.gpa.allocator();

    const abs_path = resolveAndCreateStatePath(state_path) catch {
        return 1;
    };
    defer allocator.free(abs_path);

    // Open the state file using memory mapping (same as main path)
    var context = data.GlobalContext{};
    data.BackingData.init(abs_path, &context);

    // Create trie view from memory-mapped data
    var trie = lego_trie.Trie.init(&context.backing_data.trie_blocks);
    const view = trie.to_view();

    for (strings) |s| {
        var walker = lego_trie.TrieWalker.init(view, s);
        if (walker.walk_to() and walker.char_id == s.len) {
            // Found
        } else {
            std.debug.print("Not found: '{s}' in {s}\n", .{ s, state_path });
            return 1;
        }
    }

    std.debug.print("All {d} strings verified in {s}\n", .{ strings.len, state_path });
    return 0;
}

fn runGetCostTest(state_path: []const u8, string: []const u8) !u8 {
    const allocator = alloc.gpa.allocator();

    const abs_path = resolveAndCreateStatePath(state_path) catch {
        return 1;
    };
    defer allocator.free(abs_path);

    // Open the state file using memory mapping (same as main path)
    var context = data.MMapContext{};
    data.BackingData.init(abs_path, &context);

    // Create trie view from memory-mapped data
    var trie = lego_trie.Trie.init(&context.backing_data.trie_blocks);
    const view = trie.to_view();

    // Walk to the string and get its cost
    var walker = lego_trie.TrieWalker.init(view, string);
    if (walker.walk_to() and walker.char_id == string.len) {
        std.debug.print("{d}\n", .{walker.cost});
        return 0;
    }

    std.debug.print("String not found: '{s}'\n", .{string});
    return 1;
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

    const appdata: []const u8 = windows.get_appdata_path();
    const fcmd_appdata_dir = std.mem.concatWithSentinel(alloc.temp_alloc.allocator(), u8, &[_][]const u8{ appdata, "\\fcmd" }, 0) catch unreachable;
    defer alloc.gpa.allocator().free(appdata);

    var context = data.GlobalContext{};
    data.BackingData.init(fcmd_appdata_dir, &context);

    g_shell = Shell.init(&context.backing_data.trie_blocks);

    g_shell.draw();

    // Instead of a static buffer we need a resizable list as copy/paste can produce a lot of inputs.
    var buffer = std.ArrayList(input.Input){};
    while (input.read_input(&buffer)) {
        context.data_mutex.lock();
        for (buffer.items) |in| {
            g_shell.apply_input(in);
        }

        g_shell.draw();
        context.data_mutex.unlock();

        alloc.clear_temp_alloc();
        buffer.clearRetainingCapacity();
    }
}
