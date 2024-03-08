const std = @import("std");
const alloc = @import("alloc.zig");
const shell_lib = @import("shell.zig");

const console_input = @import("console_input.zig");
const data = @import("data.zig");
const windows = @import("windows.zig");
const run = @import("run.zig");

pub var h_stdout: *anyopaque = undefined;
pub var h_stdin: *anyopaque = undefined;

pub fn main() !void {
    var stdin = windows.GetStdHandle(windows.STD_INPUT_HANDLE);
    if (stdin == null) @panic("Failed to get stdin");
    h_stdin = stdin.?;

    var stdout = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);
    if (stdout == null) @panic("Failed to get stdin");
    h_stdout = stdout.?;

    var current_flags: u32 = 0;
    _ = windows.GetConsoleMode(h_stdin, &current_flags);
    const ENABLE_WINDOW_INPUT = 0x0008;
    const ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0200;

    if (windows.SetConsoleMode(h_stdin, current_flags | ENABLE_WINDOW_INPUT | ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING) == 0) @panic("Failed to set console mode");

    const UTF8Codepage = 65001;

    if (windows.SetConsoleCP(UTF8Codepage) == 0) @panic("Failed to set Console CodePage");
    if (windows.SetConsoleOutputCP(UTF8Codepage) == 0) @panic("Failed to set Console Output CodePage");

    std.os.windows.SetConsoleCtrlHandler(control_signal_handler, true) catch @panic("Failed to set control signal handler");

    write_console("FroggyCMD v_alpha\n");

    var backing = data.BackingData.init();
    var shell = shell_lib.Shell.init(backing.trie_blocks);

    var buffer: [64]console_input.Input = undefined;
    var inputs_produced: usize = 0;
    while (console_input.read_input(h_stdin, &buffer, &inputs_produced)) {
        for (0..inputs_produced) |i| {
            shell.apply_input(buffer[i]);
        }

        draw(&shell);
        alloc.clear_temp_alloc();
    }
}

pub fn draw(shell: *shell_lib.Shell) void {
    const set_cursor_x_to_zero = "\x1b[0G";
    const clear_to_end_of_line = "\x1b[K";

    const clear_commands = comptime std.fmt.comptimePrint("{s}{s}", .{ set_cursor_x_to_zero, clear_to_end_of_line });

    var preprompt = build_preprompt();
    defer (alloc.gpa.allocator().free(preprompt));

    var prompt_buffer: []const u8 = shell.current_prompt.bs.items;

    var completion_command: []const u8 = "";
    if (shell.current_completion) |completion| {
        // Magenta: 35
        // Red: 31
        // Cyan: 36
        completion_command = std.fmt.allocPrint(alloc.temp_alloc.allocator(), "\x1b[1m\x1b[36m{s}\x1b[0m", .{completion}) catch unreachable;
    }

    // TODO handle setting cursor y pos.
    var cursor_x_pos = preprompt.len + shell.current_prompt.char_index + 1;
    var set_cursor_to_prompt_pos = std.fmt.allocPrint(alloc.temp_alloc.allocator(), "\x1b[{}G", .{cursor_x_pos}) catch unreachable;

    var commands = [_][]const u8{
        clear_commands,
        preprompt,
        prompt_buffer,
        completion_command,
        set_cursor_to_prompt_pos,
    };

    var buffer = std.mem.concat(alloc.temp_alloc.allocator(), u8, &commands) catch unreachable;
    write_console(buffer);
}

pub fn write_console(cs: []const u8) void {
    var written: c_ulong = 0;
    var res = windows.WriteConsoleA(h_stdout, cs.ptr, @intCast(cs.len), &written, null);
    std.debug.assert(res != 0);
    std.debug.assert(written == cs.len);
}

pub fn build_preprompt() []const u8 {
    var cwd = std.fs.cwd();
    var buffer: [std.os.windows.PATH_MAX_WIDE * 3 + 1]u8 = undefined;
    var filename = std.os.getFdPath(cwd.fd, &buffer) catch unreachable;

    var ret = std.mem.concat(alloc.gpa.allocator(), u8, &.{ filename, ">>> " }) catch unreachable;
    return ret;
}

pub fn control_signal_handler(signal: std.os.windows.DWORD) callconv(std.os.windows.WINAPI) std.os.windows.BOOL {
    switch (signal) {
        std.os.windows.CTRL_C_EVENT => {
            //std.debug.print("Handling CTRL C\n", .{});
            return if (run.try_kill_running_process()) 1 else 0;
        },
        std.os.windows.CTRL_BREAK_EVENT => {
            //std.debug.print("Handling CTRL BREAK\n", .{});
            return if (run.try_kill_running_process()) 1 else 0;
        },
        std.os.windows.CTRL_CLOSE_EVENT => {
            //std.debug.print("Handling CTRL CLOSE\n", .{});
            return if (run.try_kill_running_process()) 1 else 0;
        },
        else => {
            // We don't handle any other events
            return 0;
        },
    }
}
