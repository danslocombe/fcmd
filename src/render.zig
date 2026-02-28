const std = @import("std");

pub const RenderResult = struct {
    buffer: []const u8,
    cursor_row: usize,
};

/// Build the escape-sequence buffer for one draw cycle.
///
/// The algorithm:
///   1. Move up `prev_cursor_row` lines to reach row 0 of the prompt
///   2. `\r\x1b[J` — carriage return + erase to end of display
///   3. Write content (preprompt + styled prompt + styled completion)
///   4. Move cursor from content-end row to the target row
///   5. Set cursor column with `\x1b[nG` (1-based)
///
/// Returns the buffer to write and the new cursor_row (for next draw).
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
