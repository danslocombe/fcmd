const std = @import("std");
const alloc = @import("alloc.zig");
const windows = @import("windows.zig");

pub fn read_input(input_buffer: *std.ArrayList(Input)) bool {
    // Read from windows api
    var record_buffer: [128]windows.INPUT_RECORD = undefined;
    var records_read: u32 = 0;
    if (windows.ReadConsoleInputW(windows.g_stdin, &record_buffer, 128, &records_read) == 0) {
        return false;
    }

    // Convert windows api records to console inputs

    // Use an arraylist instead of a static buffer as
    // this can get large if there is a long line copy/pasted.
    var console_input_buffer = std.ArrayList(ConsoleInput){};

    // Keep a buffer for multi u16 utf codepoints
    var buffered_utf16_chars: [4]u16 = alloc.zeroed(u16, 4);
    var buffered_utf16_len: usize = 0;

    for (0..@intCast(records_read)) |i| {
        var record = record_buffer[i];
        if (record.EventType == windows.KEY_EVENT) {
            var key_event = record.Event.KeyEvent;
            // Only care about keydown events.
            if (key_event.bKeyDown == 0) {
                continue;
            }

            const utf16Char = key_event.uChar.UnicodeChar;

            buffered_utf16_chars[buffered_utf16_len] = utf16Char;
            buffered_utf16_len += 1;

            var utf8Char = Utf8Char{};
            _ = std.unicode.utf16LeToUtf8(&utf8Char.bs, &buffered_utf16_chars) catch {
                continue;
            };

            buffered_utf16_len = 0;

            const ci = ConsoleInput{
                .key = key_event.wVirtualKeyCode,
                .utf8_char = utf8Char,
                .modifier_keys = key_event.dwControlKeyState,
            };

            console_input_buffer.append(alloc.temp_alloc.allocator(), ci) catch unreachable;
        }
    }

    // Try and parse out virtual terminal escape sequences into a single command
    //
    // TODO can we have escape sequences mixed in with other inputs?
    // If so we need to greedily try and pull escape sequnces
    if (try_parse_console_inputs_as_escape_sequence(console_input_buffer.items)) |input| {
        input_buffer.append(alloc.gpa.allocator(), input) catch unreachable;
    } else {
        for (console_input_buffer.items) |ci| {
            if (Input.try_from_console_input(ci)) |input| {
                input_buffer.append(alloc.gpa.allocator(), input) catch unreachable;
            }
        }
    }

    if (windows.buffered_ctrl_c) {
        windows.buffered_ctrl_c = false;

        input_buffer.append(alloc.gpa.allocator(), Input{
            .Copy = void{},
        }) catch unreachable;
    }

    return true;
}

fn escape_sequence_equal(s: []const u8, cis: []const ConsoleInput) bool {
    if (s.len != cis.len) {
        return false;
    }

    for (cis, s) |ci, c| {
        if (ci.utf8_char.bs[0] != c) {
            return false;
        }
    }

    return true;
}

pub fn try_parse_console_inputs_as_escape_sequence(cis: []const ConsoleInput) ?Input {
    if (cis.len < 3) {
        return null;
    }

    // Escape
    if (cis[0].utf8_char.bs[0] == '\x1b' and cis[1].utf8_char.bs[0] == '[') {
        if (cis[2].utf8_char.bs[0] == 'D') {
            return Input{
                .Left = .{},
            };
        }

        // Shift left
        if (escape_sequence_equal("1;2D", cis[2..])) {
            return Input{
                .Left = .{ .highlight = true },
            };
        }

        if (cis[2].utf8_char.bs[0] == 'C') {
            return Input{
                .Right = .{},
            };
        }

        // Shift right
        if (escape_sequence_equal("1;2C", cis[2..])) {
            return Input{
                .Right = .{ .highlight = true },
            };
        }

        if (cis[2].utf8_char.bs[0] == 'H') {
            return Input{
                .GotoStart = .{},
            };
        }

        // Shift home
        if (escape_sequence_equal("1;2H", cis[2..])) {
            return Input{
                .GotoStart = .{ .highlight = true },
            };
        }

        if (cis[2].utf8_char.bs[0] == 'F') {
            return Input{
                .GotoEnd = .{},
            };
        }

        // Shift end
        if (escape_sequence_equal("1;2F", cis[2..])) {
            return Input{
                .GotoEnd = .{ .highlight = true },
            };
        }

        // Ctrl left
        if (escape_sequence_equal("1;5D", cis[2..])) {
            return Input{
                .BlockLeft = .{},
            };
        }

        // Ctrl shift left
        if (escape_sequence_equal("1;6D", cis[2..])) {
            return Input{
                .BlockLeft = .{ .highlight = true },
            };
        }

        // Ctrl right
        if (escape_sequence_equal("1;5C", cis[2..])) {
            return Input{
                .BlockRight = .{},
            };
        }

        // Ctrl shift right
        if (escape_sequence_equal("1;6C", cis[2..])) {
            return Input{
                .BlockRight = .{ .highlight = true },
            };
        }

        if (escape_sequence_equal("A", cis[2..])) {
            return Input{
                .Up = void{},
            };
        }

        if (escape_sequence_equal("B", cis[2..])) {
            return Input{
                .Down = void{},
            };
        }

        if (escape_sequence_equal("Z", cis[2..])) {
            return Input{ .PartialCompleteReverse = void{} };
        }

        {
            var chars: [64][]const u8 = undefined;
            for (cis[2..], 0..) |c, i| {
                chars[i] = c.utf8_char.bs[0..1];
            }

            const full = std.mem.join(alloc.gpa.allocator(), " ", chars[0..(cis.len - 2)]) catch unreachable;
            std.debug.print("Warning! Unknown escape sequence Len: {}, Start: ESC [ {s}", .{ cis.len, full });
        }
    }

    return null;
}

pub const ConsoleInput = struct {
    key: u16,
    utf8_char: Utf8Char,
    modifier_keys: u32,
};

pub const CursorMovementFlags = packed struct {
    highlight: bool = false,
};

pub const Input = union(enum) {
    Append: Utf8Char,

    Left: CursorMovementFlags,
    BlockLeft: CursorMovementFlags,
    Right: CursorMovementFlags,
    BlockRight: CursorMovementFlags,

    GotoStart: CursorMovementFlags,
    GotoEnd: CursorMovementFlags,

    Delete: void,
    DeleteBlock: void,

    Exit: void,

    Up: void,
    Down: void,

    Cls: void,

    Complete: void,
    PartialComplete: void,
    PartialCompleteReverse: void,

    SelectAll: void,

    Cut: void,
    Copy: void,

    Enter: void,

    pub fn try_from_console_input(ci: ConsoleInput) ?Input {
        const has_ctrl = (ci.modifier_keys & 0x08) != 0;

        // https://github.com/danslocombe/fishycmd/blob/master/src/CLI/KeyPress.hs

        // Do we still need these?

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
                return .{ .BlockLeft = .{} };
            } else {
                return .{ .Left = .{} };
            }
        }

        // Right arrow
        if (ci.key == 0x27) {
            if (has_ctrl) {
                return .{ .BlockRight = .{} };
            } else {
                return .{ .Right = .{} };
            }
        }

        // Home
        if (ci.key == 0x24) {
            return .{ .GotoStart = .{} };
        }
        // End
        if (ci.key == 0x23) {
            return .{ .GotoEnd = .{} };
        }

        if (ci.utf8_char.zero()) {
            return null;
        }

        if (ci.utf8_char.bs[0] == '\x1b') {
            return null;
        }

        if (ci.utf8_char.bs[0] == '\r') {
            return Input{
                .Enter = void{},
            };
        }

        if (ci.utf8_char.bs[0] == '\n') {
            return Input{
                .Enter = void{},
            };
        }

        if (ci.utf8_char.bs[0] == '\t') {
            return Input{
                .PartialComplete = void{},
            };
        }

        // Ctrl + F
        if (ci.utf8_char.bs[0] == '\x06') {
            return Input{
                .Complete = void{},
            };
        }

        // Ctrl + P
        if (ci.utf8_char.bs[0] == '\x10') {
            return Input{
                .Up = void{},
            };
        }

        // Ctrl + N
        if (ci.utf8_char.bs[0] == '\x0E') {
            return Input{
                .Down = void{},
            };
        }

        // Ctrl + L
        if (ci.utf8_char.bs[0] == '\x0C') {
            return Input{
                .Cls = void{},
            };
        }

        // Del character
        if (ci.utf8_char.bs[0] == '\x7F') {
            if (has_ctrl) {
                return .{ .DeleteBlock = void{} };
            } else {
                return .{ .Delete = void{} };
            }
        }

        // Backspace char
        if (ci.utf8_char.bs[0] == '\x08') {
            return .{ .DeleteBlock = void{} };
        }

        // Ctrl + A
        if (ci.utf8_char.bs[0] == '\x01') {
            return .{ .SelectAll = void{} };
        }

        // Ctrl + X
        if (ci.utf8_char.bs[0] == '\x18') {
            return .{ .Cut = void{} };
        }

        return Input{
            .Append = ci.utf8_char,
        };
    }
};

pub const Utf8Char = struct {
    bs: [32]u8 = alloc.zeroed(u8, 32),

    pub fn from_slice(xs: []const u8) Utf8Char {
        std.debug.assert(xs.len < 32);
        var char = Utf8Char{};
        @memcpy(char.bs[0..xs.len], xs);
        return char;
    }

    pub fn slice(self: *const Utf8Char) []const u8 {
        const len = std.unicode.utf8ByteSequenceLength(self.bs[0]) catch @panic("Error getting utf8char len");
        return self.bs[0..@intCast(len)];
    }

    pub fn zero(self: Utf8Char) bool {
        return std.mem.allEqual(u8, &self.bs, 0);
    }
};
