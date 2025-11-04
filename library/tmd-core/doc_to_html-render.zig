const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd.zig");
const list = @import("list");
const tree = @import("tree");

const AttributeParser = @import("tmd_to_doc-attribute_parser.zig");
const fns = @import("doc_to_html-fns.zig");

pub const GenOptions = struct {
    renderedExtension: []const u8 = ".html",
    renderRoot: bool = true,
    identSuffix: []const u8 = "", // for forum posts etc. To avoid id duplications.
    autoIdentSuffix: []const u8 = "", // to avoid some auto id duplication. Should only be used when identPrefix is blank.

    // more render switches
    // enabled_style_xxx: bool,
    // ignoreClasses: bool = false, // for forum posts etc.

    callbacks: struct {
        // Must be valid if any of the following callbacks is not null.
        // Will be passed as the first arguments of the callbacks.
        // Generally, it should hold the tmd.Doc to be generated.
        context: *const anyopaque = undefined,

        fnGetCustomBlockGenerator: ?*const fn (context: *const anyopaque, custom: *const tmd.BlockType.Custom) anyerror!?Generator = null,
        // ToDo: fnCodeBlockGenerator, and for any kinds of blocks?

        fnGetMediaUrlGenerator: ?*const fn (context: *const anyopaque, link: *const tmd.Link) anyerror!?Generator = null,
        fnGetLinkUrlGenerator: ?*const fn (context: *const anyopaque, link: *const tmd.Link, isCurrentItemInNav: *?bool) anyerror!?Generator = null,
    } = .{},
};

pub const Generator = struct {
    obj: *const anyopaque,
    genFn: *const fn (obj: *const anyopaque, w: *std.Io.Writer) anyerror!void,

    fn gen(self: Generator, w: *std.Io.Writer) !void {
        return self.genFn(self.obj, w);
    }

    pub fn init(obj: anytype) Generator {
        const T = @TypeOf(obj);
        const typeInfo = @typeInfo(T);
        switch (typeInfo) {
            .pointer => |pointer| {
                const C = struct {
                    pub fn writeAll(v: *const anyopaque, w: *std.Io.Writer) !void {
                        const Base = pointer.child;
                        const ptr: *const Base = @ptrCast(@alignCast(v));
                        return try Base.gen(ptr, w);
                    }
                };
                return .{ .obj = obj, .genFn = C.writeAll };
            },
            inline .@"struct", .@"union", .@"enum" => {
                if (@sizeOf(T) != 0) @compileError("The sizes of non-pointer Generator types must be zero.");

                const C = struct {
                    pub fn writeAll(_: *const anyopaque, w: *std.Io.Writer) !void {
                        return try T.gen(T{}, w);
                    }
                };
                return .{ .obj = undefined, .genFn = C.writeAll };
            },
            inline else => @compileError("Unsupported GenBallback type."),
        }
    }

    pub fn dummy() Generator {
        const DummyGenerator = struct {
            pub fn gen(_: @This(), _: *std.Io.Writer) !void {}
        };

        return .init(DummyGenerator{});
    }
};

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

    const FootnoteRedBlack = tree.RedBlack(*Footnote, Footnote);
    const Footnote = struct {
        id: []const u8,
        orderIndex: u32 = undefined,
        refCount: u32 = undefined,
        refWrittenCount: u32 = undefined,
        block: ?*const tmd.Block = undefined,

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

    pub fn init(doc: *const tmd.Doc, allocator: std.mem.Allocator, options: GenOptions) TmdRender {
        var r = TmdRender{
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
        self.footnoteNodes.destroy(T.destroyFootnoteNode, self.allocator);
    }

    fn getCustomBlockGenerator(self: *const TmdRender, custom: *const tmd.BlockType.Custom) !Generator {
        if (self.options.callbacks.fnGetCustomBlockGenerator) |get| {
            if (try get(self.options.callbacks.context, custom)) |callback| return callback;
        }

        return .dummy();
    }

    fn getLinkUrlGenerator(self: *const TmdRender, link: *const tmd.Link, isCurrentItemInNav: *?bool) !?Generator {
        if (self.options.callbacks.fnGetLinkUrlGenerator) |get| {
            if (try get(self.options.callbacks.context, link, isCurrentItemInNav)) |callback| return callback;
        }
        return null;
    }

    fn getMediaUrlGenerator(self: *const TmdRender, link: *const tmd.Link) !?Generator {
        if (self.options.callbacks.fnGetMediaUrlGenerator) |get| {
            if (try get(self.options.callbacks.context, link)) |callback| return callback;
        }
        return null;
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

        const nodeElement = try self.footnoteNodes.createElement(self.allocator, true);
        const node = &nodeElement.value;
        node.value = footnote;
        std.debug.assert(node == self.footnotesByID.insert(node));

        return footnote;
    }

    pub fn writeTitleInHtmlHead(self: *TmdRender, w: *std.Io.Writer) !bool {
        if (self.doc.titleHeader) |titleHeader| {
            try self.writeUsualContentBlockLinesForNoStyling(w, titleHeader);
            return true;
        } else {
            //try w.writeAll("");
            return false;
        }
    }

    pub fn writeTitleInTocItem(self: *TmdRender, w: *std.Io.Writer) !bool {
        if (self.doc.titleHeader) |titleHeader| {
            try self.writeUsualContentBlockLinesForTocItem(w, titleHeader);
            return true;
        } else {
            //try w.writeAll("");
            return false;
        }
    }

    pub fn render(self: *TmdRender, w: *std.Io.Writer) !void {
        try self._render(w, true);
    }

    fn _render(self: *TmdRender, w: *std.Io.Writer, doCleanup: bool) !void {
        defer if (doCleanup) self.cleanup();

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

    fn renderBlock(self: *TmdRender, w: *std.Io.Writer, block: *const tmd.Block) anyerror!void {
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
            .unstyled => {
                const tag = "div";
                const classes = "tmd-unstyled";

                try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);

                const firstContentBlock = if (block.specialHeaderChild(self.doc.data)) |headerBlock| blk: {
                    {
                        const headerTag = "div";
                        const headerClasses = "tmd-unstyled-header";

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
            .linkdef => {},
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

                const dropCap = if (block.startLine().firstTokenOf(.others)) |t| t.isBlankSpanMark() else false;

                const tag = "div";
                const classes = if (self.toRenderSubtitles) "tmd-usual tmd-subtitle" else blk: {
                    break :blk if (dropCap) "tmd-usual tmd-dropcap" else "tmd-usual";
                };

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
                if (attrs.contentType.len > 0 and !attrs.commentedOut) {
                    try self.writeCustomBlock(w, block, attrs);
                }
            },
        }

        if (footerTag.len > 0) {
            try fns.writeCloseTag(w, footerTag, true);
        }
    }

    fn renderBlockChildren(self: *TmdRender, w: *std.Io.Writer, firstChild: ?*const tmd.Block) !void {
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
        block: *const tmd.Block,
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

    fn collectTableCells(self: *TmdRender, firstTableChild: *const tmd.Block) ![]TableCell {
        var numCells: usize = 0;
        var firstNonLineChild: ?*const tmd.Block = null;
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

    fn writeTableCellSpans(w: *std.Io.Writer, spans: TableCell.Spans) !void {
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
    fn renderTableHeaderCellBlock(self: *TmdRender, w: *std.Io.Writer, tableHeaderCellBlock: *const tmd.Block, spans: TableCell.Spans) !void {
        try w.writeAll("<th");
        try writeTableCellSpans(w, spans);
        try w.writeAll(">\n");
        try self.writeUsualContentBlockLines(w, tableHeaderCellBlock);
        try w.writeAll("</th>\n");
    }

    // ToDo: write align
    fn renderTableCellBlock(self: *TmdRender, w: *std.Io.Writer, tableCellBlock: *const tmd.Block, spans: TableCell.Spans) !void {
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

    fn renderTableBlock_RowOriented(self: *TmdRender, w: *std.Io.Writer, tableBlock: *const tmd.Block, firstChild: *const tmd.Block) !void {
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

    fn renderTableBlock_ColumnOriented(self: *TmdRender, w: *std.Io.Writer, tableBlock: *const tmd.Block, firstChild: *const tmd.Block) !void {
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

    fn renderTableBlocks_WithoutCells(self: *TmdRender, w: *std.Io.Writer, tableBlock: *const tmd.Block) !void {
        const tag = "div";
        const classes = "tmd-table-no-cells";

        try fns.writeOpenTag(w, tag, classes, tableBlock.attributes, self.options.identSuffix, true);
        try fns.writeCloseTag(w, tag, true);
    }

    fn renderTableBlock(self: *TmdRender, w: *std.Io.Writer, tableBlock: *const tmd.Block) !void {
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

    fn writeCustomBlock(self: *TmdRender, w: *std.Io.Writer, block: *const tmd.Block, attrs: tmd.CustomBlockAttibutes) !void {
        std.debug.assert(attrs.contentType.len > 0);

        // Not a good idea to wrapping the content.
        // For example, the wrapper will break some
        // "html" custom code.

        //const tag = "div";
        //const classes = "tmd-custom";

        //try fns.writeOpenTag(w, tag, classes, block.attributes, self.options.identSuffix, true);

        const callback = try self.getCustomBlockGenerator(&block.blockType.custom);
        try callback.gen(w);

        //try fns.writeCloseTag(w, tag, true);
    }

    //============================== code

    fn writeCodeBlockLines(self: *TmdRender, w: *std.Io.Writer, block: *const tmd.Block, attrs: tmd.CodeBlockAttibutes) !void {
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
            const streamAttrs = block.blockType.code.contentStreamAttributes();
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

    fn renderTmdCode(self: *TmdRender, w: *std.Io.Writer, block: *const tmd.Block, trimBoundaryLines: bool) anyerror!void {
        switch (block.blockType) {
            .root => unreachable,
            .base => |base| {
                try self.renderTmdCodeOfLine(w, base.openLine, trimBoundaryLines);
                try self.renderTmdCodeForBlockChildren(w, block);
                if (base.closeLine) |closeLine| try self.renderTmdCodeOfLine(w, closeLine, trimBoundaryLines);
            },

            // built-in containers
            .list, .item, .table, .quotation, .notice, .reveal, .unstyled => {
                try self.renderTmdCodeForBlockChildren(w, block);
            },

            // atom
            .seperator, .header, .usual, .attributes, .linkdef, .blank, .code, .custom => try self.renderTmdCodeForAtomBlock(w, block, trimBoundaryLines),
        }
    }

    fn renderTmdCodeForBlockChildren(self: *TmdRender, w: *std.Io.Writer, parentBlock: *const tmd.Block) !void {
        var child = parentBlock.firstChild() orelse return;
        while (true) {
            try self.renderTmdCode(w, child, false);
            child = child.nextSibling() orelse break;
        }
    }

    fn renderTmdCodeForAtomBlock(self: *TmdRender, w: *std.Io.Writer, atomBlock: *const tmd.Block, trimBoundaryLines: bool) !void {
        var line = atomBlock.startLine();
        const endLine = atomBlock.endLine();
        while (true) {
            try self.renderTmdCodeOfLine(w, line, trimBoundaryLines);

            if (line == endLine) break;
            line = line.next() orelse unreachable;
        }
    }

    fn renderTmdCodeOfLine(self: *TmdRender, w: *std.Io.Writer, line: *const tmd.Line, trimBoundaryLines: bool) !void {
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

        const List = list.List(@This());
    };
    const MarkStatusesTracker = struct {
        markStatusElements: [MarkCount]MarkStatus.List.Element = .{MarkStatus.List.Element{ .value = .{} }} ** MarkCount,
        marksStack: MarkStatus.List = .{},

        activeLinkInfo: ?*tmd.Token.LinkInfo = null,
        // These are only valid when activeLinkInfo != null.
        linkFootnote: ?*Footnote = undefined,
        brokenLinkConfirmed: bool = undefined,

        fn onLinkInfo(self: *@This(), linkInfo: *tmd.Token.LinkInfo) void {
            self.activeLinkInfo = linkInfo;
            self.brokenLinkConfirmed = false;
        }
    };

    fn writeUsualContentBlockLinesForNoStyling(self: *TmdRender, w: *std.Io.Writer, block: *const tmd.Block) !void {
        try self.writeContentBlockLines(w, block, .noStyling);
    }

    fn writeUsualContentBlockLinesForTocItem(self: *TmdRender, w: *std.Io.Writer, block: *const tmd.Block) !void {
        try self.writeContentBlockLines(w, block, .tocItem);
    }

    fn writeUsualContentBlockLines(self: *TmdRender, w: *std.Io.Writer, block: *const tmd.Block) !void {
        try self.writeContentBlockLines(w, block, .general);
    }

    const contentUsage = enum {
        general,
        tocItem, // disable link (for headers when being rendered as TOC items)
        noStyling, // disable all styles (for HTML page title in head)
    };

    fn writeContentBlockLines(self: *TmdRender, w: *std.Io.Writer, block: *const tmd.Block, usage: contentUsage) !void {
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
                    .plaintext => blk: {
                        if (tracker.activeLinkInfo) |linkInfo| {
                            const link = linkInfo.link;
                            const url = link.url orelse unreachable;
                            if (token != link.firstContentToken) {
                                std.debug.assert(url.manner != .footnote);

                                if (token == url.sourceContentToken) break :blk;
                            } else if (url.manner == .footnote) {
                                if (usage == .general) {
                                    //if (tracker.linkFootnote.block) |_| {
                                    //    try w.print("[{}]", .{tracker.linkFootnote.orderIndex});
                                    //} else {
                                    //    try w.print("[{}]?", .{tracker.linkFootnote.orderIndex});
                                    //}
                                    if (tracker.linkFootnote) |ft| {
                                        std.debug.assert(tracker.brokenLinkConfirmed == (ft.block == null));
                                        const sign = if (tracker.brokenLinkConfirmed) "?" else "";
                                        try w.print("[{}]{s}", .{ ft.orderIndex, sign });
                                    } else {
                                        try w.print("[...]", .{});
                                    }
                                }
                                break :blk;
                            }
                        }
                        const text = self.doc.rangeData(token.range());
                        try fns.writeHtmlContentText(w, text);
                    },
                    .evenBackticks => |m| {
                        if (m.more.secondary) {
                            //try w.writeAll("&ZeroWidthSpace;"); // ToDo: write the code utf value instead

                            for (0..m.more.pairCount) |_| {
                                try w.writeAll("`");
                            }
                        } else if (m.more.pairCount > 1) {
                            if (usage == .noStyling) {
                                try w.writeAll(" "); // ToDo: why?
                            } else for (1..m.more.pairCount) |_| {
                                //try w.writeAll("&nbsp;");
                                try w.writeAll("&#160;"); // better in epub
                            }
                        }
                    },
                    .linkInfo => {}, // unreachable, // still some cases go here
                    .spanMark => |*m| {
                        if (m.more.blankSpan) {
                            // skipped
                        } else if (m.more.open) {
                            const markElement = &tracker.markStatusElements[m.markType.asInt()];
                            std.debug.assert(markElement.value.mark == null);

                            markElement.value.mark = m;
                            if (m.markType == .hyperlink and !m.more.secondary) {
                                std.debug.assert(tracker.activeLinkInfo == null);

                                const linkInfoElement = tokenElement.next.?;
                                const linkInfoToken = &linkInfoElement.value;
                                std.debug.assert(linkInfoToken.* == .linkInfo);
                                tracker.onLinkInfo(&linkInfoToken.linkInfo);

                                tracker.marksStack.pushHead(markElement);
                                try writeCloseMarks(w, markElement, usage);

                                const linkInfo = tracker.activeLinkInfo orelse unreachable;
                                const link = linkInfo.link;
                                if (usage == .general) blk: {
                                    const url = link.url orelse unreachable;
                                    if (url.manner == .footnote) {
                                        std.debug.assert(link.url != null);
                                        std.debug.assert(url.fragment.len > 0);
                                        //std.debug.assert(url.sourceContentToken != null);

                                        //const t = url.sourceContentToken.?;
                                        //const linkURL = tmd.trimBlanks(self.doc.rangeData(t.range()));

                                        //const footnote_id = linkURL[1..];
                                        const footnote_id = url.fragment[1..];
                                        if (footnote_id.len == 0) {
                                            tracker.linkFootnote = null;

                                            try w.print(
                                                \\<sup><a href="#fn{s}:">
                                            , .{self.options.identSuffix});
                                        } else {
                                            const footnote = try self.onFootnoteReference(footnote_id);
                                            tracker.linkFootnote = footnote;
                                            tracker.brokenLinkConfirmed = footnote.block == null;

                                            if (self.incFootnoteRefWrittenCounts) footnote.refWrittenCount += 1;

                                            try w.print(
                                                \\<sup><a id="fn{s}:{s}:ref-{}" href="#fn{s}:{s}">
                                            , .{ self.options.identSuffix, footnote_id, footnote.refWrittenCount, self.options.identSuffix, footnote_id });
                                        }

                                        break :blk;
                                    }

                                    var isCurrentItemInNav: ?bool = null;
                                    if (try self.getLinkUrlGenerator(link, &isCurrentItemInNav)) |callback| {
                                        if (isCurrentItemInNav) |b| {
                                            if (b) try w.writeAll(
                                                \\<a class="tmd-nav-current" href="
                                            ) else try w.writeAll(
                                                \\<a class="tmd-nav-others" href="
                                            );
                                        } else try w.writeAll(
                                            \\<a href="
                                        );

                                        try callback.gen(w);
                                        try w.writeAll(
                                            \\">
                                        );

                                        break :blk;
                                    }

                                    sw: switch (url.manner) {
                                        .absolute => {
                                            //const fromIndex: usize = if (std.mem.startsWith(u8, url.base, "://")) 1 else 0;
                                            try w.writeAll(
                                                \\<a href="
                                            );
                                            try fns.writeUrlAttributeValue(w, url.base); // url.base[fromIndex..]);
                                            try fns.writeUrlAttributeValue(w, url.fragment);
                                            try w.writeAll(
                                                \\">
                                            );
                                        },
                                        .relative => |v| {
                                            if (v.isTmdFile()) {
                                                const ext = std.fs.path.extension(url.base);
                                                const baseWithoutExt = url.base[0 .. url.base.len - ext.len];
                                                //try w.print(
                                                //    \\<a href="{s}{s}{s}">
                                                //, .{baseWithoutExt, self.options.renderedExtension, url.fragment});

                                                try w.writeAll(
                                                    \\<a href="
                                                );
                                                try fns.writeUrlAttributeValue(w, baseWithoutExt);
                                                try fns.writeUrlAttributeValue(w, self.options.renderedExtension);
                                                try fns.writeUrlAttributeValue(w, url.fragment);
                                                try w.writeAll(
                                                    \\">
                                                );
                                            } else continue :sw .absolute;
                                        },
                                        else => {
                                            try w.writeAll(
                                                \\<span class="tmd-broken-link">
                                            );

                                            tracker.brokenLinkConfirmed = true;
                                        },
                                    }
                                }

                                try writeOpenMarks(w, markElement, usage);

                                element = linkInfoElement.next; // skip the media specification text token
                                continue;
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
                                if (m.more.isBare) {
                                    //try w.writeAll(" "); // uncessary. Medias are not surrounded spaces automatically.
                                    break :blk;
                                }
                                if (usage == .noStyling) break :blk;

                                const isInline = inHeader or block.more.hasNonMediaContentTokens;

                                const linkInfoElement = tokenElement.next.?;
                                const linkInfoToken = &linkInfoElement.value;
                                std.debug.assert(linkInfoToken.* == .linkInfo);

                                const link = linkInfoToken.linkInfo.link;
                                const url = link.url orelse unreachable;
                                writeMedia: {
                                    if (try self.getMediaUrlGenerator(link)) |callback| {
                                        try w.writeAll("<img src=\"");
                                        try callback.gen(w);
                                    } else switch (url.manner) {
                                        .absolute, .relative => {
                                            const src = url.base;
                                            try w.writeAll("<img src=\"");
                                            try fns.writeUrlAttributeValue(w, src);

                                            // ToDo: size info is in url.fragment
                                        },
                                        else => {
                                            break :writeMedia;
                                        },
                                    }

                                    if (isInline) {
                                        try w.writeAll("\" class=\"tmd-inline-media\"/>");
                                    } else {
                                        try w.writeAll("\" class=\"tmd-media\"/>");
                                    }
                                }

                                std.debug.assert(linkInfoElement.next.?.value == .plaintext);
                                element = linkInfoElement.next.?.next; // skip the media specification text token
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
    fn closeMark(w: *std.Io.Writer, m: *tmd.Token.SpanMark, tracker: *MarkStatusesTracker, usage: contentUsage) !void {
        const markElement = &tracker.markStatusElements[m.markType.asInt()];
        std.debug.assert(markElement.value.mark != null);

        done: {
            switch (m.markType) {
                .hyperlink => blk: {
                    const linkInfo = tracker.activeLinkInfo orelse break :blk;
                    tracker.activeLinkInfo = null;
                    const link = linkInfo.link;

                    try writeCloseMarks(w, markElement, usage);

                    if (usage == .general) {
                        //if (link.urlConfirmed()) {
                        //    try w.writeAll("</a>");
                        //    if (link.isFootnote()) {
                        //        try w.writeAll("</sup>");
                        //    }
                        //} else {
                        //    try w.writeAll("</span>");
                        //}

                        if (tracker.brokenLinkConfirmed) {
                            try w.writeAll("</span>");
                        } else {
                            try w.writeAll("</a>");
                            if (link.url.?.manner == .footnote) {
                                try w.writeAll("</sup>");
                            }
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

    fn writeOpenMarks(w: *std.Io.Writer, bottomElement: *MarkStatus.List.Element, usage: contentUsage) !void {
        var next = bottomElement.next;
        while (next) |element| {
            try writeOpenMark(w, element.value.mark.?, usage);
            next = element.next;
        }
    }

    fn writeCloseMarks(w: *std.Io.Writer, bottomElement: *MarkStatus.List.Element, usage: contentUsage) !void {
        var next = bottomElement.next;
        while (next) |element| {
            try writeCloseMark(w, element.value.mark.?, usage);
            next = element.next;
        }
    }

    // ToDo: to optimize by using a table.
    fn writeOpenMark(w: *std.Io.Writer, spanMark: *tmd.Token.SpanMark, usage: contentUsage) !void {
        if (usage == .noStyling) return;

        switch (spanMark.markType) {
            .hyperlink => {
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
    fn writeCloseMark(w: *std.Io.Writer, spanMark: *tmd.Token.SpanMark, usage: contentUsage) !void {
        if (usage == .noStyling) return;

        switch (spanMark.markType) {
            .hyperlink, .fontWeight, .fontStyle, .fontSize, .deleted => {
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

    fn writeTableOfContents(self: *TmdRender, w: *std.Io.Writer, level: u8) !void {
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

    fn writeFootnotes(self: *TmdRender, w: *std.Io.Writer) !void {
        self.incFootnoteRefWrittenCounts = false;

        //var buffer: [4096]u8 = undefined;
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        try self._writeFootnotes(&discarding.writer);

        self.incFootnoteRefWrittenCounts = true;
        self.incFootnoteRefCounts = false;
        try self._writeFootnotes(w);
        self.incFootnoteRefCounts = true; // needless?
    }

    fn _writeFootnotes(self: *TmdRender, w: *std.Io.Writer) !void {
        if (self.footnoteNodes.empty()) return;

        try w.print("\n<ol class=\"tmd-list tmd-footnotes\" id=\"fn{s}:\">\n", .{self.options.identSuffix});

        var listElement = self.footnoteNodes.head;
        while (listElement) |element| {
            defer listElement = element.next;
            const footnote = element.value.value;

            try w.print("<li id=\"fn{s}:{s}\" class=\"tmd-list-item tmd-footnote-item\">\n", .{ self.options.identSuffix, footnote.id });
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
                try w.print("<a href=\"#fn{s}:{s}:ref-{}\">↩︎{s}</a>", .{ self.options.identSuffix, footnote.id, n, missing_flag });
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
            \\{%%
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

        var doc = try @import("tmd_to_doc.zig").parse_tmd(example1, std.testing.allocator);
        defer doc.destroy();

        var r = TmdRender{
            .doc = &doc,
            .allocator = std.testing.allocator,
            .options = .{},
        };

        var discarding: std.Io.Writer.Discarding = .init(&.{});
        try r._render(&discarding.writer, false);
        defer r.cleanup();

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
