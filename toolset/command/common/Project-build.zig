const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd");
const list = @import("list");

const AppContext = @import("AppContext.zig");
const FileIterator = @import("FileIterator.zig");
const Project = @import("Project.zig");
const DocRenderer = @import("DocRenderer.zig");
const gen = @import("gen.zig");
const util = @import("util.zig");

pub fn build(project: *const Project, ctx: *AppContext, BuilderType: type) !void {
    var session: BuildSession = .init(project, ctx, .init(ctx.allocator));
    defer session.deinit();
    try session.buildWith(BuilderType);
}

const maxTmdFileSize = 1 << 20; // 1M
const bufferSize = maxTmdFileSize * 8;

const maxImageFileSize = 1 << 22; // 4M
const maxStyleFileSize = 1 << 19; // 512K

const BuildSession = struct {
    project: *const Project,
    appContext: *AppContext,
    _arenaAllocator: std.heap.ArenaAllocator,

    arenaAllocator: std.mem.Allocator = undefined,

    projectVersion: []const u8 = undefined,
    buildOutputPath: []const u8 = undefined,
    buildOutputDir: std.fs.Dir = undefined,

    genBuffer: []u8 = undefined,

    calTargetFilePath: *const fn (*BuildSession, []const u8, FilePurpose) anyerror![]const u8 = undefined,
    generateArticleContent: *const fn (*BuildSession, []const u8, []const u8, *DocRenderer) anyerror![]const u8 = undefined,

    //builderContext: *anyopaque = undefined,

    // source abs-file-path to target relative-file-path
    fileMapping: std.StringHashMap([]const u8) = undefined,

    // target relative-file-path to cached file content.
    // For website mode, asset files (iamge, css, etc.) are not cached.
    // ToDo: maybe, website mode should not cache article html too.
    // ToDo2: maybe, no file content should be cached at all (for all modes).
    targetFileContents: std.StringHashMap([]const u8) = undefined,

    // source abs-file-path
    articleFiles: std.ArrayList([]const u8) = undefined,
    navArticleIndex: ?usize = null,

    // ToDo:
    // target relative-file-path
    htmlFiles: std.ArrayList([]const u8) = undefined,

    // target relative-file-path
    imageFiles: std.ArrayList([]const u8) = undefined,
    coverImageIndex: ?usize = null,
    faviconIndex: ?usize = null,

    // target relative-file-path
    cssFiles: list.List([]const u8) = .{},

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

    fn buildWith(self: *@This(), BuilderType: type) !void {
        self.arenaAllocator = self._arenaAllocator.allocator();

        try self.confirmProjectVersion();
        try self.confirmBuildOutputPath(BuilderType.buildNameSuffix());

        std.debug.print("[run] del and mkdir {s}\n", .{self.buildOutputPath});
        try std.fs.cwd().deleteTree(self.buildOutputPath);
        self.buildOutputDir = try std.fs.cwd().makeOpenPath(self.buildOutputPath, .{});
        defer self.buildOutputDir.close();

        self.genBuffer = try self.arenaAllocator.alloc(u8, bufferSize);

        self.calTargetFilePath = BuilderType.calTargetFilePath;
        self.generateArticleContent = BuilderType.generateArticleContent;

        //BuilderType.initContextFor(self);
        //defer BuilderType.deinitContextFor(self);

        self.articleFiles = .init(self.arenaAllocator);
        self.htmlFiles = .init(self.arenaAllocator);
        self.imageFiles = .init(self.arenaAllocator);
        //self.cssFiles

        self.fileMapping = .init(self.arenaAllocator);
        self.targetFileContents = .init(self.arenaAllocator);

        var tmdDocRenderer: DocRenderer = .init(
            self.appContext,
            self.project.configEx,
            BuilderType.createDocRendererCallbacks(self),
        );

        // Some images must be collected before articles.
        try self.collectSomeImages();
        try self.collectCssFiles();
        try self.collectArticles(&tmdDocRenderer);

        try BuilderType.assembleOutputFiles(self);
    }

    fn confirmProjectVersion(self: *@This()) !void {
        const project = self.project;
        self.projectVersion = if (project.configEx.basic.@"project-version") |option| blk: {
            const version = std.mem.trim(u8, option.data, " \t");
            if (std.mem.eql(u8, version, "@git-commit")) {
                break :blk AppContext.getLastGitCommitString(project.path, self.arenaAllocator);
            } else break :blk version;
        } else "";
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
        if (project.path.len != project.workspacePath.len) {
            try w.writeAll("@projects");
        }
        try w.writeByte(std.fs.path.sep);
        try w.writeAll(project.dirname());
        if (self.projectVersion.len > 0) {
            try w.writeByte('-');
            try w.writeAll(self.projectVersion);
        }
        try w.writeAll(buildNameSuffix);

        self.buildOutputPath = try self.arenaAllocator.dupe(u8, fbs.getWritten());

        //std.debug.print("self.buildOutputPath = {s}\n", .{self.buildOutputPath});
    }

    fn collectArticles(self: *@This(), tmdDocRenderer: *DocRenderer) !void {
        // Note that: in epub build,
        // the navigation file may be also used as a general article file.
        // This means the file might be rendered as two HTML files.

        if (self.project.navigationArticlePath()) |path| {
            if (!std.mem.eql(u8, std.fs.path.extension(path), ".tmd")) {
                try self.appContext.stderr.print("Navigation file must be a .tmd extension: {s}\n", .{path});
                return error.BadNavigationFile;
            }

            const absPath = try util.resolveRealPath2(self.project.path, path, true, self.arenaAllocator);
            if (!util.isFileInDir(absPath, self.project.path)) {
                try self.appContext.stderr.print("Navigation file must be in project path ({s}): {s}.\n", .{ self.project.path, absPath });
                return error.BadNavigationFile;
            }

            const index = self.articleFiles.items.len;
            _ = try self.tryToRegisterFile(absPath, .navigationArticle);
            std.debug.assert(index + 1 == self.articleFiles.items.len);
            self.navArticleIndex = index;

            var i: usize = 0;
            while (i < self.articleFiles.items.len) {
                _ = try self.collectArticle(self.articleFiles.items[i], tmdDocRenderer);
                i += 1;
            }

            return;
        }

        try self.appContext.stderr.print("Now, navigation file must be specified.\n", .{});
        return error.NavigationUnspecified;

        //const paths: [1][]const u8 = .{self.project.path};
        //
        //var fi: FileIterator = .init(paths[0..], self.appContext.allocator, self.appContext.stderr, &AppContext.excludeSpecialDir);
        //while (try fi.next()) |entry| {
        //    if (!std.mem.eql(u8, std.fs.path.extension(entry.filePath), ".tmd")) continue;
        //
        //    const path = try util.resolveRealPath2(entry.dirPath, entry.filePath, false, self.arenaAllocator);
        //    _ = try self.tryToRegisterFile(path, .contentArticle);
        //    try self.collectArticle(path, tmdDocRenderer);
        //}
        //
        //// construct nav.tmd ...
        //self.navArticle = try self.constructNavigationArticle();
    }

    // An article must be registered before being collected.
    fn collectArticle(self: *@This(), absPath: []const u8, tmdDocRenderer: *DocRenderer) !void {
        const targetPath = self.fileMapping.get(absPath) orelse return error.ArticleNotRegistered;
        if (self.targetFileContents.get(targetPath)) |_| return error.ArticleAlreadyCollected;

        // ToDo: not always need to cache the content, just output it directly.
        const htmlContent = try self.generateArticleContent(self, absPath, targetPath, tmdDocRenderer);
        try self.targetFileContents.put(targetPath, htmlContent);
    }

    // Now, use a simple design to avoid implementation complexity.
    // <img .../> element is not supported in title as TOC item now.
    // To support it, the implmentation will be much complex.
    // The TmdGenCustomHandler type needs an extra field:
    //     navPath: ?[]const u8,
    //
    // To support 3 cases:
    // 1. Full navigation file, which contains 1+ .tmd file references.
    // 2. Partial navigaiton file, only contains head part (such as localizied "Contents" text),
    //    no .tmd file references. Append all iterated tmd files.
    // 3. No navigation file.
    //    Append all iterated tmd files.
    //
    // ToDo: this is not used. Now only support the first case.
    //
    // ToDo: disable link to the current page in navigation content.
    const NavigationFileRenderer = struct {
        buffer: std.ArrayList(u8),

        fn start() !void {}

        fn end() !void {}

        fn writeTitleAsTocItem() !void {}
    };

    fn collectSomeImages(self: *@This()) !void {
        if (self.project.coverImagePath()) |path| {
            const absPath = try util.resolveRealPath2(self.project.path, path, true, self.arenaAllocator);

            const index = self.imageFiles.items.len;
            _ = try self.tryToRegisterFile(absPath, .image);
            std.debug.assert(index + 1 == self.imageFiles.items.len);
            self.coverImageIndex = index;
        }
    }

    fn collectCssFiles(self: *@This()) !void {
        if (self.project.configEx.basic.@"css-files") |option| {
            const paths = option._parsed;

            var element = paths.head;
            while (element) |e| {
                const absPath = e.value;
                _ = try self.tryToRegisterFile(absPath, .css);
                element = e.next;
            }
        }
    }

    fn tryToRegisterFile(self: *@This(), absPath: []const u8, filePurpose: FilePurpose) ![]const u8 {
        if (self.fileMapping.get(absPath)) |targetPath| return targetPath;

        const targetPath = try self.calTargetFilePath(self, absPath, filePurpose);
        try self.fileMapping.put(absPath, targetPath);

        switch (filePurpose) {
            .navigationArticle, .contentArticle => try self.articleFiles.append(absPath),
            //.html => try self.htmlFiles.append(targetPath),
            .image => try self.imageFiles.append(targetPath),
            .css => {
                const element = try self.cssFiles.createElement(self.arenaAllocator, true);
                element.value = targetPath;
            },
        }

        if (targetPath.len <= 256) std.debug.print(
            \\[register] {s}: {s}
            \\    -> {s}
            \\
        , .{ @tagName(filePurpose), absPath, targetPath }) else std.debug.print(
            \\[register] {s}: {s}
            \\    -> {s} ({} bytes)
            \\
        , .{ @tagName(filePurpose), absPath, targetPath[0..64], targetPath.len });

        return targetPath;
    }

    fn writeAssetElementLinksInHead(self: *@This(), w: anytype, docTargetFilePath: []const u8) !void {
        if (self.cssFiles.head) |head| {
            var element = head;
            while (true) {
                const next = element.next;
                const cssFilePath = element.value;

                try w.writeAll(
                    \\<link href="
                );

                const n, const s = util.relativePath(docTargetFilePath, cssFilePath, '/');
                for (0..n) |_| try w.writeAll("../");
                try tmd.writeUrlAttributeValue(w, s);

                try w.writeAll(
                    \\" rel="stylesheet">
                );

                if (next) |nxt| element = nxt else break;
            }
        }
    }
};

const TmdGenCustomHandler = struct {
    const MutableData = struct {
        relativePathWriter: gen.RelativePathWriter = undefined,
        externalBlockGenerator: gen.ExternalBlockGenerator = undefined,
    };

    session: *BuildSession,
    tmdDocInfo: DocRenderer.TmdDocInfo,
    mutableData: *MutableData,

    fn init(bs: *BuildSession, tmdDocInfo: DocRenderer.TmdDocInfo, mutableData: *MutableData) TmdGenCustomHandler {
        return .{
            .session = bs,
            .tmdDocInfo = tmdDocInfo,
            .mutableData = mutableData,
        };
    }

    fn makeTmdGenOptions(handler: *const @This()) tmd.GenOptions {
        return .{
            .callbackContext = handler,
            .getCustomBlockGenCallback = getCustomBlockGenCallback,
            .getMediaUrlGenCallback = getMediaUrlGenCallback,
            .getLinkUrlGenCallback = getLinkUrlGenCallback,
        };
    }

    fn getCustomBlockGenCallback(ctx: *const anyopaque, custom: *const tmd.BlockType.Custom) !?tmd.GenCallback {
        const handler: *const @This() = @ptrCast(@alignCast(ctx));
        return handler.mutableData.externalBlockGenerator.makeGenCallback(handler.session.project.configEx, handler.tmdDocInfo.doc, custom);
    }

    fn getLinkUrlGenCallback(ctx: *const anyopaque, link: *const tmd.Link) !?tmd.GenCallback {
        const handler: *const @This() = @ptrCast(@alignCast(ctx));

        const url = link.url.?;
        const targetPath, const fragment = switch (url.manner) {
            .relative => |v| blk: {
                if (v.extension) |ext| switch (ext) {
                    .tmd => {
                        std.debug.assert(v.isTmdFile());

                        const absPath = try util.resolvePathFromFilePath(handler.tmdDocInfo.sourceFilePath, url.base, true, handler.session.arenaAllocator);
                        break :blk .{ try handler.session.tryToRegisterFile(absPath, .contentArticle), url.fragment };
                    },
                    .txt, .html, .htm, .xhtml => @panic("ToDo"),
                    .png, .gif, .jpg, .jpeg => {
                        const absPath = try util.resolvePathFromFilePath(handler.tmdDocInfo.sourceFilePath, url.base, true, handler.session.arenaAllocator);
                        break :blk .{ try handler.session.tryToRegisterFile(absPath, .image), "" };
                    },
                };

                return null;
            },
            else => return null,
        };

        // ToDo: standalone-html build needs different handling.

        return handler.mutableData.relativePathWriter.asGenBacklback(targetPath, handler.tmdDocInfo.targetFilePath, fragment);
    }

    fn getMediaUrlGenCallback(ctx: *const anyopaque, link: *const tmd.Link) !?tmd.GenCallback {
        const handler: *const @This() = @ptrCast(@alignCast(ctx));

        const url = link.url.?;
        const targetPath = switch (url.manner) {
            .relative => blk: {
                const absPath = try util.resolvePathFromFilePath(handler.tmdDocInfo.sourceFilePath, url.base, true, handler.session.arenaAllocator);
                break :blk try handler.session.tryToRegisterFile(absPath, .image);
            },
            else => return null,
        };

        return handler.mutableData.relativePathWriter.asGenBacklback(targetPath, handler.tmdDocInfo.targetFilePath, "");
    }
};

const FilePurpose = enum {
    navigationArticle, // tmd file
    contentArticle, // tmd file
    //html,
    image,
    css,
};

pub const StaticWebsiteBuilder = struct {
    //const Context = struct {
    //    //outputDir: std.fs.Dir,
    //    //outputArticlesDir: std.fs.Dir,
    //    //outputImagesDir: std.fs.Dir,
    //    //outputCssDir: std.fs.Dir,
    //};
    //
    //fn initContextFor(session: *const BuildSession) !void {
    //    const ctx = try session.arenaAllocator.create(Context);
    //    //const outputDir = try std.fs.openDirAbsolute(session.buildOutputPath, .{});
    //    //ctx.* = {
    //    //    .outputDir = outputDir,
    //    //    .outputArticlesDir = try outputDir.makeOpenPath(articlesDirname),
    //   //    .outputImagesDir = try outputDir.makeOpenPath(imagesDirname),
    //    //    .outputCssDir = try outputDir.makeOpenPath(cssDirname),
    //    //};
    //    session.builderContext = ctx;
    //}
    //
    //fn deinitContextFor(session: *const BuildSession) void {
    //    const ctx = @ptrCast(@alignCast(session.builderContext));
    //    //ctx.outputArticlesDir.close();
    //    //ctx.outputImagesDir.close();
    //    //ctx.outputCssDir.close();
    //    //ctx.outputDir.close();
    //    _ = ctx;
    //}

    fn buildNameSuffix() []const u8 {
        return ""; // "-website";
    }

    fn calTargetFilePath(session: *BuildSession, sourceAbsPath: []const u8, filePurpose: FilePurpose) ![]const u8 {
        switch (filePurpose) {
            .navigationArticle, .contentArticle => {
                const project = session.project;
                if (!util.isFileInDir(sourceAbsPath, project.path)) {
                    try session.appContext.stderr.print("Article file must be in project path ({s}): {s}.\n", .{ session.project.path, sourceAbsPath });
                    return error.FileOutOfProject;
                }

                const relPath = sourceAbsPath[project.path.len + 1 ..];
                const ext = std.fs.path.extension(relPath);
                return try std.mem.concat(session.arenaAllocator, u8, &.{ relPath[0 .. relPath.len - ext.len], ".html" });
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
            .image => {
                const content = try util.readFile(std.fs.cwd(), sourceAbsPath, .{ .alloc = .{ .allocator = session.appContext.allocator, .maxFileSize = maxImageFileSize } }, session.appContext.stderr);
                defer session.appContext.allocator.free(content);

                const targetPath = try util.buildAssetFilePath("@images", std.fs.path.sep, std.fs.path.basename(sourceAbsPath), content, session.arenaAllocator);
                if (session.targetFileContents.get(targetPath)) |_| return targetPath;

                try util.writeFile(session.buildOutputDir, targetPath, content);
                //try session.targetFileContents.put(targetPath, "");
                return targetPath;
            },
            .css => {
                const content = try util.readFile(std.fs.cwd(), sourceAbsPath, .{ .alloc = .{ .allocator = session.appContext.allocator, .maxFileSize = maxStyleFileSize } }, session.appContext.stderr);
                defer session.appContext.allocator.free(content);

                const targetPath = try util.buildAssetFilePath("@css", std.fs.path.sep, std.fs.path.basename(sourceAbsPath), content, session.arenaAllocator);
                if (session.targetFileContents.get(targetPath)) |_| return targetPath;

                try util.writeFile(session.buildOutputDir, targetPath, content);
                //try session.targetFileContents.put(targetPath, "");
                return targetPath;
            },
        }
    }

    fn generateArticleContent(session: *BuildSession, absPath: []const u8, relPath: []const u8, tmdDocRenderer: *DocRenderer) ![]const u8 {
        var remainingBuffer = session.genBuffer;

        const tmdContent = try util.readFile(std.fs.cwd(), absPath, .{ .buffer = remainingBuffer[0..maxTmdFileSize] }, session.appContext.stderr);
        remainingBuffer = remainingBuffer[tmdContent.len..];

        var fba = std.heap.FixedBufferAllocator.init(remainingBuffer);
        // defer fba.reset(); // unnecessary
        const fbaAllocator = fba.allocator();
        const tmdDoc = try tmd.Doc.parse(tmdContent, fbaAllocator);
        // defer tmdDoc.destroy(); // unnecessary

        const renderBuffer = try fbaAllocator.alloc(u8, remainingBuffer.len - fba.end_index);
        var fbs = std.io.fixedBufferStream(renderBuffer);

        try tmdDocRenderer.render(fbs.writer(), .{
            .doc = &tmdDoc,
            .sourceFilePath = absPath,
            .targetFilePath = relPath,
        });

        const htmlContent = try session.arenaAllocator.dupe(u8, fbs.getWritten());

        // ToDo: don't return the cache content (or just return "").
        {
            try util.writeFile(session.buildOutputDir, relPath, htmlContent);
        }

        return htmlContent;
    }

    fn createDocRendererCallbacks(session: *BuildSession) DocRenderer.Callbacks {
        const T = struct {
            fn assetElementsInHeadCallback(owner: *anyopaque, r: *const DocRenderer) !void {
                const bs: *BuildSession = @ptrCast(@alignCast(owner));
                try bs.writeAssetElementLinksInHead(r.w, r.tmdDocInfo.?.targetFilePath);
            }

            fn pageTitleInHeadCallback(owner: *anyopaque, r: *const DocRenderer) !void {
                const bs: *BuildSession = @ptrCast(@alignCast(owner));
                _ = bs;

                if (r.tmdDocInfo) |info| {
                    if (try info.doc.writePageTitleInHtmlHead(r.w)) return;
                }
                try r.w.writeAll("Untitled");
            }

            fn pageContentInHeadCallback(owner: *anyopaque, r: *const DocRenderer) !void {
                const bs: *BuildSession = @ptrCast(@alignCast(owner));

                const info = if (r.tmdDocInfo) |info| info else unreachable;

                var mutableData: TmdGenCustomHandler.MutableData = undefined;
                var tmdGenCustomHandler: TmdGenCustomHandler = .init(bs, info, &mutableData);
                const genOptions = tmdGenCustomHandler.makeTmdGenOptions();

                try info.doc.writeHTML(r.w, genOptions, bs.appContext.allocator);
            }
        };

        return .{
            .owner = session,
            .assetElementsInHeadCallback = T.assetElementsInHeadCallback,
            .pageTitleInHeadCallback = T.pageTitleInHeadCallback,
            .pageContentInHeadCallback = T.pageContentInHeadCallback,
        };
    }

    fn assembleOutputFiles(session: *BuildSession) !void {
        _ = session;
    }
};

pub const EpubBuilder = struct {
    // .tmd -> .xhtml
    // image.ext -> images/image-HASH.ext
    // .css -> .css

    fn buildNameSuffix() []const u8 {
        return ".epub";
    }

    fn calTargetFilePath(session: *BuildSession, sourceAbsPath: []const u8, filePurpose: FilePurpose) ![]const u8 {
        switch (filePurpose) {
            .navigationArticle => {
                const project = session.project;
                if (!util.isFileInDir(sourceAbsPath, project.path)) {
                    try session.appContext.stderr.print("Article file must be in project path ({s}): {s}.\n", .{ session.project.path, sourceAbsPath });
                    return error.FileOutOfProject;
                }
                const basename = std.fs.path.basename(sourceAbsPath);
                const ext = std.fs.path.extension(basename);
                return std.mem.concat(session.arenaAllocator, u8, &.{ basename[0 .. basename.len - ext.len], ".xhtml" });
            },
            .contentArticle => {
                const project = session.project;
                if (!util.isFileInDir(sourceAbsPath, project.path)) {
                    try session.appContext.stderr.print("Article file must be in project path ({s}): {s}.\n", .{ session.project.path, sourceAbsPath });
                    return error.FileOutOfProject;
                }

                const relPath = sourceAbsPath[project.path.len + 1 ..];
                const ext = std.fs.path.extension(relPath);
                return util.buildPosixPath("tmd/", relPath[0 .. relPath.len - ext.len], ".xhtml", session.arenaAllocator);
            },
            //.html => {
            //    const project = session.project;
            //    if (!util.isFileInDir(sourceAbsPath, project.path)) {
            //        try session.appContext.stderr.print("Article file must be in project path ({s}): {s}.\n", .{ session.project.path, sourceAbsPath });
            //        return error.FileOutOfProject;
            //    }
            //    const relPath = sourceAbsPath[project.path.len + 1 ..];
            //    const ext = std.fs.path.extension(relPath);
            //    const targetPath = util.buildPosixPath("html/", relPath[0 .. relPath.len - ext.len], ".xhtml", session.arenaAllocator);
            //
            //    return targetPath;
            //},
            .image => {
                const content = try util.readFile(std.fs.cwd(), sourceAbsPath, .{ .alloc = .{ .allocator = session.arenaAllocator, .maxFileSize = maxImageFileSize } }, session.appContext.stderr);
                const targetPath = try util.buildPosixPathWithContentHashBase64("images/", std.fs.path.basename(sourceAbsPath), content, session.arenaAllocator);
                if (session.targetFileContents.get(targetPath)) |_| return targetPath;

                try session.targetFileContents.put(targetPath, content);
                return targetPath;
            },
            .css => {
                const content = try util.readFile(std.fs.cwd(), sourceAbsPath, .{ .alloc = .{ .allocator = session.arenaAllocator, .maxFileSize = maxStyleFileSize } }, session.appContext.stderr);
                const targetPath = try util.buildPosixPathWithContentHashBase64("css/", std.fs.path.basename(sourceAbsPath), content, session.arenaAllocator);
                if (session.targetFileContents.get(targetPath)) |_| return targetPath;

                try session.targetFileContents.put(targetPath, content);
                return targetPath;
            },
        }
    }

    fn generateArticleContent(session: *BuildSession, absPath: []const u8, relPath: []const u8, tmdDocRenderer: *DocRenderer) ![]const u8 {
        _ = session;
        _ = absPath;
        _ = relPath;
        _ = tmdDocRenderer;

        return "";
    }

    fn createDocRendererCallbacks(session: *BuildSession) DocRenderer.Callbacks {
        const T = struct {
            fn assetElementsInHeadCallback(owner: *anyopaque, r: *const DocRenderer) !void {
                const bs: *BuildSession = @ptrCast(@alignCast(owner));
                try bs.writeAssetElementLinksInHead(r.w, r.tmdDocInfo.?.targetFilePath);
            }

            fn pageTitleInHeadCallback(owner: *anyopaque, r: *const DocRenderer) !void {
                const bs: *BuildSession = @ptrCast(@alignCast(owner));
                _ = bs;

                if (r.tmdDocInfo) |info| {
                    if (try info.doc.writePageTitleInHtmlHead(r.w)) return;
                }
                try r.w.writeAll("Untitled");
            }

            fn pageContentInHeadCallback(owner: *anyopaque, r: *const DocRenderer) !void {
                const bs: *BuildSession = @ptrCast(@alignCast(owner));
                _ = bs;
                _ = r;
            }
        };

        return .{
            .owner = session,
            .assetElementsInHeadCallback = T.assetElementsInHeadCallback,
            .pageTitleInHeadCallback = T.pageTitleInHeadCallback,
            .pageContentInHeadCallback = T.pageContentInHeadCallback,
        };
    }

    fn assembleOutputFiles(session: *BuildSession) !void {
        _ = session;
    }
};

pub const StandaloneHtmlBuilder = struct {
    // .tmd -> #foo/bar.tmd
    // image.ext -> inline base64 string
    // .css -> inline

    fn buildNameSuffix() []const u8 {
        return "-standalone.html";
    }

    fn calTargetFilePath(session: *BuildSession, sourceAbsPath: []const u8, filePurpose: FilePurpose) ![]const u8 {
        switch (filePurpose) {
            .navigationArticle,
            .contentArticle, //, .html
            => {
                const project = session.project;
                if (!util.isFileInDir(sourceAbsPath, project.path)) {
                    try session.appContext.stderr.print("Article file must be in project path ({s}): {s}.\n", .{ session.project.path, sourceAbsPath });
                    return error.FileOutOfProject;
                }
                return try std.mem.concat(session.arenaAllocator, u8, &.{ "#", sourceAbsPath[project.path.len + 1 ..] });
            },
            .image => {
                const content = try util.readFile(std.fs.cwd(), sourceAbsPath, .{ .alloc = .{ .allocator = session.appContext.allocator, .maxFileSize = maxImageFileSize } }, session.appContext.stderr);
                defer session.appContext.allocator.free(content);

                const targetPath = try util.buildEmbeddedImageHref(std.fs.path.extension(sourceAbsPath), content, session.arenaAllocator);
                if (session.targetFileContents.get(targetPath)) |_| return targetPath;

                //try session.targetFileContents.put(targetPath, "");
                return targetPath;
            },
            .css => {
                const content = try util.readFile(std.fs.cwd(), sourceAbsPath, .{ .alloc = .{ .allocator = session.appContext.allocator, .maxFileSize = maxStyleFileSize } }, session.appContext.stderr);
                defer session.appContext.allocator.free(content);

                //const targetPath = try util.buildHashHexString(content, session.arenaAllocator);
                const targetPath = try util.buildHashString(content, session.arenaAllocator);
                if (session.targetFileContents.get(targetPath)) |_| return targetPath;

                try session.targetFileContents.put(targetPath, content);
                return targetPath;
            },
        }
    }

    fn generateArticleContent(session: *BuildSession, absPath: []const u8, relPath: []const u8, tmdDocRenderer: *DocRenderer) ![]const u8 {
        _ = session;
        _ = absPath;
        _ = relPath;
        _ = tmdDocRenderer;

        return "";
    }

    fn createDocRendererCallbacks(session: *BuildSession) DocRenderer.Callbacks {
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

            fn pageContentInHeadCallback(owner: *anyopaque, r: *const DocRenderer) !void {
                const bs: *BuildSession = @ptrCast(@alignCast(owner));
                _ = bs;
                _ = r;
            }
        };

        return .{
            .owner = session,
            .assetElementsInHeadCallback = T.assetElementsInHeadCallback,
            .pageTitleInHeadCallback = T.pageTitleInHeadCallback,
            .pageContentInHeadCallback = T.pageContentInHeadCallback,
        };
    }

    fn assembleOutputFiles(session: *BuildSession) !void {
        _ = session;
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
