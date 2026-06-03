const std = @import("std");
const alloc = @import("alloc.zig");

pub const RenderResult = struct {
    buffer: []const u8,
    cursor_row: usize,
};

pub const StyledBufferSegments = struct {
    count: usize = 0,
    segments: [16]StyledBuffer = undefined,

    pub fn push(self: *StyledBufferSegments, styled_buffer: StyledBuffer) void {
        std.debug.assert(self.count < 16);
        self.segments[self.count] = styled_buffer;
        self.count += 1;
    }

    pub fn total_length(self: StyledBufferSegments) usize {
        var sum: usize = 0;
        for (0..self.count) |i| {
            sum += self.segments[i].buffer.len;
        }

        return sum;
    }
};

pub const StyledBuffer = struct {
    buffer: []const u8,
    styling: Styling,

    pub fn styled(self: StyledBuffer, allocator: std.mem.Allocator) []const u8 {
        switch (self.styling) {
            .None => {
                return self.buffer;
            },
            .Completion => {
                return std.fmt.allocPrint(allocator, "\x1b[1m\x1b[36m{s}\x1b[0m", .{self.buffer}) catch unreachable;
            },
            .Highlighted => {
                return std.fmt.allocPrint(allocator, "\x1b[42m{s}\x1b[0m", .{self.buffer}) catch unreachable;
            },
            .Comment => {
                return std.fmt.allocPrint(allocator, "\x1b[1m\x1b[32m{s}\x1b[0m", .{self.buffer}) catch unreachable;
            },
        }
    }
};

pub const Styling = enum {
    None,
    Highlighted,
    Completion,
    Comment,
};

pub fn comput_render_segments(
    allocator: std.mem.Allocator,
    terminal_width: usize,
    segments: StyledBufferSegments,
    cursor_pos: usize,
    prev_cursor_row: usize,
) RenderResult {
    const w = if (terminal_width > 0) terminal_width else 80;

    const cursor_row = cursor_pos / w;
    const cursor_col = cursor_pos % w;

    const total_length = segments.total_length();
    // The row the cursor will be on after printing content.
    const end_row: usize = if (total_length == 0)
        0
    else if (total_length % w == 0)
        // Exact match - cursor will not have wrapped yet
        total_length / w - 1
    else
        (total_length - 1) / w;

    var parts: std.ArrayList([]const u8) = .empty;

    if (prev_cursor_row > 0) {
        // Move cursor back up
        alloc.append_format(&parts, allocator, "\x1b[{}A", .{prev_cursor_row});
    }

    // Carriage return and erase to the end
    // @TODO do we need to erase to the end of previous rows?
    parts.append(allocator, "\r\x1b[J") catch unreachable;

    // Write content
    for (0..segments.count) |i| {
        const styled = segments.segments[i].styled(allocator);
        parts.append(allocator, styled) catch unreachable;
    }

    // Move cursor from content end to target row
    if (end_row > cursor_row) {
        alloc.append_format(&parts, allocator, "\x1b[{}A", .{end_row - cursor_row});
    } else if (cursor_row > end_row) {
        alloc.append_format(&parts, allocator, "\x1b[{}A", .{cursor_row - cursor_row});
    }

    // Set cursor column (1-based)
    alloc.append_format(&parts, allocator, "\x1b[{}G", .{cursor_col + 1});

    const buffer = std.mem.concat(allocator, u8, parts.items) catch unreachable;

    return .{
        .buffer = buffer,
        .cursor_row = cursor_row,
    };
}

// @Cleanup @Unused
pub fn compute_render(
    allocator: std.mem.Allocator,
    terminal_width: usize,
    preprompt: []const u8,
    prompt_styled: []const u8,
    prompt_visual_width: usize,
    completion_styled: []const u8,
    completion_visual_width: usize,
    cursor_x: usize,
    preprompt_width: usize,
    prev_cursor_row: usize,
) RenderResult {
    const w = if (terminal_width > 0) terminal_width else 80;

    const abs_cursor = preprompt_width + cursor_x;
    const total_visual_width = preprompt_width + prompt_visual_width + completion_visual_width;

    const cursor_row = abs_cursor / w;
    const cursor_col = abs_cursor % w;

    // Where the terminal cursor ends up after writing all content.
    // Deferred-wrap: when total is an exact multiple of W, the terminal
    // keeps the cursor at the end of the last filled row (pending wrap).
    const end_row: usize = if (total_visual_width == 0)
        0
    else if (total_visual_width % w == 0)
        total_visual_width / w - 1
    else
        (total_visual_width - 1) / w;

    var parts: [7][]const u8 = .{ "", "", "", "", "", "", "" };
    var count: usize = 0;

    // 1. Move up from previous cursor position to row 0 of prompt
    if (prev_cursor_row > 0) {
        parts[count] = std.fmt.allocPrint(allocator, "\x1b[{}A", .{prev_cursor_row}) catch unreachable;
        count += 1;
    }

    // 2. Carriage return + erase from cursor to end of display
    parts[count] = "\r\x1b[J";
    count += 1;

    // 3. Write content
    parts[count] = preprompt;
    count += 1;
    parts[count] = prompt_styled;
    count += 1;
    if (completion_styled.len > 0) {
        parts[count] = completion_styled;
        count += 1;
    }

    // 4. Move cursor from content end to target row
    if (end_row > cursor_row) {
        parts[count] = std.fmt.allocPrint(allocator, "\x1b[{}A", .{end_row - cursor_row}) catch unreachable;
        count += 1;
    } else if (cursor_row > end_row) {
        parts[count] = std.fmt.allocPrint(allocator, "\x1b[{}B", .{cursor_row - end_row}) catch unreachable;
        count += 1;
    }

    // 5. Set cursor column (1-based)
    parts[count] = std.fmt.allocPrint(allocator, "\x1b[{}G", .{cursor_col + 1}) catch unreachable;
    count += 1;

    const buffer = std.mem.concat(allocator, u8, parts[0..count]) catch unreachable;

    return .{
        .buffer = buffer,
        .cursor_row = cursor_row,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// @TODO Migrate tests to compute_render_segments

fn test_render(
    terminal_width: usize,
    preprompt: []const u8,
    prompt_styled: []const u8,
    prompt_visual_width: usize,
    completion_styled: []const u8,
    completion_visual_width: usize,
    cursor_x: usize,
    preprompt_width: usize,
    prev_cursor_row: usize,
) struct { buf: []const u8, cursor_row: usize, arena: std.heap.ArenaAllocator } {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const result = compute_render(
        arena.allocator(),
        terminal_width,
        preprompt,
        prompt_styled,
        prompt_visual_width,
        completion_styled,
        completion_visual_width,
        cursor_x,
        preprompt_width,
        prev_cursor_row,
    );
    return .{ .buf = result.buffer, .cursor_row = result.cursor_row, .arena = arena };
}

test "single line, no wrap" {
    // W=80, preprompt "-> " (3), prompt "hello" (5), cursor at end, no completion
    // abs_cursor=8, total=8, all on row 0
    var t = test_render(80, "-> ", "hello", 5, "", 0, 5, 3, 0);
    defer t.arena.deinit();

    const expected = "\r\x1b[J" ++ "-> " ++ "hello" ++ "\x1b[9G";
    try std.testing.expectEqualSlices(u8, expected, t.buf);
    try std.testing.expectEqual(@as(usize, 0), t.cursor_row);
}

test "wrap, cursor on line 0" {
    // W=20, preprompt "-> " (3), prompt 26 chars, cursor_x=5 (abs=8)
    // total=29, end_row=1, cursor_row=0 → \x1b[1A after content
    var t = test_render(20, "-> ", "abcdefghijklmnopqrstuvwxyz", 26, "", 0, 5, 3, 0);
    defer t.arena.deinit();

    const expected = "\r\x1b[J" ++ "-> " ++ "abcdefghijklmnopqrstuvwxyz" ++ "\x1b[1A" ++ "\x1b[9G";
    try std.testing.expectEqualSlices(u8, expected, t.buf);
    try std.testing.expectEqual(@as(usize, 0), t.cursor_row);
}

test "wrap, cursor on line 1" {
    // W=10, preprompt "-> " (3), prompt 15 chars, cursor_x=12 (abs=15)
    // total=18, end_row=1, cursor_row=1 → no vertical move
    var t = test_render(10, "-> ", "abcdefghijklmno", 15, "", 0, 12, 3, 0);
    defer t.arena.deinit();

    const expected = "\r\x1b[J" ++ "-> " ++ "abcdefghijklmno" ++ "\x1b[6G";
    try std.testing.expectEqualSlices(u8, expected, t.buf);
    try std.testing.expectEqual(@as(usize, 1), t.cursor_row);
}

test "exact boundary deferred wrap" {
    // W=10, total=10 exactly → end_row should be 0 (deferred wrap, not 1)
    // preprompt "-> " (3), prompt "abcdefg" (7), cursor_x=5 (abs=8)
    // cursor_row=0, end_row=0 → no vertical move
    var t = test_render(10, "-> ", "abcdefg", 7, "", 0, 5, 3, 0);
    defer t.arena.deinit();

    const expected = "\r\x1b[J" ++ "-> " ++ "abcdefg" ++ "\x1b[9G";
    try std.testing.expectEqualSlices(u8, expected, t.buf);
    try std.testing.expectEqual(@as(usize, 0), t.cursor_row);
}

test "second draw with prev_cursor_row" {
    // prev_cursor_row=2, W=10, preprompt "-> " (3), empty prompt
    // Should emit \x1b[2A at start to get back to row 0
    var t = test_render(10, "-> ", "", 0, "", 0, 0, 3, 2);
    defer t.arena.deinit();

    const expected = "\x1b[2A" ++ "\r\x1b[J" ++ "-> " ++ "" ++ "\x1b[4G";
    try std.testing.expectEqualSlices(u8, expected, t.buf);
    try std.testing.expectEqual(@as(usize, 0), t.cursor_row);
}

test "with completion" {
    // W=20, preprompt "-> " (3), prompt "git" (3), completion "commit" styled (visual 6)
    // cursor_x=3 (abs=6), total=12, all on row 0
    const styled_completion = "\x1b[1m\x1b[36mcommit\x1b[0m";
    var t = test_render(20, "-> ", "git", 3, styled_completion, 6, 3, 3, 0);
    defer t.arena.deinit();

    const expected = "\r\x1b[J" ++ "-> " ++ "git" ++ styled_completion ++ "\x1b[7G";
    try std.testing.expectEqualSlices(u8, expected, t.buf);
    try std.testing.expectEqual(@as(usize, 0), t.cursor_row);
}

test "cursor mid-prompt, 3 lines" {
    // W=10, preprompt "-> " (3), prompt 20 chars, cursor_x=12 (abs=15)
    // total=23, end_row=2, cursor_row=1 → \x1b[1A after content
    var t = test_render(10, "-> ", "abcdefghijklmnopqrst", 20, "", 0, 12, 3, 0);
    defer t.arena.deinit();

    const expected = "\r\x1b[J" ++ "-> " ++ "abcdefghijklmnopqrst" ++ "\x1b[1A" ++ "\x1b[6G";
    try std.testing.expectEqualSlices(u8, expected, t.buf);
    try std.testing.expectEqual(@as(usize, 1), t.cursor_row);
}
