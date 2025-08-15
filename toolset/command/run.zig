
const std = @import("std");

const AppContext = @import("./common/AppContext.zig");

pub const Runner = struct {
    pub fn argsDesc() []const u8 {
        return "[ProjectDir | ProjectConfigFile]";
    }

    pub fn briefDesc() []const u8 {
        return "Preview or edit the specified project.";
    }

    pub fn completeDesc() []const u8 {
        return
            \\The 'run' command only accepts at most one argument.
            \\Without any argument specified, the current directory
            \\will be used.
            ;
    }

    pub fn process(ctx: *AppContext, args: []const []const u8) !void {
        const path = switch (args.len) {
            0 => ".",
            1 => args[0],
            else => {
                try ctx.stderr.print("Too many arguments.\n", .{});
                std.process.exit(1);

                // This line is needless, because std.process.exit is a noreturn function.
                // Now, if this line is enabled, no unreachable error. See:
                // https://ziggit.dev/t/should-std-process-exit-calls-be-treated-as-return-panic-alike-statements
                // return;
            },
        };

        const result = try ctx.regOrGetProject(path);
        switch (result) {
            .invalid => try ctx.stderr.print("Path ({s}) is not valid project path.\n", .{path}),
            .registered => unreachable,
            .new => |project| try project.run(ctx),
        }
    }
};