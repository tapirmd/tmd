const std = @import("std");

const AppContext = @import("AppContext.zig");
const Project = @import("Project.zig");
const util = @import("util.zig");

pub fn regOrGetProject(ctx: *AppContext, dirOrConfigPath: []const u8) !union(enum) { invalid: void, registered: *Project, new: *Project } {
    const path = util.resolveRealPath(dirOrConfigPath, true, ctx.arenaAllocator) catch |err| {
        try ctx.stderr.print("Path ({s}) is bad. Resolve error: {s}.\n", .{ dirOrConfigPath, @errorName(err) });
        return .invalid;
    };

    const stat = std.fs.cwd().statFile(path) catch |err| {
        try ctx.stderr.print("Path ({s}) is invalid. Stat error: {s}.\n", .{ path, @errorName(err) });
        return .invalid;
    };

    const projectDir, const configPath = blk: switch (stat.kind) {
        .file => {
            const filename = std.fs.path.basename(path);
            const extension = std.fs.path.extension(path);
            //try ctx.stderr.print("filename: {s}, extension: {s}\n", .{filename, extension});
            if (std.mem.startsWith(u8, filename, "tmd.project") and extension.len + 3 == filename.len) break :blk .{ std.fs.path.dirname(path).?, path };
            try ctx.stderr.print("Project config file ({s}) is invalid. It should start with 'tmd.project' and its base name should be 'tmd'.\n", .{filename});
            return .invalid;
        },
        .directory => {
            const configPath = util.resolveRealPath2(path, "tmd.project", false, ctx.arenaAllocator) catch {
                break :blk .{ path, path };
            };
            break :blk .{ path, configPath };
        },
        else => {
            try ctx.stderr.print("Path ({s}) is invalid. Unsupported kind: {s}.\n", .{ dirOrConfigPath, @tagName(stat.kind) });
            return .invalid;
        },
    };

    if (ctx._configPathToProjectMap.get(configPath)) |project| {
        return .{ .registered = project };
    }

    const workspaceConfigEx, const workspacePath = blk: {
        var dir = projectDir;
        while (true) {
            const workspaceConfigPath = util.resolveRealPath2(dir, "tmd.workspace", false, ctx.arenaAllocator) catch {
                dir = std.fs.path.dirname(dir) orelse break :blk .{ null, projectDir };
                continue;
            };
            const configEx = try ctx.loadTmdConfigEx(workspaceConfigPath);
            break :blk .{ configEx, dir };
        }
    };

    const projectConfigEx = if (std.mem.eql(u8, configPath, projectDir)) blk: {
        if (workspaceConfigEx) |wsConfigEx| {
            const configEx = try ctx.arenaAllocator.create(AppContext.ConfigEx);
            configEx.* = wsConfigEx.*;
            ctx.mergeTmdConfig(&configEx.basic, &ctx._defaultConfigEx.basic);
            break :blk configEx;
        } else break :blk &ctx._defaultConfigEx;
    } else blk: {
        const unmerged = try ctx.loadTmdConfigEx(configPath);
        const configEx = try ctx.arenaAllocator.create(AppContext.ConfigEx);
        configEx.* = unmerged.*;
        if (workspaceConfigEx) |wsConfigEx| ctx.mergeTmdConfig(&configEx.basic, &wsConfigEx.basic);
        ctx.mergeTmdConfig(&configEx.basic, &ctx._defaultConfigEx.basic);
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

pub const buildOutputDirname = "@tmd-build-workspace";

pub fn excludeSpecialDir(dir: []const u8) bool {
    return !std.mem.eql(u8, dir, buildOutputDirname);
}
