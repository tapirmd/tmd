const std = @import("std");

const tmd = @import("tmd.zig");

pub fn writeOpenTag(w: *std.Io.Writer, tag: []const u8, classesSeperatedBySpace: []const u8, attributes: ?*const tmd.ElementAttibutes, identSuffix: []const u8, endAndWriteNewLine: ?bool) !void {
    std.debug.assert(tag.len > 0);

    try w.writeAll("<");
    try w.writeAll(tag);
    try writeBlockAttributes(w, classesSeperatedBySpace, attributes, identSuffix);
    if (endAndWriteNewLine) |write| {
        try w.writeAll(">");
        if (write) try w.writeAll("\n");
    }
}

pub fn writeCloseTag(w: *std.Io.Writer, tag: []const u8, writeNewLine: bool) !void {
    std.debug.assert(tag.len > 0);

    try w.writeAll("</");
    try w.writeAll(tag);
    try w.writeAll(">");
    if (writeNewLine) try w.writeAll("\n");
}

pub fn writeBareTag(w: *std.Io.Writer, tag: []const u8, classesSeperatedBySpace: []const u8, attributes: ?*const tmd.ElementAttibutes, identSuffix: []const u8, writeNewLine: bool) !void {
    std.debug.assert(tag.len > 0);

    try w.writeAll("<");
    try w.writeAll(tag);
    try writeBlockAttributes(w, classesSeperatedBySpace, attributes, identSuffix);
    try w.writeAll("/>");
    if (writeNewLine) try w.writeAll("\n");
}

pub fn writeBlockAttributes(w: *std.Io.Writer, classesSeperatedBySpace: []const u8, attributes: ?*const tmd.ElementAttibutes, identSuffix: []const u8) !void {
    if (attributes) |as| {
        if (as.id.len != 0) try writeID(w, as.id, identSuffix);
        try writeClasses(w, classesSeperatedBySpace, as.classes);
    } else {
        try writeClasses(w, classesSeperatedBySpace, "");
    }
}

pub fn writeID(w: *std.Io.Writer, id: []const u8, identSuffix: []const u8) !void {
    try w.writeAll(" id=\"");
    try w.writeAll(id);
    if (identSuffix.len > 0) try w.writeAll(identSuffix);
    try w.writeAll("\"");
}

pub fn writeClasses(w: *std.Io.Writer, classesSeperatedBySpace: []const u8, classesSeperatedBySemicolon: []const u8) !void {
    if (classesSeperatedBySpace.len == 0 and classesSeperatedBySemicolon.len == 0) return;

    try w.writeAll(" class=\"");
    var needSpace = classesSeperatedBySpace.len > 0;
    if (needSpace) try w.writeAll(classesSeperatedBySpace);
    if (classesSeperatedBySemicolon.len > 0) {
        var it = std.mem.splitAny(u8, classesSeperatedBySemicolon, ";");
        var item = it.first();
        while (true) {
            if (item.len != 0) {
                if (needSpace) try w.writeAll(" ") else needSpace = true;
                try w.writeAll(item);
            }

            if (it.next()) |next| {
                item = next;
            } else break;
        }
    }
    try w.writeAll("\"");
}

pub fn writeHtmlAttributeValue(w: *std.Io.Writer, text: []const u8) !void {
    var last: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '"' => {
                try w.writeAll(text[last..i]);
                try w.writeAll("&quot;");
                last = i + 1;
            },
            //'\'' => {
            //    try w.writeAll(text[last..i]);
            //    try w.writeAll("&apos;");
            //    last = i + 1;
            //},
            '&' => {
                try w.writeAll(text[last..i]);
                try w.writeAll("&amp;");
                last = i + 1;
            },
            '<' => {
                try w.writeAll(text[last..i]);
                try w.writeAll("&lt;");
                last = i + 1;
            },
            '>' => {
                try w.writeAll(text[last..i]);
                try w.writeAll("&gt;");
                last = i + 1;
            },
            else => {},
        }
    }
    try w.writeAll(text[last..i]);
}

// It is (very) hard to implement a perfect function to do this.
// Here, I don't pursue the perfection.
// We only avoid over-processing and breaking outputted html.
pub fn writeUrlAttributeValue(w: *std.Io.Writer, text: []const u8, isRelativePath: bool) !void {
    // If isRelativePath, then
    //    \ will be write as /
    //    %, &, ?, # will be escaped as %mn
    // otherwise, these chars are kept unchanged.
    //
    // For other chars, the two are kept unchanged.
    //
    // The other chars are handled the same for all cases.

    var last: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\\' => if (isRelativePath) {
                try w.writeAll(text[last..i]);
                try w.writeByte('/');
                last = i + 1;
            },
            '%', '#', '&', '?' => |c| if (isRelativePath) {
                try w.writeAll(text[last..i]);
                //try w.writeAll("&amp;");
                try w.writeByte('%');
                try w.writeByte(std.fmt.hex_charset[c >> 4]);
                try w.writeByte(std.fmt.hex_charset[c & 15]);
                last = i + 1;
            },
            '`', '~', '!', '@', '$', '^', '*', '(', ')', '-', '+', '_', '=', '{', '}', '[', ']', ':', ';', '<', '>', ',', '.', '/', 'A'...'Z', 'a'...'z', '0'...'9' => {
                // output as is.
            },
            //'\'' => {
            //    try w.writeAll(text[last..i]);
            //    try w.writeAll("&apos;");
            //    last = i + 1;
            //},
            else => |c| { // including '"', '\'', and spaces etc.
                try w.writeAll(text[last..i]);
                try w.writeByte('%');
                try w.writeByte(std.fmt.hex_charset[c >> 4]);
                try w.writeByte(std.fmt.hex_charset[c & 15]);
                last = i + 1;
            },
        }
    }
    try w.writeAll(text[last..i]);
}

pub fn writeRelativeUrlAttributeValue(w: *std.Io.Writer, text: []const u8) !void {
    var last: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\\' => {
                try w.writeAll(text[last..i]);
                try w.writeAll("/");
                last = i + 1;
            },
            ' ', '\t' => {
                try w.writeAll(text[last..i]);
                try w.writeAll("%20");
                last = i + 1;
            },
            '"' => {
                try w.writeAll(text[last..i]);
                try w.writeAll("&quot;");
                last = i + 1;
            },
            //'\'' => {
            //    try w.writeAll(text[last..i]);
            //    try w.writeAll("&apos;");
            //    last = i + 1;
            //},
            '&' => {
                try w.writeAll(text[last..i]);
                try w.writeAll("&amp;");
                last = i + 1;
            },
            '<' => {
                try w.writeAll(text[last..i]);
                try w.writeAll("&lt;");
                last = i + 1;
            },
            '>' => {
                try w.writeAll(text[last..i]);
                try w.writeAll("&gt;");
                last = i + 1;
            },
            else => {},
        }
    }
    try w.writeAll(text[last..i]);
}

pub fn writeHtmlContentText(w: *std.Io.Writer, text: []const u8) !void {
    var last: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '&' => {
                try w.writeAll(text[last..i]);
                try w.writeAll("&amp;");
                last = i + 1;
            },
            '<' => {
                try w.writeAll(text[last..i]);
                try w.writeAll("&lt;");
                last = i + 1;
            },
            '>' => {
                try w.writeAll(text[last..i]);
                try w.writeAll("&gt;");
                last = i + 1;
            },
            //'"' => {
            //    try w.writeAll(text[last..i]);
            //    try w.writeAll("&quot;");
            //    last = i + 1;
            //},
            //'\'' => {
            //    try w.writeAll(text[last..i]);
            //    try w.writeAll("&apos;");
            //    last = i + 1;
            //},
            else => {},
        }
    }
    try w.writeAll(text[last..i]);
}
