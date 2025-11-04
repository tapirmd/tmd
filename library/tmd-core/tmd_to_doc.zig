const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd.zig");
const list = @import("list");
const tree = @import("tree");

//const AttributeParser = @import("tmd_to_doc-attribute_parser.zig");
//const LineScanner = @import("tmd_to_doc-line_scanner.zig");
const DocDumper = @import("tmd_to_doc-doc_dumper.zig");
const DocVerifier = @import("tmd_to_doc-doc_verifier.zig");
const DocParser = @import("tmd_to_doc-doc_parser.zig");

pub fn parse_tmd(tmdData: []const u8, allocator: std.mem.Allocator) !tmd.Doc {
    if (tmdData.len > tmd.MaxDocSize) return error.DocSizeTooLarge;

    const hasBOM = tmdData.len >= 3 and tmdData[0] == 0xef and tmdData[1] == 0xbb and tmdData[2] == 0xbf;
    const data = if (hasBOM) tmdData[3..] else tmdData;

    var tmdDoc = tmd.Doc{ .allocator = allocator, .hasBOM = hasBOM, .data = data };
    errdefer tmdDoc.destroy();

    const BlockRedBlack = tree.RedBlack(*tmd.Block, tmd.Block);
    const nilBlockTreeNodeElement = try tmdDoc._blockTreeNodes.createElement(allocator, true);
    const nilBlockTreeNode = &nilBlockTreeNodeElement.value;
    nilBlockTreeNode.* = BlockRedBlack.MakeNilNode();
    tmdDoc.blocksByID.init(nilBlockTreeNode);

    var docParser = DocParser{
        .tmdDoc = &tmdDoc,
    };
    try docParser.parseAll();

    if (builtin.mode == .Debug) tmdDoc.verify();

    return tmdDoc;
}
