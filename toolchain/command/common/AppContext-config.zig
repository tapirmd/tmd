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
    };
};

fn debugFoo(ctx: *AppContext) void {
    if (ctx._dirPathToConfigAndRootMap.get("/home/lx/projects/tapirmd/tmd/@debug/demo")) |info| {
        std.debug.print(">>>>>> {s} <<<<<\n", .{info.configEx.path});
        std.debug.print(">>>>>> \n", .{});
        std.debug.print("****** {s}\n", .{@tagName(info.configEx.basic.@"html-page-template".?)});
        std.debug.print("~~~~~~ {}\n", .{@intFromEnum(info.configEx.basic.@"html-page-template".?)});


            const ptr: usize = @intFromPtr(ctx._dirPathToConfigAndRootMap.getPtr("/home/lx/projects/tapirmd/tmd/@debug/demo").?);
            std.debug.print("### range: {} - {}\n", .{ptr, ptr+@sizeOf(ConfigEx)});
    }
}

pub fn getDirectoryConfigAndRoot(ctx1: *AppContext, absDirPath1: []const u8) !struct { *ConfigEx, []const u8, *ConfigEx } {
    
    if (ctx1._dirPathToConfigAndRootMap.get(absDirPath1)) |info| return .{ info.configEx, info.rootPath, info.rootConfigEx };

std.debug.print("====== {s}\n", .{absDirPath1});
            debugFoo(ctx1);

    // ToDo: let this function return this type.
    const ConfigsAndRoot = @TypeOf(ctx1._dirPathToConfigAndRootMap.get(absDirPath1).?); // yes, not crash.

    const T = struct {
        fn confirmDirectoryConfigAndRoot(ctx: *AppContext, absDirPath: []const u8, isFirstPath: bool) !?ConfigsAndRoot {
            std.debug.print("??? {s}\n", .{absDirPath});
            debugFoo(ctx);
            if (isFirstPath) {
                if (builtin.mode == .Debug) {
                    std.debug.assert(ctx._dirPathToConfigAndRootMap.get(absDirPath) == null);
                }
            } else if (ctx._dirPathToConfigAndRootMap.get(absDirPath)) |info| {
                if (info.configEx == &ctx._defaultConfigEx) return null else return info;
            }
            debugFoo(ctx);

            std.debug.print("??? 000\n", .{});

            const workspaceConfigEx = blk: {
            debugFoo(ctx);
                var pa: util.PathAllocator = .{};
                const workspaceFilePath = util.resolveRealPath2Alloc(absDirPath, "tmd.workspace", false, pa.allocator()) catch |err| {
                    if (err != error.FileNotFound) return err;
                    break :blk null;
                };
            debugFoo(ctx);
                //defer ctx.allocator.free(workspaceFilePath);
                break :blk try ctx.loadTmdConfigEx(workspaceFilePath);
            };
            debugFoo(ctx);

            std.debug.print("??? 1111\n", .{});

            const projectConfigEx = blk: {
            debugFoo(ctx);
                var pa: util.PathAllocator = .{};
                const projectFilePath = util.resolveRealPath2Alloc(absDirPath, "tmd.project", false, pa.allocator()) catch |err| {
                    if (err != error.FileNotFound) return err;
                    break :blk null;
                };
            debugFoo(ctx);
                //defer ctx.allocator.free(projectFilePath);
                break :blk try ctx.loadTmdConfigEx(projectFilePath);
            };
            debugFoo(ctx);

            const values = if (workspaceConfigEx) |workspaceEx| blk: {
                ctx.mergeTmdConfig(&workspaceEx.basic, &ctx._defaultConfigEx.basic);
            debugFoo(ctx);
                const rootPath = std.fs.path.dirname(workspaceEx.path).?;
                if (projectConfigEx) |projectEx| {
                    ctx.mergeTmdConfig(&projectEx.basic, &workspaceEx.basic);
                debugFoo(ctx);
                    break :blk .{ projectEx, rootPath, workspaceEx };
                }

                break :blk .{ workspaceEx, rootPath, workspaceEx };
            } else if (std.fs.path.dirname(absDirPath)) |parentDir| blk: {
            debugFoo(ctx);
                if (try confirmDirectoryConfigAndRoot(ctx, parentDir, false)) |info| {
            debugFoo(ctx);
                    if (projectConfigEx) |projectEx| {
                        ctx.mergeTmdConfig(&projectEx.basic, &info.rootConfigEx.basic);
                debugFoo(ctx);
                        break :blk .{ projectEx, info.rootPath, info.rootConfigEx };
                    }

                    break :blk .{ info.configEx, info.rootPath, info.rootConfigEx };
                }
                if (projectConfigEx) |projectEx| {
                    ctx.mergeTmdConfig(&projectEx.basic, &ctx._defaultConfigEx.basic);
                debugFoo(ctx);
                    break :blk .{ projectEx, absDirPath, projectEx };
                }
            debugFoo(ctx);

                break :blk null;
            } else if (projectConfigEx) |projectEx| blk: {
                ctx.mergeTmdConfig(&projectEx.basic, &ctx._defaultConfigEx.basic);
                debugFoo(ctx);
                break :blk .{ projectEx, absDirPath, projectEx };
            } else null;
            debugFoo(ctx);

            if (values) |info| {
                const configEx, const rootPath, const rootConfigEx = info;

                const configsAndRoot: ConfigsAndRoot = .{ .configEx = configEx, .rootPath = rootPath, .rootConfigEx = rootConfigEx };
                const dirPath = try ctx.arenaAllocator.dupe(u8, absDirPath);
                try ctx._dirPathToConfigAndRootMap.put(dirPath, configsAndRoot);
                return configsAndRoot;
            } else if (isFirstPath) {
                std.debug.assert(workspaceConfigEx == null and projectConfigEx == null);

                const configEx = &ctx._defaultConfigEx;

                const dirPath = try ctx.arenaAllocator.dupe(u8, absDirPath);
                const configsAndRoot: ConfigsAndRoot = .{ .configEx = configEx, .rootPath = dirPath, .rootConfigEx = configEx };
                try ctx._dirPathToConfigAndRootMap.put(dirPath, configsAndRoot);
                return configsAndRoot;
            } else return null;
        }
    };
            debugFoo(ctx1);
    const info = (try T.confirmDirectoryConfigAndRoot(ctx1, absDirPath1, true)).?;
    return .{ info.configEx, info.rootPath, info.rootConfigEx };
}

pub fn loadTmdConfigEx(ctx: *AppContext, absFilePath: []const u8) !*ConfigEx {
    var arenaAllocator: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arenaAllocator.deinit();

    var loadedFilesInSession: std.BufSet = .init(arenaAllocator.allocator());
    // defer loadedFilesInSession.deinit();

    return loadTmdConfigInternal(ctx, absFilePath, &loadedFilesInSession);
}

fn loadTmdConfigInternal(ctx: *AppContext, absFilePath: []const u8, loadedFilesInSession: *std.BufSet) !*ConfigEx {

            debugFoo(ctx);
            std.debug.print("aa\n", .{});

    if (loadedFilesInSession.contains(absFilePath)) {
        try ctx.stderr.print("error: loop config reference: {s}", .{absFilePath});
        return error.ConfigFileLoopReference;
    }
            debugFoo(ctx);
            std.debug.print("bb\n", .{});

    if (ctx._configPathToExMap.getPtr(absFilePath)) |valuePtr| return valuePtr;

    const configFilePath = try ctx.arenaAllocator.dupe(u8, absFilePath);
    //errdefer ctx.arenaAllocator.free(configFilePath);
            std.debug.print("bb2: {s}\n", .{configFilePath});
            debugFoo(ctx);

    try ctx._configPathToExMap.put(configFilePath, .{ .path = configFilePath });
    //errdefer ctx.arenaAllocator.remove(configFilePath);
    if (builtin.mode == .Debug) {
            {
            const ptr: usize = @intFromPtr(ctx._configPathToExMap.getPtr(configFilePath).?);
            std.debug.print("::: range: {} - {}\n", .{ptr, ptr+@sizeOf(ConfigEx)});
            }
            if (ctx._dirPathToConfigAndRootMap.getPtr("/home/lx/projects/tapirmd/tmd/@debug/demo")) |p| {
            std.debug.print("~~~~~~ {}\n", .{@intFromEnum(p.configEx.basic.@"html-page-template".?)});
            const ptr: usize = @intFromPtr(p);
            std.debug.print("@@@ range: {} - {}\n", .{ptr, ptr+@sizeOf(ConfigEx)});
            }
            
            debugFoo(ctx);
            std.debug.print("cc\n", .{});
    }

    var configEx = ctx._configPathToExMap.getPtr(configFilePath).?;
    {
        const fileContent = try std.fs.cwd().readFileAlloc(ctx.allocator, configFilePath, Config.maxConfigFileSize);
        defer ctx.allocator.free(fileContent);

        try ctx.parseAndFillConfig(&configEx.basic, fileContent);
    }
            debugFoo(ctx);
            std.debug.print("dd\n", .{});

    try loadedFilesInSession.insert(configFilePath);
    //var hasBase = false;
    if (configEx.basic.@"based-on") |baseConfigPath| if (baseConfigPath.path.len > 0) {
        var pa: util.PathAllocator = .{};
        const baseFilePath = try util.resolvePathFromFilePathAlloc(configFilePath, baseConfigPath.path, true, pa.allocator());
        //defer ctx.allocator.free(baseFilePath);
            debugFoo(ctx);
            std.debug.print("ee\n", .{});

        const baseConfigEx = try loadTmdConfigInternal(ctx, baseFilePath, loadedFilesInSession);
        configEx.basic.@"based-on" = .{ .path = configEx.path };
            debugFoo(ctx);
            std.debug.print("ff\n", .{});

        ctx.mergeTmdConfig(&configEx.basic, &baseConfigEx.basic);
            debugFoo(ctx);
            std.debug.print("gg\n", .{});

        //hasBase = true;
    };
            debugFoo(ctx);
            std.debug.print("gg\n", .{});

    try parseConfigOptions(ctx, configEx);
            debugFoo(ctx);
            std.debug.print("hh\n", .{});

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

    inline for (structTypeInfo.fields) |structField| {
        if (@field(base, structField.name)) |unionValue| {
            if (@field(config, structField.name) == null)
                @field(config, structField.name) = unionValue;
        }
    }
}

fn parseFilePath(ctx: *AppContext, configEx: *ConfigEx, path: []const u8) !Config.FilePath {
    switch (tmd.checkFilePathType(path)) {
        .remote => return .{ .remote = path },
        .local => {
            if (std.mem.startsWith(u8, path, "@") and std.fs.path.extension(path).len == 0)
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
            .path => |filePath| blk: {
                const absPath = try util.resolvePathFromFilePathAlloc(configEx.path, filePath, true, ctx.arenaAllocator);
                const data = try std.fs.cwd().readFileAlloc(ctx.arenaAllocator, absPath, DocTemplate.maxTemplateSize);
                break :blk .{ data, absPath };
            },
            ._parsed => break :handle,
        };

        htmlPageTemplate.* = .{
            ._parsed = try DocTemplate.parseTemplate(content, ownerFilePath, ctx, ctx.arenaAllocator, ctx.stderr),
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
        // errdefer path.destroy(nil, ctx.arenaAllocator);

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
        // errdefer path.destroy(nil, ctx.arenaAllocator);

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
