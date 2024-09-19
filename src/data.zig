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

pub var g_backing_data: BackingData = undefined;

const initial_size = 256;

pub var g_data_mutex: std.Thread.Mutex = .{};

pub var g_unload_event: *anyopaque = undefined;
pub var g_reload_event: *anyopaque = undefined;
pub var g_hack_we_are_the_process_requesting_an_unload: bool = false;
pub var g_cross_process_semaphore: *anyopaque = undefined;

pub const BackingData = struct {
    file_handle: *anyopaque,
    map_pointer: ?*anyopaque,
    map_view_pointer: *anyopaque,
    map: []u8,

    trie_blocks: DumbList(lego_trie.TrieBlock),
    size_in_bytes_ptr: *volatile i32,

    pub fn init(state_override_dir: ?[]const u8) void {
        g_backing_data.map_pointer = null;

        var state_dir = state_override_dir;
        var appdata: []const u8 = windows.get_appdata_path();
        defer (alloc.gpa.allocator().free(appdata));

        if (state_dir == null) {
            state_dir = appdata;
        }

        log.log_debug("Creating semaphore {s}\n", semaphore_name);
        var create_semaphore_result = windows.CreateSemaphoreA(null, 0, 1024, semaphore_name);
        if (create_semaphore_result == null) {
            var last_error = windows.GetLastError();
            alloc.fmt_panic("Failed to get semaphore {s}, Error {}", .{ semaphore_name, last_error });
        }

        g_cross_process_semaphore = create_semaphore_result.?;

        // Release semaphore to add to the count.
        // Meaning for another process to be able to have exclusive access to the file we will need to acquire it later
        // to decrease the account
        var prev_semaphore_count: i32 = -1;
        if (windows.ReleaseSemaphore(g_cross_process_semaphore, 1, &prev_semaphore_count) == 0) {
            var last_error = windows.GetLastError();
            alloc.fmt_panic("Failed to release semaphore, Error {}", .{last_error});
        }

        log.log_debug("Released semaphore, prev_count was {}\n", .{prev_semaphore_count});

        var fcmd_appdata_dir = std.mem.concatWithSentinel(alloc.temp_alloc.allocator(), u8, &[_][]const u8{ state_dir.?, "\\fcmd" }, 0) catch unreachable;
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

        g_backing_data.file_handle = file_handle.?;

        {
            const manually_reset = 1;
            const initial_state = 0;
            //const event_all_access: u32 = 0x1F0003;
            //var get_event_response = windows.CreateEventA(&event_all_access, manually_reset, initial_state, unload_event_name);

            var get_event_response = windows.CreateEventA(null, manually_reset, initial_state, unload_event_name);
            if (get_event_response == null) {
                var last_error = windows.GetLastError();
                alloc.fmt_panic("CreateEventA {s} error code {}", .{ unload_event_name, last_error });
            }

            g_unload_event = get_event_response.?;

            get_event_response = windows.CreateEventA(null, manually_reset, initial_state, reload_event_name);
            if (get_event_response == null) {
                var last_error = windows.GetLastError();
                alloc.fmt_panic("CreateEventA {s} error code {}", .{ reload_event_name, last_error });
            }

            g_reload_event = get_event_response.?;
        }

        ensure_other_processes_have_released_handle();

        // Do a small initial load to just read out the size.
        open_map(null);
        //var actual_initial_size = initial_size + g_backing_data.trie_blocks.len.* * @sizeOf(lego_trie.TrieBlock);
        open_map(@intCast(g_backing_data.size_in_bytes_ptr.*));

        // @Reliability add defer on error for this or a crash will block all others.
        signal_other_processes_can_reaquire_handle();

        var thread = std.Thread.spawn(.{}, background_unloader_loop, .{}) catch @panic("Could not start background thread");
        _ = thread;
    }

    pub fn open_map(new_size: ?usize) void {
        log.log_debug("Opening map. new_size {any}\n", new_size);
        var size = new_size orelse initial_size;

        if (g_backing_data.map_pointer) |map_ptr| {
            std.os.windows.CloseHandle(map_ptr);
            g_backing_data.map_pointer = null;
        }

        //var map_name = alloc.tmp_for_c_introp("Local\\fcmd_trie_data");
        var map_name = alloc.tmp_for_c_introp("fcmd_trie_data");
        var map_handle = windows.CreateFileMapping(g_backing_data.file_handle, null, windows.PAGE_READWRITE, 0, @intCast(size), map_name);
        if (map_handle == null) {
            var last_error = windows.GetLastError();
            alloc.fmt_panic("CreateFileMapping: Error code {}", .{last_error});
        }

        g_backing_data.map_pointer = map_handle.?;

        // @Reliability switch to MapViewOfFile3 to guarentee alignment
        // https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-mapviewoffile3
        var map_view = windows.MapViewOfFile(map_handle, FILE_MAP_ALL_ACCESS, 0, 0, @intCast(size));

        if (map_view == null) {
            var last_error = windows.GetLastError();
            alloc.fmt_panic("MapViewOfFile: Error code {}", .{last_error});
        }

        g_backing_data.map_view_pointer = map_view.?;

        var map = @as([*]volatile u8, @ptrCast(g_backing_data.map_view_pointer))[0..size];

        var map_magic_number = map[0..4];
        var version = &map[4];
        g_backing_data.size_in_bytes_ptr = @ptrCast(@alignCast(map.ptr + 8));

        g_backing_data.trie_blocks = undefined;
        g_backing_data.trie_blocks.len = @ptrCast(@alignCast(map.ptr + 16));
        const start = 16 + @sizeOf(usize);
        var trie_block_count = @divFloor(map.len - start, @sizeOf(lego_trie.TrieBlock));
        var end = trie_block_count * @sizeOf(lego_trie.TrieBlock);
        var trieblock_bytes = map[start .. start + end];

        g_backing_data.trie_blocks.map = @alignCast(std.mem.bytesAsSlice(lego_trie.TrieBlock, @volatileCast(trieblock_bytes)));
        //g_backing_data.trie_blocks.map = @alignCast(@ptrCast(trieblock_bytes));

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
            std.debug.print("No data in the state. Resetting ...\n", .{});
            @memcpy(map_magic_number, &magic_number);
            version.* = current_version;
            g_backing_data.size_in_bytes_ptr.* = @intCast(size);
        } else if (magic_equal) {
            if (version.* == current_version) {
                std.debug.print("Successfully read existing state, {} bytes\n", .{g_backing_data.size_in_bytes_ptr.*});
                std.debug.print("Loading block trie, {} blocks, {} used\n", .{ trie_block_count, g_backing_data.trie_blocks.len.* });
            } else {
                alloc.fmt_panic("Unexpected version '{}' expected {}", .{ version.*, current_version });
            }
        } else {
            //alloc.fmt_panic("Unexpected magic number on file '{s}'", .{map_magic_number});
            alloc.fmt_panic("Unexpected magic number on file", .{});
        }

        if (new_size) |x| {
            // We are explicitly resizing, this is either because
            // we have read the an existing file with a given size and we are mapping to that
            // or we have just resized.
            // In the first case it is harmless to set this, in the second we need to set this.
            g_backing_data.size_in_bytes_ptr.* = @intCast(x);
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

        len: *volatile usize,

        // TODO make me volatile
        //map: [*]volatile T,
        map: []T,

        pub fn append(self: *Self, x: T) void {
            if (self.len.* >= self.map.len) {
                // Resize
                var new_size = initial_size + self.map.len * 2 * @sizeOf(lego_trie.TrieBlock);

                // @Hack set the value in the backing data to the new size
                // before telling everyone to unload and reload as they need to know
                // the size to read first.
                g_backing_data.size_in_bytes_ptr.* = @intCast(new_size);

                ensure_other_processes_have_released_handle();
                BackingData.open_map(new_size);
                signal_other_processes_can_reaquire_handle();
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

pub fn ensure_other_processes_have_released_handle() void {
    log.log_debug("Ensuring exclusive control...\n", .{});

    g_hack_we_are_the_process_requesting_an_unload = true;

    if (windows.ResetEvent(g_reload_event) == 0) {
        var last_error = windows.GetLastError();
        alloc.fmt_panic("Failed to reset event '{s}'. Error {}", .{ reload_event_name, last_error });
    }

    // Signal to others they should begin unloading
    if (windows.SetEvent(g_unload_event) == 0) {
        var last_error = windows.GetLastError();
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
        _ = windows.WaitForSingleObject(g_cross_process_semaphore, INFINITE);

        var prev_count: i32 = -1;
        if (windows.ReleaseSemaphore(g_cross_process_semaphore, 1, &prev_count) == 0) {
            var last_error = windows.GetLastError();
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
            std.time.sleep(1 * 1000 * 1000);
        }
    }

    //if (windows.ReleaseSemaphore(g_cross_process_semaphore, 1, null) == 0) {
    //    var last_error = windows.GetLastError();
    //    alloc.fmt_panic("Failed to release semaphore, Error {}", .{last_error});
    //}

    //windows.WaitForSingleObject()

    // Send message to other processes.

    // Wait for semaphore to go to zero
}

pub fn signal_other_processes_can_reaquire_handle() void {
    g_hack_we_are_the_process_requesting_an_unload = false;

    if (windows.ResetEvent(g_unload_event) == 0) {
        var last_error = windows.GetLastError();
        alloc.fmt_panic("Failed to reset event '{s}'. Error {}", .{ unload_event_name, last_error });
    }

    if (windows.SetEvent(g_reload_event) == 0) {
        var last_error = windows.GetLastError();
        alloc.fmt_panic("Failed to set event '{s}'. Error {}", .{ reload_event_name, last_error });
    }
}

pub fn acquire_local_mutex() void {
    g_data_mutex.lock();
}

pub fn release_local_mutex() void {
    g_data_mutex.unlock();
}

pub fn background_unloader_loop() void {
    log.log_debug("[Background Unloader] Initialized\n", .{});
    log.log_debug("[Background Unloader] Waiting for {s}\n", .{unload_event_name});
    while (true) {
        _ = windows.WaitForSingleObject(g_unload_event, INFINITE);

        if (g_hack_we_are_the_process_requesting_an_unload) {
            // @Reliability race conditions here?
            //log.log_debug("[Background Unloader] It is us requesting an unload! Skipping", .{});

            // @Hack sleep here to avoid churn
            // 10ms
            std.time.sleep(100 * 1000 * 1000);
            continue;
        }

        // Wait for signal
        log.log_debug("[Background Unloader] Event signaled!\n", .{});

        log.log_debug("[Background Unloader] Acquiring local mutex...\n", .{});
        acquire_local_mutex();
        // Now locally safe to unload

        var reload_size = g_backing_data.size_in_bytes_ptr.*;
        log.log_debug("Unloading file...\n", .{});
        if (g_backing_data.map_pointer) |map_ptr| {
            std.os.windows.CloseHandle(map_ptr);
            g_backing_data.map_pointer = null;
        }

        // Signify we no longer have the file open
        log.log_debug("[Background Unloader] Acquiring semaphore...\n", .{});
        _ = windows.WaitForSingleObject(g_cross_process_semaphore, INFINITE);

        // ...

        log.log_debug("Waiting until its safe to reload...\n", .{});
        _ = windows.WaitForSingleObject(g_reload_event, INFINITE);

        // Increment semaphore to signify we are reading the file
        var prev_semaphore_count: i32 = -1;
        if (windows.ReleaseSemaphore(g_cross_process_semaphore, 1, &prev_semaphore_count) == 0) {
            var last_error = windows.GetLastError();
            alloc.fmt_panic("Failed to release semaphore, Error {}", .{last_error});
        }

        log.log_debug("[Background Unloader] Released semaphore, prev count {}\n", .{prev_semaphore_count});

        // This shoullld be fine, do we need more guarentees?
        // This should be opening with the same size as everyone else
        BackingData.open_map(@intCast(reload_size));

        release_local_mutex();
    }
}
