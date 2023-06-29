const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Test it");
    b.default_step = test_step;

    const lib_step = b.addSystemCommand(&.{
        "cc",      "-fno-lto", "-fPIC",                  "-shared", "-o",
        "liba.so", "a.c",      "-B../../../zig-out/bin",
    });
    test_step.dependOn(&lib_step.step);

    const exe_step = b.addSystemCommand(&.{
        "cc",                     "-fno-lto", "main.c",
        "-la",                    "-L.",      "-Wl,-rpath,.",
        "-B../../../zig-out/bin",
    });
    exe_step.step.dependOn(&lib_step.step);
    test_step.dependOn(&exe_step.step);

    const run_step = b.addSystemCommand(&.{"./a.out"});
    run_step.expectStdOutEqual("Hello world\n");
    run_step.step.dependOn(&exe_step.step);
    test_step.dependOn(&run_step.step);
}
