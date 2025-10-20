const std = @import("std");

const tmd = @import("tmd");
const list = @import("list");

const AppContext = @import("AppContext.zig");
const config = @import("Config.zig");
const util = @import("util.zig");

pub const RelativePathWriter = struct {
    path: []const u8,
    relativeTo: []const u8,
    fragment: []const u8,

    pub fn gen(self: *const RelativePathWriter, aw: std.io.AnyWriter) !void {
        const n, const s = util.relativePath(self.relativeTo, self.path, '/');
        for (0..n) |_| try aw.writeAll("../");
        try tmd.writeUrlAttributeValue(aw, s);
        if (self.fragment.len > 0) {
            try tmd.writeUrlAttributeValue(aw, self.fragment);
        }
    }

    pub fn asGenBacklback(self: *RelativePathWriter, path: []const u8, relativeTo: []const u8, fragment: []const u8) tmd.GenCallback {
        self.* = .{ .path = path, .relativeTo = relativeTo, .fragment = fragment };
        return .init(self);
    }
};

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

    pub fn makeGenCallback(self: *ExternalBlockGenerator, configEx: *AppContext.ConfigEx, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) ?tmd.GenCallback {
        const generators = (configEx.basic.@"custom-block-generators" orelse return null)._parsed;
        const attrs = custom.attributes();
        const generator = generators.getPtr(attrs.app) orelse return null;
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
