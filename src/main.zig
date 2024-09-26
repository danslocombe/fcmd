const std = @import("std");
const alloc = @import("alloc.zig");
const Shell = @import("shell.zig").Shell;
const log = @import("log.zig");

const input = @import("input.zig");
const data = @import("data.zig");
const windows = @import("windows.zig");

pub var g_shell: Shell = undefined;

pub fn main() !void {
    var args = std.process.argsAlloc(alloc.gpa.allocator()) catch unreachable;
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
    var buffer = std.ArrayList(input.Input).init(alloc.gpa.allocator());
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
