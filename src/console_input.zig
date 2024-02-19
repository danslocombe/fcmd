const std = @import("std");
const alloc = @import("alloc.zig");

pub const ConsoleInput = struct {
    key: u16,
    utf8_char: Utf8Char,
    modifier_keys: u32,
};

pub const Input = union(enum) {
    Append: Utf8Char,
    Left: void,
    BlockLeft: void,
    Right: void,
    BlockRight: void,

    GotoStart: void,
    GotoEnd: void,

    Delete: void,
    DeleteBlock: void,

    pub fn from_console_input(ci: ConsoleInput) Input {
        var has_ctrl = (ci.modifier_keys & 0x08) != 0;

        // Backspace
        if (ci.key == 0x08) {
            if (has_ctrl) {
                return .{
                    .DeleteBlock = void{},
                };
            } else {
                return .{ .Delete = void{} };
            }
        }

        // Left arrow
        if (ci.key == 0x25) {
            if (has_ctrl) {
                return .{ .BlockLeft = void{} };
            } else {
                return .{ .Left = void{} };
            }
        }

        // Right arrow
        if (ci.key == 0x27) {
            if (has_ctrl) {
                return .{ .BlockRight = void{} };
            } else {
                return .{ .Right = void{} };
            }
        }

        // Home
        if (ci.key == 0x24) {
            return .{ .GotoStart = void{} };
        }
        // End
        if (ci.key == 0x23) {
            return .{ .GotoEnd = void{} };
        }

        return Input{
            .Append = ci.utf8_char,
        };
    }
};

pub const Utf8Char = struct {
    bs: [8]u8 = alloc.zeroed(u8, 8),

    pub fn slice(self: *const Utf8Char) []const u8 {
        var len = std.unicode.utf8ByteSequenceLength(self.bs[0]) catch @panic("Error getting utf8char len");
        return self.bs[0..@intCast(len)];
    }
};
