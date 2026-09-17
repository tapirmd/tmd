const std = @import("std");

const util = @import("util.zig");

const FileIterator = @This();

paths: []const []const u8,
io: std.Io,
allocator: std.mem.Allocator,
stderr: *std.Io.Writer,
pathFilterFn: *const fn ([]const u8) bool,

_curIndex: usize = 0,

_walkingDirPath: ?[]const u8 = null,
_walkingDir: std.Io.Dir = undefined, // valid only if _walkingDirPath != null
_dirWalker: std.Io.Dir.Walker = undefined, // valid only if _walkingDirPath != null

// So not support concurrency.
_filePathBuffer: [std.Io.Dir.max_path_bytes]u8 = undefined,

pub fn init(
    paths: []const []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
    pathFilter: ?*const fn ([]const u8) bool,
) FileIterator {
    return .{
        .paths = paths,
        .io = io,
        .allocator = allocator,
        .stderr = stderr,
        .pathFilterFn = pathFilter orelse &allowAllFilter,
    };
}

fn allowAllFilter(_: []const u8) bool {
    return true;
}

pub const Entry = struct {
    dir: std.Io.Dir,
    dirPath: []const u8,
    filePath: []const u8,
};

pub fn next(fi: *FileIterator) !?Entry {
    if (fi._walkingDirPath) |dirPath| {
        while (try fi._dirWalker.next(fi.io)) |entry| {
            switch (entry.kind) {
                .file => {
                    if (fi.pathFilterFn(std.Io.Dir.path.basename(entry.path))) {
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
            fi._walkingDir.close(fi.io);
            fi._walkingDirPath = null;
            return fi.next();
        }
    }

    const dir = std.Io.Dir.cwd();
    while (fi._curIndex < fi.paths.len) {
        const path = try util.validatePathIntoBuffer(fi.paths[fi._curIndex], fi._filePathBuffer[0..]);

        const kind: enum { dir, file, others } = blk: {
            const stat = dir.statFile(fi.io, path, .{}) catch |err| {
                if (err == error.FileNotFound) {
                    fi._curIndex += 1;
                    try fi.stderr.print("Path ({s}) is not found.\n", .{path});
                    try fi.stderr.flush();
                    continue;
                }

                if (err == error.IsDir) // for Windows
                    break :blk .dir;

                return err;
            };

            break :blk switch (stat.kind) {
                .directory => .dir,
                .file => .file,
                else => .others,
            };
        };
        switch (kind) {
            .dir => {
                var subDir = try dir.openDir(fi.io, path, .{ .iterate = true });
                if (fi.pathFilterFn(std.Io.Dir.path.basename(path))) {
                    const walker = subDir.walk(fi.allocator) catch |err| {
                        subDir.close(fi.io);
                        return err;
                    };

                    fi._dirWalker = walker;
                    fi._walkingDir = subDir;
                    fi._walkingDirPath = path;
                    return fi.next();
                }
                fi._curIndex += 1;
            },
            .file => {
                fi._curIndex += 1;
                return .{
                    .dir = dir,
                    .dirPath = ".",
                    .filePath = path,
                };
            },
            else => fi._curIndex += 1,
        }
    }

    fi._curIndex = 0; // ready to be reused.
    return null;
}
