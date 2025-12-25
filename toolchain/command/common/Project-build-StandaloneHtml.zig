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

pub fn targetPathSep() u8 {
    return '/';
}

pub fn buildNameSuffix() []const u8 {
    return "-standalone.html";
}

pub fn init(session: *BuildSession) !@This() {
    return .{
        .session = session,
        .genBuffer = try session.arenaAllocator.alloc(u8, bufferSize),
    };
}

pub fn deinit(builder: *@This()) void {
    _ = builder;
}

pub fn init2(builder: *@This()) !void {
    _ = builder;
}

pub fn build(builder: *@This()) !void {
    const session = builder.session;

    _ = session;
}

pub fn calTargetFilePath(builder: *@This(), filePath: Config.FilePath, filePurpose: Project.FilePurpose) !struct { []const u8, bool } {
    const session = builder.session;
    switch (filePurpose) {
        .article => {
            switch (filePath) {
                .local => |sourceAbsPath| {
                    const project = session.project;
                    if (!util.isFileInDir(sourceAbsPath, project.path)) {
                        try session.appContext.stderr.print("Article file must be in project path ({s}): {s}.\n", .{ session.project.path, sourceAbsPath });
                        try session.appContext.stderr.flush();
                        return error.FileOutOfProject;
                    }
                    const targetPath = try std.mem.concat(session.arenaAllocator, u8, &.{ "#", sourceAbsPath[project.path.len + 1 ..] });
                    if (builtin.mode == .Debug) std.debug.assert(session.targetFileContents.get(targetPath) == null);

                    //try session.targetFileContents.put(targetPath, ""); // Don't
                    return .{ targetPath, true };
                },
                .builtin, .remote => unreachable,
            }
        },
        .images => {
            switch (filePath) {
                .builtin => |name| {
                    const info = try session.appContext.getBuiltinFileInfo(name);

                    const targetPath = try util.buildEmbeddedImageHref(info.extension, info.content, session.arenaAllocator);
                    if (builtin.mode == .Debug) std.debug.assert(session.targetFileContents.get(targetPath) == null);

                    try session.targetFileContents.put(targetPath, "");
                    return .{ targetPath, true };
                },
                .local => |sourceAbsPath| {
                    const content = try util.readFile(null, sourceAbsPath, .{ .alloc = .{ .allocator = session.appContext.allocator, .maxFileSize = maxAssetFileSize } }, session.appContext.stderr);
                    defer session.appContext.allocator.free(content);

                    const ext = tmd.extension(sourceAbsPath) orelse unreachable;
                    const info = tmd.getExtensionInfo(ext);
                    if (!info.isImage) unreachable;

                    const targetPath = try util.buildEmbeddedImageHref(ext, content, session.arenaAllocator);
                    if (session.targetFileContents.get(targetPath) == null) {
                        try session.targetFileContents.put(targetPath, "");
                        return .{ targetPath, true };
                    }

                    return .{ targetPath, false };
                },
                .remote => unreachable,
            }
        },
        .css, .js => {
            switch (filePath) {
                .builtin => |name| {
                    const info = try session.appContext.getBuiltinFileInfo(name);

                    // ToDo: why buildHashString?
                    const targetPath = try util.buildHashString(info.content, session.arenaAllocator);
                    if (builtin.mode == .Debug) std.debug.assert(session.targetFileContents.get(targetPath) == null);

                    try session.targetFileContents.put(targetPath, info.content);
                    return .{ targetPath, true };
                },
                .local => |sourceAbsPath| {
                    const content = try util.readFile(null, sourceAbsPath, .{ .alloc = .{ .allocator = session.appContext.arenaAllocator, .maxFileSize = maxAssetFileSize } }, session.appContext.stderr);
                    //defer session.appContext.allocator.free(content);

                    // ToDo: why buildHashString?
                    const targetPath = try util.buildHashString(content, session.arenaAllocator);
                    if (session.targetFileContents.get(targetPath) == null) {
                        try session.targetFileContents.put(targetPath, content);
                    }

                    return .{ targetPath, true };
                },
                .remote => unreachable,
            }
        },
    }
}

fn generateArticleContent(builder: *@This(), absPath: []const u8, relPath: []const u8, tmdDocRenderer: *DocRenderer) ![]const u8 {
    const session = builder.session;
    _ = session;
    _ = absPath;
    _ = relPath;
    _ = tmdDocRenderer;

    return "";
}

fn createDocRendererCallbacks(builder: *@This()) DocRenderer.Callbacks {
    const session = builder.session;
    const T = struct {
        fn assetElementsInHeadCallback(owner: *anyopaque, r: *const DocRenderer) !void {
            const bs: *BuildSession = @ptrCast(@alignCast(owner));
            _ = bs;
            _ = r;
        }

        fn pageTitleInHeadCallback(owner: *anyopaque, r: *const DocRenderer) !void {
            const bs: *BuildSession = @ptrCast(@alignCast(owner));
            _ = bs;
            _ = r;
        }

        fn pageContentInBodyCallback(owner: *anyopaque, r: *const DocRenderer) !void {
            const bs: *BuildSession = @ptrCast(@alignCast(owner));
            _ = bs;
            _ = r;
        }
    };

    return .{
        .owner = session,
        .assetElementsInHeadCallback = T.assetElementsInHeadCallback,
        .pageTitleInHeadCallback = T.pageTitleInHeadCallback,
        .pageContentInBodyCallback = T.pageContentInBodyCallback,
    };
}
