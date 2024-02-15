pub const ConsoleInput = struct {
    key: u8,
    modifier_keys: i32,
};

pub const Input = union(enum) {
    Append: i32,
    Left: void,
    BlockLeft: void,
    Right: void,
    BlockRight: void,

    GotoStart: void,
    GotoEnd: void,

    Delete: void,
    DeleteBlock: void,
};
