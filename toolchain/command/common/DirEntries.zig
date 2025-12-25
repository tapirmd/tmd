const std = @import("std");

const DirEntries = @This();

top: Entry = .{ .name = undefined, .children = &.{} },

needFreeNames: bool,

fn collectDir(dir: std.fs.Dir, dirEntry: *Entry, allocator: std.mem.Allocator, filter: fn ([]const u8, bool) bool) !void {
    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                if (filter(entry.name, false)) count += 1;
            },
            .directory => {
                if (filter(entry.name, true)) count += 1;
            },
            else => {},
        }
    }

    dirEntry.isNonBlank = false;
    if (count == 0) {
        dirEntry.children = &.{};
    } else {
        var hasFiles = false;
        const children = try allocator.alloc(Entry, count);

        iter.reset();
        var i: usize = 0;
        while (try iter.next()) |e| {
            switch (e.kind) {
                .file => if (filter(e.name, false)) {
                    children[i] = .{ .name = try allocator.dupe(u8, e.name) };
                    children[i].confirmTitle();
                    children[i].isNonBlank = true;
                    hasFiles = true;
                    i += 1;
                },
                .directory => if (filter(e.name, true)) {
                    children[i] = .{ .name = try allocator.dupe(u8, e.name) };
                    children[i].confirmTitle();
                    const subDir = try dir.openDir(e.name, .{ .iterate = true });
                    try collectDir(subDir, &children[i], allocator, filter);
                    hasFiles = hasFiles or children[i].isNonBlank;
                    i += 1;
                },
                else => continue,
            }
        }
        std.debug.assert(i == count);

        dirEntry.children = children;
        dirEntry.isNonBlank = hasFiles;
    }
}

pub fn collectFromRootDir(absPath: []const u8, allocator: std.mem.Allocator, filter: fn ([]const u8, bool) bool) !DirEntries {
    var dir = try std.fs.openDirAbsolute(absPath, .{ .iterate = true });
    defer dir.close();

    var topEntry: Entry = .{
        .name = absPath,
    };

    try collectDir(dir, &topEntry, allocator, filter);

    return .{
        .top = topEntry,
        .needFreeNames = true,
    };
}

// Assume that filepaths have longer lifetime than the returned DirEntries.
// Assume that filepaths have be checked with isValidArticlePath.
pub fn collectFromFilepaths(rootPath: []const u8, absPathIterator: anytype, localAllocator: std.mem.Allocator, allocator: std.mem.Allocator) !DirEntries {
    const EntryInfo = struct {
        name: []const u8,
        childCount: usize = 0,
        parent: ?*@This() = null, // null means this is a child of top

        children: ?[]Entry = null, // null means this a file entry
    };

    var pathToEntries: std.StringHashMap(*EntryInfo) = .init(localAllocator);
    defer {
        var it = pathToEntries.valueIterator();
        while (it.next()) |infoPtrPtr| {
            localAllocator.destroy(infoPtrPtr.*);
        }
        pathToEntries.deinit();
    }

    // pass 1

    var topEntryInfo: EntryInfo = .{
        .name = rootPath,
    };

    while (absPathIterator.next()) |absPath| {
        if (!std.mem.startsWith(u8, absPath, rootPath)) unreachable;
        std.debug.assert(absPath.len > rootPath.len);
        if (absPath[rootPath.len] != std.fs.path.sep) unreachable;

        const relPath = absPath[rootPath.len + 1 ..];
        var remaining = relPath;
        var isDirectory = false;
        var newChild: ?*EntryInfo = null;
        while (remaining.len > 0) {
            defer isDirectory = true;

            const entryPath = remaining;
            const name = if (std.mem.lastIndexOfScalar(u8, remaining, std.fs.path.sep)) |index| blk: {
                std.debug.assert(index > 0);
                defer remaining = remaining[0..index];
                break :blk remaining[index + 1 ..];
            } else blk: {
                defer remaining = "";
                break :blk remaining;
            };

            const r = try pathToEntries.getOrPut(entryPath);
            if (r.found_existing) {
                std.debug.assert(isDirectory);
                if (newChild) |child| {
                    r.value_ptr.*.childCount += 1;
                    child.parent = r.value_ptr.*;
                    newChild = null;
                }
            } else if (isDirectory) {
                const infoPtr = try localAllocator.create(EntryInfo);
                infoPtr.* = .{
                    .name = name,
                    .childCount = 1,
                    .children = &.{},
                };
                r.value_ptr.* = infoPtr;
                if (newChild) |child| {
                    std.debug.assert(child.parent == null);
                    child.parent = infoPtr;
                    newChild = infoPtr;
                } else unreachable;
            } else {
                const infoPtr = try localAllocator.create(EntryInfo);
                infoPtr.* = .{
                    .name = name,
                };
                r.value_ptr.* = infoPtr;
                std.debug.assert(newChild == null);
                newChild = infoPtr;
            }
        } else if (newChild) |child| {
            std.debug.assert(child.parent == null);
            child.parent = &topEntryInfo;
            topEntryInfo.childCount += 1;
        }
    }

    // pass 2

    topEntryInfo.children = try allocator.alloc(Entry, topEntryInfo.childCount);
    topEntryInfo.childCount = 0;

    var it = pathToEntries.valueIterator();
    while (it.next()) |infoPtrPtr| {
        const infoPtr = infoPtrPtr.*;
        if (infoPtr.childCount > 0) {
            infoPtr.children = try allocator.alloc(Entry, infoPtr.childCount);
            infoPtr.childCount = 0;
        }
    }

    // pass 3

    const topEntry: Entry = .{
        .name = topEntryInfo.name,
        .children = topEntryInfo.children,
    };

    it = pathToEntries.valueIterator();
    while (it.next()) |infoPtrPtr| {
        const infoPtr = infoPtrPtr.*;
        if (infoPtr.parent) |parent| {
            if (parent.children) |children| {
                std.debug.assert(parent.childCount < children.len);
                children[parent.childCount] = .{
                    .name = infoPtr.name,
                    .children = infoPtr.children,
                };
                children[parent.childCount].confirmTitle();
                parent.childCount += 1;
            } else unreachable;
        } else unreachable;
    }

    return .{
        .top = topEntry,
        .needFreeNames = false,
    };
}

fn destroyDirEntry(dirEntry: *Entry, allocator: std.mem.Allocator, needFreeNames: bool) void {
    if (dirEntry.children) |children| {
        for (children) |*child| {
            if (child.children) |cc| {
                if (cc.len > 0) destroyDirEntry(child, allocator, needFreeNames);
            }
            if (needFreeNames) allocator.free(child.name);
        }
        if (children.len > 0) allocator.free(children);
    } else unreachable;
}

pub fn deinit(de: *DirEntries, allocator: std.mem.Allocator) void {
    destroyDirEntry(&de.top, allocator, de.needFreeNames);
}

fn sortDirEntry(dirEntry: Entry) void {
    if (dirEntry.children) |children| {
        std.sort.pdq(Entry, children, {}, Entry.compare);
        for (children) |child| {
            if (child.children) |cc| {
                if (cc.len > 0) sortDirEntry(child);
            }
        }
    } else unreachable;
}

pub fn sort(de: *DirEntries) void {
    sortDirEntry(de.top);
}

fn iterateDirEntry(dirEntry: Entry, buffer: []u8, k: usize, handler: anytype, depth: usize) !void {
    if (dirEntry.children) |children| {
        for (children) |child| if (child.isNonBlank) {
            const i = k + child.name.len;
            @memcpy(buffer[k..i], child.name);
            if (child.children) |cc| {
                try handler.onEntry(buffer[0..i], child.title, depth);
                buffer[i] = std.fs.path.sep;
                if (cc.len > 0) try iterateDirEntry(child, buffer, i + 1, handler, depth + 1);
            } else try handler.onEntry(buffer[0..i], null, depth);
        };
    } else unreachable;
}

pub fn iterate(de: *DirEntries, handler: anytype) !void {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const k: usize = if (de.top.name.len > 0 and de.top.name[0] != '.') blk: {
        @memcpy(buffer[0..de.top.name.len], de.top.name);
        buffer[de.top.name.len] = std.fs.path.sep;
        break :blk de.top.name.len + 1;
    } else 0;

    try iterateDirEntry(de.top, &buffer, k, handler, 0);
}

fn confirmTitlePart(text: []const u8) []const u8 {
    var titleOffset: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const c = text[index];
        switch (c) {
            '0'...'9' => index += 1,
            '.', ',' => { // ',' is for German
                if (index == 0) break;
                index += 1;
                titleOffset = index;
            },
            '-', '_' => {
                titleOffset = index + 1;
                break;
            },
            else => break,
        }
    }
    const title = std.mem.trim(u8, text[titleOffset..], &std.ascii.whitespace);
    return if (title.len == 0) text else title;
}

const Entry = struct {
    name: []const u8,
    children: ?[]Entry = null, // null means this is a file entry
    isNonBlank: bool = true, // for files, it must be true.

    title: []const u8 = undefined,

    fn compare(_: void, x: @This(), y: @This()) bool {
        if (x.children) |_| {
            if (y.children) |_| return compareNames(x, y) else return false;
        } else if (y.children) |_| {
            return true;
        } else return compareNames(x, y);
    }

    fn compareNames(x: @This(), y: @This()) bool {
        switch (std.mem.order(u8, x.name, y.name)) {
            .eq => unreachable,
            .lt => return true,
            .gt => return false,
        }
    }

    fn confirmTitle(self: *@This()) void {
        self.title = confirmTitlePart(self.name);
    }
};

test DirEntries {
    // ToDo
}
