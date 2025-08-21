const std = @import("std");

const tmd = @import("tmd");

const AppContext = @import("AppContext.zig");
const Config = @import("Config.zig");
const Template = @import("Template.zig");

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

    if (ctx._commandConfigs.getPtr(absFilePath)) |valuePtr| return valuePtr;

    const configFilePath = try ctx.arenaAllocator.dupe(u8, absFilePath);
    //errdefer ctx.arenaAllocator.free(configFilePath);

    try ctx._commandConfigs.put(configFilePath, .{ .path = configFilePath });
    //errdefer ctx.arenaAllocator.remove(configFilePath);

    var configEx = ctx._commandConfigs.getPtr(configFilePath).?;
    {
        const fileContent = try std.fs.cwd().readFileAlloc(ctx.allocator, configFilePath, Config.maxConfigFileSize);
        defer ctx.allocator.free(fileContent);

        try ctx.parseAndFillConfig(&configEx.basic, fileContent);
    }

    try loadedFilesInSession.insert(configFilePath);
    //var hasBase = false;
    if (configEx.basic.@"based-on") |baseConfigPath| if (baseConfigPath.path.len > 0) {
        const baseFilePath = try ctx.resolvePathFromFilePath(configFilePath, baseConfigPath.path, ctx.allocator);
        defer ctx.allocator.free(baseFilePath);

        const baseConfigEx = try loadTmdConfigInternal(ctx, baseFilePath, loadedFilesInSession);
        configEx.basic.@"based-on" = .{ .path = configEx.path };

        ctx.mergeTmdConfig(&configEx.basic, &baseConfigEx.basic);

        //hasBase = true;
    };

    try parseConfigOptions(ctx, configEx);

    if (@import("builtin").mode == .Debug and false) {
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
            std.debug.print("   {{\n", .{});
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

fn parseConfigOptions(ctx: *AppContext, configEx: *ConfigEx) !void {
    if (configEx.basic.@"html-page-template") |htmlPageTemplate| {
        const content, const ownerFilePath = switch (htmlPageTemplate) {
            .data => |data| .{ data, configEx.path },
            .path => |filePath| blk: {
                const absPath = try ctx.resolvePathFromFilePath(configEx.path, filePath, ctx.arenaAllocator);
                const data = try std.fs.cwd().readFileAlloc(ctx.arenaAllocator, absPath, Template.maxTemplateSize);
                break :blk .{ data, absPath };
            },
            else => return,
        };

        configEx.basic.@"html-page-template" = .{
            ._parsed = try Template.parseTemplate(content, ownerFilePath, ctx._templateFunctions, ctx.arenaAllocator, ctx.stderr),
        };
    }
}
