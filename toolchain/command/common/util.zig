const std = @import("std");

const tmd = @import("tmd");

pub fn readFile(
    inputDir: ?std.fs.Dir,
    filePath: []const u8,
    manner: union(enum) {
        buffer: []u8,
        alloc: struct {
            allocator: std.mem.Allocator,
            maxFileSize: usize,
        },
    },
    stderr: *std.Io.Writer,
) ![]u8 {
    const dir = inputDir orelse std.fs.cwd();
    const file = dir.openFile(filePath, .{}) catch |err| {
        if (err == error.FileNotFound) {
            try stderr.print("File ({s}) is not found.\n", .{filePath});
            try stderr.flush();
        }
        return err;
    };
    defer file.close();

    const stat = try file.stat();

    const peekBuffer = switch (manner) {
        .buffer => |buffer| blk: {
            if (stat.size > buffer.len) {
                try stderr.print("File ({s}) size is too large ({} > {}).\n", .{ filePath, stat.size, buffer.len });
                try stderr.flush();
                return error.FileSizeTooLarge;
            }

            break :blk buffer;
        },
        .alloc => |alloc| blk: {
            if (stat.size > alloc.maxFileSize) {
                try stderr.print("File ({s}) size is too large ({} > {}).\n", .{ filePath, stat.size, alloc.maxFileSize });
                try stderr.flush();
                return error.FileSizeTooLarge;
            }

            break :blk try alloc.allocator.alloc(u8, stat.size);
        },
    };

    var file_reader = file.reader(peekBuffer);
    const content = try file_reader.interface.peek(stat.size);
    if (content.len != stat.size){
        try stderr.print("[{s}] read size not match ({} != {}).\n", .{ filePath, content.len, stat.size });
        try stderr.flush();
        return error.FileSizeNotMatch;
    }
    
    return content;
}

pub fn writeFile(inputDir: ?std.fs.Dir, filePath: []const u8, fileContent: []const u8) !void {
    const dir = inputDir orelse std.fs.cwd();

    if (std.fs.path.dirname(filePath)) |dirpath| try dir.makePath(dirpath);

    var file = try dir.createFile(filePath, .{});
    defer file.close();

    // tricky !!
    //var file_writer = file.writer(@constCast(fileContent));
    //file_writer.interface.end = fileContent.len;
    //try file_writer.interface.flush();
    // see: https://ziggit.dev/t/is-the-constcast-used-correctly-and-safely-with-the-0-15-new-io-design/12734
    var file_writer = file.writer(&.{});
    try file_writer.interface.writeAll(fileContent);
}

pub fn isFileInDir(filePath: []const u8, dir: []const u8) bool {
    if (filePath.len > dir.len and std.mem.startsWith(u8, filePath, dir)) {
        if (filePath[dir.len] == std.fs.path.sep) return true;
    }
    return false;
}

// dirPath should be already validated.
// If dirPath is relative, then it is relative to cwd.
// If pathToResolve is relative, then it is relative to dirPath.
// This function errors if the resolved path doesn't exit.
// The result is an absolute path.
pub fn resolveRealPath2(dirPath: []const u8, pathToResolve: []const u8, needValidatePath: bool, allocator: std.mem.Allocator) ![]u8 {
    var dir = try std.fs.cwd().openDir(dirPath, .{});
    defer dir.close();

    if (needValidatePath) {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const validPathToResolve = try validatePathIntoBuffer(pathToResolve, buffer[0..]);

        return try dir.realpathAlloc(allocator, validPathToResolve);
    }

    return try dir.realpathAlloc(allocator, pathToResolve);
}

// If pathToResolve is relative, then it is relative to cwd.
// This function errors if the resolved path doesn't exit.
// The result is an absolute path.
pub fn resolveRealPath(pathToResolve: []const u8, needValidate: bool, allocator: std.mem.Allocator) ![]u8 {
    if (needValidate) {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const validPathToResolve = try validatePathIntoBuffer(pathToResolve, buffer[0..]);
        return try std.fs.realpathAlloc(allocator, validPathToResolve);
    }

    return try std.fs.realpathAlloc(allocator, pathToResolve);
}

// absFilePath should be already validated.
// This function doesn't error if the resolved path doesn't exit.
// The result might be not an absolute path.
pub fn resolvePathFromFilePath(absFilePath: []const u8, pathToResolve: []const u8, needValidatePath: bool, allocator: std.mem.Allocator) ![]const u8 {
    //var buffer1: [std.fs.max_path_bytes]u8 = undefined;
    //const validFilePath = try validatePathIntoBuffer(absFilePath, buffer1[0..]);
    //const absDirPath = std.fs.path.dirname(validFilePath) orelse return error.NotFilePath;
    const absDirPath = std.fs.path.dirname(absFilePath) orelse return error.NotFilePath;

    if (needValidatePath) {
        var buffer2: [std.fs.max_path_bytes]u8 = undefined;
        const validPathToResolve = try validatePathIntoBuffer(pathToResolve, buffer2[0..]);
        return try std.fs.path.resolve(allocator, &.{ absDirPath, validPathToResolve });
    }

    return try std.fs.path.resolve(allocator, &.{ absDirPath, pathToResolve });
}

// absDirPath should be already validated.
// This function doesn't error if the resolved path doesn't exit.
// The result might be not an absolute path.
pub fn resolvePathFromAbsDirPath(absDirPath: []const u8, pathToResolve: []const u8, needValidatePath: bool, allocator: std.mem.Allocator) ![]const u8 {
    //var buffer1: [std.fs.max_path_bytes]u8 = undefined;
    //const validDirPath = try validatePathIntoBuffer(absDirPath, buffer1[0..]);

    if (needValidatePath) {
        var buffer2: [std.fs.max_path_bytes]u8 = undefined;
        const validPathToResolve = try validatePathIntoBuffer(pathToResolve, buffer2[0..]);
        return try std.fs.path.resolve(allocator, &.{ absDirPath, validPathToResolve });
    }

    return try std.fs.path.resolve(allocator, &.{ absDirPath, pathToResolve });
}

pub fn validatePathIntoBuffer(pathToValidate: []const u8, buffer: []u8) ![]const u8 {
    return _validatePathIntoBuffer(pathToValidate, buffer, std.fs.path.sep);
}

pub fn validatePathToPosixPathIntoBuffer(pathToValidate: []const u8, buffer: []u8) ![]const u8 {
    return _validatePathIntoBuffer(pathToValidate, buffer, std.fs.path.sep_posix);
}

fn _validatePathIntoBuffer(pathToValidate: []const u8, buffer: []u8, comptime sep: u8) ![]const u8 {
    if (pathToValidate.len > buffer.len) {
        return error.ValidatedPathTooLong;
    }

    const non_sep = if (sep == '/') '\\' else '/';

    std.debug.assert(pathToValidate.len <= buffer.len);

    for (pathToValidate, 0..) |c, i| {
        if (c == non_sep) {
            for (pathToValidate, 0..i) |c2, k| buffer[k] = c2;
            buffer[i] = sep;
            for (pathToValidate[i + 1 ..], i + 1..) |c2, k| {
                buffer[k] = if (c2 == non_sep) sep else c2;
            }
            return buffer[0..pathToValidate.len];
        }
    }

    return pathToValidate;
}

//pub fn validateURL(urlToValidate: []u8, allocator: std.mem.Allocator) !struct { []const u8, bool } {
//    if (std.mem.containsAtLeastScalar(u8, urlToValidate, 1, '\\')) {
//        const dup = try allocator.dupe(u8, urlToValidate);
//        std.mem.replaceScalar(u8, dup, '\\', '/');
//        return .{ dup, true };
//    }
//    return .{ urlToValidate, false };
//}

// validatedPath uses OS specified seperator.
pub fn validatedPathToPosixPath(validatedPath: []const u8, allocator: std.mem.Allocator) []const u8 {
    if (std.fs.path.sep == std.fs.path.sep_posix) return validatedPath;

    const dup = try allocator.dupe(u8, validatedPath);
    std.mem.replaceScalar(u8, dup, std.fs.path.sep, std.fs.path.sep_posix);
    return dup;
}

// prefix and suffix have already used posix seperator.
// validatedPath uses OS specified seperator.
pub fn buildPosixPath(prefix: []const u8, validatedPath: []const u8, suffix: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const out = try std.mem.concat(allocator, u8, &.{ prefix, validatedPath, suffix });
    if (std.fs.path.sep != std.fs.path.sep_posix) {
        std.mem.replaceScalar(u8, out[prefix.len .. prefix.len + validatedPath.len], std.fs.path.sep, std.fs.path.sep_posix);
    }
    return out;
}

// prefix has already used posix seperator.
pub fn buildPosixPathWithContentHashBase64(prefix: []const u8, fileBasename: []const u8, fileContent: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const hash = sha256Hash(fileContent);
    const encoder = std.base64.standard_no_pad.Encoder;
    const encoded_len = encoder.calcSize(hash.len);

    const sep = "-";

    const ext = std.fs.path.extension(fileBasename);
    const barename = fileBasename[0 .. fileBasename.len - ext.len];

    const n = prefix.len + barename.len + sep.len;

    const out = try allocator.alloc(u8, n + encoded_len + ext.len);
    {
        var info = out;
        @memcpy(info[0..prefix.len], prefix);
        info = info[prefix.len..];
        @memcpy(info[0..barename.len], barename);
        info = info[barename.len..];
        @memcpy(info[0..sep.len], sep);

        info = out[out.len - ext.len ..];
        @memcpy(info[0..ext.len], ext);
    }
    {
        const encoded = out[n..];
        _ = encoder.encode(encoded, &hash);
    }

    return out;
}

const HashHexString = struct {
    fn HashHexString() type {
        const hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        return @TypeOf(std.fmt.bytesToHex(&hash, .lower));
    }
}.HashHexString();

fn sha256Hash(data: []const u8) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&hash);
    return hash;
}

fn hashHex(data: []const u8) HashHexString {
    const hash = sha256Hash(data);
    return std.fmt.bytesToHex(&hash, .lower);
}

//pub fn isStringInList(str: []const u8, list: []const []const u8, comptime ignoreCases: bool) bool {
//    if (ignoreCases) for (list) |s| {
//        if (std.ascii.eqlIgnoreCase(str, s) return true;
//    } else for (list) |s| {
//        if (std.mem.eql(str, s) return true;
//    }
//    return false;
//}

pub fn buildHashString(fileContent: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const hashStr = try allocator.create(@TypeOf(sha256Hash("")));
    hashStr.* = sha256Hash(fileContent);
    return hashStr;
}

pub fn buildHashHexString(fileContent: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const hashHexStr = try allocator.create(HashHexString);
    hashHexStr.* = hashHex(fileContent);
    return hashHexStr;
}

// folder and sep should be already lower-cased.
// All other parts will be lowered case, so that the output is wholly lowered-case.
pub fn buildAssetFilePath(folder: []const u8, sep: u8, fileBasename: []const u8, fileContent: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const hashHexStr = hashHex(fileContent);

    const ext = std.fs.path.extension(fileBasename);
    const filename = fileBasename[0 .. fileBasename.len - ext.len];

    const sepStr: [1]u8 = .{sep};
    const out = try std.mem.concat(allocator, u8, &.{ folder, &sepStr, filename, "-", hashHexStr[0..], ext });
    {
        const n = folder.len + sepStr.len;
        const outFilename = out[n .. n + filename.len];
        _ = std.ascii.lowerString(outFilename, outFilename);
    }
    {
        const n = out.len - ext.len;
        const outExt = out[n .. n + ext.len];
        _ = std.ascii.lowerString(outExt, outExt);
    }
    return out;
}

// e.g.: data:image/jpeg;base64,<BASE64-string>
pub fn buildEmbeddedImageHref(extType: tmd.Extension, fileContent: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const imageMimeType = tmd.getExtensionInfo(extType).mime;

    const prefix = "data:";
    const middle = ";base64,";

    const n = prefix.len + imageMimeType.len + middle.len;

    const encoder = std.base64.standard_no_pad.Encoder;
    const encoded_len = encoder.calcSize(fileContent.len);

    const out = try allocator.alloc(u8, n + encoded_len);
    {
        var info = out[0..n];
        @memcpy(info[0..prefix.len], prefix);
        info = info[prefix.len..];
        @memcpy(info[0..imageMimeType.len], imageMimeType);
        info = info[imageMimeType.len..];
        @memcpy(info[0..middle.len], middle);
    }
    {
        const encoded = out[n..];
        _ = encoder.encode(encoded, fileContent);
    }

    return out;
}

pub fn findCommonPaths(a: []const u8, b: []const u8, sep: u8) []const u8 {
    const pa, const pb = if (a.len < b.len) .{ a, b } else .{ b, a };

    var i: usize = 0;
    while (i < pa.len) : (i += 1) {
        if (pa[i] != pb[i]) break;
    }
    if (i == 0) return "";
    if (i == pa.len) {
        if (pa.len == pb.len) return pa;
        if (pb[i] == sep) return pb[0 .. i + 1]; // ends with sep
    }
    std.debug.assert(i > 0);
    while (true) {
        i -= 1;
        if (pb[i] == sep) {
            return pb[0 .. i + 1]; // ends with sep
        }
        if (i == 0) return "";
    }
}

pub fn relativePath(relativeTo: []const u8, path: []const u8, sep: u8) struct { usize, []const u8 } {
    const c = findCommonPaths(relativeTo, path, sep);
    const d = if (c.len > relativeTo.len) blk: {
        std.debug.assert(c.len == relativeTo.len + 1 and c[relativeTo.len] == sep);
        break :blk relativeTo;
    } else relativeTo[c.len..];

    var n: usize = 0;
    for (d) |r| {
        if (r == sep) n += 1;
    }
    if (c.len > path.len) {
        std.debug.assert(c.len == path.len + 1 and c[path.len] == sep);
        return .{ n, "" };
    }
    return .{ n, path[c.len..] };
}
