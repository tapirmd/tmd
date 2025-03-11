const std = @import("std");

const tmd = @import("tmd");

const gen = @import("gen.zig").generate;
const fmt = @import("fmt.zig").format;
const vet = @import("vet.zig").vet;

pub const stdout = std.io.getStdOut().writer();
pub const stderr = std.io.getStdErr().writer();

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const gpaAllocator = gpa.allocator();

    const args = try std.process.argsAlloc(gpaAllocator);
    defer std.process.argsFree(gpaAllocator, args);

    std.debug.assert(args.len > 0);

    if (args.len <= 1) {
        try printUsages();
        return;
    }

    if (std.mem.eql(u8, args[1], "gen")) {
        try gen(args[2..], gpaAllocator);
        return;
    }

    if (std.mem.eql(u8, args[1], "fmt")) {
        try fmt(args[2..], gpaAllocator);
        return;
    }

    if (std.mem.eql(u8, args[1], "vet")) {
        try vet(args[2..], gpaAllocator);
        return;
    }

    try stderr.print("Unknown command: {s}\n\n", .{args[1]});

    try printUsages();
    std.process.exit(1);
    unreachable;
}

// "toolset" is better than "toolkit" here?
// https://www.difference.wiki/toolset-vs-toolkit/
fn printUsages() !void {
    try stdout.print(
        \\TapirMD toolset v{s}
        \\
        \\Usages:
        \\  tmd gen [--trial-page-css=...] [--enabled-custom-apps=...] TMD-paths...
        \\  tmd fmt TMD-paths...
        \\
        \\gen options:
        \\  --trial-page-css
        \\      Specify css for generated pages
        \\      Blank for incomplete page for embedding purpose.
        \\      @ means inlining the builtin example css.
        \\      @path means inlining the specified css content.
        \\      Others means a URL, either absolute or relative.
        \\  --enabled-custom-apps
        \\      Specify enabled custom apps.
        \\      Now, only html is supported.
        \\
    , .{tmd.version});
}
