const std = @import("std");

const tmd = @import("tmd");
const list = @import("list");

const Project = @import("Project.zig");

const AppContext = @This();

allocator: std.mem.Allocator,
stdout: *std.Io.Writer,
stderr: *std.Io.Writer,

_arenaAllocator: std.heap.ArenaAllocator,
arenaAllocator: std.mem.Allocator = undefined,

_defaultConfigEx: ConfigEx = .{},
_configPathToProjectMap: std.StringHashMap(*Project) = undefined,
_configExList: list.List(ConfigEx) = .{}, // use this list to make sure the addresses of ConfigEx will never change.
_configPathToExMap: std.StringHashMap(*ConfigEx) = undefined,
_dirPathToConfigAndRootMap: std.StringHashMap(struct { configEx: *ConfigEx, rootConfigEx: *ConfigEx, rootPath: []const u8 }) = undefined,
_templateFunctions: std.StringHashMap(*const anyopaque) = undefined,
_cachedContents: std.HashMap(ContentCacheKey, []const u8, ContentCacheKey.HashMapContext, 33) = undefined,

pub fn init(allocator: std.mem.Allocator, stdout: *std.Io.Writer, stderr: *std.Io.Writer) AppContext {
    const ctx = AppContext{
        .allocator = allocator,
        .stdout = stdout,
        .stderr = stderr,

        ._arenaAllocator = .init(allocator),
    };

    // !!! ctx._arenaAllocator will be copied and the old one is dead.
    //ctx.arenaAllocator = ctx._arenaAllocator.allocator();
    //ctx._configPathToExMap = .init(ctx.arenaAllocator);
    //ctx._dirPathToConfigAndRootMap = .init(ctx.arenaAllocator);

    return ctx;
}

pub fn initMore(ctx: *AppContext) !void {
    ctx.arenaAllocator = ctx._arenaAllocator.allocator();

    ctx._configPathToProjectMap = .init(ctx.arenaAllocator);

    ctx._configPathToExMap = .init(ctx.arenaAllocator);
    ctx._dirPathToConfigAndRootMap = .init(ctx.arenaAllocator);

    ctx._templateFunctions = .init(ctx.arenaAllocator);
    try @import("DocRenderer.zig").collectTemplateFunctions(ctx);

    ctx._cachedContents = .init(ctx.arenaAllocator);

    try @import("AppContext-config.zig").parseDefaultConfig(ctx);
}

pub fn deinit(ctx: *AppContext) void {
    ctx._arenaAllocator.deinit();
}

pub const ConfigEx = @import("AppContext-config.zig").ConfigEx;
pub const getDirectoryConfigAndRoot = @import("AppContext-config.zig").getDirectoryConfigAndRoot;
pub const loadTmdConfigEx = @import("AppContext-config.zig").loadTmdConfigEx;
pub const printTmdConfig = @import("AppContext-config.zig").printTmdConfig;
pub const mergeTmdConfig = @import("AppContext-config.zig").mergeTmdConfig;
pub const parseAndFillConfig = @import("AppContext-config.zig").parseAndFillConfig;

pub const BuiltinFileInfo = @import("AppContext-io.zig").BuiltinFileInfo;
pub const getBuiltinFileInfo = @import("AppContext-io.zig").getBuiltinFileInfo;
pub const ContentCacheKey = @import("AppContext-io.zig").ContentCacheKey;
pub const ContentOp = @import("AppContext-io.zig").ContentOp;
pub const writeFile = @import("AppContext-io.zig").writeFile;

pub const getLastGitCommitString = @import("AppContext-git.zig").getLastGitCommitString;

pub const regOrGetProject = @import("AppContext-project.zig").regOrGetProject;
pub const buildOutputDirname = @import("AppContext-project.zig").buildOutputDirname;
pub const excludeSpecialDir = @import("AppContext-project.zig").excludeSpecialDir;

pub fn getTemplateCommandObject(ctx: *AppContext, cmdName: []const u8) !?*const anyopaque {
    return ctx._templateFunctions.get(cmdName);
}
