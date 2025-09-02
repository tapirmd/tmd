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
    return if (project.configEx.basic.@"project-title") |t| t.data else project.dirname();
}

pub const build = @import("Project-build.zig").build;
pub const StandaloneHtmlBuilder = @import("Project-build.zig").StandaloneHtmlBuilder;
pub const EpubBuilder = @import("Project-build.zig").EpubBuilder;
pub const StaticWebsiteBuilder = @import("Project-build.zig").StaticWebsiteBuilder;

pub const run = @import("Project-run.zig").run;


