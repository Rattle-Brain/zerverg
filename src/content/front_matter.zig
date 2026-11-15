//! The `---` header of Markdown entries:
//!
//!     ---
//!     title: Hello
//!     date: 2026-11-15
//!     tags: [zig, web]
//!     ---
//!
//! Plain `key: value` lines (not full YAML). Keys are the same as the
//! `zerverg:*` meta tags of HTML entries.

const std = @import("std");

const meta_mod = @import("meta.zig");
const Meta = meta_mod.Meta;

pub const Split = struct {
    header: []const u8,
    body: []const u8,
};

/// Separates the header from the body; no header, empty `header`.
pub fn split(source: []const u8) Split {
    const none: Split = .{ .header = "", .body = source };
    const first_end = std.mem.indexOfScalar(u8, source, '\n') orelse
        return none;
    if (!isDelimiter(source[0..first_end])) return none;
    var pos = first_end + 1;
    while (pos <= source.len) {
        const end = std.mem.indexOfScalarPos(u8, source, pos, '\n') orelse
            source.len;
        if (isDelimiter(source[pos..end])) {
            return .{
                .header = source[first_end + 1 .. pos],
                .body = source[@min(end + 1, source.len)..],
            };
        }
        pos = end + 1;
    }
    return none;
}

fn isDelimiter(line: []const u8) bool {
    return std.mem.eql(u8, std.mem.trimEnd(u8, line, " \r"), "---");
}

pub fn extract(source: []const u8) meta_mod.Error!Meta {
    var meta: Meta = .{};
    var lines = std.mem.splitScalar(u8, split(source).header, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t\r");
        const value = unquote(std.mem.trim(u8, line[colon + 1 ..], " \t\r"));
        if (value.len == 0) continue;
        try meta_mod.apply(&meta, key, value);
    }
    return meta;
}

/// `"x"`, `'x'` and `[a, b]` lose their brackets.
fn unquote(value: []const u8) []const u8 {
    if (value.len < 2) return value;
    const first = value[0];
    const last = value[value.len - 1];
    const paired = (first == '"' and last == '"') or
        (first == '\'' and last == '\'') or (first == '[' and last == ']');
    return if (paired) value[1 .. value.len - 1] else value;
}

test "front matter fields map to metadata" {
    const source =
        \\---
        \\title: "Hello: world"
        \\date: 2026-11-15
        \\kind: page
        \\tags: [zig, web]
        \\---
        \\# Body
    ;
    const meta = try extract(source);
    try std.testing.expectEqualStrings("Hello: world", meta.title);
    try std.testing.expectEqualStrings("2026-11-15", meta.date);
    try std.testing.expectEqual(meta_mod.Kind.page, meta.kind);
    try std.testing.expectEqualStrings("zig, web", meta.tags);
    try std.testing.expectEqualStrings("# Body", split(source).body);
}

test "no header, whole body" {
    const parts = split("# Just text\n---\n");
    try std.testing.expectEqualStrings("", parts.header);
    try std.testing.expectEqual(@as(usize, 16), parts.body.len);
}
