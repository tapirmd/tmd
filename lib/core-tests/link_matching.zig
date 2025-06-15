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

                const Range = struct {
                    start: usize,
                    end: usize,
                };

                fn retrieveFirstLinkURL(html: []const u8) ?Range {
                    const start = std.mem.indexOf(u8, html, openNeedle) orelse return null;
                    const offset = start + openNeedle.len;
                    const end = std.mem.indexOf(u8, html[offset..], closeNeedle) orelse return null;
                    return .{ .start = offset, .end = offset + end };
                }

                pub fn checkFn(self: @This(), html: []const u8) !bool {
                    var remaining = html;
                    for (self.expectedURIs, 1..) |expected, i| {
                        const range = retrieveFirstLinkURL(remaining) orelse {
                            //std.debug.print("<<<\n{s}\n+++\n{s}\n>>>\n", .{self.data, html});
                            return error.TooLessLinks;
                        };
                        const uri = remaining[range.start..range.end];
                        if (!std.mem.eql(u8, uri, expected)) return false;
                        remaining = remaining[range.end + closeNeedle.len ..];
                        if (i == self.expectedURIs.len) {
                            if (retrieveFirstLinkURL(remaining) != null) return error.TooManyLinks;
                            break;
                        }
                    }
                    return true;
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
        \\__foo__
        \\===foo``https://go101.org
        \\
    , &.{
        "https://go101.org",
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
        \\=== foo :: https://go101.org
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
        \\__foo__
        \\=== foo 
        \\    !! https://go101.org/__foo__/`foo``
        \\
    , &.{
        "https://go101.org/__foo__/`foo``",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__foo bar__
        \\=== foo :: https://go101.org
        \\
    , &.{}));

    try std.testing.expect(try LinkChecker.check(
        \\__foo bar__
        \\=== foo... :: https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\__foo bar__
        \\=== ... bar :: https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... :: https://tapirgames.com
        \\
        \\__foo bar__
        \\
    , &.{
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... :: https://tapirgames.com
        \\
        \\__foo bar__
        \\
        \\=== ... bar :: https://go101.org
        \\
    , &.{
        "https://go101.org",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... :: https://tapirgames.com
        \\
        \\__foo bar__
        \\
        \\===
        \\=== ... bar :: https://go101.org
        \\
    , &.{
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... :: https://tapirgames.com
        \\===
        \\
        \\__foo bar__
        \\
        \\===
        \\=== ... bar :: https://go101.org
        \\
    , &.{}));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... :: https://tapirgames.com
        \\
        \\__foo bar__
        \\
        \\=== ... bar :: https://go101.org
        \\
        \\__foo bye__
        \\
    , &.{
        "https://go101.org",
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... :: https://tapirgames.com
        \\
        \\__foo bar__
        \\__foo bye__
        \\
    , &.{
        "https://tapirgames.com",
        "https://tapirgames.com",
    }));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... :: https://tapirgames.com
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
        \\=== foo... :: https://tapirgames.com
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
        \\Here is only one .link block.
        \\
    , &.{}));

    try std.testing.expect(try LinkChecker.check(
        \\=== foo... :: https://tapirgames.com
        \\
        \\__foo__
        \\__foo zzz__
        \\__foo bar__
        \\__foo bar foo__
        \\
        \\=== foobar... :: https://go101.org
        \\
        \\__foo zzz foo__
        \\__foo bar foo bar__
        \\__foo zzz foo bar__
        \\__foo bar foo bar foo__
        \\__foo zzz foo bar foo__
        \\__foo zzz foo zzz foo__
        \\
        \\=== foozzz... :: https://phyard.com
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
}
