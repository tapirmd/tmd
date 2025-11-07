const std = @import("std");

const c = @cImport({
    @cInclude("miniz.h");
});

const Zip = @This();

pub fn foo() void {
    const input = "Hello, this is a test string for miniz compression in Zig!";
    const input_len = input.len;

    const max_compressed_size = c.mz_compressBound(@as(c_ulong, input_len));
    std.debug.print("=== max_compressed_size: {}\n", .{max_compressed_size});
}
