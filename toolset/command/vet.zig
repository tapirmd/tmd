
const std = @import("std");

const AppContext = @import("./common/AppContext.zig");

pub const Vetter = struct {
    pub fn argsDesc() []const u8 {
        return "[Dir | TmdFile]...";
    }

    pub fn briefDesc() []const u8 {
        return "Check potential mistakes in .tmd files.";
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
