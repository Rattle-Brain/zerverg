//! Public HTML rendering.
//!
//! For now this wraps content in a fixed page shell. The XML layout
//! engine (next milestone) replaces `shell` with layout-driven output;
//! everything else here stays.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const SiteState = @import("../store/site_state.zig").SiteState;
const posts = @import("../store/posts.zig");

pub const Page = struct {
    site: SiteState,
    title: []const u8,
    /// Trusted, admin-authored HTML.
    main_html: []const u8,
};

pub fn shell(arena: Allocator, page: Page) ![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("<!doctype html>\n<html><head><meta charset=\"utf-8\">\n");
    try w.writeAll("<meta name=\"viewport\" ");
    try w.writeAll("content=\"width=device-width, initial-scale=1\">\n");
    try w.writeAll("<title>");
    try writeEscaped(w, page.title);
    if (page.title.len > 0) try w.writeAll(" - ");
    try writeEscaped(w, page.site.title);
    try w.writeAll("</title>\n");
    if (page.site.active_style != null) {
        try w.writeAll(
            "<link rel=\"stylesheet\" href=\"/assets/style.css\">\n",
        );
    }
    try w.writeAll("</head><body>\n<header><a href=\"/\">");
    try writeEscaped(w, page.site.title);
    try w.writeAll("</a></header>\n<main>\n");
    try w.writeAll(try resolveMediaRefs(arena, page.main_html));
    try w.writeAll("\n</main>\n");
    try writeSnippetTags(w, page.site.enabled_snippets);
    try w.writeAll("</body></html>\n");
    return out.written();
}

/// The list of posts (not pages), newest first.
pub fn entryList(arena: Allocator, entries: []const posts.Summary) ![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("<ul class=\"zv-entries\">\n");
    for (entries) |entry| {
        if (entry.meta.kind != .post) continue;
        try w.print("<li><a href=\"/{s}\">", .{entry.slug});
        const title = if (entry.meta.title.len > 0)
            entry.meta.title
        else
            entry.slug;
        try writeEscaped(w, title);
        try w.writeAll("</a> <time>");
        try writeEscaped(w, entry.meta.date);
        try w.writeAll("</time></li>\n");
    }
    try w.writeAll("</ul>\n");
    return out.written();
}

fn writeSnippetTags(w: *Writer, snippets: []const []const u8) !void {
    for (snippets) |name| {
        // Names are validated slugs, safe to embed unescaped.
        try w.print(
            "<script src=\"/assets/snippets/{s}.js\" defer></script>\n",
            .{name},
        );
    }
}

/// Rewrites `"media:x.png"` references into `"/media/x.png"`, so
/// posts never hard-code the media endpoint.
pub fn resolveMediaRefs(arena: Allocator, html: []const u8) ![]u8 {
    const double = try std.mem.replaceOwned(
        u8,
        arena,
        html,
        "\"media:",
        "\"/media/",
    );
    return std.mem.replaceOwned(u8, arena, double, "'media:", "'/media/");
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

test "media refs are resolved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try resolveMediaRefs(
        arena_state.allocator(),
        "<img src=\"media:a.png\"><img src='media:b.png'>",
    );
    try std.testing.expectEqualStrings(
        "<img src=\"/media/a.png\"><img src='/media/b.png'>",
        out,
    );
}
