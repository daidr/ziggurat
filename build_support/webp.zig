const std = @import("std");

/// Decoder-only, pinned source build; no configure subprocess or network in build.
pub fn add(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const source = ".deps/libwebp-1.6.0/";
    b.build_root.handle.access(source ++ "src/webp/decode.h", .{}) catch @panic("WebP source missing; run scripts/fetch-webp.ps1 or scripts/fetch-webp.sh first");
    const config = b.addWriteFiles();
    _ = config.add("src/webp/config.h", switch (target.result.cpu.arch) {
        .x86_64 => "#define WEBP_HAVE_SSE2 1\n",
        .aarch64 => "#define WEBP_HAVE_NEON 1\n",
        else => "\n",
    });
    const flags = &.{ "-std=c11", "-DHAVE_CONFIG_H", "-DWEBP_DSP_OMIT_C_CODE=0" };
    // A build-root archive tracks indirect headers for all decoder units.
    // COFF cannot merge multiple C translation units into one object.
    const decoder = b.addLibrary(.{ .name = "images-webp-native", .linkage = .static, .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    module.linkLibrary(decoder);
    const native = decoder.root_module;
    native.addCSourceFile(.{ .file = b.path("src/images/webp.c"), .flags = flags });
    native.addIncludePath(config.getDirectory());
    native.addIncludePath(b.path(source));
    for ([_][]const u8{
        "alpha_dec", "buffer_dec", "frame_dec", "idec_dec", "io_dec", "quant_dec", "tree_dec", "vp8_dec", "vp8l_dec", "webp_dec",
    }) |name| native.addCSourceFile(.{ .file = b.path(b.fmt(source ++ "src/dec/{s}.c", .{name})), .flags = flags });
    for ([_][]const u8{
        "alpha_processing", "cpu", "dec", "dec_clip_tables", "filters", "lossless", "rescaler", "upsampling", "yuv",
    }) |name| native.addCSourceFile(.{ .file = b.path(b.fmt(source ++ "src/dsp/{s}.c", .{name})), .flags = flags });
    const suffix: ?[]const u8 = switch (target.result.cpu.arch) {
        .x86_64 => "sse2",
        .aarch64 => "neon",
        else => null,
    };
    if (suffix) |architecture| for ([_][]const u8{
        "alpha_processing", "dec", "filters", "lossless", "rescaler", "upsampling", "yuv",
    }) |name| native.addCSourceFile(.{ .file = b.path(b.fmt(source ++ "src/dsp/{s}_{s}.c", .{ name, architecture })), .flags = flags });
    for ([_][]const u8{
        "bit_reader_utils", "color_cache_utils", "filters_utils", "huffman_utils", "palette", "quant_levels_dec_utils", "rescaler_utils", "random_utils", "thread_utils", "utils",
    }) |name| native.addCSourceFile(.{ .file = b.path(b.fmt(source ++ "src/utils/{s}.c", .{name})), .flags = flags });
    module.link_libc = true;
    if (target.result.os.tag == .linux) module.linkSystemLibrary("m", .{});
    b.installFile(source ++ "COPYING", "share/ziggurat/libwebp/COPYING");
    b.installFile(source ++ "PATENTS", "share/ziggurat/libwebp/PATENTS");
    b.installFile(source ++ "AUTHORS", "share/ziggurat/libwebp/AUTHORS");
}
