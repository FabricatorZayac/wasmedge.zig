const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wasm = b.addExecutable(.{
        .name = "cart",
        .root_source_file = b.path("src/root.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi }),
        .optimize = .ReleaseSmall,
    });
    wasm.entry = .disabled;
    wasm.root_module.export_symbol_names = &.{ "add", "suspendable" };
    b.installArtifact(wasm);

    const exe = b.addExecutable(.{
        .name = "wasmedge-embed",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkLibC();
    exe.linkSystemLibrary("wasmedge");

    exe.root_module.addAnonymousImport("wasm_bin", .{
        .root_source_file = wasm.getEmittedBin()
    });

    const libxev = b.dependency("libxev", .{}).module("xev");
    exe.root_module.addImport("xev", libxev);

    const libcoro = b.dependency("zigcoro", .{}).module("libcoro");
    exe.root_module.addImport("libcoro", libcoro);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // const wasm_unit_tests = b.addTest(.{
    //     .root_source_file = b.path("src/root.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    //
    // const run_wasm_unit_tests = b.addRunArtifact(wasm_unit_tests);
    //
    // const exe_unit_tests = b.addTest(.{
    //     .root_source_file = b.path("src/main.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    //
    // exe_unit_tests.linkLibC();
    // exe_unit_tests.linkSystemLibrary("wasmedge");
    //
    // const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    //
    // const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&run_wasm_unit_tests.step);
    // test_step.dependOn(&run_exe_unit_tests.step);
}
