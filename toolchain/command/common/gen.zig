const std = @import("std");

const tmd = @import("tmd");
const list = @import("list");

const AppContext = @import("AppContext.zig");
const config = @import("Config.zig");
const util = @import("util.zig");

pub const RelativePathWriter = struct {
    path: []const u8,
    pathSep: ?u8,
    relativeTo: []const u8,
    relativeToSep: u8,
    fragment: []const u8,

    pub fn gen(self: *const RelativePathWriter, w: *std.Io.Writer) !void {
        try writeRelativeUrl(w, self.path, self.pathSep, self.relativeTo, self.relativeToSep);

        if (self.fragment.len > 0) {
            try tmd.writeUrlAttributeValue(w, self.fragment);
        }
    }

    pub fn asGenBacklback(self: *RelativePathWriter, path: []const u8, pathSep: ?u8, relativeTo: []const u8, relativeToSep: u8, fragment: []const u8) tmd.Generator {
        self.* = .{
            .path = path,
            .pathSep = pathSep,
            .relativeTo = relativeTo,
            .relativeToSep = relativeToSep,
            .fragment = fragment,
        };
        return .init(self);
    }
};

pub fn writeRelativeUrl(w: *std.Io.Writer, path: []const u8, pathSep: ?u8, relativeTo: []const u8, relativeToSep: u8) !void {
    if (relativeToSep == '/') {
        if (pathSep) |sep| if (sep == '/') {
            const n, const s = util.relativePath(relativeTo, path, '/');
            for (0..n) |_| try w.writeAll("../");
            try tmd.writeUrlAttributeValue(w, s);
            return;
        };

        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const validatedPath = try util.validatePathToPosixPathIntoBuffer(path, buffer[0..]);

        const n, const s = util.relativePath(relativeTo, validatedPath, '/');
        for (0..n) |_| try w.writeAll("../");
        try tmd.writeUrlAttributeValue(w, s);
        return;
    } else if (pathSep) |sep| {
        if (sep == '/') {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const validatedRelativeTo = try util.validatePathToPosixPathIntoBuffer(relativeTo, buffer[0..]);

            const n, const s = util.relativePath(validatedRelativeTo, path, '/');
            for (0..n) |_| try w.writeAll("../");
            try tmd.writeUrlAttributeValue(w, s);
            return;
        }

        const n, const s = util.relativePath(relativeTo, path, '\\');
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const validated = try util.validatePathToPosixPathIntoBuffer(s, buffer[0..]);

        for (0..n) |_| try w.writeAll("../");
        try tmd.writeUrlAttributeValue(w, validated);
        return;
    }

    var buffer1: [std.fs.max_path_bytes]u8 = undefined;
    const validatedPath = try util.validatePathToPosixPathIntoBuffer(path, buffer1[0..]);

    var buffer2: [std.fs.max_path_bytes]u8 = undefined;
    const validatedRelativeTo = try util.validatePathToPosixPathIntoBuffer(relativeTo, buffer2[0..]);

    const n, const s = util.relativePath(validatedRelativeTo, validatedPath, '/');
    for (0..n) |_| try w.writeAll("../");
    try tmd.writeUrlAttributeValue(w, s);
}

pub const ShellCommandCustomBlockGenerator = struct {
    doc: *const tmd.Doc,
    custom: *const tmd.BlockType.Custom,
    shellArgs: [][]const u8,

    //

    pub fn gen(self: *const ShellCommandCustomBlockGenerator, w: *std.Io.Writer) !void {
        const startDataLine = self.custom.startDataLine() orelse return;
        const endDataLine = self.custom.endDataLine().?;
        std.debug.assert(endDataLine.lineType == .data);

        const startLineRange = startDataLine.range(.none);
        const endLineRange = endDataLine.range(.none);
        const data = self.doc.rangeData(.{ .start = startLineRange.start, .end = endLineRange.end });

        self.shellArgs[self.shellArgs.len - 1] = "gen-html";

        try writeShellCommandOutput(w, self.shellArgs, data);
    }

    pub fn asGenBacklback(self: *ShellCommandCustomBlockGenerator, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom, shellArgs: [][]const u8) tmd.Generator {
        self.* = .{ .doc = doc, .custom = custom, .shellArgs = shellArgs };
        return .init(self);
    }
};

// by grok3
fn writeShellCommandOutput(w: *std.Io.Writer, commandWithArgs: []const []const u8, stdinText: []const u8) !void {
    // ToDo: ..., use an alternative allocator?
    const allocator = std.heap.page_allocator;

    var child = std.process.Child.init(commandWithArgs, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();

    if (child.stdin) |stdin_file| {
        var buffer: [4096]u8 = undefined;
        var stdout_writer = stdin_file.writer(&buffer);
        const stdin = &stdout_writer.interface;

        if (stdinText.len > 0) {
            try stdin.writeAll(stdinText);
            try stdin.flush();
        }

        stdin_file.close();
        child.stdin = null; // Prevent double-close
    }

    // ToDo: use .initOwnedSlice instead.
    var wa: std.Io.Writer.Allocating = .init(allocator);
    defer wa.deinit();

    if (child.stdout) |stdout_file| {
        var buffer: [4096]u8 = undefined;
        var stdout_reader = stdout_file.reader(&buffer);
        const reader = &stdout_reader.interface;

        _ = try reader.streamRemaining(&wa.writer);
        //try wa.writer.flush(); // no-op
    } else {
        return error.NoStdout;
    }

    const output = std.mem.trim(u8, wa.written(), " \t\r\n");
    try w.writeAll(output);

    _ = try child.wait();
}

pub const ExternalBlockGenerator = struct {
    builtinHtmlBlockGenerator: tmd.HtmlBlockGenerator,
    shellCustomBlockGenerator: ShellCommandCustomBlockGenerator,

    pub fn asGenBacklback(self: *ExternalBlockGenerator, generator: union(enum) {
        builtinHtmlBlockGenerator: tmd.HtmlBlockGenerator,
        shellCustomBlockGenerator: ShellCommandCustomBlockGenerator,
    }) tmd.Generator {
        switch (generator) {
            .builtinHtmlBlockGenerator => |g| {
                self.builtinHtmlBlockGenerator = g;
                return .init(&self.builtinHtmlBlockGenerator);
            },
            .shellCustomBlockGenerator => |g| {
                self.shellCustomBlockGenerator = g;
                return .init(&self.shellCustomBlockGenerator);
            },
        }
    }

    pub fn makeGenerator(self: *ExternalBlockGenerator, configEx: *const AppContext.ConfigEx, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) ?tmd.Generator {
        const generators = (configEx.basic.@"custom-block-generators" orelse return null)._parsed;
        const attrs = custom.attributes();
        const generator = generators.getPtr(attrs.contentType) orelse return null;
        switch (generator.*) {
            .builtin => |app| {
                if (std.mem.eql(u8, app, "html")) {
                    return self.asGenBacklback(.{
                        .builtinHtmlBlockGenerator = .{
                            .doc = doc,
                            .custom = custom,
                        },
                    });
                }
                unreachable;
            },
            .external => |*external| {
                std.debug.assert(external.argsCount > 0 and external.argsCount + 1 < external.argsArray.len);
                const shellCommand = external.argsArray[0 .. external.argsCount + 1];

                return self.asGenBacklback(.{
                    .shellCustomBlockGenerator = .{
                        .doc = doc,
                        .custom = custom,
                        .shellArgs = shellCommand,
                    },
                });
            },
        }

        comptime unreachable;
    }
};

pub const BlockGeneratorCallbackOwner = struct {
    tmdDoc: *const tmd.Doc,
    configEx: *const AppContext.ConfigEx,
    externalBlockGenerator: *ExternalBlockGenerator,

    pub fn makeTmdGenOptions(self: *const @This()) tmd.GenOptions {
        return .{
            .callbacks = .{
                .context = self,
                .fnGetCustomBlockGenerator = getCustomBlockGenerator,
            },
        };
    }

    pub fn getCustomBlockGenerator(callbackContext: *const anyopaque, custom: *const tmd.BlockType.Custom) !?tmd.Generator {
        const self: *const @This() = @ptrCast(@alignCast(callbackContext));
        return self.externalBlockGenerator.makeGenerator(self.configEx, self.tmdDoc, custom);
    }
};

pub fn writeFaviconAssetInHead(w: *std.Io.Writer, faviconFilePath: config.FilePath, fileRegister: anytype, relativeTo: []const u8, sep: u8) !void {
    switch (faviconFilePath) {
        .builtin, .local => {
            const targetPath = try fileRegister.tryToRegisterFile(faviconFilePath, .images);

            try w.writeAll(
                \\<link rel="icon" href="
            );

            try writeRelativeUrl(w, targetPath, sep, relativeTo, sep);

            try w.writeAll(
                \\"/>
                \\
            );
        },
        .remote => |url| {
            try w.writeAll(
                \\<link rel="icon" href="
            );

            try tmd.writeUrlAttributeValue(w, url);

            try w.writeAll(
                \\"/>
                \\
            );
        },
    }
}

pub fn writeCssAssetInHead(w: *std.Io.Writer, cssFilePath: config.FilePath, fileRegister: anytype, relativeTo: []const u8, sep: u8) !void {
    switch (cssFilePath) {
        .builtin, .local => {
            const targetPath = try fileRegister.tryToRegisterFile(cssFilePath, .css);

            try w.writeAll(
                \\<link href="
            );

            try writeRelativeUrl(w, targetPath, sep, relativeTo, sep);

            try w.writeAll(
                \\" rel="stylesheet"/>
                \\
            );
        },
        .remote => |url| {
            try w.writeAll(
                \\<link href="
            );

            try tmd.writeUrlAttributeValue(w, url);

            try w.writeAll(
                \\" rel="stylesheet"/>
                \\
            );
        },
    }
}

pub fn writeJsAssetInHead(w: *std.Io.Writer, jsFilePath: config.FilePath, fileRegister: anytype, relativeTo: []const u8, sep: u8) !void {
    switch (jsFilePath) {
        .builtin, .local => {
            const targetPath = try fileRegister.tryToRegisterFile(jsFilePath, .js);

            try w.writeAll(
                \\<script src="
            );

            try writeRelativeUrl(w, targetPath, sep, relativeTo, sep);

            try w.writeAll(
                \\"></script>
                \\
            );
        },
        .remote => |url| {
            try w.writeAll(
                \\<script src="
            );

            try tmd.writeUrlAttributeValue(w, url);

            try w.writeAll(
                \\"></script>
                \\
            );
        },
    }
}
