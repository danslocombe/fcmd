const std = @import("std");
const alloc = @import("alloc.zig");
const windows = @import("windows.zig");

const lego_trie = @import("datastructures/lego_trie.zig");

const STANDARD_RIGHTS_REQUIRED = 0x000F0000;
const SECTION_QUERY: c_int = 0x0001;
const SECTION_MAP_WRITE: c_int = 0x0002;
const SECTION_MAP_READ: c_int = 0x0004;
const SECTION_MAP_EXECUTE: c_int = 0x0008;
const SECTION_EXTEND_SIZE: c_int = 0x0010;
const SECTION_MAP_EXECUTE_EXPLICIT: c_int = 0x0020;
const FILE_MAP_ALL_ACCESS = ((((STANDARD_RIGHTS_REQUIRED | SECTION_QUERY) | SECTION_MAP_WRITE) | SECTION_MAP_READ) | SECTION_MAP_EXECUTE) | SECTION_EXTEND_SIZE;

const magic_number = [_]u8{ 'f', 'r', 'o', 'g' };
const current_version: u8 = 1;

pub const BackingData = struct {
    file_handle: *anyopaque,
    map_pointer: *anyopaque,
    map_view_pointer: *anyopaque,
    map: []u8,

    trie_blocks: DumbList(lego_trie.TrieBlock),

    //allocator: MMFBackedFixedAllocator,

    pub fn init() BackingData {
        var appdata: []const u8 = windows.get_appdata_path();
        defer (alloc.gpa.allocator().free(appdata));

        var fcmd_appdata_dir = std.mem.concatWithSentinel(alloc.temp_alloc.allocator(), u8, &[_][]const u8{ appdata, "\\fcmd" }, 0) catch unreachable;
        std.fs.makeDirAbsolute(fcmd_appdata_dir) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {
                    // This is fine
                },
                else => {
                    alloc.fmt_panic("MakeDirAbsolute error when creating '{s}' {}\n", .{ fcmd_appdata_dir, err });
                },
            }
        };

        var path: [*c]const u8 = std.mem.concatWithSentinel(alloc.temp_alloc.allocator(), u8, &[_][]const u8{ fcmd_appdata_dir, "\\trie.frog" }, 0) catch unreachable;

        const GENERIC_READ = 0x80000000;
        const GENERIC_WRITE = 0x40000000;
        var file_handle: ?*anyopaque = windows.CreateFileA(path, GENERIC_READ | GENERIC_WRITE, windows.FILE_SHARE_WRITE, null, windows.OPEN_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, null);

        if (file_handle == null) {
            var last_error = windows.GetLastError();
            alloc.fmt_panic("CreateFileA: Error code {}", .{last_error});
        }

        const size = 64000;
        var map_handle = windows.CreateFileMapping(file_handle, null, windows.PAGE_READWRITE, 0, size, "trie_data");
        if (map_handle == null) {
            var last_error = windows.GetLastError();
            alloc.fmt_panic("CreateFileMapping: Error code {}", .{last_error});
        }

        var map_view = windows.MapViewOfFile(map_handle, FILE_MAP_ALL_ACCESS, 0, 0, size);

        if (map_view == null) {
            var last_error = windows.GetLastError();
            alloc.fmt_panic("MapViewOfFile: Error code {}", .{last_error});
        }

        var map = @as([*]u8, @ptrCast(map_view.?))[0..size];

        var map_magic_number = map[0..4];
        var version = &map[4];

        var trie_blocks: DumbList(lego_trie.TrieBlock) = undefined;
        trie_blocks.len = @ptrCast(@alignCast(map.ptr + 8));
        const start = 8 + @sizeOf(usize);
        var trie_block_count = @divFloor(map.len - start, @sizeOf(lego_trie.TrieBlock));
        var end = trie_block_count * @sizeOf(lego_trie.TrieBlock);
        var trieblock_bytes = map[start .. start + end];
        trie_blocks.map = @alignCast(std.mem.bytesAsSlice(lego_trie.TrieBlock, trieblock_bytes));

        if (std.mem.allEqual(u8, map_magic_number, 0)) {
            std.debug.print("Resetting state...\n", .{});
            // Empty, assume new file
            @memcpy(map_magic_number, &magic_number);
            version.* = current_version;
            //map_alloc.end_index_ptr.* = 0;
        } else if (std.mem.eql(u8, map_magic_number, &magic_number)) {
            if (version.* == current_version) {
                // All good
                std.debug.print("Loading block trie, {} blocks, {} used\n", .{ trie_block_count, trie_blocks.len.* });
            } else {
                alloc.fmt_panic("Unexpected version '{}' expected {}", .{ version.*, current_version });
            }
        } else {
            alloc.fmt_panic("Unexpected magic number on file {s} '{s}'", .{ path, map_magic_number });
        }

        return .{
            .file_handle = file_handle.?,
            .map_pointer = map_handle.?,
            .map_view_pointer = map_view.?,
            .map = map,
            //.allocator = map_alloc,
            .trie_blocks = trie_blocks,
        };
    }
};

// For now we just do the dumbest thing
pub const MMFBackedFixedAllocator = struct {
    end_index_ptr: *usize,
    map: []u8,

    pub fn allocator(self: *MMFBackedFixedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = MMFBackedFixedAllocator.alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, n: usize, log2_ptr_align: u8, ra: usize) ?[*]u8 {
        //Copypasted from std.mem.FixedBufferAllocator
        const self: *MMFBackedFixedAllocator = @ptrCast(@alignCast(ctx));
        _ = ra;
        const ptr_align = @as(usize, 1) << @as(std.mem.Allocator.Log2Align, @intCast(log2_ptr_align));
        var buffer = self.map;
        var end_index_ptr = self.end_index_ptr;
        const adjust_off = std.mem.alignPointerOffset(buffer.ptr + end_index_ptr.*, ptr_align) orelse return null;
        const adjusted_index = end_index_ptr.* + adjust_off;
        const new_end_index = adjusted_index + n;
        if (new_end_index > buffer.len) return null;
        end_index_ptr.* = new_end_index;
        return buffer.ptr + adjusted_index;
    }

    fn resize(
        ctx: *anyopaque,
        buf: []u8,
        log2_buf_align: u8,
        new_size: usize,
        return_address: usize,
    ) bool {
        _ = return_address;
        _ = new_size;
        _ = log2_buf_align;
        _ = buf;
        _ = ctx;
        @panic("unimplemented");
    }

    fn free(
        ctx: *anyopaque,
        buf: []u8,
        log2_buf_align: u8,
        return_address: usize,
    ) void {
        _ = return_address;
        _ = log2_buf_align;
        _ = buf;
        _ = ctx;

        // Do nothing
        // We could do something if the alloc passed is the last alloc
        // But we don't
    }
};

pub fn DumbList(comptime T: type) type {
    return struct {
        const Self = @This();

        len: *usize,
        map: []T,

        pub fn append(self: *const Self, x: T) void {
            self.map[self.len.*] = x;
            self.len.* += 1;
        }

        pub fn at(self: *const Self, i: usize) *T {
            std.debug.assert(i < self.len.*);
            return &self.map[i];
        }
    };
}
