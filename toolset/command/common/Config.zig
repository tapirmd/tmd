


const std = @import("std");

const Template = @import("Template.zig");

pub const maxConfigFileSize = Template.maxTemplateSize + 32 * 1024;


@"based-on": ?union(enum) {
    path: []const u8,
} = null,

/// For commands: to-html, run, build
@"custom-apps": ?union(enum) {
    data: []const u8,
    _parsed: void,
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
@"favicon": ?union(enum) {
    path: []const u8,
} = null,

// For commands: to-html, run, build
@"css-files": ?union(enum) {
    data: []const u8,
} = null,




// For commands: build
// Default to project folder name.
@"project-title": ?union(enum) {
    data: []const u8,
} = null,

// For commands: build
@"project-authors": ?union(enum) {
    data: []const u8,
} = null,

// For commands: build
@"project-tags": ?union(enum) {
    data: []const u8,
} = null,

// For commands: build
@"project-version": ?union(enum) {
    data: []const u8,
} = null,

// For commands: build
@"project-articles": ?union(enum) {
    data: []const u8,
} = null,

// For commands: build
@"project-cover-image": ?union(enum) {
    path: []const u8,
    //url: []const u8, // might be not a good idea
} = null,

