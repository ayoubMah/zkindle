const std = @import("std");

// zkindle: a tiny, fast home screen for a jailbroken Kindle, written in Zig.
//
// Drawing goes through FBInk (github.com/NiLuJe/FBInk), compiled from source by
// this build script. FBInk knows the refresh ioctls for every Kindle generation
// (i.MX mxcfb on older models, MediaTek hwtcon on PW5+), so we don't have to.
//
//   zig build                       -> Kindle build (static musl, ARMv7 hard-float)
//   zig build -Dplatform=linux      -> generic Linux framebuffer build (handy for testing)
//   zig build package               -> zig-out/zkindle-kual.zip ready to drop in /mnt/us/extensions

const Platform = enum { kindle, linux };

pub fn build(b: *std.Build) void {
    const platform = b.option(Platform, "platform", "FBInk target platform (default: kindle)") orelse .kindle;

    // Default target: every Kindle since ~2013 is ARMv7 (Cortex-A9 / A7 / A53 in 32-bit mode).
    // Cortex-A9 is the lowest common denominator, so code built for it runs on all of them.
    // Static musl means no dependency on the Kindle's glibc version, and it doesn't matter
    // whether your firmware is the older soft-float (armel) or newer hard-float (5.16.3+) userland.
    const target = b.standardTargetOptions(.{
        .default_target = if (platform == .kindle) .{
            .cpu_arch = .arm,
            .os_tag = .linux,
            .abi = .musleabihf,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a9 },
        } else .{},
    });
    // Default to ReleaseSmall: the Kindle has little RAM/flash and we want a tiny binary.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode (default: ReleaseSmall)") orelse .ReleaseSmall;

    const fbink_dir = b.path("vendor/FBInk");
    const fbink_defs = [_][]const u8{
        if (platform == .kindle) "FBINK_FOR_KINDLE" else "FBINK_FOR_LINUX",
        "FBINK_WITH_DRAW",
        "FBINK_WITH_BITMAP",
        "FBINK_WITH_IMAGE",
        "FBINK_WITH_OPENTYPE",
        "FBINK_WITH_INPUT",
    };

    // ---- FBInk as a static library -------------------------------------------------
    const fbink_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    for (fbink_defs) |d| fbink_mod.addCMacro(d, "1");
    fbink_mod.addCMacro("_GNU_SOURCE", "1");
    fbink_mod.addCMacro("_REENTRANT", "1");
    fbink_mod.addCMacro("NDEBUG", "1");
    fbink_mod.addCMacro("FBINK_VERSION", "\"zkindle-vendored\"");
    fbink_mod.addIncludePath(fbink_dir);
    fbink_mod.addCSourceFiles(.{
        .root = fbink_dir,
        .files = &.{
            "fbink.c",
            "fbink_input_scan.c",
            "cutef8/utf8.c",
            "cutef8/dfa.c",
            "qimagescale/qimagescale.c",
            "libunibreak/src/linebreak.c",
            "libunibreak/src/linebreakdata.c",
            "libunibreak/src/linebreakdef.c",
            "libunibreak/src/unibreakdef.c",
            "libunibreak/src/eastasianwidthdef.c",
            "libunibreak/src/eastasianwidthdata.c",
            "libunibreak/src/emojidef.c",
            "libunibreak/src/emojidata.c",
        },
        .flags = &.{ "-std=gnu11", "-fno-sanitize=undefined", "-Wno-everything" },
    });
    const fbink = b.addLibrary(.{ .name = "fbink", .linkage = .static, .root_module = fbink_mod });

    // ---- zkindle -------------------------------------------------------------------
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .Debug,
        .single_threaded = true,
    });
    for (fbink_defs) |d| exe_mod.addCMacro(d, "1");
    exe_mod.addIncludePath(fbink_dir);
    exe_mod.linkLibrary(fbink);

    const exe = b.addExecutable(.{ .name = "zkindle", .root_module = exe_mod });
    if (target.result.os.tag == .linux and target.result.abi.isMusl()) exe.linkage = .static;
    b.installArtifact(exe);

    // ---- tests: the pure parts (config parser, widget logic) run on the host ----------
    const test_step = b.step("test", "Run unit tests on the host");
    for ([_][]const u8{ "src/config.zig", "src/widgets.zig" }) |file| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(file),
            .target = b.graph.host,
        }) });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ---- package: zig-out/zkindle/ + zig-out/zkindle.tar.gz -------------------------
    // Copy zkindle/ to /mnt/us/zkindle on the Kindle (or scp the tarball and untar it there),
    // then run `sh /mnt/us/zkindle/install.sh` once.
    const pkg = b.step("package", "Build zig-out/zkindle.tar.gz (untar into /mnt/us on the Kindle, then run install.sh)");
    const stage = b.addWriteFiles();
    _ = stage.addCopyDirectory(b.path("device/zkindle"), "zkindle", .{});
    _ = stage.addCopyFile(exe.getEmittedBin(), "zkindle/bin/zkindle");
    _ = stage.addCopyFile(b.path("assets/fonts/IBMPlexMono-Regular.ttf"), "zkindle/fonts/IBMPlexMono-Regular.ttf");
    _ = stage.addCopyFile(b.path("assets/fonts/IBMPlexMono-Bold.ttf"), "zkindle/fonts/IBMPlexMono-Bold.ttf");
    _ = stage.addCopyFile(b.path("assets/fonts/OFL.txt"), "zkindle/fonts/OFL.txt");

    // bsdtar ships with Windows 10+, so this works from PowerShell too.
    const tar = b.addSystemCommand(&.{ "tar", "-czf" });
    const tar_out = tar.addOutputFileArg("zkindle.tar.gz");
    tar.addArg("-C");
    tar.addDirectoryArg(stage.getDirectory());
    tar.addArg("zkindle");
    pkg.dependOn(&b.addInstallFile(tar_out, "zkindle.tar.gz").step);
    pkg.dependOn(&b.addInstallDirectory(.{
        .source_dir = stage.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "",
    }).step);
}
