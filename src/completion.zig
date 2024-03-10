const std = @import("std");
const alloc = @import("alloc.zig");
const data = @import("data.zig");
const windows = @import("windows.zig");

const lego_trie = @import("datastructures/lego_trie.zig");

pub const GetCompletionFlags = packed struct {
    complete_to_files_from_empty_prefix: bool = false,
};

pub const CompletionHandler = struct {
    local_history: LocalHistoryCompleter,
    global_history: GlobalHistoryCompleter,
    directory_completer: DirectoryCompleter,

    cycle_index: usize = 0,

    pub fn init(trie_blocks: data.DumbList(lego_trie.TrieBlock)) CompletionHandler {
        var base = HistoryCompleter.init(trie_blocks);
        return .{
            .global_history = .{ .completer = base },
            .local_history = .{ .completer = base },
            .directory_completer = .{},
        };
    }

    pub fn update(self: *CompletionHandler, cmd: []const u8) void {
        self.cycle_index = 0;

        //std.debug.print("Adding to local history...\n", .{});
        self.local_history.insert(cmd);
        if (is_global_command_heuristic(cmd)) {
            //std.debug.print("Adding to global history...\n", .{});
            self.global_history.insert(cmd);
        }

        self.directory_completer.clear();
    }

    pub fn get_completion(self: *CompletionHandler, prefix: []const u8, flags: GetCompletionFlags) ?[]const u8 {
        // No completions for empty prefix.
        if (prefix.len == 0) {
            return null;
        }

        var cycle = self.cycle_index;

        if (self.local_history.get_completion(prefix, flags)) |completion| {
            if (cycle == 0) {
                return completion;
            } else {
                cycle -|= 1;
            }
        }

        if (self.global_history.get_completion(prefix, flags)) |completion| {
            if (cycle == 0) {
                return completion;
            } else {
                cycle -|= 1;
            }
        }

        if (!has_unclosed_quotes(prefix)) {
            if (self.directory_completer.get_completion(prefix, cycle, flags)) |completion| {
                return completion;
            }
        }

        return null;
    }
};

pub const DirectoryCompleter = struct {
    rel_dir: ?[]const u8 = null,
    filenames: ?std.ArrayList([]const u8) = null,

    pub fn clear(self: *DirectoryCompleter) void {
        if (self.rel_dir) |rd| {
            alloc.gpa.allocator().free(rd);
            self.rel_dir = null;
        }

        if (self.filenames) |*xs| {
            xs.deinit();
            self.filenames = null;
        }
    }

    pub fn regenerate(self: *DirectoryCompleter, rel_dir: []const u8) void {
        if (self.rel_dir) |rd| {
            if (std.mem.eql(u8, rel_dir, rd)) {
                // Nothing to do
                return;
            }

            // Start clearing data to prep for regenerate.
            alloc.gpa.allocator().free(rd);
            self.rel_dir = null;
        }

        if (self.filenames) |*xs| {
            xs.deinit();
            self.filenames = null;
        }

        self.rel_dir = alloc.copy_slice_to_gpa(rel_dir);

        //std.debug.print("Regenerating DirectoryCompleter at '{s}'...\n", .{rel_dir});

        // TODO handle absolute paths
        var cwd = std.fs.cwd();
        var dir: std.fs.IterableDir = undefined;
        if (cwd.openIterableDir(rel_dir, .{})) |rdir| {
            dir = rdir;
        } else |_| {
            return;
        }

        defer (dir.close());
        self.filenames = alloc.new_arraylist([]const u8);

        var iter = dir.iterate();
        while (iter.next()) |m_file| {
            if (m_file) |file| {
                //std.debug.print("Found '{s}'\n", .{file.name});
                self.filenames.?.append(alloc.copy_slice_to_gpa(file.name)) catch unreachable;
            } else {
                break;
            }
        } else |_| {
            return;
        }
    }

    pub fn get_completion(self: *DirectoryCompleter, prefix: []const u8, p_cycle: usize, flags: GetCompletionFlags) ?[]const u8 {
        var cycle = p_cycle;

        // TODO drop all but final word
        var last_word = prefix;

        if (prefix.len > 0 and prefix[prefix.len - 1] == ' ') {
            // Ends with a space, want to match any files.
            last_word = "";
        } else {
            var words_iter = std.mem.tokenizeAny(u8, prefix, " ");
            while (words_iter.next()) |word| {
                last_word = word;
            }
        }

        var prefix_for_query = last_word;

        if (prefix_for_query.len == 0 and !flags.complete_to_files_from_empty_prefix) {
            return null;
        }

        var count = std.mem.count(u8, last_word, "/") + std.mem.count(u8, last_word, "\\");
        if (count == 0) {
            self.regenerate("");
        } else {
            var path_index = std.mem.lastIndexOfAny(u8, last_word, "/\\").?;
            var path = last_word[0..path_index];
            prefix_for_query = last_word[path_index + 1 ..];
            self.regenerate(path);
        }

        if (self.filenames) |xs| {
            for (xs.items) |x| {
                if (std.mem.startsWith(u8, x, prefix_for_query)) {
                    if (cycle > 0) {
                        cycle -|= 1;
                        continue;
                    }

                    return alloc.copy_slice_to_gpa(x[prefix_for_query.len..]);
                }
            }
        }

        return null;
    }
};

pub const LocalHistoryCompleter = struct {
    cwd_path: ?[]const u8 = null,
    completer: HistoryCompleter,

    pub fn add_prefix(self: *LocalHistoryCompleter, s: []const u8) []const u8 {
        if (self.cwd_path == null) {
            var cwd = std.fs.cwd();
            self.cwd_path = cwd.realpathAlloc(alloc.gpa.allocator(), "") catch unreachable;
        }

        return std.mem.concat(alloc.temp_alloc.allocator(), u8, &.{ self.cwd_path.?, "|", s }) catch unreachable;
    }

    pub fn insert(self: *LocalHistoryCompleter, cmd: []const u8) void {
        self.completer.insert(self.add_prefix(cmd));
    }

    pub fn get_completion(self: *LocalHistoryCompleter, prefix: []const u8, flags: GetCompletionFlags) ?[]const u8 {
        return self.completer.get_completion(self.add_prefix(prefix), flags);
    }
};

pub const GlobalHistoryCompleter = struct {
    completer: HistoryCompleter,

    pub fn insert(self: *GlobalHistoryCompleter, cmd: []const u8) void {
        var with_prefix = std.mem.concat(alloc.temp_alloc.allocator(), u8, &.{ @as([]const u8, "GLOBAL_"), cmd }) catch unreachable;
        self.completer.insert(with_prefix);
    }

    pub fn get_completion(self: *GlobalHistoryCompleter, prefix: []const u8, flags: GetCompletionFlags) ?[]const u8 {
        var with_prefix = std.mem.concat(alloc.temp_alloc.allocator(), u8, &.{ @as([]const u8, "GLOBAL_"), prefix }) catch unreachable;
        return self.completer.get_completion(with_prefix, flags);
    }
};

pub const HistoryCompleter = struct {
    trie: lego_trie.Trie,

    pub fn init(trie_blocks: data.DumbList(lego_trie.TrieBlock)) HistoryCompleter {
        return .{ .trie = lego_trie.Trie.init(trie_blocks) };
    }

    pub fn insert(self: *HistoryCompleter, cmd: []const u8) void {
        var view = self.trie.to_view();
        view.insert(cmd) catch unreachable;
    }

    pub fn get_completion(self: *HistoryCompleter, prefix: []const u8, flags: GetCompletionFlags) ?[]const u8 {
        var view = self.trie.to_view();
        var walker = lego_trie.TrieWalker.init(view, prefix);
        if (walker.walk_to()) {
            // All of this should be cleaned up, walker so ugly atm.
            var extension = walker.extension.slice();
            var end_extension: []const u8 = "";

            var add_heuristic_walk = !walker.reached_leaf;

            if (add_heuristic_walk) {
                end_extension = walker.walk_to_heuristic(alloc.temp_alloc.allocator(), walker.cost);
            }

            // If we are completing to files we want to discard history completions
            // that do not match anything.
            // ie we want to return null here on empty extensions.
            if (flags.complete_to_files_from_empty_prefix and
                extension.len == 0 and end_extension.len == 0)
            {
                return null;
            }

            return std.mem.concat(alloc.gpa.allocator(), u8, &.{ extension, end_extension }) catch unreachable;
        }

        return null;
    }
};

fn has_unclosed_quotes(xs: []const u8) bool {
    var double_count: u32 = 0;
    var single_count: u32 = 0;
    var backtick_count: u32 = 0;
    for (xs) |x| {
        if (x == '"') {
            double_count += 1;
        }
        if (x == '\'') {
            single_count += 1;
        }
        if (x == '`') {
            backtick_count += 1;
        }
    }

    return double_count % 2 != 0 or single_count % 2 != 0 or backtick_count % 2 != 0;
}

fn is_global_command_heuristic(command: []const u8) bool {
    var words_iter = std.mem.tokenizeAny(u8, command, " ");

    while (words_iter.next()) |word| {
        if (std.mem.eql(u8, word, ".") or std.mem.eql(u8, word, "..")) {
            // Special cases, technically refer to current directoy, but also applicable anywhere.
            continue;
        }

        if (windows.word_is_local_path(word)) {
            return false;
        }
    }

    return true;
}
