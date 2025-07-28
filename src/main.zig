const std = @import("std");

const we = @import("wasmedge.zig");

const c = @cImport(@cInclude("wasmedge/wasmedge.h"));
const wasm_bytes = @embedFile("wasm_bin");

fn hello(a: i32, b: *i32) void {
    std.log.info("Hello from host! Sum result: {} + {} = {}. Doubling b", .{a, b.*, a + b.*});
    b.* *= 2;
}

pub fn main() !void {
    std.log.info("WasmEdge version: {s}", .{ we.version() });

    const configure = try we.Configure.init();
    defer configure.deinit();

    configure.addHostRegistration(.Wasi);

    const vm = try we.VM.init(configure, null);
    defer vm.deinit();

    const export_name = we.String.ownedFromCString("env");
    defer export_name.delete();

    const host_mod = try we.ModuleInstance.init(export_name);
    defer host_mod.deinit();

    const host_fn = try we.FunctionInstance.from_impl(
        hello,
        0,
    );

    const host_fn_name = we.String.ownedFromCString("hello");
    defer host_fn_name.delete();

    host_mod.addFunction(host_fn_name, host_fn);

    try vm.registerModuleFromImport(host_mod);

    var func_name = we.String.ownedFromCString("add");
    defer func_name.delete();

    const args: [2]we.Value = .{
        we.Value.gen(.I32, 123),
        we.Value.gen(.I32, 456),
    };
    var returns: [1]we.Value = undefined;

    try vm.runWasmFromBuffer(
        wasm_bytes,
        func_name,
        &args,
        &returns,
    );

    std.log.info("Get the result: 123 + 456 * 2 = {}", .{returns[0].get(.I32)});
    std.log.info("TypeCode: {}", .{ args[0].getType().getTypeCode() });
}
