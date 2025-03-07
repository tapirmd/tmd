const std = @import("std");
const tmd = @import("tmd");

const exampleConfig =
    \\@@@ #withFields
    \\* @@@ #field1
    \\html
    \\* @@@ #field2
    \\phyard
    \\
    \\@@@ #enabledCustomApps
    \\html``phyard
    \\
    \\@@@ #enabledCustomApps-2
    \\'''
    \\html``phyard
    \\'''
    \\
    \\@@@ #autoIdentSuffix
    \\-demo
    \\
    \\@@@ #identSuffix
    \\
    \\@@@ #renderRoot
    \\true
    \\
;

test "tmd config" {
    var doc = try tmd.Doc.parse(exampleConfig, std.testing.allocator);
    defer doc.destroy();

    var config = doc.asConfig();
    try std.testing.expectEqualStrings(config.stringValue("enabledCustomApps").?, "html");
    try std.testing.expectEqualStrings(config.stringValue("enabledCustomApps-2").?, "html``phyard");
    try std.testing.expectEqualStrings(config.stringValue("identSuffix").?, "");
    try std.testing.expectEqualStrings(config.stringValue("renderRoot").?, "true");
}
