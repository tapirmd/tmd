const std = @import("std");

const tmd = @import("tmd");

const cmd = @import("cmd");
const custom = @import("gen-custom.zig");
const main = @import("main.zig");

const maxTmdFileSize = 1 << 23; // 8M
const bufferSize = maxTmdFileSize * 8;
const maxCssFileSize = 1 << 20; // 1M

pub fn generate(inArgs: []const []u8, allocator: std.mem.Allocator) !void {
    const buffer = try allocator.alloc(u8, bufferSize);
    defer allocator.free(buffer);

    if (inArgs.len == 0) {
        try main.stderr.print("No tmd files specified.", .{});
        std.process.exit(1);
        unreachable;
    }

    var args = inArgs;
    var localBuffer = buffer;

    // --trial-page-css=@ (inline tmd.exampleCSS, for trial purpose)
    // --trial-page-css=@./res/css/foo.css (inline the specified css content)
    // --trial-page-css=./res/css/foo.css (relative external path)
    // --trial-page-css=https://example.com/css/foo.css (absolute external url)
    // Blank means for embedding purpose (not full page).
    // Use / as seperator, even on Windows.
    const keyTrialPageCss: []const u8 = "trial-page-css";
    var option_trial_page_css: CssOption = .none;

    // --enabled-custom-apps=html,phyard;foobar
    // Blank to disable all custom apps.
    // Use comma or semicolon as seperators.
    const keyEnabledCustomApps: []const u8 = "enabled-custom-apps";
    var option_enabled_custom_apps: []const u8 = "";

    // ToDo:
    // --ident-suffix=@comment-123
    // --ident-suffix=:embedded
    //var option_ident_suffix: []const u8 = "";

    // Currently, DON'T try to make the gen tool powerful.
    // It should only proivde some basic functionalities now:
    // 1. create incomplete html pieces for embedding purpose.
    // 2. create complete html pages for trial/experience purpose.
    // 3. test custom apps.
    //
    // Later, it might be enhanced to
    // * gen ebooks
    // * gen with templates

    // ToDo: config
    //
    // All config items are for generation (none for parsing).
    // const TmdConfig = struct {
    //    customs: []const CustomAppConfig,
    // };
    //
    // const CustomAppConfig = struct {
    //    name: []const u8,
    //    gen: union(enum) {
    //       exe: []const u8,
    //       http: []const u8,
    //    }
    // };

    for (args, 0..) |arg, k| {
        if (!std.mem.startsWith(u8, arg, "--")) {
            args = args[k..];
            break;
        }

        const argKeyValue = for (arg[2..], 2..) |c, i| {
            if (c == '-') continue;
            break arg[i..];
        } else {
            args = args[k + 1 ..];
            break;
        };

        if (std.mem.startsWith(u8, argKeyValue, keyTrialPageCss)) {
            var path = argKeyValue[keyTrialPageCss.len..];
            if (path.len > 0 and path[0] == '=') path = path[1..];
            if (path.len > 0 and path[0] == '@') {
                path = path[1..];
                cmd.validatePath(path);
                const cssContent = if (path.len == 0) tmd.exampleCSS else blk: {
                    const content = try cmd.readFileIntoBuffer(std.fs.cwd(), path, localBuffer[0..maxCssFileSize], main.stderr);
                    localBuffer = localBuffer[content.len..];
                    break :blk content;
                };
                option_trial_page_css = .{ .data = cssContent };
            } else if (path.len > 0) {
                cmd.validateURL(path);
                option_trial_page_css = .{ .url = path };
            }
        } else if (std.mem.startsWith(u8, argKeyValue, keyEnabledCustomApps)) {
            const value = argKeyValue[keyEnabledCustomApps.len..];
            if (value.len > 0 and value[0] == '=') option_enabled_custom_apps = value[1..];
        } else {
            try main.stderr.print("Unrecognized option: {s}\n", .{argKeyValue});
            std.process.exit(1);
            unreachable;
        }
    }

    const supportHTML = blk: {
        var iter = std.mem.splitAny(u8, option_enabled_custom_apps, ";,");
        var item = iter.first();
        while (true) {
            if (std.mem.eql(u8, item, "html")) break :blk true;
            if (item.len > 0) {
                try main.stderr.print("Unrecognized custom app name: {s}\n", .{item});
                std.process.exit(1);
            }
            if (iter.next()) |next| item = next else break :blk false;
        }
    };

    const generator = Generator{
        .trialPageCSS = option_trial_page_css,
        .genOptions = tmd.GenOptions{
            .customFn = if (supportHTML) custom.customFn else null,
        },
    };

    try generator.genHtmlFiles(args, localBuffer, allocator);
}

const CssOption = union(enum) {
    none: void,
    url: []const u8,
    data: []const u8,
};

const Generator = struct {
    trialPageCSS: CssOption,
    genOptions: tmd.GenOptions,

    fn genHtmlFiles(generator: Generator, paths: []const []const u8, buffer: []u8, allocator: std.mem.Allocator) !void {
        var fi = cmd.FileIterator.init(paths, allocator);
        while (try fi.next(main.stderr)) |entry| {
            if (!std.mem.eql(u8, std.fs.path.extension(entry.filePath), ".tmd")) continue;

            //std.debug.print("> [{s}] {s}\n", .{entry.dirPath, entry.filePath});

            try generator.genHtmlFile(entry, buffer, allocator);
        }
    }

    fn genHtmlFile(generator: Generator, entry: cmd.FileIterator.Entry, buffer: []u8, allocator: std.mem.Allocator) !void {
        // load file

        const tmdContent = try cmd.readFileIntoBuffer(entry.dir, entry.filePath, buffer[0..maxTmdFileSize], main.stderr);
        const remainingBuffer = buffer[tmdContent.len..];

        // parse file

        var fba = std.heap.FixedBufferAllocator.init(remainingBuffer);
        // defer fba.reset(); // unnecessary
        const fbaAllocator = fba.allocator();

        const tmdDoc = try tmd.Doc.parse(tmdContent, fbaAllocator);
        // defer tmdDoc.destroy(); // if fba, then this is actually unnecessary.

        // generate file

        const htmlExt = ".html";
        const tmdExt = ".tmd";
        var outputFilePath: [1024]u8 = undefined;
        var outputFilename: []const u8 = undefined;
        if (std.ascii.endsWithIgnoreCase(entry.filePath, tmdExt)) {
            if (entry.filePath.len - tmdExt.len + htmlExt.len > outputFilePath.len)
                return error.InputFileNameTooLong;
            outputFilename = entry.filePath[0 .. entry.filePath.len - tmdExt.len];
        } else {
            if (entry.filePath.len + htmlExt.len > outputFilePath.len)
                return error.InputFileNameTooLong;
            outputFilename = entry.filePath;
        }
        std.mem.copyBackwards(u8, outputFilePath[0..], outputFilename);
        std.mem.copyBackwards(u8, outputFilePath[outputFilename.len..], htmlExt);
        outputFilename = outputFilePath[0 .. outputFilename.len + htmlExt.len];

        const renderBuffer = try fbaAllocator.alloc(u8, remainingBuffer.len - fba.end_index);
        //defer fbaAllocator.free(renderBuffer); // unnecessary
        var fbs = std.io.fixedBufferStream(renderBuffer);

        switch (generator.trialPageCSS) {
            .none => try tmdDoc.writeHTML(fbs.writer(), generator.genOptions, allocator),
            .url => |url| {
                try writePageStartPart1(fbs.writer());
                if (!try tmdDoc.writePageTitle(fbs.writer())) _ = try fbs.writer().write("Untitled");
                try writePageStartPart2(fbs.writer());
                _ = try fbs.writer().print(
                    \\<link rel="stylesheet" href="{s}">
                    \\
                ,
                    .{url},
                );
                try writePageStartPart3(fbs.writer());
                try tmdDoc.writeHTML(fbs.writer(), generator.genOptions, allocator);
                try writePageEndPart(fbs.writer());
            },
            .data => |data| {
                try writePageStartPart1(fbs.writer());
                if (!try tmdDoc.writePageTitle(fbs.writer())) _ = try fbs.writer().write("Untitled");
                try writePageStartPart2(fbs.writer());
                _ = try fbs.writer().print(
                    \\<style>
                    \\{s}
                    \\</style>
                    \\
                ,
                    .{data},
                );
                try writePageStartPart3(fbs.writer());
                try tmdDoc.writeHTML(fbs.writer(), generator.genOptions, allocator);
                try writePageEndPart(fbs.writer());
            },
        }

        // write file

        const htmlFile = try entry.dir.createFile(outputFilename, .{});
        defer htmlFile.close();

        try htmlFile.writeAll(fbs.getWritten());

        try main.stdout.print(
            \\[{s}] {s} ({} bytes)
            \\   -> {s} ({} bytes)
            \\
        , .{ entry.dirPath, entry.filePath, tmdContent.len, outputFilename, fbs.getWritten().len });
    }
};

// generated from ../../doc/pages/static/image/tmd.jpg
const tmdFavicon = "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";

fn writePageStartPart1(w: anytype) !void {
    _ = try w.write(
        \\<!DOCTYPE html>
        \\<head>
        \\<meta charset="utf-8">
        \\<link rel="icon" type="image/jpeg" href="data:image/jpeg;base64,
    );
    _ = try w.write(tmdFavicon);
    _ = try w.write(
        \\">
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\<title>
        \\
    );
}

fn writePageStartPart2(w: anytype) !void {
    _ = try w.write(
        \\
        \\</title>
        \\
    );
}

fn writePageStartPart3(w: anytype) !void {
    _ = try w.write(
        \\</head>
        \\<body>
        \\
    );
}

fn writePageEndPart(w: anytype) !void {
    _ = try w.write(
        \\
        \\</body>
        \\</html>
    );
}
