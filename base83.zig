const std = @import("std");
const testing = std.testing;

pub const standard_alphabet_chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~".*;

pub const Codecs = struct {
    alphabet_chars: [83]u8,
    Decoder: Base83Decoder,
};

pub const standard = Codecs{
    .alphabet_chars = standard_alphabet_chars,
    .Decoder = Base83Decoder.init(standard_alphabet_chars),
};

pub const Base83Decoder = struct {
    const Self = @This();
    const invalid_char: u8 = 0xff;

    char_to_index: [256]u8,

    pub fn init(alphabet_chars: [83]u8) Base83Decoder {
        var decoder = Base83Decoder{
            .char_to_index = [_]u8{invalid_char} ** 256,
        };

        var char_in_alphabet = [_]bool{false} ** 256;
        for (alphabet_chars) |c, i| {
            std.debug.assert(!char_in_alphabet[c]);
            decoder.char_to_index[c] = @intCast(u8, i);
            char_in_alphabet[c] = true;
        }
        return decoder;
    }

    pub fn decode(self: *const Self, source: []const u8) error{InvalidCharacter}!i64 {
        var val: i64 = 0;
        for (source) |c| {
            const idx = self.char_to_index[c];
            if (idx == Base83Decoder.invalid_char) {
                return error.InvalidCharacter;
            }
            _ = @mulWithOverflow(i64, val, 83, &val);
            _ = @addWithOverflow(i64, val, @intCast(i64, idx), &val);
        }
        return val;
    }
};

test "standard decode" {
    const codecs = standard;

    var out = try codecs.Decoder.decode("");
    try testing.expectEqual(@intCast(i64, 0), out);
    out = try codecs.Decoder.decode("foobar");
    try testing.expectEqual(@intCast(i64, 163902429697), out);
    out = try codecs.Decoder.decode("LFE.@D9F01_2%L%MIVD*9Goe-;WB");
    try testing.expectEqual(@intCast(i64, -1597651267176502418), out);

    try testing.expectError(error.InvalidCharacter, codecs.Decoder.decode("LFE.@D9F01_2%L%MIVD*9Goe-;Wµ"));
}
