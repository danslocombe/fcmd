const std = @import("std");
const alloc = @import("alloc.zig");
const shell = @import("shell.zig");
const windows = @import("windows.zig");
const log = @import("log.zig");

pub var g_current_running_process_info: ?std.os.windows.PROCESS_INFORMATION = null;

pub fn run(cmd: []const u8) RunResult {
    if (FroggyCommand.try_get_froggy_command(cmd)) |froggy| {
        return froggy.execute();
    } else {
        return run_cmd(cmd);
    }
}

pub const FroggyCommand = union(enum) {
    Cd: []const u8,
    Echo: []const u8,
    Ls: void,
    Cls: void,
    Exit: void,

    pub fn execute(self: FroggyCommand) RunResult {
        switch (self) {
            .Cd => |cd| {
                // Same number of bytes should be enough space
                var utf16_buffer = alloc.temp_alloc.allocator().alloc(u16, cd.len) catch unreachable;
                _ = std.unicode.utf8ToUtf16Le(utf16_buffer, cd) catch unreachable;
                std.os.windows.SetCurrentDirectory(utf16_buffer) catch |err| {
                    std.debug.print("CD Error {}\n", .{err});
                    return .{ .add_to_history = false };
                };

                return .{};
            },
            .Echo => |e| {
                var with_newline = std.mem.concat(alloc.temp_alloc.allocator(), u8, &[_][]const u8{ e, "\n" }) catch unreachable;
                windows.write_console(with_newline);
                return .{};
            },
            .Ls => {
                return run_cmd("dir");
            },
            .Cls => {
                return run_cmd("cls");
            },
            .Exit => {
                windows.write_console("Goodbye");

                // TODO reset the console state to what it was before
                std.os.windows.kernel32.ExitProcess(0);
                unreachable;
            },
        }
    }

    pub fn try_get_froggy_command(cmd: []const u8) ?FroggyCommand {
        var splits = split_first_word(cmd);

        if (std.mem.eql(u8, splits.first, "cd")) {
            return .{
                .Cd = splits.rest,
            };
        }

        if (std.mem.eql(u8, splits.first, "echo")) {
            return .{
                .Echo = splits.rest,
            };
        }

        if (std.mem.eql(u8, splits.first, "ls")) {
            return .{
                .Ls = void{},
            };
        }

        if (std.mem.eql(u8, splits.first, "exit")) {
            return .{
                .Exit = void{},
            };
        }

        return null;
    }
};

fn split_first_word(xs: []const u8) struct { first: []const u8, rest: []const u8 } {
    var iter = std.mem.tokenizeAny(u8, xs, " ");
    if (iter.next()) |next| {
        if (next.len == xs.len) {
            // Single word
            return .{ .first = xs, .rest = "" };
        }

        var rest = xs[next.len + 1 ..];
        return .{ .first = next, .rest = rest };
    }

    return .{ .first = xs, .rest = "" };
}

pub fn hack_run_async(cmd: []const u8) bool {
    var trimmed = std.mem.trim(u8, cmd, " ");
    var internal_space_count = std.mem.count(u8, trimmed, " ");

    if (internal_space_count == 0 and std.mem.endsWith(u8, trimmed, ".sln")) {
        // @Hack if you directly invoke a .sln file open in the background
        return true;
    }

    return false;
}

pub fn run_cmd(cmd: []const u8) RunResult {
    //std.debug.print("Running command {s}\n", .{cmd});
    var command = std.fmt.allocPrintZ(alloc.temp_alloc.allocator(), "cmd /C {s}", .{cmd}) catch unreachable;
    var cmd_buf = std.unicode.utf8ToUtf16LeWithNull(alloc.temp_alloc.allocator(), command) catch unreachable;

    const NORMAL_PRIORITY_CLASS = 0x00000020;
    const CREATE_NEW_PROCESS_GROUP = 0x00000200;
    const flags = NORMAL_PRIORITY_CLASS | CREATE_NEW_PROCESS_GROUP;

    var startup_info = std.os.windows.STARTUPINFOW{
        .cb = @sizeOf(std.os.windows.STARTUPINFOW),
        .lpReserved = null,
        .lpDesktop = null,
        .lpTitle = null,
        .dwX = 0,
        .dwY = 0,
        .dwXSize = 0,
        .dwYSize = 0,
        .dwXCountChars = 0,
        .dwYCountChars = 0,
        .dwFillAttribute = 0,
        .dwFlags = 0,
        .wShowWindow = 0,
        .cbReserved2 = 0,
        .lpReserved2 = null,
        .hStdInput = null,
        .hStdOutput = null,
        .hStdError = null,
    };

    g_current_running_process_info = undefined;
    std.os.windows.CreateProcessW(null, cmd_buf.ptr, null, null, 1, flags, null, null, &startup_info, &g_current_running_process_info.?) catch |err| {
        g_current_running_process_info = null;
        std.debug.print("Error! Unable to run command '{s}', CreateProcessW error {}\n", .{ cmd, err });
        return .{ .add_to_history = false };
    };

    if (!hack_run_async(cmd)) {
        std.os.windows.WaitForSingleObject(g_current_running_process_info.?.hThread, std.os.windows.INFINITE) catch unreachable;
    }

    cleanup_process_handles();

    // Reset the console mode as some commands like `git log` can remove virtual console mode, which
    // breaks input handling.
    windows.set_console_mode();

    return .{};
}

pub fn cleanup_process_handles() void {
    if (g_current_running_process_info) |process_info| {
        std.os.windows.CloseHandle(process_info.hThread);
        std.os.windows.CloseHandle(process_info.hProcess);
        g_current_running_process_info = null;
    }
}

pub fn try_interupt_running_process() bool {
    if (g_current_running_process_info) |current_running_process| {
        const CTRL_BREAK_EVENT = 1;
        if (windows.GenerateConsoleCtrlEvent(CTRL_BREAK_EVENT, current_running_process.dwProcessId) == 0) {
            var err = windows.GetLastError();
            log.log_info("Failed to send ctrl event to running process. Last error {}", .{err});
        }
        return true;
    }

    return false;
}

pub const RunResult = struct {
    add_to_history: bool = true,
};
