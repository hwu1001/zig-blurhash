const std = @import("std");

pub fn linearTosRBG(value: f64) usize {
    var v = std.math.max(@as(f64, 0), std.math.min(@as(f64, 1), value));
    if (v <= @as(f64, 0.0031308)) {
        v = v * @as(f64, 12.92) * @as(f64, 255) + @as(f64, 0.5);
        return @floatToInt(usize, v);
    }

    v = std.math.pow(f64, v, @as(f64, 1.0 / 2.4));
    v = @as(f64, 1.055) * v - @as(f64, 0.055);
    // @floatToInt() can cause UB, but I'm not sure how to catch it so leave for now
    return @floatToInt(usize, v * @as(f64, 255) + @as(f64, 0.5));
}

pub fn sRGBToLinear(value: usize) f64 {
    var v: f64 = @intToFloat(f64, value) / @as(f64, 255);
    if (v < @as(f64, 0.04045)) {
        return v / @as(f64, 12.92);
    }
    v += @as(f64, 0.055);
    return std.math.pow(f64, v / @as(f64, 1.055), @as(f64, 2.4));
}

pub fn signPow(value: f64, exp: f64) f64 {
    const pow_res = std.math.pow(f64, @fabs(value), exp);
    return std.math.copysign(f64, pow_res, value);
}
