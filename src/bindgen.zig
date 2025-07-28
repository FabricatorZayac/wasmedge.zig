const std = @import("std");

const we = @import("wasmedge.zig");

const c = @cImport(@cInclude("wasmedge/wasmedge.h"));

fn deserializePrimitive(comptime T: type, value: we.Value) T {
    return value.get(switch (@typeInfo(T)) {
        .bool => .I32,
        .@"enum" => |e| we.valTypeGen(e.tag_type).getTypeCode(),
        .float => |f| switch (f.bits) {
            1...32 => .F32,
            33...64 => .F64,
            else => @compileError("Invalid float type"),
        },
        .int => |i| switch (i.bits) {
            1...32 => .I32,
            33...64 => .I64,
            128 => .V128,
            else => @compileError("Invalid int type"),
        },
        else => @compileError("Invalid primitive"),
    });
} 

const PointerDeserializationError = error{MemoryInstanceNotFound, Segfault};

// returns amount of values consumed
fn deserializeStruct(
    comptime T: type,
    out: *T,
    callFrame: we.CallingFrame,
    values: []const we.Value,
) PointerDeserializationError!usize {
    var count: usize = 0;
    inline for (@typeInfo(T).@"struct".fields) |field| {
        count += try deserializeAny(field.type, &@field(out, field.name), callFrame, values[count..]);
    }
    return count;
}

fn deserializeAny(
    comptime T: type,
    out: *T,
    callFrame: we.CallingFrame,
    values: []const we.Value,
) PointerDeserializationError!usize {
    var count: usize = 0;
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            const val = values[count];

            const wasm_ptr = val.get(.I32);

            // terminates wasm execution if no memory found
            // If you have more than one memory, you're not using auto generated bindings anyway
            const memory = callFrame.getMemoryInstance(0) orelse return error.MemoryInstanceNotFound;

            // terminates on segfault
            out.* = memory.getPtr(@intCast(wasm_ptr), ptr.child) orelse return error.Segfault;

            count += 1;
        },
        .@"struct" => {
            count += try deserializeStruct(T, out, callFrame, values[count..]);
        },
        else => {
            out.* = deserializePrimitive(T, values[count]);
            count += 1;
        },
    }
    return count;
}

fn serializePrimitive(v: anytype) we.Value {
    return switch (@typeInfo(@TypeOf(v))) {
        .bool => we.Value.gen(.I32, v),
        .@"enum" => |e| serializePrimitive(e.tag_type),
        .float => |f| switch (f.bits) {
            1...32 => we.Value.gen(.F32, v),
            33...64 => we.Value.gen(.F64, v),
            else => @compileError("Invalid float type"),
        },
        .int => |i| switch (i.bits) {
            1...32 => we.Value.gen(.I32, v),
            33...64 => we.Value.gen(.I64, v),
            128 => we.Value.gen(.V128, v),
            else => @compileError("Invalid int type"),
        },
        else => @compileError("Invalid primitive"),
    };
}

fn serializeStruct(v: anytype, out: []we.Value) usize {
    var count: usize = 0;
    inline for (@typeInfo(@TypeOf(v)).@"struct".fields) |field| {
        count += serializeAny(@field(v, field.name), out);
    }
    return count;
}

fn serializeAny(v: anytype, out: []we.Value) usize {
    var count: usize = 0;

    switch (@typeInfo(@TypeOf(v))) {
        .void => unreachable,
        .pointer => {
            // here be dragons
            @panic("unimplemented");
        },
        .@"struct" => count += serializeStruct(v, out[count..]),
        else => {
            out[count] = serializePrimitive(v);
            count += 1;
        }
    }

    return count;
}

pub fn bindgen(function: anytype) c.WasmEdge_HostFunc_t {
    return (struct {
        fn binding(
            data: ?*anyopaque,
            callFrameCxt: ?*const c.WasmEdge_CallingFrameContext,
            in: [*c]const c.WasmEdge_Value,
            out: [*c]c.WasmEdge_Value,
        ) callconv(.c) c.WasmEdge_Result {
            _ = data;

            var args: std.meta.ArgsTuple(@TypeOf(function)) = undefined;

            const fn_type = we.FunctionType.from_impl(function) catch unreachable;
            const params: []const we.Value = @ptrCast(in[0..fn_type.getParametersLength()]);

            const params_consumed = deserializeAny(@TypeOf(args), &args, we.CallingFrame{ .cxt = callFrameCxt orelse unreachable }, params) catch |err| {
                std.log.err("{s}", .{switch (err) {
                    error.MemoryInstanceNotFound => "No memory in module",
                    error.Segfault => "Memory offset out of bounds",
                }});
                return c.WasmEdge_Result_Terminate;
            };

            if (params_consumed != params.len) {
                @panic("Not all parameters consumed");
            }

            const retval = @call(.auto, function, args);
            const out_length = fn_type.getReturnsLength();

            if (out_length > 0) {
                const returns: []we.Value = @ptrCast(out[0..out_length]);
                const returns_consumed = serializeAny(retval, returns);

                if (returns_consumed != returns.len) {
                    @panic("Not all returns consumed");
                }
            }

            return c.WasmEdge_Result_Success;
        }
    }).binding;
}
