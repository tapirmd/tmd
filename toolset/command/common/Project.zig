const std = @import("std");

const list = @import("list");

const AppContext = @import("AppContext.zig");

const Project = @This();



path: []const u8,

// .configEx.path might be "" (for default config),
// path of tmd.workspace, or path of tmd.project.
configEx: *AppContext.ConfigEx,

// If tmd.workspace file is not found in self+ancestor directories,
// then .workspacePath == .path.
workspacePath: []const u8,

// session data

seedArticles: list.List([]const u8) = .{}, // abs paths

pub fn title(project: *const Project) ?[]const u8 {
    return if (project.configEx.basic.@"project-title") |t| t else null;
}

pub fn collectSeedArticles(project: *Project, _: *AppContext) !void {
    if (project.configEx.basic.@"project-articles") |data| {
        var it = std.mem.splitAny(u8, data, "\n");
        while (it.next()) |item| {
            const path = std.mem.trim(u8, item, " \t"); // ToDo: trim more space chars?
            if (path.len == 0) continue;
        }
    }
}


// For build
// step 1: copy css/favicon and rename them with hash in names.
//         tfcc needs a .outputDir field, a cssFilesInHead fields (relative to .outputDir).
// step 2: collect titles for TOC.
// step 2: render all tmd files and write html files.
//         During writing, calculate relative css and favicon urls in head.
//         tfcc needs a "image url rewritten callback" field, a "article url broken check callback" field.
//         copy images and rename them with hash in names during rewriting image urls.
//         - for "static-website", save each html as a file.
//         - for "epub" and "standalone-html", saving all to one file.
//         - for "standalone-html", write embedding image base64, and write embedding css style.
//
// For gen:
// step 1: render all tmd files and write html files.
//         During writing, calculate relative css and favicon urls in head. (for full generation).

// If "project-articles" is specified, use it instead of iterating project dir.
// The specified articles must be in the project dir.
// If any of them is missing, fatal error.

// Referencing articles outside "project-articles" is a broken-link.
// If "project-articles", referencing articles outside of project dir is a broken-link.

// Missing referenced assets is not a fatal error.

// Need to collect referenced asset file paths, to copy them to @tmd-build dir with hash in the new file names.
// Referenced asset href src paths will be rewritten, and a map from old to new is built.
// The built map will be passed to TapirMD core lib for rendering the new paths in a-href and image-src.

// Directories which paths (relative to workspace) containing "@xxx" is ignored in tmd file scanning.

// If the workspace directory is not found, then the project directory is viewed as the workspace directory.

// Missing tmd.project file will make a default one (Project title is defaulted to the containing directory name).

// Project name is generated from project title and config file name.

// workspace-dir
//  @tmd-build
//    project-name-VERSION-html/
//    project-name-VERSION.epub
//    project-name-VERSION-standalone.html
//
//    project-name-trial-VERSION-html/
//    project-name-trial-VERSION.epub
//    project-name-trial-VERSION-standalone.html

pub const buildStaticWebsite = @import("Project-build.zig").buildStaticWebsite;
pub const buildEpub = @import("Project-build.zig").buildEpub;
pub const buildStandaloneHtml = @import("Project-build.zig").buildStandaloneHtml;

pub const run = @import("Project-run.zig").run;


