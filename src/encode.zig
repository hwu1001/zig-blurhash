const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const test_data = @import("test_data.zig");
const img = @import("img.zig");
const Components = @import("decode.zig").Components;
const base83 = @import("base83.zig");
const base83_codec = base83.standard;
const channel_to_linear = tbl: {
    // the std.math fns used in the img.sRGBToLinear have
    // quite a few branches so adjust branch quota
    @setEvalBranchQuota(100000);
    break :tbl initLinearTable(256);
};

fn initLinearTable(comptime n: usize) [n]f64 {
    var i: usize = 0;
    var table: [n]f64 = undefined;
    while (i < table.len) : (i += 1) {
        table[i] = img.sRGBToLinear(i);
    }
    return table;
}

pub fn encode(
    allocator: Allocator,
    x_components: usize,
    y_components: usize,
    width: usize,
    height: usize,
    rgba: []const u8,
) ![]const u8 {
    if (x_components < 1 or x_components > 9) {
        return error.InvalidComponentValue;
    }
    if (y_components < 1 or y_components > 9) {
        return error.InvalidComponentValue;
    }

    var buffer: [10]u8 = undefined; 
    var blurhash = try std.ArrayList(u8).initCapacity(allocator, (2 + 4 + (9 * 9 - 1) * 2 + 1)); // the max size from the C impl
    defer blurhash.deinit();

    const size_flag: usize = (x_components - 1) + (y_components - 1) * 9;
    var out = try base83_codec.Encoder.encode(buffer[0..], size_flag, 1);
    try blurhash.appendSlice(out);

    // y_components * x_components * 3 - just use max amount possible
    var factors = [_]f64{0} ** (9 * 9 * 3);

    const bytes_per_row: usize = width * 4; // 4 is from rgba
    var yc: usize = 0;
    while (yc < y_components) : (yc += 1) {
        var xc: usize = 0;
        while (xc < x_components) : (xc += 1) {
            var r: f64 = 0;
            var g: f64 = 0;
            var b: f64 = 0;

            var y: usize = 0;
            while (y < height) : (y += 1) {
                var x: usize = 0;
                while (x < width) : (x += 1) {
                    // TODO: Probably should catch the indexing errors that could occur here
                    // n_channels is assumed to be 4 for rgba
                    // n_channels * x + index + y * bytes_per_row
                    const lin_r = channel_to_linear[rgba[4 * x + 0 + y * bytes_per_row]];
                    const lin_g = channel_to_linear[rgba[4 * x + 1 + y * bytes_per_row]];
                    const lin_b = channel_to_linear[rgba[4 * x + 2 + y * bytes_per_row]];

                    const x_basis: f64 = @cos(std.math.pi * @intToFloat(f64, xc) * @intToFloat(f64, x) / @intToFloat(f64, width));
                    const y_basis: f64 = @cos(std.math.pi * @intToFloat(f64, yc) * @intToFloat(f64, y) / @intToFloat(f64, height));
                    const basis = x_basis * y_basis;
                    r += basis * lin_r;
                    g += basis * lin_g;
                    b += basis * lin_b;
                }
            }

            const normalization: f64 = if (xc == 0 and yc == 0) @as(f64, 1) else @as(f64, 2);
            const htw = try std.math.mul(usize, width, height);
            const scale = normalization / @intToFloat(f64, htw);
            // TODO: Probably should catch any indexing/overflow errors here too
            factors[0 + xc * 3 + yc * 3 * x_components] = r * scale;
            factors[1 + xc * 3 + yc * 3 * x_components] = g * scale;
            factors[2 + xc * 3 + yc * 3 * x_components] = b * scale;
        }
    }

    var ac_count: usize = try std.math.mul(usize, x_components, y_components);
    const ac_count_overflow: bool = @subWithOverflow(usize, ac_count, 1, &ac_count);

    var maximum_value: f64 = undefined;
    var quantised_maximum_value: usize = 0;
    if (ac_count_overflow) {
        maximum_value = @as(f64, 1);
        ac_count = 0;
    } else {
        var actual_max_val: f64 = 0.0;
        var i: usize = 0;
        const limit = try std.math.mul(usize, ac_count, 3);
        while (i < limit) : (i += 1) {
            // The index here should never exceed the length in `factors` because
            // of the maximum values of x/y components
            actual_max_val = std.math.max(@fabs(factors[i + 3]), actual_max_val);
        }
        var calc_qmv: f64 = @floor(actual_max_val * @as(f64, 166) - @as(f64, 0.5));
        calc_qmv = std.math.min(@as(f64, 82), calc_qmv);
        const qmv_f = std.math.max(@as(f64, 0), calc_qmv);
        quantised_maximum_value = @floatToInt(usize, qmv_f);
        maximum_value = (qmv_f + 1) / 166;
    }

    out = try base83_codec.Encoder.encode(buffer[0..], quantised_maximum_value, 1);
    try blurhash.appendSlice(out);

    // DC value
    const edc = encodeDC(factors[0], factors[1], factors[2]);
    out = try base83_codec.Encoder.encode(buffer[0..], edc, 4);
    try blurhash.appendSlice(out);


    // AC values
    var i: usize = 0;
    while (i < ac_count) : (i += 1) {
        out = try base83_codec.Encoder.encode(
            buffer[0..],
            encodeAC(
                factors[3 + (i * 3 + 0)],
                factors[3 + (i * 3 + 1)],
                factors[3 + (i * 3 + 2)],
                maximum_value,
            ),
            2,
        );
        try blurhash.appendSlice(out);
    }

    // this can't overflow a usize because max of x/y components is 9
    if (blurhash.items.len != @as(usize, 4 + 2 * x_components * y_components)) {
        return error.InvalidHashLength;
    }

    return blurhash.toOwnedSlice();
}

fn encodeDC(r: f64, g: f64, b: f64) usize {
    var rounded_r = img.linearTosRBG(r);
    var rounded_g = img.linearTosRBG(g);
    var rounded_b = img.linearTosRBG(b);
    // The C/Go implementations don't catch any of the
    // shift left issues. Not sure if they're just guaranteed
    // not to occur based on values? In any case just have
    // overflowed bits get truncated
    rounded_r = std.math.shl(usize, rounded_r, 16);
    rounded_g = std.math.shl(usize, rounded_g, 8);
    return rounded_r + rounded_g + rounded_b;
}

fn encodeAC(r: f64, g: f64, b: f64, max_val: f64) usize {
    // The C/Go implementations just let the multiplication here overflow so
    // doing the same
    var quant_r = quantAC(r, max_val);
    // quant_r * 19 * 19
    _ = @mulWithOverflow(usize, 361, quant_r, &quant_r);
    var quant_g = quantAC(g, max_val);
    _ = @mulWithOverflow(usize, 19, quant_g, &quant_g);
    const quant_b = quantAC(b, max_val);
    return quant_r + quant_g + quant_b;
}

fn quantAC(quant: f64, max_val: f64) usize {
    var v: f64 = @floor(img.signPow(quant / max_val, @as(f64, 0.5)) * @as(f64, 9) + @as(f64, 9.5));
    v = std.math.max(@as(f64, 0), std.math.min(@as(f64, 18), v));
    return @floatToInt(usize, v);
}

test "encode.png_file" {
    const rgba = test_data.test_img;
    const actual = try encode(testing.allocator, 4, 3, 204, 204, rgba[0..]);
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, "LFE.@D9F01_2%L%MIVD*9Goe-;WB", actual);
}

test "encode.empty_image" {
    // "Empty" in this case is an image of 100 x 100 with 0 value for all rgba values
    const rgba = [_]u8{0} ** 40000;
    const actual = try encode(testing.allocator, 4, 3, 100, 100, rgba[0..]);
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, "L00000fQfQfQfQfQfQfQfQfQfQfQ", actual);
}

test "encode.single_color" {
    var rgba: [40000]u8 = undefined;
    var idx: usize = 0;
    const px_color = [_]u8{ 213, 30, 120, 255 };
    var y: usize = 0;
    while (y < 100) : (y += 1) {
        var x: usize = 0;
        while (x < 100) : (x += 1) {
            for (px_color) |c| {
                rgba[idx] = c;
                idx += 1;
            }
        }
    }
    const actual = try encode(testing.allocator, 1, 1, 100, 100, rgba[0..]);
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, "00OZZy", actual);
}

test "encode.invalid_components" {
    const rgba = [_]u8{0} ** 10;
    try testing.expectError(error.InvalidComponentValue, encode(testing.allocator, 0, 1, 100, 100, rgba[0..]));
    try testing.expectError(error.InvalidComponentValue, encode(testing.allocator, 1, 0, 100, 100, rgba[0..]));
    try testing.expectError(error.InvalidComponentValue, encode(testing.allocator, 0, 0, 100, 100, rgba[0..]));
    try testing.expectError(error.InvalidComponentValue, encode(testing.allocator, 10, 1, 100, 100, rgba[0..]));
    try testing.expectError(error.InvalidComponentValue, encode(testing.allocator, 1, 10, 100, 100, rgba[0..]));
    try testing.expectError(error.InvalidComponentValue, encode(testing.allocator, 10, 10, 100, 100, rgba[0..]));
}

test "encode.size_flag" {
    const rgba = [_]u8{0} ** 40000;
    {
        const out = try encode(testing.allocator, 1, 2, 100, 100, rgba[0..]);
        defer testing.allocator.free(out);
        const components = try Components.init(out[0..]);
        try testing.expectEqual(@as(usize, 1), components.x);
        try testing.expectEqual(@as(usize, 2), components.y);
    }
    {
        const out = try encode(testing.allocator, 9, 8, 100, 100, rgba[0..]);
        defer testing.allocator.free(out);
        const components = try Components.init(out[0..]);
        try testing.expectEqual(@as(usize, 9), components.x);
        try testing.expectEqual(@as(usize, 8), components.y);
    }
    {
        const out = try encode(testing.allocator, 5, 4, 100, 100, rgba[0..]);
        defer testing.allocator.free(out);
        const components = try Components.init(out[0..]);
        try testing.expectEqual(@as(usize, 5), components.x);
        try testing.expectEqual(@as(usize, 4), components.y);
    }
    {
        const out = try encode(testing.allocator, 2, 3, 100, 100, rgba[0..]);

        defer testing.allocator.free(out);
        const components = try Components.init(out[0..]);
        try testing.expectEqual(@as(usize, 2), components.x);
        try testing.expectEqual(@as(usize, 3), components.y);
    }
    {
        const out = try encode(testing.allocator, 4, 5, 100, 100, rgba[0..]);
        defer testing.allocator.free(out);
        const components = try Components.init(out[0..]);
        try testing.expectEqual(@as(usize, 4), components.x);
        try testing.expectEqual(@as(usize, 5), components.y);
    }
    {
        const out = try encode(testing.allocator, 7, 3, 100, 100, rgba[0..]);
        defer testing.allocator.free(out);
        const components = try Components.init(out[0..]);
        try testing.expectEqual(@as(usize, 7), components.x);
        try testing.expectEqual(@as(usize, 3), components.y);
    }
}

test "encode.channel_to_linear" {
    const expected = test_data.expected_channel_to_linear;
    try testing.expect(expected.len == channel_to_linear.len);
    const epsilon = 0.000001;
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        try testing.expect(std.math.approxEqAbs(f64, expected[i], channel_to_linear[i], epsilon));
    }
}
