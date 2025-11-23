// Multi-process testing framework for trie concurrency
// This module provides utilities for creating test state files and running
// operations in a multi-process environment

const std = @import("std");
const alloc = @import("alloc.zig");
const windows = @import("windows.zig");
const log = @import("log.zig");
const data = @import("data.zig");
const lego_trie = @import("datastructures/lego_trie.zig");

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
