const std = @import("std");

const tmd = @import("tmd");
const list = @import("list");

const AppContext = @import("AppContext.zig");
const Config = @import("Config.zig");
const DocTemplate = @import("DocTemplate.zig");
const util = @import("util.zig");

pub const ConfigEx = struct {
    basic: Config = .{},
    path: []const u8 = "", // blank is for default config etc.
};

pub fn loadTmdConfigEx(ctx: *AppContext, absFilePath: []const u8) !*ConfigEx {
    var arenaAllocator: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arenaAllocator.deinit();

    var loadedFilesInSession: std.BufSet = .init(arenaAllocator.allocator());
    // defer loadedFilesInSession.deinit();

    return loadTmdConfigInternal(ctx, absFilePath, &loadedFilesInSession);
}

fn loadTmdConfigInternal(ctx: *AppContext, absFilePath: []const u8, loadedFilesInSession: *std.BufSet) !*ConfigEx {
    if (loadedFilesInSession.contains(absFilePath)) {
        try ctx.stderr.print("error: loop config reference: {s}", .{absFilePath});
        return error.ConfigFileLoopReference;
    }

    if (ctx._configPathToExMap.getPtr(absFilePath)) |valuePtr| return valuePtr;

    const configFilePath = try ctx.arenaAllocator.dupe(u8, absFilePath);
    //errdefer ctx.arenaAllocator.free(configFilePath);

    try ctx._configPathToExMap.put(configFilePath, .{ .path = configFilePath });
    //errdefer ctx.arenaAllocator.remove(configFilePath);

    var configEx = ctx._configPathToExMap.getPtr(configFilePath).?;
    {
        const fileContent = try std.fs.cwd().readFileAlloc(ctx.allocator, configFilePath, Config.maxConfigFileSize);
        defer ctx.allocator.free(fileContent);

        try ctx.parseAndFillConfig(&configEx.basic, fileContent);
    }

    try loadedFilesInSession.insert(configFilePath);
    //var hasBase = false;
    if (configEx.basic.@"based-on") |baseConfigPath| if (baseConfigPath.path.len > 0) {
        const baseFilePath = try util.resolvePathFromFilePath(configFilePath, baseConfigPath.path, true, ctx.allocator);
        defer ctx.allocator.free(baseFilePath);

        const baseConfigEx = try loadTmdConfigInternal(ctx, baseFilePath, loadedFilesInSession);
        configEx.basic.@"based-on" = .{ .path = configEx.path };

        ctx.mergeTmdConfig(&configEx.basic, &baseConfigEx.basic);

        //hasBase = true;
    };

    try parseConfigOptions(ctx, configEx);

    if (@import("builtin").mode == .Debug and true) {
        std.debug.print("====== {s}\n", .{configFilePath});
        printTmdConfig(&configEx.basic);
    }

    return configEx;
}

const defaultConfigContent = @embedFile("tmd.settings-default");

pub fn parseDefaultConfig(ctx: *AppContext) !void {
    try ctx.parseAndFillConfig(&ctx._defaultConfigEx.basic, defaultConfigContent);
    try parseConfigOptions(ctx, &ctx._defaultConfigEx);
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

    inline for (structTypeInfo.fields) |structField| {
        if (tmdConfig.stringValue(structField.name)) |opv| {
            const optionValue = try ctx.arenaAllocator.dupe(u8, opv);
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

pub fn printTmdConfig(config: *Config) void {
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
                if ((unionField.type == []const u8) and
                    std.meta.stringToEnum(TagType, unionField.name) == activeTag)
                {
                    const v = @field(unionValue, unionField.name);
                    std.debug.print("      .{s}=\"{s}\",\n", .{ unionField.name, v });
                }
            }
        } else std.debug.print("null", .{});
    }
}

pub fn mergeTmdConfig(_: *const AppContext, config: *Config, base: *const Config) void {
    const structTypeInfo = @typeInfo(Config).@"struct";

    inline for (structTypeInfo.fields) |structField| {
        if (@field(base, structField.name)) |unionValue| {
            if (@field(config, structField.name) == null)
                @field(config, structField.name) = unionValue;
        }
    }
}

pub fn getTemplateCommandObject(ctx: *AppContext, cmdName: []const u8) !?*const anyopaque {
    return ctx._templateFunctions.get(cmdName);
}

fn parseConfigOptions(ctx: *AppContext, configEx: *ConfigEx) !void {
    if (configEx.basic.@"html-page-template") |htmlPageTemplate| {
        const content, const ownerFilePath = switch (htmlPageTemplate) {
            .data => |data| .{ data, configEx.path },
            .path => |filePath| blk: {
                const absPath = try util.resolvePathFromFilePath(configEx.path, filePath, true, ctx.arenaAllocator);
                const data = try std.fs.cwd().readFileAlloc(ctx.arenaAllocator, absPath, DocTemplate.maxTemplateSize);
                break :blk .{ data, absPath };
            },
            else => return,
        };

        configEx.basic.@"html-page-template" = .{
            ._parsed = try DocTemplate.parseTemplate(content, ownerFilePath, ctx, ctx.arenaAllocator, ctx.stderr),
        };
    }

    if (configEx.basic.favicon) |favicon| {
        const faviconPath = favicon.path;
        configEx.basic.favicon = .{
            ._parsed = try util.resolvePathFromFilePath(configEx.path, faviconPath, true, ctx.arenaAllocator),
        };
    }

    if (configEx.basic.@"css-files") |cssFiles| {
        var paths = list.List([]const u8){};

        const data = std.mem.trim(u8, cssFiles.data, " \t\r\n");
        var it = std.mem.splitAny(u8, data, "\n");
        while (it.next()) |item| {
            const line = std.mem.trim(u8, item, "\n");
            if (line.len == 0) continue;
            const path = try util.resolvePathFromFilePath(configEx.path, line, true, ctx.arenaAllocator);
            const element = try paths.createElement(ctx.arenaAllocator, true);
            element.value = path;
        }

        configEx.basic.@"css-files" = .{
            ._parsed = paths,
        };
    }
}
