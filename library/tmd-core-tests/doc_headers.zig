const std = @import("std");
const tmd = @import("tmd");
const all = @import("all.zig");

test "doc headers" {
    try std.testing.expect(try all.DocChecker.check(
        \\ ### Title
        \\ ###---
        \\ ###==== fooo
        \\ {
        \\ {//
        \\ ###==== bar
        \\ }
        \\ }
        \\ ###=== baz
        \\
        \\ . @@@ #id
        \\   ###==== section
        \\
    , struct {
        fn check(doc: *const tmd.Doc) !void {
            try std.testing.expect(doc.tocHeaders.size() == 2);
            try std.testing.expect(doc.titleHeader != null);
        }
    }.check));

    try std.testing.expect(try all.DocChecker.check(
        \\ ###=== Title
        \\ ###---
        \\ ###=== fooo
        \\ {
        \\ {
        \\ ###=== section
        \\ }
        \\ }
        \\
    , struct {
        fn check(doc: *const tmd.Doc) !void {
            try std.testing.expect(doc.tocHeaders.size() == 3);
            try std.testing.expect(doc.titleHeader == null);
        }
    }.check));
}
