const std = @import("std");
const alloc = @import("alloc.zig");
const run = @import("run.zig");
const main = @import("main.zig");
const win32 = @import("win32");

const foundation = win32.foundation;
const console = win32.system.console;
const threading = win32.system.threading;
const memory = win32.system.memory;
const fs = win32.storage.file_system;
const env = win32.system.environment;
const dataex = win32.system.data_exchange;
const sysservices = win32.system.system_services;

// Types used by callers.
pub const INPUT_RECORD = console.INPUT_RECORD;
pub const KEY_EVENT = 1;

pub const PROCESS_INFORMATION = extern struct {
    hProcess: std.os.windows.HANDLE,
    hThread: std.os.windows.HANDLE,
    dwProcessId: std.os.windows.DWORD,
    dwThreadId: std.os.windows.DWORD,
};

pub const INFINITE: u32 = 0xFFFFFFFF;

// Raw u32 flag constants so callers can OR them like before.
pub const OPEN_ALWAYS: u32 = 4;
pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
pub const FILE_SHARE_READ: u32 = 0x1;
pub const FILE_SHARE_WRITE: u32 = 0x2;
pub const PAGE_READWRITE: u32 = 0x4;

const CTRL_C_EVENT: u32 = 0;
const CTRL_BREAK_EVENT: u32 = 1;
const CTRL_CLOSE_EVENT: u32 = 2;

const CF_UNICODETEXT: u32 = 13;

pub fn GetLastError() u32 {
    return @intFromEnum(foundation.GetLastError());
}

pub fn ReadConsoleInputW(h_input: *anyopaque, buf: [*]INPUT_RECORD, length: u32, num_read: *u32) i32 {
    return console.ReadConsoleInputW(h_input, buf, length, num_read);
}

pub fn CreateMutexA(security: ?*anyopaque, initial_owner: i32, name: ?[*:0]const u8) ?*anyopaque {
    return threading.CreateMutexA(@ptrCast(@alignCast(security)), initial_owner, name);
}

pub fn ReleaseMutex(h: ?*anyopaque) i32 {
    return threading.ReleaseMutex(h);
}

pub fn WaitForSingleObject(h: ?*anyopaque, ms: u32) u32 {
    return @intFromEnum(threading.WaitForSingleObject(h, ms));
}

pub fn CreateFileA(
    filename: [*c]const u8,
    access: u32,
    share: u32,
    security: ?*anyopaque,
    disposition: u32,
    attributes: u32,
    template: ?*anyopaque,
) ?*anyopaque {
    return fs.CreateFileA(
        filename,
        @bitCast(access),
        @bitCast(share),
        @ptrCast(@alignCast(security)),
        @enumFromInt(disposition),
        @bitCast(attributes),
        template,
    );
}

pub fn CreateFileMapping(
    file_handle: ?*anyopaque,
    security: ?*anyopaque,
    protect: u32,
    max_size_high: u32,
    max_size_low: u32,
    name: ?[*:0]const u8,
) ?*anyopaque {
    return memory.CreateFileMappingA(
        file_handle,
        @ptrCast(@alignCast(security)),
        @bitCast(protect),
        max_size_high,
        max_size_low,
        name,
    );
}

pub fn MapViewOfFile(
    map: ?*anyopaque,
    access: u32,
    offset_high: u32,
    offset_low: u32,
    num_bytes: usize,
) ?*anyopaque {
    return memory.MapViewOfFile(map, @bitCast(access), offset_high, offset_low, num_bytes);
}

pub fn UnmapViewOfFile(base: ?*const anyopaque) i32 {
    return memory.UnmapViewOfFile(base);
}

pub fn FlushViewOfFile(base: ?*const anyopaque, n: usize) i32 {
    return memory.FlushViewOfFile(base, n);
}

pub fn GenerateConsoleCtrlEvent(event: u32, group: u32) i32 {
    return console.GenerateConsoleCtrlEvent(event, group);
}

pub fn SetCurrentDirectoryW(path: [*:0]const u16) bool {
    return env.SetCurrentDirectoryW(path) != 0;
}

pub fn CreateProcessW(
    lp_command_line: [*:0]u16,
    creation_flags: u32,
    startup_info: *std.os.windows.STARTUPINFOW,
    process_info: *PROCESS_INFORMATION,
) bool {
    return threading.CreateProcessW(
        null,
        lp_command_line,
        null,
        null,
        1,
        @bitCast(creation_flags),
        null,
        null,
        @ptrCast(startup_info),
        @ptrCast(process_info),
    ) != 0;
}

/// Call Win32 ExitProcess directly, bypassing any Zig runtime cleanup that
/// could block on background threads.
pub fn exitProcess(exit_code: u32) noreturn {
    threading.ExitProcess(exit_code);
}

pub var g_stdout: *anyopaque = undefined;
pub var g_stdin: *anyopaque = undefined;

pub var buffered_ctrl_c = false;

pub fn setup_console() void {
    const stdin = console.GetStdHandle(console.STD_INPUT_HANDLE);
    g_stdin = stdin;

    const stdout = console.GetStdHandle(console.STD_OUTPUT_HANDLE);
    g_stdout = stdout;

    set_console_mode();

    // Add handle for Ctrl + C.
    if (console.SetConsoleCtrlHandler(control_signal_handler, 1) == 0) @panic("Failed to set control signal handler");
}

pub fn set_console_mode() void {
    var current_mode: console.CONSOLE_MODE = @bitCast(@as(u32, 0));
    _ = console.GetConsoleMode(g_stdin, &current_mode);

    const ENABLE_WINDOW_INPUT_U32: u32 = 0x0008;
    const ENABLE_VIRTUAL_TERMINAL_INPUT_U32: u32 = 0x0200;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING_U32: u32 = 0x0004;

    const new_mode_u32 = @as(u32, @bitCast(current_mode)) |
        ENABLE_WINDOW_INPUT_U32 |
        ENABLE_VIRTUAL_TERMINAL_INPUT_U32 |
        ENABLE_VIRTUAL_TERMINAL_PROCESSING_U32;

    if (console.SetConsoleMode(g_stdin, @bitCast(new_mode_u32)) == 0) @panic("Failed to set console mode");

    const UTF8Codepage = 65001;

    if (console.SetConsoleCP(UTF8Codepage) == 0) @panic("Failed to set Console CodePage");
    if (console.SetConsoleOutputCP(UTF8Codepage) == 0) @panic("Failed to set Console Output CodePage");
}

pub fn word_is_local_path(word: []const u8) bool {
    if (std.fs.path.isAbsolute(word)) {
        return false;
    }

    // @Speed don't format just directly alloc
    const wordZ = std.fmt.allocPrintSentinel(alloc.temp_alloc.allocator(), "{s}", .{word}, 0) catch unreachable;
    const word_u16 = std.unicode.utf8ToUtf16LeAllocZ(alloc.temp_alloc.allocator(), wordZ) catch unreachable;

    const file_attributes = fs.GetFileAttributesW(word_u16);

    return file_attributes != fs.INVALID_FILE_ATTRIBUTES;
}

pub fn get_appdata_path() []const u8 {
    const appdata_literal = std.unicode.utf8ToUtf16LeAllocZ(alloc.temp_alloc.allocator(), "APPDATA") catch unreachable;
    var buffer: [256]u16 = undefined;
    const len = env.GetEnvironmentVariableW(appdata_literal, @ptrCast(&buffer), 256);
    return std.unicode.utf16LeToUtf8Alloc(alloc.gpa.allocator(), buffer[0..len]) catch unreachable;
}

pub fn get_env_var(name: []const u8) ?[]const u8 {
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(alloc.temp_alloc.allocator(), name) catch return null;
    var buffer: [32768]u16 = undefined;
    const len = env.GetEnvironmentVariableW(name_w, @ptrCast(&buffer), buffer.len);
    if (len == 0) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc.temp_alloc.allocator(), buffer[0..len]) catch null;
}

pub fn get_console_width() usize {
    var info: console.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (console.GetConsoleScreenBufferInfo(g_stdout, &info) != 0) {
        const width = info.srWindow.Right - info.srWindow.Left + 1;
        if (width > 0) return @intCast(width);
    }
    return 80;
}

pub fn write_console(cs: []const u8) void {
    var written: u32 = 0;
    const res = console.WriteConsoleA(g_stdout, cs.ptr, @intCast(cs.len), &written, null);
    std.debug.assert(res != 0);
    std.debug.assert(written == cs.len);
}

pub fn copy_to_clipboard(s: []const u8) void {
    if (dataex.OpenClipboard(null) == 0) {
        // Failed to open clipboard
        return;
    }

    if (dataex.EmptyClipboard() == 0) @panic("Failed to empty the clipboard");

    const s_utf16: [:0]u16 = std.unicode.utf8ToUtf16LeAllocZ(alloc.temp_alloc.allocator(), s) catch unreachable;
    const byte_count: usize = (s_utf16.len + 1) * @sizeOf(u16);
    const data_handle_isize = memory.GlobalAlloc(@bitCast(@as(u32, 0)), byte_count);
    if (data_handle_isize == 0) @panic("GlobalAlloc call failed when trying to copy to the clipboard");

    const allocated: [*]u16 = @ptrCast(@alignCast(memory.GlobalLock(data_handle_isize)));
    @memcpy(allocated, s_utf16);
    _ = dataex.SetClipboardData(CF_UNICODETEXT, @ptrFromInt(@as(usize, @bitCast(data_handle_isize))));

    _ = memory.GlobalUnlock(data_handle_isize);
    _ = dataex.CloseClipboard();
}

pub fn control_signal_handler(signal: u32) callconv(.winapi) i32 {
    switch (signal) {
        CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT => {
            if (run.try_interupt_running_process()) {
                // We have passed the interupt downstream to the running program.
                // Let it handle it.
            } else {
                buffered_ctrl_c = true;

                // Ugh this is a bit ugly
                // Is this what we want?
                // This makes it easy to accidently kill the shell which would be super annoying.
                // Maybe print a message on how to exit?
                if (main.g_shell.prompt.highlight != null) {
                    return 1;
                } else {
                    write_console("\nTo exit fcmd use the command 'exit'\n");
                }
            }

            return 1;
        },
        else => {
            // We don't handle any other events
            return 0;
        },
    }
}
