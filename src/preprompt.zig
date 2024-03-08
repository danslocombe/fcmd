const std = @import("std");
const alloc = @import("alloc.zig");

pub fn copy_n_tokens_with_function(dest: []u8, source: []const u8, comptime f: anytype, n: usize) struct { dest_index: usize, source_index: usize } {
    var dest_index: usize = 0;
    var split_iter = std.mem.tokenize(u8, source, "\\");
    for (0..n) |i| {
        if (i != 0) {
            dest[dest_index] = '\\';
            dest_index += 1;
        }

        if (split_iter.next()) |x| {
            dest_index += f(dest[dest_index..], x);
        } else {
            break;
        }
    }

    return .{ .dest_index = dest_index, .source_index = split_iter.index };
}

pub fn compress_path(path: []const u8, desired_len: usize) []const u8 {
    if (path.len < desired_len) {
        // Nothing to do.
        return path;
    }

    var buffer = alloc.temp_alloc.allocator().alloc(u8, path.len + 32) catch unreachable;
    //var buffer_len = path.len;

    var split_count = std.mem.count(u8, path, "\\") + 1;
    var half_index = @divFloor(split_count, 2);

    var buffer_index: usize = 0;
    var source_index: usize = 0;
    var ret = copy_n_tokens_with_function(buffer[buffer_index..], path[source_index..], copy_remove_vowels, half_index);
    buffer_index += ret.dest_index;
    source_index += ret.source_index;

    buffer[buffer_index] = '\\';
    buffer_index += 1;

    var ret2 = copy_n_tokens_with_function(buffer[buffer_index..], path[source_index..], copy_id, half_index);
    buffer_index += ret2.dest_index;
    source_index += ret2.source_index;

    //var buffer_index: usize = 0;
    //var split_iter = std.mem.tokenize(u8, path, "\\");
    //for (0..half_index) |i| {
    //    if (i != 0) {
    //        buffer[buffer_index] = '\\';
    //        buffer_index += 1;
    //    }

    //    var x = split_iter.next().?;
    //    buffer_index += copy_remove_vowels(buffer[buffer_index..], x);
    //}

    //while (split_iter.next()) |x| {
    //    buffer[buffer_index] = '\\';
    //    buffer_index += 1;

    //    @memcpy(buffer[buffer_index..(buffer_index + x.len)], x);
    //    buffer_index += x.len;
    //}

    return buffer[0..buffer_index];
}

pub fn build_preprompt() []const u8 {
    var cwd = std.fs.cwd();
    var buffer: [std.os.windows.PATH_MAX_WIDE * 3 + 1]u8 = undefined;
    var filename = std.os.getFdPath(cwd.fd, &buffer) catch unreachable;

    const desired_len = 25;
    var compressed = compress_path(filename, desired_len);

    var ret = std.mem.concat(alloc.gpa.allocator(), u8, &.{ compressed, ">>> " }) catch unreachable;
    return ret;
}

const vowels: []const u8 = "aeiyouAEIYOU";

pub fn copy_remove_vowels(dest: []u8, source: []const u8) usize {
    std.debug.assert(dest.len >= source.len);

    var write_index: usize = 0;
    outer: for (0..source.len) |i| {
        if (i > 0) {
            for (vowels) |v| {
                if (source[i] == v) {
                    continue :outer;
                }
            }
        }

        dest[write_index] = source[i];
        write_index += 1;
    }

    return write_index;
}

pub fn copy_id(dest: []u8, source: []const u8) usize {
    std.debug.assert(dest.len >= source.len);
    @memcpy(dest[0..source.len], source);
    return source.len;
}

test "compress path remove vowels first half" {
    var compressed = compress_path("C:\\Users\\daslocom\\zcmd", 10);
    try std.testing.expectEqualSlices(u8, "C:\\Usrs\\daslocom\\zcmd", compressed);
}
