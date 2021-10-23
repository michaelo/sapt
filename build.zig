const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    // b.addStaticLibrary("libcurl", "");
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("sapt", "src/main.zig");
    exe.linkSystemLibrary("c");

    exe.setTarget(target);
    // This seems quite hacky, but makes it currently possible to cross-build provided we have prebuilt libcurl.dll/.so/.dylib (and zlib1?)
    // Cross-builds with windows host: always libcurl
    // Cross-builds with WSL host: 
    if(target.isNative()) {
        exe.linkSystemLibrary("libcurl");
    } else {
        std.debug.print("Crossbuilding\n", .{});
        // exe.addIncludeDir("/usr/include/");
        // exe.addLibPath("/usr/include/"); // TODO: Only for linux as host?
        // TODO: Check arch as well to ensure x86_64
        switch(target.getOsTag()) {
            .linux => {
                exe.linkSystemLibrary("libcurl");
                // try exe.lib_paths.resize(0); // Workaround, as linkSystemLibrary adds system link-path, and we want to override this with a custom one
                try exe.lib_paths.insert(0, "xbuild/libs/x86_64-linux");
               
            },
            .macos => {
                exe.linkSystemLibrary("libcurl");
                // try exe.lib_paths.resize(0); // Workaround, as linkSystemLibrary adds system link-path, and we want to override this with a custom one
                try exe.lib_paths.insert(0, "xbuild/libs/x86_64-macos");
            },
            .windows => {
                exe.linkSystemLibrary("libcurl");
                // try exe.lib_paths.resize(0); // Workaround, as linkSystemLibrary adds system link-path, and we want to override this with a custom one
                try exe.lib_paths.insert(0, "xbuild/libs/x86_64-windows");
                // TODO: Copy in zlib1.dll and libcurl.dll to prefix
            },
            else => {
                // Not supported?
                return error.UnsupportedCrossTarget;
            }
        }
    }
    exe.setBuildMode(mode);
    // try exe.lib_paths.resize(0); 
    // exe.addLibPath("xbuild/libs/x86_64-linux");
    // exe.addLibPath("xbuild/libs/x86_64-mac");
    // exe.addLibPath("xbuild/libs/x86_64-windows/lib");
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);


    var all_tests = b.addTest("src/test.zig");
    all_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run default test suite");
    test_step.dependOn(&all_tests.step);
}
