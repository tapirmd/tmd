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

        var wa: std.Io.Writer.Allocating = ..initCapacity(std.testing.allocator, 1 << 19);
        defer wa.deinit();

        try doc.writeTMD(&wa.writer, true);
        try wa.writer.flush(); // no-op

        const newContent = wa.written();
        if (std.mem.eql(u8, newContent, tmdContent)) continue;

        // 2nd pass

        var doc2 = try tmd.Doc.parse(newContent, std.testing.allocator);
        defer doc2.destroy();

        var wa2: std.Io.Writer.Allocating = ..initCapacity(std.testing.allocator, 1 << 19);
        defer wa2.deinit();

        try doc2.writeTMD(&wa2.writer, true);
        try wa2.writer.flush(); // no-op

        const newContent2 = wa2.written();
        
        try std.testing.expectEqualStrings(newContent, newContent2);
    }
}
