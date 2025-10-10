const std = @import("std");

const tmd = @import("tmd");

const Project = @import("Project.zig");

const AppContext = @This();

allocator: std.mem.Allocator,
stdout: std.fs.File.Writer,
stderr: std.fs.File.Writer,

_arenaAllocator: std.heap.ArenaAllocator,
arenaAllocator: std.mem.Allocator = undefined,

_defaultConfigEx: ConfigEx = .{},
_configPathToProjectMap: std.StringHashMap(*Project) = undefined,
_configPathToExMap: std.StringHashMap(ConfigEx) = undefined,
_templateFunctions: std.StringHashMap(*const anyopaque) = undefined,
_cachedFileContents: std.HashMap(FileCacheKey, []const u8, FileCacheKeyContext, 16) = undefined,

pub fn init(allocator: std.mem.Allocator, stdout: std.fs.File.Writer, stderr: std.fs.File.Writer) AppContext {
    const ctx = AppContext{
        .allocator = allocator,
        .stdout = stdout,
        .stderr = stderr,

        ._arenaAllocator = .init(allocator),
    };

    // !!! ctx._arenaAllocator will be copied and the old one is dead.
    //ctx.arenaAllocator = ctx._arenaAllocator.allocator();
    //ctx._configPathToExMap = .init(ctx.arenaAllocator);

    return ctx;
}

pub fn initMore(ctx: *AppContext) !void {
    ctx.arenaAllocator = ctx._arenaAllocator.allocator();

    ctx._configPathToProjectMap = .init(ctx.arenaAllocator);

    ctx._configPathToExMap = .init(ctx.arenaAllocator);

    try ctx.initTemplateFunctions();

    ctx._cachedFileContents = .init(ctx.arenaAllocator);

    try ctx.parseDefaultConfig();
}

pub fn deinit(ctx: *AppContext) void {
    // templates.free();
    // ctx._configPathToExMap.deinit();
    ctx._arenaAllocator.deinit();
}

pub const ConfigEx = @import("AppContext-config.zig").ConfigEx;

pub const loadTmdConfigEx = @import("AppContext-config.zig").loadTmdConfigEx;

pub const printTmdConfig = @import("AppContext-config.zig").printTmdConfig;
pub const mergeTmdConfig = @import("AppContext-config.zig").mergeTmdConfig;
pub const parseAndFillConfig = @import("AppContext-config.zig").parseAndFillConfig;
const parseDefaultConfig = @import("AppContext-config.zig").parseDefaultConfig;
pub const getTemplateCommandObject = @import("AppContext-config.zig").getTemplateCommandObject;

const FileCacheKey = @import("AppContext-render.zig").FileCacheKey;
const FileCacheKeyContext = @import("AppContext-render.zig").FileCacheKeyContext;
const initTemplateFunctions = @import("AppContext-render.zig").initTemplateFunctions;
const renderTmdDoc = @import("AppContext-render.zig").renderTmdDoc;

pub const getLastGitCommitString = @import("AppContext-git.zig").getLastGitCommitString;

pub const regOrGetProject = @import("AppContext-project.zig").regOrGetProject;
pub const buildOutputDirname = @import("AppContext-project.zig").buildOutputDirname;
pub const excludeSpecialDir = @import("AppContext-project.zig").excludeSpecialDir;
