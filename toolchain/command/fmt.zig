const std = @import("std");

const tmd = @import("tmd");

const AppContext = @import("./common/AppContext.zig");
const FileIterator = @import("./common/FileIterator.zig");
const util = @import("./common/util.zig");

const maxTmdFileSize = 1 << 23; // 8M
const bufferSize = maxTmdFileSize * 4;

pub const Formatter = struct {
    pub fn argsDesc() []const u8 {
        return "[Dir | TmdFile]...";
    }

    pub fn briefDesc() []const u8 {
        return "Format .tmd files.";
    }

    pub fn completeDesc() []const u8 {
        return 
        \\The 'fmt' command formats all of the specified input
        \\.tmd files and .tmd files in the specified directories.
        \\Without any argument specified, the current directory
        \\will be used.
        ;
    }

    pub fn process(ctx: *AppContext, args: []const []const u8) !void {
        const buffer = try ctx.allocator.alloc(u8, bufferSize);
        defer ctx.allocator.free(buffer);

        if (args.len == 0) try fmtTmdFiles(&.{"."}, buffer, ctx) else try fmtTmdFiles(args, buffer, ctx);
    }

    // ToDo: to avoid duplicated arguments.
    //       Do it in common.TmdFiles.format() ?
    //       Sort args, short dir paths < longer dir paths < file paths.
    fn fmtTmdFiles(paths: []const []const u8, buffer: []u8, ctx: *AppContext) !void {
        var fi: FileIterator = .init(paths, ctx.allocator, ctx.stderr, &AppContext.excludeSpecialDir);
        while (try fi.next()) |entry| {
            if (!std.mem.eql(u8, std.fs.path.extension(entry.filePath), ".tmd")) continue;

            //std.debug.print("> [{s}] {s}\n", .{entry.dirPath, entry.filePath});

            try fmtTmdFile(entry, buffer, ctx);
        }
    }

    fn fmtTmdFile(entry: FileIterator.Entry, buffer: []u8, ctx: *AppContext) !void {
        var remainingBuffer = buffer;

        // load file

        const tmdContent = try util.readFile(entry.dir, entry.filePath, .{ .buffer = remainingBuffer[0..maxTmdFileSize] }, ctx.stderr);
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
            try ctx.stdout.print(
                \\{s}
                \\
            , .{outputFilename});
        }
    }
};

pub const FormatTester = struct {
    pub const notUserFaced: void = {};

    pub fn argsDesc() []const u8 {
        return "[Dir | TmdFile]...";
    }

    pub fn briefDesc() []const u8 {
        return "Run several format tests on .tmd files.";
    }

    pub fn completeDesc() []const u8 {
        return 
        \\The 'fmt-test' command is used to test the correctness
        \\of the format functionality of the TapirMD core lib.
        \\Without any argument specified, the current directory
        \\will be used.
        ;
    }

    pub fn process(ctx: *AppContext, args: []const []const u8) !void {
        const buffer = try ctx.allocator.alloc(u8, bufferSize);
        defer ctx.allocator.free(buffer);

        if (args.len == 0) try fmtTestTmdFiles(&.{"."}, buffer, ctx) else try fmtTestTmdFiles(args, buffer, ctx);
    }

    fn fmtTestTmdFiles(paths: []const []const u8, buffer: []u8, ctx: *AppContext) !void {
        var fi: FileIterator = .init(paths, ctx.allocator, ctx.stderr, &AppContext.excludeSpecialDir);
        while (try fi.next()) |entry| {
            if (!std.mem.eql(u8, std.fs.path.extension(entry.filePath), ".tmd")) continue;

            //std.debug.print("> [{s}] {s}\n", .{entry.dirPath, entry.filePath});

            try fmtTestFile(entry, buffer, ctx);
        }
    }

    fn fmtTestFile(entry: FileIterator.Entry, buffer: []u8, ctx: *AppContext) !void {
        // load file

        const tmdContent = try util.readFile(entry.dir, entry.filePath, .{ .buffer = buffer[0..maxTmdFileSize] }, ctx.stderr);
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
                std.debug.print("test#1 failed: [{s}] {s}\n", .{ entry.dirPath, entry.filePath });
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
                std.debug.print("test#2 failed: [{s}] {s}\n", .{ entry.dirPath, entry.filePath });
                return;
            }
            //remainingBuffer = remainingBuffer[newNewTmdContent.len..];

            break :blk newTmdDoc;
        };

        // If data !== data2, and there are streaming to data/code blocks, then the test might fail.
        // So it is disabled now.
        //
        // ToDo: if there is no streaming cases, then enable this test.
        //
        // test 3: to_html(tmdDoc) and to_html(newTmdDoc) should be identical
        if (false) {
            fbs = std.io.fixedBufferStream(remainingBuffer);
            try tmdDoc.writeHTML(fbs.writer(), .{}, ctx.allocator);
            const html = fbs.getWritten();
            remainingBuffer = remainingBuffer[html.len..];

            fbs = std.io.fixedBufferStream(remainingBuffer);
            try newTmdDoc.writeHTML(fbs.writer(), .{}, ctx.allocator);
            const newHtml = fbs.getWritten();
            //remainingBuffer = remainingBuffer[newHtml.len..];

            if (!std.mem.eql(u8, html, newHtml)) {
                std.debug.print("test#3 failed: [{s}] {s}\n", .{ entry.dirPath, entry.filePath });
                //std.debug.print("\n--------\n{s}\n------------\n{s}\n", .{ html, newHtml });
                return;
            }
        }
    }
};
