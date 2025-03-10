const std = @import("std");

const tmd = @import("tmd");

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

    std.process.exit(try fmtTest(args[1..], buffer, gpaAllocator));
    unreachable;
}

fn fmtTest(args: []const []u8, buffer: []u8, allocator: std.mem.Allocator) !u8 {
    const dir = std.fs.cwd();

    for (args) |path| {
        const stat = try dir.statFile(path);
        switch (stat.kind) {
            .file => try fmtTestFile(dir, path, buffer, allocator),
            .directory => try fmtTestDir(dir, path, buffer, allocator),
            else => {},
        }
    }

    return 1;
}

fn fmtTestDir(dir: std.fs.Dir, path: []const u8, buffer: []u8, allocator: std.mem.Allocator) !void {
    var subDir = try dir.openDir(path, .{ .no_follow = true, .access_sub_paths = false, .iterate = true });
    defer subDir.close();

    var walker = try subDir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file => try fmtTestFile(subDir, entry.path, buffer, allocator),
            // walker will iterate recusively, so this line is needless.
            //.directory => try fmtTestDir(subDir, entry.path, allocator),
            else => {},
        }
    }
}

fn fmtTestFile(dir: std.fs.Dir, path: []const u8, buffer: []u8, allocator: std.mem.Allocator) !void {
    const ext = std.fs.path.extension(path);
    if (!std.mem.eql(u8, ext, ".tmd")) return;

    //std.debug.print("> {s}\n", .{path});

    var file = try dir.openFile(path, .{});
    defer file.close();

    // load file

    const tmdContent = try readFileIntoBuffer(dir, path, buffer[0..maxTmdFileSize]);
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
            std.debug.print("test 1 failed: {s}\n", .{path});
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
            std.debug.print("test 2 failed: {s}\n", .{path});
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
            std.debug.print("test 3 failed: {s}\n", .{path});
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

fn validatePath(path: []u8) void {
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, path, '/', std.fs.path.sep);
    if (std.fs.path.sep != '\\') std.mem.replaceScalar(u8, path, '\\', std.fs.path.sep);
}

fn readFileIntoBuffer(dir: std.fs.Dir, path: []const u8, buffer: []u8) ![]u8 {
    const tmdFile = dir.openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try stderr.print("File ({s}) is not found.\n", .{path});
        }
        return err;
    };
    defer tmdFile.close();

    const stat = try tmdFile.stat();
    if (stat.size > buffer.len) {
        try stderr.print("File ({s}) size is too large ({} > {}).\n", .{ path, stat.size, buffer.len });
        return error.FileSizeTooLarge;
    }

    const readSize = try tmdFile.readAll(buffer[0..stat.size]);
    if (stat.size != readSize) {
        try stderr.print("[{s}] read size not match ({} != {}).\n", .{ path, stat.size, readSize });
        return error.FileSizeNotMatch;
    }
    return buffer[0..readSize];
}
