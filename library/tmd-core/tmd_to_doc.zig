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

pub fn parse_tmd(tmdData: []const u8, allocator: std.mem.Allocator, comptime canDump: bool) !tmd.Doc {
    if (tmdData.len > tmd.MaxDocSize) return error.DocSizeTooLarge;

    var tmdDoc = tmd.Doc{ .allocator = allocator, .data = tmdData };
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

    if (canDump) DocDumper.dumpTmdDoc(&tmdDoc);
    DocVerifier.verifyTmdDoc(&tmdDoc);

    return tmdDoc;
}
