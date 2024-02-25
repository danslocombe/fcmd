const std = @import("std");
const alloc = @import("alloc.zig");

pub const SmallStr = struct {
    const SmallStrLen = 8;

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

const TrieNode = struct {
    const TrieChildCount = 8;

    metadata: u32 = 0,
    children: [TrieChildCount]SmallStr = alloc.defaulted(SmallStr, TrieChildCount),
    data: [TrieChildCount]u32 = alloc.zeroed(u32, TrieChildCount),
    child_is_leaf: [TrieChildCount]bool = alloc.trued(TrieChildCount),

    // Id of sibling trie node if we need to spill over
    next: i32 = -1,

    pub fn empty() TrieNode {
        return TrieNode{};
    }

    pub fn get_child_size(self: TrieNode) u8 {
        return @as(u8, @intCast(self.metadata));
    }

    pub fn get_child(self: TrieNode, key: []const u8) ?struct { child_id: u8, used_chars: u8 } {
        const child_size = self.get_child_size();
        std.log.info("Getting child - child count {d}", .{child_size});

        var i: u8 = 0;
        while (i < child_size) : (i += 1) {
            if (self.children[i].len() == 0) {
                // Special case
                // When there is a node and then a leaf below it
                // We represent that leaf as an empty string
                // We do not want to walk to that.
                continue;
            }
            if (self.children[i].matches(key)) {
                return .{
                    .child_id = i,
                    .used_chars = @min(key.len, self.children[i].len()),
                };
            }
        }

        return null;
    }

    pub fn insert_prefix(self: *TrieNode, trie: *Trie, key: []const u8) void {
        for (0..@intCast(self.get_child_size())) |i| {
            const common_len = self.children[i].common_prefix_len(key);

            if (common_len > 0) {
                var child_slice = (&self.children[i]).slice();
                var recurse_key: []const u8 = "";

                if (common_len == child_slice.len and !self.child_is_leaf[i]) {
                    // Exists as a node
                    // Falthrough to recurse
                    recurse_key = key[common_len..];
                } else {
                    // Split on common prefix
                    std.log.info("Partial match on child {s}, splitting...", .{child_slice});

                    var split_first = child_slice[0..common_len];
                    var split_first_smallstring = SmallStr.from_slice(split_first);
                    var split_second = child_slice[common_len..];
                    var split_second_smallstring = SmallStr.from_slice(split_second);

                    // Create new node
                    // Careful as this can invalidate any pointers to children[i] (hence why we make the copies above)
                    trie.nodes.append(TrieNode.empty()) catch unreachable;
                    var new_node_id: u32 = @intCast(trie.nodes.items.len - 1);
                    var new_node = &trie.nodes.items[new_node_id];
                    new_node.*.metadata = 1;
                    new_node.*.child_is_leaf[0] = true;
                    new_node.*.data[0] = 0;
                    new_node.*.children[0] = split_second_smallstring;

                    // Update existing node
                    self.child_is_leaf[i] = false;
                    self.data[i] = new_node_id;
                    self.children[i] = split_first_smallstring;

                    recurse_key = key[common_len..];
                }

                if (recurse_key.len == 0) {
                    // Nothing to do;
                    return;
                }

                std.log.info("Recursing", .{});
                var node_id = self.data[i];
                var node = &trie.nodes.items[@intCast(node_id)];
                return node.insert_prefix(trie, recurse_key);
            }
        }

        // No matches
        const child_size = self.*.get_child_size();

        if (child_size == TrieChildCount) {
            // Couldnt find mathces in this node group, and the node group is full
            // Move to siblings.

            // No sibling, need to insert one
            if (self.next < 0) {
                trie.nodes.append(TrieNode.empty()) catch unreachable;
                var new_node_id: u32 = @intCast(trie.nodes.items.len - 1);
                self.next = @intCast(new_node_id);
            }

            var next = &trie.nodes.items[@intCast(self.next)];
            return next.insert_prefix(trie, key);
        } else {
            // Insert into this node
            if (key.len < SmallStr.SmallStrLen) {
                // Insert single
                self.*.metadata += 1;
                _ = self.children[child_size].copy_to_smallstr(key);
                self.child_is_leaf[child_size] = true;
                self.data[child_size] = 0;
            } else {
                // Insert multiple
                self.*.metadata += 1;
                _ = self.children[child_size].copy_to_smallstr(key[0..SmallStr.SmallStrLen]);

                trie.nodes.append(TrieNode.empty()) catch unreachable;
                var new_node_id: u32 = @intCast(trie.nodes.items.len - 1);
                var new_node = &trie.nodes.items[new_node_id];

                self.child_is_leaf[child_size] = false;
                self.data[child_size] = new_node_id;

                new_node.insert_prefix(trie, key[SmallStr.SmallStrLen..]);
            }
        }
    }
};

pub const Trie = struct {
    root: u32,
    nodes: std.ArrayList(TrieNode),
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
        };

        try trie.nodes.append(TrieNode.empty());

        return trie;
    }
};

pub const WalkResult = union(enum) {
    NoMatch: void,
    LeafMatch: struct { leaf_child_id: u8, chars_used: u32 },
    NodeMatch: struct { node_id: u32, chars_used: u32 },
};

pub const TrieView = struct {
    trie: *Trie,
    current_node: u32,

    pub fn walk_to(self: *TrieView, prefix: []const u8) WalkResult {
        var i: usize = 0;
        while (true) {
            var current_prefix = prefix[i..];
            switch (self.step_nomove(current_prefix)) {
                .NoMatch => {
                    var current = self.trie.nodes.items[self.current_node];
                    if (current.next >= 0) {
                        self.current_node = @intCast(current.next);
                        continue;
                    } else {
                        return .{ .NoMatch = void{} };
                    }
                },
                .LeafMatch => |x| {
                    i += @intCast(x.chars_used);
                    return .{
                        .LeafMatch = .{
                            .leaf_child_id = x.leaf_child_id,
                            .chars_used = @intCast(i),
                        },
                    };
                },
                .NodeMatch => |x| {
                    self.current_node = x.node_id;
                    i += @intCast(x.chars_used);
                    if (i < prefix.len) {
                        continue;
                    } else {
                        return .{
                            .NodeMatch = .{
                                .node_id = self.current_node,
                                .chars_used = @intCast(i),
                            },
                        };
                    }
                },
            }
        }
    }

    pub fn step_nomove(self: *TrieView, prefix: []const u8) WalkResult {
        var node = self.*.trie.nodes.items[self.*.current_node];
        if (node.get_child(prefix)) |child_match_info| {
            var is_leaf = node.child_is_leaf[@intCast(child_match_info.child_id)];
            var data = node.data[@intCast(child_match_info.child_id)];

            if (is_leaf) {
                return WalkResult{
                    .LeafMatch = .{
                        .leaf_child_id = child_match_info.child_id,
                        .chars_used = @intCast(child_match_info.used_chars),
                    },
                };
            } else {
                return WalkResult{ .NodeMatch = .{
                    .node_id = data,
                    .chars_used = @intCast(child_match_info.used_chars),
                } };
            }
        }

        return WalkResult{
            .NoMatch = void{},
        };
    }

    pub fn insert(self: *TrieView, string: []const u8) !void {
        var node = &self.*.trie.nodes.items[self.*.current_node];
        node.insert_prefix(self.trie, string);
    }
};

fn test_equal(actual: anytype, expected: @TypeOf(actual)) !void {
    return std.testing.expectEqual(expected, actual);
}

test "insert single" {
    var strings = [_][]const u8{
        "bug",
    };

    var trie = Trie.init(alloc.gpa.allocator()) catch unreachable;
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    try test_equal(view.current_node, 0);
    var res = view.walk_to("bug");
    try test_equal(res.LeafMatch, .{ .leaf_child_id = 0, .chars_used = 3 });
}

test "insert double" {
    var strings = [_][]const u8{
        "bug", "ben",
    };

    var trie = Trie.init(alloc.gpa.allocator()) catch unreachable;
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    view = trie.to_view();
    var res = view.walk_to("b");
    try test_equal(res.NodeMatch, .{ .node_id = 1, .chars_used = 1 });

    view = trie.to_view();
    res = view.walk_to("be");
    try test_equal(res.LeafMatch, .{ .leaf_child_id = 1, .chars_used = 2 });

    view = trie.to_view();
    res = view.walk_to("ben");
    try test_equal(res.LeafMatch, .{ .leaf_child_id = 1, .chars_used = 3 });

    view = trie.to_view();
    res = view.walk_to("bu");
    try test_equal(res.LeafMatch, .{ .leaf_child_id = 0, .chars_used = 2 });

    view = trie.to_view();
    res = view.walk_to("bug");
    try test_equal(res.LeafMatch, .{ .leaf_child_id = 0, .chars_used = 3 });
}

test "insert promoting leaf to node" {
    var strings = [_][]const u8{
        "bug", "buggin",
    };

    var trie = Trie.init(alloc.gpa.allocator()) catch unreachable;
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    view = trie.to_view();
    var res = view.walk_to("bug");
    try test_equal(res.NodeMatch, .{ .node_id = 1, .chars_used = 3 });

    view = trie.to_view();
    res = view.walk_to("buggin");
    try test_equal(res.LeafMatch, .{ .leaf_child_id = 1, .chars_used = 6 });
}

test "insert longstring" {
    var strings = [_][]const u8{
        "longlonglongstring",
    };

    var trie = Trie.init(alloc.gpa.allocator()) catch unreachable;
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    view = trie.to_view();
    var res = view.walk_to("longlonglongstring");
    try test_equal(res.LeafMatch, .{ .leaf_child_id = 0, .chars_used = 18 });
    try test_equal(view.current_node, 2);
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

    var trie = Trie.init(alloc.gpa.allocator()) catch unreachable;
    var view = trie.to_view();

    for (strings) |s| {
        try view.insert(s);
    }

    view = trie.to_view();
    var res = view.walk_to("ba");
    try test_equal(res.LeafMatch, .{ .leaf_child_id = 1, .chars_used = 2 });
    try test_equal(view.current_node, 1);
}
