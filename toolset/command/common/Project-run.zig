const std = @import("std");

const AppContext = @import("AppContext.zig");
const Project = @import("Project.zig");

pub fn run(project: *Project, ctx: *AppContext) !void {
    _ = project;
    _ = ctx;
    std.debug.print("run ...\n", .{});
}