const std = @import("std");

const tmd = @import("tmd.zig");
const render = @import("doc_to_html-render.zig");
const fns = @import("doc_to_html-fns.zig");

pub const GenOptions = render.GenOptions;
pub const GenCallback = render.GenCallback;

pub fn doc_to_html(writer: anytype, tmdDoc: *const tmd.Doc, options: GenOptions, allocator: std.mem.Allocator) !void {
    var r: render.TmdRender = .init(tmdDoc, allocator, options);
    try r.render(writer);
}

pub fn write_doc_title(writer: anytype, tmdDoc: *const tmd.Doc) !bool {
    var r: render.TmdRender = .init(tmdDoc, undefined, undefined);
    return try r.writeTitleInHtmlHeader(writer);
}

pub const GenCallback_HtmlBlock = struct {
    doc: *const tmd.Doc,
    custom: *const tmd.BlockType.Custom,

    pub fn write(self: *const GenCallback_HtmlBlock, w: std.io.AnyWriter) !void {
        var line = self.custom.startDataLine() orelse return;
        const endDataLine = self.custom.endDataLine().?;
        std.debug.assert(endDataLine.lineType == .data);

        while (true) {
            std.debug.assert(line.lineType == .data);

            try w.writeAll(self.doc.rangeData(line.range(.trimLineEnd)));
            try w.writeAll("\n");

            if (line == endDataLine) break;
            line = line.next() orelse unreachable;
        }
    }
};