pub const base83 = @import("src/base83.zig");

test {
    @import("std").testing.refAllDecls(@This());
}