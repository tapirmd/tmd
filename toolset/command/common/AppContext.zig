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
_cachedContents: std.HashMap(ContentKey, []const u8, FileCacheKeyContext, 16) = undefined,

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

    ctx._templateFunctions = .init(ctx.arenaAllocator);
    try @import("DocRenderer.zig").collectTemplateFunctions(ctx);

    ctx._cachedContents = .init(ctx.arenaAllocator);

    try @import("AppContext-config.zig").parseDefaultConfig(ctx);
}

pub fn deinit(ctx: *AppContext) void {
    ctx._arenaAllocator.deinit();
}

pub const ConfigEx = @import("AppContext-config.zig").ConfigEx;

pub const loadTmdConfigEx = @import("AppContext-config.zig").loadTmdConfigEx;

pub const printTmdConfig = @import("AppContext-config.zig").printTmdConfig;
pub const mergeTmdConfig = @import("AppContext-config.zig").mergeTmdConfig;
pub const parseAndFillConfig = @import("AppContext-config.zig").parseAndFillConfig;

pub const getLastGitCommitString = @import("AppContext-git.zig").getLastGitCommitString;

pub const regOrGetProject = @import("AppContext-project.zig").regOrGetProject;
pub const buildOutputDirname = @import("AppContext-project.zig").buildOutputDirname;
pub const excludeSpecialDir = @import("AppContext-project.zig").excludeSpecialDir;


pub fn getTemplateCommandObject(ctx: *AppContext, cmdName: []const u8) !?*const anyopaque {
    return ctx._templateFunctions.get(cmdName);
}

pub const ContentKey = struct {
    op: enum {
        none,
        base64,
    },
    path: []const u8, // ToDo: need a FileCachePath {.embeded, .fs} ?
};

pub const FileCacheKeyContext = struct {
    pub fn hash(self: @This(), key: ContentKey) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        const op_tag = @intFromEnum(key.op);
        hasher.update(std.mem.asBytes(&op_tag));
        hasher.update(key.path);
        return hasher.final();
    }

    pub fn eql(self: @This(), a: ContentKey, b: ContentKey) bool {
        _ = self;
        if (a.op != b.op) return false;
        return std.mem.eql(u8, a.path, b.path);
    }
};