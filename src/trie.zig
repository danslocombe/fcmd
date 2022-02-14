const std = @import("std");

pub const CHUNK_SIZE : usize = 64;

pub const TrieChunk = struct
{
    data : []u8,
};

// Layout
//
// u8 nonleaf sibling count
// u8 leaf sibling count
// next sibling chunk
//
// For each sibling
//     u8 first utf8 char
// 
// For each sibiling
//     metadata
//
// For each nonleaf sibling
//     u8 char len
//     more characters
//     Next chunk id
// For each child sibling
//     u8 char len
//     more characters
//     leaf offset

pub fn create_chunk(allocator : std.mem.Allocator, strings : [][]const u8) !TrieChunk {
    var chunk = try allocator.alloc(u8, CHUNK_SIZE);
    try fill_chunk(chunk, strings);

    return TrieChunk{ .data = chunk };
}

fn fill_chunk(chunk : []u8, strings : []const []const u8) !void {
    // Assume all strings have len > 0

    var writer = std.heap.FixedBufferAllocator.init(chunk).allocator();
    const nonleaf_count = 0;
    const leaf_count = strings.len;

    (try writer.alloc(u8, 1)).ptr.* = @intCast(u8, nonleaf_count);
    (try writer.alloc(u8, 1)).ptr.* = @intCast(u8, leaf_count);

    for (strings) |s|
    {
        (try writer.alloc(u8, 1)).ptr.* = s[0];
    }

    for (strings) |s|
    {
        const rest_size = s.len - 1;
        (try writer.alloc(u8, 1)).ptr.* = @intCast(u8, rest_size);
        if (s.len > 1) 
        {
            var alloced = try writer.alloc(u8, rest_size);
            std.mem.copy(u8, alloced, s[1..]);
        }
    }

    var i : u32 = 0; 
    while (i < strings.len) : (i += 1) {
        (try writer.alloc(u32, 1)).ptr.* = i;
    }
}