const std = @import("std");
const tmd = @import("tmd");
const all = @import("all.zig");

test "line end type" {
    const LinkChecker = struct {
        fn check(data: []const u8, expectedURIs: []const []const u8) !bool {
            return all.RenderChecker.check(data, struct {
                data: []const u8,
                expectedURIs: []const []const u8,

                const openNeedle = "href=\"";
                const closeNeedle = "\"";

                const UrlInfo = struct {
                    start: usize,
                    end: usize,
                    openInNewWindow: bool,
                };

                fn retrieveFirstLinkURL(html: []const u8) ?UrlInfo {
                    const start = std.mem.indexOf(u8, html, openNeedle) orelse return null;
                    const offset = start + openNeedle.len;
                    const end = std.mem.indexOf(u8, html[offset..], closeNeedle) orelse return null;
                    const remaining = html[offset + end + closeNeedle.len ..];
                    const pos = std.mem.indexOfAny(u8, remaining, "_>") orelse unreachable;
                    if (remaining[pos] == '_') {
                        if (std.mem.startsWith(u8, remaining[pos + 1 ..], "blank"))
                            return .{ .start = offset, .end = offset + end, .openInNewWindow = true };
                    }
                    return .{ .start = offset, .end = offset + end, .openInNewWindow = false };
                }

                pub fn checkFn(self: @This(), html: []const u8) !void {
                    errdefer std.debug.print("<<<\n{s}\n+++\n{s}\n>>>\n", .{ self.data, html });

                    var remaining = html;
                    for (self.expectedURIs, 1..) |expected, i| {
                        const urlInfo = retrieveFirstLinkURL(remaining) orelse return error.TooLessLinks;
                        const uri = remaining[urlInfo.start..urlInfo.end];
                        const targetUrl, const openInNewWindow = if (std.mem.startsWith(u8, expected, "^"))
                            .{ expected[1..], true }
                        else
                            .{ expected, false };
                        if (!std.mem.eql(u8, uri, targetUrl)) {
                            return error.UnmatchedLinkURL;
                        }
                        if (urlInfo.openInNewWindow != openInNewWindow) {
                            return error.UnmatchedOpenInNewWindow;
                        }
                        remaining = remaining[urlInfo.end + closeNeedle.len ..];
                        if (i == self.expectedURIs.len) {
                            if (retrieveFirstLinkURL(remaining) != null) return error.TooManyLinks;
                            break;
                        }
                    }
                }
            }{ .data = data, .expectedURIs = expectedURIs });
        }
    };

    try std.testing.expect(try LinkChecker.check(
        \\hello
        \\world
        \\
    , &.{}));

    try std.testing.expect(try LinkChecker.check(
        \\__foo `` bar.tmd __ 
        \\===foo``https://go101.org
        \\
    , &.{
        "bar.html",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\^__foo `` bar.tmd __
        \\===foo``https://go101.org
        \\
    , &.{
        "^bar.html",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__foo `` bar.htm
        \\===foo``https://go101.org
        \\
    , &.{
        "bar.htm",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__foo `` bar.png
        \\===foo``https://go101.org
        \\
    , &.{
        "bar.png",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__
        \\&& bar.png
        \\__
        \\===foo``https://go101.org
        \\
    , &.{
        "bar.png",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__
        \\&& foo.png
        \\%% bar
        \\===...bar``https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__ this
        \\%% -1
        \\__ and __this
        \\%% -2
        \\===this-2``https://go101.org
        \\===this-1``https://tapirgames.com
        \\
    , &.{
        "https://tapirgames.com",
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\````__foo__
        \\===foo``https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\^__foo__
        \\===foo``https://go101.org
        \\
    , &.{
        "^https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\^__foo__
        \\===foo`https://go101.org/"foo'bar&zoo?a=b&c=d#ddd"ccc'eee&fff?ggg
        \\
    , &.{
        "^https://go101.org/%22foo%27bar&zoo?a=b&c=d#ddd%22ccc%27eee&fff?ggg",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\^__foo``./foo"bar'zoo/?xx&yy.tmd
        \\
    , &.{
        "^./foo%22bar%27zoo/%3fxx%26yy.html",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__foo__
        \\===foo``https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__foo__
        \\=== foo ` https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__foo__
        \\=== foo `https://go101.org/__foo__`
        \\
    , &.{
        "https://go101.org/__foo__",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__
        \\!! __foo__
        \\
        \\=== __foo__` https://go101.org/__foo__
        \\
    , &.{
        "https://go101.org/__foo__",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__foo__
        \\=== foo 
        \\    !! https://go101.org/__foo__/`foo``
        \\
    , &.{
        "https://go101.org/__foo__/`foo``",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__foo bar__
        \\=== foo ` https://go101.org
        \\
    , &.{}));

    try std.testing.expect(try LinkChecker.check(
        \\__foo bar__
        \\=== foo... ` https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__foo bar__
        \\=== ... bar ` https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\
        \\__foo bar__
        \\
    , &.{
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\
        \\__foo bar__
        \\
        \\=== ... bar ` https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\
        \\__foo bar__
        \\
        \\===
        \\=== ... bar ` https://go101.org
        \\
    , &.{
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\===
        \\
        \\__foo bar__
        \\
        \\===
        \\=== ... bar ` https://go101.org
        \\
    , &.{}));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\
        \\__foo bar__
        \\
        \\=== ... bar ` https://go101.org
        \\
        \\__foo bye__
        \\
    , &.{
        "https://go101.org",
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\
        \\__foo bar__
        \\__foo bye__
        \\
    , &.{
        "https://tapirgames.com",
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo ... ` https://tapirgames.com
        \\=== bar... ` https://go101.com
        \\
        \\__foo `bar` byte__
        \\__foo `bar` `` byte__
        \\__bar `bye` foo__
        \\__bar `bye` `` foo__
        \\
    , &.{
        "https://tapirgames.com",
        "https://tapirgames.com",
        "https://go101.com",
        "https://go101.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== ... byte ` https://tapirgames.com
        \\=== ...foo ` https://go101.com
        \\
        \\__foo `bar` byte__
        \\__foo `bar` `` byte__
        \\__bar `bye` foo__
        \\__bar `bye` `` foo__
        \\
    , &.{
        "https://tapirgames.com",
        "https://tapirgames.com",
        "https://go101.com",
        "https://go101.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\
        \\__foo__
        \\__foo zzz__
        \\__foo bar__
        \\__foo bar foo__
        \\__foo zzz foo__
        \\__foo bar foo bar__
        \\__foo zzz foo bar__
        \\__foo bar foo bar foo__
        \\__foo zzz foo bar foo__
        \\__foo zzz foo zzz foo__
        \\
    , &.{
        "https://tapirgames.com",
        "https://tapirgames.com",
        "https://tapirgames.com",
        "https://tapirgames.com",
        "https://tapirgames.com",
        "https://tapirgames.com",
        "https://tapirgames.com",
        "https://tapirgames.com",
        "https://tapirgames.com",
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\__foo__
        \\__foo zzz__
        \\__foo bar__
        \\__foo bar foo__
        \\__foo zzz foo__
        \\__foo bar foo bar__
        \\__foo zzz foo bar__
        \\__foo bar foo bar foo__
        \\__foo zzz foo bar foo__
        \\__foo zzz foo zzz foo__
        \\Here is only one .linkdef block.
        \\
    , &.{}));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\
        \\__foo__
        \\__foo zzz__
        \\__foo bar__
        \\__foo bar foo__
        \\
        \\=== foo bar... ` https://go101.org
        \\
        \\__foo zzz foo__
        \\__foo bar foo bar__
        \\__foo         zzz foo bar__
        \\__foo bar foo bar foo__
        \\__foo  zzz    foo bar foo__
        \\__foo    zzz foo zzz foo__
        \\
        \\=== foo    zzz... ` https://phyard.com
        \\
    , &.{
        "https://tapirgames.com",
        "https://phyard.com",
        "https://go101.org",
        "https://go101.org",
        "https://phyard.com",
        "https://go101.org",
        "https://phyard.com",
        "https://go101.org",
        "https://phyard.com",
        "https://phyard.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo  bar ` https://google.com
        \\=== foobar ` https://tapirgames.com
        \\
        \\__foo
        \\bar__
        \\__foo``
        \\bar__
        \\
    , &.{
        "https://google.com",
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo
        \\    bar ` https://google.com
        \\=== foo
        \\    ``bar ` https://tapirgames.com
        \\
        \\__foo
        \\bar__
        \\__foo``
        \\bar__
        \\
    , &.{
        "https://google.com",
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\foo __#foo__
        \\
        \\All footnotes __ # __
        \\
    , &.{
        "#fn:foo",
        "#fn:",
        "#fn:foo:ref-1",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__c `` #ccc __ 
        \\
        \\__d `` #ddd __ 
        \\
        \\__e `` #eee __ 
        \\
    , &.{
        "#ccc",
        "#ddd",
        "#eee",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__ #bbb __ 
        \\
        \\__`` #ccc __ 
        \\
        \\__`` `` ` ` #xxx``__ 
        \\
        \\__```` #ddd __ 
        \\
        \\__https://google.com``__ 
        \\
        \\__^`` #eee __ 
        \\
        \\__fff `` __ broken link
        \\
        \\__#bbb `` __ broken link
        \\
        \\__`` `` #ggg __ 
        \\
        \\__ #bbb __ 
        \\
        \\__#__ // link to the whole footnotes div
        \\
        \\=== #xxx ` https://go101.org
        \\
        \\=== https://google.com ` https://tapirgames.org
        \\
    , &.{
        "#fn:bbb",
        "#ccc",
        "https://go101.org",
        "#ddd",
        "https://tapirgames.org",
        "#eee",
        "#ggg",
        "#fn:bbb",
        "#fn:",
        "#fn:bbb:ref-1",
        "#fn:bbb:ref-2",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__a.html ``__ 
        \\
        \\__a.html ````__ 
        \\
        \\__a.html ^``__ 
        \\
    , &.{}));
}
