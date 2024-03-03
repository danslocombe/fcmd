const std = @import("std");
const alloc = @import("alloc.zig");
const data_lib = @import("data.zig");

pub const SmallStrLen = 8;

pub fn InlineString(comptime N: usize) type {
    return struct {
        const Self = @This();
        data: [N]u8 = alloc.zeroed(u8, N),

        pub fn from_slice(xs: []const u8) Self {
            std.debug.assert(xs.len <= N);
            var small_str = Self{};
            _ = copy_to_smallstr(&small_str, xs);
            return small_str;
        }

        pub fn slice(self: *Self) []const u8 {
            return self.data[0..self.len()];
        }

        pub fn len(self: Self) u8 {
            var length: usize = 0;
            while (length < N) : (length += 1) {
                if (self.data[length] == 0) {
                    return @intCast(length);
                }
            }

            return N;
        }

        fn matches(xs: Self, key: []const u8) bool {
            const l = @min(N, key.len);
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

        fn common_prefix_len(xs: Self, ys: []const u8) u8 {
            const l = @min(N, ys.len);
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

            return l;
        }

        fn copy_to_smallstr(xs: *Self, ys: []const u8) u8 {
            const l = @min(N, ys.len);
            var i: u8 = 0;
            while (i < l) : (i += 1) {
                xs.data[i] = ys[i];
            }

            return @as(u8, @intCast(l));
        }
    };
}

pub const TrieBlock = struct {
    const TrieChildCount = 8;
    const BaseCost = 1000;

    len: u32 = 0,
    nodes: [TrieChildCount]InlineString(SmallStrLen) = alloc.defaulted(InlineString(SmallStrLen), TrieChildCount),
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

    fn insert_prefix(self: *TrieBlock, trie: *Trie, key: []const u8) void {
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
                    self.costs[i] -|= 1;
                } else {
                    // Split on common prefix
                    var split_first = child_slice[0..common_len];
                    var split_first_smallstring = InlineString(SmallStrLen).from_slice(split_first);
                    var split_second = child_slice[common_len..];
                    var split_second_smallstring = InlineString(SmallStrLen).from_slice(split_second);

                    // Create new block to hold children
                    trie.blocks.append(TrieBlock.empty());
                    var new_block_id: u32 = @intCast(trie.blocks.len.* - 1);
                    var new_block = trie.blocks.at(new_block_id);
                    new_block.*.len = 1;
                    new_block.*.node_is_leaf[0] = self.node_is_leaf[i];
                    new_block.*.data[0] = self.data[i];
                    new_block.*.nodes[0] = split_second_smallstring;
                    new_block.*.costs[0] = self.costs[i];

                    // Update existing node
                    self.node_is_leaf[i] = false;
                    self.data[i] = new_block_id;
                    self.nodes[i] = split_first_smallstring;
                    self.costs[i] -|= 1;

                    recurse_key = key[common_len..];
                }

                if (recurse_key.len == 0) {
                    // Nothing to do;
                    return;
                }

                var node_id = self.data[i];
                var node = trie.blocks.at(@intCast(node_id));
                return node.insert_prefix_and_sort(trie, recurse_key);
            }
        }

        // No matches
        if (child_size == TrieChildCount) {
            // Couldnt find mathces in this node group, and the node group is full
            // Move to siblings.
            //
            // No sibling, need to insert one
            if (self.next == 0) {
                trie.blocks.append(TrieBlock.empty());
                var new_node_id: u32 = @intCast(trie.blocks.len.* - 1);
                self.next = @intCast(new_node_id);
            }

            var next = trie.blocks.at(@intCast(self.next));

            // Note we don't call insert_prefix_and_sort here because the sorting run by the caller of this
            // method will already go through all siblings.
            return next.insert_prefix(trie, key);
        } else {
            // Insert into this node
            var insert_index = child_size;

            if (key.len < SmallStrLen) {
                // Insert single
                self.*.len += 1;
                _ = self.nodes[insert_index].copy_to_smallstr(key);
                self.node_is_leaf[insert_index] = true;
                self.data[insert_index] = 0;
                self.costs[insert_index] = BaseCost;
            } else {
                // Insert multiple
                self.*.len += 1;
                _ = self.nodes[insert_index].copy_to_smallstr(key[0..SmallStrLen]);

                trie.blocks.append(TrieBlock.empty());
                var new_node_id: u32 = @intCast(trie.blocks.len.* - 1);
                var new_node = trie.blocks.at(new_node_id);

                self.node_is_leaf[insert_index] = false;
                self.data[insert_index] = new_node_id;
                self.costs[insert_index] = BaseCost;

                new_node.insert_prefix_and_sort(trie, key[SmallStrLen..]);
            }
        }
    }

    pub fn insert_prefix_and_sort(self: *TrieBlock, trie: *Trie, key: []const u8) void {
        self.insert_prefix(trie, key);

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

                // Use >= instead of > to prefer recent insertions
                if (cost_0 >= cost_1) {
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
            trie_blocks.append(TrieBlock.empty());
        }

        return Trie{
            .blocks = trie_blocks,
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

    char_id: usize = 0,
    cost: u16 = 0,

    reached_leaf: bool = false,

    prefix: []const u8,
    extension: InlineString(SmallStrLen) = .{},

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

            components.append(current.nodes[0].slice()) catch unreachable;

            if (current.node_is_leaf[0]) {
                break;
            }

            self.trie_view.current_block = current.data[0];
        }

        return std.mem.concat(allocator, u8, components.items) catch unreachable;
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
                    var node = current.nodes[@intCast(x.node_id)];
                    _ = self.extension.copy_to_smallstr(node.slice()[@intCast(x.chars_used)..]);
                    self.cost = current.costs[@intCast(x.node_id)];
                    self.reached_leaf = true;
                    return true;
                },
                .NodeMatch => |x| {
                    self.char_id += @intCast(x.chars_used);
                    var node = current.nodes[@intCast(x.node_id)];
                    _ = self.extension.copy_to_smallstr(node.slice()[@intCast(x.chars_used)..]);
                    self.cost = current.costs[@intCast(x.node_id)];

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
        var node = self.trie.blocks.at(@intCast(self.*.current_block));
        node.insert_prefix_and_sort(self.trie, string);
    }

    pub fn walker(self: TrieView, prefix: []const u8) TrieWalker {
        return TrieWalker{
            .trie_view = self,
            .prefix = prefix,
        };
    }
};

fn test_equal(actual: anytype, expected: @TypeOf(actual)) !void {
    return std.testing.expectEqual(expected, actual);
}

test "insert single" {
    var strings = [_][]const u8{
        "bug",
    };

    var trie = Trie.init();
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    try test_equal(view.current_block, 0);
    var walker = view.walker("bug");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.char_id, 3);
    try test_equal(walker.node_id, 0);
}

test "insert double" {
    var strings = [_][]const u8{
        "bug", "ben",
    };

    var trie = Trie.init();
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    var walker = view.walker("b");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.trie_view.current_block, 1);
    try test_equal(walker.char_id, 1);
    try std.testing.expectEqualSlices(u8, walker.extension.slice(), "");

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

    var trie = Trie.init();
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    var walker = view.walker("bug");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.trie_view.current_block, 1);
    try test_equal(walker.char_id, 3);
    try std.testing.expectEqualSlices(u8, walker.extension.slice(), "");

    walker = view.walker("buggin");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.trie_view.current_block, 1);
    try test_equal(walker.node_id, 1);
    try test_equal(walker.char_id, 6);
    try std.testing.expectEqualSlices(u8, walker.extension.slice(), "");
}

test "insert longstring" {
    var strings = [_][]const u8{
        "longlonglongstring",
    };

    var trie = Trie.init();
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    var walker = view.walker("long");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.trie_view.current_block, 1);
    try test_equal(walker.char_id, 4);
    try std.testing.expectEqualSlices(u8, walker.extension.slice(), "long");

    walker = view.walker("longlonglongstring");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.trie_view.current_block, 2);
    try test_equal(walker.node_id, 0);
    try test_equal(walker.char_id, 18);
    try std.testing.expectEqualSlices(u8, walker.extension.slice(), "");
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

    var trie = Trie.init();
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    var walker = view.walker("ba");
    try std.testing.expect(walker.walk_to());
    try test_equal(walker.trie_view.current_block, 1);
    try test_equal(walker.node_id, 1);
    try std.testing.expectEqualSlices(u8, walker.extension.slice(), "");
}

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
        if (i < TrieBlock.TrieChildCount) {
            try test_equal(trie.blocks.at(0), iter.block);
        } else {
            try test_equal(trie.blocks.at(trie.blocks.at(0).next), iter.block);
        }

        try test_equal(i % TrieBlock.TrieChildCount, iter.i.?);

        try std.testing.expectEqualSlices(u8, iter.block.nodes[iter.i.?].slice(), strings[strings.len - i - 1]);
    }

    try std.testing.expect(!iter.next());
}
