const std = @import("std");

test {
    try std.testing.expect(true);
}

// ToDo:

//logMessage(@typeName(tmd.Token), " size: ", @sizeOf(tmd.Token));
//logMessage(@typeName(tmd.Token.PlainText), " size: ", @sizeOf(tmd.Token.PlainText));
//logMessage(@typeName(tmd.Token.CommentText), " size: ", @sizeOf(tmd.Token.CommentText));
//logMessage(@typeName(tmd.Token.EvenBackticks), " size: ", @sizeOf(tmd.Token.EvenBackticks));
//logMessage(@typeName(tmd.Token.SpanMark), " size: ", @sizeOf(tmd.Token.SpanMark));
//logMessage(@typeName(tmd.Token.LinkInfo), " size: ", @sizeOf(tmd.Token.LinkInfo));
//logMessage(@typeName(tmd.Token.LeadingSpanMark), " size: ", @sizeOf(tmd.Token.LeadingSpanMark));
//logMessage(@typeName(tmd.Token.ContainerMark), " size: ", @sizeOf(tmd.Token.ContainerMark));
//logMessage(@typeName(tmd.Token.LineTypeMark), " size: ", @sizeOf(tmd.Token.LineTypeMark));
//logMessage(@typeName(tmd.Token.Extra), " size: ", @sizeOf(tmd.Token.Extra));
