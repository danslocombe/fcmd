const std = @import("std");
const alloc = @import("alloc.zig");
const console_input = @import("console_input.zig");

pub const Shell = struct {
    current_prompt: Zipper,

    pub fn init() Shell {
        return .{
            .current_prompt = Zipper.init(),
        };
    }

    pub fn apply_command(self: *Shell, command: Command) void {
        switch (command) {
            .Input => |input| {
                self.current_prompt.apply_input(input);
            },
            else => {},
        }
    }

    pub fn draw(self: *Shell) void {
        self.current_prompt.draw();
    }
};

pub const Zipper = struct {
    bs: std.ArrayList(u8),
    byte_index: usize = 0,
    char_index: usize = 0,
    pub fn init() Zipper {
        return .{
            .bs = alloc.new_arraylist(u8),
        };
    }

    pub fn apply_input(self: *Zipper, input: console_input.Input) void {
        switch (input) {
            .Append => |*c| {
                var c_slice = c.slice();
                if (self.byte_index == self.bs.items.len) {
                    self.bs.appendSlice(c_slice) catch unreachable;
                } else {
                    var bs_initial_len = self.bs.items.len;

                    // Insert into middle
                    // Can this be nicer?
                    self.bs.resize(self.bs.items.len + c_slice.len) catch unreachable;

                    // Shift bytes forward
                    // May overlap so we don't use @memcpy
                    std.mem.copyBackwards(u8, self.bs.items[self.byte_index + c_slice.len ..], self.bs.items[self.byte_index..bs_initial_len]);

                    // Insert into middle
                    @memcpy(self.bs.items[self.byte_index .. self.byte_index + c_slice.len], c_slice);
                }

                self.byte_index += c.slice().len;
                self.char_index += 1;
            },
            .Left => {
                _ = self.move_left();
            },
            .Right => {
                _ = self.move_right();
            },
            .BlockLeft => {
                while (self.move_left()) |x| {
                    if (std.mem.eql(u8, x, " ")) {
                        break;
                    }
                }
            },
            .BlockRight => {
                while (self.move_right()) |x| {
                    if (std.mem.eql(u8, x, " ")) {
                        break;
                    }
                }
            },
            else => {},
        }
    }

    pub fn move_left(self: *Zipper) ?[]const u8 {
        // Saturating subtraction
        self.char_index = self.char_index -| 1;

        // @SPEED
        // How can we avoid re-iterating?

        var prev: ?[]const u8 = null;
        var prev_i: usize = 0;

        var iter = std.unicode.Utf8Iterator{
            .bytes = self.bs.items,
            .i = 0,
        };

        while (true) {
            prev = iter.nextCodepointSlice();

            if (iter.i == self.byte_index) {
                self.byte_index = prev_i;
                return prev;
            }

            prev_i = iter.i;

            if (prev == null) {
                // Can happen in case where we are already at the start.
                return null;
            }
        }
    }

    pub fn move_right(self: *Zipper) ?[]const u8 {
        var iter = std.unicode.Utf8Iterator{
            .bytes = self.bs.items,
            .i = self.byte_index,
        };

        var ret = iter.nextCodepointSlice();
        self.byte_index = iter.i;

        if (ret) |_| {
            self.char_index += 1;
        }

        return ret;
    }

    pub fn draw(self: *Zipper) void {
        _ = std.io.getStdOut().write("\r") catch unreachable;
        _ = std.io.getStdOut().write(self.bs.items) catch unreachable;
        //std.debug.print("{s}\n", .{self.bs.items});
    }
};

test "zipper move right" {
    var zipper = Zipper.init();
    zipper.bs.appendSlice("hi🐸") catch unreachable;

    try std.testing.expectEqualSlices(u8, "h", zipper.move_right().?);
    try std.testing.expectEqual(@as(usize, 1), zipper.byte_index);
    try std.testing.expectEqual(@as(usize, 1), zipper.char_index);
    try std.testing.expectEqualSlices(u8, "i", zipper.move_right().?);
    try std.testing.expectEqual(@as(usize, 2), zipper.byte_index);
    try std.testing.expectEqual(@as(usize, 2), zipper.char_index);
    try std.testing.expectEqualSlices(u8, "🐸", zipper.move_right().?);
    try std.testing.expectEqual(@as(usize, 6), zipper.byte_index);
    try std.testing.expectEqual(@as(usize, 3), zipper.char_index);
    try std.testing.expectEqual(@as(?[]const u8, null), zipper.move_right());
    try std.testing.expectEqual(@as(usize, 6), zipper.byte_index);
    try std.testing.expectEqual(@as(usize, 3), zipper.char_index);
}

test "zipper move left" {
    var zipper = Zipper.init();
    zipper.bs.appendSlice("hi🐸") catch unreachable;
    zipper.byte_index = zipper.bs.items.len;
    zipper.char_index = 3;

    try std.testing.expectEqualSlices(u8, "🐸", zipper.move_left().?);
    try std.testing.expectEqual(@as(usize, 2), zipper.byte_index);
    try std.testing.expectEqual(@as(usize, 2), zipper.char_index);
    try std.testing.expectEqualSlices(u8, "i", zipper.move_left().?);
    try std.testing.expectEqual(@as(usize, 1), zipper.byte_index);
    try std.testing.expectEqual(@as(usize, 1), zipper.char_index);
    try std.testing.expectEqualSlices(u8, "h", zipper.move_left().?);
    try std.testing.expectEqual(@as(usize, 0), zipper.byte_index);
    try std.testing.expectEqual(@as(usize, 0), zipper.char_index);
    try std.testing.expectEqual(@as(?[]const u8, null), zipper.move_left());
    try std.testing.expectEqual(@as(usize, 0), zipper.byte_index);
    try std.testing.expectEqual(@as(usize, 0), zipper.char_index);
}

pub const Command = union(enum) {
    Input: console_input.Input,
    NoOp: void,
};
