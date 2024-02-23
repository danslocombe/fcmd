const std = @import("std");
const alloc = @import("alloc.zig");
const windows = @import("windows.zig");

pub fn read_input(h_stdin: *anyopaque, input_buffer: *[64]Input, inputs_produced: *usize) bool {
    inputs_produced.* = 0;

    var record_buffer: [128]windows.INPUT_RECORD = undefined;
    var records_read: u32 = 0;
    var success = windows.ReadConsoleInputW(h_stdin, &record_buffer, 128, &records_read) != 0;
    if (!success) {
        return false;
    }

    var buffered_utf16_chars: [4]u16 = alloc.zeroed(u16, 4);
    var buffered_utf16_len: usize = 0;

    var console_input_buffer: [64]ConsoleInput = undefined;
    var console_inputs_produced: usize = 0;

    for (0..@intCast(records_read)) |i| {
        var record = record_buffer[i];
        if (record.EventType == windows.KEY_EVENT) {
            var key_event = record.Event.KeyEvent;
            // Only care about keydown events.
            if (key_event.bKeyDown == 0) {
                continue;
            }

            var utf16Char = key_event.uChar.UnicodeChar;

            buffered_utf16_chars[buffered_utf16_len] = utf16Char;
            buffered_utf16_len += 1;

            var utf8Char = Utf8Char{};
            _ = std.unicode.utf16leToUtf8(&utf8Char.bs, &buffered_utf16_chars) catch {
                continue;
            };

            buffered_utf16_len = 0;

            var ci = ConsoleInput{
                .key = key_event.wVirtualKeyCode,
                .utf8_char = utf8Char,
                .modifier_keys = key_event.dwControlKeyState,
            };

            console_input_buffer[console_inputs_produced] = ci;
            console_inputs_produced += 1;
        }
    }

    var console_inputs = console_input_buffer[0..console_inputs_produced];
    // TODO can we have escape sequences mixed in with other inputs?
    // If so we need to greedily try and pull escape sequnces
    if (try_parse_console_inputs_as_escape_sequence(console_inputs)) |input| {
        input_buffer[0] = input;
        inputs_produced.* = 1;
    } else {
        for (console_inputs) |ci| {
            if (Input.try_from_console_input(ci)) |input| {
                input_buffer[inputs_produced.*] = input;
                inputs_produced.* += 1;
            }
        }
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
                .Left = void{},
            };
        }

        if (cis[2].utf8_char.bs[0] == 'C') {
            return Input{
                .Right = void{},
            };
        }

        if (cis[2].utf8_char.bs[0] == 'H') {
            return Input{
                .GotoStart = void{},
            };
        }

        if (cis[2].utf8_char.bs[0] == 'F') {
            return Input{
                .GotoEnd = void{},
            };
        }

        if (escape_sequence_equal("1;5D", cis[2..])) {
            return Input{
                .BlockLeft = void{},
            };
        }

        if (escape_sequence_equal("1;5C", cis[2..])) {
            return Input{
                .BlockRight = void{},
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

        {
            var chars: [64][]const u8 = undefined;
            for (cis[2..], 0..) |c, i| {
                chars[i] = c.utf8_char.bs[0..1];
            }

            var full = std.mem.join(alloc.gpa.allocator(), " ", chars[0..(cis.len - 2)]) catch unreachable;
            alloc.fmt_panic("Unknown escape sequence len: {}, start: ESC [ {s}", .{ cis.len, full });
            @panic("AHHHH");
        }
    }

    return null;
}

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

    Exit: void,
    Home: void,
    End: void,

    Up: void,
    Down: void,

    Cls: void,

    Complete: void,
    PartialComplete: void,

    Enter: void,

    pub fn try_from_console_input(ci: ConsoleInput) ?Input {
        var has_ctrl = (ci.modifier_keys & 0x08) != 0;

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

    pub fn zero(self: Utf8Char) bool {
        return std.mem.readIntNative(u64, &self.bs) == 0;
    }
};
