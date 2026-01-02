const std = @import("std");
const builtin = @import("builtin");

const AppContext = @import("AppContext.zig");
const DocRenderer = @import("DocRenderer.zig");
const gen = @import("gen.zig");
const util = @import("util.zig");
const Config = @import("Config.zig");
const DirEntries = @import("DirEntries.zig");

const tmd = @import("tmd");
const list = @import("list");

pub const maxTmdFileSize = 1 << 20; // 1M

pub const StaticWebsiteBuilder = @import("Project-build-StaticWebsite.zig");
pub const EpubBuilder = @import("Project-build-Epub.zig");
pub const StandaloneHtmlBuilder = @import("Project-build-StandaloneHtml.zig");

pub const run = @import("Project-run.zig").run;

const Project = @This();

path: []const u8,

// .configEx.path might be "" (for default config)
// if default config is not found and no non-default config is specified.
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

pub fn build(project: *const Project, ctx: *AppContext, BuilderType: type) !void {
    var session: BuildSession(BuilderType) = .init(project, ctx);
    defer session.deinit();
    try session.initMore(BuilderType.buildNameSuffix());

    session.builder = try .init(&session);
    defer session.builder.deinit();

    try session.builder.init2();

    // Some images must be collected before articles.
    try session.collectKnownImages();
    try session.collectKnownCssFiles();
    try session.collectKnownJsFiles();
    try session.collectSeedArticles();

    try session.builder.build();

    std.debug.print("Done. Output path: {s}\n", .{session.buildOutputPath});
}

pub const FilePurpose = enum {
    article, // tmd file
    //html,
    images,
    css,
    js,
};

pub fn BuildSession(BuilderType: type) type {
    const targetPathSep = comptime BuilderType.targetPathSep();

    return struct {
        const BuildSessionType = @This();

        project: *const Project,
        appContext: *AppContext,
        _arenaAllocator: std.heap.ArenaAllocator,

        arenaAllocator: std.mem.Allocator = undefined,

        projectVersion: []const u8 = undefined,
        buildOutputPath: []const u8 = undefined,

        builder: BuilderType = undefined,

        // source file-path to target relative-file-path
        fileMapping: std.HashMap(Config.FilePath, []const u8, Config.FilePath.HashMapContext, 33) = undefined,

        // target relative-file-path to cached file content.
        // For website mode, asset files (iamge, css, etc.) are not cached.
        // ToDo: maybe, webnosite mode should not cache article html too.
        // ToDo2: maybe,  file content should be cached at all (for all modes).
        targetFileContents: std.StringHashMap([]const u8) = undefined,

        // source abs-file-path
        articleFiles: std.ArrayList([]const u8) = .empty,

        articleDirEntries: ?DirEntries = null,
        articleTocTitles: std.StringHashMap([]const u8) = undefined,

        // target relative-file-path
        //htmlFiles: std.ArrayList([]const u8) = .empty,
        cssFiles: list.List([]const u8) = .{},
        jsFiles: list.List([]const u8) = .{},
        imageFiles: std.ArrayList([]const u8) = .empty,
        coverImageIndex: ?usize = null,

        fn init(project: *const Project, appContext: *AppContext) @This() {
            return .{
                .project = project,
                .appContext = appContext,
                ._arenaAllocator = .init(appContext.allocator),
            };
        }

        fn deinit(session: *@This()) void {
            // session.articleDirEntries.deinit(session.arenaAllocator);
            session._arenaAllocator.deinit();
        }

        fn initMore(session: *@This(), buildNameSuffix: []const u8) !void {
            session.builder.session = session;

            session.arenaAllocator = session._arenaAllocator.allocator();

            session.fileMapping = .init(session.arenaAllocator);
            session.targetFileContents = .init(session.arenaAllocator);
            session.articleTocTitles = .init(session.arenaAllocator);

            try session.confirmProjectVersion();
            try session.confirmBuildOutputPath(buildNameSuffix);
        }

        fn confirmProjectVersion(session: *@This()) !void {
            const project = session.project;
            session.projectVersion = if (project.configEx.basic.@"project-version") |option| blk: {
                const version = std.mem.trim(u8, option.data, " \t");
                if (std.mem.eql(u8, version, "@git-commit")) {
                    break :blk AppContext.getLastGitCommitString(project.path, session.arenaAllocator);
                } else break :blk version;
            } else "";
        }

        fn confirmBuildOutputPath(session: *@This(), buildNameSuffix: []const u8) !void {
            const project = session.project;

            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buffer);

            try w.writeAll(project.workspacePath);
            try w.writeByte(std.fs.path.sep);
            try w.writeAll(AppContext.buildOutputDirname);
            try w.writeByte(std.fs.path.sep);
            if (project.path.len != project.workspacePath.len) {
                try w.writeAll("@projects");
                try w.writeByte(std.fs.path.sep);
            }
            try w.writeAll(project.dirname());
            if (session.projectVersion.len > 0) {
                try w.writeByte('-');
                try w.writeAll(session.projectVersion);
            }
            try w.writeAll(buildNameSuffix);

            session.buildOutputPath = try session.arenaAllocator.dupe(u8, w.buffered());

            //std.debug.print("session.buildOutputPath = {s}\n", .{session.buildOutputPath});
        }

        fn collectSeedArticles(session: *@This()) !void {
            if (session.project.configEx.basic.@"seed-articles") |option| {
                const paths = option._parsed;

                var element = paths.head;
                while (element) |e| {
                    const path = e.value;

                    if (!std.mem.eql(u8, std.fs.path.extension(path), ".tmd")) {
                        try session.appContext.stderr.print("Navigation file must be a .tmd extension: {s}\n", .{path});
                        try session.appContext.stderr.flush();
                        return error.BadNavigationFile;
                    }

                    var pa: util.PathAllocator = .{};
                    const absPath = try util.resolveRealPath2Alloc(session.project.path, path, true, pa.allocator());
                    if (!util.isFileInDir(absPath, session.project.path)) {
                        try session.appContext.stderr.print("Navigation file must be in project path ({s}): {s}.\n", .{ session.project.path, absPath });
                        try session.appContext.stderr.flush();
                        return error.BadNavigationFile;
                    }

                    const index = session.articleFiles.items.len;
                    _ = try session.tryToRegisterFile(.{ .local = absPath }, .article);
                    std.debug.assert(index + 1 == session.articleFiles.items.len);

                    element = e.next;
                }
            } else {
                var dirEntries: DirEntries = try .collectFromRootDir(session.project.path, session.arenaAllocator, AppContext.isValidArticlePathName);
                dirEntries.sort();

                const T = struct {
                    session: *BuildSessionType,

                    pub fn onEntry(self: *const @This(), fullPath: []const u8, dirTitle: ?[]const u8, depth: usize) !void {
                        if (dirTitle != null) return;
                        _ = depth;

                        _ = try self.session.tryToRegisterFile(.{ .local = fullPath }, .article);
                    }
                };

                try dirEntries.iterate(&T{ .session = session });
                session.articleDirEntries = dirEntries;
            }
        }

        fn collectKnownImages(session: *@This()) !void {
            if (session.project.coverImagePath()) |path| {
                var pa: util.PathAllocator = .{};
                const absPath = try util.resolveRealPath2Alloc(session.project.path, path, true, pa.allocator());
                const index = session.imageFiles.items.len;
                _ = try session.tryToRegisterFile(.{ .local = absPath }, .images);
                std.debug.assert(index + 1 == session.imageFiles.items.len);
                session.coverImageIndex = index;
            }

            if (session.project.configEx.basic.favicon) |option| {
                const absPath = option._parsed;

                _ = try session.tryToRegisterFile(absPath, .images);
            }
        }

        fn collectKnownCssFiles(session: *@This()) !void {
            if (session.project.configEx.basic.@"css-files") |option| {
                const paths = option._parsed;

                var element = paths.head;
                while (element) |e| {
                    const filePath = e.value;
                    _ = try session.tryToRegisterFile(filePath, .css);
                    element = e.next;
                }
            }
        }

        fn collectKnownJsFiles(session: *@This()) !void {
            if (session.project.configEx.basic.@"js-files") |option| {
                const paths = option._parsed;

                var element = paths.head;
                while (element) |e| {
                    const filePath = e.value;
                    _ = try session.tryToRegisterFile(filePath, .js);
                    element = e.next;
                }
            }
        }

        // The string in filePath is not hold after tryToRegisterFile exits.
        pub fn tryToRegisterFile(session: *@This(), filePath: Config.FilePath, filePurpose: FilePurpose) ![]const u8 {
            const targetPath = switch (filePath) {
                .builtin => |name| blk: {
                    if (session.fileMapping.get(filePath)) |targetPath| return targetPath;

                    const info = try session.appContext.getBuiltinFileInfo(name);
                    switch (filePurpose) {
                        .images => {
                            const extInfo = tmd.getExtensionInfo(info.extension);
                            if (!extInfo.isImage) return error.NonImageBuiltinAssertUsedAsImage;
                        },
                        .css => if (info.extension != .css) return error.NonCssBuiltinAssertUsedAsCss,
                        else => return error.NoSuchBuiltinAssets,
                    }

                    const targetPath, const fresh = try session.builder.calTargetFilePath(filePath, filePurpose);
                    try session.fileMapping.put(try filePath.dupe(session.arenaAllocator), targetPath);

                    if (fresh) {
                        switch (filePurpose) {
                            .images => try session.imageFiles.append(session.arenaAllocator, targetPath),
                            .css => {
                                const element = try session.cssFiles.createElement(session.arenaAllocator, true);
                                element.value = targetPath;
                            },
                            else => unreachable,
                        }
                    }

                    break :blk targetPath;
                },
                .remote => |url| url,
                .local => |absPath| blk: {
                    if (session.fileMapping.get(filePath)) |targetPath| return targetPath;

                    const targetPath, const fresh = try session.builder.calTargetFilePath(filePath, filePurpose);
                    try session.fileMapping.put(try filePath.dupe(session.arenaAllocator), targetPath);

                    if (fresh) {
                        switch (filePurpose) {
                            .article => {
                                std.debug.assert(absPath.len > session.project.path.len + 1);
                                if (!AppContext.isValidArticlePath(absPath[session.project.path.len + 1 ..])) {
                                    try session.appContext.stderr.print("Bad article path: {s}\n", .{absPath});
                                    try session.appContext.stderr.flush();
                                    return error.InvalidArticlePath;
                                }

                                const dupeAbsPath = try session.arenaAllocator.dupe(u8, absPath);
                                try session.articleFiles.append(session.arenaAllocator, dupeAbsPath);
                            },
                            //.html => try session.htmlFiles.append(session.arenaAllocator, targetPath),
                            .images => try session.imageFiles.append(session.arenaAllocator, targetPath),
                            .css => {
                                const element = try session.cssFiles.createElement(session.arenaAllocator, true);
                                element.value = targetPath;
                            },
                            .js => {
                                const element = try session.jsFiles.createElement(session.arenaAllocator, true);
                                element.value = targetPath;
                            },
                        }
                    }

                    break :blk targetPath;
                },
            };

            if (builtin.mode == .Debug and false) {
                switch (filePath) {
                    .remote => |url| {
                        std.debug.print(
                            \\[register] {s}: {s}
                            \\
                        , .{ @tagName(filePurpose), url });
                    },
                    inline .builtin, .local => |absPathOrName| {
                        if (targetPath.len <= 128) std.debug.print(
                            \\[register] {s}: {s}
                            \\    -> {s}
                            \\
                        , .{ @tagName(filePurpose), absPathOrName, targetPath }) else std.debug.print(
                            \\[register] {s}: {s}
                            \\    -> {s}... ({} bytes)
                            \\
                        , .{ @tagName(filePurpose), absPathOrName, targetPath[0..64], targetPath.len });
                    },
                }
            }

            return targetPath;
        }

        fn writeAssetElementLinksInHead(session: *@This(), w: *std.Io.Writer, docTargetFilePath: []const u8) !void {
            if (session.project.configEx.basic.favicon) |option| {
                const faviconPath = option._parsed;
                try gen.writeFaviconAssetInHead(w, faviconPath, session, docTargetFilePath, targetPathSep);
            }

            if (session.project.configEx.basic.@"css-files") |option| {
                const cssFiles = option._parsed;

                if (cssFiles.head) |head| {
                    var element = head;
                    while (true) {
                        const next = element.next;
                        const cssFilePath = element.value;

                        try gen.writeCssAssetInHead(w, cssFilePath, session, docTargetFilePath, targetPathSep);

                        if (next) |nxt| element = nxt else break;
                    }
                }
            }

            if (session.project.configEx.basic.@"js-files") |option| {
                const jsFiles = option._parsed;

                if (jsFiles.head) |head| {
                    var element = head;
                    while (true) {
                        const next = element.next;
                        const jsFilePath = element.value;

                        try gen.writeJsAssetInHead(w, jsFilePath, session, docTargetFilePath, targetPathSep);

                        if (next) |nxt| element = nxt else break;
                    }
                }
            }
        }

        pub fn renderArticles(session: *@This(), buffer: []u8, tmdRenderResultHandler: anytype) !void {
            if (session.articleFiles.items.len == 0) return;

            var tmdDocRenderer: DocRenderer = .init(
                session.appContext,
                session.project.configEx,
                session.createDocRendererCallbacks(),
            );

            var i: usize = 0;
            while (i < session.articleFiles.items.len) : (i += 1) {
                const absPath = session.articleFiles.items[i];
                const targetPath = session.fileMapping.get(.{ .local = absPath }) orelse return error.ArticleNotRegistered;
                // ToDo: only check it in debug mode.
                if (session.targetFileContents.get(targetPath)) |_| return error.ArticleAlreadyCollected;

                const tmdDoc, const renderBuffer = blk: {
                    var remainingBuffer = buffer;

                    const tmdContent = try util.readFile(null, absPath, .{ .buffer = remainingBuffer[0..Project.maxTmdFileSize] }, session.appContext.stderr);
                    remainingBuffer = remainingBuffer[tmdContent.len..];

                    var fba = std.heap.FixedBufferAllocator.init(remainingBuffer);
                    const fbaAllocator = fba.allocator();
                    const tmdDoc = try tmd.Doc.parse(tmdContent, fbaAllocator);
                    remainingBuffer = remainingBuffer[fba.end_index..];

                    break :blk .{ tmdDoc, remainingBuffer };
                };

                var wa: std.Io.Writer.Allocating = try .initCapacity(session.arenaAllocator, 128);
                if (!try tmdDoc.writePageTitle(&wa.writer, .htmlTocItem)) {
                    try wa.writer.writeAll("???");
                }
                try session.articleTocTitles.put(absPath, wa.written());

                var w: std.Io.Writer = .fixed(renderBuffer);
                try tmdDocRenderer.render(&w, .{
                    .doc = &tmdDoc,
                    .sourceFilePath = absPath,
                    .targetFilePath = targetPath,
                });
                const htmlContent = w.buffered();
                const cachedContent = try tmdRenderResultHandler.makeCachedArticleContent(targetPath, htmlContent);

                try session.targetFileContents.put(targetPath, cachedContent);
            }

            if (session.articleDirEntries) |_| {} else {
                const T = struct {
                    articleFiles: @TypeOf(session.articleFiles),
                    index: usize = 0,

                    pub fn next(self: *@This()) ?[]const u8 {
                        if (self.index >= self.articleFiles.items.len) return null;

                        defer self.index += 1;
                        return self.articleFiles.items[self.index];
                    }

                    pub fn reset(self: *@This()) void {
                        self.index = 0;
                    }
                };

                var t: T = .{ .articleFiles = session.articleFiles };

                var dirEntries: DirEntries = try .collectFromFilepaths(session.project.path, &t, session.appContext.allocator, session.arenaAllocator);
                defer session.articleDirEntries = dirEntries;

                if (true) return;

                // unnecessary ...

                dirEntries.sort();

                // re-store articles in sorted order

                const H = struct {
                    const E = struct {
                        path: []const u8,
                        order: usize,

                        fn compare(_: void, x: @This(), y: @This()) bool {
                            if (x.order < y.order) return true;
                            if (x.order > y.order) return false;
                            unreachable;
                        }
                    };

                    s: @TypeOf(session),
                    articles: []E,
                    index: usize = 0,

                    fn init(s: @TypeOf(session), count: usize) !@This() {
                        return .{
                            .s = s,
                            .articles = try s.appContext.allocator.alloc(E, count),
                        };
                    }

                    fn deinit(h: *@This()) void {
                        h.s.appContext.allocator.free(h.articles);
                    }

                    pub fn onEntry(h: *@This(), fullPath: []const u8, dirTitle: ?[]const u8, depth: usize) !void {
                        if (dirTitle != null) return;
                        _ = depth;

                        h.articles[h.index] = .{
                            .path = h.s.articleTocTitles.getKey(fullPath) orelse unreachable,
                            .order = h.index,
                        };
                        h.index += 1;
                    }
                };

                var h: H = try .init(session, session.articleFiles.items.len);
                defer h.deinit();

                try dirEntries.iterate(&h);
                std.debug.assert(h.index == h.articles.len);

                std.sort.pdq(H.E, h.articles, {}, H.E.compare);

                const items = session.articleFiles.items;
                for (h.articles) |a| {
                    items[a.order] = a.path;
                }
            }
        }

        const TmdGenCustomHandler = struct {
            const MutableData = struct {
                relativePathWriter: gen.RelativePathWriter = undefined,
                externalBlockGenerator: gen.ExternalBlockGenerator = undefined,
            };

            session: *BuildSessionType,
            tmdDocInfo: DocRenderer.TmdDocInfo,
            mutableData: *MutableData,

            fn init(bs: *BuildSessionType, tmdDocInfo: DocRenderer.TmdDocInfo, mutableData: *MutableData) TmdGenCustomHandler {
                return .{
                    .session = bs,
                    .tmdDocInfo = tmdDocInfo,
                    .mutableData = mutableData,
                };
            }

            fn makeTmdGenOptions(handler: *const @This()) tmd.GenOptions {
                return .{
                    .callbacks = .{
                        .context = handler,
                        .fnGetCustomBlockGenerator = getCustomBlockGenerator,
                        .fnGetMediaUrlGenerator = getMediaUrlGenerator,
                        .fnGetLinkUrlGenerator = getLinkUrlGenerator,
                    },
                };
            }

            fn getCustomBlockGenerator(ctx: *const anyopaque, custom: *const tmd.BlockType.Custom) !?tmd.Generator {
                const handler: *const @This() = @ptrCast(@alignCast(ctx));
                return handler.mutableData.externalBlockGenerator.makeGenerator(handler.session.project.configEx, handler.tmdDocInfo.doc, custom);
            }

            fn getLinkUrlGenerator(ctx: *const anyopaque, link: *const tmd.Link, isCurrentPage: *?bool) !?tmd.Generator {
                std.debug.assert(isCurrentPage.* == null);

                const handler: *const @This() = @ptrCast(@alignCast(ctx));

                const url = link.url.?;
                const targetPath, const fragment = switch (url.manner) {
                    .relative => |v| blk: {
                        if (v.extension) |ext| switch (ext) {
                            .tmd => {
                                std.debug.assert(v.isTmdFile());

                                var pa: util.PathAllocator = .{};
                                const absPath = try util.resolvePathFromFilePathAlloc(handler.tmdDocInfo.sourceFilePath, url.base, true, pa.allocator());
                                const targetPath = try handler.session.tryToRegisterFile(.{ .local = absPath }, .article);

                                isCurrentPage.* = std.mem.eql(u8, targetPath, handler.tmdDocInfo.targetFilePath);

                                break :blk .{ targetPath, url.fragment };
                            },
                            .txt, .html, .htm, .xhtml, .css, .js => {
                                try handler.session.appContext.stderr.print("Liking to .html/.htm/.xhtml/.css/.js fiels is not supported now: {s}\n", .{url.base});
                                try handler.session.appContext.stderr.flush();
                                return error.DocOtherThanTmdNotSupportedNow;
                            },
                            .png, .gif, .jpg, .jpeg, .ico => {
                                var pa: util.PathAllocator = .{};
                                const absPath = try util.resolvePathFromFilePathAlloc(handler.tmdDocInfo.sourceFilePath, url.base, true, pa.allocator());
                                break :blk .{ try handler.session.tryToRegisterFile(.{ .local = absPath }, .images), "" };
                            },
                        };

                        return null;
                    },
                    else => return null,
                };

                // ToDo: standalone-html build needs different handling.

                return handler.mutableData.relativePathWriter.asGenBacklback(
                    null,
                    targetPath,
                    targetPathSep,
                    handler.tmdDocInfo.targetFilePath,
                    targetPathSep,
                    fragment,
                );
            }

            fn getMediaUrlGenerator(ctx: *const anyopaque, link: *const tmd.Link) !?tmd.Generator {
                const handler: *const @This() = @ptrCast(@alignCast(ctx));

                const url = link.url.?;
                const targetPath = switch (url.manner) {
                    .relative => blk: {
                        var pa: util.PathAllocator = .{};
                        const absPath = try util.resolvePathFromFilePathAlloc(handler.tmdDocInfo.sourceFilePath, url.base, true, pa.allocator());
                        break :blk try handler.session.tryToRegisterFile(.{ .local = absPath }, .images);
                    },
                    else => return null,
                };

                return handler.mutableData.relativePathWriter.asGenBacklback(
                    null,
                    targetPath,
                    targetPathSep,
                    handler.tmdDocInfo.targetFilePath,
                    targetPathSep,
                    "",
                );
            }
        };

        fn renderTmdDoc(session: *@This(), w: *std.io.Writer, tmdDocInfo: DocRenderer.TmdDocInfo) !void {
            var mutableData: TmdGenCustomHandler.MutableData = undefined;
            var tmdGenCustomHandler: TmdGenCustomHandler = .init(session, tmdDocInfo, &mutableData);
            const genOptions = tmdGenCustomHandler.makeTmdGenOptions();
            try tmdDocInfo.doc.writeHTML(w, genOptions, session.appContext.allocator);
        }

        fn createDocRendererCallbacks(session: *@This()) DocRenderer.Callbacks {
            const T = struct {
                fn filepathInAttributeCallback(owner: *anyopaque, r: *const DocRenderer, filePath: Config.FilePath) !void {
                    const bs: *BuildSessionType = @ptrCast(@alignCast(owner));

                    const tmdDocInfo = if (r.tmdDocInfo) |info| info else unreachable;

                    switch (filePath) {
                        .builtin => @panic("filepath-in-attribute with built-in assets is not supported now"),
                        .remote => |url| try tmd.writeUrlAttributeValue(r.w, url),
                        .local => |absPath| {
                            const ext = tmd.extension(absPath) orelse return error.UnrecognizedExtension;
                            const purpose: Project.FilePurpose = switch (ext) {
                                .css => .css,
                                .js => .js,
                                else => blk: {
                                    const info = tmd.getExtensionInfo(ext);
                                    if (!info.isImage) return error.UnsupportedFileFormat;
                                    break :blk .images;
                                },
                            };

                            const targetPath = try bs.tryToRegisterFile(.{ .local = absPath }, purpose);

                            try gen.writeRelativeUrl(r.w, targetPath, targetPathSep, tmdDocInfo.targetFilePath, targetPathSep);
                        },
                    }
                }

                fn assetElementsInHeadCallback(owner: *anyopaque, r: *const DocRenderer) !void {
                    const bs: *BuildSessionType = @ptrCast(@alignCast(owner));
                    try bs.writeAssetElementLinksInHead(r.w, r.tmdDocInfo.?.targetFilePath);
                }

                fn pageTitleInHeadCallback(owner: *anyopaque, r: *const DocRenderer) !void {
                    const bs: *BuildSessionType = @ptrCast(@alignCast(owner));
                    _ = bs;

                    const tmdDocInfo = if (r.tmdDocInfo) |info| info else unreachable;

                    if (!try tmdDocInfo.doc.writePageTitle(r.w, .inHtmlHead)) {
                        try r.w.writeAll("Untitled"); // ToDo: localization
                    }
                }

                fn pageContentInBodyCallback(owner: *anyopaque, r: *const DocRenderer) !void {
                    const bs: *BuildSessionType = @ptrCast(@alignCast(owner));

                    const tmdDocInfo = if (r.tmdDocInfo) |info| info else unreachable;

                    try bs.renderTmdDoc(r.w, tmdDocInfo);
                }

                fn generateHtmlCallback(owner: *anyopaque, r: *const DocRenderer, embeddingTmdDoc: *tmd.Doc, embeddingTmdDocSourceFilePath: []const u8) !void {
                    const bs: *BuildSessionType = @ptrCast(@alignCast(owner));

                    const tmdDocInfo = if (r.tmdDocInfo) |info| info else unreachable;

                    const embeddingDocInfo: @TypeOf(tmdDocInfo) = .{
                        .doc = embeddingTmdDoc,
                        .sourceFilePath = embeddingTmdDocSourceFilePath,
                        .targetFilePath = tmdDocInfo.targetFilePath,
                    };

                    try bs.renderTmdDoc(r.w, embeddingDocInfo);
                }
            };

            return .{
                .owner = session,
                .filepathInAttributeCallback = T.filepathInAttributeCallback,
                .assetElementsInHeadCallback = T.assetElementsInHeadCallback,
                .pageTitleInHeadCallback = T.pageTitleInHeadCallback,
                .pageContentInBodyCallback = T.pageContentInBodyCallback,
                //.navContentInBodyCallback = T.navContentInBodyCallback,
                .generateHtmlCallback = T.generateHtmlCallback,
            };
        }
    };
}
