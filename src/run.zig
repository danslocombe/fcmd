const std = @import("std");
const alloc = @import("alloc.zig");
const shell = @import("shell.zig");
const windows = @import("windows.zig");
const log = @import("log.zig");

pub var g_current_running_process_info: ?windows.PROCESS_INFORMATION = null;

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
                const expanded_cd = expand_env_vars(cd, &windows.get_env_var);
                const utf16_buffer = std.unicode.utf8ToUtf16LeAllocZ(alloc.temp_alloc.allocator(), expanded_cd) catch unreachable;
                if (!windows.SetCurrentDirectoryW(utf16_buffer.ptr)) {
                    std.debug.print("CD Error {}\n", .{windows.GetLastError()});
                    return .{ .add_to_history = false };
                }

                return .{};
            },
            .Echo => |e| {
                const expanded_e = expand_env_vars(e, &windows.get_env_var);
                const with_newline = std.mem.concat(alloc.temp_alloc.allocator(), u8, &[_][]const u8{ expanded_e, "\n" }) catch unreachable;
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
                windows.write_console("Goodbye\n");

                // Return with exit flag so main loop can clean up properly
                // (flush trie, release semaphore) before exiting.
                return .{ .exit = true };
            },
        }
    }

    pub fn try_get_froggy_command(cmd: []const u8) ?FroggyCommand {
        const splits = split_first_word(cmd);

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

        const rest = xs[next.len + 1 ..];
        return .{ .first = next, .rest = rest };
    }

    return .{ .first = xs, .rest = "" };
}

pub fn hack_run_async(cmd: []const u8) bool {
    const trimmed = std.mem.trim(u8, cmd, " ");
    const internal_space_count = std.mem.count(u8, trimmed, " ");

    if (internal_space_count == 0 and std.mem.endsWith(u8, trimmed, ".sln")) {
        // @Hack if you directly invoke a .sln file open in the background
        return true;
    }

    return false;
}

pub fn run_cmd(cmd: []const u8) RunResult {
    //std.debug.print("Running command {s}\n", .{cmd});
    const command = std.fmt.allocPrintSentinel(alloc.temp_alloc.allocator(), "cmd /C {s}", .{cmd}, 0) catch unreachable;
    const cmd_buf = std.unicode.utf8ToUtf16LeAllocZ(alloc.temp_alloc.allocator(), command) catch unreachable;

    const NORMAL_PRIORITY_CLASS = 0x00000020;
    const CREATE_NEW_PROCESS_GROUP = 0x00000200;
    const flags: std.os.windows.CreateProcessFlags = @bitCast(@as(u32, NORMAL_PRIORITY_CLASS | CREATE_NEW_PROCESS_GROUP));

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
    if (!windows.CreateProcessW(cmd_buf.ptr, @bitCast(flags), &startup_info, &g_current_running_process_info.?)) {
        g_current_running_process_info = null;
        std.debug.print("Error! Unable to run command '{s}', CreateProcessW error {}\n", .{ cmd, windows.GetLastError() });
        return .{ .add_to_history = false };
    }

    if (!hack_run_async(cmd)) {
        _ = windows.WaitForSingleObject(g_current_running_process_info.?.hThread, windows.INFINITE);
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
            const err = windows.GetLastError();
            log.log_info("Failed to send ctrl event to running process. Last error {}", .{err});
        }
        return true;
    }

    return false;
}

pub fn expand_env_vars(input_str: []const u8, lookup: *const fn ([]const u8) ?[]const u8) []const u8 {
    // Fast path: no % in input, return as-is (zero alloc)
    if (std.mem.indexOfScalar(u8, input_str, '%') == null) return input_str;

    var result = std.ArrayList(u8).initCapacity(alloc.temp_alloc.allocator(), input_str.len) catch unreachable;
    var i: usize = 0;

    while (i < input_str.len) {
        if (input_str[i] == '%') {
            // Search for closing %
            if (std.mem.indexOfScalar(u8, input_str[i + 1 ..], '%')) |rel_close| {
                const var_name = input_str[i + 1 .. i + 1 + rel_close];
                if (var_name.len == 0) {
                    // Empty var name (%%) — keep literal
                    result.appendSlice(alloc.temp_alloc.allocator(), "%%") catch unreachable;
                    i += 2;
                } else if (lookup(var_name)) |value| {
                    result.appendSlice(alloc.temp_alloc.allocator(), value) catch unreachable;
                    i += 1 + var_name.len + 1; // skip %NAME%
                } else {
                    // Undefined variable — keep literal %NAME%
                    result.appendSlice(alloc.temp_alloc.allocator(), input_str[i .. i + 1 + var_name.len + 1]) catch unreachable;
                    i += 1 + var_name.len + 1;
                }
            } else {
                // No closing % — append rest as-is
                result.appendSlice(alloc.temp_alloc.allocator(), input_str[i..]) catch unreachable;
                break;
            }
        } else {
            result.append(alloc.temp_alloc.allocator(), input_str[i]) catch unreachable;
            i += 1;
        }
    }

    return result.items;
}

pub const RunResult = struct {
    add_to_history: bool = true,
    exit: bool = false,
};
