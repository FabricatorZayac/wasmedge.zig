const std = @import("std");

extern fn hello(a: i32, b: *i32) void;

export fn add(a: i32, b: i32) i32 {
    var bp = b;
    hello(a, &bp);

    // std.log.info("Hello from wasm!", .{});

    return a + bp;
}
