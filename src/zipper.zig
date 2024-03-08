const std = @import("std");
const alloc = @import("alloc.zig");
const input = @import("input.zig");

pub const ZipperCursorPos = struct {
    byte_index: usize = 0,
    char_index: usize = 0,
};

pub const Zipper = struct {
    bs: std.ArrayList(u8),
    pos: ZipperCursorPos,

    pub fn init() Zipper {
        return .{
            .bs = alloc.new_arraylist(u8),
            .pos = .{},
        };
    }

    pub fn clear(self: *Zipper) void {
        self.bs.clearRetainingCapacity();
        self.pos = .{};
    }

    pub fn apply_input(self: *Zipper, in: input.Input) void {
        switch (in) {
            .Append => |*c| {
                var c_slice = c.slice();
                if (self.pos.byte_index == self.bs.items.len) {
                    self.bs.appendSlice(c_slice) catch unreachable;
                } else {
                    var bs_initial_len = self.bs.items.len;

                    // Insert into middle
                    // Can this be nicer?
                    self.bs.resize(self.bs.items.len + c_slice.len) catch unreachable;

                    // Shift bytes forward
                    // May overlap so we don't use @memcpy
                    std.mem.copyBackwards(u8, self.bs.items[self.pos.byte_index + c_slice.len ..], self.bs.items[self.pos.byte_index..bs_initial_len]);

                    // Insert into middle
                    @memcpy(self.bs.items[self.pos.byte_index .. self.pos.byte_index + c_slice.len], c_slice);
                }

                self.pos.byte_index += c.slice().len;
                self.pos.char_index += 1;
            },
            .Left => {
                _ = self.move_left();
            },
            .Right => {
                _ = self.move_right();
            },
            .BlockLeft => {
                while (self.move_left()) |x| {
                    // Also need to split on / and \
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
            .Delete => {
                _ = self.delete();
            },
            .DeleteBlock => {
                while (self.delete()) |x| {
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
        self.pos.char_index = self.pos.char_index -| 1;

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

            if (iter.i == self.pos.byte_index) {
                self.pos.byte_index = prev_i;
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
            .i = self.pos.byte_index,
        };

        var ret = iter.nextCodepointSlice();
        self.pos.byte_index = iter.i;

        if (ret) |_| {
            self.pos.char_index += 1;
        }

        return ret;
    }

    pub fn delete(self: *Zipper) ?[]const u8 {
        var prev_byte_index = self.pos.byte_index;
        var ret = self.move_left();

        var delete_byte_count = prev_byte_index - self.pos.byte_index;
        if (delete_byte_count > 0) {
            if (prev_byte_index != self.bs.items.len) {
                // Have to shift some bytes in the middle
                std.mem.copyForwards(u8, self.bs.items[self.pos.byte_index..], self.bs.items[prev_byte_index..]);
            }

            self.bs.resize(self.bs.items.len - delete_byte_count) catch unreachable;
        }

        return ret;
    }

    pub fn move_to_and_clear_end(self: *Zipper, pos: ZipperCursorPos) void {
        std.debug.assert(self.bs.items.len >= pos.char_index);
        self.pos = pos;
        self.bs.resize(self.pos.byte_index) catch unreachable;
    }
};

test "zipper move right" {
    var zipper = Zipper.init();
    zipper.bs.appendSlice("hi🐸") catch unreachable;

    try std.testing.expectEqualSlices(u8, "h", zipper.move_right().?);
    try std.testing.expectEqual(@as(usize, 1), zipper.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 1), zipper.pos.char_index);
    try std.testing.expectEqualSlices(u8, "i", zipper.move_right().?);
    try std.testing.expectEqual(@as(usize, 2), zipper.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 2), zipper.pos.char_index);
    try std.testing.expectEqualSlices(u8, "🐸", zipper.move_right().?);
    try std.testing.expectEqual(@as(usize, 6), zipper.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 3), zipper.pos.char_index);
    try std.testing.expectEqual(@as(?[]const u8, null), zipper.move_right());
    try std.testing.expectEqual(@as(usize, 6), zipper.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 3), zipper.pos.char_index);
}

test "zipper move left" {
    var zipper = Zipper.init();
    zipper.bs.appendSlice("hi🐸") catch unreachable;
    zipper.pos.byte_index = zipper.bs.items.len;
    zipper.pos.char_index = 3;

    try std.testing.expectEqualSlices(u8, "🐸", zipper.move_left().?);
    try std.testing.expectEqual(@as(usize, 2), zipper.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 2), zipper.pos.char_index);
    try std.testing.expectEqualSlices(u8, "i", zipper.move_left().?);
    try std.testing.expectEqual(@as(usize, 1), zipper.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 1), zipper.pos.char_index);
    try std.testing.expectEqualSlices(u8, "h", zipper.move_left().?);
    try std.testing.expectEqual(@as(usize, 0), zipper.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 0), zipper.pos.char_index);
    try std.testing.expectEqual(@as(?[]const u8, null), zipper.move_left());
    try std.testing.expectEqual(@as(usize, 0), zipper.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 0), zipper.pos.char_index);
}
