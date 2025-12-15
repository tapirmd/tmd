const std = @import("std");

const tmd = @import("tmd.zig");
const render = @import("doc_to_html-render.zig");
const fns = @import("doc_to_html-fns.zig");

pub const GenOptions = render.GenOptions;
pub const Generator = render.Generator;

pub fn doc_to_html(writer: *std.Io.Writer, tmdDoc: *const tmd.Doc, options: GenOptions, allocator: std.mem.Allocator) !void {
    var r: render.TmdRender = .init(tmdDoc, allocator, options);
    try r.render(writer);
}

pub fn write_doc_title_in_html_head(writer: *std.Io.Writer, tmdDoc: *const tmd.Doc) !bool {
    var r: render.TmdRender = .init(tmdDoc, undefined, undefined);
    return try r.writeTitleInHtmlHead(writer);
}

pub fn write_doc_title_in_html_toc_item(writer: *std.Io.Writer, tmdDoc: *const tmd.Doc) !bool {
    var r: render.TmdRender = .init(tmdDoc, undefined, undefined);
    return try r.writeTitleInTocItem(writer);
}

pub const HtmlBlockGenerator = struct {
    doc: *const tmd.Doc, // just use its data
    custom: *const tmd.BlockType.Custom,

    pub fn gen(self: *const HtmlBlockGenerator, w: *std.Io.Writer) !void {
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

    pub fn asGenBacklback(self: *HtmlBlockGenerator, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) tmd.Generator {
        self.* = .{ .doc = doc, .custom = custom };
        return .init(self);
    }
};
