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

pub fn get_appdata_path() []const u8 {
    var appdata_literal = std.unicode.utf8ToUtf16LeWithNull(alloc.temp_alloc.allocator(), "APPDATA") catch unreachable;
    var buffer: [256]u16 = undefined;
    var len = import.GetEnvironmentVariableW(appdata_literal, &buffer, 256);
    return std.unicode.utf16leToUtf8Alloc(alloc.gpa.allocator(), buffer[0..len]) catch unreachable;
}
