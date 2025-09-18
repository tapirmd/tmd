const std = @import("std");

const list = @import("list");

const Template = @import("Template.zig");

pub const maxConfigFileSize = Template.maxTemplateSize + 32 * 1024;

@"based-on": ?union(enum) {
    path: []const u8,
} = null,

/// For commands: to-html, run, build
@"custom-apps": ?union(enum) {
    data: []const u8,
    _parsed: void, // ToDo: data might contains paths
} = null,

/// For commands: to-html, run, build
@"enabled-apps": ?union(enum) {
    data: []const u8,
} = null,

// For commands: to-html, run, build
@"html-page-template": ?union(enum) {
    data: []const u8,
    path: []const u8,
    _parsed: *Template, // ToDo: move to Ex?
} = null,

// For commands: to-html, run, build
favicon: ?union(enum) {
    path: []const u8, // relative to the containing config file
    _parsed: []const u8, // abs path
} = null,

// For commands: to-html, run, build
@"css-files": ?union(enum) {
    data: []const u8, // containing paths relative to the containing config file
    _parsed: list.List([]const u8), // abs paths
} = null,

// For commands: build
// Default to project folder name.
@"project-title": ?union(enum) {
    data: []const u8,
} = null,

// For commands: build
@"project-version": ?union(enum) {
    data: []const u8,
} = null,

// For commands: build
@"project-cover-image": ?union(enum) {
    path: []const u8, // relative to project dir
} = null,

// null means using all .tmd files in project-dir
@"project-navigation-article": ?union(enum) {
    path: []const u8, // relative to project dir
} = null,

// option: add hash suffix to file names?

