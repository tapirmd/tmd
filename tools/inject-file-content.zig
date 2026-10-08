const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();

    _ = args.skip(); // argv[0]

    const enocde_method = args.next() orelse return error.MissingInputPathArg;
    //std.debug.print("enocde_method: {s}\n", .{ enocde_method });

    const input_path = args.next() orelse return error.MissingInputPathArg;
    //std.debug.print("input_path:    {s}\n", .{ input_path });

    const placeholder = args.next() orelse return error.MissingPlaceholderArg;
    //std.debug.print("placeholder:   {s}\n", .{ placeholder });

    const content_path = args.next() orelse return error.MissingContentPathArg;
    //std.debug.print("content_path:  {s}\n", .{ content_path });

    const output_path = args.next() orelse return error.MissingOutputPathArg;
    //std.debug.print("output_path:   {s}\n", .{ output_path });

    const base64Encode = std.mem.eql(u8, enocde_method, "base64") or
        if (std.mem.eql(u8, enocde_method, "none")) false else return error.UnsupportedEncodeMethod;

    const cwd = std.Io.Dir.cwd();

    const input = try cwd.readFileAlloc(io, input_path, gpa, .unlimited);
    defer gpa.free(input);

    if (std.mem.indexOf(u8, input, placeholder)) |k| {
        const content = try cwd.readFileAlloc(io, content_path, gpa, .unlimited);
        defer gpa.free(content);

        const output_file = try cwd.createFile(io, output_path, .{ .truncate = true });
        defer output_file.close(io);

        var buffer: [4096]u8 = undefined;
        var writer = output_file.writer(io, &buffer);
        const w = &writer.interface;
        try w.writeAll(input[0..k]);

        if (base64Encode) try std.base64.standard.Encoder.encodeWriter(w, content) else try w.writeAll(content);

        try w.writeAll(input[k + placeholder.len ..]);
        try w.flush();
    } else return error.PlaceholderNotFound;
}
