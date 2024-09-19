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
    std.debug.print("Arg count {}\n", .{args.len});
    var state_dir_override: ?[]const u8 = null;
    if (args.len > 1 and std.mem.eql(u8, args[1], "--debug")) {
        std.debug.print("Running in debug mode..\n", .{});
        log.debug_log_enabled = true;
        state_dir_override = std.fs.cwd().realpathAlloc(alloc.gpa.allocator(), ".") catch unreachable;
    }

    windows.setup_console();
    windows.write_console("FroggyCMD v_alpha\n");

    data.BackingData.init(state_dir_override);

    g_shell = Shell.init(&data.g_backing_data.trie_blocks);

    g_shell.draw();
    var buffer: [64]input.Input = undefined;
    var inputs_produced: usize = 0;
    while (input.read_input(&buffer, &inputs_produced)) {
        data.acquire_local_mutex();
        for (0..inputs_produced) |i| {
            g_shell.apply_input(buffer[i]);
        }

        g_shell.draw();
        alloc.clear_temp_alloc();
        data.release_local_mutex();
    }
}
