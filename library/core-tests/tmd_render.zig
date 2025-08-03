const std = @import("std");
const tmd = @import("tmd");
const all = @import("all.zig");

test "tmd render" {
    const HtmlGenChecker = struct {
        fn check(data: []const u8, expectedHtmlTags: []const []const u8) !bool {
            return all.RenderChecker.check(data, struct {
                expectedHtmlTags: []const []const u8,

                pub fn checkFn(self: @This(), html: []const u8) !bool {
                    for (self.expectedHtmlTags) |expected| {
                        if (std.mem.indexOf(u8, html, expected) == null) {
                            return error.ExpectedTagNotFound;
                        }
                    }
                    return true;
                }
            }{ .expectedHtmlTags = expectedHtmlTags });
        }
    };

    try std.testing.expect(try HtmlGenChecker.check(
        \\   && foo.png
        \\
    , &.{"<img"}));

    try std.testing.expect(try HtmlGenChecker.check(
        \\###
        \\   && foo.png
        \\
    , &.{"<img"}));
}
