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
        \\::foo `` bar.tmd :: 
        \\===foo``https://go101.org
        \\
    , &.{
        "bar.html",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\^::foo `` bar.tmd ::
        \\===foo``https://go101.org
        \\
    , &.{
        "^bar.html",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\::foo `` bar.htm
        \\===foo``https://go101.org
        \\
    , &.{
        "bar.htm",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\::foo `` bar.png
        \\===foo``https://go101.org
        \\
    , &.{
        "bar.png",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\::
        \\&& bar.png
        \\::
        \\===foo``https://go101.org
        \\
    , &.{
        "bar.png",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\::
        \\&& foo.png
        \\%% bar
        \\===...bar``https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\:: this
        \\%% -1
        \\:: and ::this
        \\%% -2
        \\===this-2``https://go101.org
        \\===this-1``https://tapirgames.com
        \\
    , &.{
        "https://tapirgames.com",
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\````::foo::
        \\===foo``https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\^::foo::
        \\===foo``https://go101.org
        \\
    , &.{
        "^https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\^::foo::
        \\===foo`https://go101.org/"foo'bar&zoo?a=b&c=d#ddd"ccc'eee&fff?ggg
        \\
    , &.{
        "^https://go101.org/%22foo%27bar&zoo?a=b&c=d#ddd%22ccc%27eee&fff?ggg",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\^::foo``./foo"bar'zoo/?xx&yy.tmd
        \\
    , &.{
        "^./foo%22bar%27zoo/%3fxx%26yy.html",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\::foo::
        \\===foo``https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\::foo::
        \\=== foo ` https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\::foo::
        \\=== foo `https://go101.org/::foo::`
        \\
    , &.{
        "https://go101.org/::foo::",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\::
        \\!! ::foo::
        \\
        \\=== ::foo::` https://go101.org/::foo::
        \\
    , &.{
        "https://go101.org/::foo::",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\::foo::
        \\=== foo 
        \\    !! https://go101.org/::foo::/`foo``
        \\
    , &.{
        "https://go101.org/::foo::/`foo``",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\::foo bar::
        \\=== foo ` https://go101.org
        \\
    , &.{}));

    try std.testing.expect(try LinkChecker.check(
        \\::foo bar::
        \\=== foo... ` https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\::foo bar::
        \\=== ... bar ` https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\
        \\::foo bar::
        \\
    , &.{
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\
        \\::foo bar::
        \\
        \\=== ... bar ` https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\
        \\::foo bar::
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
        \\::foo bar::
        \\
        \\===
        \\=== ... bar ` https://go101.org
        \\
    , &.{}));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\
        \\::foo bar::
        \\
        \\=== ... bar ` https://go101.org
        \\
        \\::foo bye::
        \\
    , &.{
        "https://go101.org",
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\
        \\::foo bar::
        \\::foo bye::
        \\
    , &.{
        "https://tapirgames.com",
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo ... ` https://tapirgames.com
        \\=== bar... ` https://go101.com
        \\
        \\::foo `bar` byte::
        \\::foo `bar` `` byte::
        \\::bar `bye` foo::
        \\::bar `bye` `` foo::
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
        \\::foo `bar` byte::
        \\::foo `bar` `` byte::
        \\::bar `bye` foo::
        \\::bar `bye` `` foo::
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
        \\::foo::
        \\::foo zzz::
        \\::foo bar::
        \\::foo bar foo::
        \\::foo zzz foo::
        \\::foo bar foo bar::
        \\::foo zzz foo bar::
        \\::foo bar foo bar foo::
        \\::foo zzz foo bar foo::
        \\::foo zzz foo zzz foo::
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
        \\::foo::
        \\::foo zzz::
        \\::foo bar::
        \\::foo bar foo::
        \\::foo zzz foo::
        \\::foo bar foo bar::
        \\::foo zzz foo bar::
        \\::foo bar foo bar foo::
        \\::foo zzz foo bar foo::
        \\::foo zzz foo zzz foo::
        \\Here is only one .linkdef block.
        \\
    , &.{}));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... ` https://tapirgames.com
        \\
        \\::foo::
        \\::foo zzz::
        \\::foo bar::
        \\::foo bar foo::
        \\
        \\=== foo bar... ` https://go101.org
        \\
        \\::foo zzz foo::
        \\::foo bar foo bar::
        \\::foo         zzz foo bar::
        \\::foo bar foo bar foo::
        \\::foo  zzz    foo bar foo::
        \\::foo    zzz foo zzz foo::
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
        \\::foo
        \\bar::
        \\::foo``
        \\bar::
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
        \\::foo
        \\bar::
        \\::foo``
        \\bar::
        \\
    , &.{
        "https://google.com",
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\foo ::#foo::
        \\
        \\All footnotes :: # ::
        \\
    , &.{
        "#fn:foo",
        "#fn:",
        "#fn:foo:ref-1",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\::c `` #ccc :: 
        \\
        \\::d `` #ddd :: 
        \\
        \\::e `` #eee :: 
        \\
    , &.{
        "#ccc",
        "#ddd",
        "#eee",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\:: #bbb :: 
        \\
        \\::`` #ccc :: 
        \\
        \\::`` `` ` ` #xxx``:: 
        \\
        \\::```` #ddd :: 
        \\
        \\::https://google.com``:: 
        \\
        \\::^`` #eee :: 
        \\
        \\::fff `` :: broken link
        \\
        \\::#bbb `` :: broken link
        \\
        \\::`` `` #ggg :: 
        \\
        \\:: #bbb :: 
        \\
        \\::#:: // link to the whole footnotes div
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
        \\::a.html ``:: 
        \\
        \\::a.html ````:: 
        \\
        \\::a.html ^``:: 
        \\
    , &.{}));
}
