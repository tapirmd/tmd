const std = @import("std");

const AppContext = @import("AppContext.zig");

const Project = @This();

path: []const u8,

// .configEx.path might be "" (for default config),
// path of tmd.workspace, or path of tmd.project.
configEx: *AppContext.ConfigEx,

// If tmd.workspace file is not found in self+ancestor directories,
// then .workspacePath == .path.
workspacePath: []const u8,

pub fn dirname(project: *const Project) []const u8 {
    const basename = std.fs.path.basename(project.path);
    return if (basename.len > 0) basename else "untitled";
}

pub fn title(project: *const Project) []const u8 {
    if (project.configEx.basic.@"project-title") |option| {
        const text = std.mem.trim(u8, option.data, " \t");
        if (text.len > 0) return text;
    }
    return project.dirname();
}

pub fn navigationArticlePath(project: *const Project) ?[]const u8 {
    if (project.configEx.basic.@"project-navigation-article") |option| {
        const path = std.mem.trim(u8, option.path, " \t");
        if (path.len > 0) return path;
    }
    return null;
}

pub fn coverImagePath(project: *const Project) ?[]const u8 {
    if (project.configEx.basic.@"project-cover-image") |option| {
        const path = std.mem.trim(u8, option.path, " \t");
        if (path.len > 0) return path;
    }
    return null;
}

pub fn confirmProject(project: *const Project) ?[]const u8 {
    if (project.configEx.basic.@"project-cover-image") |option| {
        const path = std.mem.trim(u8, option.path, " \t");
        if (path.len > 0) return path;
    }
    return null;
}

pub const build = @import("Project-build.zig").build;
pub const StandaloneHtmlBuilder = @import("Project-build.zig").StandaloneHtmlBuilder;
pub const EpubBuilder = @import("Project-build.zig").EpubBuilder;
pub const StaticWebsiteBuilder = @import("Project-build.zig").StaticWebsiteBuilder;

pub const run = @import("Project-run.zig").run;
