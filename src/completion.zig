const std = @import("std");
const alloc = @import("alloc.zig");

const simple_trie = @import("simple_trie.zig");

pub const demo_completions = [_][]const u8{
    "echo one",
    "echo two",
};

pub const CompletionHandler = struct {
    pub fn init() CompletionHandler {
        return .{};
    }

    pub fn get_completion(self: *CompletionHandler, prefix: []const u8) ?[]const u8 {
        _ = self;
        // No completions for empty prefix.
        if (prefix.len == 0) {
            return null;
        }

        // Demo
        for (demo_completions) |demo| {
            if (prefix.len < demo.len and std.mem.eql(u8, prefix, demo[0..prefix.len])) {
                return demo[prefix.len..];
            }
        }

        return null;
    }
};

pub const GlobalHistory = struct {
    trie: simple_trie.Trie,

    pub fn init() GlobalHistory {
        return .{
            .trie = simple_trie.Trie.init(alloc.gpa.allocator()),
        };
    }

    pub fn insert(self: *GlobalHistory, cmd: []const u8) void {
        _ = cmd;
        _ = self;
    }

    pub fn get_completion(self: *GlobalHistory) ?[]const u8 {
        _ = self;
        return null;
    }
};
