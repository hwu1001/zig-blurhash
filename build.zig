const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();

    const blurhash_tests = b.addTest("blurhash.zig");
    blurhash_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&blurhash_tests.step);
}
