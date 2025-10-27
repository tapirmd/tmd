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

    pub fn gen(self: *const RelativePathWriter, aw: std.io.AnyWriter) !void {
        try writeRelativeUrl(aw, self.path, self.pathSep, self.relativeTo, self.relativeToSep);

        if (self.fragment.len > 0) {
            try tmd.writeUrlAttributeValue(aw, self.fragment);
        }
    }

    pub fn asGenBacklback(self: *RelativePathWriter, path: []const u8, pathSep: ?u8, relativeTo: []const u8, relativeToSep: u8, fragment: []const u8) tmd.GenCallback {
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

pub fn writeRelativeUrl(w: anytype, path: []const u8, pathSep: ?u8, relativeTo: []const u8, relativeToSep: u8) !void {
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

    pub fn gen(self: *const ShellCommandCustomBlockGenerator, w: std.io.AnyWriter) !void {
        const startDataLine = self.custom.startDataLine() orelse return;
        const endDataLine = self.custom.endDataLine().?;
        std.debug.assert(endDataLine.lineType == .data);

        const startLineRange = startDataLine.range(.none);
        const endLineRange = endDataLine.range(.none);
        const data = self.doc.rangeData(.{ .start = startLineRange.start, .end = endLineRange.end });

        self.shellArgs[self.shellArgs.len - 1] = "gen-html";

        try writeShellCommandOutput(w, self.shellArgs, data);
    }

    pub fn asGenBacklback(self: *ShellCommandCustomBlockGenerator, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom, shellArgs: [][]const u8) tmd.GenCallback {
        self.* = .{ .doc = doc, .custom = custom, .shellArgs = shellArgs };
        return .init(self);
    }
};

// by grok3
fn writeShellCommandOutput(w: std.io.AnyWriter, commandWithArgs: []const []const u8, stdinText: []const u8) !void {
    const allocator = std.heap.page_allocator;

    var child = std.process.Child.init(commandWithArgs, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();

    if (child.stdin) |stdin| {
        if (stdinText.len > 0) try stdin.writeAll(stdinText);
        stdin.close();
        child.stdin = null; // Prevent double-close
    }

    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    if (child.stdout) |stdout| {
        try stdout.reader().readAllArrayList(&stdout_buf, 1024 * 1024);
    } else {
        return error.NoStdout;
    }

    const output = std.mem.trim(u8, stdout_buf.items, " \t\r\n");
    try w.writeAll(output);

    _ = try child.wait();
}

pub const ExternalBlockGenerator = struct {
    builtinHtmlBlockGenerator: tmd.HtmlBlockGenerator,
    shellCustomBlockGenerator: ShellCommandCustomBlockGenerator,

    pub fn asGenBacklback(self: *ExternalBlockGenerator, generator: union(enum) {
        builtinHtmlBlockGenerator: tmd.HtmlBlockGenerator,
        shellCustomBlockGenerator: ShellCommandCustomBlockGenerator,
    }) tmd.GenCallback {
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

    pub fn makeGenCallback(self: *ExternalBlockGenerator, configEx: *const AppContext.ConfigEx, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) ?tmd.GenCallback {
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
            .callbackContext = self,
            .getCustomBlockGenCallback = getCustomBlockGenCallback,
        };
    }

    pub fn getCustomBlockGenCallback(callbackContext: *const anyopaque, custom: *const tmd.BlockType.Custom) !?tmd.GenCallback {
        const self: *const @This() = @ptrCast(@alignCast(callbackContext));
        return self.externalBlockGenerator.makeGenCallback(self.configEx, self.tmdDoc, custom);
    }
};

pub fn writeFaviconAssetInHead(w: anytype, faviconFilePath: config.FilePath, fileRegister: anytype, relativeTo: []const u8, sep: u8) !void {
    switch (faviconFilePath) {
        .builtin, .local => {
            const targetPath = try fileRegister.tryToRegisterFile(faviconFilePath, .images);

            try w.writeAll(
                \\<link rel="icon" href="
            );

            try writeRelativeUrl(w, targetPath, sep, relativeTo, sep);

            try w.writeAll(
                \\">
                \\
            );
        },
        .remote => |url| {
            try w.writeAll(
                \\<link rel="icon" href="
            );

            try tmd.writeUrlAttributeValue(w, url);

            try w.writeAll(
                \\">
                \\
            );
        },
    }
}

pub fn writeCssAssetInHead(w: anytype, cssFilePath: config.FilePath, fileRegister: anytype, relativeTo: []const u8, sep: u8) !void {
    switch (cssFilePath) {
        .builtin, .local => {
            const targetPath = try fileRegister.tryToRegisterFile(cssFilePath, .css);

            try w.writeAll(
                \\<link href="
            );

            try writeRelativeUrl(w, targetPath, sep, relativeTo, sep);

            try w.writeAll(
                \\" rel="stylesheet">
                \\
            );
        },
        .remote => |url| {
            try w.writeAll(
                \\<link href="
            );

            try tmd.writeUrlAttributeValue(w, url);

            try w.writeAll(
                \\" rel="stylesheet">
                \\
            );
        },
    }
}

pub fn writeJsAssetInHead(w: anytype, jsFilePath: config.FilePath, fileRegister: anytype, relativeTo: []const u8, sep: u8) !void {
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
