const std = @import("std");
const alloc = @import("alloc.zig");
const input = @import("input.zig");
const prompt_lib = @import("prompt.zig");
const Prompt = prompt_lib.Prompt;
const PromptCursorPos = prompt_lib.PromptCursorPos;
const run = @import("run.zig");
const completion_lib = @import("completion.zig");
const CompletionHandler = completion_lib.CompletionHandler;
const data = @import("data.zig");
const windows = @import("windows.zig");
const preprompt = @import("preprompt.zig");
const render = @import("render.zig");

const ring_buffer = @import("datastructures/ring_buffer.zig");
const lego_trie = @import("datastructures/lego_trie.zig");

pub const Shell = struct {
    prompt: Prompt,
    partial_complete_prev_cursor_pos: ?PromptCursorPos = null,
    prev_cursor_row: usize = 0,

    history: History,
    completion_handler: CompletionHandler,
    current_completion: ?[]const u8 = null,

    fn get_completion_flags(self: *Shell) completion_lib.GetCompletionFlags {
        var flags = completion_lib.GetCompletionFlags{};
        if (run.FroggyCommand.try_get_froggy_command(self.prompt.bs.items)) |froggy| {
            switch (froggy) {
                .Cd => {
                    flags.complete_to_directories_not_files = true;
                },
                else => {},
            }
        }
        return flags;
    }

    pub fn init(trie_blocks: *data.MappedArray(lego_trie.TrieBlock)) Shell {
        return .{
            .prompt = Prompt.init(),
            .history = .{
                .buffer = ring_buffer.RingBuffer([]const u8).init(256, ""),
            },
            .completion_handler = CompletionHandler.init(trie_blocks),
        };
    }

    /// Returns true if the shell should exit.
    pub fn apply_input(self: *Shell, in: input.Input) bool {
        if (Command.try_get_from_input(in)) |command| {
            switch (command) {
                .Run => {
                    const cmd = self.prompt.bs.items;

                    // @TODO Handle this nicely
                    std.debug.print("\n", .{});
                    self.prev_cursor_row = 0;

                    var run_result = run.run(cmd);

                    if (run_result.exit) return true;

                    self.history.push(cmd);

                    if (run_result.add_to_history) {
                        self.completion_handler.update(cmd);
                    }

                    if (self.completion_handler.local_history.cwd_path) |cwd| {
                        alloc.gpa.allocator().free(cwd);
                    }
                    self.completion_handler.local_history.cwd_path = null;

                    self.prompt.clear();
                    self.partial_complete_prev_cursor_pos = null;
                },
                .HistoryBack => {
                    const current_history = self.history.get_current();
                    if (!std.mem.eql(u8, current_history, self.prompt.bs.items)) {
                        // Reset to current history item
                        self.prompt.clear();
                        self.partial_complete_prev_cursor_pos = null;

                        self.prompt.bs.appendSlice(alloc.gpa.allocator(), current_history) catch unreachable;
                        while (self.prompt.move_right()) |_| {}
                    } else {
                        if (self.history.back()) |prev_cmd| {
                            self.prompt.clear();
                            self.partial_complete_prev_cursor_pos = null;

                            self.prompt.bs.appendSlice(alloc.gpa.allocator(), prev_cmd) catch unreachable;
                            while (self.prompt.move_right()) |_| {}
                        }
                    }
                },
                .HistoryForward => {
                    if (self.history.forward()) |next_cmd| {
                        self.prompt.clear();
                        self.partial_complete_prev_cursor_pos = null;
                        self.prompt.bs.appendSlice(alloc.gpa.allocator(), next_cmd) catch unreachable;
                        while (self.prompt.move_right()) |_| {}
                    }
                },
                .Complete => {
                    if (self.current_completion) |cc| {
                        self.prompt.bs.appendSlice(alloc.gpa.allocator(), cc) catch unreachable;
                        while (self.prompt.move_right()) |_| {}
                    }
                },
                .PartialComplete, .PartialCompleteReverse => {
                    const reverse = command == Command.PartialCompleteReverse;

                    if (self.partial_complete_prev_cursor_pos) |pos| {
                        // User has previously tab completed from somewhere
                        // Cycle the completion handler and if successful, reset the prompt to the previous state and apply the new completion.
                        if (self.current_completion == null or self.current_completion.?.len == 0) {
                            if (self.current_completion) |cc| {
                                alloc.gpa.allocator().free(cc);
                            }

                            if (reverse) {
                                self.completion_handler.cycle_index -|= 1;
                            } else {
                                self.completion_handler.cycle_index += 1;
                            }

                            var flags = self.get_completion_flags();
                            flags.complete_to_files_from_empty_prefix = true;
                            self.current_completion = self.completion_handler.get_completion(self.prompt.bs.items[0..pos.byte_index], flags);

                            // Bit ugly, if we've gone too far, back up
                            if ((self.current_completion == null or self.current_completion.?.len == 0) and !reverse) {
                                self.completion_handler.cycle_index -|= 1;
                            } else {
                                self.prompt.move_to_and_clear_end(pos);
                            }
                        }
                    } else {
                        // User has typed something and pressed enter but no completion
                        // Try and re-trigger completion handler get completions with more aggressive flags
                        if (self.current_completion == null or self.current_completion.?.len == 0) {
                            if (self.current_completion) |cc| {
                                alloc.gpa.allocator().free(cc);
                            }

                            var flags = self.get_completion_flags();
                            flags.complete_to_files_from_empty_prefix = true;
                            self.current_completion = self.completion_handler.get_completion(self.prompt.bs.items, flags);
                        }
                    }

                    if (self.current_completion) |cc| {
                        if (cc.len > 0) {
                            self.partial_complete_prev_cursor_pos = self.prompt.pos;

                            // Drop whitespace at the start.
                            var start_index: usize = 0;
                            for (0..cc.len) |i| {
                                if (cc[i] != ' ') {
                                    start_index = i;
                                    break;
                                }
                            }

                            var end_index = start_index;
                            const add_char: ?u8 = null;
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

                            self.prompt.bs.appendSlice(alloc.gpa.allocator(), cc[0 .. end_index + 1]) catch unreachable;
                            if (add_char) |c| {
                                self.prompt.bs.append(alloc.gpa.allocator(), c) catch unreachable;
                            }

                            while (self.prompt.move_right()) |_| {}
                        }
                    }
                },
                .Cls => {
                    // We love hackin'
                    var cls = run.FroggyCommand{ .Cls = void{} };
                    _ = cls.execute();
                    self.prev_cursor_row = 0;
                },
                else => {
                    // TODO
                },
            }
        } else {
            self.prompt.apply_input(in);

            self.completion_handler.cycle_index = 0;
            self.partial_complete_prev_cursor_pos = null;
        }

        // TODO dont recompute when we dont have to
        if (self.current_completion) |cc| {
            alloc.gpa.allocator().free(cc);
        }

        self.current_completion = self.completion_handler.get_completion(self.prompt.bs.items, self.get_completion_flags());
        return false;
    }

    pub fn draw(self: *Shell) void {
        var built_preprompt = preprompt.build_preprompt();
        defer (alloc.gpa.allocator().free(built_preprompt));

        var prompt_buffer: []const u8 = self.prompt.bs.items;
        const prompt_visual_width = self.prompt.char_len();
        if (self.prompt.highlight) |highlight| {
            const before_highlight = prompt_buffer[0..highlight.start_pos.byte_index];
            const highlighted = prompt_buffer[highlight.start_pos.byte_index..highlight.end_pos.byte_index];
            const after_highlight = prompt_buffer[highlight.end_pos.byte_index..];
            prompt_buffer = std.fmt.allocPrint(alloc.temp_alloc.allocator(), "{s}\x1b[42m{s}\x1b[0m{s}", .{ before_highlight, highlighted, after_highlight }) catch unreachable;
        }

        var completion_styled: []const u8 = "";
        var completion_visual_width: usize = 0;
        if (self.current_completion) |completion| {
            completion_styled = std.fmt.allocPrint(alloc.temp_alloc.allocator(), "\x1b[1m\x1b[36m{s}\x1b[0m", .{completion}) catch unreachable;
            completion_visual_width = completion.len;
        }

        const result = render.compute_render(
            alloc.temp_alloc.allocator(),
            windows.get_console_width(),
            built_preprompt,
            prompt_buffer,
            prompt_visual_width,
            completion_styled,
            completion_visual_width,
            self.prompt.pos.x,
            built_preprompt.len,
            self.prev_cursor_row,
        );
        windows.write_console(result.buffer);
        self.prev_cursor_row = result.cursor_row;
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
        const new_read_pos = self.buffer.index_from_base_index_and_offset(self.read_pos, -1);
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

        const value = self.buffer.buffer[self.read_pos];
        _ = value;

        const index = self.buffer.index_from_base_index_and_offset(self.read_pos, 1);
        self.read_pos = index;
        return self.buffer.buffer[index];
    }

    pub fn push(self: *History, cmd: []const u8) void {
        if (cmd.len == 0) {
            return;
        }

        const current_at_write_pos = self.buffer.buffer[self.write_pos];
        if (std.mem.eql(u8, cmd, current_at_write_pos)) {
            // Don't push duplicate commands to history
            return;
        }

        const cmd_copy = alloc.gpa_alloc_idk(u8, cmd.len);
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
    PartialCompleteReverse,

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
            .PartialCompleteReverse => Command.PartialCompleteReverse,
            .Cls => Command.Cls,
            else => null,
        };
    }
};
