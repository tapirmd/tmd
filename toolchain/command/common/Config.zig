const std = @import("std");

const tmd = @import("tmd");
const list = @import("list");

const DocTemplate = @import("DocTemplate.zig");

pub const maxConfigFileSize = DocTemplate.maxTemplateSize + 32 * 1024;

//====================================================

@"based-on": ?union(enum) {
    path: []const u8,
} = null,

@"custom-block-generators": ?union(enum) {
    data: []const u8,
    _parsed: std.StringHashMap(CustomBlockGenerator), // keys are custom block types
} = null,

@"pending-url-generators": ?union(enum) {
    data: []const u8,
    _parsed: std.StringHashMap(void),
} = null,

@"html-page-template": ?union(enum) {
    data: []const u8,
    path: []const u8,
    _parsed: *DocTemplate, // ToDo: move to Ex?
} = null,

// written in asset-elements-in-head
favicon: ?union(enum) {
    path: []const u8, // relative to the containing config file
    _parsed: FilePath,
} = null,

// written in asset-elements-in-head
@"css-files": ?union(enum) {
    data: []const u8, // containing paths relative to the containing config file
    _parsed: list.List(FilePath),
} = null,

// written in asset-elements-in-head
@"js-files": ?union(enum) {
    data: []const u8, // containing paths relative to the containing config file
    _parsed: list.List(FilePath),
} = null,

// Default to project folder name.
@"project-title": ?union(enum) {
    data: []const u8,
} = null,

@"project-version": ?union(enum) {
    data: []const u8,
} = null,

@"project-cover-image": ?union(enum) {
    path: []const u8, // relative to project dir
} = null,

// Default to a temp file referencing all .tmd files in project-dir.
@"project-seed-articles": ?union(enum) {
    data: []const u8, // containing paths relative to the containing config file
    _parsed: list.List([]const u8), // relative to project dir
} = null,

//====================================================

pub const FileLocation = std.meta.Tag(FilePath);

pub const FilePath = union(enum) {
    builtin: []const u8, // name starting with @
    local: []const u8, // abs path
    remote: []const u8, // url

    pub fn path(self: @This()) []const u8 {
        return switch (self) {
            inline else => |v| v,
        };
    }

    pub fn dupe(self: @This(), a: std.mem.Allocator) !FilePath {
        return switch (self) {
            inline else => |v, tag| @unionInit(FilePath, @tagName(tag), try a.dupe(u8, v)),
        };
    }

    pub const HashMapContext = struct {
        pub fn hash(self: @This(), key: FilePath) u64 {
            _ = self;

            var hasher = std.hash.Wyhash.init(0);

            const tag: u8 = @intFromEnum(key);
            hasher.update(std.mem.asBytes(&tag));
            const pathValue = key.path();
            hasher.update(pathValue);

            return hasher.final();
        }

        pub fn eql(self: @This(), a: FilePath, b: FilePath) bool {
            _ = self;

            const tag_a: u8 = @intFromEnum(a);
            const tag_b: u8 = @intFromEnum(b);
            if (tag_a != tag_b) return false;

            const path_a = a.path();
            const path_b = b.path();

            return std.mem.eql(u8, path_a, path_b);
        }
    };
};

pub const CustomBlockGenerator = union(enum) {
    builtin: []const u8,
    external: struct {
        argsArray: [6][]const u8 = undefined, // allow at most 6-1 args (inlcuding command name)
        argsCount: usize,
    },
};
