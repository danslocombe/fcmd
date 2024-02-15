const std = @import("std");
const console_input = @import("console_input");

pub const Shell = struct {
    current_prompt: Zipper,

    pub fn apply_command(self: *Shell, command: Command) void {
        _ = self;
        switch (command) {
            .Input => |input| {
                _ = input;
            },
            _ => {},
        }
    }
};

pub const Zipper = struct {
    bs: std.ArrayList(u8),
    byte_index: usize = 0,

    //pub fn apply_input(self: *Zipper, ConsoleInput
};

pub const Command = union(enum) {
    Input: console_input.Input,
    NoOp: void,
};
