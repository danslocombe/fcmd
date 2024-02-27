const std = @import("std");
const alloc = @import("alloc.zig");

const block_trie = @import("block_trie.zig");

pub const demo_completions = [_][]const u8{
    "echo one",
    "echo two",
};

pub const CompletionHandler = struct {
    global_history: HistoryCompleter,

    pub fn init() CompletionHandler {
        return .{
            .global_history = HistoryCompleter.init(),
        };
    }

    pub fn update(self: *CompletionHandler, cmd: []const u8) void {
        self.global_history.insert(cmd);
    }

    pub fn get_completion(self: *CompletionHandler, prefix: []const u8) ?[]const u8 {
        // No completions for empty prefix.
        if (prefix.len == 0) {
            return null;
        }

        if (self.global_history.get_completion(prefix)) |completion| {
            return completion;
        }

        return null;
    }
};

pub const HistoryCompleter = struct {
    trie: block_trie.Trie,

    pub fn init() HistoryCompleter {
        return .{ .trie = block_trie.Trie.init() };
    }

    pub fn insert(self: *HistoryCompleter, cmd: []const u8) void {
        var view = self.trie.to_view();
        view.insert(cmd) catch unreachable;
    }

    pub fn get_completion(self: *HistoryCompleter, prefix: []const u8) ?[]const u8 {
        var view = self.trie.to_view();
        var walker = block_trie.TrieWalker.init(view, prefix);
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
