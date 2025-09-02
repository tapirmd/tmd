const std = @import("std");

const tmd = @import("tmd");

const AppContext = @import("./common/AppContext.zig");
const Project = @import("./common/Project.zig");

const maxTmdFileSize = 1 << 23; // 8M
const bufferSize = maxTmdFileSize * 8;

pub const TmdToStaticWebsite = struct {
    pub fn argsDesc() []const u8 {
        return "[ProjectDir | ProjectConfigFile]...";
    }

    pub fn briefDesc() []const u8 {
        return "Generate static websites for the specified projects.";
    }

    pub fn completeDesc() []const u8 {
        return 
        \\Without any argument specified, the current directory
        \\will be used. 
        ;
    }

    pub fn process(ctx: *AppContext, args: []const []const u8) !void {
        try build(ctx, args, Project.StaticWebsiteBuilder);
    }
};

pub const TmdToEpub = struct {
    pub fn argsDesc() []const u8 {
        return "[ProjectDir | ProjectConfigFile]...";
    }

    pub fn briefDesc() []const u8 {
        return "Generate EPUB ebook files for the specified projects.";
    }

    pub fn completeDesc() []const u8 {
        return 
        \\Without any argument specified, the current directory
        \\will be used. 
        ;
    }

    pub fn process(ctx: *AppContext, args: []const []const u8) !void {
        try build(ctx, args, Project.EpubBuilder);
    }
};

pub const TmdToStandaloneHtml = struct {
    pub fn argsDesc() []const u8 {
        return "[ProjectDir | ProjectConfigFile]...";
    }

    pub fn briefDesc() []const u8 {
        return "Generate standalone HTML files for the specified projects.";
    }

    pub fn completeDesc() []const u8 {
        return 
        \\Without any argument specified, the current directory
        \\will be used. 
        ;
    }

    pub fn process(ctx: *AppContext, args: []const []const u8) !void {
        try build(ctx, args, Project.StandaloneHtmlBuilder);
    }
};

fn build(ctx: *AppContext, args: []const []const u8, builder: anytype) !void {
    const paths = if (args.len > 0) args else blk: {
        const default: []const []const u8 = &.{"."};
        break :blk default;
    };
    for (paths) |path| {
        const result = try ctx.regOrGetProject(path);

        switch (result) {
            .invalid => try ctx.stderr.print("Path ({s}) is not valid project path.\n", .{path}),
            .registered => {},
            .new => |project| try project.build(ctx, builder),
        }
    }
}
