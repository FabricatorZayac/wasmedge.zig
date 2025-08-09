const std = @import("std");

extern fn hello(a: i32, b: *i32) void;
extern fn yield() void;
extern fn exfil(val: u32) void;

export fn add(a: i32, b: i32) i32 {
    var bp = b;
    hello(a, &bp);

    // std.log.info("Hello from wasm!", .{});

    return a + bp;
}

export fn suspendable() void {
    var i: usize = 1;
    exfil(i);
    yield();

    i += 2;
    exfil(i);
    yield();

    i += 3;
    exfil(i);
}
