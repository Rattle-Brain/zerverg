//! Entries come as HTML or Markdown. This module reduces either to
//! what the renderer needs: metadata and body HTML.

const std = @import("std");
const Allocator = std.mem.Allocator;

const meta_mod = @import("meta.zig");
const front_matter = @import("front_matter.zig");
const markdown = @import("markdown.zig");

pub const Meta = meta_mod.Meta;

pub const Format = enum {
    html,
    markdown,

    pub fn extension(format: Format) []const u8 {
        return switch (format) {
            .html => "html",
            .markdown => "md",
        };
    }

    pub fn contentType(format: Format) []const u8 {
        return switch (format) {
            .html => "text/html; charset=utf-8",
            .markdown => "text/markdown; charset=utf-8",
        };
    }

    /// "html", "md" or "markdown".
    pub fn parse(name: []const u8) ?Format {
        if (std.mem.eql(u8, name, "html")) return .html;
        if (std.mem.eql(u8, name, "md")) return .markdown;
        if (std.mem.eql(u8, name, "markdown")) return .markdown;
        return null;
    }
};

/// An entry as stored: its text and how to read it.
pub const Source = struct {
    text: []const u8,
    format: Format,
};

pub fn metaOf(source: Source) meta_mod.Error!Meta {
    return switch (source.format) {
        .html => meta_mod.extract(source.text),
        .markdown => front_matter.extract(source.text),
    };
}

/// The entry's content as HTML, without `<head>` or front matter.
pub fn bodyHtml(arena: Allocator, source: Source) ![]const u8 {
    return switch (source.format) {
        .html => meta_mod.bodyOf(source.text),
        .markdown => markdown.toHtml(
            arena,
            front_matter.split(source.text).body,
        ),
    };
}

/// An upload's format: the `format` query parameter, else the
/// Content-Type, else Markdown when it opens with front matter.
pub fn detect(
    format_param: ?[]const u8,
    content_type: ?[]const u8,
    text: []const u8,
) error{InvalidFormat}!Format {
    if (format_param) |name| return Format.parse(name) orelse
        error.InvalidFormat;
    if (content_type) |ct| {
        if (std.ascii.startsWithIgnoreCase(ct, "text/markdown")) {
            return .markdown;
        }
    }
    if (front_matter.split(text).header.len > 0) return .markdown;
    return .html;
}

test "detect format" {
    try std.testing.expectEqual(Format.markdown, try detect("md", null, ""));
    try std.testing.expectEqual(
        Format.markdown,
        try detect(null, "text/markdown", "x"),
    );
    try std.testing.expectEqual(
        Format.markdown,
        try detect(null, null, "---\ntitle: a\n---\n"),
    );
    try std.testing.expectEqual(Format.html, try detect(null, null, "<p>"));
    try std.testing.expectError(error.InvalidFormat, detect("doc", null, ""));
}
