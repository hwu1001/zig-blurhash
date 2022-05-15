pub const base83 = @import("src/base83.zig");
pub const decode = @import("src/decode.zig");

test "pkg" {
    @import("std").testing.refAllDecls(@This());
}