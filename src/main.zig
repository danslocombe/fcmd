const std = @import("std");
const alloc = @import("alloc.zig");
const Shell = @import("shell.zig").Shell;

const input = @import("input.zig");
const data = @import("data.zig");
const windows = @import("windows.zig");

pub var g_shell: Shell = undefined;

pub fn main() !void {
    windows.setup_console();
    windows.write_console("FroggyCMD v_alpha\n");

    data.BackingData.init();
    g_shell = Shell.init(&data.g_backing_data.trie_blocks);

    g_shell.draw();
    var buffer: [64]input.Input = undefined;
    var inputs_produced: usize = 0;
    while (input.read_input(&buffer, &inputs_produced)) {
        for (0..inputs_produced) |i| {
            g_shell.apply_input(buffer[i]);
        }

        g_shell.draw();
        alloc.clear_temp_alloc();
    }
}
