const std = @import("std");
const alloc = @import("alloc.zig");
const run = @import("run.zig");
const main = @import("main.zig");

const import = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("Windows.h");
});

// Export commonly used types and functions from Windows API
pub const INPUT_RECORD = import.INPUT_RECORD;
pub const KEY_EVENT = import.KEY_EVENT;
pub const ReadConsoleInputW = import.ReadConsoleInputW;
pub const CreateSemaphoreA = import.CreateSemaphoreA;
pub const ReleaseSemaphore = import.ReleaseSemaphore;
pub const GetLastError = import.GetLastError;
pub const CreateEventA = import.CreateEventA;
pub const ResetEvent = import.ResetEvent;
pub const SetEvent = import.SetEvent;
pub const WaitForSingleObject = import.WaitForSingleObject;
pub const CreateFileA = import.CreateFileA;
pub const CreateFileMapping = import.CreateFileMapping;
pub const MapViewOfFile = import.MapViewOfFile;
pub const OpenFileMappingA = import.OpenFileMappingA;
pub const OPEN_ALWAYS = import.OPEN_ALWAYS;
pub const FILE_ATTRIBUTE_NORMAL = import.FILE_ATTRIBUTE_NORMAL;
pub const FILE_SHARE_WRITE = import.FILE_SHARE_WRITE;
pub const PAGE_READWRITE = import.PAGE_READWRITE;
pub const GetFileAttributesW = import.GetFileAttributesW;
pub const GetEnvironmentVariableW = import.GetEnvironmentVariableW;
pub const WriteConsoleA = import.WriteConsoleA;
pub const GlobalAlloc = import.GlobalAlloc;
pub const GlobalLock = import.GlobalLock;
pub const GlobalUnlock = import.GlobalUnlock;
pub const OpenClipboard = import.OpenClipboard;
pub const EmptyClipboard = import.EmptyClipboard;
pub const SetClipboardData = import.SetClipboardData;
pub const CloseClipboard = import.CloseClipboard;
pub const CF_UNICODETEXT = import.CF_UNICODETEXT;
pub const GetConsoleMode = import.GetConsoleMode;
pub const SetConsoleMode = import.SetConsoleMode;
pub const ENABLE_PROCESSED_INPUT = import.ENABLE_PROCESSED_INPUT;
pub const ENABLE_WINDOW_INPUT = import.ENABLE_WINDOW_INPUT;
pub const ENABLE_MOUSE_INPUT = import.ENABLE_MOUSE_INPUT;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING = import.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
pub const ENABLE_PROCESSED_OUTPUT = import.ENABLE_PROCESSED_OUTPUT;
pub const STD_INPUT_HANDLE = import.STD_INPUT_HANDLE;
pub const STD_OUTPUT_HANDLE = import.STD_OUTPUT_HANDLE;
pub const GetStdHandle = import.GetStdHandle;
pub const GenerateConsoleCtrlEvent = import.GenerateConsoleCtrlEvent;
pub const Sleep = import.Sleep;
pub const GetFileSizeEx = import.GetFileSizeEx;
pub const UnmapViewOfFile = import.UnmapViewOfFile;
pub const FlushViewOfFile = import.FlushViewOfFile;
pub const GetCurrentProcessId = import.GetCurrentProcessId;
pub const LARGE_INTEGER = import.LARGE_INTEGER;
pub const CreateMutexA = import.CreateMutexA;
pub const ReleaseMutex = import.ReleaseMutex;

// Types and constants no longer in std.os.windows
pub const PROCESS_INFORMATION = extern struct {
    hProcess: std.os.windows.HANDLE,
    hThread: std.os.windows.HANDLE,
    dwProcessId: std.os.windows.DWORD,
    dwThreadId: std.os.windows.DWORD,
};
pub const INFINITE: std.os.windows.DWORD = 0xFFFFFFFF;
pub const WAIT_TIMEOUT: std.os.windows.DWORD = 0x102;
pub const CTRL_C_EVENT: std.os.windows.DWORD = 0;

/// Call Win32 ExitProcess directly, bypassing any Zig runtime cleanup that
/// could block on background threads.
pub fn exitProcess(exit_code: u32) noreturn {
    import.ExitProcess(exit_code);
    unreachable;
}
pub const CTRL_BREAK_EVENT: std.os.windows.DWORD = 1;
pub const CTRL_CLOSE_EVENT: std.os.windows.DWORD = 2;

pub fn SetCurrentDirectoryW(path: [*:0]const u16) bool {
    return import.SetCurrentDirectoryW(@constCast(path)) != 0;
}

pub fn CreateProcessW(
    lp_command_line: [*:0]u16,
    creation_flags: u32,
    startup_info: *std.os.windows.STARTUPINFOW,
    process_info: *PROCESS_INFORMATION,
) bool {
    return import.CreateProcessW(null, lp_command_line, null, null, 1, creation_flags, null, null, @ptrCast(startup_info), @ptrCast(process_info)) != 0;
}

pub var g_stdout: *anyopaque = undefined;
pub var g_stdin: *anyopaque = undefined;

pub var buffered_ctrl_c = false;

pub fn setup_console() void {
    const stdin = import.GetStdHandle(import.STD_INPUT_HANDLE);
    if (stdin == null) @panic("Failed to get stdin");
    g_stdin = stdin.?;

    const stdout = import.GetStdHandle(import.STD_OUTPUT_HANDLE);
    if (stdout == null) @panic("Failed to get stdin");
    g_stdout = stdout.?;

    set_console_mode();

    // Add handle for Ctrl + C.
    if (import.SetConsoleCtrlHandler(control_signal_handler, 1) == 0) @panic("Failed to set control signal handler");
}

pub fn set_console_mode() void {
    var current_flags: u32 = 0;
    _ = import.GetConsoleMode(g_stdin, &current_flags);
    const ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200;

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
    const wordZ = std.fmt.allocPrintSentinel(alloc.temp_alloc.allocator(), "{s}", .{word}, 0) catch unreachable;
    const word_u16 = std.unicode.utf8ToUtf16LeAllocZ(alloc.temp_alloc.allocator(), wordZ) catch unreachable;

    const file_attributes = import.GetFileAttributesW(word_u16);

    return file_attributes != import.INVALID_FILE_ATTRIBUTES;
}

pub fn get_appdata_path() []const u8 {
    const appdata_literal = std.unicode.utf8ToUtf16LeAllocZ(alloc.temp_alloc.allocator(), "APPDATA") catch unreachable;
    var buffer: [256]u16 = undefined;
    const len = import.GetEnvironmentVariableW(appdata_literal, &buffer, 256);
    return std.unicode.utf16LeToUtf8Alloc(alloc.gpa.allocator(), buffer[0..len]) catch unreachable;
}

pub fn write_console(cs: []const u8) void {
    var written: c_ulong = 0;
    const res = import.WriteConsoleA(g_stdout, cs.ptr, @intCast(cs.len), &written, null);
    std.debug.assert(res != 0);
    std.debug.assert(written == cs.len);
}

pub fn copy_to_clipboard(s: []const u8) void {
    if (import.OpenClipboard(null) == 0) {
        // Failed to open clipboard
        return;
    }

    if (import.EmptyClipboard() == 0) @panic("Failed to empty the clipboard");

    var s_utf16: [:0]u16 = std.unicode.utf8ToUtf16LeAllocZ(alloc.temp_alloc.allocator(), s) catch unreachable;
    const data_handle = import.GlobalAlloc(0, (s_utf16.len + 1) * @sizeOf(u16));
    if (data_handle == null) @panic("GlobalAlloc call failed when trying to copy to the clipboard");

    const allocated: [*]u16 = @ptrCast(@alignCast(import.GlobalLock(data_handle)));
    @memcpy(allocated, s_utf16);
    _ = import.SetClipboardData(import.CF_UNICODETEXT, data_handle);

    _ = import.GlobalUnlock(allocated);
    _ = import.CloseClipboard();
}

pub fn control_signal_handler(signal: std.os.windows.DWORD) callconv(.c) std.os.windows.BOOL {
    switch (signal) {
        CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT => {
            //write_console("\nCtrl C input read\n");
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

