//! This module provides functions for parse tmd files (as Doc),
//! and functions for rendering (Doc) to HTML.

pub const version = @import("version.zig").version;

pub const exampleCSS = @embedFile("example.css");

pub const GenOptions = @import("doc_to_html.zig").GenOptions;
pub const Generator = @import("doc_to_html.zig").Generator;
pub const HtmlBlockGenerator = @import("doc_to_html.zig").HtmlBlockGenerator;

pub const FilePathType = @import("tmd_to_doc-attribute_parser.zig").FilePathType;
pub const checkFilePathType = @import("tmd_to_doc-attribute_parser.zig").checkFilePathType;
pub const parseLinkURL = @import("tmd_to_doc-attribute_parser.zig").parseLinkURL;
pub const Extension = @import("tmd_to_doc-attribute_parser.zig").Extension;
pub const ExtensionInfo = @import("tmd_to_doc-attribute_parser.zig").ExtensionInfo;
pub const extensionFromString = @import("tmd_to_doc-attribute_parser.zig").extensionFromString;
pub const extension = @import("tmd_to_doc-attribute_parser.zig").extension;
pub const getExtensionInfo = @import("tmd_to_doc-attribute_parser.zig").getExtensionInfo;

pub const writeHtmlAttributeValue = @import("doc_to_html-fns.zig").writeHtmlAttributeValue;
pub const writeUrlAttributeValue = @import("doc_to_html-fns.zig").writeUrlAttributeValue;
pub const writeHtmlContentText = @import("doc_to_html-fns.zig").writeHtmlContentText;

pub const bytesKindTable = @import("tmd_to_doc-line_scanner.zig").bytesKindTable;
pub const trimBlanks = @import("tmd_to_doc-line_scanner.zig").trim_blanks;

//pub var wasmLog: ?*const fn(msg: []const u8, extraMsg: []const u8, extraInt: isize) void = blk: {
//    const T = struct {
//        fn logMessage(msg: []const u8, extraMsg: []const u8, extraInt: isize) void {
//            std.debug.print("{s}, {s}, {}\n", .{msg, extraMsg, extraInt});
//        }
//    };
//    break :blk if (builtin.mode == .Debug) T.logMessage else null;
//};

const std = @import("std");
const builtin = @import("builtin");
const list = @import("list");
const tree = @import("tree");

pub const Doc = struct {
    allocator: std.mem.Allocator = undefined,

    data: []const u8,
    hasBOM: bool = false,
    blocks: list.List(Block) = .{},
    lines: list.List(Line) = .{},
    blockCount: u32 = 0,
    lineCount: u32 = 0,

    tocHeaders: list.List(*Block) = .{},
    titleHeader: ?*Block = null,
    // User should use the headerLevelNeedAdjusted method instead.
    _headerLevelNeedAdjusted: [MaxHeaderLevel]bool = @splat(false),

    blocksByID: BlockRedBlack.Tree = .{}, // ToDo: use PatriciaTree to get a better performance

    // The followings are used to track allocations for destroying.
    // ToDo: prefix them with _?

    links: Link.List = .{}, // ToDo: use Link.next instead of List?

    _blockTreeNodes: list.List(BlockRedBlack.Node) = .{}, // ToDo: use SinglyLinkedList
    // It is in _blockTreeNodes when exists. So no need to destroy it solely in the end.
    _freeBlockTreeNodeElement: ?*BlockRedBlackNodeList.Element = null,
    _urls: list.List(URL) = .{}, // ToDo: use SinglyLinkedList
    _elementAttributes: list.List(ElementAttibutes) = .{}, // ToDo: use SinglyLinkedList
    _baseBlockAttibutes: list.List(BaseBlockAttibutes) = .{}, // ToDo: use SinglyLinkedList
    _codeBlockAttibutes: list.List(CodeBlockAttibutes) = .{}, // ToDo: use SinglyLinkedList
    _customBlockAttibutes: list.List(CustomBlockAttibutes) = .{}, // ToDo: use SinglyLinkedList
    _contentStreamAttributes: list.List(ContentStreamAttributes) = .{}, // ToDo: use SinglyLinkedList

    const BlockRedBlack = tree.RedBlack(*Block, Block);
    const BlockRedBlackNodeList = list.List(BlockRedBlack.Node);

    pub fn parse(tmdData: []const u8, allocator: std.mem.Allocator) !Doc {
        return try @import("tmd_to_doc.zig").parse_tmd(tmdData, allocator);
    }

    pub fn destroy(doc: *Doc) void {
        doc.blocks.destroy(null, doc.allocator);

        const T = struct {
            fn destroyLineTokens(line: *Line, a: std.mem.Allocator) void {
                //if (line.tokens()) |tokens| {
                //    tokens.*.destroy(null, a);
                //}
                line.tokens.destroy(null, a);
            }
        };

        doc.lines.destroy(T.destroyLineTokens, doc.allocator);

        doc._elementAttributes.destroy(null, doc.allocator);
        doc._urls.destroy(null, doc.allocator);
        doc._baseBlockAttibutes.destroy(null, doc.allocator);
        doc._codeBlockAttibutes.destroy(null, doc.allocator);
        doc._customBlockAttibutes.destroy(null, doc.allocator);
        doc._contentStreamAttributes.destroy(null, doc.allocator);

        doc._blockTreeNodes.destroy(null, doc.allocator);

        doc.links.destroy(null, doc.allocator);
        doc.tocHeaders.destroy(null, doc.allocator);

        doc.* = .{ .data = "" };
    }

    pub fn writePageTitle(doc: *const Doc, writer: *std.Io.Writer, comptime purpose: enum { inHtmlHead, htmlTocItem }) !bool {
        return switch (purpose) {
            .inHtmlHead => try @import("doc_to_html.zig").write_doc_title_in_html_head(writer, doc),
            .htmlTocItem => try @import("doc_to_html.zig").write_doc_title_in_html_toc_item(writer, doc),
        };
    }

    pub fn writeHTML(doc: *const Doc, writer: *std.Io.Writer, genOptions: GenOptions, allocator: std.mem.Allocator) !void {
        try @import("doc_to_html.zig").doc_to_html(writer, doc, genOptions, allocator);
    }

    pub fn writeTMD(doc: *const Doc, writer: *std.Io.Writer, comptime format: bool) !void {
        try @import("doc_to_tmd.zig").doc_to_tmd(writer, doc, format);
    }

    pub const verify = @import("tmd_to_doc-doc_verifier.zig").verifyTmdDoc;
    pub const dumpAst = @import("tmd_to_doc-doc_dumper.zig").dumpTmdDoc;

    // A doc always has a root block. And the root
    // block is always the first block of the doc.
    pub fn rootBlock(doc: *const @This()) *const Block {
        return if (doc.blocks.head) |head| {
            std.debug.assert(head.value.blockType == .root);
            return &head.value;
        } else unreachable;
    }

    pub fn blockByID(self: *const @This(), id: []const u8) ?*const Block {
        var a = ElementAttibutes{
            .id = id,
        };
        var b = Block{
            .blockType = undefined,
            .attributes = &a,
        };

        return if (self.blocksByID.search(&b)) |node| node.value else null;
    }

    pub fn traverseBlockIDs(self: *const @This(), onID: *fn ([]const u8) void) void {
        const NodeHandler = struct {
            onID: *fn ([]const u8) void,

            pub fn onNode(h: @This(), node: *BlockRedBlack.Node) void {
                h.onID(node.value.ElementAttibutes.id);
            }
        };

        const handler = NodeHandler{ .onID = onID };
        self.blocksByID.traverseNodes(handler);
    }

    pub fn firstLine(self: *const @This()) ?*const Line {
        return if (self.lines.head) |le| &le.value else null;
    }

    pub fn rangeData(self: *const @This(), r: Range) []const u8 {
        return self.data[r.start..r.end];
    }

    pub fn headerLevelNeedAdjusted(self: *const @This(), level: u8) bool {
        std.debug.assert(1 <= level and level <= MaxHeaderLevel);
        return self._headerLevelNeedAdjusted[level - 1];
    }

    pub fn asConfig(self: *const @This()) @import("tmd_config.zig").Config {
        return .{ .doc = self };
    }
};

pub const DocSize = u28; // max 256M (in practice, most TMD doc sizes < 1M)
pub const MaxDocSize: u32 = 1 << @bitSizeOf(DocSize) - 1;

pub const Range = struct {
    start: u32, // ToDo: use DocSize instead?
    end: u32,
};

// ToDo: u8 -> usize?
pub const MaxHeaderLevel: u8 = 4;
pub fn headerLevel(headeMark: []const u8) ?u8 {
    if (headeMark.len < 2) return null;
    if (headeMark[0] != '#' or headeMark[1] != '#') return null;
    if (headeMark.len == 2) return 1;
    return switch (headeMark[headeMark.len - 1]) {
        '#' => 1,
        '=' => 2,
        '+' => 3,
        '-' => 4,
        else => null,
    };
}

pub const MaxSpanMarkLength = 8; // not inclusive. And not include ^.

// Note: the two should be consistent.
pub const MaxListNestingDepthPerBase = 11;
pub const ListItemTypeIndex = u4;
pub const ListNestingDepthType = u8; // in fact, u4 is enough now

pub fn listItemTypeIndex(itemMark: []const u8) ListItemTypeIndex {
    switch (itemMark.len) {
        1, 2 => {
            var index: ListItemTypeIndex = switch (itemMark[0]) {
                '+' => 0,
                '-' => 1,
                '*' => 2,
                '~' => 3,
                ':' => 4,
                '=' => 5,
                else => unreachable,
            };

            if (itemMark.len == 1) {
                return index;
            }

            if (itemMark[1] != '.') unreachable;
            index += 6;

            return index;
        },
        else => unreachable,
    }
}

// When this function is called, .tabs is still unable to be determined.
pub fn listType(itemMark: []const u8) ListType {
    switch (itemMark.len) {
        1, 2 => return switch (itemMark[0]) {
            '+', '-', '*', '~' => .bullets,
            ':' => .definitions,
            else => unreachable,
        },
        else => unreachable,
    }
}

pub const ElementAttibutes = struct {
    id: []const u8 = "", // ToDo: should be a Range?
    classes: []const u8 = "", // ToDo: should be Range list?
    //kvs: []const u8 = "", // ToDo: should be Range list?
};

// The definition is not the same as web URL.
pub const URL = struct {
    pub const RelativeManner = struct {
        extension: ?Extension,

        pub fn isTmdFile(self: @This()) bool {
            const ext = self.extension orelse return false;
            return ext == .tmd;
        }

        pub fn isImageFile(self: @This()) bool {
            const ext = self.extension orelse return false;
            return getExtensionInfo(ext).isImage;
        }
    };

    manner: union(enum) {
        undetermined, //
        absolute, // .base contains :// (not support //xxx.yyy/...)
        relative: RelativeManner, // relative ablolute paths (/foo/bar) are not supported.
        footnote, // __#[id]__. __#__ means all footnotes.
        invalid, // should only be set by custom handlers
    } = .undetermined,

    // ToDo: need it?
    // determinedByCustomHandler: bool = false,

    // !!! Don't refactor off this field. It provides
    //     a simple and robust way to detect whether or not
    //     the link text of a hyperlink ends in rendering.
    //
    //     It can also be used as the map key for custom link
    //     presentations in user custom callback handler code.
    //     (But now custom handlers should user *URL as map key.)
    //
    // This is the head of a list. See Token.PlainText.nextInLink.
    // It is only valid when .more.urlSourceSet == true.
    sourceContentToken: ?*const Token = null, // null for a blank link span

    // For .absloute, this inlcudes the fragment part.
    base: []const u8 = "",

    // The ending part starting with #, if it exists.
    // The meanings of this part for doc and media are different.
    // Always blank for doc links with .absolute manner.
    fragment: []const u8 = "",

    // Use as tooltip.
    // ToDo: support it? Only in link definition. Using comment lines?
    //       Be aware that self-link media might cause 2 tooltips,
    //       one for media, the other for hyperlink.
    //       Best not to support it.
    //title: []const u8 = "",
};

pub const Link = struct {
    const List = list.List(@This());

    pub const Owner = union(enum) {
        block: *Block, // for link definition. (.blockType == .linkdef)
        hyper: *Token, // for hyperlink. Token.LinkInfo.
        media: *Token, // for media. Token.LinkInfo.
    };

    // ToDo: use pointer? Memory will be more fragmental.
    // ToDo: now this field is never set.
    // attrs: ElementAttibutes = .{},

    owner: Owner,

    // This is the head of a list. See Token.PlainText.nextInLink.
    firstContentToken: ?*Token = null, // null for a blank link span

    // null means .sourceContentToken has not been determined.
    url: ?*URL = null,

    //more: packed struct {
    //    urlSourceSet: bool = false,
    //    urlConfirmed: bool = false,
    //    //blankSourceOfURL: bool = false,
    //    //isFootnote: bool = false,
    //} = .{},

    // ToDo: remove the setXXX pub funcitons. Use fileds directly.

    pub fn linkBlock(self: *const @This()) ?*const Block {
        return switch (self.owner) {
            .block => |block| block,
            else => null,
        };
    }
};

pub const BaseBlockAttibutes = struct {
    undisplayed: bool = false, // ToDo: use Range
    horizontalAlign: enum {
        none,
        left,
        center,
        right,
        justify,
    } = .none,
    verticalAlign: enum {
        none,
        top,
    } = .none,
    cellSpans: struct {
        axisSpan: u32 = 1,
        crossSpan: u32 = 1,
    } = .{},
};

pub const CodeBlockAttibutes = struct {
    undisplayed: bool = false, // ToDo: use Range
    language: []const u8 = "", // ToDo: use Range
    // ToDo
    // startLineNumber: u32 = 0, // +n, +0 means not show line numbers
    // filepath: []const u8 = "", // @path
};

pub const ContentStreamAttributes = struct {
    content: []const u8 = "", // ToDo: use Range
};

pub const CustomBlockAttibutes = struct {
    undisplayed: bool = false,
    contentType: []const u8 = "",
    //arguments: []const []const u8 = "",
    // The last argument is the content in the following custom block.
    // ToDo: support streaming. (more arguments)
    //       Streaming other blocks increases much implementation complexity.
    //       Streaming file is simpler.
};

pub const MediaAttributes = struct {
    // ToDo: ...
};

// Note: keep the two consistent.
pub const MaxBlockNestingDepth = 64; // should be 2^N
pub const BlockNestingDepthType = u6; // must be capable of storing MaxBlockNestingDepth-1

pub const Block = struct {
    index: u32 = undefined, // one basedd (for debug purpose only, ToDo: voidOr(u32))
    nestingDepth: u32 = 0, // ToDo: can be of BlockNestingDepthType and put in .more

    blockType: BlockType, // ToDo: renamed to "type".

    attributes: ?*ElementAttibutes = null,

    more: packed struct {
        // for .usual atom blocks only
        hasNonMediaContentTokens: bool = false,
    } = .{},

    pub const default: Block = .{ .blockType = undefined };

    pub fn typeName(self: *const @This()) []const u8 {
        return @tagName(self.blockType);
    }

    // for atom blocks

    pub fn isContainer(self: *const @This()) bool {
        return switch (self.blockType) {
            inline else => |bt| @hasDecl(@TypeOf(bt), "Container"),
        };
    }

    pub fn isAtom(self: *const @This()) bool {
        return switch (self.blockType) {
            inline else => |bt| @hasDecl(@TypeOf(bt), "Atom"),
        };
    }

    pub fn startLine(self: *const @This()) *const Line {
        return switch (self.blockType) {
            inline else => |bt| {
                if (@hasDecl(@TypeOf(bt), "Atom")) {
                    return bt.startLine;
                }
                unreachable;
            },
        };
    }

    pub fn setStartLine(self: *@This(), line: *Line) void {
        return switch (self.blockType) {
            inline else => |*bt| {
                if (@hasDecl(@TypeOf(bt.*), "Atom")) {
                    bt.startLine = line;
                    return;
                }
                unreachable;
            },
        };
    }

    pub fn endLine(self: *const @This()) *const Line {
        return switch (self.blockType) {
            inline else => |bt| {
                if (@hasDecl(@TypeOf(bt), "Atom")) {
                    return bt.endLine;
                }
                unreachable;
            },
        };
    }

    pub fn setEndLine(self: *@This(), line: *Line) void {
        return switch (self.blockType) {
            inline else => |*bt| {
                if (@hasDecl(@TypeOf(bt.*), "Atom")) {
                    bt.endLine = line;
                    return;
                }
                unreachable;
            },
        };
    }

    // For atom blocks only (for tests purpose).
    // ToDo: maybe it is best to support a token iterator which also
    //       iterates block/line mark and line start/end tokens.
    pub fn inlineTokens(self: *const @This()) InlineTokenIterator {
        std.debug.assert(self.isAtom());

        return inlineTokensBetweenLines(self.startLine(), self.endLine());
    }

    //pub fn isBare(self: *const @This()) bool {
    //    std.debug.assert(self.isAtom());
    //    const line = self.startLine();
    //    return line == self.endLine() and line.firstTokenOf(.others) == null;
    //}

    pub fn compare(x: *const @This(), y: *const @This()) isize {
        const xAttributes = x.attributes orelse unreachable;
        const yAttributes = y.attributes orelse unreachable;
        const xID = if (xAttributes.id.len > 0) xAttributes.id else unreachable;
        const yID = if (yAttributes.id.len > 0) yAttributes.id else unreachable;
        return switch (std.mem.order(u8, xID, yID)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
    }

    // Only atom blocks and base blocks may be footer blocks.
    pub fn footerAttibutes(self: *const @This()) ?*const ElementAttibutes {
        //if (self.isContainer()) unreachable;
        if (self.isContainer()) return null;

        if (self.nextSibling()) |sibling| {
            if (sibling.blockType == .attributes) {
                if (sibling.nextSibling() == null)
                    return sibling.attributes;
            }
        }

        return null;
    }

    const List = list.List(@This());

    fn ownerListElement(self: *const @This()) *const Block.List.Element {
        return @alignCast(@fieldParentPtr("value", self));
    }

    //pub fn next(self: *const @This()) ?*const Block {
    //    return &(self.ownerListElement().next orelse return null).value;
    //}

    //pub fn prev(self: *const @This()) ?*const Block {
    //    return &(self.ownerListElement().prev orelse return null).value;
    //}

    pub fn next(self: anytype) ?@TypeOf(self) {
        return &(self.ownerListElement().next orelse return null).value;
    }

    pub fn prev(self: anytype) ?@TypeOf(self) {
        return &(self.ownerListElement().prev orelse return null).value;
    }

    pub fn firstChild(self: *const @This()) ?*const Block {
        switch (self.blockType) {
            .root, .base => if (self.next()) |nextBlock| {
                if (nextBlock.nestingDepth > self.nestingDepth) return nextBlock;
            },
            else => {
                if (self.isContainer()) return self.next().?;
            },
        }

        return null;
    }

    pub fn nextSibling(self: *const @This()) ?*const Block {
        return switch (self.blockType) {
            .root => null,
            .base => |base| blk: {
                const closeLine = base.closeLine orelse break :blk null;
                const nextBlock = closeLine.extraInfo().?.blockRef orelse break :blk null;
                // The assurence is necessary.
                break :blk if (nextBlock.nestingDepth == self.nestingDepth) nextBlock else null;
            },
            .list => |itemList| blk: {
                std.debug.assert(itemList._lastItemConfirmed);
                break :blk itemList.lastBullet.blockType.item.nextSibling;
            },
            .item => |*item| if (item.ownerBlock() == item.list.blockType.list.lastBullet) null else item.nextSibling,
            inline .table, .quotation, .callout, .reveal, .raw => |container| blk: {
                const nextBlock = container.nextSibling orelse break :blk null;
                // ToDo: the assurence might be unnecessary.
                break :blk if (nextBlock.nestingDepth == self.nestingDepth) nextBlock else null;
            },
            inline else => blk: {
                std.debug.assert(self.isAtom());
                if (self.blockType.ownerBlock().next()) |nextBlock| {
                    std.debug.assert(nextBlock.nestingDepth <= self.nestingDepth);
                    if (nextBlock.nestingDepth == self.nestingDepth)
                        break :blk nextBlock;
                }
                break :blk null;
            },
        };
    }

    // Note, for .base, it is a potential sibling.
    pub fn setNextSibling(self: *@This(), sibling: *Block) void {
        return switch (self.blockType) {
            .root => unreachable,
            .base => |base| {
                if (base.closeLine) |closeLine| {
                    if (closeLine.extraInfo()) |info| info.blockRef = sibling;
                }
            },
            .list => |itemList| {
                std.debug.assert(itemList._lastItemConfirmed);
                //itemList.lastBullet.blockType.item.nextSibling = sibling;
                unreachable; // .list.nextSibling is always set through its .lastItem.
            },
            inline .item, .table, .quotation, .callout, .reveal, .raw => |*container| {
                container.nextSibling = sibling;
            },
            else => {
                std.debug.assert(self.isAtom());
                // do nothing
            },
        };
    }

    pub fn specialHeaderChild(self: *const @This(), tmdData: []const u8) ?*const Block {
        std.debug.assert(self.isContainer() or self.blockType == .base);
        var child = self.firstChild() orelse return null;
        while (true) {
            switch (child.blockType) {
                .attributes => {
                    child = child.nextSibling() orelse break;
                    continue;
                },
                .header => |header| if (header.level(tmdData) == 1) return child else break,
                else => break,
            }
        }
        return null;
    }
};

pub const ListType = enum {
    bullets,
    tabs,
    definitions,
};

pub const BlockType = union(enum) {
    pub const Custom = @FieldType(BlockType, "custom");
    // ToDo: others ..., when needed.

    // container block types

    item: struct {
        //isFirst: bool, // ToDo: can be saved
        //isLast: bool, // ToDo: can be saved (need .list.lastItem)

        list: *Block, // a .list
        nextSibling: ?*Block = null, // for .list.lastBullet, it is .list's sibling.

        const Container = void;

        pub fn isFirst(self: *const @This()) bool {
            return self.list.next().? == self.ownerBlock();
        }

        pub fn isLast(self: *const @This()) bool {
            return self.list.blockType.list.lastBullet == self.ownerBlock();
        }

        pub fn ownerBlock(self: anytype) if (isConst(@TypeOf(self))) *const Block else *Block {
            const bt: if (isConst(@TypeOf(self))) *const BlockType else *BlockType = @alignCast(@fieldParentPtr("item", self));
            return bt.ownerBlock();
        }
    },

    list: struct { // lists are implicitly formed.
        _lastItemConfirmed: bool = false, // for debug
        _itemTypeIndex: ListItemTypeIndex, // ToDo: can be saved, just need a little more computitation.

        listType: ListType,
        secondMode: bool, // for .bullets: unordered/ordered, for .definitions, one-line or not
        index: u32, // for debug purpose

        lastBullet: *Block = undefined,
        // nextSibling: ?*Block, // .lastBullet.nextSibling

        // Note: the depth of the list is the same as its children

        const Container = void;

        pub fn typeName(self: @This()) []const u8 {
            return @tagName(self.listType);
        }

        //pub fn bulletType(self: @This()) BulletType {
        //    if (self._itemTypeIndex & 0b100 != 0) return .ordered;
        //    return .unordered;
        //}
    },

    table: struct {
        const Container = void;
        nextSibling: ?*Block = null,
    },
    quotation: struct {
        const Container = void;
        nextSibling: ?*Block = null,
    },
    callout: struct {
        const Container = void;
        nextSibling: ?*Block = null,
    },
    reveal: struct {
        const Container = void;
        nextSibling: ?*Block = null,
    },
    raw: struct {
        const Container = void;
        nextSibling: ?*Block = null,
    },

    // base context block

    root: struct {
        doc: *Doc,
    },

    base: struct {
        openLine: *Line,
        closeLine: ?*Line = null,
        // nextSibling: ?*Block, // openLine.baseNextSibling

        pub fn attributes(self: @This()) BaseBlockAttibutes {
            if (self.openLine.extraInfo()) |info| {
                if (info.baseBlockAttrs) |attrs| return attrs.*;
            }
            return .{};
        }

        pub fn openPlayloadRange(self: @This()) Range {
            return self.openLine.playloadRange();
        }

        pub fn closePlayloadRange(self: @This()) ?Range {
            return if (self.closeLine) |closeLine| closeLine.playloadRange() else null;
        }
    },

    // atom block types

    blank: struct {
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // traits:
        const Atom = void;
    },

    seperator: struct {
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // traits:
        const Atom = void;
    },

    header: struct {
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // traits:
        const Atom = void;

        pub fn level(self: @This(), tmdData: []const u8) u8 {
            const headerLine = self.startLine;
            const start = headerLine.start(.trimContainerMark);
            const end = start + headerLine.lineTypeMarkToken().?.lineTypeMark.markLen;
            return headerLevel(tmdData[start..end]) orelse unreachable;
        }

        // An empty header is used to insert toc.
        pub fn isBare(self: @This()) bool {
            //return self.startLine == self.endLine and self.startLine.tokens().?.empty();

            return self.startLine == self.endLine and self.startLine.firstTokenOf(.others) == null;
        }
    },

    usual: struct {
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // ToDo: when false, no need to render.
        //       So a block with a singal ` will output nothing.
        //       Maybe needless with .blankSpan.
        // hasContent: bool = false,

        // traits:
        const Atom = void;
    },

    linkdef: struct {
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // traits:
        const Atom = void;

        // An empty header is used to insert toc.
        pub fn isBare(self: @This()) bool {
            //return self.startLine == self.endLine and self.startLine.tokens().?.empty();
            return self.startLine == self.endLine and self.startLine.firstTokenOf(.others) == null;
        }
    },

    attributes: struct {
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // traits:
        const Atom = void;
    },

    code: struct {
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // Note: the block end tag line might be missing.
        //       The endLine might not be a .codeBlockEnd line.
        //       and it can be also of .code or .codeBlockStart.

        // traits:
        const Atom = void;

        pub fn attributes(self: @This()) CodeBlockAttibutes {
            if (self.startLine.extraInfo()) |info| {
                if (info.codeBlockAttrs) |attrs| return attrs.*;
            }
            return .{};
        }

        pub fn contentStreamAttributes(self: @This()) ContentStreamAttributes {
            switch (self.endLine.lineType) {
                .codeBlockEnd => {
                    if (self.endLine.extraInfo()) |info| {
                        if (info.streamAttrs) |attrs| return attrs.*;
                    }
                },
                else => {},
            }
            return .{};
        }

        pub fn startPlayloadRange(self: @This()) Range {
            return self.startLine.playloadRange();
        }

        pub fn endPlayloadRange(self: @This()) ?Range {
            return switch (self.endLine.lineType) {
                .codeBlockEnd => |_| self.endLine.playloadRange(),
                else => null,
            };
        }

        pub fn startDataLine(self: @This()) ?*const Line {
            if (self.startLine.next()) |nextLine| {
                if (nextLine.lineType == .code) return nextLine;
            }
            return null;
        }

        pub fn endDataLine(self: @This()) ?*const Line {
            if (self.endLine.lineType == .code) return self.endLine;
            if (self.endLine.prev()) |prevLine| {
                if (prevLine.lineType == .code) return prevLine;
            }
            return null;
        }
    },

    custom: struct {
        startLine: *Line = undefined,
        endLine: *Line = undefined,

        // Note: the block end tag line might be missing.
        //       And the endLine might not be a .customBlockEnd line.
        //       It can be also of .data or .customBlockStart.

        // traits:
        const Atom = void;

        pub fn attributes(self: @This()) CustomBlockAttibutes {
            if (self.startLine.extraInfo()) |info| {
                if (info.customBlockAttrs) |attrs| return attrs.*;
            }
            return .{};
        }

        pub fn startPlayloadRange(self: @This()) Range {
            return self.startLine.playloadRange();
        }

        pub fn endPlayloadRange(self: @This()) ?Range {
            return switch (self.endLine.lineType) {
                .customBlockEnd => |_| self.endLine.playloadRange(),
                else => null,
            };
        }

        pub fn startDataLine(self: @This()) ?*const Line {
            if (self.startLine.next()) |nextLine| {
                if (nextLine.lineType == .data) return nextLine;
            }
            return null;
        }

        pub fn endDataLine(self: @This()) ?*const Line {
            if (self.endLine.lineType == .data) return self.endLine;
            if (self.endLine.prev()) |prevLine| {
                if (prevLine.lineType == .data) return prevLine;
            }
            return null;
        }
    },

    pub fn ownerBlock(self: anytype) if (isConst(@TypeOf(self))) *const Block else *Block {
        return @alignCast(@fieldParentPtr("blockType", self));
    }
};

fn isConst(Ptr: type) bool {
    return switch (@typeInfo(Ptr)) {
        .pointer => |p| p.is_const,
        else => @compileError("Ptr must be a pointer type."),
    };
}

fn voidOr(T: type) type {
    const ValueType = if (builtin.mode == .Debug) T else void;

    return struct {
        _value: ValueType,

        pub fn value(self: @This()) T {
            if (builtin.mode != .Debug) return 0;
            return self._value;
        }

        pub fn set(self: *@This(), v: T) void {
            if (builtin.mode != .Debug) return;
            self._value = v;
        }
    };
}

// For debug purpose, to replace voidOr in debugging.
fn identify(T: type) type {
    return struct {
        _value: T,

        pub fn value(self: @This()) T {
            return self._value;
        }

        pub fn set(self: *@This(), v: T) void {
            self._value = v;
        }
    };
}

pub const Line = struct {
    pub const Type = enum(u4) {
        blank,
        usual,
        header,
        seperator,
        linkdef,
        attributes,

        baseBlockOpen,
        baseBlockClose,

        codeBlockStart,
        codeBlockEnd,
        code,

        customBlockStart,
        customBlockEnd,
        data,
    };

    pub const EndType = enum(u2) {
        void, // doc end
        n, // \n
        rn, // \r\n

        pub fn typeName(self: @This()) []const u8 {
            return @tagName(self);
        }

        pub fn len(self: @This()) u2 {
            return switch (self) {
                .void => 0,
                .n => 1,
                .rn => 2,
            };
        }
    };

    _index: voidOr(u32) = undefined, // one based (for debug purpose only) ToDo: voidOf(u32)

    // Every line should belong to an atom block, except base block boundary lines.
    _atomBlockIndex: voidOr(u32) = undefined, // one based (for debug purpose only) ToDo: voidOf(u32)

    _startAt: voidOr(DocSize) = undefined, //

    // ToDo: it looks packing the following 6 fields doesn't reduce size at all.
    //       They use totally 91 bits, so 12 bytes (96 bits) are sufficient.
    //       But zig compiler will use 16 bytes for the packed struct anyway.
    //       Because the compiler always thinks the alignment of the packed struct is 16.
    //
    //       So maybe it is best to manually pack these fields.
    //       Use three u32 fields ...
    //       This can save 4 bytes.
    //       (Or use 3 packed structs instead? Each is composed of two origial fields.)

    // This is the end pos of the line end token.
    // It is also the start pos of the next line.
    endAt: DocSize = undefined,

    prefixBlankEnd: DocSize = undefined,
    suffixBlankStart: DocSize = undefined,

    endType: EndType = undefined,

    treatEndAsSpace: bool = false,

    lineType: Type = undefined, // ToDo: renamed to "type".

    tokens: list.List(Token) = .{},

    pub fn typeName(self: @This()) []const u8 {
        return @tagName(self.lineType);
    }

    pub fn endTypeName(self: @This()) []const u8 {
        return @tagName(self.endType);
    }

    pub fn isAttributes(self: @This()) bool {
        return self.lineType == .attributes;
    }

    const List = list.List(@This());

    fn ownerListElement(self: *const @This()) *const Line.List.Element {
        return @alignCast(@fieldParentPtr("value", self));
    }

    pub fn next(self: *const @This()) ?*const Line {
        return &(self.ownerListElement().next orelse return null).value;
    }

    pub fn prev(self: *const @This()) ?*const Line {
        return &(self.ownerListElement().prev orelse return null).value;
    }

    pub fn containerMarkToken(self: *const @This()) ?*const Token {
        if (self.firstTokenOf(.containerMark_or_others)) |token| {
            if (token.* == .containerMark) return token;
        }
        return null;
    }

    pub fn lineTypeMarkToken(self: *const @This()) ?*const Token {
        if (self.firstTokenOf(.lineTypeMark_or_others)) |token| {
            if (token.* == .lineTypeMark) return token;
        }
        return null;
    }

    fn extraInfo(self: *@This()) ?*Token.Extra.Info {
        if (self.firstTokenOf(.extra_or_others)) |constToken| {
            // ToDo: we can make firstTokenOf support adaptive const-ness result.
            const token = @constCast(constToken);
            if (token.* == .extra) {
                std.debug.assert(token.next().?.* == .lineTypeMark);
                return &token.extra.info;
            }
        }
        return null;
    }

    pub fn firstInlineToken(self: *const @This()) ?*const Token {
        return self.firstTokenOf(.others);
    }

    // Currently, .others means inline style or content tokens.
    pub fn firstTokenOf(self: *const @This(), tokenKind: enum { any, containerMark_or_others, extra_or_others, lineTypeMark_or_others, others }) ?*const Token {
        var tokenElement = self.tokens.head;

        switch (tokenKind) {
            .any, .containerMark_or_others => {
                if (tokenElement) |e| return &e.value;
            },
            .extra_or_others => {
                if (tokenElement) |e| {
                    if (e.value == .containerMark) tokenElement = e.next;
                }
                if (tokenElement) |e| return &e.value;
            },
            .lineTypeMark_or_others => {
                if (tokenElement) |e| {
                    if (e.value == .containerMark) tokenElement = e.next;
                }
                if (tokenElement) |e| {
                    if (e.value == .extra) {
                        tokenElement = e.next;
                        std.debug.assert(tokenElement.?.value == .lineTypeMark);
                        return &tokenElement.?.value;
                    } else return &e.value;
                }
            },
            .others => {
                if (tokenElement) |e| {
                    if (e.value == .containerMark) tokenElement = e.next;
                }
                if (tokenElement) |e| {
                    tokenElement = switch (e.value) {
                        .extra => e.next.?.next,
                        .lineTypeMark => e.next,
                        else => return &e.value,
                    };
                }
                if (tokenElement) |e| return &e.value;
            },
        }
        return null;
    }

    // Same as start(.none).
    fn startPos(self: *const @This()) DocSize {
        if (builtin.mode == .Debug) return self._startAt.value();
        return if (self.prev()) |prevLine| prevLine.endAt else 0;
    }

    pub fn start(self: *const @This(), trimOption: enum { none, trimLeadingSpaces, trimContainerMark }) DocSize {
        switch (trimOption) {
            .none => return self.startPos(),
            .trimLeadingSpaces => return self.prefixBlankEnd,
            .trimContainerMark => {
                if (self.tokens.head) |tokenElement| {
                    switch (tokenElement.value) {
                        .containerMark => return tokenElement.value.end(),
                        else => {},
                    }
                }
                return self.prefixBlankEnd;
            },
        }
    }

    pub fn end(self: *const @This(), trimOption: enum { none, trimLineEnd, trimTrailingSpaces }) DocSize {
        return switch (trimOption) {
            .none => self.endAt,
            .trimLineEnd => self.endAt - self.endType.len(),
            .trimTrailingSpaces => self.suffixBlankStart,
        };
    }

    pub fn range(self: *const @This(), trimOtion: enum { none, trimLineEnd, trimSpaces }) Range {
        return switch (trimOtion) {
            .none => .{ .start = self.startPos(), .end = self.endAt },
            .trimLineEnd => .{ .start = self.startPos(), .end = self.endAt - self.endType.len() },
            .trimSpaces => .{ .start = self.prefixBlankEnd, .end = self.suffixBlankStart },
        };
    }

    // ToDo: to opotimize, don't let parser use this method to
    //       get playload data for parsing.
    pub fn playloadRange(self: *const @This()) Range {
        std.debug.print("======= 000\n", .{});
        switch (self.lineType) {
            inline .baseBlockOpen,
            .baseBlockClose,
            .codeBlockStart,
            .codeBlockEnd,
            .customBlockStart,
            .customBlockEnd,
            => {
                const playloadStart = self.lineTypeMarkToken().?.end();
                std.debug.assert(playloadStart <= self.suffixBlankStart);
                return Range{ .start = playloadStart, .end = self.suffixBlankStart };
            },
            else => unreachable,
        }
    }

    pub fn isBoundary(self: *const @This()) bool {
        return switch (self.lineType) {
            inline .baseBlockOpen, .baseBlockClose, .codeBlockStart, .codeBlockEnd, .customBlockStart, .customBlockEnd => true,
            else => false,
        };
    }
};

pub const InlineTokenIterator = struct {
    _startLine: *const Line,
    _endLine: *const Line,
    _curentLine: *const Line,
    _currentToken: ?*const Token = null,

    // Call first will make other uses of the InlineTokenIterator illegal.
    pub fn first(self: *@This()) ?*const Token {
        return self.firstFromLine(self._startLine);
    }

    pub fn next(self: *@This()) ?*const Token {
        if (self._currentToken) |token| {
            if (token.next()) |nextToken| {
                self._currentToken = nextToken;
                return nextToken;
            }
            if (self._curentLine == self._endLine) {
                self._currentToken = null;
                return null;
            }
            if (self._curentLine.next()) |nextLine| return self.firstFromLine(nextLine);
            unreachable;
        } else unreachable;
    }

    fn firstFromLine(self: *@This(), line: *const Line) ?*const Token {
        self._curentLine = line;
        while (true) {
            if (self._curentLine.firstInlineToken()) |t| {
                self._currentToken = t;
                return t;
            }
            if (self._curentLine == self._endLine) {
                self._currentToken = null;
                return null;
            }
            if (self._curentLine.next()) |nextLine| self._curentLine = nextLine else unreachable;
        }
    }
};

// Both lines are inclusive.
// The returned value can be reused but can't be used concurrently.
fn inlineTokensBetweenLines(startLine: *const Line, endLine: *const Line) InlineTokenIterator {
    return InlineTokenIterator{
        ._startLine = startLine,
        ._endLine = endLine,
        ._curentLine = undefined,
    };
}

// Tokens consume most memory after a doc is parsed.
// So try to keep the size of TokenType small and use as few tokens as possible.
//
// Try to keep the size of each TokenType field <= (4 + 4 + NativeWordSize) bytes.
//
// It is possible to make size of TokenType be 8 on 32-bit systems? (By discarding
// the .start property of each TokenType).
//
// Now, even all the fields of a union type reserved enough bits for the union tag,
// the compiler will still use extra alignment bytes for the union tag.
// So the size of TokenType is 24 bytes now.
// Maybe future zig compiler will make optimization to reduce the size to 16 bytes.
//
// An unmature idea is to add an extra enum field which only use
// the reserved bits to emulate the union tag manually.
// I'm nore sure how safe this way is now.
//
//     tag: struct {
//        _: uN,
//        _type: enum(uM) { // M == 16*8 - N
//            plainText,
//            evenBackticks,
//            ...
//        },
//     },
//     plainText: ...,
//     evenBackticks: ...,

pub const Token = union(enum) {
    // Same results as using std.meta.TagPayload(Token, .XXX)
    pub const PlainText = @FieldType(Token, "plainText");
    pub const EvenBackticks = @FieldType(Token, "evenBackticks");
    pub const SpanMark = @FieldType(Token, "spanMark");
    pub const LinkInfo = @FieldType(Token, "linkInfo");
    pub const LeadingSpanMark = @FieldType(Token, "leadingSpanMark");
    pub const ContainerMark = @FieldType(Token, "containerMark");
    pub const LineTypeMark = @FieldType(Token, "lineTypeMark");
    pub const Extra = @FieldType(Token, "extra");

    plainText: struct {
        start: DocSize,

        more: packed struct {
            // (start+textLen) should be the same as the start of the next token, or end of line.
            // But it is good to keep it here, to verify the this value is the same as ....
            textLen: DocSize,

            undisplayed: bool = false,
            followedByLineEndSpaceInLink: bool = false,
        },

        // The last one might be a URL source of a self-defined link.
        // Might be .plainText or .evenBackticks.
        nextInLink: ?*Token = null,
    },
    evenBackticks: struct {
        // `` means a void char.
        // ```` means (pairCount-1) non-collapsable spaces?
        // ^```` means pairCount ` chars.

        start: DocSize,
        more: packed struct {
            pairCount: DocSize,
            secondary: bool,

            followedByLineEndSpaceInLink: bool = false,

            comptime {
                std.debug.assert(@sizeOf(@This()) <= @sizeOf(u32));
            }
        },

        // The last one might be a URL source of a self-defined link.
        // Might be plainText or evenBackticks.
        nextInLink: ?*Token = null,
    },
    spanMark: struct {
        // For a close mark, this might be the start of the attached blanks.
        // For a open mark, this might be the position of the secondary sign.
        start: DocSize,
        blankLen: DocSize, // blank char count after open-mark or before close-mark in a line.

        markType: SpanMarkType, // might
        markLen: u8, // without the secondary char

        more: packed struct {
            open: bool,
            secondary: bool = false,
            // Enclose no texts (contents or evenBackticks or treatEndAsSpace).
            // The value should be equal to the corresponding open/close mark.
            // The value is for render optimization purpose, to skip rendering
            // some blank mark spans.
            // Note that, even if this value is true, void (``) and some collapsed
            // spaces and link urls will not get rendered.
            blankSpan: bool, // no contents in the span?
            // For hyperlink spans, to distinguish footnote link and fragment link.
            containsOtherSpanMarks: bool = false,
        },

        pub fn typeName(self: @This()) []const u8 {
            return @tagName(self.markType);
        }
    },
    // A linkInfo token is always before an open .hyperlink SpanMarkType token.
    // It is used to track the Link in rendering.
    linkInfo: struct {
        link: *Link,

        // It is the prev token.
        // openHyperlinkSpanMark: ?*SpanMark = null,
    },
    leadingSpanMark: struct {
        start: DocSize,
        blankLen: DocSize, // blank char count after the mark.
        more: packed struct {
            markLen: u2, // ToDo: remove it? It must be 2 now.
            markType: LineSpanMarkType,

            isBare: bool = false,
        },

        pub fn typeName(self: @This()) []const u8 {
            return @tagName(self.more.markType);
        }
    },
    containerMark: struct {
        start: DocSize,
        blankLen: DocSize,
        more: packed struct {
            markLen: u2,
            //markType: ContainerType, // can be determined by the start char
        },
    },
    lineTypeMark: struct { // excluding container marks
        start: DocSize,
        blankLen: DocSize,
        markLen: DocSize,

        // For containing line with certain line types,
        // an .extra token is followed by this .lineTypeMark token.
        // ToDo: let .extra token follow this? So that .extra_or_others
        //       will not needed any more.
    },
    extra: struct {
        pub const Info = @FieldType(@This(), "info");

        info: packed union {
            // followed by a .lineTypeMark token in a .baseBlockClose line
            blockRef: ?*Block,
            // followed by a .lineTypeMark token in a .baseBlockOpen line
            baseBlockAttrs: ?*BaseBlockAttibutes,
            // followed by a .lineTypeMark token in a .codeBlockStart line
            codeBlockAttrs: ?*CodeBlockAttibutes,
            // followed by a .lineTypeMark token in a .codeBlockEnd line
            streamAttrs: ?*ContentStreamAttributes,
            // followed by a .lineTypeMark token in a .customBlockStart line
            customBlockAttrs: ?*CustomBlockAttibutes,
        },
    },

    pub fn typeName(self: @This()) []const u8 {
        return @tagName(self);
    }

    pub fn range(self: *const @This()) Range {
        return .{ .start = self.start(), .end = self.end() };
    }

    pub fn start(self: *const @This()) DocSize {
        switch (self.*) {
            .linkInfo => {
                if (self.prev()) |prexToken| {
                    if (builtin.mode == .Debug) {
                        switch (prexToken.*) {
                            .spanMark => |m| std.debug.assert(m.markType == .hyperlink and m.more.open == true),
                            .leadingSpanMark => |m| std.debug.assert(m.more.markType == .media),
                            else => unreachable,
                        }
                    }
                    return prexToken.end();
                } else unreachable;
            },
            .extra => {
                if (self.next()) |nextToken| {
                    if (builtin.mode == .Debug) {
                        std.debug.assert(nextToken.* == .lineTypeMark);
                    }
                    return nextToken.start();
                } else unreachable;
            },
            inline else => |token| {
                return token.start;
            },
        }
    }

    pub fn end(self: *const @This()) DocSize {
        switch (self.*) {
            .plainText => |t| {
                return t.start + t.more.textLen;
            },
            .evenBackticks => |s| {
                var e = self.start() + (s.more.pairCount << 1);
                if (s.more.secondary) e += 1;
                return e;
            },
            .spanMark => |m| {
                var e = self.start() + m.markLen + m.blankLen;
                if (m.more.secondary) e += 1;
                return e;
            },
            .linkInfo, .extra => {
                return self.start();
            },
            inline .leadingSpanMark, .containerMark => |m| {
                return self.start() + m.more.markLen + m.blankLen;
            },
            .lineTypeMark => |m| {
                return self.start() + m.markLen + m.blankLen;
            },
        }
    }

    // Debug purpose. Used to verify end() == end2(line).
    pub fn end2(self: *@This(), _: *const Line) DocSize {
        if (self.next()) |nextToken| {
            return nextToken.start();
        }
        // The old implementation.
        // ToDo: now, the assumption is false for some lines with playload.
        // return line.suffixBlankStart;
        // The current temp implementation.
        return self.end();
    }

    const List = list.List(@This());

    // ToDo: if self is const, return const. Possible?
    pub fn next(self: *const @This()) ?*const Token {
        const tokenElement: *const Token.List.Element = @alignCast(@fieldParentPtr("value", self));
        if (tokenElement.next) |te| {
            return &te.value;
        }
        return null;
    }

    pub fn prev(self: *const @This()) ?*const Token {
        const tokenElement: *const Token.List.Element = @alignCast(@fieldParentPtr("value", self));
        if (tokenElement.prev) |te| {
            return &te.value;
        }
        return null;
    }

    pub fn nextContentTokenInLink(self: *const @This()) ?*const Token {
        return switch (self.*) {
            inline .plainText, .evenBackticks => |t| t.nextInLink,
            else => unreachable,
        };
    }

    pub fn followedByLineEndSpaceInLink(self: *const @This()) bool {
        return switch (self.*) {
            inline .plainText, .evenBackticks => |t| t.more.followedByLineEndSpaceInLink,
            else => unreachable,
        };
    }

    pub fn isVoid(self: *const @This()) bool {
        return switch (self.*) {
            .evenBackticks => |t| !t.more.secondary and t.more.pairCount == 1,
            else => false,
        };
    }

    //pub fn isBlankSpanMark(self: *const @This()) bool {
    //    return switch (self.*) {
    //        .spanMark => |t| t.more.blankSpan,
    //        else => false,
    //    };
    //}
};

pub const SpanMarkType = enum(u4) {
    hyperlink,
    fontWeight,
    fontStyle,
    fontSize,
    deleted,
    marked,
    supsub,
    code, // must be the last one (why? forget the reason)

    pub const MarkCount = @typeInfo(@This()).@"enum".fields.len;

    pub fn asInt(self: @This()) u8 {
        return @intFromEnum(self);
    }

    pub fn typeName(self: @This()) []const u8 {
        return @tagName(self);
    }
};

// used in usual blocks:
pub const LineSpanMarkType = enum(u3) {
    lineBreak, // \\
    undisplayed, // %% (called comment before)
    media, // &&
    escape, // !!
    spoiler, // ??
};
