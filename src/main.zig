const std = @import("std");
const trie = @import("trie.zig");
const simple_trie = @import("simple_trie.zig");

const alloc = @import("alloc.zig");
const shell_lib = @import("shell.zig");

const console_input = @import("console_input.zig");
const data = @import("data.zig");
const windows = @import("windows.zig");

pub var h_stdout: *anyopaque = undefined;
pub var h_stdin: *anyopaque = undefined;

pub fn main_shell() !void {
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

    write_console("FroggyCMD 🐸!\n");

    var shell = shell_lib.Shell.init();

    var backing = data.BackingData.init();
    _ = backing;

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
        completion_command = std.fmt.allocPrint(alloc.temp_alloc.allocator(), "\x1b[1m\x1b[31m{s}\x1b[0m", .{completion}) catch unreachable;
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

pub fn main() anyerror!void {
    //std.log.info("All your codebase are belong to us.", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var strings = [_][]const u8{ "bug", "bad", "coffee", "covefe" };

    std.log.info("Hello", .{});

    std.log.info("\n\nBuilding", .{});

    var demo_trie = try simple_trie.Trie.init(gpa.allocator());
    var view = demo_trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    std.log.info("\n\nQuerying", .{});

    var res = view.walk_to("bu");

    std.log.info("{}", .{res});

    //var builder = trie.ZoomTrieBuilder.init(gpa.allocator());
    //defer(builder.deinit());

    //for (strings) |s| {
    //    std.log.info("Adding observation {}", .{s});
    //    builder.add_observation(s);
    //}

    //var demo_trie = try builder.build();
    //demo_trie.dump(gpa.allocator());

    //var chunk = try trie.create_chunk(gpa.allocator(), strings[0..strings.len]);
    //try std.fs.cwd().writeFile("test.chunk", chunk.data);
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
