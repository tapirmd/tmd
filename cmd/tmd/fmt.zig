const std = @import("std");

const tmd = @import("tmd");

const cmd = @import("cmd");
const main = @import("main.zig");

const maxTmdFileSize = 1 << 23; // 8M
const bufferSize = maxTmdFileSize * 4;

pub fn format(args: []const []u8, allocator: std.mem.Allocator) !void {
    const buffer = try allocator.alloc(u8, bufferSize);
    defer allocator.free(buffer);

    if (args.len == 0) {
        try main.stderr.print("No tmd files specified.", .{});
        std.process.exit(1);
    }

    try fmtTmdFiles(args, buffer, allocator);
}

fn fmtTmdFiles(paths: []const []const u8, buffer: []u8, allocator: std.mem.Allocator) !void {
    var fi = cmd.FileIterator.init(paths, allocator);
    while (try fi.next()) |entry| {
        if (!std.mem.eql(u8, std.fs.path.extension(entry.filePath), ".tmd")) continue;

        //std.debug.print("> [{s}] {s}\n", .{entry.dirPath, entry.filePath});

        try fmtTmdFile(entry, buffer);
    }
}

fn fmtTmdFile(entry: cmd.FileIterator.Entry, buffer: []u8) !void {
    var remainingBuffer = buffer;

    // load file

    const tmdContent = try cmd.readFileIntoBuffer(entry.dir, entry.filePath, remainingBuffer[0..maxTmdFileSize], main.stderr);
    remainingBuffer = remainingBuffer[tmdContent.len..];

    // parse file

    var fba = std.heap.FixedBufferAllocator.init(remainingBuffer);
    // defer fba.reset(); // unnecessary
    const fbaAllocator = fba.allocator();
    var tmdDoc = try tmd.Doc.parse(tmdContent, fbaAllocator);
    // defer tmdDoc.destroy(); // unnecessary

    remainingBuffer = remainingBuffer[fba.end_index..];

    // format file

    var fbs = std.io.fixedBufferStream(remainingBuffer);
    try tmdDoc.writeTMD(fbs.writer(), true);
    const newContent = fbs.getWritten();

    // write file

    const outputFilename: []const u8 = entry.filePath;

    if (!std.mem.eql(u8, tmdContent, newContent)) {
        const tmdFile = try entry.dir.createFile(outputFilename, .{});
        defer tmdFile.close();
        try tmdFile.writeAll(newContent);
        try main.stdout.print(
            \\{s}
            \\
        , .{outputFilename});
    }
}
