const std = @import("std");

const bindgen = @import("bindgen.zig").bindgen;

const c = @cImport(@cInclude("wasmedge/wasmedge.h"));
pub fn version() [*:0]const u8 {
    return c.WasmEdge_VersionGet();
}

// should probably move to bindgen
fn valTypeGen(comptime T: type) ValType {
    return ValType.gen(switch (@typeInfo(T)) {
        .bool => .I32,
        .@"enum" => |e| return valTypeGen(e.tag_type),
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
        .pointer => |p| switch (p.size) {
            .slice => @compileError("Slice not allowed"),
            else => .I32,
        },
        else => @compileError("Invalid primitive"),
    });
}
fn structToValTypes(comptime T: type, list: *std.ArrayList(ValType)) !void {
    if (@typeInfo(T) != .@"struct") {
        @compileError("Type is not a struct");
    }

    inline for(@typeInfo(T).@"struct".fields) |field| {
        try switch (@typeInfo(field.type)) {
            .@"struct" => structToValTypes(field.type, list),
            .void => return,
            else => list.append(valTypeGen(field.type)),
        };
    }
}

// Wrapper types

pub const Async = struct {
    impl: *c.WasmEdge_Async,

    const Self = @This();

    fn wrap(impl: ?*c.WasmEdge_Async) Self {
        return Self{ .impl = impl.? };
    }
    pub fn delete(self: Self) void {
        c.WasmEdge_AsyncDelete(self.impl);
    }

    pub fn cancel(self: Self) void {
        c.WasmEdge_AsyncCancel(self.impl);
    }
    pub fn wait(self: Self) void {
        c.WasmEdge_AsyncWait(self.impl);
    }
};

pub const Configure = struct {
    cxt: *c.WasmEdge_ConfigureContext,

    const Self = @This();

    pub fn create() error{ConfigureInitFail}!Self {
        return Self{ .cxt = c.WasmEdge_ConfigureCreate() orelse return error.ConfigureInitFail };
    }

    pub fn destroy(self: Self) void {
        c.WasmEdge_ConfigureDelete(self.cxt);
    }

    pub fn addHostRegistration(self: Self, host: HostRegistration) void {
        c.WasmEdge_ConfigureAddHostRegistration(self.cxt, @intFromEnum(host));
    }
};

pub const CallingFrame = struct {
    cxt: *const c.WasmEdge_CallingFrameContext,

    const Self = @This();

    fn wrap(cxt: ?*const c.WasmEdge_CallingFrameContext) Self {
        return Self{ .cxt = cxt orelse @panic("Where did you even get a null callFrame?") };
    }

    pub fn getModuleInstance(self: Self) ModuleInstance {
        return ModuleInstance.wrap(c.WasmEdge_CallingFrameGetModuleInstance(self.cxt).?);
    }

    pub fn getMemoryInstance(self: Self, idx: u32) ?MemoryInstance {
        return MemoryInstance.wrap(c.WasmEdge_CallingFrameGetMemoryInstance(self.cxt, idx) orelse return null);
    }
};

pub const FunctionInstance = struct {
    cxt: *c.WasmEdge_FunctionInstanceContext,

    const Self = @This();
    const Error = error{FunctionInstanceInitFail};

    pub fn init(
        fn_type: FunctionType,
        host_func: c.WasmEdge_HostFunc_t,
        data: ?*anyopaque,
        cost: u64,
    ) Self.Error!Self {
        // const func_type = FunctionType.init(param_list: ?[]const ValType, return_list: ?[]const ValType)
        return Self{
            .cxt = c.WasmEdge_FunctionInstanceCreate(
                fn_type.ctx,
                host_func,
                data,
                cost,
            ) orelse return error.FunctionInstanceInitFail,
        };
    }

    pub fn delete(self: Self) void {
        c.WasmEdge_FunctionInstanceDelete(self.cxt);
    }

    pub fn from_impl(function: anytype, data: ?*anyopaque, cost: u64) !Self {
        const fn_type = try FunctionType.from_impl(function);
        defer fn_type.delete();
        
        return init(
            fn_type,
            bindgen(function),
            data,
            cost,
        );
    }
};

pub const FunctionType = struct {
    ctx: *c.WasmEdge_FunctionTypeContext,

    const Self = @This();
    const Error = error{FunctionTypeInitFail};

    pub fn init(param_list: []const ValType, return_list: []const ValType) Self.Error!Self {
        return Self{
            .ctx = c.WasmEdge_FunctionTypeCreate(
                if (param_list.len != 0) @ptrCast(param_list.ptr) else null,
                @intCast(param_list.len),
                if (return_list.len != 0) @ptrCast(return_list.ptr) else null,
                @intCast(return_list.len),
            ) orelse return error.FunctionTypeInitFail,
        };
    }

    pub fn delete(self: Self) void {
        c.WasmEdge_FunctionTypeDelete(self.ctx);
    }

    pub fn from_impl(function: anytype) !Self {
        const fn_type = @typeInfo(@TypeOf(function)).@"fn";

        if (fn_type.is_generic) {
            @compileError("Can't export generic function");
        }

        var param_list = std.ArrayList(ValType).init(std.heap.page_allocator);
        defer param_list.deinit();
        try structToValTypes(std.meta.ArgsTuple(@TypeOf(function)), &param_list);

        var ret_list = std.ArrayList(ValType).init(std.heap.page_allocator);
        defer ret_list.deinit();
        try structToValTypes(struct { @typeInfo(@TypeOf(function)).@"fn".return_type.? }, &ret_list);

        return init(param_list.items, ret_list.items);
    }

    pub fn getParameters(self: Self, list: []ValType) u32 {
        return c.WasmEdge_FunctionTypeGetParameters(self.ctx, @ptrCast(list.ptr), list.len);
    }
    pub fn getParametersLength(self: Self) u32 {
        return c.WasmEdge_FunctionTypeGetParametersLength(self.ctx);
    }

    pub fn getReturns(self: Self, list: []ValType) u32 {
        return c.WasmEdge_FunctionTypeGetReturns(self.ctx, @ptrCast(list.ptr), list.len);
    }
    pub fn getReturnsLength(self: Self) u32 {
        return c.WasmEdge_FunctionTypeGetReturnsLength(self.ctx);
    }
};

pub const MemoryInstance = struct {
    cxt: *c.WasmEdge_MemoryInstanceContext,

    const Self = @This();

    fn wrap(cxt: *c.WasmEdge_MemoryInstanceContext) Self {
        return Self{ .cxt = cxt };
    }

    // returns host pointer into wasm memory
    pub fn getPtr(self: Self, offset: u32, comptime T: type) ?*T {
        return @alignCast(@ptrCast(c.WasmEdge_MemoryInstanceGetPointer(self.cxt, offset, @sizeOf(T))));
    }
};

pub const ModuleInstance = struct {
    cxt: *c.WasmEdge_ModuleInstanceContext,

    const Self = @This();

    pub fn wrap(cxt: *c.WasmEdge_ModuleInstanceContext) Self {
        return Self{ .cxt = cxt };
    }

    pub fn init(name: [*:0]const u8) error{ModuleInstanceInitFail}!Self {
        const mod_name = String.ownedFromCString(name);
        defer mod_name.delete();
        return Self{
            .cxt = c.WasmEdge_ModuleInstanceCreate(mod_name.impl) orelse return error.ModuleInstanceInitFail,
        };
    }

    pub fn deinit(self: Self) void {
        c.WasmEdge_ModuleInstanceDelete(self.cxt);
    }

    pub fn addFunction(self: Self, name: [*:0]const u8, func_instance: FunctionInstance) void {
        const func_name = String.ownedFromCString(name);
        defer func_name.delete();
        c.WasmEdge_ModuleInstanceAddFunction(self.cxt, func_name.impl, func_instance.cxt);
    }
};

pub const Store = struct {
    ctx: c.WasmEdge_StoreContext,

    const Self = @This();

    pub fn init() error{StoreInitFail}!Self {
        return Self{ .ctx = c.WasmEdge_StoreCreate() orelse return error.StoreInitFail };
    }
    pub fn deinit(self: Self) void {
        c.WasmEdge_StoreDelete(self.ctx);
    }

    pub fn findModule(self: Self, name: String) ?ModuleInstance {
        return c.WasmEdge_StoreFindModule(self.ctx, name.impl);
    }
};

pub const String = struct {
    impl: c.WasmEdge_String,

    const Self = @This();

    pub fn delete(self: *const Self) void {
        c.WasmEdge_StringDelete(self.impl);
    }

    pub fn ownedFromCString(cstr: [*:0]const u8) Self {
        return Self{ .impl = c.WasmEdge_StringCreateByCString(cstr) };
    }
};

pub const ValType = struct {
    impl: c.WasmEdge_ValType,

    const Self = @This();

    pub fn gen(typecode: TypeCode) Self {
        return Self{ .impl = switch (typecode) {
            .I32 => c.WasmEdge_ValTypeGenI32(),
            .I64 => c.WasmEdge_ValTypeGenI64(),
            .F32 => c.WasmEdge_ValTypeGenF32(),
            .F64 => c.WasmEdge_ValTypeGenF64(),
            .V128 => c.WasmEdge_ValTypeGenV128(),

            .FuncRef => c.WasmEdge_ValTypeGenFuncRef(),
            .ExternRef => c.WasmEdge_ValTypeGenExternRef(),

            else => @panic("Invalid ValTypeGen"),
        } };
    }

    pub fn is(self: Self, typecode: TypeCode) bool {
        return switch (typecode) {
            .I32 => c.WasmEdge_ValTypeIsI32(self.impl),
            .I64 => c.WasmEdge_ValTypeIsI64(self.impl),
            .F32 => c.WasmEdge_ValTypeIsF32(self.impl),
            .F64 => c.WasmEdge_ValTypeIsF64(self.impl),
            .V128 => c.WasmEdge_ValTypeIsV128(self.impl),

            .FuncRef => c.WasmEdge_ValTypeIsFuncRef(self.impl),
            .ExternRef => c.WasmEdge_ValTypeIsExternRef(self.impl),

            .Ref => c.WasmEdge_ValTypeIsRef(self.impl),
            .RefNull => c.WasmEdge_ValTypeIsRefNull(self.impl),

            else => @panic("Invalid ValType"),
        };
    }

    pub fn getTypeCode(self: Self) TypeCode {
        return @enumFromInt(self.impl.Data[2]);
    }
};

pub const Value = struct {
    impl: c.WasmEdge_Value,

    const Self = @This();

    pub fn gen(comptime typecode: TypeCode, value: anytype) Self {
        return Self{ .impl = switch (typecode) {
            .I32 => c.WasmEdge_ValueGenI32(value),
            .I64 => c.WasmEdge_ValueGenI64(value),
            .F32 => c.WasmEdge_ValueGenF32(value),
            .F64 => c.WasmEdge_ValueGenF64(value),
            .V128 => c.WasmEdge_ValueGenV128(value),
            .FuncRef => c.WasmEdge_ValueGenFuncRef(value),
            .ExternRef => c.WasmEdge_ValueGenExternRef(value),
            else => @panic("Invalied ValueGen"),
        } };
    }

    pub fn get(self: Self, comptime typecode: TypeCode) switch(typecode) {
        .I32 => i32,
        .I64 => i64,
        .F32 => f32,
        .F64 => f64,
        .V128 => i128,
        .FuncRef => FunctionInstance,
        .ExternRef => ?*anyopaque,
        else => @compileError("Invalid ValueGet"),
    } {
        return switch (typecode) {
            .I32 => c.WasmEdge_ValueGetI32(self.impl),
            .I64 => c.WasmEdge_ValueGetI64(self.impl),
            .F32 => c.WasmEdge_ValueGetF32(self.impl),
            .F64 => c.WasmEdge_ValueGetF64(self.impl),
            .V128 => c.WasmEdge_ValueGetV128(self.impl),
            .FuncRef => c.WasmEdge_ValueGetFuncRef(self.impl),
            .ExternRef => c.WasmEdge_ValueGetExternRef(self.impl),
            else => @compileError("Invalied ValueGet"),
        };
    }

    pub fn getType(self: Self) ValType {
        return ValType{ .impl = self.impl.Type };
    }
};

pub const VM = struct {
    cxt: *c.WasmEdge_VMContext,

    const Self = @This();

    pub fn init(
        conf: ?Configure,
        store_cxt: ?*c.WasmEdge_StoreContext,
    ) error{VMInitFail}!Self {
        return Self{
            .cxt = c.WasmEdge_VMCreate(
                if (conf) |con| con.cxt else null,
                store_cxt,
            ) orelse return error.VMInitFail,
        };
    }
    pub fn deinit(self: Self) void {
        c.WasmEdge_VMDelete(self.cxt);
    }

    pub fn execute(
        self: Self,
        funcName: [*:0]const u8,
        params: []const Value,
        returns: []Value,
    ) !void {
        const func_name = String.ownedFromCString(funcName);
        defer func_name.delete();
        try mapErr(c.WasmEdge_VMExecute(
            self.cxt,
            func_name.impl,
            @ptrCast(params.ptr),
            @intCast(params.len),
            @ptrCast(returns.ptr),
            @intCast(returns.len),
        ));
    }

    pub fn instantiate(self: Self) !void {
        try mapErr(c.WasmEdge_VMInstantiate(self.cxt));
    }

    pub fn loadWasmFromBuffer(self: Self, buf: []const u8) !void {
        try mapErr(c.WasmEdge_VMLoadWasmFromBuffer(self.cxt, buf.ptr, @intCast(buf.len)));
    }
    pub fn loadWasmFromFile(self: Self, path: []const u8) !void {
        try mapErr(c.WasmEdge_VMLoadWasmFromFile(self.cxt, path));
    }

    pub fn registerModuleFromImport(self: Self, import_mod: ModuleInstance) !void {
        try mapErr(c.WasmEdge_VMRegisterModuleFromImport(self.cxt, import_mod.cxt));
    }

    pub fn asyncRunWasmFromBuffer(
        self: Self,
        buf: []const u8,
        funcName: [*:0]const u8,
        params: []const Value,
    ) Async {
        const func_name = String.ownedFromCString(funcName);
        defer func_name.delete();
        return Async.wrap(c.WasmEdge_VMAsyncRunWasmFromBuffer(
            self.cxt,
            buf.ptr,
            @intCast(buf.len),
            func_name.impl,
            @ptrCast(params.ptr),
            @intCast(params.len),
        ));
    }
    pub fn runWasmFromBuffer(
        self: Self,
        buf: []const u8,
        funcName: [*:0]const u8,
        params: []const Value,
        returns: []Value,
    ) !void {
        const func_name = String.ownedFromCString(funcName);
        defer func_name.delete();
        try mapErr(c.WasmEdge_VMRunWasmFromBuffer(
            self.cxt,
            buf.ptr,
            @intCast(buf.len),
            func_name.impl,
            @ptrCast(params.ptr),
            @intCast(params.len),
            @ptrCast(returns.ptr),
            @intCast(returns.len),
        ));
    }
    pub fn runWasmFromFile(
        self: Self,
        path: []const u8,
        funcName: [*:0]const u8,
        params: []const Value,
        returns: []Value,
    ) !void {
        const func_name = String.ownedFromCString(funcName);
        defer func_name.delete();
        try mapErr(c.WasmEdge_VMRunWasmFromFile(
            self.cxt,
            path.ptr,
            @intCast(path.len),
            func_name.impl,
            @ptrCast(params.ptr),
            @intCast(params.len),
            @ptrCast(returns.ptr),
            @intCast(returns.len),
        ));
    }

    pub fn validate(self: Self) !void {
        try mapErr(c.WasmEdge_VMValidate(self.cxt));
    }
};

// meta internals

const ErrCode = EnumFromC(c, "WasmEdge_ErrCode");
const Error = GenError();
const errMap = genErrorMap();
fn GenError() type {
    const enumFields = @typeInfo(ErrCode).@"enum".fields;
    comptime var errorset: [enumFields.len - 1]std.builtin.Type.Error = undefined;

    inline for (enumFields, 0..) |field, i| {
        if (i == 0) { continue; }
        errorset[i - 1] = .{ .name = field.name };
    }
    return @Type(.{ .error_set = errorset[0..enumFields.len - 1] });
}
fn genErrorMap() std.EnumMap(ErrCode, Error) {
    var errmap = std.EnumMap(ErrCode, Error){};

    inline for (@typeInfo(Error).error_set.?) |err| {
        @setEvalBranchQuota(10000);
        errmap.put(@field(ErrCode, err.name), @field(Error, err.name));
    }

    return errmap;
}
fn mapErr(res: c.WasmEdge_Result) !void {
    const status: ErrCode = @enumFromInt(res.Code);
    return errMap.get(status) orelse {};
}

const TypeCode = EnumFromC(c, "WasmEdge_TypeCode");
const HostRegistration = EnumFromC(c, "WasmEdge_HostRegistration");

fn EnumFromC(
    comptime import: anytype,
    comptime prefix: []const u8,
) type {
    comptime var enum_fields: [1024]std.builtin.Type.EnumField = undefined;
    comptime var count = 0;

    inline for (std.meta.declarations(import)) |decl| {
        if (decl.name.len < prefix.len + 1) {
            continue;
        }

        @setEvalBranchQuota(10000);
        if (std.mem.eql(u8, decl.name[0..prefix.len], prefix)) {
            enum_fields[count] = .{
                .name = decl.name[prefix.len + 1 ..],
                .value = @field(import, decl.name),
            };
            count += 1;
        }
    }

    return @Type(.{ .@"enum" = .{
        .tag_type = @field(import, "enum_" ++ prefix),
        .fields = enum_fields[0..count],
        .decls = &.{},
        .is_exhaustive = true,
    } });
}
