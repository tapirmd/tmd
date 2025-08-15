const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd.zig");
const list = @import("list.zig");
const tree = @import("tree.zig");
const LineScanner = @import("tmd_to_doc-line_scanner.zig");
const AttributeParser = @import("tmd_to_doc-attribute_parser.zig");
const fns = @import("doc_to_html-fns.zig");

const FootnoteRedBlack = tree.RedBlack(*Footnote, Footnote);
const Footnote = struct {
    id: []const u8,
    orderIndex: u32 = undefined,
    refCount: u32 = undefined,
    refWrittenCount: u32 = undefined,
    block: ?*tmd.Block = undefined,

    pub fn compare(x: *const @This(), y: *const @This()) isize {
        return switch (std.mem.order(u8, x.id, y.id)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
    }
};

const TabListInfo = struct {
    orderId: u32,
    nextItemOrderId: u32 = 0,
};

pub const GenOptions = struct {
    renderRoot: bool = true,
    identSuffix: []const u8 = "", // for forum posts etc. To avoid id duplications.
    autoIdentSuffix: []const u8 = "", // to avoid some auto id duplication. Should only be used when identPrefix is blank.
    
    // more render switches
    // enabled_style_xxx: bool,
    // ignoreClasses: bool = false, // for forum posts etc.

    getCustomBlockGenCallback: ?*const fn (doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) ?GenCallback = null,
    // ToDo: codeBlockGenCallback, and for any kinds of blocks?

    //mediaUrlValidateFn: ?*const fn([]const u8) ?[]const u8 = null,
    //linkUrlValidateFn: ?*const fn(*tmd.Link) ?[]const u8 = null,
};

pub const GenCallback = struct {
  obj: *const anyopaque,
  writeFn: *const fn (obj: *const anyopaque, aw: std.io.AnyWriter) anyerror!void,

  pub fn write(self: GenCallback, aw: std.io.AnyWriter) !void {
    return self.writeFn(self.obj, aw);
  }

  pub fn init(obj: anytype) GenCallback {
    const T = @TypeOf(obj);
    const typeInfo = @typeInfo(T);
    switch (typeInfo) {
        .pointer => |pointer| {
            const C = struct {
                pub fn write(v: *const anyopaque, aw: std.io.AnyWriter) !void {
                    const Base = pointer.child;
                    const ptr: *const Base = @ptrCast(@alignCast(v));
                    return try Base.write(ptr, aw);
                }
            };
            return .{ .obj = obj, .writeFn = C.write };
        },
        inline .@"struct", .@"union", .@"enum" => |_, tag| {
            if (@sizeOf(T) != 0) @compileError(@tagName(tag) ++ " types must a zero size.");
            
            const C = struct {
                pub fn write(_: *const anyopaque, aw: std.io.AnyWriter) !void {
                    return try T.write(T{}, aw);
                }
            };
            return .{ .obj = undefined, .writeFn = C.write };
        },
        inline else => |_, tag| @compileError(@tagName(tag) ++ " types are unsupported."),
    }
  }
  
  pub fn dummy() GenCallback {
    const GenCallback_Dummy = struct {
        pub fn write(_: @This(), _: std.io.AnyWriter) !void {}
    };
    
    return .init(GenCallback_Dummy{});
  }
};

const dummyGenCallback: GenCallback = .dummy();

pub const TmdRender = struct {
    doc: *const tmd.Doc,

    allocator: std.mem.Allocator,

    options: GenOptions,

    // intermediate render-time data

    toRenderSubtitles: bool = false,
    incFootnoteRefCounts: bool = true,
    incFootnoteRefWrittenCounts: bool = true,

    tabListInfos: [tmd.MaxBlockNestingDepth]TabListInfo = undefined,
    currentTabListDepth: i32 = -1,
    nextTabListOrderId: u32 = 0,

    footnotesByID: FootnoteRedBlack.Tree = .{}, // ToDo: use PatriciaTree to get a better performance
    footnoteNodes: list.List(FootnoteRedBlack.Node) = .{}, // for destroying

    pub fn init(doc: *const tmd.Doc, allocator: std.mem.Allocator, options: GenOptions) TmdRender {
        var r = TmdRender {
            .doc = doc,
            .allocator = allocator,
            .options = options,
        };

        if (options.autoIdentSuffix.len == 0) r.options.autoIdentSuffix = options.identSuffix;

        return r;
    }

    // ToDo: rename to destroy?
    fn cleanup(self: *TmdRender) void {
        const T = struct {
            fn destroyFootnoteNode(node: *FootnoteRedBlack.Node, a: std.mem.Allocator) void {
                a.destroy(node.value);
            }
        };
        list.destroyListElements(FootnoteRedBlack.Node, self.footnoteNodes, T.destroyFootnoteNode, self.allocator);
    }

    fn getCustomBlockGenCallback(self: *const TmdRender, custom: *const tmd.BlockType.Custom) GenCallback {
        if (self.options.getCustomBlockGenCallback) |get| {
            if (get(self.doc, custom)) |callback| return callback;
        }

        return dummyGenCallback;
    }

    fn onFootnoteReference(self: *TmdRender, id: []const u8) !*Footnote {
        var footnote = @constCast(&Footnote{
            .id = id,
        });
        if (self.footnotesByID.search(footnote)) |node| {
            footnote = node.value;
            if (self.incFootnoteRefCounts) footnote.refCount += 1;
            return footnote;
        }

        std.debug.assert(self.incFootnoteRefCounts);

        footnote = try self.allocator.create(Footnote);
        footnote.* = .{
            .id = id,
            .orderIndex = @intCast(self.footnotesByID.count + 1),
            .refCount = 1,
            .refWrittenCount = 0,
            .block = self.doc.blockByID(id),
        };

        const nodeElement = try list.createListElement(FootnoteRedBlack.Node, self.allocator);
        self.footnoteNodes.pushTail(nodeElement);

        const node = &nodeElement.value;
        node.value = footnote;
        std.debug.assert(node == self.footnotesByID.insert(node));

        return footnote;
    }

    pub fn writeTitleInHtmlHeader(self: *TmdRender, w: anytype) !bool {
        if (self.doc.titleHeader) |titleHeader| {
            try self.writeUsualContentBlockLinesFornoStyling(w, titleHeader);
            return true;
        } else {
            try w.writeAll("");
            return false;
        }
    }

    pub fn render(self: *TmdRender, w: anytype) !void {
        defer self.cleanup();

        var nilFootnoteTreeNode = FootnoteRedBlack.Node{
            .color = .black,
            .value = undefined,
        };
        self.footnotesByID.init(&nilFootnoteTreeNode);

        const rootBlock = self.doc.rootBlock();
        if (self.options.renderRoot) {
            try self.renderBlock(w, rootBlock); // will call writeFootnotes
        } else {
            try self.renderBlockChildren(w, rootBlock.firstChild());
            try self.writeFootnotes(w);
        }
    }

    fn renderBlock(self: *TmdRender, w: anytype, block: *const tmd.Block) anyerror!void {
        const footerTag = if (block.footerAttibutes()) |footerAttrs| blk: {
            const tag = "footer";
            const classes = "tmd-footer";

            try fns.writeOpenTag(w, tag, classes, footerAttrs, self.options.identSuffix, true);
            break :blk tag;
        } else "";

        handle: switch (block.blockType) {
            // base blocks

            .root => {
                const tag = "div";
                const classes = "tmd-doc";

                try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);
                try self.renderBlockChildren(w, block.firstChild());
                try self.writeFootnotes(w);
                try fns.writeCloseTag(w, tag, true);
            },
            .base => |*base| {
                const attrs = base.attributes();
                if (attrs.commentedOut) break :handle;

                const tag = "div";
                const classes = switch (attrs.horizontalAlign) {
                    .none => "tmd-base",
                    .left => "tmd-base tmd-align-left",
                    .center => "tmd-base tmd-align-center",
                    .justify => "tmd-base tmd-align-justify",
                    .right => "tmd-base tmd-align-right",
                };

                try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);
                try self.renderBlockChildren(w, block.firstChild());
                try fns.writeCloseTag(w, tag, true);
            },

            // built-in blocks

            .list => |*itemList| {
                switch (itemList.listType) {
                    .bullets => {
                        const tag = if (itemList.secondMode) "ol" else "ul";
                        const classes = "tmd-list";

                        try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);
                        try self.renderBlockChildren(w, block.firstChild());
                        try fns.writeCloseTag(w, tag, true);
                    },
                    .definitions => {
                        const tag = "dl";
                        const classes = if (itemList.secondMode) "tmd-list tmd-defs-oneline" else "tmd-list tmd-defs";

                        try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);
                        try self.renderBlockChildren(w, block.firstChild());
                        try fns.writeCloseTag(w, tag, true);
                    },
                    .tabs => {
                        const tag = "div";
                        const classes = "tmd-tab";

                        try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);

                        {
                            const orderId = self.nextTabListOrderId;
                            self.nextTabListOrderId += 1;

                            std.debug.assert(self.currentTabListDepth >= -1 and self.currentTabListDepth < tmd.MaxBlockNestingDepth);
                            self.currentTabListDepth += 1;
                            self.tabListInfos[@intCast(self.currentTabListDepth)] = TabListInfo{
                                .orderId = orderId,
                            };
                        }

                        try self.renderBlockChildren(w, block.firstChild());
                        try fns.writeCloseTag(w, tag, true);

                        {
                            std.debug.assert(self.currentTabListDepth >= 0 and self.currentTabListDepth < tmd.MaxBlockNestingDepth);
                            self.currentTabListDepth -= 1;
                        }
                    },
                }
            },

            // NOTE: can't be |listItem|, which makes @fieldParentPtr return wrong pointer (to a temp value on stack?).
            .item => |*listItem| {
                std.debug.assert(block.attributes == null); // ToDo: support item attributes?

                switch (listItem.list.blockType.list.listType) {
                    .bullets => {
                        const tag = "li";
                        const classes = "tmd-list-item";

                        try fns.writeOpenTag(w, tag, classes, null, self.options.identSuffix, true);
                        try self.renderBlockChildren(w, block.firstChild());
                        try fns.writeCloseTag(w, tag, true);
                    },
                    .definitions => {
                        const forDdBlock = if (block.specialHeaderChild(self.doc.data)) |headerBlock| blk: {
                            const tag = "dt";
                            const classes = "";

                            try fns.writeOpenTag(w, tag, classes, headerBlock.attributes, self.options.identSuffix, true);
                            try self.writeUsualContentBlockLines(w, headerBlock);
                            try fns.writeCloseTag(w, tag, true);

                            break :blk headerBlock.nextSibling();
                        } else block.firstChild();

                        const tag = "dd";
                        const classes = "";

                        try fns.writeOpenTag(w, tag, classes, null, self.options.identSuffix, true);
                        try self.renderBlockChildren(w, forDdBlock);
                        try fns.writeCloseTag(w, tag, true);
                    },
                    .tabs => {
                        std.debug.assert(self.currentTabListDepth >= 0 and self.currentTabListDepth < tmd.MaxBlockNestingDepth);
                        //self.tabListInfos[@intCast(self.currentTabListDepth)].nextItemOrderId += 1;
                        const tabInfo = &self.tabListInfos[@intCast(self.currentTabListDepth)];
                        tabInfo.nextItemOrderId += 1;

                        try w.print(
                            \\<input type="radio" class="tmd-tab-radio" name="tmd-tab-{d}{s}" id="tmd-tab-{d}-input-{d}{s}"
                        ,
                            .{ tabInfo.orderId, self.options.autoIdentSuffix, tabInfo.orderId, tabInfo.nextItemOrderId, self.options.autoIdentSuffix },
                        );

                        if (listItem.isFirst()) try w.writeAll(" checked");
                        try w.writeAll(">\n");

                        const headerTag = "label";
                        const headerClasses = "tmd-tab-header tmd-tab-label";
                        try w.print(
                            \\<{s} for="tmd-tab-{d}-input-{d}{s}"
                        ,
                            .{ headerTag, tabInfo.orderId, tabInfo.nextItemOrderId, self.options.autoIdentSuffix },
                        );

                        const firstContentBlock = if (block.specialHeaderChild(self.doc.data)) |headerBlock| blk: {
                            try fns.writeBlockAttributes(w, headerClasses, headerBlock.attributes, self.options.identSuffix);
                            try w.writeAll(">\n");

                            if (listItem.list.blockType.list.secondMode) {
                                try w.print("{d}. ", .{tabInfo.nextItemOrderId});
                            }
                            try self.writeUsualContentBlockLines(w, headerBlock);

                            break :blk headerBlock.nextSibling();
                        } else blk: {
                            try fns.writeBlockAttributes(w, headerClasses, null, self.options.identSuffix);
                            try w.writeAll(">\n");

                            if (listItem.list.blockType.list.secondMode) {
                                try w.print("{d}. ", .{tabInfo.nextItemOrderId});
                            }

                            break :blk block.firstChild();
                        };
                        try fns.writeCloseTag(w, headerTag, true);

                        const tag = "div";
                        const classes = "tmd-tab-content";

                        try fns.writeOpenTag(w, tag, classes, null, self.options.identSuffix, true);

                        try self.renderBlockChildren(w, firstContentBlock);
                        try fns.writeCloseTag(w, tag, true);
                    },
                }
            },
            .table => {
                try self.renderTableBlock(w, block);
            },
            .quotation => {
                const tag = "div";

                const firstContentBlock = if (block.specialHeaderChild(self.doc.data)) |headerBlock| blk: {
                    const classes = "tmd-quotation-large";
                    try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);

                    {
                        const headerTag = "div";
                        const headerClasses = "tmd-usual";

                        try fns.writeOpenTag(w, tag, headerClasses, headerBlock.attributes, self.options.identSuffix, true);
                        try self.writeUsualContentBlockLines(w, headerBlock);
                        try fns.writeCloseTag(w, headerTag, true);
                    }

                    break :blk headerBlock.nextSibling();
                } else blk: {
                    const classes = "tmd-quotation";
                    try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);

                    break :blk block.firstChild();
                };

                try self.renderBlockChildren(w, firstContentBlock);
                try fns.writeCloseTag(w, tag, true);
            },
            .notice => {
                const tag = "div";
                const classes = "tmd-notice";

                try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);

                const firstContentBlock = if (block.specialHeaderChild(self.doc.data)) |headerBlock| blk: {
                    {
                        const headerTag = "div";
                        const headerClasses = "tmd-notice-header";

                        try fns.writeOpenTag(w, tag, headerClasses, headerBlock.attributes, self.options.identSuffix, true);
                        try self.writeUsualContentBlockLines(w, headerBlock);
                        try fns.writeCloseTag(w, headerTag, true);
                    }

                    break :blk headerBlock.nextSibling();
                } else block.firstChild();

                {
                    const contentTag = "div";
                    const contentClasses = "tmd-notice-content";

                    try fns.writeOpenTag(w, contentTag, contentClasses, null, self.options.identSuffix, true);
                    try self.renderBlockChildren(w, firstContentBlock);
                    try fns.writeCloseTag(w, contentTag, true);
                }

                try fns.writeCloseTag(w, tag, true);
            },
            .reveal => {
                const tag = "details";
                const classes = "tmd-reveal";

                try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);

                const headerTag = "summary";
                const headerClasses = "tmd-reveal-header tmd-usual";
                const firstContentBlock = if (block.specialHeaderChild(self.doc.data)) |headerBlock| blk: {
                    try fns.writeOpenTag(w, headerTag, headerClasses, headerBlock.attributes, self.options.identSuffix, true);
                    try self.writeUsualContentBlockLines(w, headerBlock);

                    break :blk headerBlock.nextSibling();
                } else blk: {
                    try fns.writeOpenTag(w, headerTag, headerClasses, null, self.options.identSuffix, true);

                    break :blk block.firstChild();
                };
                try fns.writeCloseTag(w, headerTag, true);

                {
                    const contentTag = "div";
                    const contentClasses = "tmd-reveal-content";

                    try fns.writeOpenTag(w, contentTag, contentClasses, null, self.options.identSuffix, true);
                    try self.renderBlockChildren(w, firstContentBlock);
                    try fns.writeCloseTag(w, contentTag, true);
                }

                try fns.writeCloseTag(w, tag, true);
            },
            .plain => {
                const tag = "div";
                const classes = "tmd-plain";

                try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);

                const firstContentBlock = if (block.specialHeaderChild(self.doc.data)) |headerBlock| blk: {
                    {
                        const headerTag = "div";
                        const headerClasses = "tmd-plain-header";

                        try fns.writeOpenTag(w, headerTag, headerClasses, headerBlock.attributes, self.options.identSuffix, true);
                        try self.writeUsualContentBlockLines(w, headerBlock);
                        try fns.writeCloseTag(w, headerTag, true);
                    }

                    break :blk headerBlock.nextSibling();
                } else block.firstChild();

                try self.renderBlockChildren(w, firstContentBlock);
                try fns.writeCloseTag(w, tag, true);
            },

            // atom

            .blank => {
                const tag = "p";
                const classes = "";

                try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, false);
                try fns.writeCloseTag(w, tag, true);
            },
            .attributes => {},
            .link => {},
            .seperator => {
                const tag = "hr";
                const classes = "tmd-seperator";

                try fns.writeBareTag(w, tag, classes, block.attributes, self.options.identSuffix, true);
            },
            .header => |*header| {
                const level = header.level(self.doc.data);
                if (header.isBare()) {
                    try self.writeTableOfContents(w, level);
                } else {
                    const realLevel = if (block == self.doc.titleHeader) blk: {
                        if (block.nextSibling()) |sibling| {
                            self.toRenderSubtitles = sibling.blockType == .usual;
                        }
                        break :blk level;
                    } else if (self.doc.headerLevelNeedAdjusted(level)) level + 1 else level;

                    if (self.toRenderSubtitles) {
                        const headerTag = "header";
                        const headerClasses = "tmd-with-subtitle";
                        try fns.writeOpenTag(w, headerTag, headerClasses, null, self.options.identSuffix, true);
                    }

                    try w.print("<h{}", .{realLevel});
                    try fns.writeBlockAttributes(w, tmdHeaderClass(realLevel), block.attributes, self.options.identSuffix);
                    try w.writeAll(">\n");

                    try self.writeUsualContentBlockLines(w, block);

                    try w.print("</h{}>\n", .{realLevel});
                }
            },
            .usual => |usual| {
                //const usualLine = usual.startLine.lineType.usual;
                //const writeBlank = usualLine.markLen > 0 and usualLine.tokens.empty();
                const writeBlank = if (usual.startLine.firstTokenOf(.lineTypeMark_or_others)) |token|
                    token.* == .lineTypeMark and token.next() == null
                else
                    false;
                if (writeBlank) {
                    const blankTag = "p";
                    const blankClasses = "";

                    try fns.writeBareTag(w, blankTag, blankClasses, null, self.options.identSuffix, true);
                }

                const tag = "div";
                const classes = if (self.toRenderSubtitles) "tmd-usual tmd-subtitle" else "tmd-usual";

                try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);
                try self.writeUsualContentBlockLines(w, block);
                try fns.writeCloseTag(w, tag, true);

                if (self.toRenderSubtitles) {
                    self.toRenderSubtitles = false;

                    const headerTag = "header";
                    try fns.writeCloseTag(w, headerTag, true);
                }
            },
            .code => |*code| {
                const attrs = code.attributes();
                if (!attrs.commentedOut) {
                    try self.writeCodeBlockLines(w, block, attrs);
                }
            },
            .custom => |*custom| {
                const attrs = custom.attributes();
                if (attrs.app.len > 0 and !attrs.commentedOut) {
                    try self.writeCustomBlock(w, block, attrs);
                }
            },
        }

        if (footerTag.len > 0) {
            try fns.writeCloseTag(w, footerTag, true);
        }
    }

    fn renderBlockChildren(self: *TmdRender, w: anytype, firstChild: ?*const tmd.Block) !void {
        var child = firstChild orelse return;
        while (true) {
            try self.renderBlock(w, child);
            child = child.nextSibling() orelse break;
        }
    }

    //======================== table

    const TableCell = struct {
        row: u32,
        col: u32,
        endRow: u32,
        endCol: u32,
        block: *tmd.Block,
        next: ?*TableCell = null,

        // Used to sort column-major table cells.
        fn compare(_: void, x: @This(), y: @This()) bool {
            if (x.col < y.col) return true;
            if (x.col > y.col) return false;
            if (x.row < y.row) return true;
            if (x.row > y.row) return false;
            unreachable;
        }

        const Spans = struct {
            rowSpan: u32,
            colSpan: u32,
        };

        fn spans_RowOriented(
            self: *const @This(),
        ) Spans {
            return .{ .rowSpan = self.endRow - self.row, .colSpan = self.endCol - self.col };
        }

        fn spans_ColumnOriented(
            self: *const @This(),
        ) Spans {
            return .{ .rowSpan = self.endCol - self.col, .colSpan = self.endRow - self.row };
        }
    };

    fn collectTableCells(self: *TmdRender, firstTableChild: *tmd.Block) ![]TableCell {
        var numCells: usize = 0;
        var firstNonLineChild: ?*tmd.Block = null;
        var child = firstTableChild;
        while (true) {
            check: {
                switch (child.blockType) {
                    .blank => unreachable,
                    .attributes => break :check,
                    .seperator => break :check,
                    .base => |base| if (base.attributes().commentedOut) break :check,
                    else => std.debug.assert(child.isAtom()),
                }

                numCells += 1;
                if (firstNonLineChild == null) firstNonLineChild = child;
            }

            if (child.nextSibling()) |sibling| {
                child = sibling;
                std.debug.assert(child.nestingDepth == firstTableChild.nestingDepth);
            } else break;
        }

        if (numCells == 0) return &.{};

        const cells = try self.allocator.alloc(TableCell, numCells);
        var row: u32 = 0;
        var col: u32 = 0;
        var index: usize = 0;

        var toChangeRow = false;
        var lastMinEndRow: u32 = 0;
        var activeOldCells: ?*TableCell = null;
        var lastActiveOldCell: ?*TableCell = null;
        var uncheckedCells: ?*TableCell = null;

        child = firstNonLineChild orelse unreachable;
        while (true) {
            handle: {
                const rowSpan: u32, const colSpan: u32 = switch (child.blockType) {
                    .attributes => break :handle,
                    .seperator => {
                        toChangeRow = true;
                        break :handle;
                    },
                    .base => |base| blk: {
                        const attrs = base.attributes();
                        if (attrs.commentedOut) break :handle;
                        break :blk .{ attrs.cellSpans.crossSpan, attrs.cellSpans.axisSpan };
                    },
                    else => .{ 1, 1 },
                };

                if (toChangeRow) {
                    var cell = activeOldCells;
                    uncheckedCells = while (cell) |c| {
                        std.debug.assert(c.endRow >= lastMinEndRow);
                        if (c.endRow > lastMinEndRow) {
                            activeOldCells = c;
                            var last = c;
                            while (last.next) |next| {
                                std.debug.assert(next.endRow >= lastMinEndRow);
                                if (next.endRow > lastMinEndRow) {
                                    last.next = next;
                                    last = next;
                                }
                            }
                            last.next = null;
                            break c;
                        }
                        cell = c.next;
                    } else null;

                    activeOldCells = null;
                    lastActiveOldCell = null;

                    row = lastMinEndRow;
                    col = 0;
                    lastMinEndRow = 0;

                    toChangeRow = false;
                }
                defer index += 1;

                var cell = uncheckedCells;
                while (cell) |c| {
                    if (c.col <= col) {
                        col = c.endCol;
                        cell = c.next;

                        if (c.endRow - row > 1) {
                            if (activeOldCells == null) {
                                activeOldCells = c;
                            } else {
                                lastActiveOldCell.?.next = c;
                            }
                            lastActiveOldCell = c;
                            c.next = null;
                        }
                    } else {
                        uncheckedCells = c;
                        break;
                    }
                } else uncheckedCells = null;

                const endRow = row +| rowSpan;
                const endCol = col +| colSpan;
                defer col = endCol;

                cells[index] = .{
                    .row = row,
                    .col = col,
                    .endRow = endRow,
                    .endCol = endCol,
                    .block = child,
                };

                if (lastMinEndRow == 0 or endRow < lastMinEndRow) lastMinEndRow = endRow;
                if (rowSpan > 1) {
                    const c = &cells[index];
                    if (activeOldCells == null) {
                        activeOldCells = c;
                    } else {
                        lastActiveOldCell.?.next = c;
                    }
                    lastActiveOldCell = c;
                    c.next = null;
                }
            }

            child = child.nextSibling() orelse break;
        }
        std.debug.assert(index == cells.len);

        return cells;
    }

    fn writeTableCellSpans(w: anytype, spans: TableCell.Spans) !void {
        std.debug.assert(spans.rowSpan > 0);
        if (spans.rowSpan != 1) {
            try w.print(
                \\ rowspan="{}"
            , .{spans.rowSpan});
        }
        std.debug.assert(spans.colSpan > 0);
        if (spans.colSpan != 1) try w.print(
            \\ colspan="{}"
        , .{spans.colSpan});
    }

    // ToDo: write align
    fn renderTableHeaderCellBlock(self: *TmdRender, w: anytype, tableHeaderCellBlock: *const tmd.Block, spans: TableCell.Spans) !void {
        try w.writeAll("<th");
        try writeTableCellSpans(w, spans);
        try w.writeAll(">\n");
        try self.writeUsualContentBlockLines(w, tableHeaderCellBlock);
        try w.writeAll("</th>\n");
    }

    // ToDo: write align
    fn renderTableCellBlock(self: *TmdRender, w: anytype, tableCellBlock: *const tmd.Block, spans: TableCell.Spans) !void {
        var tdClass: []const u8 = "";
        switch (tableCellBlock.blockType) {
            .header => |header| {
                if (header.level(self.doc.data) == 1)
                    return try self.renderTableHeaderCellBlock(w, tableCellBlock, spans);
            },
            .base => |*base| { // some headers might need different text aligns.
                if (tableCellBlock.specialHeaderChild(self.doc.data)) |headerBlock| {
                    if (headerBlock.nextSibling() == null)
                        return try self.renderTableHeaderCellBlock(w, headerBlock, spans);
                }

                const attrs = base.attributes();
                switch (attrs.verticalAlign) {
                    .none => {},
                    .top => tdClass = "tmd-align-top",
                }
            },
            else => {},
        }

        const tag = "td";

        try fns.writeOpenTag(w, tag, tdClass, null, self.options.identSuffix, null);
        try writeTableCellSpans(w, spans);
        try w.writeAll(">\n");
        try self.renderBlock(w, tableCellBlock);
        try fns.writeCloseTag(w, tag, true);
    }

    fn renderTableBlock_RowOriented(self: *TmdRender, w: anytype, tableBlock: *const tmd.Block, firstChild: *tmd.Block) !void {
        const cells = try self.collectTableCells(firstChild);
        if (cells.len == 0) {
            try self.renderTableBlocks_WithoutCells(w, tableBlock);
            return;
        }
        defer self.allocator.free(cells);

        const tag = "table";
        const classes = "tmd-table";

        try fns.writeOpenTag(w, tag, classes, tableBlock.attributes, self.options.identSuffix, true);

        try w.writeAll("<tr>\n");
        var lastRow: u32 = 0;
        for (cells) |cell| {
            if (cell.row != lastRow) {
                lastRow = cell.row;

                try w.writeAll("</tr>\n");
                try w.writeAll("<tr>\n");
            }

            try self.renderTableCellBlock(w, cell.block, cell.spans_RowOriented());
        }
        try w.writeAll("</tr>\n");

        try fns.writeCloseTag(w, tag, true);
    }

    fn renderTableBlock_ColumnOriented(self: *TmdRender, w: anytype, tableBlock: *const tmd.Block, firstChild: *tmd.Block) !void {
        const cells = try self.collectTableCells(firstChild);
        if (cells.len == 0) {
            try self.renderTableBlocks_WithoutCells(w, tableBlock);
            return;
        }
        defer self.allocator.free(cells);

        std.sort.pdq(TableCell, cells, {}, TableCell.compare);

        const tag = "table";
        const classes = "tmd-table";

        try fns.writeOpenTag(w, tag, classes, tableBlock.attributes, self.options.identSuffix, true);

        try w.writeAll("<tr>\n");
        var lastCol: u32 = 0;
        for (cells) |cell| {
            if (cell.col != lastCol) {
                lastCol = cell.col;

                try w.writeAll("</tr>\n");
                try w.writeAll("<tr>\n");
            }

            try self.renderTableCellBlock(w, cell.block, cell.spans_ColumnOriented());
        }
        try w.writeAll("</tr>\n");

        try fns.writeCloseTag(w, tag, true);
    }

    fn renderTableBlocks_WithoutCells(self: *TmdRender, w: anytype, tableBlock: *const tmd.Block) !void {
        const tag = "div";
        const classes = "tmd-table-no-cells";

        try fns.writeOpenTag(w, tag, classes, tableBlock.attributes, self.options.identSuffix, true);
        try fns.writeCloseTag(w, tag, true);
    }

    fn renderTableBlock(self: *TmdRender, w: anytype, tableBlock: *const tmd.Block) !void {
        const child = tableBlock.next() orelse unreachable;
        const columnOriented = switch (child.blockType) {
            .usual => |usual| blk: {
                if (usual.startLine != usual.endLine) break :blk false;
                //break :blk if (usual.startLine.tokens()) |tokens| tokens.empty() else false;
                break :blk usual.startLine.firstTokenOf(.lineTypeMark_or_others) == null;
            },
            else => false,
        };

        if (columnOriented) {
            if (child.nextSibling()) |sibling|
                try self.renderTableBlock_ColumnOriented(w, tableBlock, sibling)
            else
                try self.renderTableBlocks_WithoutCells(w, tableBlock);
        } else try self.renderTableBlock_RowOriented(w, tableBlock, child);

        if (false and builtin.mode == .Debug) {
            if (columnOriented) {
                if (child.nextSibling()) |sibling|
                    try self.renderTableBlock_RowOriented(w, tableBlock, sibling)
                else
                    self.renderTableBlocks_WithoutCells(w, tableBlock);
            } else try self.renderTableBlock_ColumnOriented(w, tableBlock, child);
        }
    }

    //======================== custom

    fn writeCustomBlock(self: *TmdRender, w: anytype, block: *const tmd.Block, attrs: tmd.CustomBlockAttibutes) !void {
        std.debug.assert(attrs.app.len > 0);

        // Not a good idea to wrapping the content.
        // For example, the wrapper will break some
        // "html" custom code.

        //const tag = "div";
        //const classes = "tmd-custom";

        //try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);

        const aw = if (@TypeOf(w) == std.io.AnyWriter) w else w.any();
        const callback = self.getCustomBlockGenCallback(&block.blockType.custom);
        try callback.write(aw);

        //try fns.writeCloseTag(w, tag, true);
    }

    //============================== code

    fn writeCodeBlockLines(self: *TmdRender, w: anytype, block: *const tmd.Block, attrs: tmd.CodeBlockAttibutes) !void {
        std.debug.assert(block.blockType == .code);

        //std.debug.print("\n==========\n", .{});
        //std.debug.print("commentedOut: {}\n", .{attrs.commentedOut});
        //std.debug.print("language: {s}\n", .{@tagName(attrs.language)});
        //std.debug.print("==========\n", .{});

        const tag = "pre";
        const classes = "tmd-code";

        try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);

        if (attrs.language.len > 0) {
            try w.writeAll("<code class=\"language-");
            try fns.writeHtmlAttributeValue(w, attrs.language);
            try w.writeAll("\"");
            try w.writeAll(">");
        }

        const endLine = block.endLine();
        const startLine = block.startLine();
        std.debug.assert(startLine.lineType == .codeBlockStart);

        if (startLine.next()) |firstLine| {
            var line = firstLine;
            while (true) {
                switch (line.lineType) {
                    .codeBlockEnd => break,
                    .code => {
                        std.debug.assert(std.meta.eql(line.range(.trimLineEnd), line.range(.trimSpaces)));
                        try fns.writeHtmlContentText(w, self.doc.rangeData(line.range(.trimLineEnd)));
                    },
                    else => unreachable,
                }

                std.debug.assert(!line.treatEndAsSpace);
                try w.writeAll("\n");

                if (line == endLine) break;

                line = line.next() orelse unreachable;
            }
        }

        blk: {
            const streamAttrs = block.blockType.code._contentStreamAttributes();
            const content = streamAttrs.content;
            if (content.len == 0) break :blk;
            if (std.mem.startsWith(u8, content, "./") or std.mem.startsWith(u8, content, "../")) {
                // ToDo: ...
            } else if (std.mem.startsWith(u8, content, "#")) {
                const id = content[1..];
                const b = if (self.doc.blockByID(id)) |b| b else break :blk;
                try self.renderTmdCode(w, b, true);
            } else break :blk;
        }

        if (attrs.language.len > 0) {
            try w.writeAll("</code>");
        }

        try fns.writeCloseTag(w, tag, true);
    }

    fn renderTmdCode(self: *TmdRender, w: anytype, block: *const tmd.Block, trimBoundaryLines: bool) anyerror!void {
        switch (block.blockType) {
            .root => unreachable,
            .base => |base| {
                try self.renderTmdCodeOfLine(w, base.openLine, trimBoundaryLines);
                try self.renderTmdCodeForBlockChildren(w, block);
                if (base.closeLine) |closeLine| try self.renderTmdCodeOfLine(w, closeLine, trimBoundaryLines);
            },

            // built-in containers
            .list, .item, .table, .quotation, .notice, .reveal, .plain => {
                try self.renderTmdCodeForBlockChildren(w, block);
            },

            // atom
            .seperator, .header, .usual, .attributes, .link, .blank, .code, .custom => try self.renderTmdCodeForAtomBlock(w, block, trimBoundaryLines),
        }
    }

    fn renderTmdCodeForBlockChildren(self: *TmdRender, w: anytype, parentBlock: *const tmd.Block) !void {
        var child = parentBlock.firstChild() orelse return;
        while (true) {
            try self.renderTmdCode(w, child, false);
            child = child.nextSibling() orelse break;
        }
    }

    fn renderTmdCodeForAtomBlock(self: *TmdRender, w: anytype, atomBlock: *const tmd.Block, trimBoundaryLines: bool) !void {
        var line = atomBlock.startLine();
        const endLine = atomBlock.endLine();
        while (true) {
            try self.renderTmdCodeOfLine(w, line, trimBoundaryLines);

            if (line == endLine) break;
            line = line.next() orelse unreachable;
        }
    }

    fn renderTmdCodeOfLine(self: *TmdRender, w: anytype, line: *const tmd.Line, trimBoundaryLines: bool) !void {
        if (trimBoundaryLines and line.isBoundary()) return;

        const start = line.start(.none);
        const end = line.end(.trimLineEnd);
        try fns.writeHtmlContentText(w, self.doc.rangeData(.{ .start = start, .end = end }));
        try w.writeAll("\n");
    }

    //======================== usual

    const MarkCount = tmd.SpanMarkType.MarkCount;
    const MarkStatus = struct {
        mark: ?*tmd.Token.SpanMark = null,
    };
    const MarkStatusesTracker = struct {
        markStatusElements: [MarkCount]list.Element(MarkStatus) = .{list.Element(MarkStatus){}} ** MarkCount,
        marksStack: list.List(MarkStatus) = .{},

        activeLinkInfo: ?*tmd.Token.LinkInfo = null,
        // These are only valid when activeLinkInfo != null.
        firstPlainTextInLink: bool = undefined,
        linkFootnote: *Footnote = undefined,

        fn onLinkInfo(self: *@This(), linkInfo: *tmd.Token.LinkInfo) void {
            self.activeLinkInfo = linkInfo;
            self.firstPlainTextInLink = true;
        }
    };

    fn writeUsualContentBlockLinesFornoStyling(self: *TmdRender, w: anytype, block: *const tmd.Block) !void {
        try self.writeContentBlockLines(w, block, .noStyling);
    }

    fn writeUsualContentBlockLinesForTocItem(self: *TmdRender, w: anytype, block: *const tmd.Block) !void {
        try self.writeContentBlockLines(w, block, .tocItem);
    }

    fn writeUsualContentBlockLines(self: *TmdRender, w: anytype, block: *const tmd.Block) !void {
        try self.writeContentBlockLines(w, block, .general);
    }

    const contentUsage = enum {
        general,
        tocItem, // disable link (for headers when being rendered as TOC items)
        noStyling, // disable all styles (for HTML page title in head)
    };

    fn writeContentBlockLines(self: *TmdRender, w: anytype, block: *const tmd.Block, usage: contentUsage) !void {
        const inHeader = block.blockType == .header;
        var tracker: MarkStatusesTracker = .{};

        const endLine = block.endLine();
        var line = block.startLine();

        while (true) {
            var element = line.tokens.head;
            var isNonBareSpoilerLine = false;
            while (element) |tokenElement| {
                const token = &tokenElement.value;
                switch (token.*) {
                    inline .commentText, .extra, .lineTypeMark, .containerMark => {},
                    .content => blk: {
                        if (tracker.activeLinkInfo) |linkInfo| {
                            const link = linkInfo.link;
                            if (!tracker.firstPlainTextInLink) {
                                std.debug.assert(!link.isFootnote());
                                std.debug.assert(link.urlSourceSet());

                                if (link.textInfo.urlSourceText) |sourceText| {
                                    if (sourceText == token) break :blk;
                                }
                            } else {
                                tracker.firstPlainTextInLink = false;

                                if (link.isFootnote()) {
                                    if (usage == .general) {
                                        if (tracker.linkFootnote.block) |_| {
                                            try w.print("[{}]", .{tracker.linkFootnote.orderIndex});
                                        } else {
                                            try w.print("[{}]?", .{tracker.linkFootnote.orderIndex});
                                        }
                                    }
                                    break :blk;
                                }
                            }
                        }
                        const text = self.doc.rangeData(token.range());
                        try fns.writeHtmlContentText(w, text);
                    },
                    .linkInfo => |*l| {
                        tracker.onLinkInfo(l);
                    },
                    .evenBackticks => |m| {
                        if (m.more.secondary) {
                            //try w.writeAll("&ZeroWidthSpace;"); // ToDo: write the code utf value instead

                            for (0..m.pairCount) |_| {
                                try w.writeAll("`");
                            }
                        } else if (usage == .noStyling) {
                            if (m.pairCount > 1) {
                                try w.writeAll(" ");
                            }
                        } else {
                            for (1..m.pairCount) |_| {
                                //try w.writeAll("&nbsp;");
                                try w.writeAll("&#160;"); // better in epub
                            }
                        }
                    },
                    .spanMark => |*m| {
                        if (m.more.blankSpan) {
                            // skipped
                        } else if (m.more.open) {
                            const markElement = &tracker.markStatusElements[m.markType.asInt()];
                            std.debug.assert(markElement.value.mark == null);

                            markElement.value.mark = m;
                            if (m.markType == .link and !m.more.secondary) {
                                std.debug.assert(tracker.activeLinkInfo != null);

                                tracker.marksStack.pushHead(markElement);
                                try writeCloseMarks(w, markElement, usage);

                                const linkInfo = tracker.activeLinkInfo orelse unreachable;
                                const link = linkInfo.link;
                                if (usage == .general) blk: {
                                    //if (link.isFootnote()) {
                                    //    std.debug.assert(link.urlConfirmed());
                                    //    break :blk;
                                    //}
                                    //
                                    //if (self.linkUrlValidateFn(link)) |validURL| {
                                    //    break :blk;
                                    //}

                                    // broken ...

                                    // old ...

                                    if (link.urlConfirmed()) {
                                        std.debug.assert(link.textInfo.urlSourceText != null);

                                        const t = link.textInfo.urlSourceText.?;
                                        const linkURL = LineScanner.trim_blanks(self.doc.rangeData(t.range()));

                                        if (link.isFootnote()) {
                                            const footnote_id = linkURL[1..];
                                            const footnote = try self.onFootnoteReference(footnote_id);
                                            tracker.linkFootnote = footnote;

                                            if (self.incFootnoteRefWrittenCounts) footnote.refWrittenCount += 1;

                                            try w.print(
                                                \\<sup><a id="fn:{s}{s}:ref-{}" href="#fn:{s}{s}">
                                            , .{ footnote_id, self.options.identSuffix, footnote.refWrittenCount, footnote_id, self.options.identSuffix });
                                            break :blk;
                                        }

                                        try w.print(
                                            \\<a href="{s}">
                                        , .{linkURL});
                                    } else {
                                        std.debug.assert(!link.urlConfirmed());
                                        std.debug.assert(!link.isFootnote());

                                        // ToDo: call custom callback to try to generate a url.

                                        try w.writeAll(
                                            \\<span class="tmd-broken-link">
                                        );

                                        break :blk;
                                    }
                                }

                                try writeOpenMarks(w, markElement, usage);
                            } else {
                                tracker.marksStack.pushTail(markElement);
                                try writeOpenMark(w, markElement.value.mark.?, usage);
                            }
                        } else try closeMark(w, m, &tracker, usage);
                    },
                    .leadingSpanMark => |m| {
                        switch (m.more.markType) {
                            .lineBreak => {
                                if (usage != .noStyling) try w.writeAll("<br/>");
                            },
                            .escape => {},
                            .spoiler => if (tokenElement.next) |_| {
                                if (usage != .noStyling) try w.writeAll(
                                    \\<span class="tmd-spoiler">
                                );
                                isNonBareSpoilerLine = true;
                            },
                            .comment => break,
                            .media => blk: {
                                if (tracker.activeLinkInfo) |_| {
                                    tracker.firstPlainTextInLink = false;
                                }
                                if (m.more.isBare) {
                                    try w.writeAll(" ");
                                    break :blk;
                                }
                                if (usage == .noStyling) break :blk;

                                const mediaInfoElement = tokenElement.next.?;
                                const isInline = inHeader or block.more.hasNonMediaTokens;

                                writeMedia: {
                                    const mediaInfoToken = mediaInfoElement.value;
                                    std.debug.assert(mediaInfoToken == .content);

                                    const src = self.doc.rangeData(mediaInfoToken.range());
                                    if (!AttributeParser.isValidMediaURL(src)) break :writeMedia;

                                    try w.writeAll("<img src=\"");
                                    try fns.writeHtmlAttributeValue(w, src);
                                    if (isInline) {
                                        try w.writeAll("\" class=\"tmd-inline-media\"/>");
                                    } else {
                                        try w.writeAll("\" class=\"tmd-media\"/>");
                                    }
                                }

                                element = mediaInfoElement.next;
                                continue;
                            },
                        }
                    },
                }

                element = tokenElement.next;
            }

            if (usage != .noStyling) {
                if (isNonBareSpoilerLine) try w.writeAll("</span>");
            }

            if (line != endLine) {
                if (line.treatEndAsSpace) try w.writeAll(" ");
                line = line.next() orelse unreachable;
            } else {
                std.debug.assert(!line.treatEndAsSpace);
                break;
            }
        }

        if (tracker.marksStack.tail) |element| {
            var markElement = element;
            while (true) {
                if (markElement.value.mark) |m| {
                    try closeMark(w, m, &tracker, usage);
                } else unreachable;

                if (markElement.prev) |prev| {
                    markElement = prev;
                } else break;
            }
        }

        if (usage == .general) try w.writeAll("\n");
    }

    // Genreally, m is a close mark. But for missing close marks in the end,
    // their open counterparts are passed in here.
    fn closeMark(w: anytype, m: *tmd.Token.SpanMark, tracker: *MarkStatusesTracker, usage: contentUsage) !void {
        const markElement = &tracker.markStatusElements[m.markType.asInt()];
        std.debug.assert(markElement.value.mark != null);

        done: {
            switch (m.markType) {
                .link => blk: {
                    const linkInfo = tracker.activeLinkInfo orelse break :blk;
                    tracker.activeLinkInfo = null;
                    const link = linkInfo.link;

                    try writeCloseMarks(w, markElement, usage);

                    if (usage == .general) {
                        if (link.urlConfirmed()) {
                            try w.writeAll("</a>");
                            if (link.isFootnote()) {
                                try w.writeAll("</sup>");
                            }
                        } else {
                            try w.writeAll("</span>");
                        }
                    }

                    try writeOpenMarks(w, markElement, usage);

                    if (tracker.marksStack.popHead()) |head| {
                        std.debug.assert(head == markElement);
                    } else unreachable;

                    break :done;
                },
                .code => {
                    if (!markElement.value.mark.?.more.secondary) {
                        if (tracker.marksStack.popTail()) |tail| {
                            std.debug.assert(tail == markElement);
                        } else unreachable;

                        try writeCloseMark(w, markElement.value.mark.?, usage);

                        break :done;
                    }
                },
                else => {},
            }

            // else ...

            try writeCloseMarks(w, markElement, usage);
            try writeCloseMark(w, markElement.value.mark.?, usage);
            try writeOpenMarks(w, markElement, usage);

            tracker.marksStack.delete(markElement);
        }

        markElement.value.mark = null;
    }

    fn writeOpenMarks(w: anytype, bottomElement: *list.Element(MarkStatus), usage: contentUsage) !void {
        var next = bottomElement.next;
        while (next) |element| {
            try writeOpenMark(w, element.value.mark.?, usage);
            next = element.next;
        }
    }

    fn writeCloseMarks(w: anytype, bottomElement: *list.Element(MarkStatus), usage: contentUsage) !void {
        var next = bottomElement.next;
        while (next) |element| {
            try writeCloseMark(w, element.value.mark.?, usage);
            next = element.next;
        }
    }

    // ToDo: to optimize by using a table.
    fn writeOpenMark(w: anytype, spanMark: *tmd.Token.SpanMark, usage: contentUsage) !void {
        if (usage == .noStyling) return;

        switch (spanMark.markType) {
            .link => {
                std.debug.assert(spanMark.more.secondary);
                try w.writeAll(
                    \\<span class="tmd-underlined">
                );
            },
            .fontWeight => {
                if (spanMark.more.secondary) {
                    try w.writeAll(
                        \\<span class="tmd-dimmed">
                    );
                } else {
                    try w.writeAll(
                        \\<span class="tmd-bold">
                    );
                }
            },
            .fontStyle => {
                if (spanMark.more.secondary) {
                    try w.writeAll(
                        \\<span class="tmd-revert-italic">
                    );
                } else {
                    try w.writeAll(
                        \\<span class="tmd-italic">
                    );
                }
            },
            .fontSize => {
                if (spanMark.more.secondary) {
                    try w.writeAll(
                        \\<span class="tmd-larger-size">
                    );
                } else {
                    try w.writeAll(
                        \\<span class="tmd-smaller-size">
                    );
                }
            },
            .deleted => {
                if (spanMark.more.secondary) {
                    try w.writeAll(
                        \\<span class="tmd-invisible">
                    );
                } else {
                    try w.writeAll(
                        \\<span class="tmd-deleted">
                    );
                }
            },
            .marked => {
                if (spanMark.more.secondary) {
                    try w.writeAll(
                        \\<mark class="tmd-marked-2">
                    );
                } else {
                    try w.writeAll(
                        \\<mark class="tmd-marked">
                    );
                }
            },
            .supsub => {
                if (spanMark.more.secondary) {
                    try w.writeAll("<sup>");
                } else {
                    try w.writeAll("<sub>");
                }
            },
            .code => {
                if (spanMark.more.secondary) {
                    try w.writeAll(
                        \\<code class="tmd-mono-font">
                    );
                } else {
                    try w.writeAll(
                        \\<code class="tmd-code-span">
                    );
                }
            },
        }
    }

    // ToDo: to optimize
    fn writeCloseMark(w: anytype, spanMark: *tmd.Token.SpanMark, usage: contentUsage) !void {
        if (usage == .noStyling) return;

        switch (spanMark.markType) {
            .link, .fontWeight, .fontStyle, .fontSize, .deleted => {
                try w.writeAll("</span>");
            },
            .marked => {
                try w.writeAll("</mark>");
            },
            .supsub => {
                if (spanMark.more.secondary) {
                    try w.writeAll("</sup>");
                } else {
                    try w.writeAll("</sub>");
                }
            },
            .code => {
                try w.writeAll("</code>");
            },
        }
    }

    //================================= TOC and footnotes

    fn writeTableOfContents(self: *TmdRender, w: anytype, level: u8) !void {
        if (self.doc.tocHeaders.empty()) return;

        try w.writeAll("\n<ul class=\"tmd-list tmd-toc\">\n");

        var levelOpened: [tmd.MaxHeaderLevel + 1]bool = .{false} ** (tmd.MaxHeaderLevel + 1);
        var lastLevel: u8 = tmd.MaxHeaderLevel + 1;
        var listElement = self.doc.tocHeaders.head;
        while (listElement) |element| {
            defer listElement = element.next;
            const headerBlock = element.value;
            const headerLevel = headerBlock.blockType.header.level(self.doc.data);
            if (headerLevel > level) continue;

            defer lastLevel = headerLevel;

            //std.debug.print("== lastLevel={}, level={}\n", .{lastLevel, level});

            if (lastLevel > headerLevel) {
                for (headerLevel..lastLevel) |level_1| if (levelOpened[level_1]) {
                    // close last level
                    levelOpened[level_1] = false;
                    try w.writeAll("</ul>\n");
                };
            } else if (lastLevel < headerLevel) {
                // open level
                levelOpened[headerLevel - 1] = true;
                try w.writeAll("\n<ul class=\"tmd-list tmd-toc\">\n");
            }

            try w.writeAll("<li class=\"tmd-list-item tmd-toc-item\">");

            const id = if (headerBlock.attributes) |as| as.id else "";

            // ToDo:
            //try w.writeAll("hdr:");
            // try self.writeUsualContentAsID(w, headerBlock);
            // Maybe it is better to pre-generate the IDs, to avoid duplications.

            if (id.len == 0) try w.writeAll("<span class=\"tmd-broken-link\"") else {
                try w.writeAll("<a href=\"#");
                try w.writeAll(id);
                try w.writeAll(self.options.identSuffix);
            }
            try w.writeAll("\">");

            try self.writeUsualContentBlockLinesForTocItem(w, headerBlock);

            if (id.len == 0) try w.writeAll("</span>\n") else try w.writeAll("</a>\n");

            try w.writeAll("</li>\n");
        }

        for (&levelOpened) |opened| if (opened) {
            try w.writeAll("</ul>\n");
        };

        try w.writeAll("</ul>\n");
    }

    fn writeFootnotes(self: *TmdRender, w: anytype) !void {
        self.incFootnoteRefWrittenCounts = false;
        try self._writeFootnotes(std.io.null_writer);
        self.incFootnoteRefWrittenCounts = true;
        self.incFootnoteRefCounts = false;
        try self._writeFootnotes(w);
        self.incFootnoteRefCounts = true; // needless?
    }

    fn _writeFootnotes(self: *TmdRender, w: anytype) !void {
        if (self.footnoteNodes.empty()) return;

        try w.writeAll("\n<ol class=\"tmd-list tmd-footnotes\">\n");

        var listElement = self.footnoteNodes.head;
        while (listElement) |element| {
            defer listElement = element.next;
            const footnote = element.value.value;

            try w.print("<li id=\"fn:{s}{s}\" class=\"tmd-list-item tmd-footnote-item\">\n", .{ footnote.id, self.options.identSuffix });
            const missing_flag = if (footnote.block) |block| blk: {
                switch (block.blockType) {
                    // .item can't have ID now.
                    //.item => try self.renderBlockChildren(w, block),
                    .item => unreachable,
                    else => try self.renderBlock(w, block),
                }
                break :blk "";
            } else "?";

            for (1..footnote.refCount + 1) |n| {
                try w.print("<a href=\"#fn:{s}{s}:ref-{}\">↩︎{s}</a>", .{ footnote.id, self.options.identSuffix, n, missing_flag });
            }
            try w.writeAll("</li>\n");
        }

        try w.writeAll("</ol>\n");
    }

    //===================================

    fn tmdHeaderClass(level: u8) []const u8 {
        return switch (level) {
            1 => "tmd-header-1",
            2 => "tmd-header-2",
            3 => "tmd-header-3",
            4 => "tmd-header-4",
            5 => "tmd-header-5", // tmd.MaxHeaderLevel + 1
            else => unreachable,
        };
    }
};

test "footnotes" {
    {
        const example1 =
            \\
            \\### Title
            \\
            \\This is a footnode __#foo__
            \\
            \\{//
            \\
            \\@@@ #foo
            \\bla bla bla __#foo__.
            \\bla bla __#bar__.
            \\
            \\@@@ #bar
            \\bla bla bla __#foo__.
            \\bla bla __#bar__.
            \\
            \\}
            \\
        ;

        var doc = try @import("tmd_to_doc.zig").parse_tmd(example1, std.testing.allocator, false);
        defer doc.destroy();

        var r = TmdRender{
            .doc = &doc,
            .allocator = std.testing.allocator,
            .options = .{},
        };

        try r.render(std.io.null_writer);

        const footnotes = &r.footnoteNodes;
        try std.testing.expect(!footnotes.empty());

        if (footnotes.head) |head| {
            var element = head;
            while (true) {
                const next = element.next;
                const footnote = element.value.value;
                try std.testing.expect(footnote.refCount == footnote.refWrittenCount);
                if (next) |n| element = n else break;
            }
        }
    }
}
