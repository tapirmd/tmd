const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd");
const list = @import("list");

const AppContext = @import("AppContext.zig");
const Config = @import("Config.zig");
const DocTemplate = @import("DocTemplate.zig");
const util = @import("util.zig");

pub const ConfigEx = struct {
    basic: Config = .{},
    path: []const u8 = "", // blank is for default config etc.

    // Keys are Template.Token.Command.Argument.value.ptr.
    parsedCommandArgs: std.AutoHashMap([*]const u8, ParsedCommandArg) = undefined,

    pub const ParsedCommandArg = union(enum) {
        filePath: Config.FilePath,
        tmdDocInfo: struct {
            doc: *tmd.Doc,
            sourceFilePath: []const u8,
        },
    };
};

pub fn getTmdConfigEx(ctx: *AppContext, absPath: []const u8, isDir: bool) !*ConfigEx {
    if (isDir) return &ctx._defaultConfigEx;

    return ctx.loadTmdConfigEx(absPath);
}

// absFilePath should be an existing file path.
pub fn loadTmdConfigEx(ctx: *AppContext, absFilePath: []const u8) !*ConfigEx {
    var arenaAllocator: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arenaAllocator.deinit();

    var loadedFilesInSession: std.BufSet = .init(arenaAllocator.allocator());
    // defer loadedFilesInSession.deinit();

    std.debug.print("========= absFilePath: {s}\n", .{absFilePath});

    return loadTmdConfigInternal(ctx, absFilePath, &loadedFilesInSession);
}

fn loadTmdConfigInternal(ctx: *AppContext, absFilePath: []const u8, loadedFilesInSession: *std.BufSet) !*ConfigEx {
    if (loadedFilesInSession.contains(absFilePath)) {
        try ctx.stderr.print("error: loop config reference: {s}", .{absFilePath});
        try ctx.stderr.flush();
        return error.ConfigFileLoopReference;
    }

    if (ctx._configPathToExMap.get(absFilePath)) |ex| return ex;

    const configFilePath = try ctx.arenaAllocator.dupe(u8, absFilePath);
    //errdefer ctx.arenaAllocator.free(configFilePath);

    //var configEx = ctx._configPathToExMap.getPtr(configFilePath).?;
    // List element addresses will never change, but std map element addresses may change.
    const element = try ctx._configExList.createElement(ctx.arenaAllocator, true);
    const configEx = &element.value;
    configEx.* = .{ .path = configFilePath };
    try ctx._configPathToExMap.put(configFilePath, configEx);

    {
        const fileContent = try util.readFile(ctx.io, null, configFilePath, .{ .alloc = .{ .allocator = ctx.allocator, .maxFileSize = Config.maxConfigFileSize } }, ctx.stderr);
        defer ctx.allocator.free(fileContent);

        try ctx.parseAndFillConfig(&configEx.basic, fileContent);
    }

    try loadedFilesInSession.insert(configFilePath);
    //var hasBase = false;
    if (configEx.basic.@"based-on") |baseConfigPath| if (baseConfigPath.path.len > 0) {
        var pa: util.PathAllocator = .{};
        const baseFilePath = try util.resolvePathFromFilePathAlloc(configFilePath, baseConfigPath.path, true, pa.allocator());
        //defer ctx.allocator.free(baseFilePath);

        const baseConfigEx = try loadTmdConfigInternal(ctx, baseFilePath, loadedFilesInSession);
        configEx.basic.@"based-on" = .{ .path = configEx.path };

        ctx.mergeTmdConfig(&configEx.basic, &baseConfigEx.basic);

        //hasBase = true;
    };

    try parseConfigOptions(ctx, configEx);

    if (builtin.mode == .debug and false) {
        printConfigEx(configEx);
    }

    configEx.parsedCommandArgs = .init(ctx.arenaAllocator);

    return configEx;
}

const defaultConfigContent = @embedFile("tmd.settings-default");

pub fn parseDefaultConfig(ctx: *AppContext) !void {
    try ctx.parseAndFillConfig(&ctx._defaultConfigEx.basic, defaultConfigContent);
    try parseConfigOptions(ctx, &ctx._defaultConfigEx);
    ctx._defaultConfigEx.parsedCommandArgs = .init(ctx.arenaAllocator);
}

pub fn parseAndFillConfig(ctx: *AppContext, config: *Config, configContent: []const u8) !void {
    var tmdDoc = try tmd.Doc.parse(configContent, ctx.allocator);
    defer tmdDoc.destroy();

    try fillTmdConfig(ctx, &tmdDoc, config);
}

// ToDo: it would be better to collect the config type info at compile time,
//       and use the info to do run-time reflections.

fn fillTmdConfig(ctx: *AppContext, tmdDoc: *const tmd.Doc, config: *Config) !void {
    const tmdConfig = tmdDoc.asConfig();

    const structTypeInfo = @typeInfo(Config).@"struct";

    inline for (structTypeInfo.field_names, structTypeInfo.field_types) |fieldName, fieldType| {
        if (tmdConfig.stringValue(fieldName)) |opv| {
            const optionValue = try ctx.arenaAllocator.dupe(u8, opv);
            const tmdBlock = tmdDoc.blockByID(fieldName).?;
            const blockAttributes = tmdBlock.attributes.?;
            const class = blockAttributes.classes;

            const UnionType = @typeInfo(fieldType).optional.child;
            const unionTypeInfo = @typeInfo(UnionType).@"union";
            const uFieldNames = unionTypeInfo.field_names;
            const uFieldTypes = unionTypeInfo.field_types;

            if (class.len == 0) {
                if (uFieldTypes[0] == []const u8) {
                    @field(config, fieldName) = @unionInit(UnionType, uFieldNames[0], optionValue);
                }
            } else inline for (uFieldNames, uFieldTypes) |uFieldName, uFieldType| {
                if ((uFieldType == []const u8) and std.mem.eql(u8, uFieldName, class)) {
                    @field(config, fieldName) = @unionInit(UnionType, uFieldName, optionValue);
                }
            }
        }
    }

    // ToDo: tmdConfig.traverseBlockIDs(), to find unrecognized option names.
}

fn printConfigEx(ex: *const ConfigEx) void {
    std.debug.print("===== {s} =====\n", .{ex.path});
    printTmdConfig(&ex.basic);
}

pub fn printTmdConfig(config: *const Config) void {
    const structTypeInfo = @typeInfo(Config).@"struct";
    std.debug.print("{{\n", .{});
    defer std.debug.print("}}\n", .{});

    inline for (structTypeInfo.fields) |structField| {
        std.debug.print("   .{s}=", .{structField.name});
        defer std.debug.print(",\n", .{});
        if (@field(config, structField.name)) |unionValue| {
            std.debug.print("{{\n", .{});
            defer std.debug.print("   }}", .{});
            const UnionType = @typeInfo(structField.type).optional.child;
            const TagType = std.meta.Tag(UnionType);
            const unionTypeInfo = @typeInfo(UnionType).@"union";
            const unionTypeFields = unionTypeInfo.fields;

            const activeTag = std.meta.activeTag(unionValue);
            inline for (unionTypeFields) |unionField| {
                if (std.meta.stringToEnum(TagType, unionField.name) == activeTag) {
                    if (unionField.type == []const u8) {
                        const v = @field(unionValue, unionField.name);
                        std.debug.print("      .{s}=\"{s}\",\n", .{ unionField.name, v });
                    } else { // if (std.mem.eql(u8, "_parsed", unionField.name)) {
                        std.debug.print("      .{s}=[...],\n", .{unionField.name});
                    }
                }
            }
        } else std.debug.print("null", .{});
    }
}

pub fn mergeTmdConfig(_: *const AppContext, config: *Config, base: *const Config) void {
    const structTypeInfo = @typeInfo(Config).@"struct";

    inline for (structTypeInfo.field_names) |fieldName| {
        if (@field(base, fieldName)) |unionValue| {
            if (@field(config, fieldName) == null)
                @field(config, fieldName) = unionValue;
        }
    }
}

fn parseFilePath(ctx: *AppContext, configEx: *ConfigEx, path: []const u8) !Config.FilePath {
    switch (tmd.checkFilePathType(path)) {
        .remote => return .{ .remote = path },
        .local => {
            if (std.mem.startsWith(u8, path, "@") and std.Io.Dir.path.extension(path).len == 0)
                return .{ .builtin = path };

            const absPath = try util.resolvePathFromFilePathAlloc(configEx.path, path, true, ctx.arenaAllocator);
            return .{ .local = absPath };
        },
        .invalid => return error.InvalidFilePath,
    }
}

fn parseConfigOptions(ctx: *AppContext, configEx: *ConfigEx) !void {
    if (configEx.basic.@"custom-block-generators") |*customBlockGenerators| handle: {
        const configData = switch (customBlockGenerators.*) {
            .data => |data| data,
            ._parsed => break :handle,
        };

        var map: std.StringHashMap(Config.CustomBlockGenerator) = .init(ctx.arenaAllocator);
        // errdefer map.destroy();

        var lineIt = std.mem.tokenizeAny(u8, configData, "\n");
        while (lineIt.next()) |lineItem| {
            const lineData = std.mem.trim(u8, lineItem, " \t\r");
            if (lineData.len == 0) continue;
            if (std.mem.startsWith(u8, lineData, "%%")) continue;

            var tokenIt = std.mem.tokenizeAny(u8, lineData, " \t");
            const customContentType = tokenIt.next() orelse continue;

            const commandName = tokenIt.next() orelse continue;
            if (std.mem.startsWith(u8, commandName, "@")) {
                if (commandName.len == 1) return error.BuiltinCustomBlockGeneratorUnspecified;
                if (tokenIt.next() != null) return error.BuiltinCustomBlockGeneratorNeedsNotArgs;
                const appName = commandName[1..];
                if (!std.ascii.eqlIgnoreCase(appName, "html")) return error.UnrecognizedBuiltinCustomBlockGenerator;

                const r = try map.getOrPut(customContentType);
                if (r.found_existing) return error.DuplicateustomBlockGenerator;
                r.value_ptr.* = .{ .builtin = appName };
                continue;
            }

            const ExternalGenerator = @FieldType(Config.CustomBlockGenerator, "external");
            var generator: ExternalGenerator = .{ .argsCount = 1 };
            generator.argsArray[0] = commandName;

            while (tokenIt.next()) |tokenItem| {
                if (generator.argsCount + 1 >= generator.argsArray.len) return error.TooManyCustomBlockGeneratorArgs;

                generator.argsArray[generator.argsCount] = tokenItem;
                generator.argsCount += 1;
            }

            const r = try map.getOrPut(customContentType);
            if (r.found_existing) return error.DuplicateustomBlockGenerator;
            r.value_ptr.* = .{ .external = generator };
        }

        customBlockGenerators.* = .{
            ._parsed = map,
        };
    }

    if (configEx.basic.@"html-page-template") |*htmlPageTemplate| handle: {
        const content, const ownerFilePath = switch (htmlPageTemplate.*) {
            .data => |data| .{ data, configEx.path },
            .path => |path| blk: {
                const absPath = try util.resolvePathFromFilePathAlloc(configEx.path, path, true, ctx.arenaAllocator);
                const data = try util.readFile(ctx.io, null, absPath, .{ .alloc = .{ .allocator = ctx.arenaAllocator, .maxFileSize = DocTemplate.maxTemplateSize } }, ctx.stderr);
                break :blk .{ data, absPath };
            },
            ._parsed => break :handle,
        };

        htmlPageTemplate.* = .{
            ._parsed = try DocTemplate.parseTemplate(content, ownerFilePath, ctx, ctx.arenaAllocator, ctx.stderr),
        };
    }

    if (configEx.basic.@"project-seed-articles") |*seedArticles| handle: {
        const seedArticlesData = switch (seedArticles.*) {
            .data => |data| std.mem.trim(u8, data, " \t\r\n"),
            ._parsed => break :handle,
        };

        var paths = list.List([]const u8){};
        // errdefer path.destroy(null, ctx.arenaAllocator);

        var it = std.mem.tokenizeAny(u8, seedArticlesData, "\n");
        while (it.next()) |item| {
            const line = std.mem.trim(u8, item, " \t\r");
            if (line.len == 0) continue;

            const absPath = try util.resolvePathFromFilePathAlloc(configEx.path, line, true, ctx.arenaAllocator);

            const element = try paths.createElement(ctx.arenaAllocator, true);
            element.value = absPath;
        }

        seedArticles.* = .{
            ._parsed = paths,
        };
    }

    if (configEx.basic.favicon) |*favicon| handle: {
        const faviconPath = switch (favicon.*) {
            .path => |path| path,
            ._parsed => break :handle,
        };

        favicon.* = .{
            ._parsed = try parseFilePath(ctx, configEx, faviconPath),
        };
    }

    if (configEx.basic.@"css-files") |*cssFiles| handle: {
        const cssFilesData = switch (cssFiles.*) {
            .data => |data| std.mem.trim(u8, data, " \t\r\n"),
            ._parsed => break :handle,
        };

        var paths = list.List(Config.FilePath){};
        // errdefer path.destroy(null, ctx.arenaAllocator);

        var it = std.mem.tokenizeAny(u8, cssFilesData, "\n");
        while (it.next()) |item| {
            const line = std.mem.trim(u8, item, " \t\r");
            if (line.len == 0) continue;
            const filePath = try parseFilePath(ctx, configEx, line);

            const element = try paths.createElement(ctx.arenaAllocator, true);
            element.value = filePath;
        }

        cssFiles.* = .{
            ._parsed = paths,
        };
    }

    if (configEx.basic.@"js-files") |*jsFiles| handle: {
        const jsFilesData = switch (jsFiles.*) {
            .data => |data| std.mem.trim(u8, data, " \t\r\n"),
            ._parsed => break :handle,
        };

        var paths = list.List(Config.FilePath){};
        // errdefer path.destroy(null, ctx.arenaAllocator);

        var it = std.mem.tokenizeAny(u8, jsFilesData, "\n");
        while (it.next()) |item| {
            const line = std.mem.trim(u8, item, " \t\r");
            if (line.len == 0) continue;
            const filePath = try parseFilePath(ctx, configEx, line);

            const element = try paths.createElement(ctx.arenaAllocator, true);
            element.value = filePath;
        }

        jsFiles.* = .{
            ._parsed = paths,
        };
    }
}
