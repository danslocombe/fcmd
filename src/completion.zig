const std = @import("std");
const alloc = @import("alloc.zig");
const data = @import("data.zig");

const lego_trie = @import("lego_trie.zig");

pub const CompletionHandler = struct {
    local_history: LocalHistoryCompleter,
    global_history: GlobalHistoryCompleter,
    directory_completer: DirectoryCompleter,

    pub fn init(trie_blocks: data.DumbList(lego_trie.TrieBlock)) CompletionHandler {
        var base = HistoryCompleter.init(trie_blocks);
        return .{
            .global_history = .{ .completer = base },
            .local_history = .{ .completer = base },
            .directory_completer = .{},
        };
    }

    pub fn update(self: *CompletionHandler, cmd: []const u8) void {
        //self.local_history.insert(cmd);
        self.global_history.insert(cmd);
    }

    pub fn get_completion(self: *CompletionHandler, prefix: []const u8) ?[]const u8 {
        // No completions for empty prefix.
        if (prefix.len == 0) {
            return null;
        }

        if (self.local_history.get_completion(prefix)) |completion| {
            return completion;
        }

        if (self.global_history.get_completion(prefix)) |completion| {
            return completion;
        }

        if (self.directory_completer.get_completion(prefix)) |completion| {
            return completion;
        }

        return null;
    }
};

pub const DirectoryCompleter = struct {
    rel_dir: ?[]const u8 = null,
    filenames: ?std.ArrayList([]const u8) = null,

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

        if (self.filenames) |xs| {
            xs.deinit();
            self.filenames = null;
        }

        self.rel_dir = alloc.copy_slice_to_gpa(rel_dir);

        //std.debug.print("Regenerating DirectoryCompleter at '{s}'...\n", .{rel_dir});

        // TODO handle full paths
        var cwd = std.fs.cwd();
        var dir: std.fs.IterableDir = undefined;
        if (cwd.openIterableDir(rel_dir, .{})) |rdir| {
            dir = rdir;
        } else |_| {
            return;
        }
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

    pub fn get_completion(self: *DirectoryCompleter, prefix: []const u8) ?[]const u8 {
        // TODO drop all but final word
        var last_word = prefix;

        var words_iter = std.mem.tokenizeAny(u8, prefix, " ");
        while (words_iter.next()) |word| {
            last_word = word;
        }

        var prefix_for_query = last_word;

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

    pub fn get_completion(self: *LocalHistoryCompleter, prefix: []const u8) ?[]const u8 {
        return self.completer.get_completion(self.add_prefix(prefix));
    }
};

pub const GlobalHistoryCompleter = struct {
    completer: HistoryCompleter,

    pub fn insert(self: *GlobalHistoryCompleter, cmd: []const u8) void {
        var with_prefix = std.mem.concat(alloc.temp_alloc.allocator(), u8, &.{ @as([]const u8, "GLOBAL_"), cmd }) catch unreachable;
        self.completer.insert(with_prefix);
    }

    pub fn get_completion(self: *GlobalHistoryCompleter, prefix: []const u8) ?[]const u8 {
        var with_prefix = std.mem.concat(alloc.temp_alloc.allocator(), u8, &.{ @as([]const u8, "GLOBAL_"), prefix }) catch unreachable;
        return self.completer.get_completion(with_prefix);
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

    pub fn get_completion(self: *HistoryCompleter, prefix: []const u8) ?[]const u8 {
        var view = self.trie.to_view();
        var walker = lego_trie.TrieWalker.init(view, prefix);
        if (walker.walk_to()) {
            // All of this should be cleaned up, walker so ugly atm.
            var extension = walker.extension.slice();
            var end_extension: []const u8 = "";

            if (!walker.reached_leaf) {
                end_extension = walker.walk_to_end(alloc.temp_alloc.allocator());
            }

            //var buffer = alloc.gpa_alloc_idk(u8, extension.len);
            //@memcpy(buffer, extension);
            var buffer = std.fmt.allocPrint(alloc.gpa.allocator(), "{s}{s}  Cost: {d}", .{ extension, end_extension, walker.cost }) catch unreachable;
            return buffer;
        }

        return null;
    }
};
