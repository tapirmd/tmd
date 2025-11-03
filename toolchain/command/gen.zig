const std = @import("std");

const tmd = @import("tmd");

const AppContext = @import("./common/AppContext.zig");
const DocRenderer = @import("./common/DocRenderer.zig");
const FileIterator = @import("./common/FileIterator.zig");
const config = @import("./common/Config.zig");
const gen = @import("./common/gen.zig");
const util = @import("./common/util.zig");

const maxTmdFileSize = 1 << 23; // 8M
const bufferSize = maxTmdFileSize * 4;

pub const Generator = struct {
    pub fn argsDesc() []const u8 {
        return "[Dir | TmdFile]...";
    }

    pub fn briefDesc() []const u8 {
        return "Generate HTML snippets for .tmd files.";
    }

    pub fn completeDesc() []const u8 {
        return 
        \\The 'gen' command generates HTML snippets for the
        \\specified input .tmd files and .tmd files in the
        \\specified directories.
        \\Without any argument specified, the current directory
        \\will be used.
        ;
    }

    pub fn process(ctx: *AppContext, args: []const []const u8) !void {
        const buffer = try ctx.allocator.alloc(u8, bufferSize);
        defer ctx.allocator.free(buffer);

        if (args.len == 0) try genHtmlSnippets(&.{"."}, buffer, ctx) else try genHtmlSnippets(args, buffer, ctx);
    }

    // ToDo: to avoid duplicated arguments.
    //       Do it in common.TmdFiles.format() ?
    //       Sort args, short dir paths < longer dir paths < file paths.
    fn genHtmlSnippets(paths: []const []const u8, buffer: []u8, ctx: *AppContext) !void {
        var fi: FileIterator = .init(paths, ctx.allocator, ctx.stderr, &AppContext.excludeSpecialDir);
        while (try fi.next()) |entry| {
            if (!std.mem.eql(u8, std.fs.path.extension(entry.filePath), ".tmd")) continue;

            //std.debug.print("> [{s}] {s}\n", .{entry.dirPath, entry.filePath});

            try genHtmlSnippet(entry, buffer, ctx);
        }
    }

    fn genHtmlSnippet(entry: FileIterator.Entry, buffer: []u8, ctx: *AppContext) !void {
        try genHtml(entry, buffer, ctx, false);
    }
};

pub const FullPageGenerator = struct {
    pub fn argsDesc() []const u8 {
        return "[Dir | TmdFile]...";
    }

    pub fn briefDesc() []const u8 {
        return "Generate full HTML pages for .tmd files.";
    }

    pub fn completeDesc() []const u8 {
        return 
        \\The 'gen-full-page' command generates fill HTML pages
        \\for the specified input .tmd files and .tmd files in
        \\the specified directories.
        \\Without any argument specified, the current directory
        \\will be used.
        ;
    }

    pub fn process(ctx: *AppContext, args: []const []const u8) !void {
        const buffer = try ctx.allocator.alloc(u8, bufferSize);
        defer ctx.allocator.free(buffer);

        if (args.len == 0) try genFullPages(&.{"."}, buffer, ctx) else try genFullPages(args, buffer, ctx);
    }

    fn genFullPages(paths: []const []const u8, buffer: []u8, ctx: *AppContext) !void {
        var fi: FileIterator = .init(paths, ctx.allocator, ctx.stderr, &AppContext.excludeSpecialDir);
        while (try fi.next()) |entry| {
            if (!std.mem.eql(u8, std.fs.path.extension(entry.filePath), ".tmd")) continue;

            //std.debug.print("> [{s}] {s}\n", .{entry.dirPath, entry.filePath});

            try genFullPage(entry, buffer, ctx);
        }
    }

    fn genFullPage(entry: FileIterator.Entry, buffer: []u8, ctx: *AppContext) !void {
        try genHtml(entry, buffer, ctx, true);
    }
};

fn genHtml(entry: FileIterator.Entry, buffer: []u8, ctx: *AppContext, fullPage: bool) !void {
    var remainingBuffer = buffer;

    // determine input and output filenames

    const absFilePath = try entry.dir.realpathAlloc(ctx.allocator, entry.filePath);
    defer ctx.allocator.free(absFilePath);

    const tmdExt = ".tmd";
    const ext = std.fs.path.extension(absFilePath);
    const base = if (std.ascii.eqlIgnoreCase(ext, tmdExt)) absFilePath[0 .. absFilePath.len - tmdExt.len] else absFilePath;
    const outputFilename = try std.mem.concat(ctx.allocator, u8, &.{ base, ".html" });
    defer ctx.allocator.free(outputFilename);

    // get config

    const dirPath = std.fs.path.dirname(absFilePath) orelse unreachable;

    const configEx, _, _ = try ctx.getDirectoryConfigAndRoot(dirPath);

    // load file

    const tmdContent = try util.readFile(null, absFilePath, .{ .buffer = remainingBuffer[0..maxTmdFileSize] }, ctx.stderr);
    remainingBuffer = remainingBuffer[tmdContent.len..];

    // parse file

    var fba = std.heap.FixedBufferAllocator.init(remainingBuffer);
    // defer fba.reset(); // unnecessary
    const fbaAllocator = fba.allocator();
    var tmdDoc = try tmd.Doc.parse(tmdContent, fbaAllocator);
    // defer tmdDoc.destroy(); // unnecessary

    remainingBuffer = remainingBuffer[fba.end_index..];

    // generate HTML snippet

    var w: std.Io.Writer = .fixed(remainingBuffer);

    switch (fullPage) {
        false => {
            var externalBlockGenerator: gen.ExternalBlockGenerator = undefined;
            const co: gen.BlockGeneratorCallbackOwner = .{
                .tmdDoc = &tmdDoc,
                .configEx = configEx,
                .externalBlockGenerator = &externalBlockGenerator,
            };
            const genOptions: tmd.GenOptions = co.makeTmdGenOptions();

            try tmdDoc.writeHTML(&w, genOptions, ctx.allocator);
        },
        true => {
            var tmdDocRenderer: DocRenderer = .init(ctx, configEx, .{});

            try tmdDocRenderer.render(&w, .{
                .doc = &tmdDoc,
                .sourceFilePath = absFilePath,
                .targetFilePath = outputFilename,
            });
        },
    }

    const htmlContent = w.buffered();

    // write file

    try util.writeFile(null, outputFilename, htmlContent);

    if (false) try ctx.stdout.print(
        \\{s} ({} bytes)
        \\
    , .{ outputFilename, htmlContent.len });
}
