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
_dirPathToConfigAndRootMap: std.StringHashMap(struct { configEx: *ConfigEx, rootConfigEx: *ConfigEx, rootPath: []const u8 }) = undefined,
_templateFunctions: std.StringHashMap(*const anyopaque) = undefined,
_cachedContents: std.HashMap(ContentCacheKey, []const u8, FileCacheKeyContext, 16) = undefined,

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

pub const FileCacheKeyContext = struct {
    pub fn hash(self: @This(), key: ContentCacheKey) u64 {
        _ = self;

        const zero: u8 = 0;
        const one: u8 = 1;

        var hasher = std.hash.Wyhash.init(0);

        if (key.contentOp) |op| {
            hasher.update(std.mem.asBytes(&one));
            const tag: u8 = @intFromEnum(op);
            hasher.update(std.mem.asBytes(&tag));
        } else hasher.update(std.mem.asBytes(&zero));

        {
            const tag: u8 = @intFromEnum(key.filePath);
            hasher.update(std.mem.asBytes(&tag));
            const path = key.filePath.path();
            hasher.update(path);
        }

        return hasher.final();
    }

    pub fn eql(self: @This(), a: ContentCacheKey, b: ContentCacheKey) bool {
        _ = self;
        if (a.contentOp != b.contentOp) return false;

        const tag_a: u8 = @intFromEnum(a.filePath);
        const tag_b: u8 = @intFromEnum(b.filePath);
        if (tag_a != tag_b) return false;

        const path_a = a.filePath.path();
        const path_b = b.filePath.path();

        return std.mem.eql(u8, path_a, path_b);
    }
};
