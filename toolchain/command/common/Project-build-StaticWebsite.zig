const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd");
const list = @import("list");

const AppContext = @import("AppContext.zig");
const DocRenderer = @import("DocRenderer.zig");
const Project = @import("Project.zig");
const Config = @import("Config.zig");
const gen = @import("gen.zig");
const util = @import("util.zig");




const bufferSize = Project.maxTmdFileSize * 8;

const maxAssetFileSize = 1 << 22; // 4M

const BuildSession = Project.BuildSession(@This());

session: *BuildSession,
genBuffer: []u8,
buildOutputPath: std.fs.Dir = undefined,

pub fn buildNameSuffix() []const u8 {
    return "";
}

pub fn init(session: *BuildSession) !@This() {
    try std.fs.cwd().deleteTree(session.buildOutputPath);
    return .{
        .session = session,
        .genBuffer = try session.arenaAllocator.alloc(u8, bufferSize),
        .buildOutputPath = try std.fs.cwd().makeOpenPath(session.buildOutputPath, .{}),
    };
}

pub fn deinit(builder: *@This()) void {
    builder.buildOutputPath.close();
}

pub fn init2(builder: *@This()) !void {
    _ = builder;
}

pub fn build(builder: *@This()) !void {
    try builder.renderArticles();
}

pub fn calTargetFilePath(builder: *@This(), filePath: Config.FilePath, filePurpose: Project.FilePurpose) !struct{[]const u8, bool} {
    const session = builder.session;
    switch (filePurpose) {
        .article => {
            switch (filePath) {
                .local => |sourceAbsPath| {
                    const project = session.project;
                    if (!util.isFileInDir(sourceAbsPath, project.path)) {
                        try session.appContext.stderr.print("Article file must be in project path ({s}): {s}.\n", .{ session.project.path, sourceAbsPath });
                        return error.FileOutOfProject;
                    }

                    const relPath = sourceAbsPath[project.path.len + 1 ..];
                    const ext = std.fs.path.extension(relPath);
                    const targetPath = try std.mem.concat(session.arenaAllocator, u8, &.{ relPath[0 .. relPath.len - ext.len], ".html" });
                    if (builtin.mode == .Debug) std.debug.assert(session.targetFileContents.get(targetPath) == null);

                    //try session.targetFileContents.put(targetPath, ""); // Don't
                    return .{targetPath, true};
                },
                .builtin, .remote => unreachable,
            }
        },
        //.html => {
        //    const project = session.project;
        //    if (!util.isFileInDir(sourceAbsPath, project.path)) {
        //        try session.appContext.stderr.print("Article file must be in project path ({s}): {s}.\n", .{ session.project.path, sourceAbsPath });
        //        return error.FileOutOfProject;
        //    }
        //
        //    const relPath = sourceAbsPath[project.path.len + 1 ..];
        //    return try std.fs.path.join(session.arenaAllocator, &.{ "@html", relPath });
        //},
        inline .images, .css, .js => |tag| {
            const folderName = "@assets" ++ &[1]u8{std.fs.path.sep} ++ @tagName(tag) ++ &[1]u8{std.fs.path.sep};

            switch (filePath) {
                .builtin => |name| {
                    const info = try session.appContext.getBuiltinFileInfo(name);

                    const targetPath = try util.buildAssetFilePath(folderName, name, info.content, session.arenaAllocator);
                    if (builtin.mode == .Debug) std.debug.assert(session.targetFileContents.get(targetPath) == null);

                    try util.writeFile(builder.buildOutputPath, targetPath, info.content);

                    if (builtin.mode == .Debug) std.debug.assert(session.targetFileContents.get(targetPath) == null);
                    try session.targetFileContents.put(targetPath, "");
                    return .{targetPath, true};
                },
                .local => |sourceAbsPath| {
                    const content = try util.readFile(std.fs.cwd(), sourceAbsPath, .{ .alloc = .{ .allocator = session.appContext.allocator, .maxFileSize = maxAssetFileSize } }, session.appContext.stderr);
                    defer session.appContext.allocator.free(content);

                    const targetPath = try util.buildAssetFilePath(folderName, std.fs.path.basename(sourceAbsPath), content, session.arenaAllocator);
                    if (session.targetFileContents.get(targetPath) == null) {
                        try util.writeFile(builder.buildOutputPath, targetPath, content);
                        try session.targetFileContents.put(targetPath, "");
                        return .{targetPath, true};
                    }

                    return .{targetPath, false};
                },
                .remote => unreachable,
            }
        },
    }
}

fn renderArticles(builder: *@This()) !void {
    try builder.session.renderArticles(std.fs.path.sep, builder.genBuffer, builder);
}

pub fn makeCachedArticleContent(builder: *@This(), targetFilePath: []const u8, htmlContent: []const u8) ![]const u8 {
    try util.writeFile(builder.buildOutputPath, targetFilePath, htmlContent);

    //const htmlContent2 = try session.arenaAllocator.dupe(u8, htmlContent);
    //return htmlContent2;
    return ""; // ToDo: when nav is .autoGenerated, the content needs to be cached to output later.
}


// If "project-navigation-file" is specified and the file references 1+ doc files,
//     use it as the seed file.
// If "project-navigation-file" is nit specified, iterate all tmd files in project dir
//     and use the files in a generated navigation file.
// If "project-navigation-file" is specified and the file doesn't reference any doc file,
//     iterate all tmd files in project dir and append the files to the navigation file.

// Referencing articles outside project dir is a broken-link.

// Missing referenced assets is not a fatal error.

// Directories which paths (relative to workspace) containing "@xxx" is ignored in tmd file scanning.

// If the workspace directory is not found, then the project directory is viewed as the workspace directory.

// Missing tmd.project file will make a default one (Project title is defaulted to the containing directory name).

// Project name is generated from project title and config file name.
