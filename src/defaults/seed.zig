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

const entries = [_]File{
    .{ .name = "index", .data = @embedFile("posts/index.html") },
    .{ .name = "docs", .data = @embedFile("posts/docs.html") },
    .{ .name = "api", .data = @embedFile("posts/api.html") },
    .{ .name = "hello-world", .data = @embedFile("posts/hello-world.html") },
    .{
        .name = "under-the-hood",
        .data = @embedFile("posts/under-the-hood.html"),
    },
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
    for (entries) |file| _ = try posts.put(store, file.name, file.data);
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
    const meta = @import("../content/meta.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    _ = try schema.parseLayout(arena_state.allocator(), default_layout);
    for (entries) |file| {
        try validate.text(file.data);
        _ = try meta.extract(file.data);
    }
    for (media_files) |file| {
        const media_type = media.mediaTypeOf(file.name).?;
        try validate.media(media_type, file.data);
    }
}
