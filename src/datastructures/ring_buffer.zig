const alloc = @import("../alloc.zig");

pub fn RingBuffer(comptime T: type) type {
    return struct {
        buffer: []T,
        current_pos: usize = 0,

        const Self = @This();

        pub fn init(sample_count: usize, default_value: T) Self {
            const buffer = alloc.gpa_alloc_idk(T, sample_count);

            for (buffer) |*p| {
                p.* = default_value;
            }

            return .{
                .buffer = buffer,
            };
        }

        pub fn deinit(self: *Self) void {
            alloc.gpa.allocator().free(self.buffer);
        }

        pub fn push(self: *Self, x: T) T {
            self.incr_current_pos();

            const prev = self.buffer[self.current_pos];
            self.buffer[self.current_pos] = x;

            return prev;
        }

        pub fn incr_current_pos(self: *Self) void {
            self.current_pos += 1;
            if (self.current_pos == self.buffer.len) {
                self.current_pos = 0;
            }
        }

        pub fn get(self: *Self, offset: i32) *T {
            const pos = self.pos_wrapping(offset);
            return &self.buffer[pos];
        }

        pub fn pos_wrapping(self: *Self, offset: i32) usize {
            return self.index_from_base_index_and_offset(self.current_pos, offset);
        }

        pub fn index_from_base_index_and_offset(self: *Self, index: usize, offset: i32) usize {
            const size: i32 = @intCast(self.buffer.len);

            // Assume: offset < buffersize
            var pos = @as(i32, @intCast(index)) + offset;
            if (pos < 0) {
                pos += size;
            } else if (pos >= size) {
                pos -= size;
            }

            return @intCast(pos);
        }
    };
}
