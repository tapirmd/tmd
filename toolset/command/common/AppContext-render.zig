const std = @import("std");

const tmd = @import("tmd");

const AppContext = @import("AppContext.zig");
const DocTemplate = @import("DocTemplate.zig");
const util = @import("util.zig");

pub fn renderTmdDoc(ctx: *AppContext, w: anytype, tmdDoc: *const tmd.Doc, tmdFilePath: []const u8, configEx: *const AppContext.ConfigEx) !void {
    const template = configEx.basic.@"html-page-template".?._parsed;

    const tfcc = TemplateFunctionCallContext{
        .ctx = ctx,
        .tmdDoc = tmdDoc,
        .tmdFilePath = tmdFilePath,
        .configEx = configEx,
        .template = template,
        .w = w.any(),
    };

    try template.render(&tfcc);
}

const TemplateFunctionCallContext = struct {
    ctx: *AppContext,
    tmdDoc: *const tmd.Doc,
    tmdFilePath: []const u8,
    configEx: *const AppContext.ConfigEx,
    template: *DocTemplate,
    w: std.io.AnyWriter,

    pub fn onTemplateText(tfcc: *const @This(), text: []const u8) !void {
        try tfcc.w.writeAll(text);
    }

    pub fn onTemplateTag(_: *const @This(), tag: DocTemplate.Token.Command) !void {
        _ = tag;
    }

    pub fn onTemplateCommand(tfcc: *const @This(), command: DocTemplate.Token.Command) !void {
        const FunctionType = fn (tfcc: *const TemplateFunctionCallContext, args: ?*DocTemplate.Token.Command.Argument) anyerror!void;
        const func: *const FunctionType = @ptrCast(@alignCast(command.obj));

        try func(tfcc, command.name, command.args);
        //func(tfcc, command.name, command.args) catch |err| {std.debug.print("@@@ error: {s}\n", .{@errorName(err)});} ;
    }
};

pub const TemplateFunctions = struct {
    pub fn @"generate-url"(tfcc: *const TemplateFunctionCallContext, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        _ = tfcc;
        _ = args;
    }

    pub fn @"asset-elements-in-head"(tfcc: *const TemplateFunctionCallContext, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        _ = tfcc;
        _ = args;
    }

    pub fn @"page-title-in-head"(tfcc: *const TemplateFunctionCallContext, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;

        if (!try tfcc.tmdDoc.writePageTitleInHtmlHead(tfcc.w)) try tfcc.w.writeAll("Untitled");
    }

    pub fn @"page-content-in-body"(tfcc: *const TemplateFunctionCallContext, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;

        try tfcc.tmdDoc.writeHTML(tfcc.w, .{}, tfcc.ctx.allocator);
    }

    pub fn @"embed-file-content"(tfcc: *const TemplateFunctionCallContext, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args == null) {
            try tfcc.ctx.stderr.print("function [embed-file-content] needs at least one argument.\n", .{});
            return error.TooFewTemplateFunctionArguments;
        }

        const arg = args.?;
        const content, _ = try loadFileContent(tfcc.ctx, tfcc, arg);
        try tfcc.w.writeAll(content);

        if (arg.next != null) return error.TooManyTemplateFunctionArguments;
    }

    pub fn @"base64-encode"(tfcc: *const TemplateFunctionCallContext, _: []const u8, args: ?*DocTemplate.Token.Command.Argument) !void {
        if (args == null) {
            try tfcc.ctx.stderr.print("function [base64-encode] needs at least one argument.\n", .{});
            return error.TooFewTemplateFunctionArguments;
        }

        const arg = args.?;
        const content = try base64FileContent(tfcc.ctx, tfcc, arg);
        try tfcc.w.writeAll(content);

        if (arg.next != null) return error.TooManyTemplateFunctionArguments;
    }
};

pub fn initTemplateFunctions(ctx: *AppContext) !void {
    var functions: std.StringHashMap(*const anyopaque) = .init(ctx.arenaAllocator);

    const structTypeInfo = @typeInfo(TemplateFunctions).@"struct";
    inline for (structTypeInfo.decls) |decl| {
        try functions.put(decl.name, @ptrCast(@alignCast(&@field(TemplateFunctions, decl.name))));
    }

    ctx._templateFunctions = functions;
}

pub const FileCacheKey = struct {
    op: enum {
        none,
        base64,
    },
    path: []const u8, // ToDo: need a FileCachePath {.embeded, .fs} ?
};

pub const FileCacheKeyContext = struct {
    pub fn hash(self: @This(), key: FileCacheKey) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        const op_tag = @intFromEnum(key.op);
        hasher.update(std.mem.asBytes(&op_tag));
        hasher.update(key.path);
        return hasher.final();
    }

    pub fn eql(self: @This(), a: FileCacheKey, b: FileCacheKey) bool {
        _ = self;
        if (a.op != b.op) return false;
        return std.mem.eql(u8, a.path, b.path);
    }
};

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

const faviconFileContent = @embedFile("favicon.jpg");

fn loadFileContent(ctx: *AppContext, tfcc: *const TemplateFunctionCallContext, arg: *DocTemplate.Token.Command.Argument) !struct { []const u8, []const u8 } {
    const filePath = arg.value;
    const relativeToFinalConfigFile = try readTheOnlyBoolArgument(arg.next);
    const relativeToPath = if (relativeToFinalConfigFile) tfcc.configEx.path else tfcc.template.ownerFilePath;

    const absFilePath = if (std.mem.startsWith(u8, filePath, "@")) filePath else try util.resolvePathFromFilePath(relativeToPath, filePath, true, ctx.arenaAllocator);

    if (std.mem.startsWith(u8, absFilePath, "@")) {
        const asset = absFilePath[1..];
        const content = if (std.mem.eql(u8, asset, "css")) tmd.exampleCSS else if (std.mem.eql(u8, asset, "favicon")) faviconFileContent else {
            try ctx.stderr.print("unknown asset: {s}\n", .{asset});
            return error.UnknownBuiltinAsset;
        };

        return .{ content, absFilePath };
    }

    const cacheKey: FileCacheKey = .{
        .op = .none,
        .path = absFilePath,
    };
    if (ctx._cachedFileContents.get(cacheKey)) |content| return .{ content, absFilePath };

    const content = try util.readFile(null, absFilePath, .{ .alloc = .{ .allocator = ctx.arenaAllocator, .maxFileSize = maxCachedFileSize } }, ctx.stderr);
    try ctx._cachedFileContents.put(cacheKey, content);
    return .{ content, absFilePath };
}

fn base64FileContent(ctx: *AppContext, tfcc: *const TemplateFunctionCallContext, arg: *DocTemplate.Token.Command.Argument) ![]const u8 {
    const fileContent, const absFilePath = try loadFileContent(ctx, tfcc, arg);

    const cacheKey: FileCacheKey = .{
        .op = .base64,
        .path = absFilePath,
    };
    if (ctx._cachedFileContents.get(cacheKey)) |content| return content;

    const encoder = std.base64.standard_no_pad.Encoder;
    const encoded_len = encoder.calcSize(fileContent.len);
    const encoded = try ctx.arenaAllocator.alloc(u8, encoded_len);
    _ = encoder.encode(encoded, fileContent);

    try ctx._cachedFileContents.put(cacheKey, encoded);
    return encoded;
}
