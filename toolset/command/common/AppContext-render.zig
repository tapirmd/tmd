const std = @import("std");

const tmd = @import("tmd");

const AppContext = @import("AppContext.zig");
const Template = @import("Template.zig");

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
    template: *Template,
    w: std.io.AnyWriter,

    pub fn writeText(tfcc: *const @This(), text: []const u8) !void {
        try tfcc.w.writeAll(text);
    }

    pub fn onTag(_: *const @This(), tagText: []const u8) !void {
        _ = tagText;
    }

    pub fn callFunction(tfcc: *const @This(), funcOpaque: *const anyopaque, args: ?*Template.Token.FunctionCall.Argument) !void {
        // const FunctionType = @TypeOf(TemplateFunctions.@"generate-url");
        // !!! The above line is a bad idea. The error set of the function arg will be inferred,
        //     which might be blank error set or others, other than anyerror.
        const FunctionType = fn (tfcc: *const TemplateFunctionCallContext, args: ?*Template.Token.FunctionCall.Argument) anyerror!void;
        const func: *const FunctionType = @ptrCast(@alignCast(funcOpaque));

        try func(tfcc, args);
        //func(tfcc, args) catch |err| {std.debug.print("@@@ error: {s}\n", .{@errorName(err)});} ;
    }
};

pub const TemplateFunctions = struct {
    pub fn @"generate-url"(tfcc: *const TemplateFunctionCallContext, args: ?*Template.Token.FunctionCall.Argument) !void {
        _ = tfcc;
        _ = args;
    }

    pub fn @"asset-elements-in-head"(tfcc: *const TemplateFunctionCallContext, args: ?*Template.Token.FunctionCall.Argument) !void {
        _ = tfcc;
        _ = args;
    }

    pub fn @"page-title-in-head"(tfcc: *const TemplateFunctionCallContext, args: ?*Template.Token.FunctionCall.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;

        if (!try tfcc.tmdDoc.writePageTitle(tfcc.w)) try tfcc.w.writeAll("Untitled");
    }

    pub fn @"project-title-in-head"(tfcc: *const TemplateFunctionCallContext, args: ?*Template.Token.FunctionCall.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;

        if (!try tfcc.tmdDoc.writePageTitle(tfcc.w)) try tfcc.w.writeAll("Untitled");
    }

    pub fn @"html-snippet-in-body"(tfcc: *const TemplateFunctionCallContext, args: ?*Template.Token.FunctionCall.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;

        try tfcc.tmdDoc.writeHTML(tfcc.w, .{}, tfcc.ctx.allocator);
    }

    pub fn @"file-content"(tfcc: *const TemplateFunctionCallContext, args: ?*Template.Token.FunctionCall.Argument) !void {
        if (args == null) {
            try tfcc.ctx.stderr.print("function [file-content] needs at least one argument.\n", .{});
            return error.TooFewTemplateFunctionArguments;
        }

        const arg = args.?;
        const content, _ = try loadFileContent(tfcc.ctx, tfcc, arg);
        try tfcc.w.writeAll(content);

        if (arg.next != null) return error.TooManyTemplateFunctionArguments;
    }

    pub fn @"base64-encode"(tfcc: *const TemplateFunctionCallContext, args: ?*Template.Token.FunctionCall.Argument) !void {
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

fn readTheOnlyBoolArgument(arg_: ?*Template.Token.FunctionCall.Argument) !bool {
    const arg = arg_ orelse return false;
    if (arg.next != null) return error.TooManyTemplateFunctionArguments;

    if (std.ascii.eqlIgnoreCase(arg.value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(arg.value, "f")) return false;
    if (std.ascii.eqlIgnoreCase(arg.value, "n")) return false;
    if (std.ascii.eqlIgnoreCase(arg.value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(arg.value, "no")) return false;
    return true;
}

const maxCachedFileSize = 10 * 1024 * 1024;

const faviconFileContent = @embedFile("favicon.jpg");

fn loadFileContent(ctx: *AppContext, tfcc: *const TemplateFunctionCallContext, arg: *Template.Token.FunctionCall.Argument) !struct { []const u8, []const u8 } {
    const filePath = arg.value;
    const relativeToFinalConfigFile = try readTheOnlyBoolArgument(arg.next);
    const relativeToPath = if (relativeToFinalConfigFile) tfcc.configEx.path else tfcc.template.ownerFilePath;

    const absFilePath = if (std.mem.startsWith(u8, filePath, "@")) filePath else try AppContext.resolvePathFromFilePath(relativeToPath, filePath, ctx.arenaAllocator);

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

    const content = try ctx.readFile(absFilePath, ctx.arenaAllocator, maxCachedFileSize);
    try ctx._cachedFileContents.put(cacheKey, content);
    return .{ content, absFilePath };
}

fn base64FileContent(ctx: *AppContext, tfcc: *const TemplateFunctionCallContext, arg: *Template.Token.FunctionCall.Argument) ![]const u8 {
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
