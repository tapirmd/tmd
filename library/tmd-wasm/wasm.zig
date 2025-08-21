// This is a simple implementation which is mainly
// for "tmd fmt" and "tmd gen" commands.
//
// ToDo (maybe):
// A full implementation needs much more time and
// energy to careflluy make an elaborated design.

const std = @import("std");
const builtin = @import("builtin");

const tmd = @import("tmd");

extern fn print(addr: usize, len: usize, addr2: usize, len2: usize, extra: isize) void;

fn logMessage(msg: []const u8, extraMsg: []const u8, extraInt: isize) void {
    print(@intFromPtr(msg.ptr), msg.len, @intFromPtr(extraMsg.ptr), extraMsg.len, extraInt);
}

const maxOptionsDataSize = 4096;
const maxTmdDataSize = 2 << 20; // 2M // ToDo: add a max_tmd_size API?
const bufferSize = 7 * maxTmdDataSize;

var buffer: []u8 = "";
var docInfo: ?struct {
    tmdContent: []const u8,
    tmdDoc: tmd.Doc,
    remainingBuffer: []u8,
} = null;

export fn lib_version() isize {
    return @intCast(@intFromPtr(tmd.version.ptr));
}

export fn buffer_offset() isize {
    const bufferWithHeader = tryToInit() catch |err| {
        logMessage("init error: ", @errorName(err), @intFromError(err));
        const addr: isize = @intCast(@intFromPtr(@errorName(err).ptr));
        return -addr - 1; // assume address space < 2G. addr might be 0? so -1 here.
    };
    return @intCast(@intFromPtr(bufferWithHeader.ptr));
}

// return the start of free buffer (the end of the tmd.Doc).
export fn tmd_parse() isize {
    const remainingBuffer = parseTMD() catch |err| {
        logMessage("parse TMD error: ", @errorName(err), @intFromError(err));
        const addr: isize = @intCast(@intFromPtr(@errorName(err).ptr));
        return -addr - 1; // assume address space < 2G. addr might be 0? so -1 here.
    };
    return @intCast(@intFromPtr(remainingBuffer.ptr));
}

export fn tmd_title() isize {
    const titleWithLengthHeader = generatePageTitle() catch |err| {
        logMessage("generate page title error: ", @errorName(err), @intFromError(err));
        const addr: isize = @intCast(@intFromPtr(@errorName(err).ptr));
        return -addr - 1; // assume address space < 2G. addr might be 0? so -1 here.
    };
    return @intCast(@intFromPtr(titleWithLengthHeader.ptr));
}

export fn tmd_to_html() isize {
    const htmlWithLengthHeader = generateHTML() catch |err| {
        logMessage("generate HTML error: ", @errorName(err), @intFromError(err));
        const addr: isize = @intCast(@intFromPtr(@errorName(err).ptr));
        return -addr - 1; // assume address space < 2G. addr might be 0? so -1 here.
    };
    return @intCast(@intFromPtr(htmlWithLengthHeader.ptr));
}

export fn tmd_format() isize {
    const tmdWithLengthHeader = formatTMD() catch |err| {
        logMessage("format TMD error: ", @errorName(err), @intFromError(err));
        const addr: isize = @intCast(@intFromPtr(@errorName(err).ptr));
        return -addr - 1; // assume address space < 2G. addr might be 0? so -1 here.
    };
    return @intCast(@intFromPtr(tmdWithLengthHeader.ptr));
}

fn tryToInit() ![]u8 {
    if (buffer.len == 0) {
        buffer = try std.heap.wasm_allocator.alloc(u8, bufferSize);
        var fbs = std.io.fixedBufferStream(buffer);
        try fbs.writer().writeInt(u32, 0, .little);
    }

    return buffer;
}

const DataWithLengthHeader = struct {
    data: []const u8,

    fn size(self: @This()) usize {
        return self.data.len + @sizeOf(u32);
    }
};

fn retrieveData(dataBuffer: []const u8, maxAllowedSize: usize) !DataWithLengthHeader {
    var fbs = std.io.fixedBufferStream(dataBuffer);
    const dataLen = try fbs.reader().readInt(u32, .little);
    if (maxAllowedSize > 0 and dataLen > maxAllowedSize) {
        return error.DataSizeTooLarge;
    }

    const dataStart = @sizeOf(u32);
    const dataEnd = dataStart + dataLen;
    return .{ .data = dataBuffer[dataStart..dataEnd] };
}

fn parseTMD() ![]const u8 {
    if (buffer.len == 0) {
        return error.BufferNotCreatedYet;
    }

    // retrieve input tmd data

    const tmdInput = try retrieveData(buffer, maxTmdDataSize);
    const tmdContent = tmdInput.data;

    // parse tmd

    const docBuffer = buffer[tmdInput.size()..];

    var fba = std.heap.FixedBufferAllocator.init(docBuffer);
    const fbaAllocator = fba.allocator();

    const tmdDoc = try tmd.Doc.parse(tmdContent, fbaAllocator);

    // ...

    const remainingBuffer = docBuffer[fba.end_index..];

    docInfo = .{
        .tmdContent = tmdContent,
        .tmdDoc = tmdDoc,
        .remainingBuffer = remainingBuffer,
    };

    return remainingBuffer;
}

fn generatePageTitle() ![]const u8 {
    const tmdDoc, const remainingBuffer = if (docInfo) |info| .{
        info.tmdDoc,
        info.remainingBuffer,
    } else {
        return error.DocNotParsedYet;
    };

    // retrieve input options data

    const optionsInput = try retrieveData(remainingBuffer, maxOptionsDataSize);
    const optionsContent = optionsInput.data;

    _ = optionsContent; // not used now

    // gen title

    const titleBuffer = remainingBuffer[optionsInput.size()..];

    var fbs = std.io.fixedBufferStream(titleBuffer);
    try fbs.writer().writeInt(u32, 0, .little);

    const hasTitle = try tmdDoc.writePageTitle(fbs.writer());
    const titleWithLengthHeader = fbs.getWritten();

    try fbs.seekTo(0);
    try fbs.writer().writeInt(u32, if (hasTitle) titleWithLengthHeader.len - 4 else 0xFFFFFFFF, .little);

    //logMessage("", "generatePageTitle: titleWithLengthHeader.len: ", @intCast(titleWithLengthHeader.len));

    return titleWithLengthHeader;
}

fn generateHTML() ![]const u8 {
    const tmdDoc, const remainingBuffer = if (docInfo) |info| .{
        info.tmdDoc,
        info.remainingBuffer,
    } else {
        return error.DocNotParsedYet;
    };

    // retrieve input options data

    const optionsInput = try retrieveData(remainingBuffer, maxOptionsDataSize);
    const optionsContent = optionsInput.data;

    // parse options

    const optionsBuffer = remainingBuffer[optionsInput.size()..];

    var fba = std.heap.FixedBufferAllocator.init(optionsBuffer);
    const fbaAllocator = fba.allocator();

    const optionsConfig = (try tmd.Doc.parse(optionsContent, fbaAllocator)).asConfig();

    const enabledCustomApps = optionsConfig.stringValue("enabledCustomApps") orelse "";
    const identSuffix = optionsConfig.stringValue("identSuffix") orelse "";
    const autoIdentSuffix = optionsConfig.stringValue("autoIdentSuffix") orelse "";
    const renderRoot = blk: {
        const v = optionsConfig.stringValue("renderRoot") orelse "";
        if (v.len == 0) break :blk true;
        break :blk v[0] != 'f' and v[0] != 'F' and v[0] != 'n' and v[0] != 'N';
    };

    const supportHTML = blk: {
        var iter = std.mem.splitAny(u8, enabledCustomApps, ";,");
        var item = iter.first();
        while (true) {
            if (std.mem.eql(u8, item, "html")) break :blk true;
            if (item.len > 0) {
                return error.UnknownApp;
            }
            if (iter.next()) |next| item = next else break :blk false;
        }
    };

    // render file

    const renderBuffer = optionsBuffer[fba.end_index..];

    var fbs = std.io.fixedBufferStream(renderBuffer);
    try fbs.writer().writeInt(u32, 0, .little);

    const CallbackFactory = struct {
        var htmlGenCallback: tmd.GenCallback_HtmlBlock = undefined;

        fn getCustomBlockGenCallback(doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) ?tmd.GenCallback {
            const attrs = custom.attributes();
            if (std.ascii.eqlIgnoreCase(attrs.app, "html")) {
                std.debug.assert(doc == htmlGenCallback.doc);
                htmlGenCallback.custom = custom;
                return .init(&htmlGenCallback);
            }
            return null;
        }
    };
    CallbackFactory.htmlGenCallback.doc = &tmdDoc;

    const genOptions = tmd.GenOptions{
        .renderRoot = renderRoot,
        .identSuffix = identSuffix,
        .autoIdentSuffix = autoIdentSuffix,
        .getCustomBlockGenCallback = if (supportHTML) CallbackFactory.getCustomBlockGenCallback else null,
    };

    try tmdDoc.writeHTML(fbs.writer(), genOptions, std.heap.wasm_allocator);
    const htmlWithLengthHeader = fbs.getWritten();
    try fbs.seekTo(0);
    try fbs.writer().writeInt(u32, htmlWithLengthHeader.len - 4, .little);

    //logMessage("", "generateHTML: htmlWithLengthHeader.len: ", @intCast(htmlWithLengthHeader.len));

    return htmlWithLengthHeader;
}

fn formatTMD() ![]const u8 {
    const tmdContent, const tmdDoc, const remainingBuffer = if (docInfo) |info| .{
        info.tmdContent,
        info.tmdDoc,
        info.remainingBuffer,
    } else {
        return error.DocNotParsedYet;
    };

    // retrieve input options data

    const optionsInput = try retrieveData(remainingBuffer, maxOptionsDataSize);
    const optionsContent = optionsInput.data;

    _ = optionsContent; // not used now

    // format file

    const formatBuffer = remainingBuffer[optionsInput.size()..];

    var fbs = std.io.fixedBufferStream(formatBuffer);
    try fbs.writer().writeInt(u32, 0, .little);

    try tmdDoc.writeTMD(fbs.writer(), true);

    const tmdWithLengthHeader = fbs.getWritten();
    try fbs.seekTo(0);
    const length = if (std.mem.eql(u8, tmdContent, tmdWithLengthHeader[4..])) 0xFFFFFFFF else tmdWithLengthHeader.len - 4;
    try fbs.writer().writeInt(u32, length, .little);

    //logMessage("formatTMD: ", "tmdWithLengthHeader.len: ", @intCast(tmdWithLengthHeader.len));

    return tmdWithLengthHeader;
}
