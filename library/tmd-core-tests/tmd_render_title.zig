const std = @import("std");
const tmd = @import("tmd");
const all = @import("all.zig");

test "tmd render" {
    const PageTitleChecker = struct {
        fn check(data: []const u8, expectedHasTitle: bool, expectedTitleText: []const u8) !bool {
            return all.TitleRenderChecker.check(data, struct {
                expectedHasTitle: bool,
                expectedTitleText: []const u8,

                pub fn checkFn(self: @This(), hasTitle: bool, titleText: []const u8) !void {
                    if (self.expectedHasTitle != hasTitle) {
                        if (hasTitle) return error.ExpectTitleExisting else return error.ExpectNoTitle;
                    }
                    if (!std.mem.eql(u8, self.expectedTitleText, titleText)) {
                        return error.UnexpectedTitle;
                    }
                }
            }{ .expectedHasTitle = expectedHasTitle, .expectedTitleText = expectedTitleText });
        }
    };

    try std.testing.expect(try PageTitleChecker.check(
        \\   ### title
        \\
    , true, "title"));

    try std.testing.expect(try PageTitleChecker.check(
        \\
        \\ {%%
        \\   ### title
        \\ }
        \\
    , true, "title"));

    try std.testing.expect(try PageTitleChecker.check(
        \\
        \\ ###=== section
        \\
        \\ {%%
        \\   ### title
        \\ }
        \\
    , false, ""));

    try std.testing.expect(try PageTitleChecker.check(
        \\   ###--- not title
        \\
    , false, ""));

    try std.testing.expect(try PageTitleChecker.check(
        \\   ### foo
        \\      && bar.png
        \\
    , true, "foobar.png"));

    try std.testing.expect(try PageTitleChecker.check(
        \\   ### __link__ **bold **// italic
        \\
    , true, "link bolditalic"));
}
