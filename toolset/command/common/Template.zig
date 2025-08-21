const std = @import("std");

const Template = @This();

content: []const u8,
ownerFilePath: []const u8,

firstToken: ?*Token,
numTokens: usize,

pub const maxTemplateSize = 32 * 1024;

// Keep it simple. Not consider how to escape function tag chars.
// To escape function tag chars, put them in a line without pairing tag chars.

pub const Token = struct {
    next: ?*Token = null,

    type: union(enum) {
        text: []const u8,
        tag: []const u8,
        call: FunctionCall,
    } = undefined,

    pub const String = struct {
        ptr: [*]const u8 = undefined,
        len: usize = undefined,
    };

    pub const FunctionCall = struct {
        func: *const anyopaque,
        args: ?*Argument,

        pub const Argument = struct {
            next: ?*Argument = null,
            value: []const u8 = undefined,
        };
    };
};

pub fn parseTemplate(content: []const u8, ownerFilePath: []const u8, functionsMap: std.StringHashMap(*const anyopaque), allocator: std.mem.Allocator, stderr: std.fs.File.Writer) !*Template {
    if (content.len > maxTemplateSize) return error.TemplateSizeTooLarge;

    // std.debug.print("========== content:\n\n{s}\n\n", .{content});

    const Parser = struct {
        tagOpening: bool = undefined,
        numOpenTagChars: usize = undefined,
        numCloseTagChars: usize = undefined,

        pendingOffset: usize = 0,
        pendingOpenTagEnd: usize = undefined,

        headToken: Token = .{},
        lastToken: *Token = undefined,
        numTokens: usize = 0,

        contentStart: [*]const u8,
        ownerFilePath: []const u8,
        functionsMap: std.StringHashMap(*const anyopaque),
        allocator: std.mem.Allocator,
        stderr: std.fs.File.Writer,

        fn createToken(parser: *@This(), tokenType: std.meta.Tag(std.meta.FieldType(Token, .type)), start: usize, end: usize) !void {
            const t = try parser.allocator.create(Token);
            t.* = .{};
            parser.lastToken.next = t;
            parser.lastToken = t;

            switch (tokenType) {
                inline .text, .tag => |at| {
                    t.type = @unionInit(@TypeOf(t.type), @tagName(at), parser.contentStart[start..end]);
                },
                .call => {
                    const func, const args = try parser.parseFunctionCall(parser.contentStart[start..end]);
                    t.type = .{ .call = .{ .func = func, .args = args } };
                },
            }
        }

        fn denyOpening(parser: *@This()) void {
            parser.tagOpening = false;
            parser.numOpenTagChars = 0;
            // parser.numCloseTagChars = 0;
        }

        fn tryConfirmCloseTag(parser: *@This(), at: usize) !bool {
            std.debug.assert(parser.tagOpening);

            if (parser.numCloseTagChars > 0) {
                if (parser.numCloseTagChars != parser.numOpenTagChars) parser.numCloseTagChars = 0 else {
                    try parser.onCloseTagConfirmed(at);
                    return true;
                }
            }

            return false;
        }

        fn onPendingOpenTagConfirmed(parser: *@This(), openTagEndAt: usize, initialNumCloseTagChars: usize) void {
            parser.tagOpening = true;
            parser.pendingOpenTagEnd = openTagEndAt;
            parser.numCloseTagChars = initialNumCloseTagChars;

            //std.debug.print(">>> {}\n", .{parser.pendingOpenTagEnd});
        }

        fn onNewLine(parser: *@This(), at: usize) !void {
            if (parser.tagOpening) {
                if (try parser.tryConfirmCloseTag(at)) return;
            }

            parser.denyOpening();
        }

        fn onOtherChars(parser: *@This(), at: usize, atEnd: bool) !void {
            if (atEnd) {
                std.debug.assert(at > parser.pendingOffset);
                try parser.createToken(.text, parser.pendingOffset, at);
                return;
            }

            if (parser.tagOpening) {
                _ = try parser.tryConfirmCloseTag(at);
            } else {
                if (parser.numOpenTagChars > 0) {
                    if (parser.numOpenTagChars == 1) parser.numOpenTagChars = 0 else parser.onPendingOpenTagConfirmed(at, 0);
                }
            }
        }

        fn onCloseTagConfirmed(parser: *@This(), closeTagEndAt: usize) !void {
            std.debug.assert(parser.numCloseTagChars == parser.numOpenTagChars);
            std.debug.assert(parser.numCloseTagChars > 1);

            //std.debug.print(
            //    \\=========
            //    \\  parser.pendingOffset={}
            //    \\  parser.pendingOpenTagEnd={}
            //    \\  closeTagEndAt={}
            //    \\  parser.numCloseTagChars={}
            //    \\
            //    , .{parser.pendingOffset, parser.pendingOpenTagEnd, closeTagEndAt, parser.numCloseTagChars});

            const openTagStart = parser.pendingOpenTagEnd - parser.numOpenTagChars;
            if (openTagStart > parser.pendingOffset) {
                try parser.createToken(.text, parser.pendingOffset, openTagStart);
            } else std.debug.assert(openTagStart == parser.pendingOffset);

            try parser.createToken(.tag, openTagStart, parser.pendingOpenTagEnd);

            const closeTagStart = closeTagEndAt - parser.numOpenTagChars;
            if (closeTagStart > parser.pendingOpenTagEnd) {
                try parser.createToken(.call, parser.pendingOpenTagEnd, closeTagStart);
            } else std.debug.assert(closeTagStart == parser.pendingOpenTagEnd);

            try parser.createToken(.tag, closeTagStart, closeTagEndAt);

            parser.pendingOffset = closeTagEndAt;
            parser.denyOpening();
        }

        fn parseFunctionCall(parser: *@This(), callContent: []const u8) !struct { *const anyopaque, ?*Token.FunctionCall.Argument } {
            var it = std.mem.splitAny(u8, callContent, " \t");
            const funcName = while (it.next()) |item| {
                if (item.len == 0) continue;
                break item;
            } else {
                try parser.stderr.print("error: A template function is not unspecified in file '{s}' is not found.\n", .{parser.ownerFilePath});
                return error.TemplateFunctionNotSpecified;
            };

            const func = parser.functionsMap.get(funcName) orelse {
                try parser.stderr.print("error: Template function '{s}' in file '{s}' is not found.\n", .{ funcName, parser.ownerFilePath });
                return error.TemplateFunctionNotFound;
            };

            var headArg: Token.FunctionCall.Argument = .{};
            var lastArg: *Token.FunctionCall.Argument = &headArg;
            while (it.next()) |item| {
                if (item.len == 0) continue;
                const arg = try parser.allocator.create(Token.FunctionCall.Argument);
                arg.* = .{ .value = item };
                lastArg.next = arg;
                lastArg = arg;
            }

            return .{ func, headArg.next };
        }
    };

    var parser: Parser = .{
        .contentStart = content.ptr,
        .ownerFilePath = ownerFilePath,
        .functionsMap = functionsMap,
        .allocator = allocator,
        .stderr = stderr,
    };
    parser.lastToken = &parser.headToken;

    parser.denyOpening();

    const OpenTagChar = '{';
    const CloseTagChar = '}';
    const NewLineChar = '\n';

    for (content, 0..) |c, i| {
        switch (c) {
            OpenTagChar => {
                if (!parser.tagOpening) parser.numOpenTagChars += 1;
            },
            CloseTagChar => {
                if (parser.tagOpening) parser.numCloseTagChars += 1 else if (parser.numOpenTagChars > 1) parser.onPendingOpenTagConfirmed(@intCast(i), 1);
            },
            NewLineChar => try parser.onNewLine(@intCast(i)),
            else => try parser.onOtherChars(@intCast(i), false),
        }
    } else try parser.onOtherChars(@intCast(content.len), true);

    const t = try allocator.create(Template);
    t.* = .{
        .content = content,
        .ownerFilePath = ownerFilePath,
        .firstToken = parser.headToken.next,
        .numTokens = parser.numTokens,
    };
    return t;
}

pub fn render(template: *Template, renderCallBacks: anytype) !void {
    var token = template.firstToken orelse return;
    while (true) {
        switch (token.type) {
            .text => |text| try renderCallBacks.writeText(text),
            .tag => |tagText| try renderCallBacks.onTag(tagText),
            .call => |call| try renderCallBacks.callFunction(call.func, call.args),
        }
        token = token.next orelse break;
    }
}
