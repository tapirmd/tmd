const std = @import("std");

const tmd = @import("tmd");

const Config = @import("Config.zig");
const Template = @import("Template.zig");

const AppContext = @This();

allocator: std.mem.Allocator,
stdout: std.fs.File.Writer,
stderr: std.fs.File.Writer,

_areraAllocator: std.heap.ArenaAllocator,
areraAllocator: std.mem.Allocator = undefined,

_commandConfigs: std.StringHashMap(ConfigEx) = undefined,
_templateFunctions: std.StringHashMap(*const anyopaque) = undefined,
_cachedFileContents: std.HashMap(FileCacheKey, []const u8, FileCacheKeyContext, 16) = undefined,

pub fn init(allocator: std.mem.Allocator, stdout: std.fs.File.Writer, stderr: std.fs.File.Writer) AppContext {
    const ctx = AppContext {
        .allocator = allocator,
        .stdout = stdout,
        .stderr = stderr,

        ._areraAllocator = .init(allocator),
    };

    // !!! ctx._areraAllocator will be copied and the old one is dead.
    //ctx.areraAllocator = ctx._areraAllocator.allocator();
    //ctx._commandConfigs = .init(ctx.areraAllocator);

    return ctx;
}

pub fn initMore(ctx: *AppContext) !void {
    ctx.areraAllocator = ctx._areraAllocator.allocator();
    ctx._commandConfigs = .init(ctx.areraAllocator);
    try ctx.initTemplateFunctions();
    ctx._cachedFileContents = .init(ctx.areraAllocator);
    try ctx.parseConfigOptions(&defaultConfigEx);
}

pub fn deinit(ctx: *AppContext) void {
    // templates.free();
    // ctx._commandConfigs.deinit();
    ctx._areraAllocator.deinit();
}

pub fn readFileIntoBuffer(ctx: AppContext, dir: std.fs.Dir, filePath: []const u8, buffer: []u8) ![]u8 {
    const file = dir.openFile(filePath, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try ctx.stderr.print("File ({s}) is not found.\n", .{filePath});
        }
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.size > buffer.len) {
        try ctx.stderr.print("File ({s}) size is too large ({} > {}).\n", .{ filePath, stat.size, buffer.len });
        return error.FileSizeTooLarge;
    }

    const readSize = try file.readAll(buffer[0..stat.size]);
    if (stat.size != readSize) {
        try ctx.stderr.print("[{s}] read size not match ({} != {}).\n", .{ filePath, stat.size, readSize });
        return error.FileSizeNotMatch;
    }
    return buffer[0..readSize];
}

pub const ConfigEx = struct {
    basic: Config = .{},
    path: []const u8 = undefined,
};

// ToDo: parse an embedded file at compile time instead.
pub var defaultConfigEx: ConfigEx = .{
    .basic = .{
        .@"html-page-template" = .{
            .data = 
                \\<!DOCTYPE html>
                \\<html>
                \\<head>
                \\<meta charset="utf-8">
                \\<meta http-equiv="X-UA-Compatible" content="IE=edge">
                \\<meta name="viewport" content="width=device-width, initial-scale=1">
                \\<title>{{{ page-title-in-head }}}</title>
                \\<link rel="icon" type="image/jpeg" href="data:image/jpeg;base64,{{ base64-encode @favicon }}">
                \\<style>
                \\{{ load-content @css }}
                \\</style>
                \\</head>
                \\<body>
                \\{{{ page-html-snippet }}}
                \\</body>
                \\</html>
            ,
        },
    },
};

pub fn loadTmdConfig(ctx: *AppContext, absFilePath: []const u8) !*ConfigEx {
    var areraAllocator: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer areraAllocator.deinit();

    var loadedFilesInSession: std.BufSet = .init(areraAllocator.allocator());
    // defer loadedFilesInSession.deinit();

    return ctx.loadTmdConfigInternal(absFilePath, &loadedFilesInSession);
}

pub fn loadTmdConfigInternal(ctx: *AppContext, absFilePath: []const u8, loadedFilesInSession: *std.BufSet) !*ConfigEx {
    if (loadedFilesInSession.contains(absFilePath)) {
        try ctx.stderr.print("error: loop config reference: {s}", .{absFilePath});
        return error.ConfigFileLoopReference;
    }

    if (ctx._commandConfigs.getPtr(absFilePath)) |valuePtr| return valuePtr;

    const configFilePath = try ctx.areraAllocator.dupe(u8, absFilePath);
    //errdefer ctx.areraAllocator.free(configFilePath);

    try ctx._commandConfigs.put(configFilePath, .{.path = configFilePath});
    //errdefer ctx.areraAllocator.remove(configFilePath);

    var configEx = ctx._commandConfigs.getPtr(configFilePath).?;
    {
        const fileContent = try std.fs.cwd().readFileAlloc(ctx.allocator, configFilePath, Config.maxConfigFileSize);
        defer ctx.allocator.free(fileContent);

        var tmdDoc = try tmd.Doc.parse(fileContent, ctx.allocator);
        defer tmdDoc.destroy();

        try ctx.fillTmdConfig(&tmdDoc, &configEx.basic);
    }

    try loadedFilesInSession.insert(configFilePath);
    var hasBase = false;
    if (configEx.basic.@"based-on") |baseConfigPath| if (baseConfigPath.path.len > 0) {
        const baseFilePath = try ctx.resolvePathFromFilePath(configFilePath, baseConfigPath.path, ctx.allocator);
        defer ctx.allocator.free(baseFilePath);

        const baseConfigEx = try ctx.loadTmdConfigInternal(baseFilePath, loadedFilesInSession);
        configEx.basic.@"based-on" = .{.path = configEx.path};

        ctx.mergeTmdConfig(&configEx.basic, &baseConfigEx.basic);

        hasBase = true;
    };

    if (!hasBase) {
        // merge with default, which should be parsed already
        ctx.mergeTmdConfig(&configEx.basic, &defaultConfigEx.basic);
    }

    try ctx.parseConfigOptions(configEx);

    if (@import("builtin").mode == .Debug and false) {
        std.debug.print("====== {s}\n", .{configFilePath});
        printTmdConfig(&configEx.basic);
    }

    return configEx;
}

// ToDo: it would be better to collect the config type info at compile time,
//       and use the info to do run-time reflections.

fn fillTmdConfig(ctx: *AppContext, tmdDoc: *const tmd.Doc, config: *Config) !void {
    const tmdConfig = tmdDoc.asConfig();

    const structTypeInfo = @typeInfo(Config).@"struct";

    inline for (structTypeInfo.fields) |structField| {
        if (tmdConfig.stringValue(structField.name)) |opv| {
            const optionValue = try ctx.areraAllocator.dupe(u8, opv);
            const tmdBlock = tmdDoc.blockByID(structField.name).?;
            const blockAttributes = tmdBlock.attributes.?;
            const class = blockAttributes.classes;

            const UnionType = @typeInfo(structField.type).optional.child;
            const unionTypeInfo = @typeInfo(UnionType).@"union";
            const unionTypeFields = unionTypeInfo.fields;

            if (class.len == 0) {
                if (unionTypeFields[0].type == []const u8) {
                    @field(config, structField.name) = @unionInit(UnionType, unionTypeFields[0].name, optionValue);
                }
            } else inline for (unionTypeFields) |unionField| {
                if ((unionField.type == []const u8) and std.mem.eql(u8, unionField.name, class)) {
                    @field(config, structField.name) = @unionInit(UnionType, unionField.name, optionValue);
                }
            }
        }
    }

    // ToDo: tmdConfig.traverseBlockIDs(), to find unrecognized option names.
}

fn printTmdConfig(config: *Config) void {
    const structTypeInfo = @typeInfo(Config).@"struct";
    std.debug.print("{{\n", .{});
    defer std.debug.print("}}\n", .{});

    inline for (structTypeInfo.fields) |structField| {
        std.debug.print("   .{s}=", .{structField.name});
        defer std.debug.print(",\n", .{});
        if (@field(config, structField.name)) |unionValue| {
            std.debug.print("   {{\n", .{});
            defer std.debug.print("   }}", .{});
            const UnionType = @typeInfo(structField.type).optional.child;
            const TagType = std.meta.Tag(UnionType);
            const unionTypeInfo = @typeInfo(UnionType).@"union";
            const unionTypeFields = unionTypeInfo.fields;

            const activeTag = std.meta.activeTag(unionValue);
            inline for (unionTypeFields) |unionField| {
                if ((unionField.type == []const u8) and
                    std.meta.stringToEnum(TagType, unionField.name) == activeTag) {
                    const v = @field(unionValue, unionField.name);
                    std.debug.print("      .{s}=\"{s}\",\n", .{unionField.name, v});
                }
            }
        } else std.debug.print("null", .{});
    }
}

fn mergeTmdConfig(_: *const AppContext, config: *Config, base: *const Config) void {
    const structTypeInfo = @typeInfo(Config).@"struct";

    inline for (structTypeInfo.fields) |structField| {
        if (@field(base, structField.name)) |unionValue| {
            if (@field(config, structField.name) == null)
                @field(config, structField.name) = unionValue;
        }
    }
}

fn parseConfigOptions(ctx: *AppContext, configEx: *ConfigEx) !void {
    if (configEx.basic.@"html-page-template") |htmlPageTemplate| {
        const content, const ownerFilePath = switch (htmlPageTemplate) {
            .data => |data| .{ data, configEx.path },
            .path => |filePath| blk: {
                const absPath = try ctx.resolvePathFromFilePath(configEx.path, filePath, ctx.areraAllocator);
                const data = try std.fs.cwd().readFileAlloc(ctx.areraAllocator, absPath, Template.maxTemplateSize);
                break :blk .{ data, absPath };
            },
            else => return,
        };

        configEx.basic.@"html-page-template" = .{ 
            ._parsed = try Template.parseTemplate(content, ownerFilePath, ctx._templateFunctions, ctx.areraAllocator, ctx.stderr),
        };
    }
}

fn initTemplateFunctions(ctx: *AppContext) !void {
    var functions: std.StringHashMap(*const anyopaque) = .init(ctx.areraAllocator);

    const structTypeInfo = @typeInfo(TemplateFunctions).@"struct";
    inline for (structTypeInfo.decls) |decl| {
        try functions.put(decl.name, @ptrCast(@alignCast(&@field(TemplateFunctions, decl.name))));
    }

    ctx._templateFunctions = functions;
}

pub fn renderTmdDoc(ctx: *AppContext, w: anytype, tmdDoc: *const tmd.Doc, tmdFilePath: []const u8, configEx: *const ConfigEx) !void {
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
    configEx: *const ConfigEx,
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

const TemplateFunctions = struct {
    pub fn @"generate-url"(tfcc: *const TemplateFunctionCallContext, args: ?*Template.Token.FunctionCall.Argument) !void {
        _ = tfcc;
        _ = args;
    }

    pub fn @"page-title-in-head"(tfcc: *const TemplateFunctionCallContext, args: ?*Template.Token.FunctionCall.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;

        if (!try tfcc.tmdDoc.writePageTitle(tfcc.w)) try tfcc.w.writeAll("Untitled");
    }

    pub fn @"page-html-snippet"(tfcc: *const TemplateFunctionCallContext, args: ?*Template.Token.FunctionCall.Argument) !void {
        if (args != null) return error.TooManyTemplateFunctionArguments;
        
        try tfcc.tmdDoc.writeHTML(tfcc.w, .{}, tfcc.ctx.allocator);
    }

    pub fn @"load-content"(tfcc: *const TemplateFunctionCallContext, args: ?*Template.Token.FunctionCall.Argument) !void {
        if (args == null) {
            try tfcc.ctx.stderr.print("function [load-content] needs at least one argument.\n", .{});
            return error.TooFewTemplateFunctionArguments;
        }

        const arg = args.?;
        const content, _ = try tfcc.ctx.loadFileContent(tfcc, arg);
        try tfcc.w.writeAll(content);

        if (arg.next != null) return error.TooManyTemplateFunctionArguments;
    }

    pub fn @"base64-encode"(tfcc: *const TemplateFunctionCallContext, args: ?*Template.Token.FunctionCall.Argument) !void {
        if (args == null) {
            try tfcc.ctx.stderr.print("function [load-content] needs at least one argument.\n", .{});
            return error.TooFewTemplateFunctionArguments;
        }

        const arg = args.?;
        const content = try tfcc.ctx.base64FileContent(tfcc, arg);
        try tfcc.w.writeAll(content);

        if (arg.next != null) return error.TooManyTemplateFunctionArguments;
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


const FileCacheKey = struct {
    op: enum {
        none,
        base64,
    },
    path: []const u8, // ToDo: need a FileCachePath {.embeded, .fs} ?
};

const FileCacheKeyContext = struct {
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


const maxCachedFileSize = 10 * 1024 * 1024;

const faviconFileContent = @embedFile("favicon.jpg");

fn loadFileContent(ctx: *AppContext, tfcc: *const TemplateFunctionCallContext, arg: *Template.Token.FunctionCall.Argument) !struct{ []const u8, []const u8} {
    const filePath = arg.value;
    const relativeToFinalConfigFile = try readTheOnlyBoolArgument(arg.next);
    const relativeToPath = if (relativeToFinalConfigFile) tfcc.configEx.path else tfcc.template.ownerFilePath;
    
    const absFilePath = if (std.mem.startsWith(u8, filePath, "@")) filePath
        else try ctx.resolvePathFromFilePath(relativeToPath, filePath, ctx.areraAllocator);

    if (std.mem.startsWith(u8, absFilePath, "@")) {
        const asset = absFilePath[1..];
        const content = if (std.mem.eql(u8, asset, "css")) tmd.exampleCSS
            else if (std.mem.eql(u8, asset, "favicon")) faviconFileContent
            else {
                try ctx.stderr.print("unknown asset: {s}\n", .{asset});
                return error.UnknownBuiltinAsset;
            };

        return .{content, absFilePath};
    }

    const cacheKey: FileCacheKey = .{
        .op = .none,
        .path = absFilePath,
    };
    if (ctx._cachedFileContents.get(cacheKey)) |content| return .{content, absFilePath};

    const content = try ctx.readFile(absFilePath, ctx.areraAllocator, maxCachedFileSize);
    try ctx._cachedFileContents.put(cacheKey, content);
    return .{content, absFilePath};
}

fn base64FileContent(ctx: *AppContext, tfcc: *const TemplateFunctionCallContext, arg: *Template.Token.FunctionCall.Argument) ![]const u8 {
    const fileContent, const absFilePath = try ctx.loadFileContent(tfcc, arg);

    const cacheKey: FileCacheKey = .{
        .op = .base64,
        .path = absFilePath,
    };
    if (ctx._cachedFileContents.get(cacheKey)) |content| return content;

    const encoder = std.base64.standard_no_pad.Encoder;
    const encoded_len = encoder.calcSize(fileContent.len);
    const encoded = try ctx.areraAllocator.alloc(u8, encoded_len);
    _ = encoder.encode(encoded, fileContent);

    try ctx._cachedFileContents.put(cacheKey, encoded);
    return encoded;
}



pub fn resolvePathFromFilePath(ctx: *const AppContext, absFilePath: []const u8, pathToResolve: []const u8, allocator: std.mem.Allocator) ![]const u8{
    const validFilePath, const needFreePath = try validatePath(absFilePath, ctx.allocator);
    defer if (needFreePath) ctx.allocator.free(validFilePath);

    const absDirPath = std.fs.path.dirname(validFilePath) orelse return error.NotFilePath;

    return try ctx.resolvePathFromAbsDirPath(absDirPath, pathToResolve, allocator);
}

pub fn resolvePathFromAbsDirPath(ctx: *const AppContext, absDirPath: []const u8, pathToResolve: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const validDirPath, const needFreeDir = try validatePath(absDirPath, ctx.allocator);
    defer if (needFreeDir) ctx.allocator.free(validDirPath);
    
    const validPath, const needFreePath = try validatePath(pathToResolve, ctx.allocator);
    defer if (needFreePath) ctx.allocator.free(validPath);
    
    return try std.fs.path.resolve(allocator, &.{ validDirPath, validPath });
}

pub fn validatePath(pathToValidate: []const u8, allocator: std.mem.Allocator) !struct{[]const u8, bool} {
    const sep = std.fs.path.sep;
    const non_sep = if (sep == '/') '\\' else '/';
    if (std.mem.containsAtLeastScalar(u8, pathToValidate, 1, non_sep)) {
        const dup = try allocator.dupe(u8, pathToValidate);
        std.mem.replaceScalar(u8, dup, non_sep, sep);
        return .{dup, true};
    }
    return .{pathToValidate, false};
}

pub fn validateURL(urlToValidate: []u8, allocator: std.mem.Allocator) !struct{[]const u8, bool} {
    if (std.mem.containsAtLeastScalar(u8, urlToValidate, 1, '\\')) {
        const dup = try allocator.dupe(u8, urlToValidate);
        std.mem.replaceScalar(u8, dup, '\\', '/');
        return .{dup, true};
    }
    return .{urlToValidate, false};
}

pub fn readFile(ctx: *const AppContext, absFilePath: []const u8, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    const file = std.fs.cwd().openFile(absFilePath, .{}) catch |err| {
        if (err == error.FileNotFound) {
            ctx.stderr.print("File ({s}) is not found.\n", .{absFilePath}) catch {};
        }
        ctx.stderr.print("=== read file [{s}] error: {s}\n", .{absFilePath, @errorName(err)});
        return err;
    };
    defer file.close();

    return try file.readToEndAlloc(allocator, max_bytes);
}