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

// Changelog
// ----------------------
// v0.01.02 - Fix bug where commands that are an exact prefix of other commands would not
//            correctly update costs.

const current_version: []const u8 = "v0.01.02";

pub fn main(init: std.process.Init) !void {
    alloc.g_io = init.io;

    var args_arena = std.heap.ArenaAllocator.init(alloc.gpa.allocator());
    defer args_arena.deinit();
    const args = try init.minimal.args.toSlice(args_arena.allocator());

    if (args.len > 1 and std.mem.eql(u8, args[1], "--help")) {
        print_usage();
        return;
    }

    // Multiprocess test mode
    if (args.len > 1 and std.mem.eql(u8, args[1], "--test-mp")) {
        const exit_code = mp_test_mode(args) catch 1;

        // Use ExitProcess directly: std.process.exit does not terminate background
        // threads spawned by BackingData.init in Zig 0.16-dev, causing a hang.
        windows.exit_process(@intCast(exit_code));
    }

    var state_dir_override: ?[]const u8 = null;
    if (args.len > 1 and std.mem.eql(u8, args[1], "--debug")) {
        std.debug.print("Running in debug mode..\n", .{});
        log.debug_log_enabled = true;
        state_dir_override = std.Io.Dir.realPathFileAlloc(std.Io.Dir.cwd(), alloc.g_io, ".", alloc.gpa.allocator()) catch unreachable;
        std.debug.print("Overriding state dir with {s}\n", .{state_dir_override.?});
    }

    windows.setup_console();

    const startup_str = std.fmt.allocPrint(alloc.temp_alloc.allocator(), "Fcmd {s}\n", .{current_version}) catch unreachable;
    windows.write_console(startup_str);

    const appdata: []const u8 = windows.get_appdata_path();
    const fcmd_appdata_dir = std.mem.concatWithSentinel(alloc.temp_alloc.allocator(), u8, &[_][]const u8{ appdata, "\\fcmd" }, 0) catch unreachable;
    defer alloc.gpa.allocator().free(appdata);

    var context = data.GlobalContext{};
    data.BackingData.init(fcmd_appdata_dir, &context);

    g_shell = Shell.init(&context.backing_data.trie_blocks);

    g_shell.draw();

    // Instead of a static buffer we need a resizable list as copy/paste can produce a lot of inputs.
    var buffer: std.ArrayList(input.Input) = .empty;
    var should_exit = false;
    while (!should_exit and input.read_input(&buffer)) {
        for (buffer.items) |in| {
            if (g_shell.apply_input(in)) {
                should_exit = true;
                break;
            }
        }

        if (!should_exit) g_shell.draw();

        alloc.clear_temp_alloc();
        buffer.clearRetainingCapacity();
    }

    // Flush the trie to disk before exiting. ExitProcess does not flush dirty pages.
    windows.flush_view(context.backing_data.map_view_pointer);
}

fn print_usage() void {
    const usage_fmt =
        \\Fcmd {s}
        \\
        \\Usage:
        \\  fcmd                                   Run interactive shell
        \\  fcmd --help                            Print this
        \\  fcmd --debug                           Run with debug logging
        \\  fcmd --test-mp <operation> <args...>   Run multi-process test operation
        \\
        \\Multi-process test operations:
        \\  insert <state_path> <string>           Insert string into state file
        \\  search <state_path> <string>           Search for string in state file
        \\  verify <state_path> <string1> ...      Verify all strings are in state file
        \\
    ;
    std.debug.print(usage_fmt, .{current_version});
}

// Multiprocess test mode
fn mp_test_mode(args: []const [:0]const u8) !u8 {
    if (args.len < 3) {
        std.debug.print("Error: --test-mp requires operation and arguments\n", .{});
        print_usage();
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

        return try mp_test_insert(state_path, string_to_insert);
    } else if (std.mem.eql(u8, operation_str, "search")) {
        if (args.len < 5) {
            std.debug.print("Error: search requires <state_path> <string>\n", .{});
            return 1;
        }
        const state_path = args[3];
        const string_to_search = args[4];

        return try mp_test_search(state_path, string_to_search);
    } else if (std.mem.eql(u8, operation_str, "verify")) {
        if (args.len < 4) {
            std.debug.print("Error: verify requires <state_path> <string1> [string2 ...]\n", .{});
            return 1;
        }
        const state_path = args[3];
        const strings_to_verify = args[4..];

        return try mp_test_verify(state_path, strings_to_verify);
    } else if (std.mem.eql(u8, operation_str, "insert_many")) {
        if (args.len < 5) {
            std.debug.print("Error: insert_many requires <state_path> <string1> [string2 ...]\n", .{});
            return 1;
        }
        const state_path = args[3];
        const strings_to_insert = args[4..];

        return try mp_test_insert_many(state_path, strings_to_insert);
    } else if (std.mem.eql(u8, operation_str, "get-cost")) {
        if (args.len < 5) {
            std.debug.print("Error: get-cost requires <state_path> <string>\n", .{});
            return 1;
        }
        const state_path = args[3];
        const string_to_check = args[4];

        return try mp_test_get_cost(state_path, string_to_check);
    } else {
        std.debug.print("Error: Unknown operation '{s}'\n", .{operation_str});
        print_usage();
        return 1;
    }
}

fn mp_test_insert(state_path: []const u8, string: []const u8) !u8 {
    const abs_path = mp_test_resolve_state_path(state_path) catch {
        return 1;
    };
    defer alloc.gpa.allocator().free(abs_path);

    var context = data.GlobalContext{};
    data.BackingData.init(abs_path, &context);

    var trie = lego_trie.Trie.init(&context.backing_data.trie_blocks);
    var view = trie.to_view();
    view.insert(string) catch |err| {
        std.debug.print("Error inserting string '{s}': {}\n", .{ string, err });
        return 1;
    };

    windows.flush_view(context.backing_data.map_view_pointer);
    windows.unmap_view(context.backing_data.map_view_pointer);

    std.debug.print("Successfully inserted '{s}' into {s}\n", .{ string, state_path });
    return 0;
}

fn mp_test_insert_many(state_path: []const u8, strings: []const [:0]const u8) !u8 {
    const abs_path = mp_test_resolve_state_path(state_path) catch {
        return 1;
    };
    defer alloc.gpa.allocator().free(abs_path);

    var context = data.GlobalContext{};
    data.BackingData.init(abs_path, &context);

    var trie = lego_trie.Trie.init(&context.backing_data.trie_blocks);
    var view = trie.to_view();

    for (strings) |string| {
        view.insert(string) catch |err| {
            std.debug.print("Error inserting string '{s}': {}\n", .{ string, err });
            return 1;
        };
        std.debug.print("Inserted '{s}'\n", .{string});
    }

    windows.flush_view(context.backing_data.map_view_pointer);
    windows.unmap_view(context.backing_data.map_view_pointer);

    std.debug.print("insert_many: inserted {d} strings into {s}\n", .{ strings.len, state_path });
    return 0;
}

fn mp_test_search(state_path: []const u8, string: []const u8) !u8 {
    const abs_path = mp_test_resolve_state_path(state_path) catch {
        return 1;
    };
    defer alloc.gpa.allocator().free(abs_path);

    var context = data.GlobalContext{};
    data.BackingData.init(abs_path, &context);

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

fn mp_test_verify(state_path: []const u8, strings: []const [:0]const u8) !u8 {
    const allocator = alloc.gpa.allocator();

    const abs_path = mp_test_resolve_state_path(state_path) catch {
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

fn mp_test_get_cost(state_path: []const u8, string: []const u8) !u8 {
    const allocator = alloc.gpa.allocator();

    const abs_path = mp_test_resolve_state_path(state_path) catch {
        return 1;
    };
    defer allocator.free(abs_path);

    var context = data.MMapContext{};
    data.BackingData.init(abs_path, &context);

    var trie = lego_trie.Trie.init(&context.backing_data.trie_blocks);
    const view = trie.to_view();
    var walker = lego_trie.TrieWalker.init(view, string);
    if (walker.walk_to() and walker.char_id == string.len) {
        std.debug.print("{d}\n", .{walker.cost});
        return 0;
    }

    std.debug.print("String not found: '{s}'\n", .{string});
    return 1;
}

fn mp_test_resolve_state_path(state_path: []const u8) ![:0]u8 {
    const allocator = alloc.gpa.allocator();
    const io = alloc.g_io;
    const cwd = std.Io.Dir.cwd();

    // Convert to absolute path
    const abs_path = std.Io.Dir.realPathFileAlloc(cwd, io, state_path, allocator) catch |err| {
        // If path doesn't exist, try to create it
        if (err == error.FileNotFound) {
            // Create the directory
            std.Io.Dir.createDirPath(cwd, io, state_path) catch |make_err| {
                std.debug.print("Error creating directory '{s}': {}\n", .{ state_path, make_err });
                return make_err;
            };

            // Try to resolve again after creating
            return std.Io.Dir.realPathFileAlloc(cwd, io, state_path, allocator) catch |realpath_err| {
                std.debug.print("Error resolving path '{s}' after creation: {}\n", .{ state_path, realpath_err });
                return realpath_err;
            };
        }

        std.debug.print("Error resolving path '{s}': {}\n", .{ state_path, err });
        return err;
    };

    return abs_path;
}
