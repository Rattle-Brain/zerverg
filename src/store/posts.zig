//! Posts and pages, stored as `posts/<slug>.html` or
//! `posts/<slug>.md`. Both are entries; `kind` tells them apart. A
//! slug has one file per shelf: saving in one format removes the
//! other.
//!
//! Unpublished work lives the same way under `drafts/`. A draft may
//! stand alone or shadow a published entry with the same slug; the
//! public site never reads drafts.

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

/// Where an entry lives; each is a directory of the same name.
pub const Shelf = enum {
    /// Published: what the site serves.
    posts,
    /// Saved but unpublished.
    drafts,
};

const formats = [_]Format{ .html, .markdown };
const shelves = std.enums.values(Shelf);

/// A text replacement, applied to entries when what they refer to
/// moves.
pub const Edit = struct {
    old: []const u8,
    new: []const u8,
};

/// All entries on `shelf`, newest date first.
pub fn list(store: *Store, arena: Allocator, shelf: Shelf) ![]Summary {
    store.lockShared();
    defer store.unlockShared();
    var dir = try store.openSubdir(@tagName(shelf));
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

/// Published entries whose title or visible text contains `query`
/// (ASCII case-insensitive), newest first.
pub fn search(
    store: *Store,
    arena: Allocator,
    query: []const u8,
) ![]Summary {
    const all = try list(store, arena, .posts);
    var hits: std.ArrayList(Summary) = .empty;
    for (all) |summary| {
        if (std.ascii.indexOfIgnoreCase(summary.meta.title, query) != null) {
            try hits.append(arena, summary);
            continue;
        }
        const source = read(store, arena, .posts, summary.slug) catch
            continue;
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

pub fn read(
    store: *Store,
    arena: Allocator,
    shelf: Shelf,
    slug: []const u8,
) !Source {
    try names.validateSlug(slug);
    store.lockShared();
    defer store.unlockShared();
    var dir = try store.openSubdir(@tagName(shelf));
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
pub fn put(
    store: *Store,
    shelf: Shelf,
    slug: ?[]const u8,
    source: Source,
) !Summary {
    if (source.text.len > store.limits.text_bytes) return error.TooLarge;
    const meta = try entry.metaOf(source);
    const final_slug = slug orelse meta.slug orelse return error.MissingSlug;
    try names.validateSlug(final_slug);
    if (meta.layout) |layout| try names.validateSlug(layout);

    store.lockExclusive();
    defer store.unlockExclusive();
    var dir = try store.openSubdir(@tagName(shelf));
    defer dir.close(store.io);

    var buf: [names.max_len + 8]u8 = undefined;
    const file = try fileName(&buf, final_slug, source.format);
    try files.writeAtomic(store.io, dir, file, source.text);
    try removeOtherFormats(store, dir, final_slug, source.format);
    return .{ .slug = final_slug, .format = source.format, .meta = meta };
}

/// Moves the draft `slug` onto the published shelf, replacing the
/// live entry. A rename, so readers see the old entry or the new
/// one, never neither.
pub fn publish(store: *Store, slug: []const u8) !Format {
    try names.validateSlug(slug);
    store.lockExclusive();
    defer store.unlockExclusive();
    var drafts = try store.openSubdir(@tagName(Shelf.drafts));
    defer drafts.close(store.io);
    var published = try store.openSubdir(@tagName(Shelf.posts));
    defer published.close(store.io);

    for (formats) |format| {
        var buf: [names.max_len + 8]u8 = undefined;
        const file = try fileName(&buf, slug, format);
        drafts.rename(file, published, file, store.io) catch |err|
            switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
        try removeOtherFormats(store, published, slug, format);
        return format;
    }
    return error.NotFound;
}

pub fn remove(store: *Store, shelf: Shelf, slug: []const u8) !void {
    try names.validateSlug(slug);
    store.lockExclusive();
    defer store.unlockExclusive();
    var dir = try store.openSubdir(@tagName(shelf));
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

/// Whether `slug` has a file on either shelf. The caller holds the
/// store's lock.
pub fn existsLocked(store: *Store, slug: []const u8) !bool {
    try names.validateSlug(slug);
    for (shelves) |shelf| {
        var dir = try store.openSubdir(@tagName(shelf));
        defer dir.close(store.io);
        for (formats) |format| {
            var buf: [names.max_len + 8]u8 = undefined;
            const file = try fileName(&buf, slug, format);
            if (dir.access(store.io, file, .{})) |_| return true else |_| {}
        }
    }
    return false;
}

/// Moves entry `from` to `to` on both shelves and applies `edits` to
/// every entry, so references follow what moved. The caller holds
/// the exclusive lock and has checked that `to` is free.
pub fn renameLocked(
    store: *Store,
    arena: Allocator,
    from: []const u8,
    to: []const u8,
    edits: []const Edit,
) !void {
    for (shelves) |shelf| {
        var dir = try store.openSubdir(@tagName(shelf));
        defer dir.close(store.io);
        const all = try files.listNames(arena, store.io, dir, .file);
        for (all) |name| {
            const slug, const format = splitName(name) orelse continue;
            const limit = store.limits.text_bytes;
            const text = try files.readAll(arena, store.io, dir, name, limit);
            const edited = try applyEdits(arena, text, edits);
            if (std.mem.eql(u8, slug, from)) {
                var buf: [names.max_len + 8]u8 = undefined;
                const moved = try fileName(&buf, to, format);
                try files.writeAtomic(store.io, dir, moved, edited);
                try dir.deleteFile(store.io, name);
            } else if (edited.ptr != text.ptr) {
                try files.writeAtomic(store.io, dir, name, edited);
            }
        }
    }
}

/// `text` with every edit applied; `text` itself when none matches.
fn applyEdits(
    arena: Allocator,
    text: []const u8,
    edits: []const Edit,
) ![]const u8 {
    var out = text;
    for (edits) |edit| {
        if (std.mem.indexOf(u8, out, edit.old) == null) continue;
        out = try std.mem.replaceOwned(u8, arena, out, edit.old, edit.new);
    }
    return out;
}

/// A slug has one file per shelf: drops the one not in `keep`.
fn removeOtherFormats(
    store: *Store,
    dir: std.Io.Dir,
    slug: []const u8,
    keep: Format,
) !void {
    for (formats) |other| {
        if (other == keep) continue;
        var buf: [names.max_len + 8]u8 = undefined;
        const stale = try fileName(&buf, slug, other);
        dir.deleteFile(store.io, stale) catch {};
    }
}

fn fileName(buf: []u8, slug: []const u8, format: Format) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.{s}", .{ slug, format.extension() });
}

test "drafts stay off the site until published" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try Store.openTesting(&tmp);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const live: Source = .{ .text = "<title>live</title>", .format = .html };
    const draft: Source = .{ .text = "# edited\n", .format = .markdown };
    _ = try put(&store, .posts, "hello", live);
    _ = try put(&store, .drafts, "hello", draft);
    try std.testing.expectEqualStrings(
        live.text,
        (try read(&store, arena, .posts, "hello")).text,
    );
    try std.testing.expectEqual(1, (try search(&store, arena, "live")).len);

    try std.testing.expectEqual(Format.markdown, try publish(&store, "hello"));
    const now = try read(&store, arena, .posts, "hello");
    try std.testing.expectEqualStrings(draft.text, now.text);
    try std.testing.expectEqual(1, (try list(&store, arena, .posts)).len);
    try std.testing.expectEqual(0, (try list(&store, arena, .drafts)).len);
    try std.testing.expectError(error.NotFound, publish(&store, "hello"));
}
