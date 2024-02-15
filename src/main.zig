const std = @import("std");
const trie = @import("trie.zig");
const simple_trie = @import("simple_trie.zig");

const alloc = @import("alloc.zig");
const shell = @import("shell");

const windows = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("Windows.h");
});

pub fn main() !void {
    var h_stdin = windows.GetStdHandle(windows.STD_INPUT_HANDLE);
    if (h_stdin == null) {
        @panic("Failed to get stdin");
    }

    var buffer: [128]windows.INPUT_RECORD = undefined;
    var records_read: u32 = 0;
    while (windows.ReadConsoleInputA(h_stdin, &buffer, 128, &records_read) != 0) {
        for (0..@intCast(records_read)) |i| {
            var record = buffer[i];
            if (record.EventType == windows.KEY_EVENT) {
                // C:.Users.daslocom.zcmd.zig-cache.o.af2e8ff273267e902e5ad2dc82c0ab12.cimport.struct__KEY_EVENT_RECORD{ .bKeyDown = 0, .wRepeatCount = 1, .wVirtualKeyCode = 65, .wVirtualScanCode = 30, .uChar = C:.Users.daslocom.zcmd.zig-cache.o.af2e8ff273267e902e5ad2dc82c0ab12.cimport.union_unnamed_171@5c4abfe6a8, .dwControlKeyState = 32 }
                std.debug.print("{}\n", .{record.Event.KeyEvent});
            }
        }
    }
}

pub fn main_old() anyerror!void {
    //std.log.info("All your codebase are belong to us.", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var strings = [_][]const u8{ "bug", "fly", "coffee", "daniel" };

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
