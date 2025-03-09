const std = @import("std");

const tmd = @import("tmd");

const cmd = @import("cmd.zig");

const maxTmdFileSize = 1 << 23; // 8M
const bufferSize = maxTmdFileSize * 4;

pub fn format(args: []const []u8, allocator: std.mem.Allocator) !u8 {
    const buffer = try allocator.alloc(u8, bufferSize);
    defer allocator.free(buffer);

    if (args.len == 0) {
        try cmd.stderr.print("No tmd files specified.", .{});
        std.process.exit(1);
    }

    var localBuffer = buffer;

    for (args) |arg| {

        // load file

        const tmdContent = try cmd.readFileIntoBuffer(arg, localBuffer[0..maxTmdFileSize]);
        const remainingBuffer = localBuffer[tmdContent.len..];

        // parse file

        var fba = std.heap.FixedBufferAllocator.init(remainingBuffer);
        // defer fba.reset(); // unnecessary
        const fbaAllocator = fba.allocator();

        var tmdDoc = try tmd.Doc.parse(tmdContent, fbaAllocator);
        // defer tmdDoc.destroy(); // if fba, then this is actually unnecessary.

        // write file

        const outputFilename: []const u8 = arg;

        const formatBuffer = try fbaAllocator.alloc(u8, remainingBuffer.len - fba.end_index);
        // defer fbaAllocator.free(formatBuffer); // unnecessary
        var fbs = std.io.fixedBufferStream(formatBuffer);

        try tmdDoc.writeTMD(fbs.writer(), true);

        // write file

        const newContent = fbs.getWritten();
        if (!std.mem.eql(u8, tmdContent, newContent)) {
            const tmdFile = try std.fs.cwd().createFile(outputFilename, .{});
            defer tmdFile.close();
            try tmdFile.writeAll(newContent);
            try cmd.stdout.print(
                \\{s}
                \\
            , .{outputFilename});
        }
    }

    return 0;
}
