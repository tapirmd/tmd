
const std = @import("std");

const AppContext = @import("./common/AppContext.zig");

// Only accept one or two argument (missing means CWD).
//
// single config file arg: use it for its parent directory
// The name of config file starts with "tmd.config" and doesn't have a ".tmd" extension.
// 
// dir arg: try to use tmd.config.run, then tmd.config, then the default config.
//
// (delayed) start tmd file arg: use its parent dir.
//                    in read-only service mode.
//

pub const Runner = struct {
    pub fn argsDesc() []const u8 {
        return "[ProjectDir | ProjectConfigFile | StartTmdPage]";
    }

    pub fn briefDesc() []const u8 {
        return "Preview or edit the specified project.";
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
            \\The 'run' command only accepts one argument, which
            \\may be a path to a project (ProjectDir), a project
            \\settings file (tmd.project), or a .tmd file (StartPage).
            \\Without any argument specified, the current directory
            \\will be used.
            \\
            ;
    }

    pub fn process(_: *AppContext, _: []const []u8) !void {

    }
};