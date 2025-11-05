const std = @import("std");

const tmd = @import("tmd");

const AppContext = @import("./common/AppContext.zig");
const util = @import("./common/util.zig");

const maxTmdFileSize = 1 << 23; // 8M
const bufferSize = maxTmdFileSize * 4;

pub const AstDumper = struct {
    pub fn argsDesc() []const u8 {
        return "a-tmd-file";
    }

    pub fn briefDesc() []const u8 {
        return "Dump the AST structure of .tmd file.";
    }

    pub fn completeDesc() []const u8 {
        return 
        \\The 'dump-ast' command only accepts exact one argument,
        \\which should be a TapirMD doc.
        ;
    }

    pub fn process(ctx: *AppContext, args: []const []const u8) !void {
        const tmdFilePath = switch (args.len) {
            0 => {
                try ctx.stderr.print("Too few arguments.\n", .{});
                std.process.exit(1);
            },
            1 => args[0],
            else => {
                try ctx.stderr.print("Too many arguments.\n", .{});
                std.process.exit(1);
            },
        };

        const buffer = try ctx.allocator.alloc(u8, bufferSize);
        defer ctx.allocator.free(buffer);

        try dumpAstOfTmdDoc(tmdFilePath, buffer, ctx);
    }

    fn dumpAstOfTmdDoc(filePath: []const u8, buffer: []u8, ctx: *AppContext) !void {
        var remainingBuffer = buffer;

        // load file

        const tmdContent = try util.readFile(null, filePath, .{ .buffer = remainingBuffer[0..maxTmdFileSize] }, ctx.stderr);
        remainingBuffer = remainingBuffer[tmdContent.len..];

        // parse file

        var fba = std.heap.FixedBufferAllocator.init(remainingBuffer);
        // defer fba.reset(); // unnecessary
        const fbaAllocator = fba.allocator();
        var tmdDoc = try tmd.Doc.parse(tmdContent, fbaAllocator);
        // defer tmdDoc.destroy(); // unnecessary

        tmdDoc.dumpAst();
    }
};
