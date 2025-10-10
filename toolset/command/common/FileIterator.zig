const std = @import("std");

const util = @import("util.zig");

const FileIterator = @This();

paths: []const []const u8,
allocator: std.mem.Allocator,
stderr: std.fs.File.Writer,
pathFilterFn: *const fn ([]const u8) bool,

_curIndex: usize = 0,

_walkingDirPath: ?[]const u8 = null,
_walkingDir: std.fs.Dir = undefined, // valid only if _walkingDirPath != null
_dirWalker: std.fs.Dir.Walker = undefined, // valid only if _walkingDirPath != null

pub fn init(
    paths: []const []const u8,
    allocator: std.mem.Allocator,
    stderr: std.fs.File.Writer,
    pathFilter: ?*const fn ([]const u8) bool,
) FileIterator {
    return .{
        .paths = paths,
        .allocator = allocator,
        .stderr = stderr,
        .pathFilterFn = pathFilter orelse &allowAllFilter,
    };
}

fn allowAllFilter(_: []const u8) bool {
    return true;
}

pub const Entry = struct {
    dir: std.fs.Dir,
    dirPath: []const u8,
    filePath: []const u8,
};

pub fn next(fi: *FileIterator) !?Entry {
    if (fi._walkingDirPath) |dirPath| {
        while (try fi._dirWalker.next()) |entry| {
            switch (entry.kind) {
                .file => {
                    if (fi.pathFilterFn(std.fs.path.basename(entry.path))) {
                        return .{
                            .dir = fi._walkingDir,
                            .dirPath = dirPath,
                            .filePath = entry.path,
                        };
                    } else continue;
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

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fs.cwd();
    while (fi._curIndex < fi.paths.len) {
        const path = util.validatePath(fi.paths[fi._curIndex], buffer[0..]);

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
                var subDir = try dir.openDir(path, .{ .iterate = true });
                if (fi.pathFilterFn(std.fs.path.basename(path))) {
                    const walker = subDir.walk(fi.allocator) catch |err| {
                        subDir.close();
                        return err;
                    };

                    fi._dirWalker = walker;
                    fi._walkingDir = subDir;
                    fi._walkingDirPath = path;
                    return fi.next();
                }
                fi._curIndex += 1;
            },
            else => fi._curIndex += 1,
        }
    }

    fi._curIndex = 0; // ready to be reused.
    return null;
}
