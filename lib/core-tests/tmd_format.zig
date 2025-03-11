const std = @import("std");
const tmd = @import("tmd");

const exampleTmdContents: []const []const u8 = &.{
    \\
    ,
    \\### 
    \\the above line ends with a space
};

test "tmd format" {
    for (exampleTmdContents) |tmdContent| {
        // 1st pass

        var doc = try tmd.Doc.parse(tmdContent, std.testing.allocator);
        defer doc.destroy();

        var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 1 << 19);
        defer buf.deinit();

        try doc.writeTMD(buf.writer(), true);
        const newContent = buf.items;
        if (std.mem.eql(u8, newContent, tmdContent)) continue;

        // 2nd pass

        var doc2 = try tmd.Doc.parse(newContent, std.testing.allocator);
        defer doc2.destroy();

        var buf2 = try std.ArrayList(u8).initCapacity(std.testing.allocator, 1 << 19);
        defer buf2.deinit();

        try doc2.writeTMD(buf2.writer(), true);
        const newContent2 = buf2.items;

        try std.testing.expectEqualStrings(newContent, newContent2);
    }
}
