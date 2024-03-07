const std = @import("std");
const alloc = @import("alloc.zig");
const shell = @import("shell.zig");

pub var g_current_running_process_info: ?std.os.windows.PROCESS_INFORMATION = null;

pub const FroggyCommand = union(enum) {
    Cd: []const u8,
    Echo: []const u8,
    Ls: void,
    Cls: void,

    pub fn execute(self: FroggyCommand) void {
        switch (self) {
            .Cd => |cd| {
                // Same number of bytes should be enough space
                var utf16_buffer = alloc.temp_alloc.allocator().alloc(u16, cd.len) catch unreachable;
                _ = std.unicode.utf8ToUtf16Le(utf16_buffer, cd) catch unreachable;
                std.os.windows.SetCurrentDirectory(utf16_buffer) catch unreachable;
            },
            .Echo => |e| {
                std.debug.print("{s}\n", .{e});
            },
            .Ls => {
                run_cmd("dir");
            },
            .Cls => {
                run_cmd("cls");
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

pub fn run_cmd(cmd: []const u8) void {
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
        return;
    };

    std.os.windows.WaitForSingleObject(g_current_running_process_info.?.hThread, std.os.windows.INFINITE) catch unreachable;

    std.os.windows.CloseHandle(g_current_running_process_info.?.hThread);
    std.os.windows.CloseHandle(g_current_running_process_info.?.hProcess);

    g_current_running_process_info = null;
}

pub fn try_kill_running_process() bool {
    if (g_current_running_process_info) |current_running_process| {
        std.os.windows.TerminateProcess(current_running_process.hProcess, 100) catch {};
        return true;
    }

    return false;
}
