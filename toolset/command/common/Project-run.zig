const std = @import("std");

const AppContext = @import("AppContext.zig");
const Project = @import("Project.zig");


pub fn run(_: *Project, _: *AppContext) !void {
    //project.arenaAllocator = ctx.arenaAllocator;

    std.debug.print("run ...\n", .{});
}
