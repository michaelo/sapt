const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    // b.addStaticLibrary("libcurl", "");
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const tinyregex = b.addStaticLibrary("tiny-regex-c", null);
    tinyregex.setTarget(target);
    tinyregex.setBuildMode(mode);
    tinyregex.linkLibC();
    tinyregex.force_pic = true;
    // tinyregex.addIncludeDir("libs/tiny-regex-c");
    tinyregex.addCSourceFiles(&.{
            "libs/tiny-regex-c/re.c",
        }, &.{
            "-Wall",
            "-W",
            "-Wstrict-prototypes",
            "-Wwrite-strings",
            "-Wno-missing-field-initializers",
        });


    const htregex = b.addStaticLibrary("ht-regex", null);
    htregex.setTarget(target);
    htregex.setBuildMode(mode);
    htregex.linkLibC();
    htregex.force_pic = true;
    htregex.addCSourceFiles(&.{
            "libs/ht-regex/regex.c",
        }, &.{
            "-Wall",
            "-W",
            "-Wstrict-prototypes",
            "-Wwrite-strings",
            "-Wno-missing-field-initializers",
        });


    const exe = b.addExecutable("apitester", "src/main.zig");
    exe.linkSystemLibrary("c");
    
    // exe.initExtraArgs(linkage = exe.Linkage.static);
    exe.linkSystemLibrary("curl"); // TODO: verify if it's statically
    exe.linkLibrary(tinyregex);
    exe.addIncludeDir("libs");
    exe.linkLibrary(htregex);
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    // TODO: Temporary version to support experimental code, and still link anything we want.
    // Should look into executing the actual tests
    const testexe = b.addExecutable("test", "src/test.zig");
    testexe.linkSystemLibrary("c");
    testexe.linkLibrary(tinyregex);
    testexe.addIncludeDir("libs");
    testexe.linkLibrary(htregex);
    testexe.setTarget(target);
    testexe.setBuildMode(mode);
    testexe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);


    const test_cmd = testexe.run();
    test_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        test_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Test the app");
    test_step.dependOn(&test_cmd.step);

}
