const std = @import("std");
const alloc = @import("alloc.zig");
const input = @import("input.zig");
const Zipper = @import("zipper.zig").Zipper;
const run = @import("run.zig");
const CompletionHandler = @import("completion.zig").CompletionHandler;
const data = @import("data.zig");
const windows = @import("windows.zig");

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

    pub fn draw(self: *Shell) void {
        const set_cursor_x_to_zero = "\x1b[0G";
        const clear_to_end_of_line = "\x1b[K";

        const clear_commands = comptime std.fmt.comptimePrint("{s}{s}", .{ set_cursor_x_to_zero, clear_to_end_of_line });

        var preprompt = build_preprompt();
        defer (alloc.gpa.allocator().free(preprompt));

        var prompt_buffer: []const u8 = self.current_prompt.bs.items;

        var completion_command: []const u8 = "";
        if (self.current_completion) |completion| {
            // Magenta: 35
            // Red: 31
            // Cyan: 36
            completion_command = std.fmt.allocPrint(alloc.temp_alloc.allocator(), "\x1b[1m\x1b[36m{s}\x1b[0m", .{completion}) catch unreachable;
        }

        // TODO handle setting cursor y pos.
        var cursor_x_pos = preprompt.len + self.current_prompt.char_index + 1;
        var set_cursor_to_prompt_pos = std.fmt.allocPrint(alloc.temp_alloc.allocator(), "\x1b[{}G", .{cursor_x_pos}) catch unreachable;

        var commands = [_][]const u8{
            clear_commands,
            preprompt,
            prompt_buffer,
            completion_command,
            set_cursor_to_prompt_pos,
        };

        var buffer = std.mem.concat(alloc.temp_alloc.allocator(), u8, &commands) catch unreachable;
        windows.write_console(buffer);
    }
};

const vowels: []const u8 = "aeiyouAEIYOU";

pub fn copy_remove_vowels(dest: []u8, source: []const u8) usize {
    std.debug.assert(dest.len >= source.len);

    var write_index: usize = 0;
    outer: for (0..source.len) |i| {
        if (i > 0) {
            for (vowels) |v| {
                if (source[i] == v) {
                    continue :outer;
                }
            }
        }

        dest[write_index] = source[i];
        write_index += 1;
    }

    return write_index;
}

pub fn compress_path(path: []const u8) []const u8 {
    const desired_len = 25;

    if (path.len < desired_len) {
        // Nothing to do.
        return path;
    }

    var buffer = alloc.temp_alloc.allocator().alloc(u8, path.len + 32) catch unreachable;
    //var buffer_len = path.len;

    var split_count = std.mem.count(u8, path, "\\") + 1;
    var half_index = @divFloor(split_count, 2);

    var buffer_index: usize = 0;
    var split_iter = std.mem.tokenize(u8, path, "\\");
    for (0..half_index) |i| {
        if (i != 0) {
            buffer[buffer_index] = '\\';
            buffer_index += 1;
        }

        var x = split_iter.next().?;
        buffer_index += copy_remove_vowels(buffer[buffer_index..], x);
    }

    while (split_iter.next()) |x| {
        buffer[buffer_index] = '\\';
        buffer_index += 1;

        @memcpy(buffer[buffer_index..(buffer_index + x.len)], x);
        buffer_index += x.len;
    }

    return buffer[0..buffer_index];
}

pub fn build_preprompt() []const u8 {
    var cwd = std.fs.cwd();
    var buffer: [std.os.windows.PATH_MAX_WIDE * 3 + 1]u8 = undefined;
    var filename = std.os.getFdPath(cwd.fd, &buffer) catch unreachable;

    var compressed = compress_path(filename);

    var ret = std.mem.concat(alloc.gpa.allocator(), u8, &.{ compressed, ">>> " }) catch unreachable;
    return ret;
}

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
