const std = @import("std");

const tmd = @import("tmd");

const cmd = @import("cmd");

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

const maxTmdFileSize = 1 << 23; // 8M
const bufferSize = maxTmdFileSize * 16;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const gpaAllocator = gpa.allocator();

    const buffer = try gpaAllocator.alloc(u8, bufferSize);
    defer gpaAllocator.free(buffer);

    const args = try std.process.argsAlloc(gpaAllocator);
    defer std.process.argsFree(gpaAllocator, args);

    std.debug.assert(args.len > 0);

    if (args.len <= 1) {
        try printUsages();
        std.process.exit(0);
        unreachable;
    }

    try fmtTest(args[1..], buffer, gpaAllocator);
    return;
}

fn fmtTest(paths: []const []const u8, buffer: []u8, allocator: std.mem.Allocator) !void {
    var fi = cmd.FileIterator.init(paths, allocator);
    while (try fi.next()) |entry| {
        if (!std.mem.eql(u8, std.fs.path.extension(entry.filePath), ".tmd")) continue;

        //std.debug.print("> [{s}] {s}\n", .{entry.dirPath, entry.filePath});

        try fmtTestFile(entry, buffer, allocator);
    }
}

fn fmtTestFile(entry: cmd.FileIterator.Entry, buffer: []u8, allocator: std.mem.Allocator) !void {
    // load file

    const tmdContent = try cmd.readFileIntoBuffer(entry.dir, entry.filePath, buffer[0..maxTmdFileSize], stderr);
    var remainingBuffer = buffer[tmdContent.len..];

    // parse file

    var fba = std.heap.FixedBufferAllocator.init(remainingBuffer);
    var fbaAllocator = fba.allocator();
    const tmdDoc = try tmd.Doc.parse(tmdContent, fbaAllocator);
    remainingBuffer = remainingBuffer[fba.end_index..];

    // test 1: data -> parse -> write w/o formatting -> data2. assert(data == data2)
    if (true) {
        // write file without formatting

        var fbs = std.io.fixedBufferStream(remainingBuffer);
        try tmdDoc.writeTMD(fbs.writer(), false);
        const newContent = fbs.getWritten();
        if (!std.mem.eql(u8, tmdContent, newContent)) {
            std.debug.print("test 1 failed: [{s}] {s}\n", .{ entry.dirPath, entry.filePath });
            return;
        }
    }

    // write file with formatting

    var fbs = std.io.fixedBufferStream(remainingBuffer);
    try tmdDoc.writeTMD(fbs.writer(), true);
    const newTmdContent = fbs.getWritten();
    if (std.mem.eql(u8, tmdContent, newTmdContent)) return;
    remainingBuffer = remainingBuffer[newTmdContent.len..];

    // test 2: data -> parse -> write with formating -> data2 -> re-parse -> write with formating -> data3. assert(data2 == data3)
    const newTmdDoc = blk: {
        // re-parse

        fba = std.heap.FixedBufferAllocator.init(remainingBuffer);
        fbaAllocator = fba.allocator();
        const newTmdDoc = try tmd.Doc.parse(newTmdContent, fbaAllocator);
        remainingBuffer = remainingBuffer[fba.end_index..];

        // write file with formatting again.

        fbs = std.io.fixedBufferStream(remainingBuffer);
        try newTmdDoc.writeTMD(fbs.writer(), true);
        const newNewTmdContent = fbs.getWritten();
        if (!std.mem.eql(u8, newNewTmdContent, newTmdContent)) {
            std.debug.print("test 2 failed: [{s}] {s}\n", .{ entry.dirPath, entry.filePath });
            return;
        }
        //remainingBuffer = remainingBuffer[newNewTmdContent.len..];

        break :blk newTmdDoc;
    };

    // test 3: to_html(tmdDoc) and to_html(newTmdDoc) should be identical
    {
        fbs = std.io.fixedBufferStream(remainingBuffer);
        try tmdDoc.writeHTML(fbs.writer(), .{}, allocator);
        const html = fbs.getWritten();
        remainingBuffer = remainingBuffer[html.len..];

        fbs = std.io.fixedBufferStream(remainingBuffer);
        try newTmdDoc.writeHTML(fbs.writer(), .{}, allocator);
        const newHtml = fbs.getWritten();
        //remainingBuffer = remainingBuffer[newHtml.len..];

        if (!std.mem.eql(u8, html, newHtml)) {
            std.debug.print("test 3 failed: [{s}] {s}\n", .{ entry.dirPath, entry.filePath });
            return;
        }
    }
}

// "toolset" is better than "toolkit" here?
// https://www.difference.wiki/toolset-vs-toolkit/
fn printUsages() !void {
    try stdout.print(
        \\TapirMD fmt test tool v{s}
        \\
        \\Usages:
        \\  tmd-fmt-test TMD-paths...
        \\
    , .{tmd.version});
}
