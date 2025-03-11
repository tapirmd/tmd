const std = @import("std");

pub fn validateURL(path: []u8) void {
    std.mem.replaceScalar(u8, path, '\\', '/');
}

pub fn validatePath(path: []u8) void {
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, path, '/', std.fs.path.sep);
    if (std.fs.path.sep != '\\') std.mem.replaceScalar(u8, path, '\\', std.fs.path.sep);
}

pub fn readFileIntoBuffer(dir: std.fs.Dir, path: []const u8, buffer: []u8, stderr: std.fs.File.Writer) ![]u8 {
    const tmdFile = dir.openFile(path, .{}) catch |err| {
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

pub const FileIterator = struct {
    paths: []const []const u8,
    allocator: std.mem.Allocator,

    curIndex: usize = 0,

    walkingDirPath: ?[]const u8 = null,
    walkingDir: std.fs.Dir = undefined, // valid only if walkingDirPath != null
    dirWalker: std.fs.Dir.Walker = undefined, // valid only if walkingDirPath != null

    pub fn init(paths: []const []const u8, allocator: std.mem.Allocator) FileIterator {
        return .{
            .paths = paths,
            .allocator = allocator,
        };
    }

    pub const Entry = struct {
        dir: std.fs.Dir,
        dirPath: []const u8,
        filePath: []const u8,
    };

    pub fn next(fi: *FileIterator) !?Entry {
        if (fi.walkingDirPath) |dirPath| {
            while (try fi.dirWalker.next()) |entry| {
                switch (entry.kind) {
                    .file => return .{
                        .dir = fi.walkingDir,
                        .dirPath = dirPath,
                        .filePath = entry.path,
                    },
                    else => {},
                }
            } else {
                fi.curIndex += 1;
                fi.dirWalker.deinit();
                fi.walkingDir.close();
                fi.walkingDirPath = null;
                return fi.next();
            }
        }

        const dir = std.fs.cwd();
        while (fi.curIndex < fi.paths.len) {
            const path = fi.paths[fi.curIndex];
            const stat = try dir.statFile(path);
            switch (stat.kind) {
                .file => {
                    fi.curIndex += 1;
                    return .{
                        .dir = dir,
                        .dirPath = ".",
                        .filePath = path,
                    };
                },
                .directory => {
                    var subDir = try dir.openDir(path, .{ .no_follow = true, .access_sub_paths = false, .iterate = true });
                    const walker = subDir.walk(fi.allocator) catch |err| {
                        subDir.close();
                        return err;
                    };

                    fi.dirWalker = walker;
                    fi.walkingDir = subDir;
                    fi.walkingDirPath = path;
                    return fi.next();
                },
                else => fi.curIndex += 1,
            }
        }

        fi.curIndex = 0; // ready to be reused.
        return null;
    }
};
