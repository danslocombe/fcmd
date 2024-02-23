const std = @import("std");
const alloc = @import("alloc.zig");
const console_input = @import("console_input.zig");
const Zipper = @import("zipper.zig").Zipper;
const run = @import("run.zig");
const ring_buffer = @import("ring_buffer.zig");

pub const Shell = struct {
    current_prompt: Zipper,
    history: History,

    pub fn init() Shell {
        return .{
            .current_prompt = Zipper.init(),
            .history = .{
                .buffer = ring_buffer.RingBuffer([]const u8).init(256, ""),
            },
        };
    }

    pub fn apply_input(self: *Shell, input: console_input.Input) void {
        if (Command.try_get_from_input(input)) |command| {
            switch (command) {
                .Run => {
                    var cmd = self.current_prompt.bs.items;

                    // Handle this nicely
                    std.debug.print("\n", .{});

                    if (run.FroggyCommand.try_get_froggy_command(cmd)) |froggy| {
                        froggy.execute();
                    } else {
                        run.run_cmd(cmd);
                        // Run command
                    }

                    self.history.push(cmd);
                    self.current_prompt.clear();
                },
                .HistoryBack => {
                    var current_history = self.history.get_current();
                    if (!std.mem.eql(u8, current_history, self.current_prompt.bs.items)) {
                        // Reset to current history item
                        self.current_prompt.clear();
                        self.current_prompt.bs.appendSlice(current_history) catch unreachable;
                        while (self.current_prompt.move_right()) |_| {}
                    } else {
                        if (self.history.back()) |prev_cmd| {
                            self.current_prompt.clear();
                            self.current_prompt.bs.appendSlice(prev_cmd) catch unreachable;
                            while (self.current_prompt.move_right()) |_| {}
                        }
                    }
                },
                .HistoryForward => {
                    if (self.history.forward()) |next_cmd| {
                        self.current_prompt.clear();
                        self.current_prompt.bs.appendSlice(next_cmd) catch unreachable;
                        while (self.current_prompt.move_right()) |_| {}
                    }
                },
                else => {
                    // TODO
                },
            }
        } else {
            self.current_prompt.apply_input(input);
        }
    }

    pub fn draw(self: *Shell) void {
        self.current_prompt.draw();
    }
};

pub const History = struct {
    buffer: ring_buffer.RingBuffer([]const u8),
    read_pos: usize = 0,
    write_pos: usize = 0,

    pub fn get_current(self: *History) []const u8 {
        return self.buffer.buffer[self.read_pos];
    }

    pub fn back(self: *History) ?[]const u8 {
        var new_read_pos = self.buffer.index_from_base_index_and_offset(self.read_pos, -1);
        var value = self.buffer.buffer[new_read_pos];
        if (value.len == 0) {
            return null;
        }

        self.read_pos = new_read_pos;
        return value;
    }

    pub fn forward(self: *History) ?[]const u8 {
        if (self.read_pos == self.write_pos) {
            // Don't allow going forward
            return null;
        }

        var value = self.buffer.buffer[self.read_pos];
        _ = value;

        var index = self.buffer.index_from_base_index_and_offset(self.read_pos, 1);
        self.read_pos = index;
        return self.buffer.buffer[index];
    }

    pub fn push(self: *History, cmd: []const u8) void {
        if (cmd.len == 0) {
            return;
        }

        var cmd_copy = alloc.gpa_alloc_idk(u8, cmd.len);
        @memcpy(cmd_copy, cmd);
        var discarded = self.buffer.push(cmd_copy);
        if (discarded.len > 0) {
            alloc.gpa.allocator().free(discarded);
        }

        self.write_pos = self.buffer.current_pos;
        self.read_pos = self.buffer.current_pos;
    }
};

pub const Command = enum {
    Run,

    Complete,
    PartialComplete,

    HistoryBack,
    HistoryForward,

    Cls,
    Exit,
    NoOp,

    fn try_get_from_input(input: console_input.Input) ?Command {
        return switch (input) {
            .Enter => Command.Run,
            .Up => Command.HistoryBack,
            .Down => Command.HistoryForward,
            else => null,
        };
    }
};
