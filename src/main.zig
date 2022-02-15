const std = @import("std");
const trie = @import("trie.zig");
const simple_trie = @import("simple_trie.zig");

pub fn main() anyerror!void {
    //std.log.info("All your codebase are belong to us.", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var strings = [_][] const u8 {
        "bug",
        "fly",
        "coffee",
        "daniel"
    };

    std.log.info("Hello", .{});

    std.mem.doNotOptimizeAway(strings);

    std.log.info("\n\nBuilding", .{});

    var demo_trie = try simple_trie.Trie.init(gpa.allocator());
    var view = demo_trie.to_view();
    try view.insert("bug");


    std.log.info("\n\nQuerying", .{});

    var res = view.walk_to("bu");

    std.log.info("{}", .{res});

    std.mem.doNotOptimizeAway(view);
    std.mem.doNotOptimizeAway(res);

    //var builder = trie.ZoomTrieBuilder.init(gpa.allocator());
    //defer(builder.deinit());

    //for (strings) |s| {
    //    std.log.info("Adding observation {}", .{s});
    //    builder.add_observation(s);
    //}

    //var demo_trie = try builder.build();
    //demo_trie.dump(gpa.allocator());

    //var chunk = try trie.create_chunk(gpa.allocator(), strings[0..strings.len]);
    //try std.fs.cwd().writeFile("test.chunk", chunk.data);
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
