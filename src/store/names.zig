//! Validation of user-supplied names. Every name that reaches the
//! filesystem passes through here, which rules out path traversal.

const std = @import("std");

pub const max_len = 64;

pub const Error = error{InvalidName};

/// Slugs: `[a-z0-9][a-z0-9_-]{0,63}`.
pub fn validateSlug(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_len) return error.InvalidName;
    if (!isAlnum(name[0])) return error.InvalidName;
    for (name) |c| {
        if (!isAlnum(c) and c != '-' and c != '_') return error.InvalidName;
    }
}

/// File names: a slug, one dot, and a 1-8 char alphanumeric extension.
pub fn validateFileName(name: []const u8) Error!void {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse
        return error.InvalidName;
    try validateSlug(name[0..dot]);
    const ext = name[dot + 1 ..];
    if (ext.len == 0 or ext.len > 8) return error.InvalidName;
    for (ext) |c| if (!isAlnum(c)) return error.InvalidName;
}

pub fn extensionOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse
        return "";
    return name[dot + 1 ..];
}

fn isAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}

test "slugs" {
    try validateSlug("hello-world_2");
    try std.testing.expectError(error.InvalidName, validateSlug(""));
    try std.testing.expectError(error.InvalidName, validateSlug("-x"));
    try std.testing.expectError(error.InvalidName, validateSlug("../x"));
    try std.testing.expectError(error.InvalidName, validateSlug("Abc"));
}

test "file names" {
    try validateFileName("cat.png");
    try std.testing.expectError(error.InvalidName, validateFileName("cat"));
    try std.testing.expectError(error.InvalidName, validateFileName(".png"));
    try std.testing.expectError(
        error.InvalidName,
        validateFileName("a/b.png"),
    );
}
