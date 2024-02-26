const std = @import("std");
const alloc = @import("alloc.zig");

pub const SmallStr = struct {
    pub const SmallStrLen = 8;

    data: [SmallStrLen]u8 = alloc.zeroed(u8, SmallStrLen),

    pub fn from_slice(xs: []const u8) SmallStr {
        std.debug.assert(xs.len <= SmallStrLen);
        var small_str = SmallStr{};
        _ = copy_to_smallstr(&small_str, xs);
        return small_str;
    }

    pub fn slice(self: *SmallStr) []const u8 {
        return self.data[0..self.len()];
    }

    pub fn len(self: SmallStr) u8 {
        var length: usize = 0;
        while (length < SmallStrLen) : (length += 1) {
            if (self.data[length] == 0) {
                return @intCast(length);
            }
        }

        return SmallStrLen;
    }

    fn matches(xs: SmallStr, key: []const u8) bool {
        const l = @min(SmallStr.SmallStrLen, key.len);
        var i: u8 = 0;
        while (i < l) : (i += 1) {
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
        const l = @min(SmallStr.SmallStrLen, ys.len);
        var i: u8 = 0;
        while (i < l) : (i += 1) {
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
        const l = @min(SmallStr.SmallStrLen, ys.len);
        var i: u8 = 0;
        while (i < l) : (i += 1) {
            xs.data[i] = ys[i];
        }

        return @as(u8, @intCast(l));
    }
};

const TrieBlock = struct {
    const TrieChildCount = 8;

    len: u32 = 0,
    nodes: [TrieChildCount]SmallStr = alloc.defaulted(SmallStr, TrieChildCount),
    data: [TrieChildCount]u32 = alloc.zeroed(u32, TrieChildCount),
    costs: [TrieChildCount]u16 = alloc.zeroed(u16, TrieChildCount),
    node_is_leaf: [TrieChildCount]bool = alloc.trued(TrieChildCount),

    // Id of sibling trie node if we need to spill over
    // We treat 0 is invalid as 0 indicates the root node which can never be a sibling
    next: u32 = 0,

    pub fn empty() TrieBlock {
        return TrieBlock{};
    }

    pub fn get_child_size(self: TrieBlock) u8 {
        return @as(u8, @intCast(self.len));
    }

    pub fn get_child(self: TrieBlock, key: []const u8) ?struct { node_id: u8, used_chars: u8 } {
        const child_size = self.get_child_size();

        var i: u8 = 0;
        while (i < child_size) : (i += 1) {
            if (self.nodes[i].len() == 0) {
                // Special case
                // When there is a node and then a leaf below it
                // We represent that leaf as an empty string
                // We do not want to walk to that.
                continue;
            }
            if (self.nodes[i].matches(key)) {
                return .{
                    .node_id = i,
                    .used_chars = @min(key.len, self.nodes[i].len()),
                };
            }
        }

        return null;
    }

    fn insert_prefix(self: *TrieBlock, trie: *Trie, key: []const u8, cost: u16) void {
        const child_size = self.*.get_child_size();
        for (0..@intCast(child_size)) |i| {
            const common_len = self.nodes[i].common_prefix_len(key);

            if (common_len > 0) {
                var child_slice = (&self.nodes[i]).slice();
                var recurse_key: []const u8 = "";

                if (common_len == child_slice.len and !self.node_is_leaf[i]) {
                    // Exists as a node
                    // Falthrough to recurse
                    recurse_key = key[common_len..];
                } else {
                    // Split on common prefix
                    var split_first = child_slice[0..common_len];
                    var split_first_smallstring = SmallStr.from_slice(split_first);
                    var split_second = child_slice[common_len..];
                    var split_second_smallstring = SmallStr.from_slice(split_second);

                    // Create new block to hold children
                    trie.blocks.append(alloc.gpa.allocator(), TrieBlock.empty()) catch unreachable;
                    var new_block_id: u32 = @intCast(trie.blocks.len - 1);
                    var new_block = trie.blocks.at(new_block_id);
                    new_block.*.len = 1;
                    new_block.*.node_is_leaf[0] = true;
                    new_block.*.data[0] = 0;
                    new_block.*.nodes[0] = split_second_smallstring;
                    new_block.*.costs[0] = cost;

                    // Update existing node
                    self.node_is_leaf[i] = false;
                    self.data[i] = new_block_id;
                    self.nodes[i] = split_first_smallstring;
                    self.costs[i] = @min(self.costs[i], cost);

                    recurse_key = key[common_len..];
                }

                if (recurse_key.len == 0) {
                    // Nothing to do;
                    return;
                }

                var node_id = self.data[i];
                var node = trie.blocks.at(@intCast(node_id));
                return node.insert_prefix_and_sort(trie, recurse_key, cost);
            }
        }

        // No matches
        if (child_size == TrieChildCount) {
            // Couldnt find mathces in this node group, and the node group is full
            // Move to siblings.
            //
            // No sibling, need to insert one
            if (self.next == 0) {
                trie.blocks.append(alloc.gpa.allocator(), TrieBlock.empty()) catch unreachable;
                var new_node_id: u32 = @intCast(trie.blocks.len - 1);
                self.next = @intCast(new_node_id);
            }

            var next = trie.blocks.at(@intCast(self.next));

            // Note we don't call insert_prefix_and_sort here because the sorting run by the caller of this
            // method will already go through all siblings.
            return next.insert_prefix(trie, key, cost);
        } else {
            // Insert into this node
            var insert_index = child_size;

            if (key.len < SmallStr.SmallStrLen) {
                // Insert single
                self.*.len += 1;
                _ = self.nodes[insert_index].copy_to_smallstr(key);
                self.node_is_leaf[insert_index] = true;
                self.data[insert_index] = 0;
                self.costs[insert_index] = cost;
            } else {
                // Insert multiple
                self.*.len += 1;
                _ = self.nodes[insert_index].copy_to_smallstr(key[0..SmallStr.SmallStrLen]);

                trie.blocks.append(alloc.gpa.allocator(), TrieBlock.empty()) catch unreachable;
                var new_node_id: u32 = @intCast(trie.blocks.len - 1);
                var new_node = trie.blocks.at(new_node_id);

                self.node_is_leaf[insert_index] = false;
                self.data[insert_index] = new_node_id;
                self.costs[insert_index] = cost;

                new_node.insert_prefix_and_sort(trie, key[SmallStr.SmallStrLen..], cost);
            }
        }
    }

    pub fn insert_prefix_and_sort(self: *TrieBlock, trie: *Trie, key: []const u8, cost: u16) void {
        self.insert_prefix(trie, key, cost);

        if (self.get_child_size() < 2) {
            return;
        }

        // Sort children
        // Bubble sort was the easiest to implement
        // I'm so sorry
        // @Speed.
        var total_count: usize = 0;
        var i_iter = ChildIterator{ .block = self, .trie = trie };
        while (i_iter.next()) {
            total_count += 1;
        }

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

                var cost_0 = iter_0.block.costs[iter_0.i.?];
                var cost_1 = iter_1.block.costs[iter_1.i.?];

                if (cost_0 > cost_1) {
                    swapped = true;

                    var tmp_cost = iter_0.block.costs[iter_0.i.?];
                    var tmp_str = iter_0.block.nodes[iter_0.i.?];
                    var tmp_data = iter_0.block.data[iter_0.i.?];
                    var tmp_is_leaf = iter_0.block.node_is_leaf[iter_0.i.?];

                    iter_0.block.costs[iter_0.i.?] = iter_1.block.costs[iter_1.i.?];
                    iter_0.block.nodes[iter_0.i.?] = iter_1.block.nodes[iter_1.i.?];
                    iter_0.block.data[iter_0.i.?] = iter_1.block.data[iter_1.i.?];
                    iter_0.block.node_is_leaf[iter_0.i.?] = iter_1.block.node_is_leaf[iter_1.i.?];

                    iter_1.block.costs[iter_1.i.?] = tmp_cost;
                    iter_1.block.nodes[iter_1.i.?] = tmp_str;
                    iter_1.block.data[iter_1.i.?] = tmp_data;
                    iter_1.block.node_is_leaf[iter_1.i.?] = tmp_is_leaf;
                }
            }

            if (!swapped) {
                break;
            }
        }
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

        if (self.i.? == TrieBlock.TrieChildCount) {
            if (self.block.next > 0) {
                var new = self.trie.blocks.at(self.block.next);
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

pub const Trie = struct {
    blocks: std.SegmentedList(TrieBlock, 0),

    const root = 0;
    //tails : std.ArrayList([] const u8),

    pub fn to_view(self: *Trie) TrieView {
        return .{
            .trie = self,
            .current_block = root,
        };
    }

    pub fn init() Trie {
        var blocks = std.SegmentedList(TrieBlock, 0){};
        blocks.append(alloc.gpa.allocator(), TrieBlock.empty()) catch unreachable;

        return Trie{
            .blocks = blocks,
        };
    }
};

//pub const WalkResult = union(enum) {
//    NoMatch: void,
//    LeafMatch: struct { leaf_child_id: u8, chars_used: u32, hack_chars_used_in_leaf: u32 = 0 },
//    NodeMatch: struct { node_id: u32, chars_used: u32 },
//};

pub const StepResult = union(enum) {
    NoMatch: void,
    LeafMatch: struct { node_id: u8, data: u32, chars_used: u8 },
    NodeMatch: struct { node_id: u8, next_chunk_id: u32, chars_used: u8 },
};

pub const TrieWalker = struct {
    trie_view: TrieView,

    chars_within_node: u32 = 0,
    node_id: u8 = 0,
    char_id: usize = 0,

    prefix: []const u8,
    extension: SmallStr = .{},

    pub fn init(view: TrieView, prefix: []const u8) TrieWalker {
        return TrieWalker{
            .trie_view = view,
            .prefix = prefix,
        };
    }

    pub fn walk_trivial(self: *TrieWalker) void {
        _ = self;
    }

    pub fn walk_to(self: *TrieWalker) bool {
        while (true) {
            var current_prefix = self.prefix[self.char_id..];
            var current = self.trie_view.trie.blocks.at(self.trie_view.current_block);
            self.extension = .{};
            switch (self.trie_view.step_nomove(current_prefix)) {
                .NoMatch => {
                    if (current.next > 0) {
                        self.trie_view.current_block = @intCast(current.next);
                        continue;
                    } else {
                        return false;
                    }
                },
                .LeafMatch => |x| {
                    self.char_id += @intCast(x.chars_used);
                    self.node_id = x.node_id;
                    var node = current.nodes[@intCast(x.node_id)];
                    _ = self.extension.copy_to_smallstr(node.slice()[@intCast(x.chars_used)..]);
                    return true;
                },
                .NodeMatch => |x| {
                    self.char_id += @intCast(x.chars_used);
                    self.node_id = x.node_id;
                    var node = current.nodes[@intCast(x.node_id)];
                    _ = self.extension.copy_to_smallstr(node.slice()[@intCast(x.chars_used)..]);

                    self.trie_view.current_block = x.next_chunk_id;
                    if (self.char_id < self.prefix.len) {
                        continue;
                    } else {
                        return true;
                    }
                },
            }
        }
    }
};

pub const TrieView = struct {
    trie: *Trie,
    current_block: u32 = 0,

    pub fn step_nomove(self: *TrieView, prefix: []const u8) StepResult {
        var node = self.*.trie.blocks.at(self.*.current_block);
        if (node.get_child(prefix)) |child_match_info| {
            var is_leaf = node.node_is_leaf[@intCast(child_match_info.node_id)];
            var data = node.data[@intCast(child_match_info.node_id)];

            if (is_leaf) {
                return StepResult{
                    .LeafMatch = .{
                        .node_id = child_match_info.node_id,
                        .data = data,
                        .chars_used = @intCast(child_match_info.used_chars),
                    },
                };
            } else {
                return StepResult{ .NodeMatch = .{
                    .node_id = child_match_info.node_id,
                    .next_chunk_id = data,
                    .chars_used = @intCast(child_match_info.used_chars),
                } };
            }
        }

        return StepResult{
            .NoMatch = void{},
        };
    }

    pub fn insert(self: *TrieView, string: []const u8) !void {
        var node = self.*.trie.blocks.at(self.*.current_block);
        node.insert_prefix_and_sort(self.trie, string, 0);
    }

    pub fn insert_cost(self: *TrieView, string: []const u8, cost: u16) !void {
        var node = self.*.trie.blocks.at(self.*.current_block);
        node.insert_prefix_and_sort(self.trie, string, cost);
    }
};

fn test_equal(actual: anytype, expected: @TypeOf(actual)) !void {
    return std.testing.expectEqual(expected, actual);
}

//test "insert single" {
//    var strings = [_][]const u8{
//        "bug",
//    };
//
//    var trie = Trie.init();
//    var view = trie.to_view();
//
//    for (strings) |s| {
//        try view.insert(s);
//    }
//
//    try test_equal(view.current_block, 0);
//    var res = view.walk_to("bug");
//    try test_equal(res.LeafMatch, .{ .leaf_child_id = 0, .chars_used = 3 });
//}
//
//test "insert double" {
//    var strings = [_][]const u8{
//        "bug", "ben",
//    };
//
//    var trie = Trie.init();
//    var view = trie.to_view();
//
//    for (strings) |s| {
//        try view.insert(s);
//    }
//
//    view = trie.to_view();
//    var res = view.walk_to("b");
//    try test_equal(res.NodeMatch, .{ .node_id = 1, .chars_used = 1 });
//
//    view = trie.to_view();
//    res = view.walk_to("be");
//    try test_equal(res.LeafMatch, .{ .leaf_child_id = 1, .chars_used = 2 });
//
//    view = trie.to_view();
//    res = view.walk_to("ben");
//    try test_equal(res.LeafMatch, .{ .leaf_child_id = 1, .chars_used = 3 });
//
//    view = trie.to_view();
//    res = view.walk_to("bu");
//    try test_equal(res.LeafMatch, .{ .leaf_child_id = 0, .chars_used = 2 });
//
//    view = trie.to_view();
//    res = view.walk_to("bug");
//    try test_equal(res.LeafMatch, .{ .leaf_child_id = 0, .chars_used = 3 });
//}
//
//test "insert promoting leaf to node" {
//    var strings = [_][]const u8{
//        "bug", "buggin",
//    };
//
//    var trie = Trie.init();
//    var view = trie.to_view();
//
//    for (strings) |s| {
//        try view.insert(s);
//    }
//
//    view = trie.to_view();
//    var res = view.walk_to("bug");
//    try test_equal(res.NodeMatch, .{ .node_id = 1, .chars_used = 3 });
//
//    view = trie.to_view();
//    res = view.walk_to("buggin");
//    try test_equal(res.LeafMatch, .{ .leaf_child_id = 1, .chars_used = 6 });
//}
//
//test "insert longstring" {
//    var strings = [_][]const u8{
//        "longlonglongstring",
//    };
//
//    var trie = Trie.init();
//    var view = trie.to_view();
//
//    for (strings) |s| {
//        try view.insert(s);
//    }
//
//    view = trie.to_view();
//    var res = view.walk_to("long");
//    try test_equal(res.NodeMatch, .{ .node_id = 1, .chars_used = 4 });
//    try test_equal(view.current_block, 1);
//
//    view = trie.to_view();
//    res = view.walk_to("longlonglongstring");
//    try test_equal(res.LeafMatch, .{ .leaf_child_id = 0, .chars_used = 18 });
//    try test_equal(view.current_block, 2);
//}
//
//test "insert splillover" {
//    var strings = [_][]const u8{
//        "0a",
//        "1a",
//        "2a",
//        "3a",
//        "4a",
//        "5a",
//        "6a",
//        "7a",
//        "aa",
//        "ba",
//        "ca",
//        "da",
//        "ea",
//        "fa",
//        "ga",
//        "ha",
//    };
//
//    var trie = Trie.init();
//    var view = trie.to_view();
//
//    for (strings) |s| {
//        try view.insert(s);
//    }
//
//    view = trie.to_view();
//    var walker = TrieWalker.init(view, "ba");
//    var res = walker.walk_to("ba");
//    try test_equal(res, true);
//    try test_equal(res, true);
//    //try test_equal(res.LeafMatch, .{ .leaf_child_id = 1, .chars_used = 2 });
//    //try test_equal(view.current_block, 1);
//}

test "iterate spillover" {
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

    var trie = Trie.init();
    var view = trie.to_view();

    for (strings, 0..) |s, i| {
        try view.insert_cost(s, @intCast(strings.len + 1 - i));
    }

    var iter = ChildIterator{
        .trie = &trie,
        .block = trie.blocks.at(0),
    };

    for (strings, 0..) |s, i| {
        _ = s;
        try std.testing.expect(iter.next());
        if (i < TrieBlock.TrieChildCount) {
            try test_equal(trie.blocks.at(0), iter.block);
        } else {
            try test_equal(trie.blocks.at(1), iter.block);
        }

        try test_equal(i % TrieBlock.TrieChildCount, iter.i.?);

        try std.testing.expectEqualSlices(u8, iter.block.nodes[iter.i.?].slice(), strings[strings.len - i - 1]);
    }

    try std.testing.expect(!iter.next());
}
