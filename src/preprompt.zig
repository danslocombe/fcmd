const std = @import("std");
const alloc = @import("alloc.zig");

pub fn build_preprompt() []const u8 {
    var cwd = std.fs.cwd();
    var buffer: [std.os.windows.PATH_MAX_WIDE * 3 + 1]u8 = undefined;
    var filename = std.os.getFdPath(cwd.fd, &buffer) catch unreachable;

    const desired_len = 40;
    var compressed = compress_path(filename, desired_len);

    var ret = std.mem.concat(alloc.gpa.allocator(), u8, &.{ compressed, ">>> " }) catch unreachable;
    return ret;
}

pub fn compress_path(path: []const u8, desired_len: usize) []const u8 {
    if (path.len < desired_len) {
        // Nothing to do.
        return path;
    }

    var buffer = alloc.temp_alloc.allocator().alloc(u8, path.len + 32) catch unreachable;

    var len = compress_half_and_half(buffer, path, copy_remove_vowels, copy_id);
    if (len < desired_len) {
        return buffer[0..len];
    }

    len = compress_half_and_half(buffer, path, copy_remove_vowels, copy_remove_vowels);
    if (len < desired_len) {
        return buffer[0..len];
    }

    len = compress_half_and_half(buffer, path, copy_first_letter, copy_remove_vowels);
    if (len < desired_len) {
        return buffer[0..len];
    }

    len = compress_half_and_half(buffer, path, copy_first_letter, copy_first_letter);
    return buffer[0..len];
}

const DestSourceIndexes = struct {
    dest_index: usize = 0,
    source_index: usize = 0,
};

pub fn compress_half_and_half(buffer: []u8, path: []const u8, comptime f0: anytype, comptime f1: anytype) usize {
    var token_count = std.mem.count(u8, path, "\\") + 1;
    var half_index = @divFloor(token_count, 2);

    var indexes = DestSourceIndexes{};
    indexes = copy_n_tokens_with_function(buffer[indexes.dest_index..], path[indexes.source_index..], f0, half_index);

    std.debug.assert(path[indexes.source_index] == '\\');
    buffer[indexes.dest_index] = '\\';
    indexes.dest_index += 1;

    var t = token_count - half_index - 1;
    var ret = copy_n_tokens_with_function(buffer[indexes.dest_index..], path[indexes.source_index..], f1, t);
    indexes.dest_index += ret.dest_index;
    indexes.source_index += ret.source_index;

    std.debug.assert(path[indexes.source_index] == '\\');
    var rest = (path.len - indexes.source_index);
    @memcpy(buffer[indexes.dest_index .. indexes.dest_index + rest], path[indexes.source_index..]);

    return indexes.dest_index + rest;
}

fn copy_n_tokens_with_function(dest: []u8, source: []const u8, comptime f: anytype, n: usize) DestSourceIndexes {
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

const vowels: []const u8 = "aeiyouAEIYOU";

fn copy_remove_vowels(dest: []u8, source: []const u8) usize {
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

fn copy_first_letter(dest: []u8, source: []const u8) usize {
    std.debug.assert(dest.len >= source.len);
    std.debug.assert(source.len > 0);

    dest[0] = source[0];

    if (source.len > 1 and source[1] == ':') {
        // Special case
        // C:\users\ -> C:\u\
        // Keep the colon
        dest[1] = source[1];
        return 2;
    } else {
        return 1;
    }
}

fn copy_id(dest: []u8, source: []const u8) usize {
    std.debug.assert(dest.len >= source.len);
    @memcpy(dest[0..source.len], source);
    return source.len;
}

test "remove vowels first half" {
    var compressed = compress_path("C:\\Useeers\\daslocom\\zcmd", 24);
    try std.testing.expectEqualSlices(u8, "C:\\Usrs\\daslocom\\zcmd", compressed);
}

test "remove all vowels" {
    var compressed = compress_path("C:\\Users\\daslocom\\baaa", 20);

    // Note we leave the final token unchanged
    try std.testing.expectEqualSlices(u8, "C:\\Usrs\\dslcm\\baaa", compressed);
}

test "single char first half" {
    var compressed = compress_path("C:\\Users\\daslocom\\baaa\\baaa", 18);

    // Note we leave the final token unchanged
    try std.testing.expectEqualSlices(u8, "C:\\U\\dslcm\\b\\baaa", compressed);
}

test "single char all" {
    var compressed = compress_path("C:\\Users\\daslocom\\baaa\\baaa", 16);

    // Note we leave the final token unchanged
    try std.testing.expectEqualSlices(u8, "C:\\U\\d\\b\\baaa", compressed);
}
