//! Posts and pages, stored as `posts/<slug>.html` or
//! `posts/<slug>.md`. Both are entries; `kind` tells them apart. A
//! slug has one file: saving in one format removes the other.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Store = @import("Store.zig");
const names = @import("names.zig");
const files = @import("files.zig");
const entry = @import("../content/entry.zig");

pub const Meta = entry.Meta;
pub const Format = entry.Format;
pub const Source = entry.Source;

pub const Summary = struct {
    slug: []const u8,
    format: Format = .html,
    meta: Meta,
};

const formats = [_]Format{ .html, .markdown };

const dir_name = "posts";

/// All entries, newest date first.
pub fn list(store: *Store, arena: Allocator) ![]Summary {
    store.lockShared();
    defer store.unlockShared();
    var dir = try store.openSubdir(dir_name);
    defer dir.close(store.io);

    const names_list = try files.listNames(arena, store.io, dir, .file);
    var out: std.ArrayList(Summary) = .empty;
    for (names_list) |name| {
        const slug, const format = splitName(name) orelse continue;
        // Sorted names put "x.html" right before "x.md": first wins.
        const last = out.getLastOrNull();
        if (last != null and std.mem.eql(u8, last.?.slug, slug)) continue;
        const text = files.readAll(
            arena,
            store.io,
            dir,
            name,
            store.limits.text_bytes,
        ) catch continue;
        const source: Source = .{ .text = text, .format = format };
        const meta = entry.metaOf(source) catch continue;
        try out.append(arena, .{
            .slug = slug,
            .format = format,
            .meta = meta,
        });
    }
    std.mem.sort(Summary, out.items, {}, newerFirst);
    return out.items;
}

/// "hello.md" -> .{ "hello", .markdown }; other files -> null.
fn splitName(name: []const u8) ?struct { []const u8, Format } {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    for (formats) |format| {
        if (std.mem.eql(u8, name[dot + 1 ..], format.extension())) {
            return .{ name[0..dot], format };
        }
    }
    return null;
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
    for (all) |summary| {
        if (std.ascii.indexOfIgnoreCase(summary.meta.title, query) != null) {
            try hits.append(arena, summary);
            continue;
        }
        const source = read(store, arena, summary.slug) catch continue;
        const body = entry.bodyHtml(arena, source) catch continue;
        const visible = try visibleText(arena, body);
        if (std.ascii.indexOfIgnoreCase(visible, query) != null) {
            try hits.append(arena, summary);
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

pub fn read(store: *Store, arena: Allocator, slug: []const u8) !Source {
    try names.validateSlug(slug);
    store.lockShared();
    defer store.unlockShared();
    var dir = try store.openSubdir(dir_name);
    defer dir.close(store.io);

    for (formats) |format| {
        var buf: [names.max_len + 8]u8 = undefined;
        const file = try fileName(&buf, slug, format);
        const text = files.readAll(
            arena,
            store.io,
            dir,
            file,
            store.limits.text_bytes,
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        return .{ .text = text, .format = format };
    }
    return error.NotFound;
}

/// Validates and stores an entry. `slug` comes from the URL when
/// given, otherwise from the entry's own `slug` field.
pub fn put(store: *Store, slug: ?[]const u8, source: Source) !Summary {
    if (source.text.len > store.limits.text_bytes) return error.TooLarge;
    const meta = try entry.metaOf(source);
    const final_slug = slug orelse meta.slug orelse return error.MissingSlug;
    try names.validateSlug(final_slug);
    if (meta.layout) |layout| try names.validateSlug(layout);

    store.lockExclusive();
    defer store.unlockExclusive();
    var dir = try store.openSubdir(dir_name);
    defer dir.close(store.io);

    var buf: [names.max_len + 8]u8 = undefined;
    const file = try fileName(&buf, final_slug, source.format);
    try files.writeAtomic(store.io, dir, file, source.text);
    for (formats) |other| {
        if (other == source.format) continue;
        const stale = try fileName(&buf, final_slug, other);
        dir.deleteFile(store.io, stale) catch {};
    }
    return .{ .slug = final_slug, .format = source.format, .meta = meta };
}

pub fn remove(store: *Store, slug: []const u8) !void {
    try names.validateSlug(slug);
    store.lockExclusive();
    defer store.unlockExclusive();
    var dir = try store.openSubdir(dir_name);
    defer dir.close(store.io);

    var removed = false;
    for (formats) |format| {
        var buf: [names.max_len + 8]u8 = undefined;
        const file = try fileName(&buf, slug, format);
        dir.deleteFile(store.io, file) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        removed = true;
    }
    if (!removed) return error.NotFound;
}

fn fileName(buf: []u8, slug: []const u8, format: Format) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.{s}", .{ slug, format.extension() });
}
