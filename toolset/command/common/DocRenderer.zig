const std = @import("std");

const tmd = @import("tmd");

const AppContext = @import("AppContext.zig");
const DocTemplate = @import("DocTemplate.zig");
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
    owner: *anyopaque,
    assetElementsInHeadCallback: *const fn (*anyopaque, *const DocRenderer) anyerror!void,
    pageTitleInHeadCallback: *const fn (*anyopaque, *const DocRenderer) anyerror!void,
    pageContentInHeadCallback: *const fn (*anyopaque, *const DocRenderer) anyerror!void,

    // nav-content-in-body

    // local-file-url
};

pub const TmdDocInfo = struct {
    doc: *const tmd.Doc = undefined,
    sourceFilePath: []const u8 = undefined, // absolute
    targetFilePath: []const u8 = undefined, // relative to output dir
};

// as DocTemplate render context.

pub fn onTemplateText(r: *const @This(), text: []const u8) !void {
    try r.w.writeAll(text);
}

pub fn onTemplateTag(_: *const @This(), tag: DocTemplate.Token.Tag) !void {
    _ = tag;
}

pub fn onTemplateCommand(r: *const @This(), command: DocTemplate.Token.Command) !void {
    const FunctionType = fn (r: *const DocRenderer, cmdName: []const u8, args: ?*DocTemplate.Token.Command.Argument) anyerror!void;
    const func: *const FunctionType = @ptrCast(@alignCast(command.obj));

    try func(r, command.name, command.args);
    //func(r, command.name, command.args) catch |err| {std.debug.print("@@@ error: {s}\n", .{@errorName(err)});} ;
}

const TemplateFunctions = struct {
    pub fn @"local-file-url"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        _ = r;
        _ = args;
    }

    pub fn @"asset-elements-in-head"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;

        try r.callbackConfig.assetElementsInHeadCallback(r.callbackConfig.owner, r);
    }

    pub fn @"page-title-in-head"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;

        try r.callbackConfig.pageTitleInHeadCallback(r.callbackConfig.owner, r);
    }

    pub fn @"page-content-in-body"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;

        try r.callbackConfig.pageContentInHeadCallback(r.callbackConfig.owner, r);
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

        const arg = args.?;
        const content, _ = try loadFileContent(r.ctx, r, arg);
        try r.w.writeAll(content);

        if (arg.next != null) return error.TooManyTemplateFunctionArguments;
    }

    pub fn @"base64-encode"(r: *const DocRenderer, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args == null) {
            try r.ctx.stderr.print("function [base64-encode] needs at least one argument.\n", .{});
            return error.TooFewTemplateFunctionArguments;
        }

        const arg = args.?;
        const content = try base64FileContent(r.ctx, r, arg);
        try r.w.writeAll(content);

        if (arg.next != null) return error.TooManyTemplateFunctionArguments;
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

// ToDo: we should only cache files <= a threshold size,
//       and allow even more larger files (but those large
//       files will not get cached).
const maxCachedFileSize = 10 * 1024 * 1024;

const faviconFileContent = @embedFile("tmd-favicon.jpg");

fn loadFileContent(ctx: *AppContext, r: *const DocRenderer, arg: *DocTemplate.Token.Command.Argument) !struct { []const u8, []const u8 } {
    const filePath = arg.value;
    const relativeToFinalConfigFile = try readTheOnlyBoolArgument(arg.next);
    const relativeToPath = if (relativeToFinalConfigFile) r.configEx.path else r.template.ownerFilePath;

    const absFilePath = if (std.mem.startsWith(u8, filePath, "@")) filePath else try util.resolvePathFromFilePath(relativeToPath, filePath, true, ctx.arenaAllocator);

    if (std.mem.startsWith(u8, absFilePath, "@")) {
        const asset = absFilePath[1..];
        const content = if (std.mem.eql(u8, asset, "tmd-default-css")) tmd.exampleCSS else if (std.mem.eql(u8, asset, "tmd-favicon")) faviconFileContent else {
            try ctx.stderr.print("unknown asset: {s}\n", .{asset});
            return error.UnknownBuiltinAsset;
        };

        return .{ content, absFilePath };
    }

    const cacheKey: AppContext.ContentKey = .{
        .op = .none,
        .path = absFilePath,
    };
    if (ctx._cachedContents.get(cacheKey)) |content| return .{ content, absFilePath };

    const content = try util.readFile(null, absFilePath, .{ .alloc = .{ .allocator = ctx.arenaAllocator, .maxFileSize = maxCachedFileSize } }, ctx.stderr);
    try ctx._cachedContents.put(cacheKey, content);
    return .{ content, absFilePath };
}

fn base64FileContent(ctx: *AppContext, r: *const DocRenderer, arg: *DocTemplate.Token.Command.Argument) ![]const u8 {
    const fileContent, const absFilePath = try loadFileContent(ctx, r, arg);

    const cacheKey: AppContext.ContentKey = .{
        .op = .base64,
        .path = absFilePath,
    };
    if (ctx._cachedContents.get(cacheKey)) |content| return content;

    const encoder = std.base64.standard_no_pad.Encoder;
    const encoded_len = encoder.calcSize(fileContent.len);
    const encoded = try ctx.arenaAllocator.alloc(u8, encoded_len);
    _ = encoder.encode(encoded, fileContent);

    try ctx._cachedContents.put(cacheKey, encoded);
    return encoded;
}
