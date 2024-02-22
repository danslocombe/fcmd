const std = @import("std");
const alloc = @import("alloc.zig");
const shell = @import("shell.zig");

pub const FroggyCommand = union(enum) {
    Cd: []const u8,
    Echo: []const u8,
    Ls: void,

    pub fn execute(self: FroggyCommand) void {
        switch (self) {
            .Echo => |e| {
                std.debug.print("{s}\n", .{e});
            },
            else => {
                std.debug.print("Unhandled FroggyCommand {}\n", .{self});
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
                .Cd = splits.rest,
            };
        }

        if (std.mem.eql(u8, splits.first, "ls")) {
            return .{
                .Cd = splits.rest,
            };
        }

        return null;
    }
};

fn split_first_word(xs: []const u8) struct { first: []const u8, rest: []const u8 } {
    var iter = std.mem.tokenizeAny(u8, xs, " ");
    if (iter.next()) |next| {
        var rest = xs[next.len + 1 ..];
        return .{ .first = xs, .rest = rest };
    }

    return .{ .first = xs, .rest = "" };
}
