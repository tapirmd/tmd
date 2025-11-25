const std = @import("std");

const miniz = @cImport({
    @cInclude("miniz.h");
});

const Zip = @This();



zipArchive: *miniz.mz_zip_archive,
finalData: ?[]u8 = null,



pub fn init(initialCapacity: usize) !Zip {
    const za: *miniz.mz_zip_archive = @ptrCast(@alignCast(std.c.malloc(@sizeOf(miniz.mz_zip_archive)) orelse return error.ZipCreate));
    za.* = std.mem.zeroInit(miniz.mz_zip_archive, .{});
    if (miniz.mz_zip_writer_init_heap(za, 0, initialCapacity) == miniz.MZ_FALSE)
        return error.ZipWriterInit;

    return .{
        .zipArchive = za,
    };
}

pub fn deinit(self: *@This()) void {
    if (self.finalData == null) {
        _ = self.finalize() catch {
            @panic("zip finalize error in deinit");
        };
    }
    if (self.finalData) |data| {
        if (data.len > 0) std.c.free(data.ptr);
        self.finalData = null;
    } else unreachable;

    _ = miniz.mz_zip_writer_end(self.zipArchive);
    std.c.free(self.zipArchive);
}

pub fn addFile(self: *@This(), filepath: []const u8, fileContent: []const u8, compress: bool) !void {
    const compression: miniz.mz_uint = if (compress) miniz.MZ_BEST_COMPRESSION else miniz.MZ_NO_COMPRESSION;
    if (miniz.mz_zip_writer_add_mem(self.zipArchive, filepath.ptr, fileContent.ptr, fileContent.len, compression) == miniz.MZ_FALSE)
        return error.ZipAddFile;
}

pub fn finalize(self: *@This()) ![]const u8 {
    var ptr: ?*anyopaque = null;
    var size: usize = 0;
    if (miniz.mz_zip_writer_finalize_heap_archive(self.zipArchive, &ptr, &size) == miniz.MZ_FALSE)
        return error.ZipFinalize;
    
    std.debug.assert(ptr != null);
    const data = @as([*]u8, @ptrCast(ptr.?))[0..size];
    self.finalData = data;

    return data;
}
