const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd");

const AppContext = @import("AppContext.zig");
const config = @import("Config.zig");
const util = @import("util.zig");

const maxFileSize = 8 * 1024 * 1024; // 10M

pub const BuiltinFileInfo = struct {
    name: []const u8,
    extension: tmd.Extension,
    content: []const u8,
};

const builtinFileInfos: []const BuiltinFileInfo = &.{
    .{
        .name = "@tmd-favicon",
        .extension = .jpg,
        .content = @embedFile("tmd-favicon.jpg"),
    },
    .{
        .name = "@tmd-css-default",
        .extension = .css,
        .content = tmd.exampleCSS,
    },
};

pub fn getBuiltinFileInfo(ctx: *AppContext, name: []const u8) !BuiltinFileInfo {
    for (builtinFileInfos) |info| {
        if (std.mem.eql(u8, info.name, name)) return info;
    }
    try ctx.stderr.print("Unknown builtin asset: {s}\n", .{name});
    return error.UnknownBuiltinAsset;
}

pub const ContentOp = enum {
    base64,
    // hex, // ToDo: needed?
};

pub const ContentCacheKey = struct {
    filePath: config.FilePath,
    contentOp: ?ContentOp,
};

pub fn writeFile(ctx: *AppContext, w: anytype, filePath: config.FilePath, comptime contentOp: ?ContentOp, cacheIt: bool) !void {
    if (ctx._cachedContents.get(.{ .filePath = filePath, .contentOp = contentOp })) |content| {
        try w.writeAll(content);
        return;
    }

    const content, const allocatorForFree = switch (filePath) {
        .builtin => |name| blk: {
            const info = try ctx.getBuiltinFileInfo(name);
            break :blk .{ info.content, null };
        },
        .local => |absPath| blk: {
            const needFree = !cacheIt or contentOp != null;
            const a = if (needFree) ctx.allocator else ctx.arenaAllocator;
            const content = try util.readFile(null, absPath, .{ .alloc = .{ .allocator = a, .maxFileSize = maxFileSize } }, ctx.stderr);
            break :blk .{ content, if (needFree) ctx.allocator else null };
        },
        .remote => |url| {
            _ = url;
            @panic("unimplemented");
        },
    };
    if (allocatorForFree) |a| a.free(content);

    const writtenContent = if (contentOp) |op| blk: {
        switch (op) {
            .base64 => {
                if (cacheIt) {
                    const encoder = std.base64.standard_no_pad.Encoder;
                    const encoded_len = encoder.calcSize(content.len);
                    const encoded = try ctx.arenaAllocator.alloc(u8, encoded_len);
                    _ = encoder.encode(encoded, content);

                    break :blk encoded;
                } else {
                    @panic("Steaming content in base64 format is not implemented yet.");
                }
            },
        }
    } else blk: {
        if (cacheIt and filePath != .builtin) {
            break :blk content;
        } else {
            try w.writeAll(content);
            return;
        }
    };

    try w.writeAll(writtenContent);

    try ctx._cachedContents.put(.{ .filePath = filePath, .contentOp = contentOp }, writtenContent);
}
