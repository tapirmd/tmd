const std = @import("std");

const tmd = @import("tmd");

const AppContext = @import("AppContext.zig");
const DocTemplate = @import("DocTemplate.zig");
const config = @import("Config.zig");
const gen = @import("gen.zig");
const util = @import("util.zig");

const maxEmbeddingTmdFileSize = 1 << 19; // 0.5M

const DocRenderer = @This();

ctx: *AppContext,
configEx: *AppContext.ConfigEx,
_template: *DocTemplate,

callbackConfig: Callbacks,

w: *std.Io.Writer = undefined,
tmdDocInfo: ?TmdDocInfo = null,

pub fn init(ctx: *AppContext, configEx: *AppContext.ConfigEx, cc: Callbacks) DocRenderer {
    const _template = configEx.basic.@"html-page-template".?._parsed;
    return .{
        .ctx = ctx,
        .configEx = configEx,
        ._template = _template,
        .callbackConfig = cc,
    };
}

pub fn render(r: *DocRenderer, w: *std.Io.Writer, docInfo: ?TmdDocInfo) !void {
    r.w = w;
    r.tmdDocInfo = docInfo;

    try r._template.render(r);
}

pub const Callbacks = struct {
    // must be valid value if any of the following callback is not null.
    owner: *anyopaque = undefined,

    filepathInAttributeCallback: ?*const fn (*anyopaque, *const DocRenderer, config.FilePath) anyerror!void = null,
    assetElementsInHeadCallback: ?*const fn (*anyopaque, *const DocRenderer) anyerror!void = null,
    pageTitleInHeadCallback: ?*const fn (*anyopaque, *const DocRenderer) anyerror!void = null,
    pageContentInBodyCallback: ?*const fn (*anyopaque, *const DocRenderer) anyerror!void = null,
    //navContentInBodyCallback: ?*const fn (*anyopaque, *const DocRenderer) anyerror!void = null,
    generateHtmlCallback: ?*const fn (*anyopaque, *const DocRenderer, tmdDoc: *tmd.Doc, tmdDocAbsPath: []const u8) anyerror!void = null,

    // local-file-url
};

pub const TmdDocInfo = struct {
    doc: *const tmd.Doc = undefined, // just use its data (right?)
    sourceFilePath: []const u8 = undefined, // absolute
    targetFilePath: []const u8 = undefined, // relative to output dir
};

// as DocTemplate render context.

pub fn onTemplateText(r: *const DocRenderer, text: []const u8) !void {
    try r.w.writeAll(text);
}

//pub fn onTemplateTag(_: *const DocRenderer, tag: DocTemplate.Token.Tag) !void {
//    _ = tag;
//}

pub fn onTemplateCommand(r: *const DocRenderer, command: DocTemplate.Token.Command) !void {
    const FunctionType = fn (r: *const DocRenderer, cmdName: []const u8, args: ?*DocTemplate.Token.Command.Argument) anyerror!void;
    const func: *const FunctionType = @ptrCast(@alignCast(command.obj));

    try func(r, command.name(), command.args);
    //func(r, command.name(), command.args) catch |err| {std.debug.print("@@@ error: {s}\n", .{@errorName(err)});} ;
}

const TemplateFunctions = struct {
    pub fn @"filepath-in-attribute"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        const filePathArg = args orelse {
            try r.ctx.stderr.print("function [filepath-in-attribute] needs one argument.\n", .{});
            try r.ctx.stderr.flush();
            return error.TooFewTemplateFunctionArguments;
        };
        if (filePathArg.next != null) {
            try r.ctx.stderr.print("function [filepath-in-attribute] has too many arguments.\n", .{});
            try r.ctx.stderr.flush();
            return error.TooFewTemplateFunctionArguments;
        }

        const filePath = try r.getFilePath(filePathArg);

        if (r.callbackConfig.filepathInAttributeCallback) |callback| {
            try callback(r.callbackConfig.owner, r, filePath);
            return;
        }

        // Default implementation

        switch (filePath) {
            .builtin => return error.CannotGenerateUrlForBuiltinAssets,
            .remote => |url| try tmd.writeUrlAttributeValue(r.w, url, false),
            .local => |absPath| {
                const tmdDocInfo = if (r.tmdDocInfo) |info| info else return error.CannotGenerateUrlForLocalFileWithoutTmdDoc;

                try gen.writeRelativeUrl(r.w, absPath, std.fs.path.sep, tmdDocInfo.sourceFilePath, std.fs.path.sep);
            },
        }
    }

    pub fn @"asset-elements-in-head"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;

        if (r.callbackConfig.assetElementsInHeadCallback) |callback| {
            try callback(r.callbackConfig.owner, r);
            return;
        }

        // Default implementation

        if (r.configEx.basic.favicon) |option| {
            const faviconFilePath = option._parsed;

            try r.writeFaviconAssetInHead(faviconFilePath);
        }

        if (r.configEx.basic.@"css-files") |option| {
            const cssFiles = option._parsed;

            if (cssFiles.head) |head| {
                var element = head;
                while (true) {
                    const next = element.next;
                    const cssFilePath = element.value;

                    try r.writeCssAssetInHead(cssFilePath);

                    if (next) |nxt| element = nxt else break;
                }
            }
        }

        if (r.configEx.basic.@"js-files") |option| {
            const jsFiles = option._parsed;

            if (jsFiles.head) |head| {
                var element = head;
                while (true) {
                    const next = element.next;
                    const jsFilePath = element.value;

                    try r.writeJsAssetInHead(jsFilePath);

                    if (next) |nxt| element = nxt else break;
                }
            }
        }
    }

    pub fn @"page-title-in-head"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;

        if (r.callbackConfig.pageTitleInHeadCallback) |callback| {
            try callback(r.callbackConfig.owner, r);
            return;
        }

        // Default implementation

        if (r.tmdDocInfo) |info| {
            if (try info.doc.writePageTitle(r.w, .inHtmlHead)) return;
        }
        try r.w.writeAll("Untitled"); // ToDo: localization
    }

    pub fn @"page-content-in-body"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;

        if (r.callbackConfig.pageContentInBodyCallback) |callback| {
            try callback(r.callbackConfig.owner, r);
            return;
        }

        // Default implementation

        const tmdDocInfo = if (r.tmdDocInfo) |info| info else return;

        var mutableData: gen.BlockGeneratorCallbackOwner.MutableData = undefined;
        const co: gen.BlockGeneratorCallbackOwner = .{
            .appContext = r.ctx,
            .tmdDoc = tmdDocInfo.doc,
            .tmdDocSourceFilePath = tmdDocInfo.sourceFilePath,
            .currentPageSourceFilePath = tmdDocInfo.sourceFilePath,
            .configEx = r.configEx,
            .mutableData = &mutableData,
        };
        const genOptions: tmd.GenOptions = co.makeTmdGenOptions();

        try tmdDocInfo.doc.writeHTML(r.w, genOptions, r.ctx.allocator);
    }

    pub fn @"generate-html"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        const filePathArg = args orelse {
            try r.ctx.stderr.print("function [tmd-to-html] needs one argument.\n", .{});
            try r.ctx.stderr.flush();
            return error.TooFewTemplateFunctionArguments;
        };
        if (filePathArg.next != null) {
            try r.ctx.stderr.print("function [tmd-to-html] has too many arguments.\n", .{});
            try r.ctx.stderr.flush();
            return error.TooFewTemplateFunctionArguments;
        }

        const embeddingTmdDocInfo = try r.getTmdDocInfoFromFilePathArg(filePathArg);

        if (r.callbackConfig.generateHtmlCallback) |callback| {
            try callback(r.callbackConfig.owner, r, embeddingTmdDocInfo.doc, embeddingTmdDocInfo.sourceFilePath);
            return;
        }

        // Default implementation

        const tmdDocInfo = if (r.tmdDocInfo) |info| info else return;

        var mutableData: gen.BlockGeneratorCallbackOwner.MutableData = undefined;
        const co: gen.BlockGeneratorCallbackOwner = .{
            .appContext = r.ctx,
            .tmdDoc = embeddingTmdDocInfo.doc,
            .tmdDocSourceFilePath = embeddingTmdDocInfo.sourceFilePath,
            .currentPageSourceFilePath = tmdDocInfo.sourceFilePath,
            .configEx = r.configEx,
            .mutableData = &mutableData,
        };
        const genOptions: tmd.GenOptions = co.makeTmdGenOptions();

        try embeddingTmdDocInfo.doc.writeHTML(r.w, genOptions, r.ctx.allocator);
    }

    //pub fn @"nav-content-in-body"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
    //    if (args != null) return error.TooManyTemplateFunctionArguments;
    //
    //    if (r.callbackConfig.navContentInBodyCallback) |callback| {
    //        try callback(r.callbackConfig.owner, r);
    //        return;
    //    }
    //
    //    // @panic("nav-content-in-body template command has no default implementation");
    //}

    pub fn @"embed-file-content"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        const filePathArg = args orelse {
            try r.ctx.stderr.print("function [embed-file-content] needs one argument.\n", .{});
            try r.ctx.stderr.flush();
            return error.TooFewTemplateFunctionArguments;
        };
        if (filePathArg.next != null) {
            try r.ctx.stderr.print("function [embed-file-content] has too many arguments.\n", .{});
            try r.ctx.stderr.flush();
            return error.TooFewTemplateFunctionArguments;
        }

        // ToDo: should cached as []const u8 in ConfigEx.ParsedCommandArg.

        const filePath = try r.getFilePath(filePathArg);
        try r.ctx.writeFile(r.w, filePath, null, true);
    }

    pub fn @"base64-encode"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        const filePathArg = args orelse {
            try r.ctx.stderr.print("function [base64-encode] needs one argument.\n", .{});
            try r.ctx.stderr.flush();
            return error.TooFewTemplateFunctionArguments;
        };
        if (filePathArg.next != null) {
            try r.ctx.stderr.print("function [base64-encode] has too many arguments.\n", .{});
            try r.ctx.stderr.flush();
            return error.TooFewTemplateFunctionArguments;
        }

        // ToDo: should cached as []const u8 in ConfigEx.ParsedCommandArg.

        const filePath = try r.getFilePath(filePathArg);
        try r.ctx.writeFile(r.w, filePath, .base64, true);
    }
};

pub fn collectTemplateFunctions(ctx: *AppContext) !void {
    const structTypeInfo = @typeInfo(TemplateFunctions).@"struct";
    inline for (structTypeInfo.decls) |decl| {
        try ctx._templateFunctions.put(decl.name, @ptrCast(@alignCast(&@field(TemplateFunctions, decl.name))));
    }
}

fn getFilePath(r: *const DocRenderer, arg: *DocTemplate.Token.Command.Argument) !config.FilePath {
    const result = try r.configEx.parsedCommandArgs.getOrPut(arg.value.ptr);
    const valuePtr = if (result.found_existing) {
        switch (result.value_ptr.*) {
            .filePath => |filePath| return filePath,
            else => unreachable,
        }
    } else result.value_ptr;

    const assetPath = arg.value;
    const relativeToPath = r._template.ownerFilePath;

    const filePath: config.FilePath = switch (tmd.checkFilePathType(assetPath)) {
        .remote => .{ .remote = assetPath },
        .local => blk: {
            break :blk if (std.mem.startsWith(u8, assetPath, "@") and std.fs.path.extension(assetPath).len == 0)
                .{ .builtin = assetPath }
            else
                .{ .local = try util.resolvePathFromFilePathAlloc(relativeToPath, assetPath, true, r.ctx.arenaAllocator) };
        },
        .invalid => return error.InvalidFilePath,
    };

    valuePtr.* = .{ .filePath = filePath };
    return filePath;
}

fn getTmdDocInfoFromFilePathArg(r: *const DocRenderer, arg: *DocTemplate.Token.Command.Argument) !@FieldType(AppContext.ConfigEx.ParsedCommandArg, "tmdDocInfo") {
    const result = try r.configEx.parsedCommandArgs.getOrPut(arg.value.ptr);
    const valuePtr = if (result.found_existing) {
        switch (result.value_ptr.*) {
            .tmdDocInfo => |tmdDocInfo| return tmdDocInfo,
            else => unreachable,
        }
    } else result.value_ptr;

    const assetPath = arg.value;
    const relativeToPath = r._template.ownerFilePath;

    const tmdDocInfo: @FieldType(AppContext.ConfigEx.ParsedCommandArg, "tmdDocInfo") = switch (tmd.checkFilePathType(assetPath)) {
        .remote => return error.InvalidTmdFilePath,
        .local => blk: {
            const filePath = try util.resolvePathFromFilePathAlloc(relativeToPath, assetPath, true, r.ctx.arenaAllocator);
            const tmdContent = try util.readFile(null, filePath, .{ .alloc = .{ .allocator = r.ctx.arenaAllocator, .maxFileSize = maxEmbeddingTmdFileSize } }, r.ctx.stderr);
            const tmdDoc = try r.ctx.arenaAllocator.create(tmd.Doc);
            tmdDoc.* = try tmd.Doc.parse(tmdContent, r.ctx.arenaAllocator);
            break :blk .{
                .doc = tmdDoc,
                .sourceFilePath = filePath,
            };
        },
        .invalid => return error.InvalidTmdFilePath,
    };

    valuePtr.* = .{ .tmdDocInfo = tmdDocInfo };
    return tmdDocInfo;
}

fn writeFaviconAssetInHead(r: *const DocRenderer, faviconFilePath: config.FilePath) !void {
    switch (faviconFilePath) {
        .builtin => |name| {
            const info = try r.ctx.getBuiltinFileInfo(name);
            const mimeType = tmd.getExtensionInfo(info.extension).mime;

            try r.w.writeAll(
                \\<link rel="icon" type="
            );
            try r.w.writeAll(mimeType);
            try r.w.writeAll(
                \\" href="data:image/jpeg;base64,
            );
            try r.ctx.writeFile(r.w, faviconFilePath, .base64, false);
            try r.w.writeAll(
                \\">
                \\
            );
        },
        .local => |absPath| {
            try r.w.writeAll(
                \\<link rel="icon" href="
            );

            const tmdDocInfo = if (r.tmdDocInfo) |info| info else return error.CannotGenerateUrlForLocalFileWithoutTmdDoc;

            try gen.writeRelativeUrl(r.w, absPath, std.fs.path.sep, tmdDocInfo.sourceFilePath, std.fs.path.sep);

            try r.w.writeAll(
                \\">
                \\
            );
        },
        .remote => |url| {
            try r.w.writeAll(
                \\<link rel="icon" href="
            );

            try tmd.writeUrlAttributeValue(r.w, url, false);

            try r.w.writeAll(
                \\">
                \\
            );
        },
    }
}

fn writeCssAssetInHead(r: *const DocRenderer, cssFilePath: config.FilePath) !void {
    switch (cssFilePath) {
        .builtin => |_| {
            try r.w.writeAll(
                \\<style>
                \\
            );

            try r.ctx.writeFile(r.w, cssFilePath, null, false);

            try r.w.writeAll(
                \\</style>
                \\
            );
        },
        .local => |absPath| {
            try r.w.writeAll(
                \\<link href="
            );

            const tmdDocInfo = if (r.tmdDocInfo) |info| info else return error.CannotGenerateUrlForLocalFileWithoutTmdDoc;

            try gen.writeRelativeUrl(r.w, absPath, std.fs.path.sep, tmdDocInfo.sourceFilePath, std.fs.path.sep);

            try r.w.writeAll(
                \\" rel="stylesheet">
                \\
            );
        },
        .remote => |url| {
            try r.w.writeAll(
                \\<link href="
            );

            try tmd.writeUrlAttributeValue(r.w, url, false);

            try r.w.writeAll(
                \\" rel="stylesheet">
                \\
            );
        },
    }
}

fn writeJsAssetInHead(r: *const DocRenderer, jsFilePath: config.FilePath) !void {
    switch (jsFilePath) {
        .builtin => |_| {
            try r.w.writeAll(
                \\<script>
                \\
            );

            try r.ctx.writeFile(r.w, jsFilePath, null, false);

            try r.w.writeAll(
                \\</script>
                \\
            );
        },
        .local => |absPath| {
            try r.w.writeAll(
                \\<script src="
            );

            const tmdDocInfo = if (r.tmdDocInfo) |info| info else return error.CannotGenerateUrlForLocalFileWithoutTmdDoc;

            try gen.writeRelativeUrl(r.w, absPath, std.fs.path.sep, tmdDocInfo.sourceFilePath, std.fs.path.sep);

            try r.w.writeAll(
                \\"></script>
                \\
            );
        },
        .remote => |url| {
            try r.w.writeAll(
                \\<script src="
            );

            try tmd.writeUrlAttributeValue(r.w, url, false);

            try r.w.writeAll(
                \\"></script>
                \\
            );
        },
    }
}
