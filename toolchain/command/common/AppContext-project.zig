const std = @import("std");

const AppContext = @import("AppContext.zig");
const Project = @import("Project.zig");
const util = @import("util.zig");

pub fn regOrGetProject(ctx: *AppContext, dirOrConfigPath: []const u8) !union(enum) { invalid: void, registered: *Project, new: *Project } {
    const path = blk: {
        var pa: util.PathAllocator = .{};
        const path = try util.resolvePathFromAbsDirPathAlloc(".", dirOrConfigPath, true, pa.allocator());
        //defer ctx.allocator.free(path);
        break :blk try util.resolveRealPathAlloc(path, false, ctx.arenaAllocator);
    };

    const stat = std.fs.cwd().statFile(path) catch |err| {
        try ctx.stderr.print("Path ({s}) is invalid. Stat error: {s}.\n", .{ path, @errorName(err) });
        try ctx.stderr.flush();
        return .invalid;
    };

    const projectDir, const configPath = blk: switch (stat.kind) {
        .file => {
            const filename = std.fs.path.basename(path);
            const extension = std.fs.path.extension(path);
            //try ctx.stderr.print("filename: {s}, extension: {s}\n", .{filename, extension});
            //try ctx.stderr.flush();
            if (std.mem.startsWith(u8, filename, "tmd.project") and extension.len + 3 == filename.len) break :blk .{ std.fs.path.dirname(path).?, path };
            try ctx.stderr.print("Project config file ({s}) is invalid. It should start with 'tmd.project' and its base name should be 'tmd'.\n", .{filename});
            try ctx.stderr.flush();
            return .invalid;
        },
        .directory => {
            const configPath = util.resolveRealPath2Alloc(path, "tmd.project", false, ctx.arenaAllocator) catch {
                break :blk .{ path, path };
            };
            break :blk .{ path, configPath };
        },
        else => {
            try ctx.stderr.print("Path ({s}) is invalid. Unsupported kind: {s}.\n", .{ dirOrConfigPath, @tagName(stat.kind) });
            try ctx.stderr.flush();
            return .invalid;
        },
    };

    if (ctx._configPathToProjectMap.get(configPath)) |project| {
        return .{ .registered = project };
    }

    const projectDefaultConfigEx, const workspacePath, const workspaceConfigEx = try ctx.getDirectoryConfigAndRoot(projectDir);
    const projectConfigEx = if (projectDir.len == configPath.len) projectDefaultConfigEx else blk: {
        const configEx = try ctx.loadTmdConfigEx(configPath);
        const baseEx = if (workspacePath.len == projectDir.len) &ctx._defaultConfigEx else workspaceConfigEx;
        ctx.mergeTmdConfig(&configEx.basic, &baseEx.basic);
        break :blk configEx;
    };

    const project = try ctx.arenaAllocator.create(Project);
    project.* = .{
        .path = projectDir,
        .configEx = projectConfigEx,
        .workspacePath = workspacePath,
    };

    try ctx._configPathToProjectMap.put(configPath, project);

    return .{ .new = project };
}

pub const buildOutputDirname = "@tmd-build";

pub fn excludeSpecialDir(dir: []const u8) bool {
    return !std.mem.eql(u8, dir, buildOutputDirname);
}
