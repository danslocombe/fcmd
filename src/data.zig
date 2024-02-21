const std = @import("std");
const alloc = @import("alloc.zig");
const windows = @import("windows.zig");

const STANDARD_RIGHTS_REQUIRED = 0x000F0000;
const SECTION_QUERY = @as(c_int, 0x0001);
const SECTION_MAP_WRITE = @as(c_int, 0x0002);
const SECTION_MAP_READ = @as(c_int, 0x0004);
const SECTION_MAP_EXECUTE = @as(c_int, 0x0008);
const SECTION_EXTEND_SIZE = @as(c_int, 0x0010);
const SECTION_MAP_EXECUTE_EXPLICIT = @as(c_int, 0x0020);
const FILE_MAP_ALL_ACCESS = ((((STANDARD_RIGHTS_REQUIRED | SECTION_QUERY) | SECTION_MAP_WRITE) | SECTION_MAP_READ) | SECTION_MAP_EXECUTE) | SECTION_EXTEND_SIZE;

pub const BackingData = struct {
    file_handle: *anyopaque,
    map_pointer: *anyopaque,
    map_view_pointer: *anyopaque,
    map: []u8,

    pub fn init() BackingData {
        const path = "v0.fcmd_data";
        const GENERIC_READ = 0x80000000;
        const GENERIC_WRITE = 0x40000000;
        var file_handle: ?*anyopaque = windows.CreateFileA(path, GENERIC_READ | GENERIC_WRITE, windows.FILE_SHARE_WRITE, null, windows.OPEN_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, null);

        if (file_handle == null) {
            var last_error = windows.GetLastError();
            alloc.fmt_panic("CreateFileA: Error code {}", .{last_error});
        }

        const size = 64000;
        //var map_handle = windows.CreateFileMapping(file_handle, null, windows.PAGE_READWRITE, 0, size, "Global\\Blahhh");
        var map_handle = windows.CreateFileMapping(file_handle, null, windows.PAGE_READWRITE, 0, size, "Blahhh");
        if (map_handle == null) {
            var last_error = windows.GetLastError();
            alloc.fmt_panic("CreateFileMapping: Error code {}", .{last_error});
        }

        var map_view = windows.MapViewOfFile(map_handle, FILE_MAP_ALL_ACCESS, 0, 0, size);

        if (map_view == null) {
            var last_error = windows.GetLastError();
            alloc.fmt_panic("MapViewOfFile: Error code {}", .{last_error});
        }

        //var map = .{ .ptr = @as(*u8, @ptrCast(map_view.?)), .len = size };
        var map = @as([*]u8, @ptrCast(map_view.?))[0..size];

        map[0] = 0x01;

        return .{
            .file_handle = file_handle.?,
            .map_pointer = map_handle.?,
            .map_view_pointer = map_view.?,
            .map = map,
        };
    }
};
