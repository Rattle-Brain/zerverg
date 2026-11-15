//! Minimal, allocation-free scanning of HTML tags and attributes.
//! Not a full HTML parser: enough to read our own meta tags and
//! placeholder elements from admin-authored content.

const std = @import("std");

pub const Tag = struct {
    /// The tag without its closing `>`, e.g. `<meta name="x"`.
    text: []const u8,
    /// Offset of `<`.
    start: usize,
    /// Offset just past `>`.
    end: usize,
};

/// Finds the next tag starting with `prefix` (case-insensitive).
pub fn findTag(html: []const u8, prefix: []const u8) ?Tag {
    var from: usize = 0;
    while (from < html.len) {
        const rel = std.ascii.indexOfIgnoreCase(html[from..], prefix) orelse
            return null;
        const start = from + rel;
        const after = start + prefix.len;
        from = after;
        if (after < html.len and !isTagBoundary(html[after])) continue;
        const close = std.mem.indexOfScalarPos(u8, html, after, '>') orelse
            return null;
        return .{
            .text = html[start..close],
            .start = start,
            .end = close + 1,
        };
    }
    return null;
}

pub fn isTagBoundary(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or
        c == '>' or c == '/';
}

/// Value of a quoted attribute inside a tag's text.
pub fn attrValue(tag: []const u8, attr: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(tag, i, attr)) |pos| {
        i = pos + attr.len;
        if (pos == 0 or !isTagBoundary(tag[pos - 1])) continue;
        var j = i;
        while (j < tag.len and tag[j] == ' ') j += 1;
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and tag[j] == ' ') j += 1;
        if (j >= tag.len) return null;
        const quote = tag[j];
        if (quote != '"' and quote != '\'') continue;
        const end = std.mem.indexOfScalarPos(u8, tag, j + 1, quote) orelse
            return null;
        return tag[j + 1 .. end];
    }
    return null;
}
