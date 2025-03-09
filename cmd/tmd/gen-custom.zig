const std = @import("std");

const tmd = @import("tmd");

pub fn customFn(w: std.io.AnyWriter, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) anyerror!void {
    const attrs = custom.attributes();
    if (std.ascii.eqlIgnoreCase(attrs.app, "html")) {
        return tmd.htmlCustomDefaultGenFn(w, doc, custom);
    }
}
