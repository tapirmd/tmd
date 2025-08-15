const std = @import("std");

const AppContext = @import("AppContext.zig");

pub fn readFileIntoBuffer(ctx: AppContext, dir: std.fs.Dir, filePath: []const u8, buffer: []u8) ![]u8 {
    const file = dir.openFile(filePath, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try ctx.stderr.print("File ({s}) is not found.\n", .{filePath});
        }
        return err;
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.size > buffer.len) {
        try ctx.stderr.print("File ({s}) size is too large ({} > {}).\n", .{ filePath, stat.size, buffer.len });
        return error.FileSizeTooLarge;
    }

    const readSize = try file.readAll(buffer[0..stat.size]);
    if (stat.size != readSize) {
        try ctx.stderr.print("[{s}] read size not match ({} != {}).\n", .{ filePath, stat.size, readSize });
        return error.FileSizeNotMatch;
    }
    return buffer[0..readSize];
}


// If dirPath is relative, then it is relative to cwd.
// If pathToResolve is relative, then it is relative to dirPath.
pub fn resolveRealPath2(_: *const AppContext, dirPath: []const u8, pathToResolve: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;

    const validDirPath = validatePath(dirPath, buffer[0..]);

    var dir = try std.fs.cwd().openDir(validDirPath, .{});
    defer dir.close();
    
    const validPathToResolve = validatePath(pathToResolve, buffer[0..]);

    return try dir.realpathAlloc(allocator, validPathToResolve);
}

// If pathToResolve is relative, then it is relative to cwd.
pub fn resolveRealPath(_: *const AppContext, pathToResolve: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;

    const validPathToResolve = validatePath(pathToResolve, buffer[0..]);

    return try std.fs.realpathAlloc(allocator, validPathToResolve);
}

pub fn resolvePathFromFilePath(_: *const AppContext, absFilePath: []const u8, pathToResolve: []const u8, allocator: std.mem.Allocator) ![]const u8{
    var buffer1: [std.fs.max_path_bytes]u8 = undefined;
    const validFilePath = validatePath(absFilePath, buffer1[0..]);
    const absDirPath = std.fs.path.dirname(validFilePath) orelse return error.NotFilePath;
    
    var buffer2: [std.fs.max_path_bytes]u8 = undefined;
    const validPathToResolve = validatePath(pathToResolve, buffer2[0..]);

    return try std.fs.path.resolve(allocator, &.{ absDirPath, validPathToResolve });
}

pub fn resolvePathFromAbsDirPath(_: *const AppContext, absDirPath: []const u8, pathToResolve: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var buffer1: [std.fs.max_path_bytes]u8 = undefined;
    const validDirPath = validatePath(absDirPath, buffer1[0..]);
    
    var buffer2: [std.fs.max_path_bytes]u8 = undefined;
    const validPathToResolve = validatePath(pathToResolve, buffer2[0..]);
    
    return try std.fs.path.resolve(allocator, &.{ validDirPath, validPathToResolve });
}

pub fn validatePath(pathToValidate: []const u8, buffer: []u8) []const u8 {
    const sep = std.fs.path.sep;
    const non_sep = if (sep == '/') '\\' else '/';

    std.debug.assert(pathToValidate.len <= buffer.len);

    for (pathToValidate, 0..) |c, i| {
        if (c == non_sep) {
            for (pathToValidate, 0..i) |c2, k| buffer[k] = c2;
            buffer[i] = sep;
            for (pathToValidate[i+1..], i+1..) |c2, k| {
                buffer[k] = if (c2 == non_sep) sep else c2;
            }
            return buffer[0..pathToValidate.len];
        }
    }

    return pathToValidate;
}

pub fn validateURL(urlToValidate: []u8, allocator: std.mem.Allocator) !struct{[]const u8, bool} {
    if (std.mem.containsAtLeastScalar(u8, urlToValidate, 1, '\\')) {
        const dup = try allocator.dupe(u8, urlToValidate);
        std.mem.replaceScalar(u8, dup, '\\', '/');
        return .{dup, true};
    }
    return .{urlToValidate, false};
}

pub fn readFile(ctx: *const AppContext, absFilePath: []const u8, allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
    const file = std.fs.cwd().openFile(absFilePath, .{}) catch |err| {
        if (err == error.FileNotFound) {
            ctx.stderr.print("File ({s}) is not found.\n", .{absFilePath}) catch {};
        }
        return err;
    };
    defer file.close();

    return try file.readToEndAlloc(allocator, max_bytes);
}

