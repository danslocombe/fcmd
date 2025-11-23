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
    std.os.windows.SetConsoleCtrlHandler(control_signal_handler, true) catch @panic("Failed to set control signal handler");
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
        std.os.windows.CTRL_C_EVENT, std.os.windows.CTRL_BREAK_EVENT, std.os.windows.CTRL_CLOSE_EVENT => {
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

// Hacky
// In the standard lib there are functions that can panic on bad input.
// We want are using these functions to check if a given string is a path
// so it needs to handle the "worst of all inputs"
// Copy paste the std lib code and map the panic to an error.
pub const CopyPastedFromStdLibWithAdditionalSafety = struct {
    const Dir = std.fs.Dir;
    const OpenDirOptions = Dir.OpenOptions;
    const OpenError = Dir.OpenError;
    const This = @This();
    pub fn openIterableDir(self: Dir, sub_path: []const u8, args: OpenDirOptions) OpenError!Dir {
        const sub_path_w = try std.os.windows.sliceToPrefixedFileW(self.fd, sub_path);
        return try This.openDirW(self, sub_path_w.span().ptr, args, true);
    }

    pub fn openDirW(self: Dir, sub_path_w: [*:0]const u16, args: OpenDirOptions, iterable: bool) OpenError!Dir {
        const w = std.os.windows;
        // TODO remove some of these flags if args.access_sub_paths is false
        const base_flags = w.STANDARD_RIGHTS_READ | w.FILE_READ_ATTRIBUTES | w.FILE_READ_EA |
            w.SYNCHRONIZE | w.FILE_TRAVERSE;
        const flags: u32 = if (iterable) base_flags | w.FILE_LIST_DIRECTORY else base_flags;
        const dir = try This.openDirAccessMaskW(self, sub_path_w, flags, !args.follow_symlinks);
        return dir;
    }

    fn openDirAccessMaskW(self: Dir, sub_path_w: [*:0]const u16, access_mask: u32, no_follow: bool) OpenError!Dir {
        const w = std.os.windows;

        var result = Dir{
            .fd = undefined,
        };

        const path_len_bytes = @as(u16, @intCast(std.mem.sliceTo(sub_path_w, 0).len * 2));
        var nt_name = w.UNICODE_STRING{
            .Length = path_len_bytes,
            .MaximumLength = path_len_bytes,
            .Buffer = @constCast(sub_path_w),
        };
        var attr = w.OBJECT_ATTRIBUTES{
            .Length = @sizeOf(w.OBJECT_ATTRIBUTES),
            .RootDirectory = if (std.fs.path.isAbsoluteWindowsW(sub_path_w)) null else self.fd,
            .Attributes = 0, // Note we do not use OBJ_CASE_INSENSITIVE here.
            .ObjectName = &nt_name,
            .SecurityDescriptor = null,
            .SecurityQualityOfService = null,
        };
        const open_reparse_point: w.DWORD = if (no_follow) w.FILE_OPEN_REPARSE_POINT else 0x0;
        var io: w.IO_STATUS_BLOCK = undefined;
        const rc = w.ntdll.NtCreateFile(
            &result.fd,
            access_mask,
            &attr,
            &io,
            null,
            0,
            w.FILE_SHARE_READ | w.FILE_SHARE_WRITE,
            w.FILE_OPEN,
            w.FILE_DIRECTORY_FILE | w.FILE_SYNCHRONOUS_IO_NONALERT | w.FILE_OPEN_FOR_BACKUP_INTENT | open_reparse_point,
            null,
            0,
        );
        switch (rc) {
            .SUCCESS => return result,

            // This is the change, because we are trying to navigate to arbitrary user commands this was triggering on urls
            // Replace the unreachable here with an error
            //.OBJECT_NAME_INVALID => unreachable,
            .OBJECT_NAME_INVALID => return error.NotDir,

            .OBJECT_NAME_NOT_FOUND => return error.FileNotFound,
            .OBJECT_PATH_NOT_FOUND => return error.FileNotFound,
            .NOT_A_DIRECTORY => return error.NotDir,
            // This can happen if the directory has 'List folder contents' permission set to 'Deny'
            // and the directory is trying to be opened for iteration.
            .ACCESS_DENIED => return error.AccessDenied,
            .INVALID_PARAMETER => unreachable,
            else => return w.unexpectedStatus(rc),
        }
    }
};
