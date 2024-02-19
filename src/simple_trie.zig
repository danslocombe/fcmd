const std = @import("std");

pub const SmallStr = struct {
    const SmallStrLen = 8;

    data: [SmallStrLen]u8,

    pub fn len(self: SmallStr) u8 {
        var length = 0;
        while (length < SmallStrLen) : (length += 1) {
            if (self.data[length] == 0) {
                return length;
            }
        }

        return SmallStrLen;
    }
};

fn prefix_of(xs: SmallStr, key: []const u8) bool {
    const len = @min(SmallStr.SmallStrLen, key.len);
    var i: u8 = 0;
    while (i < len) : (i += 1) {
        if (xs.data[i] == 0) {
            // xs ended
            return true;
        }

        if (xs.data[i] != key[i]) {
            return false;
        }
    }

    return true;
}

fn common_prefix_len(xs: SmallStr, ys: []const u8) u8 {
    const len = @min(SmallStr.SmallStrLen, ys.len);
    var i: u8 = 0;
    while (i < len) : (i += 1) {
        if (xs.data[i] == 0) {
            // xs ended
            return i;
        }

        if (xs.data[i] != ys[i]) {
            return i;
        }
    }

    return 0;
}

fn copy_to_smallstr(xs: *SmallStr, ys: []const u8) u8 {
    const len = @min(SmallStr.SmallStrLen, ys.len);
    var i: u8 = 0;
    while (i < len) : (i += 1) {
        xs.data[i] = ys[i];
    }

    return @as(u8, @intCast(len));
}

const TrieNode = struct {
    const TrieChildCount = 8;

    metadata: u32,
    children: [TrieChildCount]SmallStr,
    data: [TrieChildCount]u32,
    // Id of sibling trie node
    next: u32,

    pub fn empty() TrieNode {
        return std.mem.zeroes(TrieNode);
    }

    pub fn get_child_size(self: TrieNode) u8 {
        return @as(u8, @intCast(self.metadata));
    }

    pub fn get_child(self: TrieNode, key: []const u8) ?u8 {
        const child_size = self.get_child_size();
        std.log.info("Getting child - child count {d}", .{child_size});

        var i: u8 = 0;
        while (i < child_size) : (i += 1) {
            if (prefix_of(self.children[i], key)) {
                return i;
            }
        }

        return null;
    }

    pub fn insert_prefix(self: *TrieNode, key: []const u8) ?u32 {
        if (self.*.get_child(key) != null) {
            return null;
        }

        for (0..@intCast(self.get_child_size())) |i| {
            if (prefix_of(self.children[i], key)) {
                // Already have the prefix, nothing to do
                return null;
            }

            const common_len = common_prefix_len(self.children[i], key);

            if (common_len > 0) {
                @panic("TODO!");
            }
        }

        // No longest common prefix, insert new

        const child_size = self.*.get_child_size();

        if (child_size == TrieChildCount) {
            // Spill over to new node?
            @panic("TODO");
        }

        self.*.metadata += 1;
        std.log.info("Self child size {d}", .{self.get_child_size()});
        return copy_to_smallstr(&self.children[child_size], key);
    }
};

// TODO bad allignment waste-y
pub const ChildKey = struct {
    node_id: u32,
    child_id: u8,
};

pub const Trie = struct {
    root: u32,
    nodes: std.ArrayList(TrieNode),
    child_tables: std.ArrayList(u32),
    //child_tables : std.AutoHashMap(ChildKey, u32),
    //tails : std.ArrayList([] const u8),

    pub fn to_view(self: *Trie) TrieView {
        return .{
            .trie = self,
            .current_node = self.*.root,
        };
    }

    pub fn init(allocator: std.mem.Allocator) !Trie {
        var trie = .{
            .root = 0,
            .nodes = std.ArrayList(TrieNode).init(allocator),
            .child_tables = std.ArrayList(u32).init(allocator),
            //.child_tables = std.AutoHashMap(ChildKey, u32).init(allocator),
        };

        try trie.nodes.append(TrieNode.empty());

        return trie;
    }
};

pub const TrieView = struct {
    trie: *Trie,
    current_node: u32,

    pub fn walk_to(self: *TrieView, prefix: []const u8) bool {
        std.log.info("Walking to {s}", .{prefix});
        var i: usize = 0;
        while (true) {
            var node = self.*.trie.nodes.items[self.*.current_node];
            if (node.get_child(prefix[i..])) |val| {
                std.log.info("Successfully walked {d}", .{val});
                std.mem.doNotOptimizeAway(val);
                return true;
            } else {
                std.log.info("Could not walk", .{});
                return false;
            }
        }
    }

    pub fn insert(self: *TrieView, string: []const u8) !void {
        std.mem.doNotOptimizeAway(string);
        std.mem.doNotOptimizeAway(self);

        var node = &self.*.trie.nodes.items[self.*.current_node];

        var inserted_count = node.insert_prefix(string);
        std.log.info("Inserted {any}", .{inserted_count});
        std.log.info("node size {d}", .{self.trie.nodes.items[0].get_child_size()});
        std.mem.doNotOptimizeAway(inserted_count);

        //if (node.get_child(string)) |child_id| {
        //}
        // If there is a node with common prefix
        // Otherwise insert one

    }
};
