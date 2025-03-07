const std = @import("std");

const tmd = @import("tmd");

const cmd = @import("cmd.zig");

// ToDo:
// * duplicated block IDs
// * ill-formed attribute lines and boundary line attribute lines
// * ...

pub fn vet(args: []const []u8, allocator: std.mem.Allocator) !u8 {
    _ = args;
    _ = allocator;
    try cmd.stdout.print("Not implemented yet.", .{});
    return 1;
}
