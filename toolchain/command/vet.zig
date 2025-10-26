const std = @import("std");

const AppContext = @import("./common/AppContext.zig");

// vet Command args...

// Broken links.
// Bad media links.
// Missing tab names.
// ...

pub const Vetter = struct {
    pub fn argsDesc() []const u8 {
        return "[Dir | TmdFile]...";
    }

    pub fn briefDesc() []const u8 {
        return "Check potential mistakes in .tmd files.";
    }

    pub fn completeDesc() []const u8 {
        return 
        \\Without any argument specified, the current directory
        \\will be used. 
        ;
    }

    pub fn process(ctx: *AppContext, _: []const []const u8) !void {
        try ctx.stdout.print("Not implemented yet.\n", .{});
    }
};

pub const ProjectVetter = struct {
    pub fn argsDesc() []const u8 {
        return "[ProjectDir | ProjectConfigFile]";
    }

    pub fn briefDesc() []const u8 {
        return "Check potential mistakes in a project.";
    }

    pub fn completeDesc() []const u8 {
        return 
        \\Without any argument specified, the current directory
        \\will be used. 
        ;
    }

    pub fn process(ctx: *AppContext, _: []const []const u8) !void {
        try ctx.stdout.print("Not implemented yet.\n", .{});
    }
};
