const std = @import("std");
const alloc = @import("alloc.zig");
const console_input = @import("console_input.zig");
const Zipper = @import("zipper.zig").Zipper;
const run = @import("run.zig");

pub const Shell = struct {
    current_prompt: Zipper,

    pub fn init() Shell {
        return .{
            .current_prompt = Zipper.init(),
        };
    }

    pub fn apply_input(self: *Shell, input: console_input.Input) void {
        if (Command.try_get_from_input(input)) |command| {
            switch (command) {
                .Run => {
                    if (run.FroggyCommand.try_get_froggy_command(self.current_prompt.bs.items)) |froggy| {
                        froggy.execute();
                    } else {
                        // Run command
                    }
                },
                else => {
                    // TODO
                },
            }
        } else {
            self.current_prompt.apply_input(input);
        }
    }

    pub fn draw(self: *Shell) void {
        self.current_prompt.draw();
    }
};

pub const Command = enum {
    Run,

    Complete,
    PartialComplete,

    HistoryBack,
    HistoryForward,

    Cls,
    Exit,
    NoOp,

    fn try_get_from_input(input: console_input.Input) ?Command {
        return switch (input) {
            .Enter => Command.Run,
            else => null,
        };
    }
};
