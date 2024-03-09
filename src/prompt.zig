const std = @import("std");
const alloc = @import("alloc.zig");
const input = @import("input.zig");

pub const PromptCursorPos = struct {
    byte_index: usize = 0,
    char_index: usize = 0,
};

pub const Prompt = struct {
    bs: std.ArrayList(u8),
    pos: PromptCursorPos,

    pub fn init() Prompt {
        return .{
            .bs = alloc.new_arraylist(u8),
            .pos = .{},
        };
    }

    pub fn clear(self: *Prompt) void {
        self.bs.clearRetainingCapacity();
        self.pos = .{};
    }

    pub fn apply_input(self: *Prompt, in: input.Input) void {
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

    pub fn move_left(self: *Prompt) ?[]const u8 {
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

    pub fn move_right(self: *Prompt) ?[]const u8 {
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

    pub fn delete(self: *Prompt) ?[]const u8 {
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

    pub fn move_to_and_clear_end(self: *Prompt, pos: PromptCursorPos) void {
        std.debug.assert(self.bs.items.len >= pos.char_index);
        self.pos = pos;
        self.bs.resize(self.pos.byte_index) catch unreachable;
    }
};

test "move right" {
    var prompt = Prompt.init();
    prompt.bs.appendSlice("hi🐸") catch unreachable;

    try std.testing.expectEqualSlices(u8, "h", prompt.move_right().?);
    try std.testing.expectEqual(@as(usize, 1), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 1), prompt.pos.char_index);
    try std.testing.expectEqualSlices(u8, "i", prompt.move_right().?);
    try std.testing.expectEqual(@as(usize, 2), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 2), prompt.pos.char_index);
    try std.testing.expectEqualSlices(u8, "🐸", prompt.move_right().?);
    try std.testing.expectEqual(@as(usize, 6), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 3), prompt.pos.char_index);
    try std.testing.expectEqual(@as(?[]const u8, null), prompt.move_right());
    try std.testing.expectEqual(@as(usize, 6), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 3), prompt.pos.char_index);
}

test "move left" {
    var prompt = Prompt.init();
    prompt.bs.appendSlice("hi🐸") catch unreachable;
    prompt.pos.byte_index = prompt.bs.items.len;
    prompt.pos.char_index = 3;

    try std.testing.expectEqualSlices(u8, "🐸", prompt.move_left().?);
    try std.testing.expectEqual(@as(usize, 2), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 2), prompt.pos.char_index);
    try std.testing.expectEqualSlices(u8, "i", prompt.move_left().?);
    try std.testing.expectEqual(@as(usize, 1), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 1), prompt.pos.char_index);
    try std.testing.expectEqualSlices(u8, "h", prompt.move_left().?);
    try std.testing.expectEqual(@as(usize, 0), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 0), prompt.pos.char_index);
    try std.testing.expectEqual(@as(?[]const u8, null), prompt.move_left());
    try std.testing.expectEqual(@as(usize, 0), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 0), prompt.pos.char_index);
}
