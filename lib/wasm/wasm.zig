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

const maxGenOptionsDataSize = 4096;
const maxTmdDataSize = 2 << 20; // 2M // ToDo: add a max_tmd_size API?
const bufferSize = 7 * maxTmdDataSize;

var buffer: []u8 = "";

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
    }

    return buffer;
}

const DataWithLengthHeader = struct {
    data: []const u8,

    fn size(self: @This()) usize {
        return self.data.len + @sizeOf(u32);
    }
};

fn writeBlankTmdData(dataBuffer: []const u8) !void {
    var fbs = std.io.fixedBufferStream(dataBuffer);
    try fbs.writer().writeInt(u32, 0, .little);
}

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

fn customFn(w: std.io.AnyWriter, doc: *const tmd.Doc, custom: *const tmd.BlockType.Custom) anyerror!void {
    const attrs = custom.attributes();
    if (std.ascii.eqlIgnoreCase(attrs.app, "html")) blk: {
        var line = custom.startDataLine() orelse break :blk;
        const endDataLine = custom.endDataLine().?;
        std.debug.assert(endDataLine.lineType == .data);

        while (true) {
            std.debug.assert(line.lineType == .data);

            _ = try w.write(doc.rangeData(line.range(.trimLineEnd)));
            _ = try w.write("\n");

            if (line == endDataLine) break;
            line = line.next() orelse unreachable;
        }
    }
}

const GenOptions = struct {
    enabledCustomApps: []const u8 = "",
    identSuffix: []const u8 = "",
    autoIdentSuffix: []const u8 = "",
    renderRoot: bool = true,
};

fn generateHTML() ![]u8 {
    if (buffer.len == 0) {
        return error.BufferNotCreatedYet;
    }

    var remainingBuffer = buffer;

    // retrieve inputs

    const tmdInput = try retrieveData(remainingBuffer, maxTmdDataSize);
    const tmdContent = tmdInput.data;
    remainingBuffer = remainingBuffer[tmdInput.size()..];

    const optionsInput = try retrieveData(remainingBuffer, maxGenOptionsDataSize);
    const optionsContent = optionsInput.data;
    remainingBuffer = remainingBuffer[optionsInput.size()..];

    // parse tmd

    var fba = std.heap.FixedBufferAllocator.init(remainingBuffer);
    const fbaAllocator = fba.allocator();

    const tmdDoc = try tmd.Doc.parse(tmdContent, fbaAllocator);

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

    //logMessage("", "tmdDataLength: ", @intCast(tmdDataLength));
    //logMessage("", "fba.end_index: ", @intCast(fba.end_index));

    const renderBuffer = try fbaAllocator.alloc(u8, remainingBuffer.len - fba.end_index);
    var fbs = std.io.fixedBufferStream(renderBuffer);
    try fbs.writer().writeInt(u32, 0, .little);

    const genOptions = tmd.GenOptions{
        .customFn = if (supportHTML) customFn else null,
        .identSuffix = identSuffix,
        .autoIdentSuffix = autoIdentSuffix,
        .renderRoot = renderRoot,
    };

    try tmdDoc.writeHTML(fbs.writer(), genOptions, std.heap.wasm_allocator);
    const htmlWithLengthHeader = fbs.getWritten();
    try fbs.seekTo(0);
    try fbs.writer().writeInt(u32, htmlWithLengthHeader.len - 4, .little);

    //logMessage("", "htmlWithLengthHeader.len: ", @intCast(htmlWithLengthHeader.len));

    return htmlWithLengthHeader;
}

fn formatTMD() ![]u8 {
    if (buffer.len == 0) {
        return error.BufferNotCreatedYet;
    }

    var remainingBuffer = buffer;

    // retrieve inputs

    const tmdInput = try retrieveData(remainingBuffer, maxTmdDataSize);
    const tmdContent = tmdInput.data;
    remainingBuffer = remainingBuffer[tmdInput.size()..];

    const optionsInput = try retrieveData(remainingBuffer, maxGenOptionsDataSize);
    const optionsContent = optionsInput.data;
    remainingBuffer = remainingBuffer[optionsInput.size()..];
    if (optionsContent.len > 0) {
        // ToDo: now, no options for fmt
    }

    // parse tmd

    var fba = std.heap.FixedBufferAllocator.init(remainingBuffer);
    const fbaAllocator = fba.allocator();

    var tmdDoc = try tmd.Doc.parse(tmdContent, fbaAllocator);

    // format file

    const formatBuffer = try fbaAllocator.alloc(u8, remainingBuffer.len - fba.end_index);
    var fbs = std.io.fixedBufferStream(formatBuffer);
    try fbs.writer().writeInt(u32, 0, .little);

    try tmdDoc.writeTMD(fbs.writer(), true);

    const tmdWithLengthHeader = fbs.getWritten();
    try fbs.seekTo(0);
    const length = if (std.mem.eql(u8, tmdContent, tmdWithLengthHeader[4..])) 0 else tmdWithLengthHeader.len - 4;
    try fbs.writer().writeInt(u32, length, .little);

    //logMessage("", "tmdWithLengthHeader.len: ", @intCast(tmdWithLengthHeader.len));

    return tmdWithLengthHeader;
}
