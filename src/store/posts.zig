//! Posts and pages, stored as `posts/<slug>.html`. Both are entries;
//! `zerverg:kind` tells them apart.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Store = @import("Store.zig");
const names = @import("names.zig");
const files = @import("files.zig");
const meta_mod = @import("../content/meta.zig");

pub const Meta = meta_mod.Meta;

pub const Summary = struct {
    slug: []const u8,
    meta: Meta,
};

const dir_name = "posts";

/// All entries, newest date first.
pub fn list(store: *Store, arena: Allocator) ![]Summary {
    store.lockShared();
    defer store.unlockShared();
    var dir = try store.openSubdir(dir_name);
    defer dir.close(store.io);

    const entries = try files.listNames(arena, store.io, dir, .file);
    var out: std.ArrayList(Summary) = .empty;
    for (entries) |entry| {
        if (!std.mem.endsWith(u8, entry, ".html")) continue;
        const html = files.readAll(
            arena,
            store.io,
            dir,
            entry,
            store.limits.text_bytes,
        ) catch continue;
        const meta = meta_mod.extract(html) catch continue;
        const slug = entry[0 .. entry.len - ".html".len];
        try out.append(arena, .{ .slug = slug, .meta = meta });
    }
    std.mem.sort(Summary, out.items, {}, newerFirst);
    return out.items;
}

/// Newest date first; ties (e.g. undated pages) by slug.
fn newerFirst(_: void, a: Summary, b: Summary) bool {
    return switch (std.mem.order(u8, a.meta.date, b.meta.date)) {
        .gt => true,
        .lt => false,
        .eq => std.mem.order(u8, a.slug, b.slug) == .lt,
    };
}

/// Entries whose title or visible text contains `query`
/// (ASCII case-insensitive), newest first.
pub fn search(
    store: *Store,
    arena: Allocator,
    query: []const u8,
) ![]Summary {
    const all = try list(store, arena);
    var hits: std.ArrayList(Summary) = .empty;
    for (all) |entry| {
        if (std.ascii.indexOfIgnoreCase(entry.meta.title, query) != null) {
            try hits.append(arena, entry);
            continue;
        }
        const html = read(store, arena, entry.slug) catch continue;
        const visible = try visibleText(arena, meta_mod.bodyOf(html));
        if (std.ascii.indexOfIgnoreCase(visible, query) != null) {
            try hits.append(arena, entry);
        }
    }
    return hits.items;
}

/// Strips tags so searches match words, not markup.
fn visibleText(arena: Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_tag = false;
    for (html) |c| {
        if (c == '<') {
            in_tag = true;
        } else if (c == '>') {
            in_tag = false;
            try out.append(arena, ' ');
        } else if (!in_tag) {
            try out.append(arena, c);
        }
    }
    return out.items;
}

pub fn read(store: *Store, arena: Allocator, slug: []const u8) ![]u8 {
    try names.validateSlug(slug);
    store.lockShared();
    defer store.unlockShared();
    var dir = try store.openSubdir(dir_name);
    defer dir.close(store.io);

    var buf: [names.max_len + 8]u8 = undefined;
    const file = try fileName(&buf, slug);
    return files.readAll(
        arena,
        store.io,
        dir,
        file,
        store.limits.text_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => error.NotFound,
        else => err,
    };
}

/// Validates and stores an entry. `slug` comes from the URL when
/// given, otherwise from the `zerverg:slug` meta tag.
pub fn put(store: *Store, slug: ?[]const u8, html: []const u8) !Summary {
    if (html.len > store.limits.text_bytes) return error.TooLarge;
    const meta = try meta_mod.extract(html);
    const final_slug = slug orelse meta.slug orelse return error.MissingSlug;
    try names.validateSlug(final_slug);
    if (meta.layout) |layout| try names.validateSlug(layout);

    store.lockExclusive();
    defer store.unlockExclusive();
    var dir = try store.openSubdir(dir_name);
    defer dir.close(store.io);

    var buf: [names.max_len + 8]u8 = undefined;
    const file = try fileName(&buf, final_slug);
    try files.writeAtomic(store.io, dir, file, html);
    return .{ .slug = final_slug, .meta = meta };
}

pub fn remove(store: *Store, slug: []const u8) !void {
    try names.validateSlug(slug);
    store.lockExclusive();
    defer store.unlockExclusive();
    var dir = try store.openSubdir(dir_name);
    defer dir.close(store.io);

    var buf: [names.max_len + 8]u8 = undefined;
    const file = try fileName(&buf, slug);
    dir.deleteFile(store.io, file) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return err,
    };
}

fn fileName(buf: []u8, slug: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.html", .{slug});
}
