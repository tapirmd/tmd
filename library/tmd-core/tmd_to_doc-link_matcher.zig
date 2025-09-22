const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd.zig");
const list = @import("list");
const tree = @import("tree");

const AttributeParser = @import("tmd_to_doc-attribute_parser.zig");
const DocParser = @import("tmd_to_doc-doc_parser.zig");

const LinkMatcher = @This();

tmdData: []const u8,
links: *list.List(tmd.Link),
urls: *list.List(tmd.URL),
allocator: std.mem.Allocator,

pub fn init(doc: *tmd.Doc) LinkMatcher {
    return LinkMatcher{
        .tmdData = doc.data,
        .links = &doc.links,
        .urls = &doc._urls,
        .allocator = doc.allocator,
    };
}

fn tokenAsString(self: *const LinkMatcher, contentToken: *const tmd.Token) []const u8 {
    return self.tmdData[contentToken.start()..contentToken.end()];
}

fn copyLinkText(dst: anytype, from: u32, src: []const u8) u32 {
    var n: u32 = from;
    for (src) |r| {
        std.debug.assert(r != '\n');
        if (dst.set(n, r)) n += 1;
    }
    return n;
}

const DummyLinkText = struct {
    pub fn set(_: *DummyLinkText, _: u32, r: u8) bool {
        return !tmd.bytesKindTable[r].isBlank();
    }
};

const RealLinkText = struct {
    text: [*]u8,
    dummy: DummyLinkText = .{},
    pub fn set(self: *RealLinkText, n: u32, r: u8) bool {
        if (self.dummy.set(n, r)) {
            self.text[n] = r;
            return true;
        }
        return false;
    }
};

const RevisedLinkText = struct {
    len: u32 = 0,
    text: [*]const u8 = "".ptr,

    pub fn at(self: *const RevisedLinkText, n: u32) u8 {
        std.debug.assert(n < self.len);
        return self.text[n];
    }

    pub fn suffix(self: *const RevisedLinkText, from: u32) RevisedLinkText {
        std.debug.assert(from < self.len); // deliborately not <=
        return RevisedLinkText{
            .len = self.len - from,
            .text = self.text + from,
        };
    }

    pub fn prefix(self: *const RevisedLinkText, to: u32) RevisedLinkText {
        std.debug.assert(to < self.len); // deliborately not <=
        return RevisedLinkText{
            .len = to,
            .text = self.text,
        };
    }

    pub fn unprefix(self: *const RevisedLinkText, unLen: u32) RevisedLinkText {
        return RevisedLinkText{
            .len = self.len + unLen,
            .text = self.text - unLen,
        };
    }

    pub fn asString(self: *const RevisedLinkText) []const u8 {
        return self.text[0..self.len];
    }

    pub fn invert(t: *const RevisedLinkText) InvertedRevisedLinkText {
        return InvertedRevisedLinkText{
            .len = t.len,
            .text = t.text + t.len - 1, // -1 is to make some conveniences
        };
    }
};

const InvertedRevisedLinkText = struct {
    len: u32 = 0,
    text: [*]const u8 = "".ptr,

    pub fn at(self: *const InvertedRevisedLinkText, n: u32) u8 {
        std.debug.assert(n < self.len);
        return (self.text - n)[0];
    }

    pub fn suffix(self: *const InvertedRevisedLinkText, from: u32) InvertedRevisedLinkText {
        std.debug.assert(from < self.len);
        return InvertedRevisedLinkText{
            .len = self.len - from,
            .text = self.text - from,
        };
    }

    pub fn prefix(self: *const InvertedRevisedLinkText, to: u32) InvertedRevisedLinkText {
        std.debug.assert(to < self.len);
        return InvertedRevisedLinkText{
            .len = to,
            .text = self.text,
        };
    }

    pub fn unprefix(self: *const InvertedRevisedLinkText, unLen: u32) InvertedRevisedLinkText {
        return InvertedRevisedLinkText{
            .len = self.len + unLen,
            .text = self.text + unLen,
        };
    }

    pub fn asString(self: *const InvertedRevisedLinkText) []const u8 {
        return (self.text - self.len + 1)[0..self.len];
    }
};

fn Patricia(comptime TextType: type) type {
    return struct {
        allocator: std.mem.Allocator,

        topTree: Tree = .{},
        nilNode: Node = rbtree.MakeNilNode(),

        freeNodeList: ?*Node = null,

        _debugAlloctedNodeCount: usize = 0,
        _debugFreeNodeCount: usize = 0,

        const rbtree = tree.RedBlack(NodeValue, NodeValue);
        const Tree = rbtree.Tree;
        const Node = rbtree.Node;

        fn init(self: *@This()) void {
            self.topTree.init(&self.nilNode);
        }

        fn deinit(self: *@This()) void {
            self.clear();
            std.debug.assert(self._debugAlloctedNodeCount == self._debugFreeNodeCount);

            var count: usize = 0;
            while (self.tryToGetFreeNode()) |node| {
                self.allocator.destroy(node);
                count += 1;
            }
            std.debug.assert(self._debugAlloctedNodeCount == count);
            std.debug.assert(self._debugFreeNodeCount == 0);
        }

        fn clear(self: *@This()) void {
            const PatriciaTree = @This();

            const NodeHandler = struct {
                t: *PatriciaTree,

                pub fn onNode(h: *@This(), node: *Node) void {
                    node.value.deeperTree.traverseNodes(h);
                    //node.value = .{};
                    h.t.freeNode(node);
                }
            };

            var handler = NodeHandler{ .t = self };
            self.topTree.traverseNodes(&handler);
            self.topTree.reset();
        }

        fn tryToGetFreeNode(self: *@This()) ?*Node {
            if (self.freeNodeList) |node| {
                if (node.value.deeperTree.count == 0) { // mean next == null
                    self.freeNodeList = null;
                } else { // count == 1 means next free node != null
                    std.debug.assert(node.value.deeperTree.count == 1);
                    self.freeNodeList = node.value.deeperTree.root;
                    node.value.deeperTree.count = 0;
                }
                self._debugFreeNodeCount -= 1;
                return node;
            }
            return null;
        }

        fn getFreeNode(self: *@This()) !*Node {
            const n = self.tryToGetFreeNode() orelse blk: {
                self._debugAlloctedNodeCount += 1;
                break :blk try self.allocator.create(Node);
            };

            n.* = .{
                .value = .{},
            };
            n.value.init(&self.nilNode);

            //n.value.textSegment is undefined (deliborately).
            //std.debug.assert(n.value.textSegment.len == 0);
            std.debug.assert(n.value.deeperTree.count == 0);
            std.debug.assert(n.value.links.empty());

            return n;
        }

        fn freeNode(self: *@This(), node: *Node) void {
            //std.debug.assert(node.value.links.empty());

            node.value.textSegment.len = 0;
            if (self.freeNodeList) |old| {
                node.value.deeperTree.root = old;
                node.value.deeperTree.count = 1;
            } else {
                node.value.deeperTree.count = 0;
            }
            self.freeNodeList = node;

            self._debugFreeNodeCount += 1;
        }

        const NodeValue = struct {
            textSegment: TextType = undefined,
            links: list.List(*tmd.Link) = .{},
            deeperTree: Tree = .{},

            fn init(self: *@This(), nilNodePtr: *Node) void {
                self.deeperTree.init(nilNodePtr);
            }

            // ToDo: For https://github.com/ziglang/zig/issues/18478,
            //       this must be marked as public.
            pub fn compare(x: @This(), y: @This()) isize {
                if (x.textSegment.len == 0 and y.textSegment.len == 0) return 0;
                if (x.textSegment.len == 0) return -1;
                if (y.textSegment.len == 0) return 1;
                return @as(isize, x.textSegment.at(0)) - @as(isize, y.textSegment.at(0));
            }

            fn commonPrefixLen(x: *const @This(), y: *const @This()) u32 {
                const lx = x.textSegment.len;
                const ly = y.textSegment.len;
                const n = if (lx < ly) lx else ly;
                for (0..n) |i| {
                    const k: u32 = @intCast(i);
                    if (x.textSegment.at(k) != y.textSegment.at(k)) {
                        return k;
                    }
                }
                return n;
            }
        };

        fn putLinkInfo(self: *@This(), text: TextType, linkElement: *list.List(*tmd.Link).Element) !void {
            var node = try self.getFreeNode();
            node.value.textSegment = text;

            var n = try self.putNodeIntoTree(&self.topTree, node);
            if (n != node) self.freeNode(node);

            // ToDo: also free text ... ?

            n.value.links.pushTail(linkElement);
        }

        fn putNodeIntoTree(self: *@This(), theTree: *Tree, node: *Node) !*Node {
            const n = theTree.insert(node);
            //std.debug.print("   111, theTree.root.text={s}\n", .{theTree.root.value.textSegment.asString()});
            //std.debug.print("   111, n.value.textSegment={s}, {}\n", .{ n.value.textSegment.asString(), n.value.textSegment.len });
            //std.debug.print("   111, node.value.textSegment={s}, {}\n", .{ node.value.textSegment.asString(), node.value.textSegment.len });
            if (n == node) { // node is added successfully
                return n;
            }

            // n is an old already existing node.

            const k = NodeValue.commonPrefixLen(&n.value, &node.value);
            std.debug.assert(k <= n.value.textSegment.len);
            std.debug.assert(k <= node.value.textSegment.len);

            //std.debug.print("   222 k={}\n", .{k});

            if (k == n.value.textSegment.len) {
                //std.debug.print("   333 k={}\n", .{k});
                if (k == node.value.textSegment.len) {
                    return n;
                }

                //std.debug.print("   444 k={}\n", .{k});
                // k < node.value.textSegment.len

                node.value.textSegment = node.value.textSegment.suffix(k);
                return self.putNodeIntoTree(&n.value.deeperTree, node);
            }

            //std.debug.print("   555 k={}\n", .{k});
            // k < n.value.textSegment.len

            if (k == node.value.textSegment.len) {
                //std.debug.print("   666 k={}\n", .{k});

                n.fillNodeWithoutValue(node);

                if (!theTree.checkNilNode(n.parent)) {
                    if (n == n.parent.left) n.parent.left = node else n.parent.right = node;
                }
                if (!theTree.checkNilNode(n.left)) n.left.parent = node;
                if (!theTree.checkNilNode(n.right)) n.right.parent = node;
                if (n == theTree.root) theTree.root = node;

                n.value.textSegment = n.value.textSegment.suffix(k);
                _ = try self.putNodeIntoTree(&node.value.deeperTree, n);
                std.debug.assert(node.value.deeperTree.count == 1);

                return node;
            }
            // k < node.value.textSegment.len

            var newNode = try self.getFreeNode();
            newNode.value.textSegment = node.value.textSegment.prefix(k);
            n.fillNodeWithoutValue(newNode);

            //std.debug.print("   777 k={}, newNode.text={s}\n", .{ k, newNode.value.textSegment.asString() });

            if (!theTree.checkNilNode(n.parent)) {
                if (n == n.parent.left) n.parent.left = newNode else n.parent.right = newNode;
            }
            if (!theTree.checkNilNode(n.left)) n.left.parent = newNode;
            if (!theTree.checkNilNode(n.right)) n.right.parent = newNode;
            if (n == theTree.root) theTree.root = newNode;

            n.value.textSegment = n.value.textSegment.suffix(k);
            _ = try self.putNodeIntoTree(&newNode.value.deeperTree, n);

            //std.debug.print("   888 count={}\n", .{newNode.value.deeperTree.count});
            std.debug.assert(newNode.value.deeperTree.count == 1);
            defer std.debug.assert(newNode.value.deeperTree.count == 2);
            //defer std.debug.print("   999 count={}\n", .{newNode.value.deeperTree.count});

            node.value.textSegment = node.value.textSegment.suffix(k);
            return self.putNodeIntoTree(&newNode.value.deeperTree, node);
        }

        fn searchLinkInfo(self: *const @This(), text: TextType, prefixMatching: bool) ?*Node {
            var theText = text;
            var theTree = &self.topTree;
            while (true) {
                const nodeValue = NodeValue{ .textSegment = theText };
                if (theTree.search(nodeValue)) |n| {
                    const k = NodeValue.commonPrefixLen(&n.value, &nodeValue);
                    if (n.value.textSegment.len < theText.len) {
                        if (k < n.value.textSegment.len) break;
                        std.debug.assert(k == n.value.textSegment.len);
                        theTree = &n.value.deeperTree;
                        theText = theText.suffix(k);
                        continue;
                    } else {
                        if (k < theText.len) break;
                        std.debug.assert(k == theText.len);
                        if (prefixMatching) return n;
                        if (n.value.textSegment.len == theText.len) return n;
                        break;
                    }
                } else break;
            }
            return null;
        }

        //fn setUrlSourceForNode(node: *Node, urlSource: ?*tmd.Token, confirmed: bool) void {
        //    var le = node.value.links.head;
        //    while (le) |linkInfoElement| {
        //        if (!linkInfoElement.value.urlSourceSet()) {
        //            linkInfoElement.value.setSourceOfURL(urlSource, confirmed);
        //        }
        //        le = linkInfoElement.next;
        //    }
        //
        //    if (node.value.deeperTree.count == 0) {
        //        // ToDo: delete the node (not necessarily).
        //    }
        //}

        fn setUrlSourceForNode(node: *Node, url: *tmd.URL) void {
            var le = node.value.links.head;
            while (le) |linkInfoElement| {
                if (linkInfoElement.value.url == null) {
                    linkInfoElement.value.url = url;
                }
                le = linkInfoElement.next;
            }

            if (node.value.deeperTree.count == 0) {
                // ToDo: delete the node (not necessarily).
            }
        }

        //fn setUrlSourceForTreeNodes(theTree: *Tree, urlSource: ?*tmd.Token, confirmed: bool) void {
        //    const NodeHandler = struct {
        //        urlSource: ?*tmd.Token,
        //        confirmed: bool,
        //
        //        pub fn onNode(h: @This(), node: *Node) void {
        //            setUrlSourceForTreeNodes(&node.value.deeperTree, h.urlSource, h.confirmed);
        //            setUrlSourceForNode(node, h.urlSource, h.confirmed);
        //        }
        //    };
        //
        //    const handler = NodeHandler{ .urlSource = urlSource, .confirmed = confirmed };
        //    theTree.traverseNodes(handler);
        //}

        fn setUrlSourceForTreeNodes(theTree: *Tree, url: *tmd.URL) void {
            const NodeHandler = struct {
                url: *tmd.URL,

                pub fn onNode(h: @This(), node: *Node) void {
                    setUrlSourceForTreeNodes(&node.value.deeperTree, h.url);
                    setUrlSourceForNode(node, h.url);
                }
            };

            const handler = NodeHandler{ .url = url };
            theTree.traverseNodes(handler);
        }
    };
}

const LinkForTree = struct {
    linkInfoElementNormal: list.List(*tmd.Link).Element,
    linkInfoElementInverted: list.List(*tmd.Link).Element,
    revisedLinkText: RevisedLinkText,

    const List = list.List(@This());

    fn setLinkAndText(self: *@This(), link: *tmd.Link, text: RevisedLinkText) void {
        self.linkInfoElementNormal.value = link;
        self.linkInfoElementInverted.value = link;
        self.revisedLinkText = text;
    }

    fn getLink(self: *const @This()) *tmd.Link {
        std.debug.assert(self.linkInfoElementNormal.value == self.linkInfoElementInverted.value);
        return self.linkInfoElementNormal.value;
    }
};

fn destroyRevisedLinkText(link: *LinkForTree, a: std.mem.Allocator) void {
    a.free(link.revisedLinkText.asString());
}

const NormalPatricia = Patricia(RevisedLinkText);
const InvertedPatricia = Patricia(InvertedRevisedLinkText);

const Matcher = struct {
    normalPatricia: *NormalPatricia,
    invertedPatricia: *InvertedPatricia,

    fn doForLinkDefinition(self: @This(), linkDef: *LinkForTree) void {
        const link = linkDef.getLink();
        std.debug.assert(link.owner == .block);

        //const urlSource = link.url.sourceText.?;
        //const confirmed = link.urlConfirmed();
        const url = link.url.?;

        const linkText = linkDef.revisedLinkText.asString();

        // ToDo: require that the ending "..." must be amtomic?
        const ddd = "...";
        if (std.mem.endsWith(u8, linkText, ddd)) {
            if (linkText.len == ddd.len) {
                // all matching

                //NormalPatricia.setUrlSourceForTreeNodes(&self.normalPatricia.topTree, urlSource, confirmed);
                ////InvertedPatricia.setUrlSourceForTreeNodes(&self.invertedPatricia.topTree, urlSource, confirmed);
                NormalPatricia.setUrlSourceForTreeNodes(&self.normalPatricia.topTree, url);
                //InvertedPatricia.setUrlSourceForTreeNodes(&self.invertedPatricia.topTree, url);

                self.normalPatricia.clear();
                self.invertedPatricia.clear();
            } else {
                // prefix matching

                const revisedLinkText = linkDef.revisedLinkText.prefix(linkDef.revisedLinkText.len - @as(u32, ddd.len));
                if (self.normalPatricia.searchLinkInfo(revisedLinkText, true)) |node| {
                    //NormalPatricia.setUrlSourceForTreeNodes(&node.value.deeperTree, urlSource, confirmed);
                    //NormalPatricia.setUrlSourceForNode(node, urlSource, confirmed);
                    NormalPatricia.setUrlSourceForTreeNodes(&node.value.deeperTree, url);
                    NormalPatricia.setUrlSourceForNode(node, url);
                }
            }
        } else {
            if (std.mem.startsWith(u8, linkText, ddd)) {
                // suffix matching

                const revisedLinkText = linkDef.revisedLinkText.suffix(@intCast(ddd.len));
                if (self.invertedPatricia.searchLinkInfo(revisedLinkText.invert(), true)) |node| {
                    //InvertedPatricia.setUrlSourceForTreeNodes(&node.value.deeperTree, urlSource, confirmed);
                    //InvertedPatricia.setUrlSourceForNode(node, urlSource, confirmed);
                    InvertedPatricia.setUrlSourceForTreeNodes(&node.value.deeperTree, url);
                    InvertedPatricia.setUrlSourceForNode(node, url);
                }
            } else {
                // exact matching

                if (self.normalPatricia.searchLinkInfo(linkDef.revisedLinkText, false)) |node| {
                    //NormalPatricia.setUrlSourceForNode(node, urlSource, confirmed);
                    NormalPatricia.setUrlSourceForNode(node, url);
                }
            }
        }
    }
};

fn setLinkURL(self: *const LinkMatcher, link: *tmd.Link, url: tmd.URL) !*tmd.URL {
    std.debug.assert(link.url == null);

    const urlElement = try self.urls.createElement(self.allocator, true);
    urlElement.value = url;
    link.url = &urlElement.value;

    return &urlElement.value;
}

pub fn matchLinks(self: *const LinkMatcher) !void {
    const links = self.links;
    var linkElement = links.head orelse return;

    var linksForTree: LinkForTree.List = .{};
    defer linksForTree.destroy(destroyRevisedLinkText, self.allocator);

    var normalPatricia = NormalPatricia{ .allocator = self.allocator };
    normalPatricia.init();
    defer normalPatricia.deinit();

    var invertedPatricia = InvertedPatricia{ .allocator = self.allocator };
    invertedPatricia.init();
    defer invertedPatricia.deinit();

    const matcher = Matcher{
        .normalPatricia = &normalPatricia,
        .invertedPatricia = &invertedPatricia,
    };

    // The top-to-bottom pass.
    while (true) {
        const link = &linkElement.value;
        std.debug.assert(link.url == null);
        blk: {
            const firstTextToken = if (link.firstPlainText) |first| first else {
                // The link should be ignored in rendering.

                //std.debug.print("ignored for no content tokens\n", .{});
                //link.setSourceOfURL(null, true);
                _ = try self.setLinkURL(link, AttributeParser.parseLinkURL("", false));

                if (link.linkBlock()) |linkBlock| {
                    if (linkBlock.isBare()) {
                        normalPatricia.clear();
                        invertedPatricia.clear();

                        //const theElement = try self.allocator.create(LinkForTree.List.Element);
                        //linksForTree.pushTail(theElement);
                        const theElement = try linksForTree.createElement(self.allocator, true);
                        theElement.value.setLinkAndText(link, .{});
                    }
                }

                break :blk;
            };

            var linkTextLen: u32 = 0;
            var lastToken = firstTextToken;
            // count sum length without the last text token
            var dummyLinkText = DummyLinkText{};
            while (lastToken.content.nextInLink) |nextToken| {
                defer lastToken = nextToken;
                const str = self.tokenAsString(lastToken);
                linkTextLen = copyLinkText(&dummyLinkText, linkTextLen, str);
            }

            // handle the last text token
            {
                const str = tmd.trimBlanks(self.tokenAsString(lastToken));
                if (link.linkBlock() != null) {
                    if (copyLinkText(&dummyLinkText, 0, str) == 0) {
                        // This link definition will be ignored.

                        //std.debug.print("ignored for blank link definition\n", .{});
                        //link.setSourceOfURL(null, false);
                        _ = try self.setLinkURL(link, AttributeParser.parseLinkURL("", false));
                        break :blk;
                    }
                } else {
                    //if (AttributeParser.isValidLinkURL(str)) {
                    //    // For built-in cases, no need to call callback to determine the url.
                    //
                    //    //std.debug.print("self defined url: {s}\n", .{str});
                    //    link.setSourceOfURL(lastToken, true);
                    //
                    //    if (lastToken == firstTextToken and std.mem.startsWith(u8, str, "#") and !std.mem.startsWith(u8, str[1..], "#")) {
                    //        link.setFootnoteManner();
                    //    }
                    //
                    //    break :blk;
                    //}
                    const url = AttributeParser.parseLinkURL(str, lastToken == firstTextToken);
                    if (url.manner != .undetermined) {
                        // This is a self-defined hyperlink.

                        //std.debug.print("self defined url: {s}\n", .{str});
                        (try self.setLinkURL(link, url)).sourceText = lastToken;

                        break :blk;
                    }

                    // The URL of the hyperlink needs to be matched by a link definition
                    // or determined by a custom handler.

                    linkTextLen = copyLinkText(&dummyLinkText, linkTextLen, str);
                }

                if (linkTextLen == 0) {
                    // For link definition, it will not match any hyperlinks.
                    // For hyperlink, it will not match any definitions.

                    //std.debug.print("ignored for blank link text\n", .{});
                    //link.setSourceOfURL(null, true);
                    _ = try self.setLinkURL(link, AttributeParser.parseLinkURL("", false));

                    break :blk;
                }
            }

            // build RevisedLinkText

            const textPtr: [*]u8 = (try self.allocator.alloc(u8, linkTextLen)).ptr;
            const revisedLinkText = RevisedLinkText{
                .len = linkTextLen,
                .text = textPtr,
            };
            //defer std.debug.print("====={}: ||{s}||\n", .{link.linkBlock() != null, revisedLinkText.asString()});

            //const theElement = try self.allocator.create(LinkForTree.List.Element);
            //linksForTree.pushTail(theElement);
            const theElement = try linksForTree.createElement(self.allocator, true);
            theElement.value.setLinkAndText(link, revisedLinkText);
            const linkForTree = &theElement.value;

            const url = while (true) { // ToDo: use a labled non-loop block
                var realLinkText = RealLinkText{
                    .text = textPtr, // == revisedLinkText.text,
                };

                var linkTextLen2: u32 = 0;
                lastToken = firstTextToken;
                // build text data without the last text token
                while (lastToken.content.nextInLink) |nextToken| {
                    defer lastToken = nextToken;
                    const str = self.tokenAsString(lastToken);
                    linkTextLen2 = copyLinkText(&realLinkText, linkTextLen2, str);
                }

                // handle the last text token
                const str = tmd.trimBlanks(self.tokenAsString(lastToken));
                if (link.linkBlock() != null) {
                    std.debug.assert(linkTextLen2 == linkTextLen);

                    //std.debug.print("    222 linkText = {s}\n", .{revisedLinkText.asString()});

                    //std.debug.print("==== /{s}/, {}\n", .{ str, AttributeParserisValidLinkURL(str) });

                    break AttributeParser.parseLinkURL(str, false);
                } else {
                    if (builtin.mode == .Debug) {
                        std.debug.assert(AttributeParser.parseLinkURL(str, false).manner == .undetermined);
                    }

                    // For a link whose url is not built-in determined,
                    // all of its text tokens are used as link texts.

                    linkTextLen2 = copyLinkText(&realLinkText, linkTextLen2, str);
                    std.debug.assert(linkTextLen2 == linkTextLen);

                    //std.debug.print("    111 linkText = {s}\n", .{revisedLinkText.asString()});

                    try normalPatricia.putLinkInfo(revisedLinkText, &linkForTree.linkInfoElementNormal);
                    try invertedPatricia.putLinkInfo(revisedLinkText.invert(), &linkForTree.linkInfoElementInverted);
                    break :blk;
                }
            };

            std.debug.assert(link.linkBlock() != null);

            //link.setSourceOfURL(lastToken, confirmed);
            (try self.setLinkURL(link, url)).sourceText = lastToken;

            matcher.doForLinkDefinition(linkForTree);
        }

        if (linkElement.next) |next| {
            linkElement = next;
        } else break;
    }

    // The bottom-to-top pass.
    {
        normalPatricia.clear();
        invertedPatricia.clear();

        var element = linksForTree.tail;
        while (element) |theElement| {
            const linkForTree = &theElement.value;
            const link = linkForTree.getLink();
            if (link.linkBlock()) |linkBlock| {
                if (linkBlock.isBare()) {
                    normalPatricia.clear();
                    invertedPatricia.clear();
                } else {
                    std.debug.assert(link.url != null);

                    matcher.doForLinkDefinition(linkForTree);
                }
            } else if (link.url == null) {
                try normalPatricia.putLinkInfo(linkForTree.revisedLinkText, &linkForTree.linkInfoElementNormal);
                try invertedPatricia.putLinkInfo(linkForTree.revisedLinkText.invert(), &linkForTree.linkInfoElementInverted);
            }
            element = theElement.prev;
        }
    }

    // The final pass (for still unmatched links).
    {
        var element = linksForTree.head;
        while (element) |theElement| {
            const link = theElement.value.getLink();
            if (link.url == null) {
                //link.setSourceOfURL(link.firstPlainText, false);
                (try self.setLinkURL(link, .{})).sourceText = link.firstPlainText;
            }
            element = theElement.next;
        }
    }
}
