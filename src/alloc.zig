const std = @import("std");

pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub var temp_alloc = std.heap.ArenaAllocator.init(gpa.allocator());

pub fn clear_temp_alloc() void {
    _ = temp_alloc.reset(.{
        .retain_with_limit = 64 * 1024,
    });
}

pub fn gpa_alloc_idk(comptime T: type, n: usize) []T {
    return gpa.allocator().alloc(T, n) catch unreachable;
}

pub fn gpa_new_idk(comptime T: type) *T {
    var array = gpa_alloc_idk(T, 1);
    return &array[0];
}

pub fn new_arraylist(comptime T: type) std.ArrayList(T) {
    return std.ArrayList(T).init(gpa.allocator());
}
// Is there a standard library function for this?
pub fn zeroed(comptime T: type, comptime N: usize) [N]T {
    var xs: [N]T = undefined;
    inline for (0..N) |i| {
        xs[i] = 0;
    }

    return xs;
}

pub fn trued(comptime N: usize) [N]bool {
    var xs: [N]bool = undefined;
    inline for (0..N) |i| {
        xs[i] = true;
    }

    return xs;
}

pub fn defaulted(comptime T: type, comptime N: usize) [N]T {
    var xs: [N]T = undefined;
    inline for (0..N) |i| {
        xs[i] = .{};
    }

    return xs;
}

pub fn fmt_panic(comptime f: []const u8, xs: anytype) void {
    var s = std.fmt.allocPrint(gpa.allocator(), f, xs) catch unreachable;
    @panic(s);
}
