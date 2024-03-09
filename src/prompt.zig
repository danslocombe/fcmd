const std = @import("std");
const alloc = @import("alloc.zig");
const input = @import("input.zig");
const windows = @import("windows.zig");
const unicode_width = @import("unicode_width.zig");

pub const PromptCursorPos = struct {
    // The byte position into the array of utf8 chars.
    byte_index: usize = 0,

    // The "physical" x coordinate when writing out to the screen.
    // *Not* the codepoint index
    x: usize = 0,
};

pub const Highlight = struct {
    start_pos: PromptCursorPos,
    end_pos: PromptCursorPos,
};

pub const Prompt = struct {
    bs: std.ArrayList(u8),
    pos: PromptCursorPos,
    highlight: ?Highlight = null,

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

    pub fn char_len(self: *Prompt) usize {
        var iter = std.unicode.Utf8Iterator{
            .bytes = self.bs.items,
            .i = 0,
        };

        var count: usize = 0;
        while (iter.nextCodepointSlice()) |c| {
            count += unicode_width.get_width_slice(c);
        }

        return count;
    }

    pub fn apply_input(self: *Prompt, in: input.Input) void {
        var prev_pos = self.pos;
        switch (in) {
            .Append => |*c| {
                if (self.highlight) |_| {
                    self.delete_highlighted();
                }

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
                self.pos.x += unicode_width.get_width(c.*);
            },
            .Left => |flags| {
                _ = self.move_left();
                self.update_highlighting_after_move(prev_pos, flags);
            },
            .Right => |flags| {
                _ = self.move_right();
                self.update_highlighting_after_move(prev_pos, flags);
            },
            .BlockLeft => |flags| {
                var moved_nonspace = false;
                while (self.move_left()) |x| {
                    // Also need to split on / and \
                    if (moved_nonspace and std.mem.eql(u8, x, " ")) {
                        // Overshot, move back once.
                        _ = self.move_right();
                        break;
                    } else {
                        moved_nonspace = true;
                    }
                }

                self.update_highlighting_after_move(prev_pos, flags);
            },
            .BlockRight => |flags| {
                var moved_nonspace = false;
                while (self.move_right()) |x| {
                    if (moved_nonspace and std.mem.eql(u8, x, " ")) {
                        // Overshot, move back once.
                        _ = self.move_left();
                        break;
                    } else {
                        moved_nonspace = true;
                    }
                }

                self.update_highlighting_after_move(prev_pos, flags);
            },
            .GotoStart => |flags| {
                self.pos = .{};
                self.update_highlighting_after_move(prev_pos, flags);
            },
            .GotoEnd => |flags| {
                while (self.move_right()) |_| {}
                self.update_highlighting_after_move(prev_pos, flags);
            },
            .Delete => {
                if (self.highlight) |_| {
                    self.delete_highlighted();
                    return;
                }

                _ = self.delete();
            },
            .DeleteBlock => {
                if (self.highlight) |_| {
                    self.delete_highlighted();
                    return;
                }

                while (self.delete()) |x| {
                    if (std.mem.eql(u8, x, " ")) {
                        break;
                    }
                }
            },
            .SelectAll => {
                while (self.move_right()) |_| {}

                self.highlight = .{
                    .start_pos = .{},
                    .end_pos = .{
                        .byte_index = self.bs.items.len,
                        .x = self.char_len(),
                    },
                };
            },
            .Cut => {
                if (self.highlight) |_| {
                    windows.copy_to_clipboard(self.get_highlighted());
                    self.delete_highlighted();
                }
            },
            .Copy => {
                if (self.highlight) |_| {
                    windows.copy_to_clipboard(self.get_highlighted());
                }
            },
            else => {},
        }
    }

    pub fn get_highlighted(self: *Prompt) []const u8 {
        if (self.highlight) |highlight| {
            return self.bs.items[highlight.start_pos.byte_index..highlight.end_pos.byte_index];
        } else {
            return "";
        }
    }

    pub fn move_left(self: *Prompt) ?[]const u8 {
        // @SPEED
        // How can we avoid re-iterating?

        var prev: ?[]const u8 = null;
        var prev_i: usize = 0;
        var prev_x: usize = 0;

        var iter = std.unicode.Utf8Iterator{
            .bytes = self.bs.items,
            .i = 0,
        };

        while (true) {
            prev = iter.nextCodepointSlice();

            if (iter.i == self.pos.byte_index) {
                self.pos.byte_index = prev_i;
                self.pos.x = prev_x;
                return prev;
            }

            prev_i = iter.i;
            if (prev) |cp_slice| {
                prev_x += unicode_width.get_width_slice(cp_slice);
            }

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

        if (ret) |c| {
            self.pos.x += unicode_width.get_width_slice(c);
        }

        return ret;
    }

    fn update_highlighting_after_move(self: *Prompt, prev_pos: PromptCursorPos, flags: input.CursorMovementFlags) void {
        var not_moving = self.pos.byte_index == prev_pos.byte_index;
        var moving_right = self.pos.byte_index > prev_pos.byte_index;

        if (flags.highlight) {
            if (not_moving) {
                // Nothing to do
                return;
            }

            if (self.highlight) |*highlight| {
                var cursor_at_start = prev_pos.byte_index < highlight.end_pos.byte_index;

                if (cursor_at_start) {
                    highlight.start_pos = self.pos;
                } else {
                    highlight.end_pos = self.pos;
                }

                // Its possible to move the end of the highlight back beyond the start or vice versa
                // eg with a shift + home input
                // In that case we swap the highlight positions.
                if (highlight.start_pos.byte_index > highlight.end_pos.byte_index) {
                    var start = highlight.start_pos;
                    highlight.start_pos = highlight.end_pos;
                    highlight.end_pos = start;
                }

                if (highlight.start_pos.byte_index == highlight.end_pos.byte_index) {
                    self.highlight = null;
                }
            } else {
                if (moving_right) {
                    self.highlight = .{
                        .start_pos = prev_pos,
                        .end_pos = self.pos,
                    };
                } else {
                    self.highlight = .{
                        .start_pos = self.pos,
                        .end_pos = prev_pos,
                    };
                }
            }
        } else {
            // Remove highlighting.
            self.highlight = null;
        }
    }

    pub fn delete_highlighted(self: *Prompt) void {
        std.debug.assert(self.highlight != null);
        var highlight = self.highlight.?;

        var after_highlighted = self.bs.items[highlight.end_pos.byte_index..];
        std.mem.copyForwards(u8, self.bs.items[highlight.start_pos.byte_index..], after_highlighted);

        var delete_len = highlight.end_pos.byte_index - highlight.start_pos.byte_index;
        self.bs.resize(self.bs.items.len - delete_len) catch unreachable;
        self.pos = highlight.start_pos;

        self.highlight = null;
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

        if (self.highlight) |*highlight| {
            if (prev_byte_index <= highlight.end_pos.byte_index) {
                highlight.end_pos.byte_index -= delete_byte_count;
                // @nocheckin subtract theh correct width
                highlight.end_pos.x -|= 1;
            }
            if (prev_byte_index <= highlight.start_pos.byte_index) {
                highlight.start_pos.byte_index -= delete_byte_count;
                // @nocheckin subtract theh correct width
                highlight.start_pos.x -|= 1;
            }
        }

        return ret;
    }

    pub fn move_to_and_clear_end(self: *Prompt, pos: PromptCursorPos) void {
        std.debug.assert(self.bs.items.len >= pos.x);
        self.pos = pos;
        self.bs.resize(self.pos.byte_index) catch unreachable;
    }
};

test "move right" {
    var prompt = Prompt.init();
    prompt.bs.appendSlice("hi🐸") catch unreachable;

    try std.testing.expectEqualSlices(u8, "h", prompt.move_right().?);
    try std.testing.expectEqual(@as(usize, 1), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 1), prompt.pos.x);
    try std.testing.expectEqualSlices(u8, "i", prompt.move_right().?);
    try std.testing.expectEqual(@as(usize, 2), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 2), prompt.pos.x);
    try std.testing.expectEqualSlices(u8, "🐸", prompt.move_right().?);
    try std.testing.expectEqual(@as(usize, 6), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 3), prompt.pos.x);
    try std.testing.expectEqual(@as(?[]const u8, null), prompt.move_right());
    try std.testing.expectEqual(@as(usize, 6), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 3), prompt.pos.x);
}

test "move left" {
    var prompt = Prompt.init();
    prompt.bs.appendSlice("hi🐸") catch unreachable;
    prompt.pos.byte_index = prompt.bs.items.len;
    prompt.pos.x = 3;

    try std.testing.expectEqualSlices(u8, "🐸", prompt.move_left().?);
    try std.testing.expectEqual(@as(usize, 2), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 2), prompt.pos.x);
    try std.testing.expectEqualSlices(u8, "i", prompt.move_left().?);
    try std.testing.expectEqual(@as(usize, 1), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 1), prompt.pos.x);
    try std.testing.expectEqualSlices(u8, "h", prompt.move_left().?);
    try std.testing.expectEqual(@as(usize, 0), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 0), prompt.pos.x);
    try std.testing.expectEqual(@as(?[]const u8, null), prompt.move_left());
    try std.testing.expectEqual(@as(usize, 0), prompt.pos.byte_index);
    try std.testing.expectEqual(@as(usize, 0), prompt.pos.x);
}
