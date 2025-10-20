const std = @import("std");

const tmd = @import("tmd.zig");

// ToDo: remove the following parse functions (use tokens instead)?

// Only check id and class names for epub output.
//
// EPUB 3.3 (from ChatGPT):
//
// IDs
// * They must start with a letter (a-z or A-Z) or underscore (_).
// * They can include letters, digits (0-9), hyphens (-), underscores (_), and periods (.).
// * They cannot contain spaces or special characters.
// (However, Grok says colom (:) is allowed in ID.
//
// Class names:
// * They can start with a letter (a-z or A-Z) or an underscore (_).
// * They can include letters, digits (0-9), hyphens (-), underscores (_), and periods (.).
// * They cannot contain spaces or special characters.
//
// Attribute names:
// * Attribute names must begin with a letter (a-z or A-Z) or an underscore (_).
// * They can include letters, digits (0-9), hyphens (-), and underscores (_).
// * They cannot contain spaces or special characters.

// HTML4 spec:
//     ID and NAME tokens must begin with a letter ([A-Za-z]) and
//     may be followed by any number of letters, digits ([0-9]),
//     hyphens ("-"), underscores ("_"), colons (":"), and periods (".").

// Only for ASCII chars in range[0, 127].
const charPropertiesTable = blk: {
    var table = [1]packed struct {
        canBeFirstInID: bool = false,
        canBeInID: bool = false,

        canBeFirstInClassName: bool = false,
        canBeInClassName: bool = false,

        canBeInLanguageName: bool = false,

        canBeInAppName: bool = false,
    }{.{}} ** 128;

    for ('a'..'z' + 1, 'A'..'Z' + 1) |i, j| {
        table[i].canBeFirstInID = true;
        table[j].canBeFirstInID = true;

        table[i].canBeInID = true;
        table[j].canBeInID = true;

        table[i].canBeFirstInClassName = true;
        table[j].canBeFirstInClassName = true;

        table[i].canBeInClassName = true;
        table[j].canBeInClassName = true;
    }

    for ('0'..'9' + 1) |i| {
        table[i].canBeInID = true;
        table[i].canBeInClassName = true;
    }

    // Yes, TapirD is more stricted here. (Why?)
    //for ("_") |i| {
    //    table[i].canBeFirstInID = true;
    //    table[i].canBeFirstInClassName = true;
    //}
    for ("_") |i| {
        table[i].canBeInID = true;
        table[i].canBeFirstInID = true;
        table[i].canBeInClassName = true;
        table[i].canBeFirstInClassName = true;
    }

    // Yes, TapirMD is less stricted here, by extra allowing `:`,
    // to work with TailWind CSS alike frameworks.
    for (".-:") |i| {
        table[i].canBeInID = true;
        table[i].canBeInClassName = true;
    }

    // Any visible chars (not including spaces).
    // Unicode with value >= 128 are also valid.
    for (33..127) |i| {
        table[i].canBeInLanguageName = true;
        table[i].canBeInAppName = true;
    }

    break :blk table;
};

pub fn parse_element_attributes(playload: []const u8) tmd.ElementAttibutes {
    var attrs = tmd.ElementAttibutes{};

    const id = std.meta.fieldIndex(tmd.ElementAttibutes, "id").?;
    const classes = std.meta.fieldIndex(tmd.ElementAttibutes, "classes").?;
    //const kvs = std.meta.fieldIndex(tmd.ElementAttibutes, "kvs").?;

    var lastOrder: isize = -1;
    // var kvList: ?struct {
    //     first: []const u8,
    //     last: []const u8,
    // } = null;

    var it = std.mem.splitAny(u8, playload, " \t");
    var item = it.first(); // ToDo: only use next() is okay.
    parse: while (true) {
        if (item.len != 0) {
            switch (item[0]) {
                '#' => {
                    if (lastOrder >= id) break;
                    if (item.len == 1) break;
                    if (item[1] >= 128 or !charPropertiesTable[item[1]].canBeFirstInID) break;
                    for (item[2..]) |c| {
                        if (c >= 128 or !charPropertiesTable[c].canBeInID) break :parse;
                    }

                    attrs.id = item[1..];
                    lastOrder = id;
                },
                '.' => {
                    // classes can't contain periods, but can contain colons.
                    // (This is TMD specific. HTML4 allows periods in classes).

                    // classes are seperated by semicolons.

                    // ToDo: support .class1 .class2?

                    if (lastOrder >= classes) break;
                    if (item.len == 1) break;
                    var firstInName = true;
                    for (item[1..]) |c| {
                        if (c == ';') {
                            firstInName = true;
                            continue; // seperators (TMD specific)
                        }
                        if (c >= 128) break :parse;
                        if (firstInName) {
                            if (!charPropertiesTable[c].canBeFirstInClassName) break :parse;
                            firstInName = false;
                        } else {
                            if (!charPropertiesTable[c].canBeInClassName) break :parse;
                        }
                    }

                    attrs.classes = item[1..];
                    lastOrder = classes;
                },
                else => {
                    break; // break the loop (kvs is not supported now)

                    // // key-value pairs are seperated by SPACE or TAB chars.
                    // // Key parsing is the same as ID parsing.
                    // // Values containing SPACE and TAB chars must be quoted in `...` (the Go literal string form).
                    //
                    // if (lastOrder > kvs) break;
                    //
                    // if (item.len < 3) break;
                    //
                    // // ToDo: write a more pricise implementation.
                    //
                    // if (std.mem.indexOfScalar(u8, item, '=')) |i| {
                    //     if (0 < i and i < item.len - 1) {
                    //         if (kvList == null) kvList = .{ .first = item, .last = item } else kvList.?.last = item;
                    //     } else break;
                    // } else break;
                    //
                    // lastOrder = kvs;
                },
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }

    // if (kvList) |v| {
    //     const start = @intFromPtr(v.first.ptr);
    //     const end = @intFromPtr(v.last.ptr + v.last.len);
    //     attrs.kvs = v.first.ptr[0 .. end - start];
    // }

    return attrs;
}

test "parse_element_attributes" {
    try std.testing.expectEqualDeep(parse_element_attributes(
        \\
    ), tmd.ElementAttibutes{});

    try std.testing.expectEqualDeep(parse_element_attributes(
        \\#foo .bar;baz
    ), tmd.ElementAttibutes{
        .id = "foo",
        .classes = "bar;baz",
    });

    try std.testing.expectEqualDeep(parse_element_attributes(
        \\#foo .bar-baz
    ), tmd.ElementAttibutes{
        .id = "foo",
        .classes = "bar-baz",
    });

    try std.testing.expectEqualDeep(parse_element_attributes(
        \\#foo .-bar-baz
    ), tmd.ElementAttibutes{
        .id = "foo",
        .classes = "",
    });

    try std.testing.expectEqualDeep(parse_element_attributes(
        \\#foo .;bar;baz
    ), tmd.ElementAttibutes{
        .id = "foo",
        .classes = ";bar;baz",
    });

    try std.testing.expectEqualDeep(parse_element_attributes(
        \\#foo .bar;#baz
    ), tmd.ElementAttibutes{
        .id = "foo",
        .classes = "",
    });

    try std.testing.expectEqualDeep(parse_element_attributes(
        \\#foo .bar;baz bla bla bla ...
    ), tmd.ElementAttibutes{
        .id = "foo",
        .classes = "bar;baz",
    });

    try std.testing.expectEqualDeep(parse_element_attributes(
        \\#?foo .bar
    ), tmd.ElementAttibutes{});

    try std.testing.expectEqualDeep(parse_element_attributes(
        \\.bar;baz #foo
    ), tmd.ElementAttibutes{
        .id = "",
        .classes = "bar;baz",
    });
}

pub fn parse_base_block_open_playload(playload: []const u8) tmd.BaseBlockAttibutes {
    var attrs = tmd.BaseBlockAttibutes{};

    const commentedOut = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "commentedOut").?;
    const horizontalAlign = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "horizontalAlign").?;
    const verticalAlign = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "verticalAlign").?;
    const cellSpans = std.meta.fieldIndex(tmd.BaseBlockAttibutes, "cellSpans").?;

    var lastOrder: isize = -1;

    var it = std.mem.splitAny(u8, playload, " \t");
    var item = it.first();
    parse: while (true) {
        if (item.len != 0) {
            switch (item[0]) {
                '/' => {
                    if (lastOrder >= commentedOut) break;
                    defer lastOrder = commentedOut;

                    if (item.len == 1) break;
                    for (item[1..]) |c| {
                        if (c != '/') break :parse;
                    }
                    attrs.commentedOut = true;
                    return attrs;
                },
                '>', '<' => {
                    if (lastOrder >= horizontalAlign) break;
                    defer lastOrder = horizontalAlign;

                    if (item.len != 2) break;
                    if (item[1] != '>' and item[1] != '<') break;
                    if (std.mem.eql(u8, item, "<<"))
                        attrs.horizontalAlign = .left
                    else if (std.mem.eql(u8, item, ">>"))
                        attrs.horizontalAlign = .right
                    else if (std.mem.eql(u8, item, "><"))
                        attrs.horizontalAlign = .center
                    else if (std.mem.eql(u8, item, "<>"))
                        attrs.horizontalAlign = .justify;
                },
                '^' => {
                    if (lastOrder >= verticalAlign) break;
                    defer lastOrder = verticalAlign;

                    if (item.len != 2) break;
                    if (item[1] != '^') break;
                    attrs.verticalAlign = .top;
                },
                '.' => {
                    if (lastOrder >= cellSpans) break;
                    defer lastOrder = cellSpans;

                    if (item.len < 3) break;
                    if (item[1] != '.') break;
                    const trimDotDot = item[2..];
                    const colonPos = std.mem.indexOfScalar(u8, trimDotDot, ':') orelse trimDotDot.len;
                    if (colonPos == 0 or colonPos == trimDotDot.len - 1) break;
                    const axisSpan = std.fmt.parseInt(u32, trimDotDot[0..colonPos], 10) catch break;
                    const crossSpan = if (colonPos == trimDotDot.len) 1 else std.fmt.parseInt(u32, trimDotDot[colonPos + 1 ..], 10) catch break;
                    attrs.cellSpans = .{
                        .axisSpan = axisSpan,
                        .crossSpan = crossSpan,
                    };
                },
                ':' => {
                    if (lastOrder >= cellSpans) break;
                    defer lastOrder = cellSpans;

                    if (item.len < 2) break;
                    const crossSpan = std.fmt.parseInt(u32, item[1..], 10) catch break;
                    attrs.cellSpans = .{
                        .axisSpan = 1,
                        .crossSpan = crossSpan,
                    };
                },
                else => {
                    break; // break the loop
                },
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }

    return attrs;
}

test "parse_base_block_open_playload" {
    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\
    ), tmd.BaseBlockAttibutes{});

    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\// >> ^^ ..2:3
    ), tmd.BaseBlockAttibutes{
        .commentedOut = true,
    });

    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\>> ^^ ..2:3
    ), tmd.BaseBlockAttibutes{
        .commentedOut = false,
        .horizontalAlign = .right,
        .verticalAlign = .top,
        .cellSpans = .{
            .axisSpan = 2,
            .crossSpan = 3,
        },
    });

    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\>< :3
    ), tmd.BaseBlockAttibutes{
        .commentedOut = false,
        .horizontalAlign = .center,
        .verticalAlign = .none,
        .cellSpans = .{
            .axisSpan = 1,
            .crossSpan = 3,
        },
    });

    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\^^ ..2
    ), tmd.BaseBlockAttibutes{
        .commentedOut = false,
        .horizontalAlign = .none,
        .verticalAlign = .top,
        .cellSpans = .{
            .axisSpan = 2,
            .crossSpan = 1,
        },
    });

    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\<>
    ), tmd.BaseBlockAttibutes{
        .commentedOut = false,
        .horizontalAlign = .justify,
    });

    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\<<
    ), tmd.BaseBlockAttibutes{
        .commentedOut = false,
        .horizontalAlign = .left,
    });

    try std.testing.expectEqualDeep(parse_base_block_open_playload(
        \\^^ <<
    ), tmd.BaseBlockAttibutes{
        .commentedOut = false,
        .verticalAlign = .top,
    });
}

pub fn parse_code_block_open_playload(playload: []const u8) tmd.CodeBlockAttibutes {
    var attrs = tmd.CodeBlockAttibutes{};

    const commentedOut = std.meta.fieldIndex(tmd.CodeBlockAttibutes, "commentedOut").?;
    //const language = std.meta.fieldIndex(tmd.CodeBlockAttibutes, "language").?;

    const lastOrder: isize = -1;

    var it = std.mem.splitAny(u8, playload, " \t");
    var item = it.first();
    parse: while (true) {
        if (item.len != 0) {
            switch (item[0]) {
                '/' => {
                    if (lastOrder >= commentedOut) break;
                    if (item.len == 1) break;
                    for (item[1..]) |c| {
                        if (c != '/') break :parse;
                    }
                    attrs.commentedOut = true;
                    //lastOrder = commentedOut;
                    return attrs;
                },
                else => {
                    for (item[0..]) |c| {
                        //if (c >= 128) break :parse;
                        if (!charPropertiesTable[c].canBeInLanguageName) break :parse;
                    }
                    attrs.language = item;
                    break; // break the loop
                },
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }

    return attrs;
}

test "parse_code_block_open_playload" {
    try std.testing.expectEqualDeep(parse_code_block_open_playload(
        \\
    ), tmd.CodeBlockAttibutes{});

    try std.testing.expectEqualDeep(parse_code_block_open_playload(
        \\// 
    ), tmd.CodeBlockAttibutes{
        .commentedOut = true,
        .language = "",
    });

    try std.testing.expectEqualDeep(parse_code_block_open_playload(
        \\// zig
    ), tmd.CodeBlockAttibutes{
        .commentedOut = true,
        .language = "",
    });

    try std.testing.expectEqualDeep(parse_code_block_open_playload(
        \\zig
    ), tmd.CodeBlockAttibutes{
        .commentedOut = false,
        .language = "zig",
    });

    try std.testing.expectEqualDeep(parse_code_block_open_playload(
        \\zig bla bla bla ...
    ), tmd.CodeBlockAttibutes{
        .commentedOut = false,
        .language = "zig",
    });
}

pub fn parse_code_block_close_playload(playload: []const u8) tmd.ContentStreamAttributes {
    var attrs = tmd.ContentStreamAttributes{};

    var arrowFound = false;
    var content: []const u8 = "";

    var it = std.mem.splitAny(u8, playload, " \t");
    var item = it.first();
    while (true) {
        if (item.len != 0) {
            if (!arrowFound) {
                if (item.len != 2) return attrs;
                for (item) |c| if (c != '<') return attrs;
                arrowFound = true;
            } else if (content.len > 0) {
                // ToDo:
                unreachable;
            } else {
                content = item;
                break; // break the loop
                // ToDo: now only support one stream source.
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }

    attrs.content = content;
    return attrs;
}

test "parse_code_block_close_playload" {
    try std.testing.expectEqualDeep(parse_code_block_close_playload(
        \\
    ), tmd.ContentStreamAttributes{});

    try std.testing.expectEqualDeep(parse_code_block_close_playload(
        \\<<
    ), tmd.ContentStreamAttributes{});

    try std.testing.expectEqualDeep(parse_code_block_close_playload(
        \\<< content
    ), tmd.ContentStreamAttributes{
        .content = "content",
    });

    try std.testing.expectEqualDeep(parse_code_block_close_playload(
        \\<< #id bla bla ...
    ), tmd.ContentStreamAttributes{
        .content = "#id",
    });
}

pub fn parse_custom_block_open_playload(playload: []const u8) tmd.CustomBlockAttibutes {
    var attrs = tmd.CustomBlockAttibutes{};

    const commentedOut = std.meta.fieldIndex(tmd.CustomBlockAttibutes, "commentedOut").?;
    //const app = std.meta.fieldIndex(tmd.CustomBlockAttibutes, "app").?;

    const lastOrder: isize = -1;

    var it = std.mem.splitAny(u8, playload, " \t");
    var item = it.first();
    parse: while (true) {
        if (item.len != 0) {
            switch (item[0]) {
                '/' => {
                    if (lastOrder >= commentedOut) break;
                    if (item.len == 1) break;
                    for (item[1..]) |c| {
                        if (c != '/') break :parse;
                    }
                    attrs.commentedOut = true;
                    //lastOrder = commentedOut;
                    return attrs;
                },
                else => {
                    // ToDo: maybe it is okay to just disallow blank chars in the app name.
                    for (item[0..]) |c| {
                        //if (c >= 128) break :parse;
                        if (!charPropertiesTable[c].canBeInAppName) break :parse;
                    }
                    attrs.app = item;
                    break; // break the loop
                },
            }
        }

        if (it.next()) |next| {
            item = next;
        } else break;
    }

    return attrs;
}

test "parse_custom_block_open_playload" {
    try std.testing.expectEqualDeep(parse_custom_block_open_playload(
        \\
    ), tmd.CustomBlockAttibutes{});

    try std.testing.expectEqualDeep(parse_custom_block_open_playload(
        \\// 
    ), tmd.CustomBlockAttibutes{
        .commentedOut = true,
        .app = "",
    });

    try std.testing.expectEqualDeep(parse_custom_block_open_playload(
        \\// html
    ), tmd.CustomBlockAttibutes{
        .commentedOut = true,
        .app = "",
    });

    try std.testing.expectEqualDeep(parse_custom_block_open_playload(
        \\html
    ), tmd.CustomBlockAttibutes{
        .commentedOut = false,
        .app = "html",
    });

    try std.testing.expectEqualDeep(parse_custom_block_open_playload(
        \\html bla bla bla ...
    ), tmd.CustomBlockAttibutes{
        .commentedOut = false,
        .app = "html",
    });
}

pub const FilePathType = enum {
    invalid,
    local, // included builtin assets now
    remote,
    // builtin, // Todo: now, not support to link to builtin assets.
};

pub fn checkFilePathType(path: []const u8) FilePathType {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\') return .invalid;

    if (std.mem.indexOf(u8, path, "://")) |k| {
        if (k > 0) return .remote else return .invalid;
    }

    return .local;
}

// .relative media urls must end with supported extensions.
// media urls can also have the fragment part.
pub fn parseLinkURL(urlText: []const u8, potentailFootnoteRef: bool) tmd.URL {
    var url: tmd.URL = .{};

    const text = std.mem.trim(u8, urlText, " \t");
    if (std.mem.indexOfAny(u8, text, "#")) |k| {
        url.base = text[0..k];

        if (potentailFootnoteRef and k == 0) url.manner = .footnote;

        url.fragment = text[k..];
    } else {
        url.base = text;
    }

    if (url.manner == .undetermined) {
        const base = url.base;
        if (base.len > 0) {
            switch (checkFilePathType(base)) {
                .remote => url.manner = .absolute,
                .local => {
                    //if (std.mem.indexOfScalar(u8, base, '?') == null) {
                    if (checkValidExtensionAsURL(base)) |ext| {
                        url.manner = .{
                            .relative = .{ .extension = ext },
                        };
                    }
                    //}
                },
                .invalid => {},
            }
        } else if (url.fragment.len > 0) {
            url.manner = .{
                .relative = .{ .extension = null },
            };
        }
    }

    return url;
}

fn compareURLs(a: tmd.URL, b: tmd.URL) bool {
    //if (a.manner != b.manner) return false;
    if (std.meta.activeTag(a.manner) != std.meta.activeTag(b.manner)) return false;
    switch (a.manner) {
        .relative => |v| {
            if (v.extension != b.manner.relative.extension) return false;
        },
        else => {},
    }
    if (!std.mem.eql(u8, a.base, b.base)) return false;
    if (!std.mem.eql(u8, a.fragment, b.fragment)) return false;
    //if (!std.mem.eql(u8, a.title, b.title)) return false;
    return true;
}

test "parseLinkURL" {
    try std.testing.expect(compareURLs(parseLinkURL("http://aaa/foo.png", false), .{
        .manner = .absolute,
        .base = "http://aaa/foo.png",
    }));
    try std.testing.expect(compareURLs(parseLinkURL("//google.com/foo.jpg", false), .{
        .manner = .undetermined,
        .base = "//google.com/foo.jpg",
    }));
    try std.testing.expect(compareURLs(parseLinkURL("/bar/foo.jpg", false), .{
        .manner = .undetermined,
        .base = "/bar/foo.jpg",
    }));
    try std.testing.expect(compareURLs(parseLinkURL("bar/foo.jpg", false), .{
        .manner = .{ .relative = .{ .extension = .jpg } },
        .base = "bar/foo.jpg",
    }));
    try std.testing.expect(compareURLs(parseLinkURL("bar/foo.jpg?zoo##park#", false), .{
        .manner = .undetermined,
        .base = "bar/foo.jpg?zoo",
        .fragment = "##park#",
    }));
    try std.testing.expect(compareURLs(parseLinkURL("bar/foo.jpg?##park#", false), .{
        .manner = .undetermined,
        .base = "bar/foo.jpg?",
        .fragment = "##park#",
    }));
    try std.testing.expect(compareURLs(parseLinkURL("bar/foo.JPG##park#", false), .{
        .manner = .{ .relative = .{ .extension = .jpg } },
        .base = "bar/foo.JPG",
        .fragment = "##park#",
    }));
    try std.testing.expect(compareURLs(parseLinkURL("bar/foo.jpg##park#", true), .{
        .manner = .{ .relative = .{ .extension = .jpg } },
        .base = "bar/foo.jpg",
        .fragment = "##park#",
    }));
    try std.testing.expect(compareURLs(parseLinkURL("../bar/foo.JPEG#..300:500", true), .{
        .manner = .{ .relative = .{ .extension = .jpeg } },
        .base = "../bar/foo.JPEG",
        .fragment = "#..300:500",
    }));
    try std.testing.expect(compareURLs(parseLinkURL("bar/foo.tmd#section-1", true), .{
        .manner = .{ .relative = .{ .extension = .tmd } },
        .base = "bar/foo.tmd",
        .fragment = "#section-1",
    }));
    try std.testing.expect(compareURLs(parseLinkURL("bar/foo.HTM", true), .{
        .manner = .{ .relative = .{ .extension = .htm } },
        .base = "bar/foo.HTM",
    }));
    try std.testing.expect(compareURLs(parseLinkURL("bar/foo.htmx", false), .{
        .manner = .undetermined,
        .base = "bar/foo.htmx",
    }));
    try std.testing.expect(compareURLs(parseLinkURL("##park#", true), .{
        .manner = .footnote,
        .fragment = "##park#",
    }));
    try std.testing.expect(compareURLs(parseLinkURL(" #foo ", true), .{
        .manner = .footnote,
        .fragment = "#foo",
    }));
}

pub const Extension = enum {
    tmd,
    //md,

    txt,
    htm,
    html,
    xhtml,

    png,
    gif,
    jpg,
    jpeg,

    css,
    js,
};

const maxExtLen = blk: {
    const names = std.meta.fieldNames(Extension);
    var len: usize = 0;
    for (names) |name| {
        if (name.len > len) len = name.len;
    }
    break :blk len;
};

pub fn extensionFromString(extWithoutStartingDot: []const u8) ?Extension {
    if (extWithoutStartingDot.len > maxExtLen) return null;
    var buffer: [maxExtLen]u8 = undefined;
    const lower = std.ascii.lowerString(&buffer, extWithoutStartingDot);
    return std.meta.stringToEnum(Extension, lower);
}

pub fn extension(text: []const u8) ?Extension {
    const index = std.mem.lastIndexOfScalar(u8, text, '.') orelse return null;
    return extensionFromString(text[index + 1 ..]);
}

pub fn getExtensionInfo(ext: Extension) ExtensionInfo {
    return extensionInfo[@intFromEnum(ext)];
}

fn checkValidExtensionAsURL(text: []const u8) ?Extension {
    if (extension(text)) |ext| {
        const info = getExtensionInfo(ext);
        if (info.canBeUsedAsURL) return ext;
    }
    return null;
}

pub const ExtensionInfo = struct {
    ext: Extension,
    mime: []const u8,
    isImage: bool = false,
    isText: bool = false,
    canBeUsedAsURL: bool = false,
};

const extensionInfo: [@typeInfo(Extension).@"enum".fields.len]ExtensionInfo = .{
    .{ .ext = .tmd, .mime = "text/tapir-markdown", .isText = true, .canBeUsedAsURL = true },
    //.{.ext = .md, .mime = "text/markdown", .isText = true, .canBeUsedAsURL = true},

    .{ .ext = .txt, .mime = "text/plain", .isText = true, .canBeUsedAsURL = true },
    .{ .ext = .htm, .mime = "text/html", .isText = true, .canBeUsedAsURL = true },
    .{ .ext = .html, .mime = "text/html", .isText = true, .canBeUsedAsURL = true },
    .{ .ext = .xhtml, .mime = "application/xhtml+xml", .isText = true, .canBeUsedAsURL = true },

    .{ .ext = .png, .mime = "image/png", .isImage = true, .canBeUsedAsURL = true },
    .{ .ext = .gif, .mime = "image/gif", .isImage = true, .canBeUsedAsURL = true },
    .{ .ext = .jpg, .mime = "image/jpeg", .isImage = true, .canBeUsedAsURL = true },
    .{ .ext = .jpeg, .mime = "image/jpeg", .isImage = true, .canBeUsedAsURL = true },

    // ToDo: also support canBeUsedAsURL/
    //       Or never. Only support .css.txt, .js.txt, ....
    .{ .ext = .css, .mime = "text/css" },
    .{ .ext = .js, .mime = "text/javascript" },
};

test "extensionInfo" {
    for (extensionInfo, 0..) |mt, i| {
        try std.testing.expect(@intFromEnum(mt.ext) == i);
    }
}

test "extension" {
    try std.testing.expect(extension("http://aaa/foo.png") == .png);
    try std.testing.expect(extension("bar.tmd") == .tmd);
    try std.testing.expect(extension("./a.html") == .html);
    try std.testing.expect(extension("./a.HTML") == .html);
    try std.testing.expect(extension("../b.htm") == .htm);
    try std.testing.expect(extension("../b.XhtmL") == .xhtml);
    try std.testing.expect(extension("../foo/c.txt") == .txt);
    try std.testing.expect(extension("../c.asp") == null);
    try std.testing.expect(extension("https://example.com/p") == null);

    try std.testing.expect(extension("foo.png") == .png);
    try std.testing.expect(extension("bar.PNG") == .png);
    try std.testing.expect(extension("foo.Jpeg") == .jpeg);
    try std.testing.expect(extension("bar.JPG") == .jpg);
    try std.testing.expect(extension("bar.jpg") == .jpg);
    try std.testing.expect(extension("f.gif") == .gif);
    try std.testing.expect(extension("b.GIF") == .gif);

    try std.testing.expect(extension("PNG") == null);
    try std.testing.expect(extension("foo.xyz") == null);
}
