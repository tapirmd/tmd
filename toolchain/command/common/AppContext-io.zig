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
    try ctx.stderr.flush();
    return error.UnknownBuiltinAsset;
}

pub const ContentOp = enum {
    base64,
    // hex, // ToDo: needed?
};

pub const ContentCacheKey = struct {
    filePath: config.FilePath,
    contentOp: ?ContentOp,

    pub const HashMapContext = struct {
        pub fn hash(self: @This(), key: ContentCacheKey) u64 {
            _ = self;

            const zero: u8 = 0;
            const one: u8 = 1;

            var hasher = std.hash.Wyhash.init(0);

            if (key.contentOp) |op| {
                hasher.update(std.mem.asBytes(&one));
                const tag: u8 = @intFromEnum(op);
                hasher.update(std.mem.asBytes(&tag));
            } else hasher.update(std.mem.asBytes(&zero));

            {
                const tag: u8 = @intFromEnum(key.filePath);
                hasher.update(std.mem.asBytes(&tag));
                const path = key.filePath.path();
                hasher.update(path);
            }

            return hasher.final();
        }

        pub fn eql(self: @This(), a: ContentCacheKey, b: ContentCacheKey) bool {
            _ = self;
            if (a.contentOp != b.contentOp) return false;

            const tag_a: u8 = @intFromEnum(a.filePath);
            const tag_b: u8 = @intFromEnum(b.filePath);
            if (tag_a != tag_b) return false;

            const path_a = a.filePath.path();
            const path_b = b.filePath.path();

            return std.mem.eql(u8, path_a, path_b);
        }
    };
};

pub fn writeFile(ctx: *AppContext, w: *std.Io.Writer, filePath: config.FilePath, comptime contentOp: ?ContentOp, cacheIt: bool) !void {
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
                    std.debug.assert(allocatorForFree != null or filePath == .builtin);

                    const encoder = std.base64.standard_no_pad.Encoder;
                    try encoder.encodeWriter(w, content);

                    return;
                }
            },
        }
    } else blk: {
        if (cacheIt and filePath != .builtin) {
            break :blk content;
        } else {
            std.debug.assert(allocatorForFree != null or filePath == .builtin);

            try w.writeAll(content);
            return;
        }
    };

    try w.writeAll(writtenContent);

    try ctx._cachedContents.put(.{ .filePath = filePath, .contentOp = contentOp }, writtenContent);
}
