const std = @import("std");
const tmd = @import("tmd");
const all = @import("all.zig");

test "tmd render" {
    const PageTitleChecker = struct {
        fn check(forToc: bool, data: []const u8, expectedHasTitle: bool, expectedTitleText: []const u8) !bool {
            return all.TitleRenderChecker.check(data, forToc, struct {
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

    try std.testing.expect(try PageTitleChecker.check(false,
        \\   ### title
        \\
    , true, "title"));

    try std.testing.expect(try PageTitleChecker.check(false,
        \\
        \\ {%%
        \\   ### title
        \\ }
        \\
    , true, "title"));

    try std.testing.expect(try PageTitleChecker.check(false,
        \\
        \\ ###=== section
        \\
        \\ {%%
        \\   ### title
        \\ }
        \\
    , false, ""));

    try std.testing.expect(try PageTitleChecker.check(false,
        \\   ###--- not title
        \\
    , false, ""));

    try std.testing.expect(try PageTitleChecker.check(false,
        \\   ### foo
        \\      && bar.png
        \\
    , true, "foo"));

    try std.testing.expect(try PageTitleChecker.check(false,
        \\   ### __link__ **bold **// italic
        \\
    , true, "link bolditalic"));

    try std.testing.expect(try PageTitleChecker.check(true,
        \\   ### __link__ **bold **// italic
        \\
    , true, 
        \\link <span class="tmd-bold">bold</span><span class="tmd-italic">italic</span>
        ));
}
