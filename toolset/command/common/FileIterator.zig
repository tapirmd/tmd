
const std = @import("std");

const FileIterator = @This();

paths: []const []const u8,
allocator: std.mem.Allocator,
stderr: std.fs.File.Writer,

_curIndex: usize = 0,

_walkingDirPath: ?[]const u8 = null,
_walkingDir: std.fs.Dir = undefined, // valid only if _walkingDirPath != null
_dirWalker: std.fs.Dir.Walker = undefined, // valid only if _walkingDirPath != null

pub const Entry = struct {
    dir: std.fs.Dir,
    dirPath: []const u8,
    filePath: []const u8,
};

pub fn next(fi: *FileIterator) !?Entry {
    if (fi._walkingDirPath) |dirPath| {
        while (try fi._dirWalker.next()) |entry| {
            switch (entry.kind) {
                .file => return .{
                    .dir = fi._walkingDir,
                    .dirPath = dirPath,
                    .filePath = entry.path,
                },
                else => {},
            }
        } else {
            fi._curIndex += 1;
            fi._dirWalker.deinit();
            fi._walkingDir.close();
            fi._walkingDirPath = null;
            return fi.next();
        }
    }

    const dir = std.fs.cwd();
    while (fi._curIndex < fi.paths.len) {
        const path = fi.paths[fi._curIndex];
        const stat = dir.statFile(path) catch |err| {
            if (err == error.FileNotFound) {
                fi._curIndex += 1;
                try fi.stderr.print("Path ({s}) is not found.\n", .{path});
                continue;
            }
            return err;
        };
        switch (stat.kind) {
            .file => {
                fi._curIndex += 1;
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

                fi._dirWalker = walker;
                fi._walkingDir = subDir;
                fi._walkingDirPath = path;
                return fi.next();
            },
            else => fi._curIndex += 1,
        }
    }

    fi._curIndex = 0; // ready to be reused.
    return null;
}

