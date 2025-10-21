const std = @import("std");

const tmd = @import("tmd");

const AppContext = @import("AppContext.zig");
const DocTemplate = @import("DocTemplate.zig");
const config = @import("Config.zig");
const util = @import("util.zig");

const DocRenderer = @This();

ctx: *AppContext,
configEx: *const AppContext.ConfigEx,
template: *DocTemplate,
callbackConfig: Callbacks,

w: std.io.AnyWriter = undefined,
tmdDocInfo: ?TmdDocInfo = null,

pub fn init(ctx: *AppContext, configEx: *const AppContext.ConfigEx, cc: Callbacks) DocRenderer {
    const template = configEx.basic.@"html-page-template".?._parsed;
    return .{
        .ctx = ctx,
        .configEx = configEx,
        .template = template,
        .callbackConfig = cc,
    };
}

pub fn render(r: *DocRenderer, w: anytype, docInfo: ?TmdDocInfo) !void {
    r.w = if (@TypeOf(w) == std.io.AnyWriter) w else w.any();
    r.tmdDocInfo = docInfo;

    try r.template.render(r);
}

pub const Callbacks = struct {
    // must be valid value if any of the following callback is not null.
    owner: *anyopaque = undefined,

    urlInAttributeCallback: ?*const fn (*anyopaque, *const DocRenderer, config.FilePath) anyerror!void = null,
    assetElementsInHeadCallback: ?*const fn (*anyopaque, *const DocRenderer) anyerror!void = null,
    pageTitleInHeadCallback: ?*const fn (*anyopaque, *const DocRenderer) anyerror!void = null,
    pageContentInBodyCallback: ?*const fn (*anyopaque, *const DocRenderer) anyerror!void = null,

    // nav-content-in-body

    // local-file-url
};

pub const TmdDocInfo = struct {
    doc: *const tmd.Doc = undefined,
    sourceFilePath: []const u8 = undefined, // absolute
    targetFilePath: []const u8 = undefined, // relative to output dir
};

// as DocTemplate render context.

pub fn onTemplateText(r: *const DocRenderer, text: []const u8) !void {
    try r.w.writeAll(text);
}

pub fn onTemplateTag(_: *const DocRenderer, tag: DocTemplate.Token.Tag) !void {
    _ = tag;
}

pub fn onTemplateCommand(r: *const DocRenderer, command: DocTemplate.Token.Command) !void {
    const FunctionType = fn (r: *const DocRenderer, cmdName: []const u8, args: ?*DocTemplate.Token.Command.Argument) anyerror!void;
    const func: *const FunctionType = @ptrCast(@alignCast(command.obj));

    try func(r, command.name, command.args);
    //func(r, command.name, command.args) catch |err| {std.debug.print("@@@ error: {s}\n", .{@errorName(err)});} ;
}

const TemplateFunctions = struct {
    pub fn @"url-in-attribute"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args == null) {
            try r.ctx.stderr.print("function [url-in-attribute] needs at least one argument.\n", .{});
            return error.TooFewTemplateFunctionArguments;
        }

        // Default implementation

        const filePath, const hasMoreArgs = try getFilePath(r.ctx, r, args.?);
        if (hasMoreArgs) return error.TooManyTemplateFunctionArguments;

        if (r.callbackConfig.urlInAttributeCallback) |callback| {
            try callback(r.callbackConfig.owner, r, filePath);
            return;
        }

        switch (filePath) {
            .builtin => return error.BuiltinAssetHasNoPath,
            .remote => |url| {
                try tmd.writeUrlAttributeValue(r.w, url);
            },
            .local => |absPath| {
                var buffer: [std.fs.max_path_bytes]u8 = undefined;
                const path = try util.validatePathToPosixPathIntoBuffer(absPath, buffer[0..]);
                try tmd.writeUrlAttributeValue(r.w, path);
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

        unreachable;
    }

    pub fn @"page-title-in-head"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;

        if (r.callbackConfig.pageTitleInHeadCallback) |callback| {
            try callback(r.callbackConfig.owner, r);
            return;
        }

        // Default implementation

        if (r.tmdDocInfo) |info| {
            if (try info.doc.writePageTitleInHtmlHead(r.w)) return;
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

        try tmdDocInfo.doc.writeHTML(r.w, .{}, r.ctx.allocator);
    }

    pub fn @"nav-content-in-body"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;

        _ = r;
    }

    pub fn @"embed-file-content"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args == null) {
            try r.ctx.stderr.print("function [embed-file-content] needs at least one argument.\n", .{});
            return error.TooFewTemplateFunctionArguments;
        }

        const filePath, const hasMoreArgs = try getFilePath(r.ctx, r, args.?);
        if (hasMoreArgs) return error.TooManyTemplateFunctionArguments;

        try r.ctx.writeFile(r.w, filePath, null, true);
    }

    pub fn @"base64-encode"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args == null) {
            try r.ctx.stderr.print("function [base64-encode] needs at least one argument.\n", .{});
            return error.TooFewTemplateFunctionArguments;
        }

        const filePath, const hasMoreArgs = try getFilePath(r.ctx, r, args.?);
        if (hasMoreArgs) return error.TooManyTemplateFunctionArguments;

        try r.ctx.writeFile(r.w, filePath, .base64, true);
    }
};

pub fn collectTemplateFunctions(ctx: *AppContext) !void {
    const structTypeInfo = @typeInfo(TemplateFunctions).@"struct";
    inline for (structTypeInfo.decls) |decl| {
        try ctx._templateFunctions.put(decl.name, @ptrCast(@alignCast(&@field(TemplateFunctions, decl.name))));
    }
}

fn readTheOnlyBoolArgument(arg_: ?*DocTemplate.Token.Command.Argument) !bool {
    const arg = arg_ orelse return false;
    if (arg.next != null) return error.TooManyTemplateFunctionArguments;

    if (std.ascii.eqlIgnoreCase(arg.value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(arg.value, "f")) return false;
    if (std.ascii.eqlIgnoreCase(arg.value, "n")) return false;
    if (std.ascii.eqlIgnoreCase(arg.value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(arg.value, "no")) return false;
    return true;
}

fn getFilePath(ctx: *AppContext, r: *const DocRenderer, arg: *DocTemplate.Token.Command.Argument) !struct { config.FilePath, bool } {
    const assetPath = arg.value;
    const relativeToFinalConfigFile = try readTheOnlyBoolArgument(arg.next);
    const relativeToPath = if (relativeToFinalConfigFile) r.configEx.path else r.template.ownerFilePath;

    const filePath: config.FilePath, const hasMoreArgs = switch (tmd.checkFilePathType(assetPath)) {
        .remote => .{ .{ .remote = assetPath }, arg.next != null },
        .local => blk: {
            const filePath: config.FilePath = if (std.mem.startsWith(u8, assetPath, "@") and std.fs.path.extension(assetPath).len == 0)
                .{ .builtin = assetPath }
            else
                .{ .local = try util.resolvePathFromFilePath(relativeToPath, assetPath, true, ctx.arenaAllocator) };
            const hasMoreArgs = if (arg.next) |a| a.next != null else false;
            break :blk .{ filePath, hasMoreArgs };
        },
        .invalid => return error.InvalidFilePath,
    };

    return .{ filePath, hasMoreArgs };
}
