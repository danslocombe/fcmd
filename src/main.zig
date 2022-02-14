const std = @import("std");
const trie = @import("trie.zig");

pub fn main() anyerror!void {
    //std.log.info("All your codebase are belong to us.", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var strings = [_][] const u8 {
        "bug",
        "fly",
        "coffee",
        "daniel"
    };

    std.log.info("Hello");

    var builder = trie.ZoomTrieBuilder.init(gpa.allocator());
    defer(builder.deinit());

    for (strings) |s| {
        std.log.info("Adding observation {}", .{s});
        builder.add_observation(s);
    }

    var demo_trie = try builder.build();
    demo_trie.dump(gpa.allocator());

    //var chunk = try trie.create_chunk(gpa.allocator(), strings[0..strings.len]);
    //try std.fs.cwd().writeFile("test.chunk", chunk.data);
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
