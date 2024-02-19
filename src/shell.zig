const std = @import("std");
const alloc = @import("alloc.zig");
const console_input = @import("console_input.zig");

pub const Shell = struct {
    current_prompt: Zipper,

    pub fn init() Shell {
        return .{
            .current_prompt = Zipper.init(),
        };
    }

    pub fn apply_command(self: *Shell, command: Command) void {
        switch (command) {
            .Input => |input| {
                self.current_prompt.apply_input(input);
            },
            else => {},
        }
    }

    pub fn draw(self: *Shell) void {
        self.current_prompt.draw();
    }
};

pub const Zipper = struct {
    bs: std.ArrayList(u8),
    byte_index: usize = 0,
    pub fn init() Zipper {
        return .{
            .bs = alloc.new_arraylist(u8),
        };
    }

    pub fn apply_input(self: *Zipper, input: console_input.Input) void {
        switch (input) {
            .Append => |*c| {
                self.bs.appendSlice(c.slice()) catch unreachable;
            },
            else => {},
        }
    }

    pub fn draw(self: *Zipper) void {
        _ = std.io.getStdOut().write("\r") catch unreachable;
        _ = std.io.getStdOut().write(self.bs.items) catch unreachable;
        //std.debug.print("{s}\n", .{self.bs.items});
    }
};

pub const Command = union(enum) {
    Input: console_input.Input,
    NoOp: void,
};
