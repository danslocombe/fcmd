const std = @import("std");
const alloc = @import("alloc.zig");

const import = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("Windows.h");
});

pub usingnamespace import;

pub fn word_is_local_path(word: []const u8) bool {
    if (std.fs.path.isAbsolute(word)) {
        return false;
    }

    // @Speed don't format just directly alloc
    var wordZ = std.fmt.allocPrintZ(alloc.temp_alloc.allocator(), "{s}", .{word}) catch unreachable;
    var word_u16 = std.unicode.utf8ToUtf16LeWithNull(alloc.temp_alloc.allocator(), wordZ) catch unreachable;

    var file_attributes = import.GetFileAttributesW(word_u16);

    return file_attributes != import.INVALID_FILE_ATTRIBUTES;
}
