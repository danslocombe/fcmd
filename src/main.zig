const std = @import("std");
const trie = @import("trie.zig");
const simple_trie = @import("simple_trie.zig");

const alloc = @import("alloc.zig");
const shell_lib = @import("shell.zig");

const console_input = @import("console_input.zig");
const data = @import("data.zig");
const windows = @import("windows.zig");

pub fn main() !void {
    var h_stdin = windows.GetStdHandle(windows.STD_INPUT_HANDLE);
    if (h_stdin == null) @panic("Failed to get stdin");

    var h_stdout = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE);
    if (h_stdout == null) @panic("Failed to get stdin");

    var current_flags: u32 = 0;
    _ = windows.GetConsoleMode(h_stdin, &current_flags);
    const ENABLE_WINDOW_INPUT = 0x0008;
    const ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0200;

    if (windows.SetConsoleMode(h_stdin, current_flags | ENABLE_WINDOW_INPUT | ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING) == 0) @panic("Failed to set console mode");

    const UTF8Codepage = 65001;

    if (windows.SetConsoleCP(UTF8Codepage) == 0) @panic("Failed to set Console CodePage");
    if (windows.SetConsoleOutputCP(UTF8Codepage) == 0) @panic("Failed to set Console Output CodePage");

    var shell = shell_lib.Shell.init();

    var backing = data.BackingData.init();
    _ = backing;

    var buffer: [128]windows.INPUT_RECORD = undefined;
    var records_read: u32 = 0;
    while (windows.ReadConsoleInputW(h_stdin, &buffer, 128, &records_read) != 0) {
        var buffered_utf16_chars: [4]u16 = alloc.zeroed(u16, 4);
        var buffered_utf16_len: usize = 0;

        for (0..@intCast(records_read)) |i| {
            var record = buffer[i];
            if (record.EventType == windows.KEY_EVENT) {
                var key_event = record.Event.KeyEvent;
                // Only care about keydown events.
                if (key_event.bKeyDown == 0) {
                    continue;
                }

                var utf16Char = key_event.uChar.UnicodeChar;

                buffered_utf16_chars[buffered_utf16_len] = utf16Char;
                buffered_utf16_len += 1;

                var utf8Char = console_input.Utf8Char{};
                _ = std.unicode.utf16leToUtf8(&utf8Char.bs, &buffered_utf16_chars) catch {
                    continue;
                };

                buffered_utf16_len = 0;

                var ci = console_input.ConsoleInput{
                    .key = key_event.wVirtualKeyCode,
                    .utf8_char = utf8Char,
                    .modifier_keys = key_event.dwControlKeyState,
                };

                var input = console_input.Input.from_console_input(ci);

                var command = shell_lib.Command{
                    .Input = input,
                };

                shell.apply_command(command);
            }
        }
        draw(h_stdout, &shell);
        alloc.clear_temp_alloc();
    }
}

pub fn draw(h_stdout: ?*anyopaque, shell: *shell_lib.Shell) void {
    const set_cursor_x_to_zero = "\x1b[0G";
    const clear_to_end_of_line = "\x1b[K";

    const commands = comptime std.fmt.comptimePrint("{s}{s}", .{ set_cursor_x_to_zero, clear_to_end_of_line });

    var preprompt = build_preprompt();
    defer (alloc.gpa.allocator().free(preprompt));

    var prompt_buffer: []const u8 = shell.current_prompt.bs.items;

    var buffer = std.mem.concat(alloc.temp_alloc.allocator(), u8, &.{ commands, preprompt, ">>> ", prompt_buffer }) catch unreachable;
    var written: c_ulong = 0;
    var res = windows.WriteConsoleA(h_stdout, buffer.ptr, @intCast(buffer.len), &written, null);
    std.debug.assert(res != 0);
    std.debug.assert(written == buffer.len);
}

pub fn build_preprompt() []const u8 {
    var cwd = std.fs.cwd();
    var buffer: [std.os.windows.PATH_MAX_WIDE * 3 + 1]u8 = undefined;
    var filename = std.os.getFdPath(cwd.fd, &buffer) catch unreachable;
    var ret = alloc.gpa_alloc_idk(u8, filename.len);
    @memcpy(ret, filename);

    return ret;
}

pub fn main_old() anyerror!void {
    //std.log.info("All your codebase are belong to us.", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var strings = [_][]const u8{ "bug", "fly", "coffee", "daniel" };

    std.log.info("Hello", .{});

    std.mem.doNotOptimizeAway(strings);

    std.log.info("\n\nBuilding", .{});

    var demo_trie = try simple_trie.Trie.init(gpa.allocator());
    var view = demo_trie.to_view();
    try view.insert("bug");

    std.log.info("\n\nQuerying", .{});

    var res = view.walk_to("bu");

    std.log.info("{}", .{res});

    std.mem.doNotOptimizeAway(view);
    std.mem.doNotOptimizeAway(res);

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
