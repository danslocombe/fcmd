const std = @import("std");


pub const SmallStr = struct {
    const SmallStrLen = 8;

    data : [SmallStrLen]u8,

    pub fn len(self : SmallStr) u8 {
        var length = 0;
        while (length < SmallStrLen) : (length += 1) {
            if (self.data[length] == 0) {
                return length;
            }
        }

        return SmallStrLen;
    }
};

fn prefix_of(xs : SmallStr, key: []const u8) bool {
    const len = @minimum(xs.data.len, key.len);
    var i : u8 = 0;
    while (i < len) : (i+=1) {
        if (xs.data[i] != key[i]) {
            return false;
        }
    }

    return true;
}

const TrieNode = struct {
    const TrieChildCount = 8;

    metadata : u32,
    children : [TrieChildCount]SmallStr,
    data : [TrieChildCount]u32,
    // Id of sibling trie node
    next : u32,

    pub fn get_child_size(_ : TrieNode) u8 {
        return 0;
    }

    pub fn get_child(self : TrieNode, key : []const u8) ?u8 {
        var i : u8 = 0;
        while (i < self.get_child_size()) : (i+=1) {
            if (prefix_of(self.children[i], key)) {
                return i;
            }
        }

        return null;
    }
};

// TODO bad allignment waste-y
pub const ChildKey = struct {
    node_id : u32,
    child_id : u8,
};

pub const Trie = struct {
    root : u32,
    nodes : std.ArrayList(TrieNode),
    child_tables : std.AutoHashMap(ChildKey, u32),
    //tails : std.ArrayList([] const u8),

    pub fn to_view(self : *const Trie) TrieView {
        return .{
            .trie = self,
            .current_node = self.*.root,
        };
    }

    pub fn init(allocator : std.mem.Allocator) Trie {
        return .{
            .root = 0,
            .nodes = std.ArrayList(TrieNode).init(allocator),
            .child_tables = std.AutoHashMap(ChildKey, u32).init(allocator),
        };
    }
};

pub const TrieView = struct {
    trie : * const Trie,
    current_node : u32,

    pub fn walk_to(self : *TrieView, prefix : [] const u8) bool {
        var i : usize = 0;
        while (true) {
            var node = self.*.trie.nodes.items[self.*.current_node];
            if (node.get_child(prefix[i..])) |val| {
                std.mem.doNotOptimizeAway(val);
                return true;
            }
            else {
                return false;
            }
        }
    }
};