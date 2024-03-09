const std = @import("std");
const alloc = @import("alloc.zig");
const run = @import("run.zig");
const main = @import("main.zig");

const import = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("Windows.h");
});

pub usingnamespace import;

pub var g_stdout: *anyopaque = undefined;
pub var g_stdin: *anyopaque = undefined;

pub var buffered_ctrl_c = false;

pub fn setup_console() void {
    var stdin = import.GetStdHandle(import.STD_INPUT_HANDLE);
    if (stdin == null) @panic("Failed to get stdin");
    g_stdin = stdin.?;

    var stdout = import.GetStdHandle(import.STD_OUTPUT_HANDLE);
    if (stdout == null) @panic("Failed to get stdin");
    g_stdout = stdout.?;

    set_console_mode();

    // Add handle for Ctrl + C.
    std.os.windows.SetConsoleCtrlHandler(control_signal_handler, true) catch @panic("Failed to set control signal handler");
}

pub fn set_console_mode() void {
    var current_flags: u32 = 0;
    _ = import.GetConsoleMode(g_stdin, &current_flags);
    const ENABLE_WINDOW_INPUT = 0x0008;
    const ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0200;

    if (import.SetConsoleMode(g_stdin, current_flags | ENABLE_WINDOW_INPUT | ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING) == 0) @panic("Failed to set console mode");

    const UTF8Codepage = 65001;

    if (import.SetConsoleCP(UTF8Codepage) == 0) @panic("Failed to set Console CodePage");
    if (import.SetConsoleOutputCP(UTF8Codepage) == 0) @panic("Failed to set Console Output CodePage");
}

pub fn word_is_local_path(word: []const u8) bool {
    if (std.fs.path.isAbsolute(word)) {
        return false;
    }

    // @Speed don't format just directly alloc
    var wordZ = std.fmt.allocPrintZ(alloc.temp_alloc.allocator(), "{s}", .{word}) catch unreachable;
    var word_u16 = std.unicode.utf8ToUtf16LeWithNull(alloc.temp_alloc.allocator(), wordZ) catch unreachable;

    var file_attributes = import.GetFileAttributesW(word_u16);

    return file_attributes != import.INVALID_FILE_ATTRIBUTES;
}

pub fn get_appdata_path() []const u8 {
    var appdata_literal = std.unicode.utf8ToUtf16LeWithNull(alloc.temp_alloc.allocator(), "APPDATA") catch unreachable;
    var buffer: [256]u16 = undefined;
    var len = import.GetEnvironmentVariableW(appdata_literal, &buffer, 256);
    return std.unicode.utf16leToUtf8Alloc(alloc.gpa.allocator(), buffer[0..len]) catch unreachable;
}

pub fn write_console(cs: []const u8) void {
    var written: c_ulong = 0;
    var res = import.WriteConsoleA(g_stdout, cs.ptr, @intCast(cs.len), &written, null);
    std.debug.assert(res != 0);
    std.debug.assert(written == cs.len);
}

pub fn copy_to_clipboard(s: []const u8) void {
    if (import.OpenClipboard(null) == 0) {
        // Failed to open clipboard
        return;
    }

    if (import.EmptyClipboard() == 0) @panic("Failed to empty the clipboard");

    var s_utf16: [:0]u16 = std.unicode.utf8ToUtf16LeWithNull(alloc.temp_alloc.allocator(), s) catch unreachable;
    var data_handle = import.GlobalAlloc(0, (s_utf16.len + 1) * @sizeOf(u16));
    if (data_handle == null) @panic("GlobalAlloc call failed when trying to copy to the clipboard");

    var allocated: [*]u16 = @ptrCast(@alignCast(import.GlobalLock(data_handle)));
    @memcpy(allocated, s_utf16);
    _ = import.SetClipboardData(import.CF_UNICODETEXT, data_handle);

    _ = import.GlobalUnlock(allocated);
    _ = import.CloseClipboard();
}

pub fn control_signal_handler(signal: std.os.windows.DWORD) callconv(std.os.windows.WINAPI) std.os.windows.BOOL {
    switch (signal) {
        std.os.windows.CTRL_C_EVENT, std.os.windows.CTRL_BREAK_EVENT => {
            //return if (run.try_kill_running_process()) 1 else 0;
            if (run.try_kill_running_process()) {
                // Ok
                return 1;
            } else {
                buffered_ctrl_c = true;

                // Ugh this is a bit ugly
                // Is this what we want?
                // This makes it easy to accidently kill the shell which would be super annoying.
                // Maybe print a message on how to exit?
                if (main.g_shell.prompt.highlight != null) {
                    return 1;
                } else {
                    return 0;
                }
            }
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
