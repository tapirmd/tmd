const std = @import("std");

// return tag name or rev<HASH>.
// ending with ! means not last commit is found.
pub fn getLastGitCommitString(projectPath: []const u8, allocator: std.mem.Allocator) []const u8 {
    _ = projectPath;
    _ = allocator;
    return "!";
}
