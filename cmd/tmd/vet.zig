const std = @import("std");

const tmd = @import("tmd");

const main = @import("main.zig");

// ToDo:
// * duplicated block IDs
// * ill-formed attribute lines and boundary line attribute lines
// * ...

pub fn vet(args: []const []u8, allocator: std.mem.Allocator) !void {
    _ = args;
    _ = allocator;
    try main.stdout.print("Not implemented yet.", .{});
}
