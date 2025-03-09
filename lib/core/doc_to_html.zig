const std = @import("std");

const tmd = @import("tmd.zig");
const render = @import("doc_to_html-render.zig");
const fns = @import("doc_to_html-fns.zig");

pub const Options = struct {
    customFn: ?*const fn (w: std.io.AnyWriter, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) anyerror!void = null,
    identSuffix: []const u8 = "", // for forum posts etc. To avoid id duplications.
    autoIdentSuffix: []const u8 = "", // to avoid some auto id duplication. Should only be used when identPrefix is blank.
    renderRoot: bool = true,
};

fn dummayCustomFn(_: std.io.AnyWriter, _: *const tmd.Doc, _: *const tmd.BlockType.Custom) anyerror!void {}

pub fn doc_to_html(writer: anytype, tmdDoc: *const tmd.Doc, options: Options, allocator: std.mem.Allocator) !void {
    var r = render.TmdRender{
        .doc = tmdDoc,
        .allocator = allocator,

        .customFn = options.customFn orelse dummayCustomFn,
        .identSuffix = options.identSuffix,
        .autoIdentSuffix = if (options.autoIdentSuffix.len > 0) options.autoIdentSuffix else options.identSuffix,
        .renderRoot = options.renderRoot,
    };

    try r.render(writer);
}

pub fn write_doc_title(writer: anytype, tmdDoc: *const tmd.Doc) !bool {
    var r = render.TmdRender{
        .doc = tmdDoc,
        .allocator = undefined,

        .customFn = undefined,
    };

    return try r.writeTitleInHtmlHeader(writer);
}

pub fn htmlCustomGenFn(w: std.io.AnyWriter, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) anyerror!void {
    var line = custom.startDataLine() orelse return;
    const endDataLine = custom.endDataLine().?;
    std.debug.assert(endDataLine.lineType == .data);

    while (true) {
        std.debug.assert(line.lineType == .data);

        _ = try w.write(doc.rangeData(line.range(.trimLineEnd)));
        _ = try w.write("\n");

        if (line == endDataLine) break;
        line = line.next() orelse unreachable;
    }
}
