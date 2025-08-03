
const std = @import("std");

const tmd = @import("tmd");

const AppContext = @import("./common/AppContext.zig");
const FileIterator = @import("./common/FileIterator.zig");

const maxTmdFileSize = 1 << 23; // 8M
const bufferSize = maxTmdFileSize * 8;

pub const TmdToStaticWebsite = struct {
    pub fn argsDesc() []const u8 {
        return "[ProjectDir | ProjectConfigFile]...";
    }

    pub fn briefDesc() []const u8 {
        return "Generate static websites for the specified projects.";
    }

    pub fn completeDesc(comptime command: []const u8) []const u8 {
        return (comptime briefDesc()) ++
            \\
            \\
            \\  tmd 
            ++ command ++ " " 
            ++ (comptime argsDesc()) ++
            \\
            \\
            \\Without any argument specified, the current directory
            \\will be used. 
            \\
            ;
    }

    pub fn process(ctx: *AppContext, _: []const []u8) !void {
        try ctx.stdout.print("Not implemented yet.\n", .{});
    }
};

pub const TmdToEpub = struct {
    pub fn argsDesc() []const u8 {
        return "[ProjectDir | ProjectConfigFile]...";
    }

    pub fn briefDesc() []const u8 {
        return "Generate EPUB ebook files for the specified projects.";
    }

    pub fn completeDesc(comptime command: []const u8) []const u8 {
        return (comptime briefDesc()) ++
            \\
            \\
            \\  tmd 
            ++ command ++ " " 
            ++ (comptime argsDesc()) ++
            \\
            \\
            \\Without any argument specified, the current directory
            \\will be used. 
            \\
            ;
    }

    pub fn process(ctx: *AppContext, _: []const []u8) !void {
        try ctx.stdout.print("Not implemented yet.\n", .{});
    }
};

pub const TmdToStandaloneHtml = struct {
    pub fn argsDesc() []const u8 {
        return "[ProjectDir | ProjectConfigFile]...";
    }

    pub fn briefDesc() []const u8 {
        return "Generate standalone HTML files the for specified projects.";
    }

    pub fn completeDesc(comptime command: []const u8) []const u8 {
        return (comptime briefDesc()) ++
            \\
            \\
            \\  tmd 
            ++ command ++ " " 
            ++ (comptime argsDesc()) ++
            \\
            \\
            \\Without any argument specified, the current directory
            \\will be used. 
            \\
            ;
    }

    pub fn process(ctx: *AppContext, _: []const []u8) !void {
        try ctx.stdout.print("Not implemented yet.\n", .{});
    }
};

