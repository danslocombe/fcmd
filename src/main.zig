const std = @import("std");
const alloc = @import("alloc.zig");
const shell_lib = @import("shell.zig");

const input = @import("input.zig");
const data = @import("data.zig");
const windows = @import("windows.zig");

pub fn main() !void {
    windows.setup_console();
    windows.write_console("FroggyCMD v_alpha\n");

    var backing = data.BackingData.init();
    var shell = shell_lib.Shell.init(backing.trie_blocks);

    shell.draw();
    var buffer: [64]input.Input = undefined;
    var inputs_produced: usize = 0;
    while (input.read_input(&buffer, &inputs_produced)) {
        for (0..inputs_produced) |i| {
            shell.apply_input(buffer[i]);
        }

        shell.draw();
        alloc.clear_temp_alloc();
    }
}
