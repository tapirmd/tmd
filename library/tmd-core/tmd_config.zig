const std = @import("std");

const tmd = @import("tmd.zig");

pub const Config = struct {
    doc: *const tmd.Doc,

    // blank key means the whole doc.
    //pub fn value(comptime T: type, key: []const u8) !T {
    //  switch (@typeInfo(T))
    //}

    //pub const ValueIterator = struct {
    //  pub fn first() []const u8 {
    //  }
    //
    //  pub fn next() ![]const u8 {
    //  }
    //};

    //pub fn values(key: []const u8) ?ValueIterator {
    //  ValueIterator
    //}

    //pub fn boolValue(key: []const u8) ?ValueIterator {
    //}

    //pub fn intValue(comptime T: type, key: []const u8) ?T {
    //}

    pub fn stringValue(config: *const Config, key: []const u8) ?[]const u8 {
        const block = config.doc.blockByID(key) orelse return null;

        return switch (block.blockType) {
            .header, .usual => blk: {
                var iter = block.inlineTokens();
                var token = iter.first() orelse break :blk "";
                while (true) {
                    switch (token.*) {
                        .plaintext => break :blk config.doc.rangeData(token.range()),
                        // ToDo: .evenBackticks ?
                        else => {},
                    }
                    token = iter.next() orelse break :blk "";
                }
            },
            inline .code, .custom => |c| blk: {
                const startLine = c.startDataLine() orelse break :blk "";
                const endLine = c.endDataLine() orelse unreachable;
                break :blk config.doc.rangeData(.{ .start = startLine.start(.none), .end = endLine.end(.trimLineEnd) });
            },
            else => "",
        };
    }
};
