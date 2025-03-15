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

pub fn temp_format(comptime format_string: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(temp_alloc.allocator(), format_string, args) catch unreachable;
}

// Is there a standard library function for this?
pub fn zeroed(comptime T: type, comptime N: usize) [N]T {
    var xs: [N]T = undefined;
    for (0..N) |i| {
        xs[i] = 0;
    }

    return xs;
}

pub fn defaulted(comptime T: type, comptime N: usize) [N]T {
    var xs: [N]T = undefined;
    for (0..N) |i| {
        xs[i] = .{};
    }

    return xs;
}

pub fn fmt_panic(comptime f: []const u8, xs: anytype) noreturn {
    var s = std.fmt.allocPrint(gpa.allocator(), f, xs) catch unreachable;
    @panic(s);
}

pub fn copy_slice_to_gpa(s: []const u8) []const u8 {
    var copy = gpa_alloc_idk(u8, s.len);
    @memcpy(copy, s);
    return copy;
}

pub fn tmp_for_c_introp(s: []const u8) [:0]const u8 {
    var copy = temp_alloc.allocator().allocSentinel(u8, s.len, 0) catch unreachable;
    @memcpy(copy, s);
    return copy;
}
