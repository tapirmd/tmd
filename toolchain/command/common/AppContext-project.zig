const std = @import("std");

const AppContext = @import("AppContext.zig");
const Project = @import("Project.zig");
const util = @import("util.zig");

pub fn regOrGetProject(ctx: *AppContext, dirOrConfigPath: []const u8, comptime buildTarget: std.meta.FieldEnum(Project.BuildTarget)) !union(enum) { registered: *Project, new: *Project } {
    const path = blk: {
        var pa: util.PathAllocator = .{};
        const path = try util.resolvePathFromAbsDirPathAlloc(".", dirOrConfigPath, true, pa.allocator());
        //defer ctx.allocator.free(path);
        break :blk try util.resolveRealPathAlloc(ctx.io, path, false, ctx.arenaAllocator);
    };

    const isDir = blk: {
        const stat = std.Io.Dir.cwd().statFile(ctx.io, path, .{}) catch |err| {
            if (err == error.IsDir) break :blk true; // for Windows
            return err;
        };

        break :blk switch (stat.kind) {
            .directory => true,
            .file => false,
            else => return error.UnsupportedPathKind,
        };
    };

    const projectDir, const configPath = if (isDir) blk: {
        const configPath = util.resolveRealPath2Alloc(ctx.io, path, "tmd.project", false, ctx.arenaAllocator) catch |err| {
            if (err != error.FileNotFound) return err;
            break :blk .{ path, path };
        };
        break :blk .{ path, configPath };
    } else .{ std.Io.Dir.path.dirname(path).?, path };

    if (ctx._configPathToProjectMap.get(configPath)) |project| {
        return .{ .registered = project };
    }

    const projectConfigEx = try ctx.getTmdConfigEx(configPath, projectDir.len == configPath.len, buildTarget);

    const project = try ctx.arenaAllocator.create(Project);
    project.* = .{
        .path = projectDir,
        .configEx = projectConfigEx,
    };

    try ctx._configPathToProjectMap.put(configPath, project);

    return .{ .new = project };
}

pub const buildOutputDirname = "@tmd-build";

pub fn excludeSpecialDir(dir: []const u8) bool {
    return !std.mem.eql(u8, dir, buildOutputDirname);
}
