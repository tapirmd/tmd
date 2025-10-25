const std = @import("std");

const DocTemplate = @This();

content: []const u8,
ownerFilePath: []const u8,

firstToken: ?*Token,
numTokens: usize,

pub const maxTemplateSize = 32 * 1024;

// Keep it simple. Not consider how to escape command tag chars.
// To escape command tag chars, put them in a line without pairing tag chars.

pub const Token = struct {
    next: ?*Token = null,

    type: union(enum) {
        text: []const u8,
        //tag: Tag,
        command: Command,
    } = undefined,

    //pub const Tag = struct {
    //    text: []const u8,
    //    type: enum {
    //        open,
    //        close,
    //    },
    //};

    pub const Command = struct {
        namePtr: [*]const u8, // muitlple names may share the same obj.
        nameLen: u32,

        tagLen: u32,

        obj: *const anyopaque,
        args: ?*Argument,

        cached: ?[]const u8 = null,

        pub const Argument = struct {
            next: ?*Argument = null,
            value: []const u8 = undefined,
        };

        pub fn name(self: @This()) []const u8 {
            return self.namePtr[0..self.nameLen];
        }
    };
};

pub fn parseTemplate(content: []const u8, ownerFilePath: []const u8, context: anytype, allocator: std.mem.Allocator, stderr: std.fs.File.Writer) !*DocTemplate {
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
        allocator: std.mem.Allocator,
        stderr: std.fs.File.Writer,

        fn newToken(parser: *@This()) !*Token {
            const t = try parser.allocator.create(Token);
            t.* = .{};
            parser.lastToken.next = t;
            parser.lastToken = t;
            return t;
        }

        fn createTextToken(parser: *@This(), start: usize, end: usize) !void {
            const t = try parser.newToken();
            t.type = .{ .text = parser.contentStart[start..end] };
        }

        fn createTagToken(parser: *@This(), start: usize, end: usize, isOpen: bool) !void {
            const t = try parser.newToken();
            t.type = .{ .tag = .{
                .text = parser.contentStart[start..end],
                .type = if (isOpen) .open else .close,
            } };
        }

        fn createCommandToken(parser: *@This(), start: usize, end: usize, tagLen: usize, ctx: anytype) !void {
            const t = try parser.newToken();
            t.type = .{ .command = try parser.parseCommand(parser.contentStart[start..end], tagLen, ctx) };
        }

        fn denyOpening(parser: *@This()) void {
            parser.tagOpening = false;
            parser.numOpenTagChars = 0;
            // parser.numCloseTagChars = 0;
        }

        fn tryConfirmCloseTag(parser: *@This(), at: usize, ctx: anytype) !bool {
            std.debug.assert(parser.tagOpening);

            if (parser.numCloseTagChars > 0) {
                if (parser.numCloseTagChars != parser.numOpenTagChars) parser.numCloseTagChars = 0 else {
                    try parser.onCloseTagConfirmed(at, ctx);
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

        fn onNewLine(parser: *@This(), at: usize, ctx: anytype) !void {
            if (parser.tagOpening) {
                if (try parser.tryConfirmCloseTag(at, ctx)) return;
            }

            parser.denyOpening();
        }

        fn onOtherChars(parser: *@This(), at: usize, ctx: anytype) !void {
            if (parser.tagOpening) {
                _ = try parser.tryConfirmCloseTag(at, ctx);
            } else {
                if (parser.numOpenTagChars > 0) {
                    if (parser.numOpenTagChars == 1) parser.numOpenTagChars = 0 else parser.onPendingOpenTagConfirmed(at, 0);
                }
            }
        }

        fn onEnd(parser: *@This(), at: usize) !void {
            std.debug.assert(at > parser.pendingOffset);
            try parser.createTextToken(parser.pendingOffset, at);
        }

        fn onCloseTagConfirmed(parser: *@This(), closeTagEndAt: usize, ctx: anytype) !void {
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
                try parser.createTextToken(parser.pendingOffset, openTagStart);
            } else std.debug.assert(openTagStart == parser.pendingOffset);

            //try parser.createTagToken(openTagStart, parser.pendingOpenTagEnd, true);
            const tagLen = parser.pendingOpenTagEnd - openTagStart;

            const closeTagStart = closeTagEndAt - parser.numOpenTagChars;
            if (closeTagStart > parser.pendingOpenTagEnd) {
                try parser.createCommandToken(parser.pendingOpenTagEnd, closeTagStart, tagLen, ctx);
            } else std.debug.assert(closeTagStart == parser.pendingOpenTagEnd);

            //try parser.createTagToken(closeTagStart, closeTagEndAt, false);

            parser.pendingOffset = closeTagEndAt;
            parser.denyOpening();
        }

        fn parseCommand(parser: *@This(), callContent: []const u8, tagLen: usize, ctx: anytype) !Token.Command {
            var it = std.mem.splitAny(u8, callContent, " \t");
            const cmdName = while (it.next()) |item| {
                if (item.len == 0) continue;
                break item;
            } else {
                try parser.stderr.print("error: DocTemplate command is not specified in file '{s}'.\n", .{parser.ownerFilePath});
                return error.TemplateCommandNotSpecified;
            };

            const obj = (try ctx.getTemplateCommandObject(cmdName)) orelse {
                try parser.stderr.print("error: DocTemplate command '{s}' in file '{s}' is not defined.\n", .{ cmdName, parser.ownerFilePath });
                return error.TemplateCommandNotDefined;
            };

            var headArg: Token.Command.Argument = .{};
            var lastArg: *Token.Command.Argument = &headArg;
            while (it.next()) |item| {
                if (item.len == 0) continue;
                const arg = try parser.allocator.create(Token.Command.Argument);
                arg.* = .{ .value = item };
                lastArg.next = arg;
                lastArg = arg;
            }

            return .{ .namePtr = cmdName.ptr, .nameLen = @intCast(cmdName.len), .obj = obj, .args = headArg.next, .tagLen = @intCast(tagLen)};
        }
    };

    var parser: Parser = .{
        .contentStart = content.ptr,
        .ownerFilePath = ownerFilePath,
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
            NewLineChar => try parser.onNewLine(@intCast(i), context),
            else => try parser.onOtherChars(@intCast(i), context),
        }
    } else try parser.onEnd(@intCast(content.len));

    const t = try allocator.create(DocTemplate);
    t.* = .{
        .content = content,
        .ownerFilePath = ownerFilePath,
        .firstToken = parser.headToken.next,
        .numTokens = parser.numTokens,
    };
    return t;
}

pub fn render(template: *DocTemplate, context: anytype) !void {
    var token = template.firstToken orelse return;
    while (true) {
        switch (token.type) {
            .text => |text| try context.onTemplateText(text),
            //.tag => |tag| try context.onTemplateTag(tag),
            .command => |command| try context.onTemplateCommand(command),
        }
        token = token.next orelse break;
    }
}
