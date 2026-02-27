const std = @import("std");
const alloc = @import("alloc.zig");
const windows = @import("windows.zig");
const log = @import("log.zig");

const lego_trie = @import("datastructures/lego_trie.zig");

const STANDARD_RIGHTS_REQUIRED = 0x000F0000;
const SECTION_QUERY: c_int = 0x0001;
const SECTION_MAP_WRITE: c_int = 0x0002;
const SECTION_MAP_READ: c_int = 0x0004;
const SECTION_MAP_EXECUTE: c_int = 0x0008;
const SECTION_EXTEND_SIZE: c_int = 0x0010;
const SECTION_MAP_EXECUTE_EXPLICIT: c_int = 0x0020;
const FILE_MAP_ALL_ACCESS = ((((STANDARD_RIGHTS_REQUIRED | SECTION_QUERY) | SECTION_MAP_WRITE) | SECTION_MAP_READ) | SECTION_MAP_EXECUTE) | SECTION_EXTEND_SIZE;
const INFINITE = 0xFFFFFFFF;

const magic_number = [_]u8{ 'f', 'r', 'o', 'g' };
const current_version: u8 = 3;

const write_mutex_name: [:0]const u8 = "Local\\fcmd_trie_write_mutex";

// Fixed 16MB mapping size. Windows only commits physical pages for data actually
// written, so this costs nothing upfront. Eliminates all cross-process resize coordination.
const fixed_map_size = 16 * 1024 * 1024;

// Alias for backward compatibility and clarity
pub const GlobalContext = MMapContext;

pub const MMapContext = struct {
    /// Named mutex that serializes all trie writes across processes.
    write_mutex: *anyopaque = undefined,

    filepath: [*c]const u8 = "",

    backing_data: BackingData = undefined,
};

pub const BackingData = struct {
    file_handle: ?*anyopaque,
    map_pointer: ?*anyopaque,
    map_view_pointer: *anyopaque,
    map: []u8,

    trie_blocks: MappedArray(lego_trie.TrieBlock),
    size_in_bytes_ptr: *std.atomic.Value(i32),

    pub fn init(state_dir: []const u8, context: *MMapContext) void {
        std.Io.Dir.createDirPath(std.Io.Dir.cwd(), alloc.g_io, state_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                alloc.fmt_panic("createDirPath error when creating '{s}' {}\n", .{ state_dir, err });
            }
        };

        const filepath = std.mem.concatWithSentinel(alloc.gpa.allocator(), u8, &[_][]const u8{ state_dir, "\\trie.frog" }, 0) catch unreachable;

        const result = init_internal(filepath, context) catch |err| {
            alloc.fmt_panic("Failed to initialize BackingData: {}", .{err});
        };

        context.backing_data = result;
    }

    /// Internal initialization function that handles the actual file mapping and sync object creation
    fn init_internal(filepath: [*c]const u8, mmap_context: *MMapContext) !BackingData {
        log.log_debug("Initializing BackingData for: {s}\n", .{filepath});

        // Create named write mutex — serializes all trie writes across processes.
        const write_mutex = windows.CreateMutexA(null, 0, write_mutex_name);
        if (write_mutex == null) {
            const last_error = windows.GetLastError();
            log.log_debug("Failed to create write mutex, Error {}\n", .{last_error});
            return error.CannotCreateWriteMutex;
        }
        mmap_context.write_mutex = write_mutex.?;

        // Open or create the file
        const GENERIC_READ = 0x80000000;
        const GENERIC_WRITE = 0x40000000;
        const file_handle: ?*anyopaque = windows.CreateFileA(filepath, GENERIC_READ | GENERIC_WRITE, windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE, null, windows.OPEN_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, null);

        if (file_handle == null) {
            const last_error = windows.GetLastError();
            log.log_debug("CreateFileA failed: Error code {}\n", .{last_error});
            return error.CannotOpenFile;
        }

        const size = fixed_map_size;

        const map_name = alloc.tmp_for_c_introp("Local\\fcmd_trie_data");
        const map_handle = windows.CreateFileMapping(file_handle, null, windows.PAGE_READWRITE, 0, @intCast(size), map_name);
        if (map_handle == null) {
            const last_error = windows.GetLastError();
            std.os.windows.CloseHandle(file_handle.?);
            log.log_debug("CreateFileMapping failed: Error code {}\n", .{last_error});
            return error.CannotCreateMapping;
        }

        const map_view = windows.MapViewOfFile(map_handle.?, FILE_MAP_ALL_ACCESS, 0, 0, @intCast(size));
        if (map_view == null) {
            const last_error = windows.GetLastError();
            std.os.windows.CloseHandle(map_handle.?);
            std.os.windows.CloseHandle(file_handle.?);
            log.log_debug("MapViewOfFile failed: Error code {}\n", .{last_error});
            return error.CannotMapView;
        }

        var map = @as([*]volatile u8, @ptrCast(map_view.?))[0..size];

        const map_magic_number = map[0..4];
        const version = &map[4];
        const size_in_bytes_ptr: *std.atomic.Value(i32) = @ptrCast(@alignCast(@volatileCast(map.ptr + 8)));

        var trie_blocks: MappedArray(lego_trie.TrieBlock) = undefined;
        trie_blocks.len = @ptrCast(@alignCast(@volatileCast(map.ptr + 16)));
        trie_blocks.mmap_context = mmap_context;
        const start = 16 + @sizeOf(usize);
        const trie_block_count = @divFloor(map.len - start, @sizeOf(lego_trie.TrieBlock));
        const end = trie_block_count * @sizeOf(lego_trie.TrieBlock);
        const trieblock_bytes = map[start .. start + end];

        trie_blocks.map = @alignCast(std.mem.bytesAsSlice(lego_trie.TrieBlock, @volatileCast(trieblock_bytes)));

        var magic_equal = true;
        var magic_all_zero = true;
        for (map_magic_number, magic_number) |actual_magic, expected_magic| {
            if (actual_magic != expected_magic) {
                magic_equal = false;
            }

            if (actual_magic != 0) {
                magic_all_zero = false;
            }
        }

        if (magic_all_zero) {
            // Empty, assume new file
            log.log_debug("No data in the state. Resetting ...\n", .{});
            @memcpy(@volatileCast(map_magic_number), &magic_number);
            version.* = current_version;
            size_in_bytes_ptr.store(@intCast(size), .release);
        } else if (magic_equal) {
            if (version.* == current_version) {
                log.log_debug("Successfully read existing state, {} bytes\n", .{size_in_bytes_ptr.load(.acquire)});
                log.log_debug("Loading block trie, {} blocks, {} used\n", .{ trie_block_count, trie_blocks.len.* });
            } else {
                std.os.windows.CloseHandle(map_handle.?);
                std.os.windows.CloseHandle(file_handle.?);
                return error.InvalidVersion;
            }
        } else {
            std.os.windows.CloseHandle(map_handle.?);
            std.os.windows.CloseHandle(file_handle.?);
            return error.InvalidMagicNumber;
        }

        return BackingData{
            .file_handle = file_handle,
            .map_pointer = map_handle,
            .map_view_pointer = map_view.?,
            .map = @volatileCast(map),
            .trie_blocks = trie_blocks,
            .size_in_bytes_ptr = size_in_bytes_ptr,
        };
    }

};

pub fn MappedArray(comptime T: type) type {
    return struct {
        const Self = @This();

        len: *std.atomic.Value(usize),

        // Bulk data doesn't need to be volatile - we use atomics for len and synchronization
        map: []T,

        mmap_context: *MMapContext,

        pub fn append(self: *Self, x: T) void {
            _ = windows.WaitForSingleObject(self.mmap_context.write_mutex, INFINITE);
            defer _ = windows.ReleaseMutex(self.mmap_context.write_mutex);

            const len_val = self.len.load(.monotonic);
            if (len_val >= self.map.len) {
                @panic("trie full: 16MB mapping exhausted");
            }
            self.map[len_val] = x;
            // Release semantics ensures the write to map[len_val] is visible before len increment
            self.len.store(len_val + 1, .release);
        }

        pub fn at(self: *const Self, i: usize) *T {
            // Acquire semantics ensures we see all writes up to the length
            std.debug.assert(i < self.len.load(.acquire));
            return &self.map[i];
        }
    };
}

