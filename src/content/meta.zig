//! Extraction of post metadata from uploaded HTML.
//!
//! Metadata lives in `<meta name="zerverg:KEY" content="VALUE">`
//! tags; the title falls back to `<title>`. All returned slices point
//! into the input, nothing is allocated.

const std = @import("std");

pub const Kind = enum { post, page };

pub const Meta = struct {
    slug: ?[]const u8 = null,
    title: []const u8 = "",
    /// ISO 8601 date, `YYYY-MM-DD` at minimum.
    date: []const u8 = "",
    kind: Kind = .post,
    /// Layout override; null means the site's active layout.
    layout: ?[]const u8 = null,
    /// Comma separated.
    tags: []const u8 = "",
};

pub const Error = error{ InvalidKind, InvalidDate };

pub fn extract(html: []const u8) Error!Meta {
    var meta: Meta = .{};
    var rest = html;
    while (findTag(rest, "<meta")) |tag| {
        rest = rest[tag.end..];
        const name = attrValue(tag.text, "name") orelse continue;
        const value = attrValue(tag.text, "content") orelse continue;
        if (!std.mem.startsWith(u8, name, "zerverg:")) continue;
        try apply(&meta, name["zerverg:".len..], value);
    }
    if (meta.title.len == 0) meta.title = titleOf(html) orelse "";
    return meta;
}

fn apply(meta: *Meta, key: []const u8, value: []const u8) Error!void {
    if (eql(key, "slug")) {
        meta.slug = value;
    } else if (eql(key, "title")) {
        meta.title = value;
    } else if (eql(key, "date")) {
        if (!isIsoDate(value)) return error.InvalidDate;
        meta.date = value;
    } else if (eql(key, "kind")) {
        meta.kind = std.meta.stringToEnum(Kind, value) orelse
            return error.InvalidKind;
    } else if (eql(key, "layout")) {
        meta.layout = value;
    } else if (eql(key, "tags")) {
        meta.tags = value;
    }
}

/// Returns the content of `<body>`, or the whole input if absent.
pub fn bodyOf(html: []const u8) []const u8 {
    const open = findTag(html, "<body") orelse return html;
    const inner = html[open.end..];
    const close = std.ascii.indexOfIgnoreCase(inner, "</body") orelse
        return inner;
    return inner[0..close];
}

fn titleOf(html: []const u8) ?[]const u8 {
    const open = findTag(html, "<title") orelse return null;
    const inner = html[open.end..];
    const close = std.ascii.indexOfIgnoreCase(inner, "</title") orelse
        return null;
    return std.mem.trim(u8, inner[0..close], " \t\r\n");
}

const Tag = struct { text: []const u8, end: usize };

/// Finds the next tag starting with `prefix` (case-insensitive).
fn findTag(html: []const u8, prefix: []const u8) ?Tag {
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
        return .{ .text = html[start..close], .end = close + 1 };
    }
    return null;
}

fn isTagBoundary(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or
        c == '>' or c == '/';
}

/// Value of a quoted attribute inside a tag's text.
fn attrValue(tag: []const u8, attr: []const u8) ?[]const u8 {
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

fn isIsoDate(s: []const u8) bool {
    if (s.len < 10) return false;
    for (s[0..10], 0..) |c, i| {
        const want_dash = i == 4 or i == 7;
        if (want_dash != (c == '-')) return false;
        if (!want_dash and !std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "extract metadata" {
    const html =
        \\<html><head><title> Fallback </title>
        \\<meta name="zerverg:date" content="2026-11-15">
        \\<meta name='zerverg:kind' content='page'>
        \\<meta name="zerverg:tags" content="zig,web">
        \\<meta charset="utf-8">
        \\</head><body><p>Hi</p></body></html>
    ;
    const meta = try extract(html);
    try std.testing.expectEqualStrings("Fallback", meta.title);
    try std.testing.expectEqualStrings("2026-11-15", meta.date);
    try std.testing.expectEqual(Kind.page, meta.kind);
    try std.testing.expectEqualStrings("zig,web", meta.tags);
    try std.testing.expectEqualStrings("<p>Hi</p>", bodyOf(html));
}

test "reject bad date" {
    const html = "<meta name=\"zerverg:date\" content=\"15/11/2026\">";
    try std.testing.expectError(error.InvalidDate, extract(html));
}
