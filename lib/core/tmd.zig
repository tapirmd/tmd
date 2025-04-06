//! This module provides functions for parse tmd files (as Doc),
//! and functions for rendering (Doc) to HTML.

pub const version = @import("version.zig").version;

pub const exampleCSS = @embedFile("example.css");

pub const GenOptions = @import("doc_to_html.zig").Options;
pub const htmlCustomDefaultGenFn = @import("doc_to_html.zig").htmlCustomGenFn;

const std = @import("std");
const builtin = @import("builtin");
const list = @import("list.zig");
const tree = @import("tree.zig");

pub const Doc = struct {
    allocator: std.mem.Allocator = undefined,

    data: []const u8,
    blocks: list.List(Block) = .{},
    lines: list.List(Line) = .{},
    blockCount: u32 = 0,
    lineCount: u32 = 0,

    tocHeaders: list.List(*Block) = .{},
    titleHeader: ?*Block = null,
    // User should use the headerLevelNeedAdjusted method instead.
    _headerLevelNeedAdjusted: [MaxHeaderLevel]bool = .{false} ** MaxHeaderLevel,

    blocksByID: BlockRedBlack.Tree = .{}, // ToDo: use PatriciaTree to get a better performance

    // The followings are used to track allocations for destroying.
    // ToDo: prefix them with _?

    links: list.List(Link) = .{}, // ToDo: use Link.next
    _blockTreeNodes: list.List(BlockRedBlack.Node) = .{}, // ToDo: use SinglyLinkedList
    // It is in _blockTreeNodes when exists. So no need to destroy it solely in the end.
    _freeBlockTreeNodeElement: ?*list.Element(BlockRedBlack.Node) = null,
    _elementAttributes: list.List(ElementAttibutes) = .{}, // ToDo: use SinglyLinkedList
    _baseBlockAttibutes: list.List(BaseBlockAttibutes) = .{}, // ToDo: use SinglyLinkedList
    _codeBlockAttibutes: list.List(CodeBlockAttibutes) = .{}, // ToDo: use SinglyLinkedList
    _customBlockAttibutes: list.List(CustomBlockAttibutes) = .{}, // ToDo: use SinglyLinkedList
    _contentStreamAttributes: list.List(ContentStreamAttributes) = .{}, // ToDo: use SinglyLinkedList

    const BlockRedBlack = tree.RedBlack(*Block, Block);

    pub fn parse(tmdData: []const u8, allocator: std.mem.Allocator) !Doc {
        return try @import("tmd_to_doc.zig").parse_tmd(tmdData, allocator, true);
    }

    pub fn destroy(doc: *Doc) void {
        list.destroyListElements(Block, doc.blocks, null, doc.allocator);

        const T = struct {
            fn destroyLineTokens(line: *Line, a: std.mem.Allocator) void {
                //if (line.tokens()) |tokens| {
                //    list.destroyListElements(Token, tokens.*, null, a);
                //}
                list.destroyListElements(Token, line.tokens, null, a);
            }
        };

        list.destroyListElements(Line, doc.lines, T.destroyLineTokens, doc.allocator);

        list.destroyListElements(ElementAttibutes, doc._elementAttributes, null, doc.allocator);
        list.destroyListElements(BaseBlockAttibutes, doc._baseBlockAttibutes, null, doc.allocator);
        list.destroyListElements(CodeBlockAttibutes, doc._codeBlockAttibutes, null, doc.allocator);
        list.destroyListElements(CustomBlockAttibutes, doc._customBlockAttibutes, null, doc.allocator);
        list.destroyListElements(ContentStreamAttributes, doc._contentStreamAttributes, null, doc.allocator);

        list.destroyListElements(BlockRedBlack.Node, doc._blockTreeNodes, null, doc.allocator);

        list.destroyListElements(Link, doc.links, null, doc.allocator);
        list.destroyListElements(*Block, doc.tocHeaders, null, doc.allocator);

        doc.* = .{ .data = "" };
    }

    pub fn writePageTitle(doc: *const Doc, writer: anytype) !bool {
        return try @import("doc_to_html.zig").write_doc_title(writer, doc);
    }

    pub fn writeHTML(doc: *const Doc, writer: anytype, genOptions: GenOptions, allocator: std.mem.Allocator) !void {
        try @import("doc_to_html.zig").doc_to_html(writer, doc, genOptions, allocator);
    }

    pub fn writeTMD(doc: *const Doc, writer: anytype, comptime format: bool) !void {
        try @import("doc_to_tmd.zig").doc_to_tmd(writer, doc, format);
    }

    // A doc always has a root block. And the root
    // block is always the first block of the doc.
    pub fn rootBlock(doc: *const @This()) *const Block {
        return if (doc.blocks.head) |head| {
            std.debug.assert(head.value.blockType == .root);
            return &head.value;
        } else unreachable;
    }

    pub fn blockByID(self: *const @This(), id: []const u8) ?*Block {
        var a = ElementAttibutes{
            .id = id,
        };
        var b = Block{
            .blockType = undefined,
            .attributes = &a,
        };

        return if (self.blocksByID.search(&b)) |node| node.value else null;
    }

    pub fn firstLine(self: *const @This()) ?*Line {
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

    pub fn isForFootnote(self: *const @This()) bool {
        return self.id.len > 0 and self.id[0] == '^';
    }
};

pub const Link = struct {
    // ToDo: use pointer? Memory will be more fragmental.
    // ToDo: now this field is never set.
    // attrs: ElementAttibutes = .{},

    info: *Token.LinkInfo,
};

pub const BaseBlockAttibutes = struct {
    commentedOut: bool = false, // ToDo: use Range
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
    commentedOut: bool = false, // ToDo: use Range
    language: []const u8 = "", // ToDo: use Range
    // ToDo
    // startLineNumber: u32 = 0, // +n, +0 means not show line numbers
    // filepath: []const u8 = "", // @path
};

pub const ContentStreamAttributes = struct {
    content: []const u8 = "", // ToDo: use Range
};

pub const CustomBlockAttibutes = struct {
    commentedOut: bool = false, // ToDo: use Range
    app: []const u8 = "", // ToDo: use Range
    //arguments: []const u8 = "", // ToDo: use Range. Should be [][]const u8? Bad idea, try to keep lib smaller.
    // The argument is the content in the following custom block.
    // It might be a file path.
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

    blockType: BlockType,

    attributes: ?*ElementAttibutes = null,

    more: packed struct {
        // for .usual atom blocks only
        hasNonMediaTokens: bool = false,
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

    pub fn startLine(self: *const @This()) *Line {
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

    pub fn endLine(self: *const @This()) *Line {
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
    pub fn footerAttibutes(self: *const @This()) ?*ElementAttibutes {
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

    pub fn ownerListElement(self: *const @This()) *list.Element(@This()) {
        return @alignCast(@fieldParentPtr("value", @constCast(self)));
    }

    pub fn next(self: *const @This()) ?*Block {
        return &(self.ownerListElement().next orelse return null).value;
    }

    pub fn prev(self: *const @This()) ?*Block {
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

    pub fn nextSibling(self: *const @This()) ?*Block {
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
            inline .table, .quotation, .notice, .reveal, .plain => |container| blk: {
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
            inline .item, .table, .quotation, .notice, .reveal, .plain => |*container| {
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
    pub const Custom = std.meta.FieldType(BlockType, .custom);
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

        pub fn ownerBlock(self: *const @This()) *Block {
            const blockType: *BlockType = @alignCast(@fieldParentPtr("item", @constCast(self)));
            return blockType.ownerBlock();
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
    notice: struct {
        const Container = void;
        nextSibling: ?*Block = null,
    },
    reveal: struct {
        const Container = void;
        nextSibling: ?*Block = null,
    },
    plain: struct {
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

        pub fn _contentStreamAttributes(self: @This()) ContentStreamAttributes {
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

    pub fn ownerBlock(self: *const @This()) *Block {
        return @alignCast(@fieldParentPtr("blockType", @constCast(self)));
    }
};

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

    lineType: Type = undefined,

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

    pub fn ownerListElement(self: *const @This()) *list.Element(@This()) {
        return @alignCast(@fieldParentPtr("value", @constCast(self)));
    }

    pub fn next(self: *const @This()) ?*Line {
        return &(self.ownerListElement().next orelse return null).value;
    }

    pub fn prev(self: *const @This()) ?*Line {
        return &(self.ownerListElement().prev orelse return null).value;
    }

    pub fn containerMarkToken(self: *const @This()) ?*Token {
        if (self.firstTokenOf(.containerMark_or_others)) |token| {
            if (token.* == .containerMark) return token;
        }
        return null;
    }

    pub fn lineTypeMarkToken(self: *const @This()) ?*Token {
        if (self.firstTokenOf(.lineTypeMark_or_others)) |token| {
            if (token.* == .lineTypeMark) return token;
        }
        return null;
    }

    pub fn extraInfo(self: *const @This()) ?*Token.Extra.Info {
        if (self.firstTokenOf(.extra_or_others)) |token| {
            if (token.* == .extra) {
                std.debug.assert(token.next().?.* == .lineTypeMark);
                return &token.extra.info;
            }
        }
        return null;
    }

    pub fn firstInlineToken(self: *const @This()) ?*Token {
        return self.firstTokenOf(.others);
    }

    // Currently, .others means inline style or content tokens.
    pub fn firstTokenOf(self: *const @This(), tokenKind: enum { any, containerMark_or_others, extra_or_others, lineTypeMark_or_others, others }) ?*Token {
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
//            content,
//            commentText,
//            ...
//        },
//     },
//     content: ...,
//     commentText: ...,

pub const Token = union(enum) {
    pub const PlainText = std.meta.FieldType(Token, .content);
    pub const CommentText = std.meta.FieldType(Token, .commentText);
    pub const EvenBackticks = std.meta.FieldType(Token, .evenBackticks);
    pub const SpanMark = std.meta.FieldType(Token, .spanMark);
    pub const LinkInfo = std.meta.FieldType(Token, .linkInfo);
    pub const LeadingSpanMark = std.meta.FieldType(Token, .leadingSpanMark);
    pub const ContainerMark = std.meta.FieldType(Token, .containerMark);
    pub const LineTypeMark = std.meta.FieldType(Token, .lineTypeMark);
    pub const Extra = std.meta.FieldType(Token, .extra);

    content: struct {
        start: DocSize,
        // The value should be the same as the start of the next token, or end of line.
        // But it is good to keep it here, to verify the this value is the same as ....
        end: DocSize,

        // Finally, the list will exclude the last one if
        // it is only used for self-defined URL.
        nextInLink: ?*Token = null,
    },
    commentText: struct {
        start: DocSize,
        // The value should be the same as the end of line.
        end: DocSize,

        inAttributesLine: bool, // ToDo: don't use commentText tokens for attributes lines.
    },
    // ToDo: follow a .media LineSpanMarkType.
    //mediaInfo: struct {
    //    attrs: *MediaAttributes,
    //},
    evenBackticks: struct {
        start: DocSize,
        pairCount: DocSize,
        more: packed struct {
            secondary: bool,
        },

        // `` means a void char.
        // ```` means (pairCount-1) non-collapsable spaces?
        // ^```` means pairCount ` chars.
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
            blankSpan: bool, // enclose no texts (contents or evenBackticks or treatEndAsSpace)

            inComment: bool, // for .linkInfo
            urlSourceSet: bool = false, // for .linkInfo
            urlConfirmed: bool = false, // for .linkInfo
            isFootnote: bool = false, // for .linkInfo
        },

        pub fn typeName(self: @This()) []const u8 {
            return @tagName(self.markType);
        }
    },
    // A linkInfo token is always before an open .link SpanMarkType token.
    linkInfo: struct {
        info: packed union {
            // This is only used for link matching.
            firstPlainText: ?*Token, // null for a blank link span

            // This is a list, it is the head.
            // Surely, if urlConfirmed, it is the only one in the list.
            urlSourceText: ?*Token, // null for a blank link span
        },

        fn followingOpenLinkSpanMark(self: *const @This()) *SpanMark {
            const token: *const Token = @alignCast(@fieldParentPtr("linkInfo", self));
            const m = token.followingSpanMark();
            std.debug.assert(m.markType == .link and m.more.open == true);
            return m;
        }

        pub fn isFootnote(self: *const @This()) bool {
            return self.followingOpenLinkSpanMark().more.isFootnote;
        }

        pub fn setFootnote(self: *const @This(), is: bool) void {
            self.followingOpenLinkSpanMark().more.isFootnote = is;
        }

        pub fn inComment(self: *const @This()) bool {
            return self.followingOpenLinkSpanMark().more.inComment;
        }

        pub fn urlConfirmed(self: *const @This()) bool {
            return self.followingOpenLinkSpanMark().more.urlConfirmed;
        }

        pub fn urlSourceSet(self: *const @This()) bool {
            return self.followingOpenLinkSpanMark().more.urlSourceSet;
        }

        pub fn setSourceOfURL(self: *@This(), urlSource: ?*Token, confirmed: bool) void {
            std.debug.assert(!self.urlSourceSet());

            self.followingOpenLinkSpanMark().more.urlConfirmed = confirmed;
            self.info = .{
                .urlSourceText = urlSource,
            };

            self.followingOpenLinkSpanMark().more.urlSourceSet = true;
        }
    },
    leadingSpanMark: struct {
        start: DocSize,
        blankLen: DocSize, // blank char count after the mark.
        more: packed struct {
            markLen: u2, // ToDo: remove it? It must be 2 now.
            markType: LineSpanMarkType,

            // when isBare is false,
            // * for .media, the next token is a .content token.
            // * for .comment and .anchor, the next token is a .commentText token.
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

        // For containing line with certain lien types,
        // an extra token is followed by this .lineTypeMark token.
    },
    extra: struct {
        pub const Info = std.meta.FieldType(@This(), .info);

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
                if (self.next()) |nextToken| {
                    if (builtin.mode == .Debug) {
                        std.debug.assert(nextToken.* == .spanMark);
                        const m = nextToken.spanMark;
                        std.debug.assert(m.markType == .link and m.more.open == true);
                    }
                    return nextToken.start();
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
            .commentText => |t| {
                return t.end;
            },
            .content => |t| {
                return t.end;
            },
            .evenBackticks => |s| {
                var e = self.start() + (s.pairCount << 1);
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
    pub fn end2(self: *@This(), _: *Line) DocSize {
        if (self.next()) |nextToken| {
            return nextToken.start();
        }
        // The old implementation.
        // ToDo: now, the assumption is false for some lines with playload.
        // return line.suffixBlankStart;
        // The current temp implementation.
        return self.end();
    }

    // ToDo: if self is const, return const. Possible?
    pub fn next(self: *const @This()) ?*Token {
        const tokenElement: *const list.Element(Token) = @alignCast(@fieldParentPtr("value", self));
        if (tokenElement.next) |te| {
            return &te.value;
        }
        return null;
    }

    pub fn prev(self: *const @This()) ?*Token {
        const tokenElement: *const list.Element(Token) = @alignCast(@fieldParentPtr("value", self));
        if (tokenElement.prev) |te| {
            return &te.value;
        }
        return null;
    }

    fn followingSpanMark(self: *const @This()) *SpanMark {
        if (self.next()) |nextToken| {
            switch (nextToken.*) {
                .spanMark => |*m| {
                    return m;
                },
                else => unreachable,
            }
        } else unreachable;
    }
};

pub const SpanMarkType = enum(u4) {
    link,
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
    comment, // //
    media, // &&
    escape, // !!
    spoiler, // ??
};
