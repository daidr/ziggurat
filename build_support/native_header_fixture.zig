const std = @import("std");
const native_support = @import("native.zig");

// The regression scripts copy this build file, the actual helper and fixture
// into a private build root before changing only its second-level C header.
// Debug keeps the four rebuilds to about a second each; the check is about
// which header changes reach the native object, not about code generation.
pub fn build(b: *std.Build) void {
    const target = b.graph.host;
    const helper = b.createModule(.{ .root_source_file = b.path("fixture/helper.zig"), .target = target, .optimize = .Debug, .link_libc = true });
    const archive = b.option(bool, "archive", "Check an archive member instead of a mandatory native object") orelse false;
    if (archive) {
        _ = native_support.addArchive(b, helper, "header-fixture-native", "fixture/value.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, .Debug);
    } else {
        _ = native_support.add(b, helper, "header-fixture-native", "fixture/value.c", &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" }, target, .Debug);
    }
    const exe = b.addExecutable(.{ .name = "native-header-fixture", .root_module = b.createModule(.{
        .root_source_file = b.path("fixture/main.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{.{ .name = "fixture_helper", .module = helper }},
        .link_libc = true,
    }) });
    b.step("run", "Read the indirect C header value").dependOn(&b.addRunArtifact(exe).step);
}
