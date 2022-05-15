const std = @import("std");
const testing = std.testing;

pub const Error = error{
    InvalidCharacter,
};

pub const standard_alphabet_chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~".*;

pub const Codecs = struct {
    alphabet_chars: [83]u8,
    Encoder: Base83Encoder,
    Decoder: Base83Decoder,
};

pub const standard = Codecs{
    .alphabet_chars = standard_alphabet_chars,
    .Encoder = Base83Encoder.init(standard_alphabet_chars),
    .Decoder = Base83Decoder.init(standard_alphabet_chars),
};

pub const Base83Encoder = struct {
    const Self = @This();

    alphabet_chars: [83]u8,

    pub fn init(alphabet_chars: [83]u8) Base83Encoder {
        std.debug.assert(alphabet_chars.len == 83);
        var char_in_alphabet = [_]bool{false} ** 256;
        for (alphabet_chars) |c| {
            std.debug.assert(!char_in_alphabet[c]);
            char_in_alphabet[c] = true;
        }
        return Base83Encoder{
            .alphabet_chars = alphabet_chars,
        };
    }

    pub fn encode(self: *const Self, dest: []u8, value: usize, length: usize) ![]const u8 {
        std.debug.assert(dest.len >= length);

        var divisor: usize = 1;
        var i: usize = 0;
        while (length > 0 and i < length - 1) {
            _ = @mulWithOverflow(usize, divisor, 83, &divisor);
            i += 1;
        }

        i = 0;
        while (i < length) {
            const d = try std.math.divFloor(usize, value, divisor);
            const index = try std.math.mod(usize, d, 83);
            divisor = try std.math.divFloor(usize, divisor, 83);

            dest[i] = self.alphabet_chars[index];
            i += 1;
        }
        return dest[0..length];
    }
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

    pub fn decode(self: *const Self, source: []const u8) error{InvalidCharacter}!usize {
        var val: usize = 0;
        for (source) |c| {
            const idx = self.char_to_index[c];
            if (idx == Base83Decoder.invalid_char) {
                return error.InvalidCharacter;
            }
            _ = @mulWithOverflow(usize, val, 83, &val);
            _ = @addWithOverflow(usize, val, @intCast(usize, idx), &val);
        }
        return val;
    }
};

test "standard encode" {
    const codecs = standard;
    var dest = [_]u8{0} ** 100;
    var out = try codecs.Encoder.encode(dest[0..], 0, 0);
    try testing.expectEqualSlices(u8, "", out);

    out = try codecs.Encoder.encode(dest[0..], 163902429697, 6);
    try testing.expectEqualSlices(u8, "foobar", out);

    out = try codecs.Encoder.encode(dest[0..], 100, 2);
    try testing.expectEqualSlices(u8, "1H", out);
}

test "standard decode" {
    const codecs = standard;

    var out = try codecs.Decoder.decode("");
    try testing.expectEqual(@intCast(usize, 0), out);
    out = try codecs.Decoder.decode("foobar");
    try testing.expectEqual(@intCast(usize, 163902429697), out);
    out = try codecs.Decoder.decode("LFE.@D9F01_2%L%MIVD*9Goe-;WB");
    try testing.expectEqual(@intCast(usize, 16849092806533049198), out);

    try testing.expectError(error.InvalidCharacter, codecs.Decoder.decode("LFE.@D9F01_2%L%MIVD*9Goe-;Wµ"));
}
