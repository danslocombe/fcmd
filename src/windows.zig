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

pub const INPUT_RECORD = console.INPUT_RECORD;
pub const KEY_EVENT = 1;

pub const PROCESS_INFORMATION = extern struct {
    hProcess: std.os.windows.HANDLE,
    hThread: std.os.windows.HANDLE,
    dwProcessId: std.os.windows.DWORD,
    dwThreadId: std.os.windows.DWORD,
};

const CTRL_C_EVENT: u32 = 0;
const CTRL_BREAK_EVENT: u32 = 1;
const CTRL_CLOSE_EVENT: u32 = 2;

const CF_UNICODETEXT: u32 = 13;
const INFINITE: u32 = 0xFFFFFFFF;

pub fn GetLastError() u32 {
    return @intFromEnum(foundation.GetLastError());
}

pub fn read_console_input(buf: []INPUT_RECORD) ?u32 {
    var n: u32 = 0;
    if (console.ReadConsoleInputW(g_stdin, buf.ptr, @intCast(buf.len), &n) == 0) return null;
    return n;
}

pub fn create_named_mutex(name: [:0]const u8) ?*anyopaque {
    return threading.CreateMutexA(null, 0, name);
}

pub fn wait_forever(h: ?*anyopaque) void {
    _ = threading.WaitForSingleObject(h, INFINITE);
}

pub fn release_mutex(h: ?*anyopaque) void {
    _ = threading.ReleaseMutex(h);
}

/// Open existing or create new file with read+write access, shared read+write.
pub fn open_or_create_file_rw(path: [*c]const u8) ?*anyopaque {
    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const SHARE_RW: u32 = 0x3;
    const OPEN_ALWAYS: u32 = 4;
    const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
    return fs.CreateFileA(
        path,
        @bitCast(GENERIC_READ | GENERIC_WRITE),
        @bitCast(SHARE_RW),
        null,
        @enumFromInt(OPEN_ALWAYS),
        @bitCast(FILE_ATTRIBUTE_NORMAL),
        null,
    );
}

pub fn create_file_mapping_rw(file: ?*anyopaque, size: u32, name: [:0]const u8) ?*anyopaque {
    const PAGE_READWRITE: u32 = 0x4;
    return memory.CreateFileMappingA(file, null, @bitCast(PAGE_READWRITE), 0, size, name);
}

pub fn map_view_all_access(map: ?*anyopaque, size: usize) ?*anyopaque {
    const STANDARD_RIGHTS_REQUIRED: u32 = 0x000F0000;
    const SECTION_QUERY: u32 = 0x0001;
    const SECTION_MAP_WRITE: u32 = 0x0002;
    const SECTION_MAP_READ: u32 = 0x0004;
    const SECTION_MAP_EXECUTE: u32 = 0x0008;
    const SECTION_EXTEND_SIZE: u32 = 0x0010;
    const FILE_MAP_ALL_ACCESS: u32 = STANDARD_RIGHTS_REQUIRED | SECTION_QUERY |
        SECTION_MAP_WRITE | SECTION_MAP_READ | SECTION_MAP_EXECUTE | SECTION_EXTEND_SIZE;
    return memory.MapViewOfFile(map, @bitCast(FILE_MAP_ALL_ACCESS), 0, 0, size);
}

pub fn flush_view(base: *const anyopaque) void {
    _ = memory.FlushViewOfFile(base, 0);
}

pub fn unmap_view(base: *const anyopaque) void {
    _ = memory.UnmapViewOfFile(base);
}

pub fn send_ctrl_break(pid: u32) bool {
    return console.GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, pid) != 0;
}

pub fn set_current_directory(path: [*:0]const u16) bool {
    return env.SetCurrentDirectoryW(path) != 0;
}

pub fn create_process(
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
pub fn exit_process(exit_code: u32) noreturn {
    threading.ExitProcess(exit_code);
}

pub var g_stdout: *anyopaque = undefined;
pub var g_stdin: *anyopaque = undefined;

pub var buffered_ctrl_c = false;

pub fn setup_console() void {
    g_stdin = console.GetStdHandle(console.STD_INPUT_HANDLE);
    g_stdout = console.GetStdHandle(console.STD_OUTPUT_HANDLE);

    set_console_mode();

    if (console.SetConsoleCtrlHandler(control_signal_handler, 1) == 0) @panic("Failed to set control signal handler");
}

pub fn set_console_mode() void {
    var current_mode: console.CONSOLE_MODE = @bitCast(@as(u32, 0));
    _ = console.GetConsoleMode(g_stdin, &current_mode);

    const ENABLE_WINDOW_INPUT: u32 = 0x0008;
    const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;

    const new_mode = @as(u32, @bitCast(current_mode)) |
        ENABLE_WINDOW_INPUT |
        ENABLE_VIRTUAL_TERMINAL_INPUT |
        ENABLE_VIRTUAL_TERMINAL_PROCESSING;

    if (console.SetConsoleMode(g_stdin, @bitCast(new_mode)) == 0) @panic("Failed to set console mode");

    const UTF8Codepage = 65001;
    if (console.SetConsoleCP(UTF8Codepage) == 0) @panic("Failed to set Console CodePage");
    if (console.SetConsoleOutputCP(UTF8Codepage) == 0) @panic("Failed to set Console Output CodePage");
}

pub fn word_is_local_path(word: []const u8) bool {
    if (std.fs.path.isAbsolute(word)) return false;

    // @Speed don't format just directly alloc
    const wordZ = std.fmt.allocPrintSentinel(alloc.temp_alloc.allocator(), "{s}", .{word}, 0) catch unreachable;
    const word_u16 = std.unicode.utf8ToUtf16LeAllocZ(alloc.temp_alloc.allocator(), wordZ) catch unreachable;

    return fs.GetFileAttributesW(word_u16) != fs.INVALID_FILE_ATTRIBUTES;
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
    if (dataex.OpenClipboard(null) == 0) return;

    if (dataex.EmptyClipboard() == 0) @panic("Failed to empty the clipboard");

    const s_utf16: [:0]u16 = std.unicode.utf8ToUtf16LeAllocZ(alloc.temp_alloc.allocator(), s) catch unreachable;
    const byte_count: usize = (s_utf16.len + 1) * @sizeOf(u16);
    const handle = memory.GlobalAlloc(@bitCast(@as(u32, 0)), byte_count);
    if (handle == 0) @panic("GlobalAlloc call failed when trying to copy to the clipboard");

    const allocated: [*]u16 = @ptrCast(@alignCast(memory.GlobalLock(handle)));
    @memcpy(allocated, s_utf16);
    _ = dataex.SetClipboardData(CF_UNICODETEXT, @ptrFromInt(@as(usize, @bitCast(handle))));

    _ = memory.GlobalUnlock(handle);
    _ = dataex.CloseClipboard();
}

pub fn control_signal_handler(signal: u32) callconv(.winapi) i32 {
    switch (signal) {
        CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT => {
            if (run.try_interupt_running_process()) {
                // Passed the interrupt downstream to the running program.
            } else {
                buffered_ctrl_c = true;

                if (main.g_shell.prompt.highlight != null) {
                    // Allow ctrl+c to work
                    return 1;
                } else {
                    write_console("\nTo exit fcmd use the command 'exit'\n");
                }
            }

            return 1;
        },
        else => return 0,
    }
}
