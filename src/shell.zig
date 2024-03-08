const std = @import("std");
const alloc = @import("alloc.zig");
const input = @import("input.zig");
const Zipper = @import("zipper.zig").Zipper;
const run = @import("run.zig");
const CompletionHandler = @import("completion.zig").CompletionHandler;
const data = @import("data.zig");

const ring_buffer = @import("datastructures/ring_buffer.zig");
const lego_trie = @import("datastructures/lego_trie.zig");

pub const Shell = struct {
    current_prompt: Zipper,
    history: History,
    completion_handler: CompletionHandler,
    current_completion: ?[]const u8 = null,

    pub fn init(trie_blocks: data.DumbList(lego_trie.TrieBlock)) Shell {
        return .{
            .current_prompt = Zipper.init(),
            .history = .{
                .buffer = ring_buffer.RingBuffer([]const u8).init(256, ""),
            },
            .completion_handler = CompletionHandler.init(trie_blocks),
        };
    }

    pub fn apply_input(self: *Shell, in: input.Input) void {
        if (Command.try_get_from_input(in)) |command| {
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
                    self.completion_handler.update(cmd);
                    if (self.completion_handler.local_history.cwd_path) |cwd| {
                        alloc.gpa.allocator().free(cwd);
                    }
                    self.completion_handler.local_history.cwd_path = null;
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
                .Complete => {
                    if (self.current_completion) |cc| {
                        self.current_prompt.bs.appendSlice(cc) catch unreachable;
                        while (self.current_prompt.move_right()) |_| {}
                    }
                },
                .PartialComplete => {
                    if (self.current_completion) |cc| {
                        // Drop whitespace at the start.
                        var start_index: usize = 0;
                        for (0..cc.len) |i| {
                            if (cc[i] != ' ') {
                                start_index = i;
                                break;
                            }
                        }

                        var end_index = start_index;
                        var add_char: ?u8 = null;
                        for (start_index..cc.len) |i| {
                            if (cc[i] == ' ') {
                                break;
                            }

                            end_index = i;

                            if (cc[i] == '\\' or cc[i] == '/') {
                                //add_char = cc[i];
                                break;
                            }
                        }

                        self.current_prompt.bs.appendSlice(cc[0 .. end_index + 1]) catch unreachable;
                        if (add_char) |c| {
                            self.current_prompt.bs.append(c) catch unreachable;
                        }

                        while (self.current_prompt.move_right()) |_| {}
                    }
                },
                .Cls => {
                    // We love hackin'
                    var cls = run.FroggyCommand{ .Cls = void{} };
                    cls.execute();
                },
                else => {
                    // TODO
                },
            }
        } else {
            self.current_prompt.apply_input(in);
        }

        // TODO dont recompute when we dont have to
        if (self.current_completion) |cc| {
            alloc.gpa.allocator().free(cc);
        }
        self.current_completion = self.completion_handler.get_completion(self.current_prompt.bs.items);
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

        var current_at_write_pos = self.buffer.buffer[self.write_pos];
        if (std.mem.eql(u8, cmd, current_at_write_pos)) {
            // Don't push duplicate commands to history
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

    fn try_get_from_input(in: input.Input) ?Command {
        return switch (in) {
            .Enter => Command.Run,
            .Up => Command.HistoryBack,
            .Down => Command.HistoryForward,
            .Complete => Command.Complete,
            .PartialComplete => Command.PartialComplete,
            .Cls => Command.Cls,
            else => null,
        };
    }
};
