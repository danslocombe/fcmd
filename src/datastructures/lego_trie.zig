const std = @import("std");
const alloc = @import("../alloc.zig");
const data_lib = @import("../data.zig");
const data = @import("../data.zig");

const InlineString = @import("inline_string.zig").InlineString;

const BaseCost = 1000;

const TallStringLen = 22;
const TallNodeLen = 2;
const WideStringLen = 1;
const WideNodeLen = 8;

pub const TrieBlock = struct {
    const NextAndBlockshape = packed struct {
        next: u31 = 0,
        wide: bool = true,
    };

    metadata: NextAndBlockshape,
    node_data: extern union {
        wide: NodeData(1, 8),
        tall: NodeData(TallStringLen, 2),
    },

    pub fn empty_tall() TrieBlock {
        return TrieBlock{
            .metadata = .{
                .next = 0,
                .wide = false,
            },
            .node_data = .{
                .tall = .{},
            },
        };
    }

    pub fn empty_wide() TrieBlock {
        return TrieBlock{
            .metadata = .{
                .next = 0,
                .wide = true,
            },
            .node_data = .{
                .wide = .{},
            },
        };
    }

    fn get_child_size(self: *TrieBlock) usize {
        if (self.metadata.wide) {
            return self.node_data.wide.get_child_size();
        }

        return self.node_data.tall.get_child_size();
    }

    fn get_node_count(self: *TrieBlock) usize {
        if (self.metadata.wide) {
            return WideNodeLen;
        }

        return TallNodeLen;
    }

    fn get_string_size(self: *TrieBlock) usize {
        if (self.metadata.wide) {
            return WideStringLen;
        }

        return TallStringLen;
    }

    pub fn get_child(self: *TrieBlock, key: []const u8) ?GetChildResult {
        if (self.metadata.wide) {
            return self.node_data.wide.get_child(key);
        }

        return self.node_data.tall.get_child(key);
    }

    fn insert_prefix(self: *TrieBlock, trie: *Trie, key: []const u8) void {
        var node_count = self.get_node_count();
        var string_size = self.get_string_size();
        _ = string_size;

        if (self.metadata.wide) {
            if (self.node_data.wide.try_insert_along(trie, key)) {
                return;
            }
        } else {
            if (self.node_data.tall.try_insert_along(trie, key)) {
                return;
            }
        }

        var child_size = self.get_child_size();

        // No matches
        if (child_size == node_count) {
            if (!self.metadata.wide) {
                // Promote to wide
                var replacement = self.node_data.tall.promote_tall_to_wide(trie);
                self.node_data = .{ .wide = replacement };
                self.metadata.wide = true;
            } else {
                // Couldnt find mathces in this node group, and the node group is full
                // Move to siblings.
                //
                // No sibling, need to insert one
                if (self.metadata.next == 0) {
                    trie.blocks.append(TrieBlock.empty_wide());
                    var new_node_id: u32 = @intCast(trie.blocks.len.* - 1);
                    self.metadata.next = @intCast(new_node_id);
                }

                var next = trie.blocks.at(@intCast(self.metadata.next));

                // Note we don't call insert_prefix_and_sort here because the sorting run by the caller of this
                // method will already go through all siblings.
                return next.insert_prefix(trie, key);
            }
        }

        // Insert into this node
        if (self.metadata.wide) {
            self.node_data.wide.insert_down(trie, key);
        } else {
            self.node_data.tall.insert_down(trie, key);
        }
    }

    pub fn sort(self: *TrieBlock, trie: *Trie) void {
        // Sort children
        // Bubble sort was the easiest to implement
        // I'm so sorry
        // @Speed.
        var total_count: usize = 0;
        var i_iter = ChildIterator{ .block = self, .trie = trie };
        while (i_iter.next()) {
            total_count += 1;
        }

        if (total_count < 2) {
            // Nothing to do
            return;
        }

        // Assume all of the same shape
        var wide = self.metadata.wide;

        for (0..total_count) |i| {
            var iter_0 = ChildIterator{ .block = self, .trie = trie };
            var iter_1 = iter_0;
            var res = iter_1.next();
            std.debug.assert(res);

            var swapped = false;

            for (0..(total_count - i - 1)) |_| {
                res = iter_0.next();
                std.debug.assert(res);
                res = iter_1.next();
                std.debug.assert(res);

                // Remove duplication
                if (wide) {
                    var cost_0 = iter_0.block.node_data.wide.costs[iter_0.i.?];
                    var cost_1 = iter_1.block.node_data.wide.costs[iter_1.i.?];

                    // Use >= instead of > to prefer recent insertions
                    if (cost_0 >= cost_1) {
                        swapped = true;

                        var tmp_cost = iter_0.block.node_data.wide.costs[iter_0.i.?];
                        var tmp_str = iter_0.block.node_data.wide.nodes[iter_0.i.?];
                        var tmp_data = iter_0.block.node_data.wide.data[iter_0.i.?];

                        iter_0.block.node_data.wide.costs[iter_0.i.?] = iter_1.block.node_data.wide.costs[iter_1.i.?];
                        iter_0.block.node_data.wide.nodes[iter_0.i.?] = iter_1.block.node_data.wide.nodes[iter_1.i.?];
                        iter_0.block.node_data.wide.data[iter_0.i.?] = iter_1.block.node_data.wide.data[iter_1.i.?];

                        iter_1.block.node_data.wide.costs[iter_1.i.?] = tmp_cost;
                        iter_1.block.node_data.wide.nodes[iter_1.i.?] = tmp_str;
                        iter_1.block.node_data.wide.data[iter_1.i.?] = tmp_data;
                    }
                } else {
                    var cost_0 = iter_0.block.node_data.tall.costs[iter_0.i.?];
                    var cost_1 = iter_1.block.node_data.tall.costs[iter_1.i.?];

                    // Use >= instead of > to prefer recent insertions
                    if (cost_0 >= cost_1) {
                        swapped = true;

                        var tmp_cost = iter_0.block.node_data.tall.costs[iter_0.i.?];
                        var tmp_str = iter_0.block.node_data.tall.nodes[iter_0.i.?];
                        var tmp_data = iter_0.block.node_data.tall.data[iter_0.i.?];

                        iter_0.block.node_data.tall.costs[iter_0.i.?] = iter_1.block.node_data.tall.costs[iter_1.i.?];
                        iter_0.block.node_data.tall.nodes[iter_0.i.?] = iter_1.block.node_data.tall.nodes[iter_1.i.?];
                        iter_0.block.node_data.tall.data[iter_0.i.?] = iter_1.block.node_data.tall.data[iter_1.i.?];

                        iter_1.block.node_data.tall.costs[iter_1.i.?] = tmp_cost;
                        iter_1.block.node_data.tall.nodes[iter_1.i.?] = tmp_str;
                        iter_1.block.node_data.tall.data[iter_1.i.?] = tmp_data;
                    }
                }
            }

            if (!swapped) {
                break;
            }
        }
    }

    pub fn insert_prefix_and_sort(self: *TrieBlock, trie: *Trie, key: []const u8) void {
        self.insert_prefix(trie, key);
        self.sort(trie);
    }
};

pub const GetChildResult = struct {
    node_id: usize,
    used_chars: usize,
    data: NodeDataWithIsLeaf,
    slice: []const u8,
    cost: u16,
};

pub const NodeDataWithIsLeaf = packed struct {
    data: u30 = 0,
    exists: bool = false,
    is_leaf: bool = false,
};

pub const WideNodeData = NodeData(WideStringLen, WideNodeLen);
pub const TallNodeData = NodeData(TallStringLen, TallNodeLen);

pub fn NodeData(comptime StringLen: usize, comptime NodeCount: usize) type {
    return extern struct {
        const Self = @This();

        nodes: [NodeCount]InlineString(StringLen) = alloc.defaulted(InlineString(StringLen), NodeCount),
        data: [NodeCount]NodeDataWithIsLeaf = alloc.defaulted(NodeDataWithIsLeaf, NodeCount),
        costs: [NodeCount]u16 = alloc.zeroed(u16, NodeCount),

        pub fn get_child_size(self: Self) usize {
            var size: usize = 0;
            for (self.data) |d| {
                if (!d.exists) {
                    break;
                }
                size += 1;
            }

            return size;
        }

        pub fn promote_tall_to_wide(self: *Self, trie: *Trie) WideNodeData {
            // Allocate new
            var replacement = WideNodeData{};

            for (0..TallNodeLen) |i| {
                if (self.nodes[i].len() <= WideStringLen) {
                    // Special case already short enough, don't allocate anything just copy over.
                    replacement.nodes[i].assign_from(self.nodes[i].slice());
                    replacement.data[i] = self.data[i];
                    replacement.costs[i] = self.costs[i];

                    continue;
                }

                trie.blocks.append(TrieBlock.empty_tall());
                var new_index: u30 = @intCast(trie.blocks.len.* - 1);

                var new_block = trie.blocks.at(@intCast(new_index));
                new_block.node_data.tall.nodes[0].assign_from(self.nodes[i].slice()[WideStringLen..]);
                new_block.node_data.tall.data[0] = self.data[i];
                new_block.node_data.tall.costs[0] = self.costs[i];

                replacement.nodes[i].assign_from(self.nodes[i].slice()[0..WideStringLen]);
                replacement.data[i].exists = true;
                replacement.data[i].is_leaf = false;
                replacement.data[i].data = new_index;
                replacement.costs[i] = self.costs[i];
            }

            return replacement;
        }

        pub fn get_child(self: Self, key: []const u8) ?GetChildResult {
            for (self.data, self.nodes, self.costs, 0..) |d, node, cost, i| {
                if (!d.exists) {
                    return null;
                }

                if (node.len() == 0) {
                    // Special case
                    // When there is a node and then a leaf below it
                    // We represent that leaf as an empty string
                    // We do not want to walk to that.
                    continue;
                }
                if (node.matches(key)) {
                    return .{
                        .node_id = @intCast(i),
                        .used_chars = @min(key.len, node.len()),
                        .data = d,

                        .slice = node.slice(),
                        .cost = cost,
                    };
                }
            }

            return null;
        }

        pub fn try_insert_along(self: *Self, trie: *Trie, key: []const u8) bool {
            for (0..NodeCount) |i| {
                const common_len = self.nodes[i].common_prefix_len(key);

                if (common_len > 0) {
                    var child_slice = (&self.nodes[i]).slice();
                    var recurse_key: []const u8 = "";

                    if (common_len == child_slice.len and !self.data[i].is_leaf) {
                        // Exists as a node
                        // Falthrough to recurse
                        recurse_key = key[common_len..];
                        self.costs[i] -|= 1;
                    } else {
                        // Split on common prefix
                        var split_first = child_slice[0..common_len];
                        var split_first_smallstring = InlineString(StringLen).from_slice(split_first);
                        var split_second = child_slice[common_len..];
                        var split_second_smallstring = InlineString(TallStringLen).from_slice(split_second);

                        // Create new block to hold children
                        trie.blocks.append(TrieBlock.empty_tall());
                        var new_block_id: u30 = @intCast(trie.blocks.len.* - 1);
                        var new_block = trie.blocks.at(new_block_id);
                        var new_tall = &new_block.*.node_data.tall;
                        new_tall.*.data[0] = self.data[i];
                        std.debug.assert(new_tall.*.data[0].exists);
                        new_tall.*.nodes[0] = split_second_smallstring;
                        new_tall.*.costs[0] = self.costs[i];

                        // Update existing node
                        self.data[i].data = new_block_id;
                        self.data[i].exists = true;
                        self.data[i].is_leaf = false;
                        self.nodes[i] = split_first_smallstring;
                        self.costs[i] -|= 1;

                        recurse_key = key[common_len..];
                    }

                    if (recurse_key.len == 0) {
                        // Nothing to do;
                        return true;
                    }

                    var block_id = self.data[i].data;
                    var block = trie.blocks.at(@intCast(block_id));
                    block.insert_prefix_and_sort(trie, recurse_key);
                    return true;
                }
            }

            return false;
        }

        pub fn insert_down(self: *Self, trie: *Trie, key: []const u8) void {
            std.debug.assert(self.get_child_size() < NodeCount);
            var insert_index = self.get_child_size();
            if (key.len < StringLen) {
                // Insert single
                self.nodes[insert_index].assign_from(key);
                self.data[insert_index].is_leaf = true;
                self.data[insert_index].data = 0;
                self.data[insert_index].exists = true;
                self.costs[insert_index] = BaseCost;
            } else {
                // Insert multiple
                self.nodes[insert_index].assign_from(key[0..StringLen]);

                trie.blocks.append(TrieBlock.empty_tall());
                var new_node_id: u30 = @intCast(trie.blocks.len.* - 1);
                var new_node = trie.blocks.at(new_node_id);

                self.data[insert_index].is_leaf = false;
                self.data[insert_index].data = new_node_id;
                self.data[insert_index].exists = true;
                self.costs[insert_index] = BaseCost;

                new_node.insert_prefix_and_sort(trie, key[StringLen..]);
            }
        }
    };
}

pub const StepResult = struct {
    leaf_match: bool,
    get_child: GetChildResult,
};

pub const TrieView = struct {
    trie: *Trie,
    current_block: u32 = 0,

    pub fn insert(self: *TrieView, string: []const u8) !void {
        var node = self.trie.blocks.at(@intCast(self.*.current_block));
        node.insert_prefix_and_sort(self.trie, string);
    }

    pub fn walker(self: TrieView, prefix: []const u8) TrieWalker {
        return TrieWalker{
            .trie_view = self,
            .prefix = prefix,
        };
    }

    pub fn step_nomove(self: *TrieView, prefix: []const u8) ?StepResult {
        var node = self.*.trie.blocks.at(self.*.current_block);
        if (node.get_child(prefix)) |child_match_info| {
            if (child_match_info.data.is_leaf) {
                return StepResult{
                    .leaf_match = true,
                    .get_child = child_match_info,
                };
            } else {
                return StepResult{
                    .leaf_match = false,
                    .get_child = child_match_info,
                };
            }
        }

        return null;
    }
};

pub const TrieWalker = struct {
    trie_view: TrieView,

    char_id: usize = 0,
    cost: u16 = 0,

    reached_leaf: bool = false,

    prefix: []const u8,
    extension: InlineString(32) = .{},

    pub fn init(view: TrieView, prefix: []const u8) TrieWalker {
        return TrieWalker{
            .trie_view = view,
            .prefix = prefix,
        };
    }

    pub fn walk_trivial(self: *TrieWalker) void {
        _ = self;
    }

    pub fn walk_to_end(self: *TrieWalker, allocator: std.mem.Allocator) []const u8 {
        var components = std.ArrayList([]const u8).init(alloc.temp_alloc.allocator());
        while (true) {
            var current = self.trie_view.trie.blocks.at(self.trie_view.current_block);
            if (current.get_child_size() == 0) {
                break;
            }

            var str: []const u8 = undefined;
            var is_leaf: bool = undefined;
            var next_block: u30 = undefined;

            if (current.metadata.wide) {
                str = current.node_data.wide.nodes[0].slice();
                is_leaf = current.node_data.wide.data[0].is_leaf;
                next_block = current.node_data.wide.data[0].data;
            } else {
                str = current.node_data.tall.nodes[0].slice();
                is_leaf = current.node_data.tall.data[0].is_leaf;
                next_block = current.node_data.tall.data[0].data;
            }

            components.append(str) catch unreachable;
            if (is_leaf) {
                break;
            }
            self.trie_view.current_block = next_block;
        }

        return std.mem.concat(allocator, u8, components.items) catch unreachable;
    }

    pub fn walk_to(self: *TrieWalker) bool {
        while (true) {
            var current_prefix = self.prefix[self.char_id..];
            var current = self.trie_view.trie.blocks.at(self.trie_view.current_block);
            self.extension = .{};

            if (self.trie_view.step_nomove(current_prefix)) |step_result| {
                self.reached_leaf = step_result.leaf_match;

                self.char_id += @intCast(step_result.get_child.used_chars);
                self.extension.assign_from(step_result.get_child.slice[@intCast(step_result.get_child.used_chars)..]);
                self.cost = step_result.get_child.cost;

                if (self.reached_leaf) {
                    return true;
                } else {
                    self.trie_view.current_block = step_result.get_child.data.data;
                    if (self.char_id < self.prefix.len) {
                        continue;
                    } else {
                        return true;
                    }
                }
            } else {
                if (current.metadata.next > 0) {
                    self.trie_view.current_block = @intCast(current.metadata.next);
                    continue;
                } else {
                    return false;
                }
            }
        }
    }
};

pub const Trie = struct {
    blocks: data_lib.DumbList(TrieBlock),

    const root = 0;
    //tails : std.ArrayList([] const u8),

    pub fn to_view(self: *Trie) TrieView {
        return .{
            .trie = self,
            .current_block = root,
        };
    }

    pub fn init(trie_blocks: data_lib.DumbList(TrieBlock)) Trie {
        if (trie_blocks.len.* == 0) {
            trie_blocks.append(TrieBlock.empty_tall());
        }

        return Trie{
            .blocks = trie_blocks,
        };
    }
};

pub const ChildIterator = struct {
    block: *TrieBlock,
    trie: *Trie,
    i: ?usize = null,

    pub fn next(self: *ChildIterator) bool {
        if (self.i == null) {
            self.i = 0;
            return true;
        }

        self.i.? += 1;

        var child_size = self.block.get_child_size();
        if (self.i.? == child_size) {
            if (self.block.metadata.next > 0) {
                var new = self.trie.blocks.at(self.block.metadata.next);
                self.block = new;
                self.i.? = 0;
            } else {
                return false;
            }
        }

        if (self.i.? < self.block.get_child_size()) {
            return true;
        }

        return false;
    }
};

fn test_equal(actual: anytype, expected: @TypeOf(actual)) !void {
    return std.testing.expectEqual(expected, actual);
}

test "insert single" {
    var strings = [_][]const u8{
        "bug",
    };

    var backing: [16]TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(TrieBlock){
        .len = &len,
        .map = &backing,
    };

    var trie = Trie.init(blocks);
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    try test_equal(view.current_block, 0);
    var walker = view.walker("b");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.char_id, 1);

    walker = view.walker("bug");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.char_id, 3);

    walker = view.walker("bag");
    try std.testing.expect(!walker.walk_to());
}

test "insert double" {
    var strings = [_][]const u8{
        "bug", "ben",
    };

    var backing: [16]TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(TrieBlock){
        .len = &len,
        .map = &backing,
    };

    var trie = Trie.init(blocks);
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    var walker = view.walker("b");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.trie_view.current_block, 1);
    try test_equal(walker.char_id, 1);
    try std.testing.expectEqualSlices(u8, "", walker.extension.slice());

    walker = view.walker("be");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.trie_view.current_block, 1);
    try test_equal(walker.char_id, 2);
    try std.testing.expectEqualSlices(u8, "n", walker.extension.slice());

    walker = view.walker("ben");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.trie_view.current_block, 1);
    try test_equal(walker.char_id, 3);
    try std.testing.expectEqualSlices(u8, "", walker.extension.slice());

    walker = view.walker("bu");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.trie_view.current_block, 1);
    try test_equal(walker.char_id, 2);
    try std.testing.expectEqualSlices(u8, "g", walker.extension.slice());

    walker = view.walker("bug");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.trie_view.current_block, 1);
    try test_equal(walker.char_id, 3);
    try std.testing.expectEqualSlices(u8, "", walker.extension.slice());

    walker = view.walker("ban");
    try std.testing.expect(!walker.walk_to());
}

test "insert promoting leaf to node" {
    var strings = [_][]const u8{
        "bug", "buggin",
    };

    var backing: [16]TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(TrieBlock){
        .len = &len,
        .map = &backing,
    };

    var trie = Trie.init(blocks);
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    var walker = view.walker("bug");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.char_id, 3);
    try std.testing.expectEqualSlices(u8, walker.extension.slice(), "");

    walker = view.walker("buggin");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.char_id, 6);
    try std.testing.expectEqualSlices(u8, walker.extension.slice(), "");
}

test "insert longstring" {
    var strings = [_][]const u8{
        "longlonglonglonglonglongstring",
    };

    var backing: [16]TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(TrieBlock){
        .len = &len,
        .map = &backing,
    };

    var trie = Trie.init(blocks);
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    var walker = view.walker("long");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.char_id, 4);
    try std.testing.expectEqualSlices(u8, "longlonglonglonglo", walker.extension.slice());

    walker = view.walker("longlonglonglonglonglongstring");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.char_id, 30);
    try std.testing.expectEqualSlices(u8, "", walker.extension.slice());
}

test "insert splillover" {
    var strings = [_][]const u8{
        "0a",
        "1a",
        "2a",
        "3a",
        "4a",
        "5a",
        "6a",
        "7a",
        "aa",
        "ba",
        "ca",
        "da",
        "ea",
        "fa",
        "ga",
        "ha",
    };

    var backing: [32]TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(TrieBlock){
        .len = &len,
        .map = &backing,
    };

    var trie = Trie.init(blocks);
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    var walker = view.walker("ba");
    try std.testing.expect(walker.walk_to());
    try std.testing.expectEqualSlices(u8, walker.extension.slice(), "");
}

test "iterate spillover" {
    var strings = [_][]const u8{
        "0",
        "1",
        "2",
        "3",
        "4",
        "5",
        "6",
        "7",
        "a",
        "b",
        "c",
        "d",
        "e",
        "f",
        "g",
        "h",
    };

    var backing: [32]TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(TrieBlock){
        .len = &len,
        .map = &backing,
    };

    var trie = Trie.init(blocks);
    var view = trie.to_view();

    for (strings, 0..) |s, i| {
        for (0..(i + 1)) |_| {
            try view.insert(s);
        }
    }

    var iter = ChildIterator{
        .trie = &trie,
        .block = trie.blocks.at(0),
    };

    for (strings, 0..) |s, i| {
        _ = s;
        try std.testing.expect(iter.next());
        if (i < 8) {
            try test_equal(trie.blocks.at(0), iter.block);
        } else {
            try test_equal(trie.blocks.at(trie.blocks.at(0).metadata.next), iter.block);
        }

        try test_equal(i % 8, iter.i.?);

        try std.testing.expectEqualSlices(u8, iter.block.node_data.wide.nodes[iter.i.?].slice(), strings[strings.len - i - 1]);
    }

    try std.testing.expect(!iter.next());
}

test "promote tall to wide" {
    var strings = [_][]const u8{
        "GLOBAL_aaa",
        "GLOBAL_bbb",
        "GLOBAL_ccc",
    };

    var backing: [16]TrieBlock = undefined;
    var len: usize = 0;
    var blocks = data.DumbList(TrieBlock){
        .len = &len,
        .map = &backing,
    };

    var trie = Trie.init(blocks);
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    var walker = view.walker("GLOBAL_aaa");
    try std.testing.expect(walker.walk_to());

    walker = view.walker("GLOBAL_bbb");
    try std.testing.expect(walker.walk_to());

    walker = view.walker("GLOBAL_ccc");
    try std.testing.expect(walker.walk_to());
}
