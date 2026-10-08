const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd.zig");

const BlockArranger = @This();

// BlockArranger determines block nesting depths.
//const BlockArranger = struct {
root: *tmd.Block,

stackedBlocks: [tmd.MaxBlockNestingDepth]*tmd.Block = undefined,
count_1: tmd.BlockNestingDepthType = 0,

openingBaseBlocks: [tmd.MaxBlockNestingDepth]BaseContext = undefined,
baseCount_1: tmd.BlockNestingDepthType = 0,

const BaseContext = struct {
    nestingDepth: tmd.BlockNestingDepthType,
    undisplayed: bool,

    openingListNestingDepths: [tmd.MaxListNestingDepthPerBase]u6 = @splat(0),
    openingListCount: tmd.ListNestingDepthType = 0,
    topOpeningListNestingDepth: u6 = undefined,

    explainableBlock: ?*tmd.Block = null,

    // inBlankContainableContainer: bool = false,
};

pub fn tryToSetExplanationBlock(self: *BlockArranger, firstLevelHeaderBlock: *const tmd.Block) void {
    const baseContext = &self.openingBaseBlocks[self.baseCount_1];
    const block = self.stackedBlocks[baseContext.nestingDepth + 1];
    std.debug.assert(block.nestingDepth == baseContext.nestingDepth + 1);

    if (block.type != .quotation) return;
    if (builtin.mode == .debug) if (block.next()) |s| {
        switch (s.type) {
            .header => std.debug.assert(s == firstLevelHeaderBlock),
            .attributes => std.debug.assert(s.nextSibling() == firstLevelHeaderBlock),
            else => unreachable,
        }
    } else unreachable;

    if (baseContext.explainableBlock) |b| {

        //std.debug.print("b.type: {s}\n", .{@tagName(b.type)});

        if (builtin.mode == .debug) if (b.nextSibling()) |s| {
            switch (s.type) {
                .quotation => std.debug.assert(s == block),
                .attributes => std.debug.assert(s.nextSibling() == block),
                .linkdef => {
                    if (s.nextSibling()) |ss| {
                        switch (ss.type) {
                            .quotation => std.debug.assert(s == block),
                            .attributes => std.debug.assert(s.nextSibling() == block),
                            else => unreachable,
                        }
                    }
                },
                else => unreachable,
            }
        } else unreachable;

        b.explanationBlock = block;
        baseContext.explainableBlock = null;
    } else {
        block.explanationBlock = block;
    }
}

test BaseContext {
    std.debug.assert(@bitSizeOf(std.meta.Elem(@FieldType(BaseContext, "openingListNestingDepths"))) > @bitSizeOf(tmd.ListItemTypeIndex));
}

pub fn start(root: *tmd.Block, doc: *tmd.Doc) BlockArranger {
    root.* = .{ .nestingDepth = 0, .type = .{
        .root = .{ .doc = doc },
    } };

    var s = BlockArranger{
        .root = root,
        .count_1 = 1, // because of the fake first child
        .baseCount_1 = 0,
    };
    s.stackedBlocks[0] = root;
    s.openingBaseBlocks[0] = BaseContext{
        .nestingDepth = 0,
        .undisplayed = false,
    };
    s.stackedBlocks[s.count_1] = root; // fake first child (for implementation convenience)
    return s;
}

// This function should not be called deferredly. (Why? for errors?)
pub fn done(self: *BlockArranger) void {
    while (self.tryToCloseCurrentBaseBlock()) |_| {}
}

pub fn canOpenBaseBlock(self: *const BlockArranger) bool {
    if (self.count_1 == tmd.MaxBlockNestingDepth - 1) {
        return false;
    }
    return self.baseCount_1 < tmd.MaxBlockNestingDepth - 1;
}

pub fn canCloseBaseBlock(self: *const BlockArranger) bool {
    return self.baseCount_1 > 0;
}

pub fn openBaseBlock(self: *BlockArranger, newBaseBlock: *tmd.Block, firstInContainer: bool, undisplayed: bool) !void {
    std.debug.assert(newBaseBlock.type == .base);

    if (!self.canOpenBaseBlock()) return error.NestingDepthTooLarge;

    try self.stackAtomBlock(newBaseBlock, firstInContainer);

    const newUndisplayed = undisplayed or self.openingBaseBlocks[self.baseCount_1].undisplayed;
    self.baseCount_1 += 1;
    self.openingBaseBlocks[self.baseCount_1] = BaseContext{
        .nestingDepth = self.count_1,
        .undisplayed = newUndisplayed,
    };

    self.count_1 += 1;
    self.stackedBlocks[self.count_1] = self.root; // fake first child (for implementation convenience).
}

pub fn closeCurrentBaseBlock(self: *BlockArranger) !*tmd.Block {
    if (!self.canCloseBaseBlock()) return error.NoBaseBlockToClose;

    return self.tryToCloseCurrentBaseBlock() orelse unreachable;
}

fn tryToCloseCurrentBaseBlock(self: *BlockArranger) ?*tmd.Block {
    self.clearListContextInBase(true);

    const baseContext = &self.openingBaseBlocks[self.baseCount_1];
    std.debug.assert(self.count_1 > baseContext.nestingDepth);
    const baseBlock = self.stackedBlocks[baseContext.nestingDepth];
    std.debug.assert(baseBlock.type == .base or baseBlock.type == .root);

    const last = self.stackedBlocks[self.count_1];
    std.debug.assert(last.nestingDepth == self.count_1 or last.type == .root);

    if (last.type == .blank) {
        // Ensure the nestingDepth of the blank block.
        last.nestingDepth = baseContext.nestingDepth + 1;
    }

    self.count_1 = baseContext.nestingDepth;
    if (self.baseCount_1 == 0) {
        return null;
    }
    self.baseCount_1 -= 1;
    return baseBlock;
}

//fn stackAsChildOfBase(self: *BlockArranger, block: *tmd.Block, isBlankContainableContainer: bool) !void {
fn stackAsChildOfBase(self: *BlockArranger, block: *tmd.Block) !void {
    const baseContext = &self.openingBaseBlocks[self.baseCount_1];
    std.debug.assert(self.count_1 > baseContext.nestingDepth);
    std.debug.assert(self.stackedBlocks[baseContext.nestingDepth].type == .base or self.stackedBlocks[baseContext.nestingDepth].type == .root);

    if (baseContext.nestingDepth >= tmd.MaxBlockNestingDepth - 1) {
        return error.NestingDepthTooLarge;
    }

    self.clearListContextInBase(false); // here, if the last is a blank, its nestingDepth will be adjusted.

    self.count_1 = baseContext.nestingDepth + 1;

    const last = self.stackedBlocks[self.count_1];
    std.debug.assert(last.nestingDepth == self.count_1 or last.type == .root);
    if (last.type != .root) last.setNextSibling(block);

    block.nestingDepth = self.count_1;
    self.stackedBlocks[self.count_1] = block;

    switch (block.type) {
        .attributes, .linkdef, .quotation => {},
        .item => unreachable,
        else => self.openingBaseBlocks[self.baseCount_1].explainableBlock = block,
    }

    // baseContext.inBlankContainableContainer = isBlankContainableContainer;
}

pub fn shouldHeaderChildBeInTOC(self: *BlockArranger, titleNotDeterminedYet: bool) bool {
    return self.stackedBlocks[self.count_1].nestingDepth - 1 == self.baseCount_1 and (titleNotDeterminedYet or !self.openingBaseBlocks[self.baseCount_1].undisplayed);
}

// for non-list-item containers.
//pub fn stackContainerBlock(self: *BlockArranger, block: *tmd.Block, blankContainable: bool) !void {
pub fn stackContainerBlock(self: *BlockArranger, block: *tmd.Block) !void {
    std.debug.assert(block.isContainer());
    std.debug.assert(block.type != .item);

    //try self.stackAsChildOfBase(block, blankContainable);
    try self.stackAsChildOfBase(block);
}

fn assertBaseOpeningListCount(self: *BlockArranger) void {
    if (builtin.mode == .debug) {
        var baseContext = &self.openingBaseBlocks[self.baseCount_1];

        var count: @TypeOf(baseContext.openingListCount) = 0;
        for (&baseContext.openingListNestingDepths) |d| {
            if (d != 0) count += 1;
        }
        //std.debug.print("==== {} : {}\n", .{ count, baseContext.openingListCount });
        std.debug.assert(count == baseContext.openingListCount);

        if (baseContext.openingListCount > 0) {
            //std.debug.print("assertBaseOpeningListCount {}, {} + {} + 1\n", .{ self.count_1, baseContext.nestingDepth, baseContext.openingListCount });

            //std.debug.assert(self.count_1 == baseContext.nestingDepth + baseContext.openingListCount + 1);
            std.debug.assert(self.count_1 == baseContext.topOpeningListNestingDepth + baseContext.openingListCount);
        }
    }
}

// Returns whether or not a new list should be created.
pub fn shouldCreateNewList(self: *BlockArranger, markTypeIndex: tmd.ListItemTypeIndex) bool {
    const baseContext = &self.openingBaseBlocks[self.baseCount_1];
    std.debug.assert(self.count_1 > baseContext.nestingDepth);

    return baseContext.openingListCount == 0 or baseContext.openingListNestingDepths[markTypeIndex] == 0;
}

// listBlock != null means this is the first item in list.
pub fn stackListItemBlock(self: *BlockArranger, listItemBlock: *tmd.Block, markTypeIndex: tmd.ListItemTypeIndex, listBlock: ?*tmd.Block) !void {
    std.debug.assert(listItemBlock.type == .item);

    self.assertBaseOpeningListCount();

    const baseContext = &self.openingBaseBlocks[self.baseCount_1];
    std.debug.assert(self.count_1 > baseContext.nestingDepth);

    const newListItem = &listItemBlock.type.item;

    if (listBlock) |theListBlock| {
        // baseContext.inBlankContainableContainer = false;

        std.debug.assert(theListBlock.type.list._itemTypeIndex == markTypeIndex);

        if (baseContext.nestingDepth >= tmd.MaxBlockNestingDepth - 1) {
            return error.NestingDepthTooLarge;
        }

        if (baseContext.openingListCount == 0) { // start list context
            //const last = self.stackedBlocks[self.count_1];
            //self.count_1 = baseContext.nestingDepth + 1;
            //const prevSibling = self.stackedBlocks[self.count_1];
            //if (last.type == .blank and last.nestingDepth != self.count_1) {
            //    prevSibling.setNextSibling(last);
            //    // Ensure the nestingDepth of the blank block.
            //    last.nestingDepth = self.count_1;
            //    // no need to setNextSibling for atom blocks.
            //} else if (prevSibling.type != .root) { // ! Yes, it might be .root temporarily
            //    prevSibling.setNextSibling(theListBlock);
            //}
            try self.stackAtomBlock(theListBlock, false);
            std.debug.assert(theListBlock.nestingDepth == self.count_1);
            baseContext.topOpeningListNestingDepth = self.count_1;
        } else {
            std.debug.assert(baseContext.openingListNestingDepths[markTypeIndex] == 0);
            theListBlock.nestingDepth = self.count_1;

            const last = self.stackedBlocks[self.count_1];
            std.debug.assert(last.nestingDepth == self.count_1 or last.type == .root);
            std.debug.assert(last.type != .item);

            if (last.type == .blank) {
                changeBlankBlockToUsual(last);
            }
        }
        const listNestingDepth = self.count_1;

        //newListItem.isFirst = true;
        //newListItem.firstItem = listItemBlock;
        newListItem.list = theListBlock;

        // The depth of the list is the same as its children.
        listItemBlock.nestingDepth = listNestingDepth;
        self.stackedBlocks[listNestingDepth] = listItemBlock;

        baseContext.openingListNestingDepths[markTypeIndex] = listNestingDepth;
        baseContext.openingListCount += 1;
    } else {
        std.debug.assert(baseContext.openingListNestingDepths[markTypeIndex] != 0);

        const last = self.stackedBlocks[self.count_1];
        std.debug.assert(last.nestingDepth == self.count_1 or last.type == .root);
        std.debug.assert(last.type != .item);

        var deltaCount: @TypeOf(baseContext.openingListCount) = 0;
        var depth = self.count_1 - 1;
        //while (depth > baseContext.nestingDepth) : (depth -= 1) {
        while (depth >= baseContext.topOpeningListNestingDepth) : (depth -= 1) {
            std.debug.assert(self.stackedBlocks[depth].nestingDepth == depth);
            std.debug.assert(self.stackedBlocks[depth].type == .item);
            var itemBlock = self.stackedBlocks[depth];
            var item = &itemBlock.type.item;
            if (item.list.type.list._itemTypeIndex == markTypeIndex) {
                //newListItem.firstItem = item.firstItem;
                itemBlock.setNextSibling(listItemBlock);
                newListItem.list = item.list;
                break;
            }
            //item.isLast = true;
            item.list.type.list.lastBullet = item.ownerBlock();
            item.list.type.list._lastItemConfirmed = true;
            baseContext.openingListNestingDepths[item.list.type.list._itemTypeIndex] = 0;
            deltaCount += 1;
        }

        std.debug.assert(depth > baseContext.nestingDepth);
        std.debug.assert(baseContext.openingListCount > deltaCount);

        if (deltaCount > 0) {
            baseContext.openingListCount -= deltaCount;

            // if (last.type == .blank) {
            //     // Ensure the nestingDepth of the blank block.
            //     last.nestingDepth = depth + 1;
            //
            //     const lastBulletOfDeeperList = self.stackedBlocks[last.nestingDepth];
            //      lastBulletOfDeeperList.setNextSibling(last);
            // }
        } else {
            std.debug.assert(last.nestingDepth == depth + 1);
        }

        if (last.type == .blank) {
            changeBlankBlockToUsual(last);
        }

        self.count_1 = depth;
        listItemBlock.nestingDepth = self.count_1;
        self.stackedBlocks[self.count_1] = listItemBlock;
    }
}

// ToDo: remove the forClosingBase parameter?
fn clearListContextInBase(self: *BlockArranger, forClosingBase: bool) void {
    _ = forClosingBase; // ToDo: the logic will be a bit simpler but might be unnecessary.

    const baseContext = &self.openingBaseBlocks[self.baseCount_1];
    std.debug.assert(self.count_1 > baseContext.nestingDepth);
    std.debug.assert(self.stackedBlocks[baseContext.nestingDepth].type == .base or self.stackedBlocks[baseContext.nestingDepth].type == .root);

    const last = self.stackedBlocks[self.count_1];
    std.debug.assert(last.nestingDepth == self.count_1 or last.type == .root);
    std.debug.assert(last.type != .item);
    defer {
        self.count_1 = baseContext.nestingDepth + 1;
        if (last.type == .blank and last.nestingDepth != self.count_1) {
            // prevOfLast might be the last item in a just closed list.
            const prevOfLast = self.stackedBlocks[self.count_1];
            std.debug.assert(prevOfLast.nestingDepth == self.count_1 or prevOfLast.type == .root);
            if (prevOfLast.type != .root) prevOfLast.setNextSibling(last);

            // Ensure the nestingDepth of the blank block.
            last.nestingDepth = self.count_1;
            self.stackedBlocks[self.count_1] = last;

            self.openingBaseBlocks[self.baseCount_1].explainableBlock = last;
        }
    }

    if (baseContext.openingListCount == 0) {
        return;
    }

    self.assertBaseOpeningListCount();

    {
        var deltaCount: @TypeOf(baseContext.openingListCount) = 0;
        var depth = self.count_1 - 1;
        //while (depth > baseContext.nestingDepth) : (depth -= 1) {
        while (depth >= baseContext.topOpeningListNestingDepth) : (depth -= 1) {
            std.debug.assert(self.stackedBlocks[depth].nestingDepth == depth);
            std.debug.assert(self.stackedBlocks[depth].type == .item);
            var item = &self.stackedBlocks[depth].type.item;
            //item.isLast = true;
            item.list.type.list.lastBullet = item.ownerBlock();
            item.list.type.list._lastItemConfirmed = true;
            baseContext.openingListNestingDepths[item.list.type.list._itemTypeIndex] = 0;
            deltaCount += 1;
        }

        //std.debug.assert(depth == baseContext.nestingDepth);
        std.debug.assert(depth + 1 == baseContext.topOpeningListNestingDepth);
        std.debug.assert(baseContext.openingListCount == deltaCount);
        baseContext.openingListCount = 0;
        baseContext.topOpeningListNestingDepth = undefined;
    }
}

fn stackAsFirstInContainer(self: *BlockArranger, block: *tmd.Block) !void {
    const last = self.stackedBlocks[self.count_1];
    if (builtin.mode == .debug) std.debug.assert(last.isContainer());
    std.debug.assert(last.nestingDepth == self.count_1);

    std.debug.assert(block.type != .blank);

    if (self.count_1 >= tmd.MaxBlockNestingDepth - 1) {
        return error.NestingDepthTooLarge;
    }

    self.count_1 += 1;
    block.nestingDepth = self.count_1;
    self.stackedBlocks[self.count_1] = block;
}

// block can an either atom or base block.
pub fn stackAtomBlock(self: *BlockArranger, block: *tmd.Block, firstInContainer: bool) !void {
    if (builtin.mode == .debug) std.debug.assert(block.isAtom() or block.type == .base or block.type == .list);
    if (firstInContainer) {
        try self.stackAsFirstInContainer(block);
        return;
    }

    const last = self.stackedBlocks[self.count_1];
    std.debug.assert(last.nestingDepth == self.count_1 or last.type == .root);
    std.debug.assert(!last.isContainer());

    //if (last.type == .blank) blk: {
    if (last.type == .blank) {
        std.debug.assert(block.type != .blank);

        //const baseContext = &self.openingBaseBlocks[self.baseCount_1];
        //if (baseContext.inBlankContainableContainer) break :blk;

        //try self.stackAsChildOfBase(block, false);
        try self.stackAsChildOfBase(block);
        return;
    } else if (last.type == .base) {
        last.setNextSibling(block);
    }

    block.nestingDepth = self.count_1;
    self.stackedBlocks[self.count_1] = block;

    if (block.nestingDepth == self.openingBaseBlocks[self.baseCount_1].nestingDepth + 1) {
        switch (block.type) {
            .attributes, .linkdef => {},
            else => self.openingBaseBlocks[self.baseCount_1].explainableBlock = block,
        }
    }
}

pub fn stackFirstLevelHeaderBlock(self: *BlockArranger, block: *tmd.Block, firstInContainer: bool) !void {
    if (firstInContainer) {
        const last = self.stackedBlocks[self.count_1];
        std.debug.assert(last.isContainer());
        std.debug.assert(last.nestingDepth == self.count_1);
        switch (last.type) {
            .item => |*listItem| {
                // listItem.confirmTabItem();
                //listItem.list.type.list.isTab = true;
                if (listItem.list.type.list.listType == .bullets)
                    listItem.list.type.list.listType = .panels;
            },
            else => {},
        }
    } else {
        const last = self.stackedBlocks[self.count_1];
        std.debug.assert(!last.isContainer());
        if (last.type == .attributes) {
            const container = self.stackedBlocks[self.count_1 - 1];
            switch (container.type) {
                .item => |*listItem| {
                    // listItem.confirmTabItem();
                    //listItem.list.type.list.isTab = true;
                    if (listItem.list.type.list.listType == .bullets)
                        listItem.list.type.list.listType = .panels;
                },
                else => {},
            }
        }
    }

    try self.stackAtomBlock(block, firstInContainer);
}
//};

fn changeBlankBlockToUsual(block: *tmd.Block) void {
    switch (block.type) {
        .blank => |bt| {
            const startLine = bt.startLine;
            const endLine = bt.endLine;
            block.type = .{
                .usual = .{
                    .startLine = startLine,
                    .endLine = endLine,
                },
            };
        },
        else => unreachable,
    }
}
