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
        std.process.exit(0);
        unreachable;
    }

    if (std.mem.eql(u8, args[1], "gen")) {
        std.process.exit(try gen(args[2..], gpaAllocator));
        unreachable;
    }

    if (std.mem.eql(u8, args[1], "fmt")) {
        std.process.exit(try fmt(args[2..], gpaAllocator));
        unreachable;
    }

    if (std.mem.eql(u8, args[1], "vet")) {
        std.process.exit(try vet(args[2..], gpaAllocator));
        unreachable;
    }

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
        \\  tmd gen [--trial-page-css=...] [--enabled-custom-apps=...] TMD-files...
        \\  tmd fmt TMD-files...
        \\
        \\gen options:
        \\  --trial-page-css           Specify css for generated pages
        \\                             Blank for incomplete page for embedding purpose.
        \\                             @ means inlining the builtin example css.
        \\                             @path means inlining the specified css content.
        \\                             Others means a URL, either absolute or relative.
        \\  --enabled-custom-apps      Specify enabled custom apps.
        \\                             Now only html is supported.
        \\
    , .{tmd.version});
}

pub fn validateURL(path: []u8) void {
    std.mem.replaceScalar(u8, path, '\\', '/');
}

pub fn validatePath(path: []u8) void {
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, path, '/', std.fs.path.sep);
    if (std.fs.path.sep != '\\') std.mem.replaceScalar(u8, path, '\\', std.fs.path.sep);
}

pub fn readFileIntoBuffer(path: []const u8, buffer: []u8) ![]u8 {
    const tmdFile = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try stderr.print("File ({s}) is not found.\n", .{path});
        }
        return err;
    };
    defer tmdFile.close();

    const stat = try tmdFile.stat();
    if (stat.size > buffer.len) {
        try stderr.print("File ({s}) size is too large ({} > {}).\n", .{ path, stat.size, buffer.len });
        return error.FileSizeTooLarge;
    }

    const readSize = try tmdFile.readAll(buffer[0..stat.size]);
    if (stat.size != readSize) {
        try stderr.print("[{s}] read size not match ({} != {}).\n", .{ path, stat.size, readSize });
        return error.FileSizeNotMatch;
    }
    return buffer[0..readSize];
}
