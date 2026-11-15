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

const layouts = [_]File{
    .{ .name = "default", .data = default_layout },
};

const styles = [_]File{
    .{ .name = "default", .data = @embedFile("styles/default.css") },
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

const media_files = [_]File{
    .{
        .name = "zerverg-logo.svg",
        .data = @embedFile("media/zerverg-logo.svg"),
    },
    .{
        .name = "zerverg-banner.svg",
        .data = @embedFile("media/zerverg-banner.svg"),
    },
};

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
    for (entries) |e| _ = try posts.put(store, e.name, e.source);
    for (media_files) |file| try media.put(store, arena, file.name, file.data);
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
    _ = try schema.parseLayout(arena_state.allocator(), default_layout);
    for (entries) |e| {
        try validate.text(e.source.text);
        _ = try entry.metaOf(e.source);
        _ = try entry.bodyHtml(arena_state.allocator(), e.source);
    }
    for (media_files) |file| {
        const media_type = media.mediaTypeOf(file.name).?;
        try validate.media(media_type, file.data);
    }
}
