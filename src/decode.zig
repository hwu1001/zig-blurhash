const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_data = @import("test_data.zig");
const base83 = @import("base83.zig");
const base83_codec = base83.standard;
const img = @import("img.zig");

const Components = struct {
    x: usize,
    y: usize,

    pub fn init(hash: []const u8) !Components {
        if (hash.len < 6) {
            return error.InvalidHash;
        }

        const size_flag = try base83_codec.Decoder.decode(hash[0..1]);
        // The C and Go impls just let the language do the overflow, but with zig that's
        // a specific choice to overflow and error or not. Doesn't seem worth returning
        // the error since the other implementations don't and it will likely lead to
        // an invalid hash length on overflow anyways
        var y_components: usize = undefined;
        const y_div = size_flag / 9;
        _ = @addWithOverflow(usize, y_div, 1, &y_components);

        var x_components: usize = undefined;
        const x_mod = @mod(size_flag, 9);
        _ = @addWithOverflow(usize, x_mod, 1, &x_components);

        // 4+2*x_components*y_components
        var expected_len: usize = undefined;
        _ = @mulWithOverflow(usize, 2, x_components, &expected_len);
        _ = @mulWithOverflow(usize, expected_len, y_components, &expected_len);
        _ = @addWithOverflow(usize, 4, expected_len, &expected_len);
        if (hash.len != expected_len) {
            return error.InvalidHash;
        }

        return Components{
            .x = x_components,
            .y = y_components,
        };
    }
};

pub fn decode(
    allocator: Allocator,
    hash: []const u8,
    width: usize,
    height: usize,
    punch: usize,
) ![]const u8 {
    const comps = try Components.init(hash);

    const quantised_maximum_value = try base83_codec.Decoder.decode(hash[1..2]);
    const maximum_value: f64 = (@intToFloat(f64, quantised_maximum_value) + @as(f64, 1)) / @as(f64, 166);

    const used_punch: usize = if (punch == 0) 1 else punch;

    // The C/Go implementations just let this overflow, but my guess is that when
    // the number of colors overflows from the multiplication the end result is
    // not a valid blurhash so just return an error in that case
    const num_colors = try std.math.mul(usize, comps.x, comps.y);

    var colors = try std.ArrayList([3]f64).initCapacity(allocator, num_colors);
    defer colors.deinit();
    try buildColors(hash, used_punch, maximum_value, num_colors, &colors);

    // The C implementation has an nChannels parameter, but for now we'll just assume rgba
    // so width * 4. The Go one makes this assumption as well
    const bytes_per_row = try std.math.mul(usize, width, 4);
    const max_buf_size = try std.math.mul(usize, height, bytes_per_row);
    var buf = try std.ArrayList(u8).initCapacity(allocator, max_buf_size);
    defer buf.deinit();

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            var r: f64 = 0.0;
            var g: f64 = 0.0;
            var b: f64 = 0.0;

            var j: usize = 0;
            while (j < comps.y) : (j += 1) {
                var i: usize = 0;
                while (i < comps.x) : (i += 1) {
                    const b_width: f64 = @cos((std.math.pi * @intToFloat(f64, x) * @intToFloat(f64, i)) / @intToFloat(f64, width));
                    const b_height: f64 = @cos((std.math.pi * @intToFloat(f64, y) * @intToFloat(f64, j)) / @intToFloat(f64, height));
                    const basis: f64 = b_width * b_height;

                    // i+j*x_components
                    var color_idx = try std.math.mul(usize, j, comps.x);
                    color_idx = try std.math.add(usize, i, color_idx);
                    if (color_idx >= colors.items.len) {
                        return error.HashOverflow;
                    }

                    const pcolor: [3]f64 = colors.items[color_idx];
                    r += pcolor[0] * basis;
                    g += pcolor[1] * basis;
                    b += pcolor[2] * basis;
                }
            }

            try buf.append(clampToU8(img.linearTosRBG(r)));
            try buf.append(clampToU8(img.linearTosRBG(g)));
            try buf.append(clampToU8(img.linearTosRBG(b)));
            try buf.append(@as(u8, 255));
        }
    }
    return buf.toOwnedSlice();
}

fn decodeDC(value: usize) [3]f64 {
    return [3]f64{
        img.sRGBToLinear(value >> 16), // R
        img.sRGBToLinear((value >> 8) & 255), // G
        img.sRGBToLinear(value & 255), // B
    };
}

fn decodeAC(value: usize, maximum_value: f64) [3]f64 {
    // TODO: In the Go implemention it converts everything to floats and does the arithmetic.
    // In the C one it converts some to floats then back to ints, then to floats again. They
    // both return floats. Not sure if the initial parts for quantR, G, B can just stay integers
    // then only translate to float when calling quantAC() - ?
    const f_val = @intToFloat(f64, value);
    const quant_r = @floor(f_val / @as(f64, 19 * 19));
    const quant_g = @mod(@floor(f_val / @as(f64, 19)), @as(f64, 19));
    const quant_b = @mod(f_val, @as(f64, 19));

    return [3]f64{
        quantAC(quant_r, maximum_value),
        quantAC(quant_g, maximum_value),
        quantAC(quant_b, maximum_value),
    };
}

fn quantAC(quant: f64, max_val: f64) f64 {
    const v = (quant - @as(f64, 9)) / @as(f64, 9);
    return img.signPow(v, @as(f64, 2.0)) * max_val;
}

fn buildColors(hash: []const u8, punch: usize, max_val: f64, num_colors: usize, colors: *std.ArrayList([3]f64)) !void {
    var i: usize = 0;
    while (i < num_colors) : (i += 1) {
        if (i == 0) {
            const val = try base83_codec.Decoder.decode(hash[2..6]);
            try colors.append(decodeDC(val));
        } else {
            // C/Go implementions just let these overflow, but
            // since they're used to find indices on the input `hash`
            // slice I don't think it works correctly if they overflow.
            // e.g., the lower bound doesn't overflow but the upper bound
            // does. Not sure if that's possible with given inputs but
            // if it did happen pretty sure the decoding wouldn't be right
            var lower = try std.math.mul(usize, i, 2);
            lower = try std.math.add(usize, lower, 4);

            var upper = try std.math.mul(usize, i, 2);
            upper = try std.math.add(usize, upper, 6);

            const val = try base83_codec.Decoder.decode(hash[lower..upper]);
            try colors.append(decodeAC(val, max_val * @intToFloat(f64, punch)));
        }
    }
    return;
}

fn clampToU8(src: usize) u8 {
    if (src <= 255) {
        return @intCast(u8, src);
    }
    return 255;
}

test "decode" {
    const out = try decode(testing.allocator, "LFE.@D9F01_2%L%MIVD*9Goe-;WB", 204, 204, 1);
    defer testing.allocator.free(out);
    try testing.expect(test_data.expected_decode.len == out.len);
    try testing.expectEqualSlices(u8, test_data.expected_decode[0..], out[0..]);

    const single_color = try decode(testing.allocator, "00OZZy", 1, 1, 0);
    defer testing.allocator.free(single_color);
    var expected = [_]u8{ 213, 30, 120, 255 };
    try testing.expectEqualSlices(u8, expected[0..], single_color[0..]);
}

test "decode.invalid" {
    const Case = struct {
        hash: []const u8,
        expected_err: anyerror,
    };
    const cases = [_]Case{
        Case{
            .hash = "00OZZy1",
            .expected_err = error.InvalidHash,
        },
        Case{
            .hash = "\x000OZZy",
            .expected_err = base83.Error.InvalidCharacter,
        },
        Case{
            .hash = "0\x00OZZy",
            .expected_err = base83.Error.InvalidCharacter,
        },
        Case{
            .hash = "00\x00ZZy",
            .expected_err = base83.Error.InvalidCharacter,
        },
        Case{
            .hash = "00O\x00Zy",
            .expected_err = base83.Error.InvalidCharacter,
        },
        Case{
            .hash = "00OZ\x00y",
            .expected_err = base83.Error.InvalidCharacter,
        },
        Case{
            .hash = "00OZZ\x00",
            .expected_err = base83.Error.InvalidCharacter,
        },
        Case{
            .hash = "LFE.@D\x00F01_2%L%MIVD*9Goe-;WB",
            .expected_err = base83.Error.InvalidCharacter,
        },
    };

    for (cases) |c| {
        try testing.expectError(
            c.expected_err,
            decode(testing.allocator, c.hash, 32, 32, 1),
        );
    }
}

test "components" {
    var c = try Components.init("LFE.@D9F01_2%L%MIVD*9Goe-;WB");
    try testing.expectEqual(@as(usize, 4), c.x);
    try testing.expectEqual(@as(usize, 3), c.y);

    try testing.expectError(error.InvalidHash, Components.init("12345"));
    try testing.expectError(error.InvalidHash, Components.init("LFE.@D9F"));
}

test "buildColors" {
    const max_val: f64 = 9.63855421686747e-02;
    const num_colors: usize = 12;
    var colors = try std.ArrayList([3]f64).initCapacity(testing.allocator, num_colors);
    defer colors.deinit();

    try buildColors("LFE.@D9F01_2%L%MIVD*9Goe-;WB", 1, max_val, num_colors, &colors);
    try testing.expect(test_data.expected_colors.len == colors.items.len);
    var i: usize = 0;
    while (i < test_data.expected_colors.len) : (i += 1) {
        try testing.expectEqualSlices(f64, test_data.expected_colors[i][0..], colors.items[i][0..]);
    }
}
