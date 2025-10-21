const std = @import("std");

const tmd = @import("tmd");

const AppContext = @import("./command/common/AppContext.zig");

const fmt = @import("./command/fmt.zig");
const vet = @import("./command/vet.zig");
const gen = @import("./command/gen.zig");
const run = @import("./command/run.zig");
const build = @import("./command/build.zig");

const Command = union(enum) {
    fmt: fmt.Formatter,
    @"fmt-test": fmt.FormatTester,

    vet: vet.Vetter,
    @"vet-project": vet.ProjectVetter,

    // Generators ignore project-xxx settings.
    gen: gen.Generator, // gen partial html
    @"gen-full-page": gen.FullPageGenerator,

    build: build.TmdToStaticWebsite,
    @"build-epub": build.TmdToEpub,
    @"build-standalone-html": build.TmdToStandaloneHtml,

    run: run.Runner,

    help: Helper, // must be the last one
};

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const gpaAllocator = gpa.allocator();

    const args = try std.process.argsAlloc(gpaAllocator);
    defer std.process.argsFree(gpaAllocator, args);

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    std.debug.assert(args.len > 0);

    if (args.len <= 1) {
        try stdout.print(
            \\TapirMD toolset v{s}
            \\
        , .{tmd.version});

        try listCommands(stdout);
        return;
    }

    if (std.meta.stringToEnum(std.meta.FieldEnum(Command), args[1])) |cmd| {
        var appContext = AppContext.init(gpaAllocator, stdout, stderr);
        defer appContext.deinit();
        try appContext.initMore();

        switch (cmd) {
            inline else => |tag| {
                const CommandType = std.meta.TagPayload(Command, tag);
                try CommandType.process(&appContext, args[2..]);
            },
        }
    } else {
        try stderr.print("Unknown command: {s}\n", .{args[1]});

        try listCommands(stderr);
        std.process.exit(1);
        unreachable;
    }
}

fn listCommands(w: std.fs.File.Writer) !void {
    try w.print(
        \\
        \\Supported commands:
        \\
        \\
    , .{});

    const unionTypeInfo = @typeInfo(Command).@"union";
    inline for (unionTypeInfo.fields) |unionField| {
        try w.print(
            \\  {s} {s}
            \\    {s}
            \\
            \\
        ,
            .{ unionField.name, unionField.type.argsDesc(), unionField.type.briefDesc() },
        );
    }
}

const Helper = struct {
    pub fn process(ctx: *AppContext, args: []const []u8) !void {
        const unionTypeInfo = @typeInfo(Command).@"union";

        const command = switch (args.len) {
            0 => unionTypeInfo.fields[unionTypeInfo.fields.len - 1].name,
            1 => args[0],
            else => {
                try ctx.stderr.print("Too many arguments.\n\n", .{});
                std.process.exit(1);
                unreachable;
            },
        };

        if (std.meta.stringToEnum(std.meta.FieldEnum(Command), command)) |cmd| {
            switch (cmd) {
                inline else => |tag| {
                    const CommandType = std.meta.TagPayload(Command, tag);
                    try ctx.stdout.print(
                        \\{s}
                        \\
                        \\  tmd {s} {s}
                        \\
                        \\{s}
                        \\
                    , .{
                        CommandType.briefDesc(),
                        command,
                        CommandType.argsDesc(),
                        CommandType.completeDesc(),
                    });
                },
            }
        } else {
            try ctx.stderr.print("Unknown command: {s}\n", .{command});

            try listCommands(ctx.stderr);
            std.process.exit(1);
        }
    }

    pub fn argsDesc() []const u8 {
        return "[Command]";
    }

    pub fn briefDesc() []const u8 {
        return "Explain the specified command with more details.";
    }

    pub fn completeDesc() []const u8 {
        return 
        \\Run 'tmd' without arguments to list available commands.
        \\
        \\Please visit the following webpages to learn more:
        \\- https://tmd.tapirgames.com
        ;
    }
};
