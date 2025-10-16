const std = @import("std");

const tmd = @import("tmd");

const ExternalBlockGenerator = @This();

doc: *const tmd.Doc,
custom: *const tmd.BlockType.Custom,
shellArgs: [][]const u8,

pub fn gen(self: *const ExternalBlockGenerator, w: std.io.AnyWriter) !void {
    const startDataLine = self.custom.startDataLine() orelse return;
    const endDataLine = self.custom.endDataLine().?;
    std.debug.assert(endDataLine.lineType == .data);

    const startLineRange = startDataLine.range(.none);
    const endLineRange = endDataLine.range(.none);
    const data = self.doc.rangeData(.{.start = startLineRange.start, .end = endLineRange.end});

    self.shellArgs[self.shellArgs.len - 1] = "gen-html";

    try writeShellCommandOutput(w, self.shellArgs, data);
}

pub fn asGenBacklback(self: *ExternalBlockGenerator, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom, shellArgs: [][]const u8) tmd.GenCallback {
    self.* = .{ .doc = doc, .custom = custom, .shellArgs = shellArgs };
    return .init(self);
}


// by grok3
fn writeShellCommandOutput(w: std.io.AnyWriter, commandWithArgs: []const []const u8, stdinText: []const u8) !void {
    const allocator = std.heap.page_allocator;
    
    var child = std.process.Child.init(commandWithArgs, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();

    if (child.stdin) |stdin| {
        try stdin.writeAll(stdinText);
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