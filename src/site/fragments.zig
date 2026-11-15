//! Small HTML fragments shared by the layout renderer and pages.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const posts = @import("../store/posts.zig");
const meta = @import("../content/meta.zig");

pub const EntryFilter = struct {
    kind: meta.Kind = .post,
    tag: ?[]const u8 = null,
    limit: usize = std.math.maxInt(usize),
};

/// `<ul>` of entries matching `filter`, newest first. `entries` must
/// already be sorted. Writes `empty_text` when nothing matches.
pub fn writeEntryList(
    w: *Writer,
    entries: []const posts.Summary,
    filter: EntryFilter,
    class: []const u8,
) !void {
    var written: usize = 0;
    for (entries) |entry| {
        if (written == filter.limit) break;
        if (!matches(entry, filter)) continue;
        if (written == 0) try w.print("<ul class=\"{s}\">\n", .{class});
        try writeEntryItem(w, entry);
        written += 1;
    }
    if (written == 0) {
        try w.writeAll("<p class=\"zv-empty\">nothing here yet.</p>\n");
    } else {
        try w.writeAll("</ul>\n");
    }
}

fn writeEntryItem(w: *Writer, entry: posts.Summary) !void {
    try w.writeAll("<li>");
    if (entry.meta.date.len >= 10) {
        try w.writeAll("<time>");
        try writeEscaped(w, entry.meta.date[0..10]);
        try w.writeAll("</time> ");
    }
    // Slugs are validated, safe in an attribute unescaped.
    try w.print("<a href=\"/{s}\">", .{entry.slug});
    try writeEscaped(w, titleOf(entry));
    try w.writeAll("</a></li>\n");
}

pub fn titleOf(entry: posts.Summary) []const u8 {
    return if (entry.meta.title.len > 0) entry.meta.title else entry.slug;
}

pub fn matches(entry: posts.Summary, filter: EntryFilter) bool {
    if (entry.meta.kind != filter.kind) return false;
    const tag = filter.tag orelse return true;
    return hasTag(entry.meta.tags, tag);
}

pub fn hasTag(tags: []const u8, tag: []const u8) bool {
    var it = std.mem.splitScalar(u8, tags, ',');
    while (it.next()) |t| {
        if (std.mem.eql(u8, std.mem.trim(u8, t, " "), tag)) return true;
    }
    return false;
}

/// Writes `url` as an escaped attribute value, resolving `media:`.
pub fn writeUrl(w: *Writer, url: []const u8) !void {
    if (std.mem.startsWith(u8, url, "media:")) {
        try w.writeAll("/media/");
        return writeEscaped(w, url["media:".len..]);
    }
    try writeEscaped(w, url);
}

/// Rewrites `"media:x.png"` attribute values into `"/media/x.png"`,
/// so content never hard-codes the media endpoint. Only text inside
/// real tags is touched: escaped examples (`&lt;img ...`) in prose
/// and code blocks stay as written.
pub fn resolveMediaRefs(arena: Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, html.len);
    var in_tag = false;
    var i: usize = 0;
    while (i < html.len) : (i += 1) {
        const c = html[i];
        if (c == '<') in_tag = true;
        if (c == '>') in_tag = false;
        try out.append(arena, c);
        if (!in_tag or (c != '"' and c != '\'')) continue;
        if (std.mem.startsWith(u8, html[i + 1 ..], "media:")) {
            try out.appendSlice(arena, "/media/");
            i += "media:".len;
        }
    }
    return out.items;
}

pub fn writeEscaped(w: *Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(c),
    };
}

test "media refs are resolved only inside tags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try resolveMediaRefs(
        arena_state.allocator(),
        "<img src=\"media:a.png\"><img src='media:b.png'>" ++
            "<code>&lt;img src=\"media:c.png\"&gt;</code>",
    );
    try std.testing.expectEqualStrings(
        "<img src=\"/media/a.png\"><img src='/media/b.png'>" ++
            "<code>&lt;img src=\"media:c.png\"&gt;</code>",
        out,
    );
}

test "tag matching" {
    try std.testing.expect(hasTag("zig, web", "web"));
    try std.testing.expect(!hasTag("zig,web", "we"));
}
