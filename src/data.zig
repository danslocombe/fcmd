const std = @import("std");
const alloc = @import("alloc.zig");
const windows = @import("windows.zig");
const log = @import("log.zig");

const lego_trie = @import("datastructures/lego_trie.zig");

// Hack workaround macro expansion error in MinGW when referencing ReleaseSemaphore
extern fn ReleaseSemaphoreA(hSemaphore: *anyopaque, lReleaseCount: i32, lpPreviousCount: *i32) i32;

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

const unload_event_name: [:0]const u8 = "fcmd_unload_data";
const reload_event_name: [:0]const u8 = "fcmd_reload_data";
const semaphore_name: [:0]const u8 = "Local\\fcmd_data_semaphore";

const initial_size = 256;

// Alias for backward compatibility and clarity
pub const GlobalContext = MMapContext;

pub const MMapContext = struct {
    data_mutex: std.Thread.Mutex = .{},

    unload_event: *anyopaque = undefined,
    reload_event: *anyopaque = undefined,
    hack_we_are_the_process_requesting_an_unload: bool = false,
    cross_process_semaphore: *anyopaque = undefined,

    filepath: [*c]const u8 = "",

    backing_data: BackingData = undefined,
};

pub const BackingData = struct {
    file_handle: ?*anyopaque,
    map_pointer: ?*anyopaque,
    map_view_pointer: *anyopaque,
    map: []u8,

    trie_blocks: DumbList(lego_trie.TrieBlock),
    size_in_bytes_ptr: *volatile i32,

    pub fn init(state_dir: []const u8, context: *MMapContext) void {
        std.fs.makeDirAbsolute(state_dir) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {
                    // This is fine
                },
                else => {
                    alloc.fmt_panic("MakeDirAbsolute error when creating '{s}' {}\n", .{ state_dir, err });
                },
            }
        };

        const filepath = std.mem.concatWithSentinel(alloc.gpa.allocator(), u8, &[_][]const u8{ state_dir, "\\trie.frog" }, 0) catch unreachable;

        const result = init_internal(filepath, context) catch |err| {
            alloc.fmt_panic("Failed to initialize BackingData: {}", .{err});
        };

        context.backing_data = result;

        // Open the mapping - will automatically discover size if it's an existing mapping
        open_map(null, context);
        open_map(@intCast(context.backing_data.size_in_bytes_ptr.*), context);

        const thread = std.Thread.spawn(.{}, background_unloader_loop, .{context}) catch @panic("Could not start background thread");
        _ = thread;
    }

    /// Internal initialization function that handles the actual file mapping and sync object creation
    fn init_internal(filepath: [*c]const u8, mmap_context: *MMapContext) !BackingData {
        log.log_debug("Initializing BackingData for: {s}\n", .{filepath});

        // Create semaphore
        log.log_debug("Creating semaphore {s}\n", .{semaphore_name});
        const create_semaphore_result = windows.CreateSemaphoreA(null, 0, 1024, semaphore_name);
        if (create_semaphore_result == null) {
            const last_error = windows.GetLastError();
            log.log_debug("Failed to create semaphore {s}, Error {}\n", .{ semaphore_name, last_error });
            return error.CannotCreateSemaphore;
        }

        const semaphore = create_semaphore_result.?;
        mmap_context.cross_process_semaphore = semaphore;

        // Release semaphore to add to the count
        var prev_semaphore_count: i32 = -1;
        if (windows.ReleaseSemaphore(semaphore, 1, &prev_semaphore_count) == 0) {
            const last_error = windows.GetLastError();
            log.log_debug("Failed to release semaphore, Error {}\n", .{last_error});
            return error.CannotReleaseSemaphore;
        }

        log.log_debug("Released semaphore, prev_count was {}\n", .{prev_semaphore_count});

        // Create events
        const manually_reset = 1;
        const initial_state = 0;

        var get_event_response = windows.CreateEventA(null, manually_reset, initial_state, unload_event_name);
        if (get_event_response == null) {
            const last_error = windows.GetLastError();
            log.log_debug("CreateEventA {s} error code {}\n", .{ unload_event_name, last_error });
            return error.CannotCreateUnloadEvent;
        }

        const unload_event = get_event_response.?;
        mmap_context.unload_event = unload_event;

        get_event_response = windows.CreateEventA(null, manually_reset, initial_state, reload_event_name);
        if (get_event_response == null) {
            const last_error = windows.GetLastError();
            log.log_debug("CreateEventA {s} error code {}\n", .{ reload_event_name, last_error });
            return error.CannotCreateReloadEvent;
        }

        const reload_event = get_event_response.?;
        mmap_context.reload_event = reload_event;

        // Open or create the file
        const GENERIC_READ = 0x80000000;
        const GENERIC_WRITE = 0x40000000;
        const file_handle: ?*anyopaque = windows.CreateFileA(filepath, GENERIC_READ | GENERIC_WRITE, windows.FILE_SHARE_WRITE, null, windows.OPEN_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, null);

        if (file_handle == null) {
            const last_error = windows.GetLastError();
            log.log_debug("CreateFileA failed: Error code {}\n", .{last_error});
            return error.CannotOpenFile;
        }

        const size = initial_size;

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
        const size_in_bytes_ptr: *volatile i32 = @ptrCast(@alignCast(map.ptr + 8));

        var trie_blocks: DumbList(lego_trie.TrieBlock) = undefined;
        trie_blocks.len = @ptrCast(@alignCast(map.ptr + 16));
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
            size_in_bytes_ptr.* = @intCast(size);
        } else if (magic_equal) {
            if (version.* == current_version) {
                log.log_debug("Successfully read existing state, {} bytes\n", .{size_in_bytes_ptr.*});
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

    pub fn open_map(new_size: ?usize, mmap_context: *MMapContext) void {
        log.log_debug("Opening map. new_size {any}\n", new_size);

        const size = new_size orelse initial_size;

        if (mmap_context.backing_data.map_pointer) |map_ptr| {
            std.os.windows.CloseHandle(map_ptr);
            mmap_context.backing_data.map_pointer = null;
        }

        const map_name = alloc.tmp_for_c_introp("Local\\fcmd_trie_data");

        // Try and open existing mapping
        const m_open_mapping_result = windows.OpenFileMappingA(FILE_MAP_ALL_ACCESS, 0, map_name);
        if (m_open_mapping_result) |open_mapping_result| {
            log.log_debug("Opened existing file mapping!\n", .{});
            mmap_context.backing_data.map_pointer = open_mapping_result;
        } else {
            log.log_debug("Could not open file mapping, creating new..\n", .{});
            // Create file mapping
            if (mmap_context.backing_data.file_handle == null) {
                const GENERIC_READ = 0x80000000;
                const GENERIC_WRITE = 0x40000000;
                const file_handle: ?*anyopaque = windows.CreateFileA(mmap_context.filepath, GENERIC_READ | GENERIC_WRITE, windows.FILE_SHARE_WRITE, null, windows.OPEN_ALWAYS, windows.FILE_ATTRIBUTE_NORMAL, null);

                if (file_handle == null) {
                    const last_error = windows.GetLastError();
                    alloc.fmt_panic("CreateFileA: Error code {}", .{last_error});
                }

                mmap_context.backing_data.file_handle = file_handle.?;
            }

            const map_handle = windows.CreateFileMapping(mmap_context.backing_data.file_handle, null, windows.PAGE_READWRITE, 0, @intCast(size), map_name);
            if (map_handle == null) {
                const last_error = windows.GetLastError();
                alloc.fmt_panic("CreateFileMapping: Error code {}", .{last_error});
            }

            mmap_context.backing_data.map_pointer = map_handle.?;
        }

        // @Reliability switch to MapViewOfFile3 to guarentee alignment
        // https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-mapviewoffile3
        const map_view = windows.MapViewOfFile(mmap_context.backing_data.map_pointer.?, FILE_MAP_ALL_ACCESS, 0, 0, @intCast(actual_size));

        if (map_view == null) {
            const last_error = windows.GetLastError();
            alloc.fmt_panic("MapViewOfFile: Error code {}", .{last_error});
        }

        mmap_context.backing_data.map_view_pointer = map_view.?;

        var map = @as([*]volatile u8, @ptrCast(mmap_context.backing_data.map_view_pointer))[0..actual_size];

        const map_magic_number = map[0..4];
        const version = &map[4];
        mmap_context.backing_data.size_in_bytes_ptr = @ptrCast(@alignCast(map.ptr + 8));

        mmap_context.backing_data.trie_blocks = undefined;
        mmap_context.backing_data.trie_blocks.mmap_context = mmap_context;
        mmap_context.backing_data.trie_blocks.len = @ptrCast(@alignCast(map.ptr + 16));
        const start = 16 + @sizeOf(usize);
        const trie_block_count = @divFloor(map.len - start, @sizeOf(lego_trie.TrieBlock));
        const end = trie_block_count * @sizeOf(lego_trie.TrieBlock);
        const trieblock_bytes = map[start .. start + end];

        mmap_context.backing_data.trie_blocks.map = @alignCast(std.mem.bytesAsSlice(lego_trie.TrieBlock, @volatileCast(trieblock_bytes)));

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
            log.log_info("No data in the state. Resetting ...\n", .{});
            @memcpy(map_magic_number, &magic_number);
            version.* = current_version;
            mmap_context.backing_data.size_in_bytes_ptr.* = @intCast(size);
        } else if (magic_equal) {
            if (version.* == current_version) {
                log.log_debug("Successfully read existing state, {} bytes\n", .{mmap_context.backing_data.size_in_bytes_ptr.*});
                log.log_debug("Loading block trie, {} blocks, {} used\n", .{ trie_block_count, mmap_context.backing_data.trie_blocks.len.* });
            } else {
                alloc.fmt_panic("Unexpected version '{}' expected {}", .{ version.*, current_version });
            }
        } else {
            //alloc.fmt_panic("Unexpected magic number on file '{s}'", .{map_magic_number});
            alloc.fmt_panic("Unexpected magic number on file", .{});
        }

        if (new_size) |x| {
            mmap_context.backing_data.size_in_bytes_ptr.* = @intCast(x);
        }
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
        const end_index_ptr = self.end_index_ptr;
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

        len: *volatile usize,

        // TODO make me volatile
        //map: [*]volatile T,
        map: []T,

        mmap_context: *MMapContext,

        pub fn append(self: *Self, x: T) void {
            if (self.len.* >= self.map.len) {
                // Resize
                const new_size = initial_size + self.map.len * 2 * @sizeOf(lego_trie.TrieBlock);

                ensure_other_processes_have_released_handle(self.mmap_context);
                BackingData.open_map(new_size, self.mmap_context);
                signal_other_processes_can_reaquire_handle(self.mmap_context);
            }

            self.map[self.len.*] = x;
            self.len.* += 1;
        }

        pub fn at(self: *const Self, i: usize) *T {
            std.debug.assert(i < self.len.*);
            return &self.map[i];
        }
    };
}

pub fn ensure_other_processes_have_released_handle(mmap_context: *MMapContext) void {
    log.log_debug("Ensuring exclusive control...\n", .{});

    mmap_context.hack_we_are_the_process_requesting_an_unload = true;

    if (windows.ResetEvent(mmap_context.reload_event) == 0) {
        const last_error = windows.GetLastError();
        alloc.fmt_panic("Failed to reset event '{s}'. Error {}", .{ reload_event_name, last_error });
    }

    // Signal to others they should begin unloading
    if (windows.SetEvent(mmap_context.unload_event) == 0) {
        const last_error = windows.GetLastError();
        alloc.fmt_panic("Failed to set event '{s}'. Error {}", .{ unload_event_name, last_error });
    }

    // @Cleanup is there a better way of doing this?
    while (true) {
        //const WAIT_OBJECT_0 = 0x00000000L;
        //if (windows.WaitForSingleObject(g_cross_process_semaphore, INFINITE) == 0) {
        //    var last_error = windows.GetLastError();
        //    alloc.fmt_panic("Spinny loopy acquire semaphore error, GetLastError {}", .{last_error});
        //}

        log.log_debug("Acquiring semaphore...\n", .{});
        _ = windows.WaitForSingleObject(mmap_context.cross_process_semaphore, INFINITE);

        var prev_count: i32 = -1;
        if (windows.ReleaseSemaphore(mmap_context.cross_process_semaphore, 1, &prev_count) == 0) {
            const last_error = windows.GetLastError();
            alloc.fmt_panic("Failed to release semaphore, Error {}", .{last_error});
        }

        log.log_debug("Got semaphore, prev count {}\n", .{prev_count});
        if (prev_count == 0) {
            // Everyone apart from us has released
            // So we are good to go
            break;
        } else {
            // Someone else is still holding the semaphore, continue to wait
            // 1ms
            windows.Sleep(1);
        }
    }
}

pub fn signal_other_processes_can_reaquire_handle(mmap_context: *MMapContext) void {
    mmap_context.hack_we_are_the_process_requesting_an_unload = false;

    if (windows.ResetEvent(mmap_context.unload_event) == 0) {
        const last_error = windows.GetLastError();
        alloc.fmt_panic("Failed to reset event '{s}'. Error {}", .{ unload_event_name, last_error });
    }

    if (windows.SetEvent(mmap_context.reload_event) == 0) {
        const last_error = windows.GetLastError();
        alloc.fmt_panic("Failed to set event '{s}'. Error {}", .{ reload_event_name, last_error });
    }
}

pub fn background_unloader_loop(mmap_context: *MMapContext) void {
    log.log_debug("[Background Unloader] Initialized\n", .{});
    log.log_debug("[Background Unloader] Waiting for {s}\n", .{unload_event_name});
    while (true) {
        _ = windows.WaitForSingleObject(mmap_context.unload_event, INFINITE);

        if (mmap_context.hack_we_are_the_process_requesting_an_unload) {
            // @Reliability race conditions here?
            //log.log_debug("[Background Unloader] It is us requesting an unload! Skipping", .{});

            // @Hack sleep here to avoid churn
            // 10ms
            windows.Sleep(10);
            continue;
        }

        // Wait for signal
        log.log_debug("[Background Unloader] Event signaled!\n", .{});

        log.log_debug("[Background Unloader] Acquiring local mutex...\n", .{});
        mmap_context.data_mutex.lock();
        // Now locally safe to unload

        log.log_debug("Unloading file...\n", .{});
        if (mmap_context.backing_data.map_pointer) |map_ptr| {
            std.os.windows.CloseHandle(map_ptr);
            mmap_context.backing_data.map_pointer = null;
        }

        // Signify we no longer have the file open
        log.log_debug("[Background Unloader] Acquiring semaphore...\n", .{});
        _ = windows.WaitForSingleObject(mmap_context.cross_process_semaphore, INFINITE);

        // ...

        log.log_debug("Waiting until its safe to reload...\n", .{});
        _ = windows.WaitForSingleObject(mmap_context.reload_event, INFINITE);

        // Increment semaphore to signify we are reading the file
        var prev_semaphore_count: i32 = -1;
        if (windows.ReleaseSemaphore(mmap_context.cross_process_semaphore, 1, &prev_semaphore_count) == 0) {
            const last_error = windows.GetLastError();
            alloc.fmt_panic("Failed to release semaphore, Error {}", .{last_error});
        }

        log.log_debug("[Background Unloader] Released semaphore, prev count {}\n", .{prev_semaphore_count});

        BackingData.open_map(null, mmap_context);

        mmap_context.data_mutex.unlock();
    }
}
