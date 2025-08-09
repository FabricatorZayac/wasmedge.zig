const std = @import("std");

const we = @import("wasmedge.zig");

const c = @cImport(@cInclude("wasmedge/wasmedge.h"));
const wasm_bytes = @embedFile("wasm_bin");

const xev = @import("xev");
const libcoro = @import("libcoro");

fn hello(a: i32, b: *i32) void {
    std.log.info("Hello from host! Sum result: {} + {} = {}. Doubling b", .{a, b.*, a + b.*});
    b.* *= 2;
}

pub fn main() !void {
    std.log.info("WasmEdge version: {s}", .{ we.version() });

    const configure = try we.Configure.create();
    defer configure.destroy();

    configure.addHostRegistration(.Wasi);

    const vm = try we.VM.init(configure, null);
    defer vm.deinit();

    const host_mod = try we.ModuleInstance.init("env");
    defer host_mod.deinit();

    const host_fn = try we.FunctionInstance.from_impl(hello, null, 0);
    host_mod.addFunction("hello", host_fn);

    {
        const yield_func_type = try we.FunctionType.init(&.{}, &.{});
        defer yield_func_type.delete();
        const yield_func = try we.FunctionInstance.init(yield_func_type, wasm_yield, null, 0);
        host_mod.addFunction("yield", yield_func);
    }
    var exfil: u32 = undefined;
    {
        const exfil_func_type = try we.FunctionType.init(&.{we.ValType.gen(.I32)}, &.{});
        defer exfil_func_type.delete();
        const exfil_func = try we.FunctionInstance.init(exfil_func_type, wasm_exfil_i32, &exfil, 0);
        host_mod.addFunction("exfil", exfil_func);
    }

    try vm.registerModuleFromImport(host_mod);
    try vm.loadWasmFromBuffer(wasm_bytes);
    try vm.validate();
    try vm.instantiate();
    const params: [2]we.Value = .{
        we.Value.gen(.I32, 123),
        we.Value.gen(.I32, 456),
    };
    var returns: [1]we.Value = undefined;
    try vm.execute("add", &params, &returns);

    std.log.info("Get the result: 123 + 456 * 2 = {}", .{returns[0].get(.I32)});
    std.log.info("TypeCode: {}", .{ params[0].getType().getTypeCode() });

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    var a = gpa.allocator();

    const stack = try libcoro.stackAlloc(a, 1024 * 8);
    defer a.free(stack);

    // try vm.execute("suspendable", &.{}, &.{});
    const frame = try libcoro.xasync(struct {
        fn f(v: we.VM) !void {
            return v.execute("suspendable", &.{}, &.{});
        }
    }.f, .{vm}, stack);
    std.log.info("exfil: {}", .{exfil});
    libcoro.xresume(frame);
    std.log.info("exfil: {}", .{exfil});
    libcoro.xresume(frame);
    std.log.info("exfil: {}", .{exfil});
    try libcoro.xawait(frame);
}

fn wasm_yield(
    data: ?*anyopaque,
    callFrameCxt: ?*const c.WasmEdge_CallingFrameContext,
    in: [*c]const c.WasmEdge_Value,
    out: [*c]c.WasmEdge_Value,
) callconv(.c) c.WasmEdge_Result {
    _ = data;
    _ = callFrameCxt;
    _ = in;
    _ = out;
    libcoro.xsuspend();
    return c.WasmEdge_Result_Success;
}

fn wasm_exfil_i32(
    data: ?*anyopaque,
    callFrameCxt: ?*const c.WasmEdge_CallingFrameContext,
    in: [*c]const c.WasmEdge_Value,
    out: [*c]c.WasmEdge_Value,
) callconv(.c) c.WasmEdge_Result {
    _ = callFrameCxt;
    _ = out;

    const value = we.Value.get(we.Value{ .impl = in[0] }, .I32);
    const target: *u32 = @alignCast(@ptrCast(data orelse unreachable));

    target.* = @intCast(value);

    return c.WasmEdge_Result_Success;
}
