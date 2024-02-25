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
        switch (view.walk_to(prefix)) {
            .NoMatch => return null,
            .LeafMatch => |x| {
                var block = view.trie.blocks.items[@intCast(view.current_block)];
                var str = block.nodes[@intCast(x.leaf_child_id)];
                var rest = str.slice()[x.hack_chars_used_in_leaf..];
                var copied = alloc.gpa_alloc_idk(u8, rest.len);
                @memcpy(copied, rest);
                return copied;
            },
            .NodeMatch => |x| {
                _ = x;
                // TODO
                return null;
            },
        }
    }
};
