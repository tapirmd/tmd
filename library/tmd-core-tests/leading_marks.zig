const std = @import("std");
const tmd = @import("tmd");
const all = @import("all.zig");

test "leading marks" {
    try std.testing.expect(try all.RenderChecker.check(
        \\ &&
        \\ foo
        \\
    , struct {
        pub fn checkFn(self: @This(), html: []const u8) !void {
            _ = self;
            try std.testing.expect(std.mem.indexOf(u8, html, "tmd-dropcap") != null);
        }
    }{}));

    try std.testing.expect(try all.RenderChecker.check(
        \\ ;;; &&
        \\ foo
        \\
    , struct {
        pub fn checkFn(self: @This(), html: []const u8) !void {
            _ = self;
            try std.testing.expect(std.mem.indexOf(u8, html, "tmd-dropcap") != null);
        }
    }{}));

    try std.testing.expect(try all.RenderChecker.check(
        \\ ;;; && bar
        \\ foo
        \\
    , struct {
        pub fn checkFn(self: @This(), html: []const u8) !void {
            _ = self;
            try std.testing.expect(std.mem.indexOf(u8, html, "tmd-dropcap") == null);
        }
    }{}));

    try std.testing.expect(try all.RenderChecker.check(
        \\ ### &&
        \\ foo
        \\
    , struct {
        pub fn checkFn(self: @This(), html: []const u8) !void {
            _ = self;
            try std.testing.expect(std.mem.indexOf(u8, html, "tmd-dropcap") == null);
        }
    }{}));
}
