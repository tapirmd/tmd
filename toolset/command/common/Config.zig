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
@"project-navigation-article": ?union(enum) {
    path: []const u8, // relative to project dir
} = null,

//====================================================

pub const FileType = enum {
    builtin,
    local,
    remote,
};

pub const FilePath = union(FileType) {
    builtin: []const u8, // name starting with @
    local: []const u8, // abs path
    remote: []const u8, // url

    pub fn path(self: @This()) []const u8 {
        return switch (self) {
            inline else => |v| v,
        };
    }
};

pub const CustomBlockGenerator = union(enum) {
    builtin: []const u8,
    external: struct {
        argsArray: [6][]const u8 = undefined, // allow at most 6-1 args (inlcuding command name)
        argsCount: usize,
    },
};
