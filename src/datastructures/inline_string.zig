const std = @import("std");
const alloc = @import("../alloc.zig");

pub fn InlineString(comptime N: usize) type {
    return extern struct {
        const Self = @This();
        data: [N]u8 = alloc.zeroed(u8, N),

        pub fn clear(self: *Self) void {
            @memset(&self.data, 0);
        }

        pub fn from_slice(xs: []const u8) Self {
            var small_str = Self{};
            small_str.assign_from(xs);
            return small_str;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.data[0..self.len()];
        }

        pub fn len(self: Self) usize {
            var length: usize = 0;
            while (length < N) : (length += 1) {
                if (self.data[length] == 0) {
                    return length;
                }
            }

            return N;
        }

        pub fn matches(xs: Self, key: []const u8) bool {
            const l = @min(N, key.len);
            var i: usize = 0;
            while (i < l) : (i += 1) {
                if (xs.data[i] == 0) {
                    // xs ended
                    return true;
                }

                if (xs.data[i] != key[i]) {
                    return false;
                }
            }

            return true;
        }

        pub fn common_prefix_len(xs: Self, ys: []const u8) usize {
            const l = @min(N, ys.len);
            var i: usize = 0;
            while (i < l) : (i += 1) {
                if (xs.data[i] == 0) {
                    // xs ended
                    return i;
                }

                if (xs.data[i] != ys[i]) {
                    return i;
                }
            }

            return l;
        }

        pub fn assign_from(self: *Self, xs: []const u8) void {
            std.debug.assert(xs.len <= N);
            self.clear();
            @memcpy(self.data[0..xs.len], xs);
        }
    };
}
