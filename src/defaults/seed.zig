//! The default site, compiled into the binary and written to an
//! empty data directory on first start. `site.json` is written last
//! and doubles as the "already seeded" marker, so deleted defaults
//! never come back.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Store = @import("../store/Store.zig");
const library = @import("../store/library.zig");
const posts = @import("../store/posts.zig");
const media = @import("../store/media.zig");
const site_state = @import("../store/site_state.zig");

const File = struct {
    name: []const u8,
    data: []const u8,
};

pub const default_layout = @embedFile("layouts/default.xml");

/// Starter themes: a layout and a style with the same name. The
/// console's Themes page offers them; "default" is active.
pub const theme_names = [_][]const u8{
    "default", "magazine", "landing", "newsletter",
};

const layouts = [_]File{
    .{ .name = "default", .data = default_layout },
    .{ .name = "magazine", .data = @embedFile("layouts/magazine.xml") },
    .{ .name = "landing", .data = @embedFile("layouts/landing.xml") },
    .{ .name = "newsletter", .data = @embedFile("layouts/newsletter.xml") },
};

const styles = [_]File{
    .{ .name = "default", .data = @embedFile("styles/default.css") },
    .{ .name = "magazine", .data = @embedFile("styles/magazine.css") },
    .{ .name = "landing", .data = @embedFile("styles/landing.css") },
    .{ .name = "newsletter", .data = @embedFile("styles/newsletter.css") },
};

const snippets = [_]File{
    .{ .name = "terminal", .data = @embedFile("snippets/terminal.js") },
};

const Entry = struct {
    name: []const u8,
    source: posts.Source,
};

fn html(name: []const u8, comptime path: []const u8) Entry {
    return .{ .name = name, .source = .{
        .text = @embedFile(path),
        .format = .html,
    } };
}

const entries = [_]Entry{
    html("index", "posts/index.html"),
    html("docs", "posts/docs.html"),
    html("api", "posts/api.html"),
    html("hello-world", "posts/hello-world.html"),
    html("under-the-hood", "posts/under-the-hood.html"),
    .{ .name = "writing-in-markdown", .source = .{
        .text = @embedFile("posts/writing-in-markdown.md"),
        .format = .markdown,
    } },
};

const MediaFile = struct {
    place: media.Place,
    data: []const u8,
};

/// The logo and banner are site-wide; covers sit in their post's
/// own folder.
const media_files = [_]MediaFile{
    siteMedia("zerverg-logo.svg"),
    siteMedia("zerverg-banner.svg"),
    postMedia("hello-world", "cover.svg", "cover-hello.svg"),
    postMedia("under-the-hood", "cover.svg", "cover-hood.svg"),
    postMedia("writing-in-markdown", "cover.svg", "cover-markdown.svg"),
};

fn siteMedia(comptime name: []const u8) MediaFile {
    return .{
        .place = .{ .name = name },
        .data = @embedFile("media/" ++ name),
    };
}

fn postMedia(
    slug: []const u8,
    name: []const u8,
    comptime file: []const u8,
) MediaFile {
    return .{
        .place = .{ .folder = .{ .kind = .post, .slug = slug }, .name = name },
        .data = @embedFile("media/" ++ file),
    };
}

pub const default_state: site_state.SiteState = .{
    .title = "zerverg",
    .active_layout = "default",
    .active_style = "default",
    .enabled_snippets = &.{"terminal"},
};

/// Seeds the default site unless `site.json` already exists.
pub fn seedIfFresh(store: *Store, arena: Allocator) !void {
    if (try site_state.exists(store)) return;
    std.log.info("fresh data directory: installing the default site", .{});
    try seedLibrary(store, arena, .layouts, &layouts);
    try seedLibrary(store, arena, .styles, &styles);
    try seedLibrary(store, arena, .snippets, &snippets);
    for (entries) |e| _ = try posts.put(store, .posts, e.name, e.source);
    for (media_files) |file| try media.put(store, arena, file.place, file.data);
    try site_state.write(store, arena, default_state);
}

fn seedLibrary(
    store: *Store,
    arena: Allocator,
    kind: library.Kind,
    files: []const File,
) !void {
    for (files) |file| {
        _ = try library.upload(store, arena, kind, file.name, file.data);
    }
}

test "default content is valid" {
    const schema = @import("../layout/schema.zig");
    const validate = @import("../content/validate.zig");
    const entry = @import("../content/entry.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for (layouts) |file| {
        _ = try schema.parseLayout(arena_state.allocator(), file.data);
    }
    for (entries) |e| {
        try validate.text(e.source.text);
        _ = try entry.metaOf(e.source);
        _ = try entry.bodyHtml(arena_state.allocator(), e.source);
    }
    for (media_files) |file| {
        const media_type = media.mediaTypeOf(file.place.name).?;
        try validate.media(media_type, file.data);
    }
}
