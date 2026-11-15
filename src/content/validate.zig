//! Upload content checks, applied before anything is stored.
//!
//! Text must be valid UTF-8 without NUL bytes. Media must start
//! with the signature of its extension's format, so a file cannot
//! masquerade as another type. SVGs must not carry scripts.

const std = @import("std");

const media_store = @import("../store/media.zig");

pub const Error = error{ InvalidContent, ContentMismatch };

pub fn text(data: []const u8) Error!void {
    if (std.mem.indexOfScalar(u8, data, 0) != null) {
        return error.InvalidContent;
    }
    if (!std.unicode.utf8ValidateSlice(data)) return error.InvalidContent;
}

pub fn media(
    media_type: media_store.MediaType,
    data: []const u8,
) Error!void {
    const ext = media_type.extension;
    const ok = if (eql(ext, "png"))
        startsWith(data, "\x89PNG\r\n\x1a\n")
    else if (eql(ext, "jpg") or eql(ext, "jpeg"))
        startsWith(data, "\xff\xd8\xff")
    else if (eql(ext, "gif"))
        startsWith(data, "GIF87a") or startsWith(data, "GIF89a")
    else if (eql(ext, "webp"))
        startsWith(data, "RIFF") and at(data, 8, "WEBP")
    else if (eql(ext, "avif"))
        at(data, 4, "ftypavif") or at(data, 4, "ftypavis")
    else if (eql(ext, "mp4"))
        at(data, 4, "ftyp")
    else if (eql(ext, "webm"))
        startsWith(data, "\x1a\x45\xdf\xa3")
    else if (eql(ext, "ogv"))
        startsWith(data, "OggS")
    else if (eql(ext, "ico"))
        startsWith(data, "\x00\x00\x01\x00")
    else if (eql(ext, "svg"))
        return svg(data)
    else
        false;
    if (!ok) return error.ContentMismatch;
}

/// SVG is XML that browsers will execute scripts from when opened
/// directly. We also serve it sandboxed, but reject scripts upfront.
fn svg(data: []const u8) Error!void {
    try text(data);
    if (std.ascii.indexOfIgnoreCase(data, "<svg") == null) {
        return error.ContentMismatch;
    }
    const forbidden = [_][]const u8{
        "<script", "javascript:", "<foreignobject", " on", "\ton", "\non",
    };
    for (forbidden) |needle| {
        if (containsHandler(data, needle)) return error.InvalidContent;
    }
}

/// For `on` prefixes, only flags real attributes like `onload=`.
fn containsHandler(data: []const u8, needle: []const u8) bool {
    var from: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(data, from, needle)) |pos| {
        from = pos + needle.len;
        if (!std.mem.endsWith(u8, needle, "on")) return true;
        var i = from;
        while (i < data.len and std.ascii.isAlphabetic(data[i])) i += 1;
        if (i > from and i < data.len and data[i] == '=') return true;
    }
    return false;
}

fn startsWith(data: []const u8, magic: []const u8) bool {
    return std.mem.startsWith(u8, data, magic);
}

fn at(data: []const u8, offset: usize, magic: []const u8) bool {
    if (data.len < offset + magic.len) return false;
    return std.mem.eql(u8, data[offset..][0..magic.len], magic);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const testing = std.testing;

test "text" {
    try text("héllo");
    try testing.expectError(error.InvalidContent, text("a\x00b"));
    try testing.expectError(error.InvalidContent, text("\xff\xfe"));
}

test "media signatures" {
    const png = media_store.mediaTypeOf("a.png").?;
    try media(png, "\x89PNG\r\n\x1a\nrest");
    try testing.expectError(error.ContentMismatch, media(png, "GIF89a"));
}

test "svg scripts are rejected" {
    const t = media_store.mediaTypeOf("a.svg").?;
    try media(t, "<svg viewBox='0 0 1 1'><rect/></svg>");
    try testing.expectError(
        error.InvalidContent,
        media(t, "<svg><script>alert(1)</script></svg>"),
    );
    try testing.expectError(
        error.InvalidContent,
        media(t, "<svg onload='x()'></svg>"),
    );
    try media(t, "<svg><title>on the road</title></svg>");
}
