const std = @import("std");

pub var debug_log_enabled: bool = false;

pub fn log_debug(comptime s: []const u8, args: anytype) void {
    const ArgsType = @TypeOf(args);
    const args_type_info = @typeInfo(ArgsType);
    if (args_type_info == .Struct) {
        std.debug.print(s, args);
    } else {
        std.debug.print(s, .{args});
    }
}
