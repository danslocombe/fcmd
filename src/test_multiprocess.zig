// Multi-process testing framework for trie concurrency
// This module provides utilities for creating test state files and running
// operations in a multi-process environment

const std = @import("std");
const alloc = @import("alloc.zig");
const windows = @import("windows.zig");
const log = @import("log.zig");
const data = @import("data.zig");
const lego_trie = @import("datastructures/lego_trie.zig");

const magic_number = [_]u8{ 'f', 'r', 'o', 'g' };
const current_version: u8 = 3;

/// Represents a standalone test state file
pub const TestStateFile = struct {
    filepath: []const u8,
    allocator: std.mem.Allocator,

    /// Create a new test state file with initial capacity
    pub fn create(allocator: std.mem.Allocator, filepath: []const u8, initial_blocks: usize) !TestStateFile {
        const file = try std.fs.cwd().createFile(filepath, .{ .read = true, .truncate = true });
        defer file.close();

        // Calculate total size needed
        const header_size = 16; // magic(4) + version(1) + padding(3) + size_in_bytes(4) + padding(4)
        const len_size = @sizeOf(usize);
        const block_data_size = initial_blocks * @sizeOf(lego_trie.TrieBlock);
        const total_size = header_size + len_size + block_data_size;

        // Allocate buffer for initial state
        const buffer = try allocator.alloc(u8, total_size);
        defer allocator.free(buffer);
        @memset(buffer, 0);

        // Write magic number
        @memcpy(buffer[0..4], &magic_number);

        // Write version
        buffer[4] = current_version;

        // Write size_in_bytes (at offset 8)
        const size_ptr: *i32 = @ptrCast(@alignCast(buffer.ptr + 8));
        size_ptr.* = @intCast(total_size);

        // Write trie block count (at offset 16) - starts at 0
        const len_ptr: *usize = @ptrCast(@alignCast(buffer.ptr + 16));
        len_ptr.* = 0;

        // Write to file
        try file.writeAll(buffer);

        return TestStateFile{
            .filepath = try allocator.dupe(u8, filepath),
            .allocator = allocator,
        };
    }

    /// Open an existing test state file
    pub fn open(allocator: std.mem.Allocator, filepath: []const u8) !TestStateFile {
        // Verify file exists and has valid header
        const file = try std.fs.cwd().openFile(filepath, .{});
        defer file.close();

        var header: [16]u8 = undefined;
        const bytes_read = try file.preadAll(&header, 0);
        if (bytes_read != 16) {
            return error.InvalidHeader;
        }

        // Verify magic number
        if (!std.mem.eql(u8, header[0..4], &magic_number)) {
            return error.InvalidMagicNumber;
        }

        // Verify version
        if (header[4] != current_version) {
            return error.InvalidVersion;
        }

        return TestStateFile{
            .filepath = try allocator.dupe(u8, filepath),
            .allocator = allocator,
        };
    }

    /// Populate the test state file with initial data
    pub fn populate(self: *TestStateFile, strings: []const []const u8) !void {
        // We need to manually create a trie in memory, insert the strings,
        // then write the entire state to the file

        const file = try std.fs.cwd().openFile(self.filepath, .{ .mode = .read_write });
        defer file.close();

        // Read current file size
        const stat = try file.stat();
        const file_size = stat.size;

        // Map the file into memory
        const map_size = if (file_size < 1024) 1024 * 64 else file_size; // Minimum 64KB for testing

        // Allocate buffer to work with
        const buffer = try self.allocator.alloc(u8, map_size);
        defer self.allocator.free(buffer);
        @memset(buffer, 0);

        // If file has data, read it
        if (file_size > 0) {
            try file.seekTo(0);
            const bytes_read = try file.preadAll(buffer[0..@min(file_size, map_size)], 0);
            _ = bytes_read;
        } else {
            // Initialize new file
            @memcpy(buffer[0..4], &magic_number);
            buffer[4] = current_version;
        }

        // Set up trie structure in the buffer
        const size_ptr: *i32 = @ptrCast(@alignCast(buffer.ptr + 8));
        size_ptr.* = @intCast(map_size);

        var len: usize = 0;
        const len_ptr: *usize = @ptrCast(@alignCast(buffer.ptr + 16));
        len_ptr.* = 0;

        const start = 16 + @sizeOf(usize);
        const trie_block_count = @divFloor(buffer.len - start, @sizeOf(lego_trie.TrieBlock));
        const end = trie_block_count * @sizeOf(lego_trie.TrieBlock);
        const trieblock_bytes = buffer[start .. start + end];

        const trie_blocks: []lego_trie.TrieBlock = @alignCast(std.mem.bytesAsSlice(lego_trie.TrieBlock, trieblock_bytes));

        var blocks_list = data.DumbList(lego_trie.TrieBlock){
            .len = &len,
            .map = trie_blocks,
        };

        var trie = lego_trie.Trie.init(&blocks_list);

        // Insert all strings
        for (strings) |s| {
            var view = trie.to_view();
            try view.insert(s);
        }

        // Write len back
        len_ptr.* = len;

        // Write buffer back to file
        try file.seekTo(0);
        try file.writeAll(buffer);
        try file.setEndPos(map_size);
    }

    /// Clean up resources
    pub fn deinit(self: *TestStateFile) void {
        self.allocator.free(self.filepath);
    }

    /// Delete the test state file
    pub fn delete(self: *TestStateFile) !void {
        try std.fs.cwd().deleteFile(self.filepath);
    }
};

/// Operations that can be performed in a test process
pub const TestOperation = enum {
    insert,
    search,
    walk,
    stress,
    verify,
};

/// Result of a test operation
pub const TestResult = struct {
    success: bool,
    message: []const u8,
};

/// Execute a test operation on a state file
/// This is designed to be called from a subprocess via CLI
pub fn executeTestOperation(
    operation: TestOperation,
    state_file: []const u8,
    args: []const []const u8,
) !TestResult {
    _ = operation;
    _ = state_file;
    _ = args;

    // This will be implemented based on the operation type
    // For now, return a placeholder
    return TestResult{
        .success = true,
        .message = "Not implemented yet",
    };
}

/// Helper to verify all strings in a list are findable in a state file
pub fn verifyStringsInStateFile(
    allocator: std.mem.Allocator,
    state_file: []const u8,
    strings: []const []const u8,
) !bool {
    _ = allocator;

    const state_file_c = alloc.tmp_for_c_introp(state_file);

    // Open the state file using memory mapping (same as main path)
    var backing_data = data.BackingData.open_test_state_file(state_file_c) catch |err| {
        log.log_debug("Error opening state file '{s}': {}\n", .{ state_file, err });
        return false;
    };
    defer backing_data.close_test_state_file();

    // Create trie view from memory-mapped data
    var trie = lego_trie.Trie.init(&backing_data.trie_blocks);
    const view = trie.to_view();

    // Try to find each string
    for (strings) |needle| {
        var walker = lego_trie.TrieWalker.init(view, needle);
        if (!walker.walk_to()) {
            std.debug.print("Failed to find: '{s}'\n", .{needle});
            return false;
        }
        // Verify we consumed the entire string
        if (walker.char_id != needle.len) {
            std.debug.print("Partial match only for: '{s}'\n", .{needle});
            return false;
        }
    }

    return true;
}

/// Helper to verify a single string is findable in a state file
pub fn verifyStringInStateFile(
    allocator: std.mem.Allocator,
    state_file: []const u8,
    needle: []const u8,
) !bool {
    const strings = [_][]const u8{needle};
    return verifyStringsInStateFile(allocator, state_file, &strings);
}

/// Helper to get the cost (priority score) of a specific string in a state file
/// Returns the cost value, or null if string not found
/// Lower cost = higher priority (more frequently used)
pub fn getStringCost(
    allocator: std.mem.Allocator,
    state_file: []const u8,
    needle: []const u8,
) !?u16 {
    _ = allocator;

    const state_file_c = alloc.tmp_for_c_introp(state_file);

    // Open the state file using memory mapping (same as main path)
    var backing_data = data.BackingData.open_test_state_file(state_file_c) catch |err| {
        log.log_debug("Error opening state file '{s}': {}\n", .{ state_file, err });
        return null;
    };
    defer backing_data.close_test_state_file();

    // Create trie view from memory-mapped data
    var trie = lego_trie.Trie.init(&backing_data.trie_blocks);
    const view = trie.to_view();

    // Walk to the string and get its cost
    var walker = lego_trie.TrieWalker.init(view, needle);
    if (!walker.walk_to()) {
        return null;
    }

    // Verify we consumed the entire string
    if (walker.char_id != needle.len) {
        return null;
    }

    return walker.cost;
}

/// Process controller for spawning and managing test processes
pub const ProcessController = struct {
    allocator: std.mem.Allocator,
    processes: std.ArrayList(std.process.Child),

    pub fn init(allocator: std.mem.Allocator) ProcessController {
        return .{
            .allocator = allocator,
            .processes = std.ArrayList(std.process.Child){},
        };
    }

    pub fn deinit(self: *ProcessController) void {
        for (self.processes.items) |*proc| {
            _ = proc.kill() catch {};
        }
        self.processes.deinit(self.allocator);
    }

    /// Spawn a test process with given arguments
    pub fn spawn(self: *ProcessController, args: []const []const u8) !void {
        var child = std.process.Child.init(args, self.allocator);
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        try child.spawn();
        try self.processes.append(self.allocator, child);
    }

    /// Wait for all processes to complete and collect exit codes
    pub fn waitAll(self: *ProcessController) ![]u8 {
        var exit_codes = try self.allocator.alloc(u8, self.processes.items.len);

        for (self.processes.items, 0..) |*proc, i| {
            const term = try proc.wait();
            exit_codes[i] = switch (term) {
                .Exited => |code| @intCast(code),
                else => 255,
            };
        }

        return exit_codes;
    }

    /// Check if all processes succeeded (exit code 0)
    pub fn allSucceeded(exit_codes: []const u8) bool {
        for (exit_codes) |code| {
            if (code != 0) return false;
        }
        return true;
    }
};
