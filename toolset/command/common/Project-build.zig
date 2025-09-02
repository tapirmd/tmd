const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd");
const list = @import("list");

const AppContext = @import("AppContext.zig");
const FileIterator = @import("FileIterator.zig");
const Project = @import("Project.zig");

pub fn build(project: *const Project, ctx: *AppContext, BuilderType: type) !void {
    var session: BuildSession = .init(project, ctx, .init(ctx.allocator));
    defer session.deinit();
    try session.buildWith(BuilderType);
}

const maxTmdFileSize = 1 << 22; // 4M
const bufferSize = maxTmdFileSize * 8;

const BuildSession = struct {
    project: *const Project,
    appContext: *AppContext,
    _arenaAllocator: std.heap.ArenaAllocator,

    arenaAllocator: std.mem.Allocator = undefined,

    projectVersion: []const u8 = undefined,
    buildOutputPath: []const u8 = undefined,

    calTargetArticlePath: *const fn(*const BuildSession, []const u8) anyerror![]const u8 = undefined,

    genBuffer: []u8 = undefined,
    
    tmdGenCustomHandler: TmdGenCustomHandler = undefined,
    getCustomBlockGenCallback: *const fn (session: *BuildSession, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) ?tmd.GenCallback = undefined,
    getMediaUrlGenCallback: *const fn(session: *BuildSession, doc: *const tmd.Doc, mediaInfoToken: tmd.Token) ?tmd.GenCallback = undefined,
    getLinkUrlGenCallback: *const fn(session: *BuildSession, doc: *const tmd.Doc, link: *const tmd.Link) ?tmd.GenCallback = undefined,

    // source abs-file-path to target relative-file-path
    fileMapping: std.StringHashMap([]const u8) = undefined,
    
    // target relative-file-path to file content
    targetFiles: std.StringHashMap([]const u8) = undefined,

    // abs-file-path
    articleFiles: list.List([]const u8) = .{},

    // all are target relative-file-path
    imageFiles: list.List([]const u8) = .{},
    cssFiles: list.List([]const u8) = .{},
    navArticle: []const u8 = "",
    coverImage: []const u8 = "",

       
    fn init(project: *const Project, appContext: *AppContext, arenaAllocator: std.heap.ArenaAllocator) @This() {
        return .{
            .project = project,
            .appContext = appContext,
            ._arenaAllocator = arenaAllocator,
        };
    }

    fn deinit(self: *@This()) void {
        self._arenaAllocator.deinit();
    }

    const TmdGenCustomHandler = struct {
        session: *BuildSession,

        fn getCustomBlockGenCallback(ctx: *const anyopaque, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) ?tmd.GenCallback {
            const handler: *const @This() = @ptrCast(@alignCast(ctx));
            return handler.session.getCustomBlockGenCallback(handler.session, doc, custom);
        }

        fn getMediaUrlGenCallback(ctx: *const anyopaque, doc: *const tmd.Doc, mediaInfoToken: tmd.Token) ?tmd.GenCallback {
            const handler: *const @This() = @ptrCast(@alignCast(ctx));
            return handler.session.getMediaUrlGenCallback(handler.session, doc, mediaInfoToken);
        }

        fn getLinkUrlGenCallback(ctx: *const anyopaque, doc: *const tmd.Doc, link: *const tmd.Link) ?tmd.GenCallback {
            const handler: *const @This() = @ptrCast(@alignCast(ctx));
            return handler.session.getLinkUrlGenCallback(handler.session, doc, link);
        }
        
        fn makeTmdGenOptions(handler: *const @This()) tmd.GenOptions {
            return .{
                .callbackContext = handler,
                .getCustomBlockGenCallback = &getCustomBlockGenCallback,
                .getMediaUrlGenCallback = &getMediaUrlGenCallback,
                .getLinkUrlGenCallback = &getLinkUrlGenCallback,
            };
        }
    };

    fn buildWith(self: *@This(), BuilderType: type) !void {
        self.arenaAllocator =  self._arenaAllocator.allocator();

        try self.confirmProjectVersion();
        try self.confirmBuildOutputPath(BuilderType.buildNameSuffix());

        self.calTargetArticlePath = BuilderType.calTargetArticlePath;

        self.genBuffer = try self.arenaAllocator.alloc(u8, bufferSize);

        self.tmdGenCustomHandler = .{.session = self};
        self.getCustomBlockGenCallback = BuilderType.getCustomBlockGenCallback;
        self.getMediaUrlGenCallback = BuilderType.getMediaUrlGenCallback;
        self.getLinkUrlGenCallback = BuilderType.getLinkUrlGenCallback;
        
        self.fileMapping = .init(self.arenaAllocator);
        self.targetFiles = .init(self.arenaAllocator);

        try self.collectArticles();
    }



    fn confirmProjectVersion(self: *@This()) !void {
        self.projectVersion = "";
    }

    fn confirmBuildOutputPath(self: *@This(), buildNameSuffix: []const u8) !void {
        const project = self.project;

        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buffer);
        const w = fbs.writer();

        try w.writeAll(project.workspacePath);
        try w.writeByte(std.fs.path.sep);
        try w.writeAll(AppContext.buildOutputDirname);
        try w.writeByte(std.fs.path.sep);
        try w.writeAll(if (project.path.len == project.workspacePath.len) "@workspace" else "@projects");
        try w.writeByte(std.fs.path.sep);
        try w.writeAll(project.dirname());
        if (self.projectVersion.len > 0) {
            try w.writeByte('-');
            try w.writeAll(self.projectVersion);
        }
        try w.writeAll(buildNameSuffix);

        self.buildOutputPath = try self.arenaAllocator.dupe(u8, fbs.getWritten());

        std.debug.print("self.buildOutputPath = {s}\n", .{self.buildOutputPath});
    }

    fn collectArticles(self: *@This()) !void {
        if (self.project.configEx.basic.@"project-navigation-file") |option| {
            const path = std.mem.trim(u8, option.path, " \t");
            if (path.len > 0) {
                if (!std.mem.eql(u8, std.fs.path.extension(path), ".tmd")) {
                    try self.appContext.stderr.print("Navigation file must be a .tmd extension: {s}\n", .{path});
                    return error.BadNavigationFile;
                }

                const absPath = try AppContext.resolveRealPath(path, self.arenaAllocator);
                if (!AppContext.isFileInDir(absPath, self.project.path)) {
                    try self.appContext.stderr.print("Navigation file must be in project path ({s}): {s}.\n", .{self.project.path, absPath});
                    return error.BadNavigationFile;
                }

                self.navArticle = try self.tryToRegisterArticle(absPath) orelse unreachable;

                var element = self.articleFiles.head.?;
                if (builtin.mode == .Debug) {
                    std.debug.assert(std.meta.eql(element.value, self.navArticle));
                }

                while (true) {
                    _ = try self.collectArticle(element.value);
                    element = element.next orelse break;
                }

                return;
            }
        } 

        const paths: [1][]const u8 = .{self.project.path};

        var fi: FileIterator = .init(paths[0..], self.appContext.allocator, self.appContext.stderr, &AppContext.excludeSpecialDir);
        while (try fi.next()) |entry| {
            if (!std.mem.eql(u8, std.fs.path.extension(entry.filePath), ".tmd")) continue;

            const path = try AppContext.resolveRealPath2(entry.dirPath, entry.filePath, self.arenaAllocator);
            _ = try self.tryToRegisterArticle(path);
            try self.collectArticle(path);
        }

        // construct nav.tmd ...
    }

    fn collectArticle(self: *@This(), absPath: []const u8) !void {
        const targetPath = self.fileMapping.get(absPath) orelse return error.ArticleNotRegistered;
        if (self.targetFiles.get(targetPath)) |_| return error.ArticleAlreadyCollected;

        var remainingBuffer = self.genBuffer;

        const tmdContent = try self.appContext.readFileIntoBuffer(std.fs.cwd(), absPath, remainingBuffer[0..maxTmdFileSize]);
        remainingBuffer = remainingBuffer[tmdContent.len..];

        var fba = std.heap.FixedBufferAllocator.init(remainingBuffer);
        // defer fba.reset(); // unnecessary
        const fbaAllocator = fba.allocator();
        const tmdDoc = try tmd.Doc.parse(tmdContent, fbaAllocator);
        // defer tmdDoc.destroy(); // unnecessary

        const genOptions = self.tmdGenCustomHandler.makeTmdGenOptions();
        var fbs = std.io.fixedBufferStream(remainingBuffer);
        try tmdDoc.writeHTML(fbs.writer(), genOptions, self.appContext.allocator);

        const htmlSnippet = try self.arenaAllocator.dupe(u8, fbs.getWritten());
        try self.targetFiles.put(targetPath, htmlSnippet);
    }

    fn tryToRegisterArticle(self: *@This(), absPath: []const u8) !?[]const u8 {
        if (self.fileMapping.contains(absPath)) return null;

        // ToDo: tolerate file-out-of-project error and collect it to
        //       show in the warning list at the end of the build.
        const targetPath = try self.calTargetArticlePath(self, absPath);

        try self.fileMapping.put(absPath, targetPath);
        
        const element = try self.articleFiles.createElement(self.arenaAllocator, true);
        element.value = absPath;

        return targetPath;
    }


};

pub const StaticWebsiteBuilder = struct {
    // .tmd -> .html
    // image.ext -> image-HASH.ext
    // .css -> .css

    fn buildNameSuffix() []const u8 {
        return "-website";
    }

    fn calTargetArticlePath(session: *const BuildSession, sourceAbsPath: []const u8) ![]const u8 {
        const project = session.project;
        if (!AppContext.isFileInDir(sourceAbsPath, project.path)) return error.FileOutOfProject;
        return sourceAbsPath[project.path.len..];
    }

    fn getCustomBlockGenCallback(session: *BuildSession, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) ?tmd.GenCallback {
        _ = session;
        _ = doc;
        _ = custom;

        return null;
    }

    fn getMediaUrlGenCallback(session: *BuildSession, doc: *const tmd.Doc, mediaToken: tmd.Token) ?tmd.GenCallback {
        _ = session;
        _ = doc;
        _ = mediaToken;
        
        return null;
    }

    fn getLinkUrlGenCallback(session: *BuildSession, doc: *const tmd.Doc, link: *const tmd.Link) ?tmd.GenCallback {
        _ = session;
        _ = doc;
        _ = link;
        
        return null;
    }


};

pub const EpubBuilder = struct {
    // .tmd -> .xhtml
    // image.ext -> image.ext
    // .css -> .css

    fn buildNameSuffix() []const u8 {
        return ".epub";
    }

    fn calTargetArticlePath(session: *const BuildSession, sourceAbsPath: []const u8) ![]const u8 {
        return try StaticWebsiteBuilder.calTargetArticlePath(session, sourceAbsPath);
    }

    fn getCustomBlockGenCallback(session: *BuildSession, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) ?tmd.GenCallback {
        _ = session;
        _ = doc;
        _ = custom;

        return null;
    }

    fn getMediaUrlGenCallback(session: *BuildSession, doc: *const tmd.Doc, mediaToken: tmd.Token) ?tmd.GenCallback {
        _ = session;
        _ = doc;
        _ = mediaToken;
        
        return null;
    }

    fn getLinkUrlGenCallback(session: *BuildSession, doc: *const tmd.Doc, link: *const tmd.Link) ?tmd.GenCallback {
        _ = session;
        _ = doc;
        _ = link;
        
        return null;
    }
};

pub const StandaloneHtmlBuilder = struct {
    // .tmd -> #article-anchor
    // image.ext -> inline base64 string
    //   - https://x.com/i/grok/share/2X2ge6HIngibFO8fbyIFYxQAz
    //   - https://g.co/gemini/share/7518b55d3bbb
    // .css -> inline

    fn buildNameSuffix() []const u8 {
        return "-standalone.html";
    }

    fn calTargetArticlePath(session: *const BuildSession, sourceAbsPath: []const u8) ![]const u8 {
        const relPath = try StaticWebsiteBuilder.calTargetArticlePath(session, sourceAbsPath);
        return std.mem.concat(session.arenaAllocator, u8, &.{"#", relPath});
    }

    fn getCustomBlockGenCallback(session: *BuildSession, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) ?tmd.GenCallback {
        _ = session;
        _ = doc;
        _ = custom;

        return null;
    }

    fn getMediaUrlGenCallback(session: *BuildSession, doc: *const tmd.Doc, mediaToken: tmd.Token) ?tmd.GenCallback {
        _ = session;
        _ = doc;
        _ = mediaToken;
        
        return null;
    }

    fn getLinkUrlGenCallback(session: *BuildSession, doc: *const tmd.Doc, link: *const tmd.Link) ?tmd.GenCallback {
        _ = session;
        _ = doc;
        _ = link;
        
        return null;
    }
};


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

// If "project-navigation-file" is specified, use it as the seed file.
// Otherwise, iterate all tmd files in project dir.
// The navigation article must be in the project dir.

// Referencing articles outside project dir is a broken-link.

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