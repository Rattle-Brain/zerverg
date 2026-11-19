//! Media files (images, videos), with per-type size limits and a
//! total quota so uploads cannot fill the disk.
//!
//!   media/<file>                  site-wide: logos, banners
//!   media/posts/<slug>/<file>     one post's own
//!   media/pages/<slug>/<file>     one page's own
//!
//! An entry's folder is created by its first upload and removed with
//! its last file, or all at once. Content refers to files by their path under
//! `media/`: `media:logo.svg`, `media:posts/hello/cat.png`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Store = @import("Store.zig");
const names = @import("names.zig");
const files = @import("files.zig");
const Kind = @import("../content/meta.zig").Kind;

pub const Category = enum { image, video };

pub const MediaType = struct {
    extension: []const u8,
    category: Category,
    content_type: []const u8,
};

const media_types = [_]MediaType{
    image("png", "image/png"),
    image("jpg", "image/jpeg"),
    image("jpeg", "image/jpeg"),
    image("gif", "image/gif"),
    image("webp", "image/webp"),
    image("avif", "image/avif"),
    image("svg", "image/svg+xml"),
    image("ico", "image/x-icon"),
    video("mp4", "video/mp4"),
    video("webm", "video/webm"),
    video("ogv", "video/ogg"),
};

fn image(ext: []const u8, content_type: []const u8) MediaType {
    return .{
        .extension = ext,
        .category = .image,
        .content_type = content_type,
    };
}

fn video(ext: []const u8, content_type: []const u8) MediaType {
    return .{
        .extension = ext,
        .category = .video,
        .content_type = content_type,
    };
}

/// The folder of one entry's own media.
pub const Folder = struct {
    kind: Kind,
    slug: []const u8,
};

/// Where a media file lives: site-wide, or in an entry's folder.
pub const Place = struct {
    folder: ?Folder = null,
    name: []const u8,
};

pub const Item = struct {
    /// Relative to `media/`; what references and URLs use.
    path: []const u8,
    name: []const u8,
    size: u64,
    content_type: []const u8,
};

const dir_name = "media";

pub fn mediaTypeOf(name: []const u8) ?MediaType {
    const ext = names.extensionOf(name);
    for (media_types) |t| {
        if (std.mem.eql(u8, t.extension, ext)) return t;
    }
    return null;
}

/// The place a URL names: `<name>` alone is site-wide, a `folder`
/// segment ("posts" or "pages") and `slug` name an entry's folder.
pub fn placeOf(
    folder: ?[]const u8,
    slug: ?[]const u8,
    name: []const u8,
) names.Error!Place {
    const dir = folder orelse return .{ .name = name };
    const s = slug orelse return error.InvalidName;
    return .{ .folder = try folderOf(dir, s), .name = name };
}

/// The folder a URL names: "posts" or "pages", then a slug.
pub fn folderOf(dir: []const u8, slug: []const u8) names.Error!Folder {
    const kind = kindOfDir(dir) orelse return error.InvalidName;
    return .{ .kind = kind, .slug = slug };
}

/// `place` relative to `media/`: "cat.png", "posts/hello/cat.png".
pub fn pathOf(arena: Allocator, place: Place) ![]const u8 {
    const f = place.folder orelse return place.name;
    return std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{
        dirOfKind(f.kind), f.slug, place.name,
    });
}

/// Every media file: site-wide first, then folder by folder.
pub fn list(store: *Store, arena: Allocator) ![]Item {
    store.lockShared();
    defer store.unlockShared();
    var dir = try store.openSubdir(dir_name);
    defer dir.close(store.io);
    return collect(store.io, arena, dir);
}

pub const Opened = struct {
    file: std.Io.File,
    size: u64,
    content_type: []const u8,
};

/// Opens a media file for streaming. The caller closes `file`.
/// POSIX keeps the handle valid even if the file is replaced or
/// deleted meanwhile, so the lock is only held while opening.
pub fn open(store: *Store, place: Place) !Opened {
    try validatePlace(place);
    const media_type = mediaTypeOf(place.name) orelse return error.NotFound;
    store.lockShared();
    defer store.unlockShared();
    var dir = try openFolder(store, place.folder, false);
    defer dir.close(store.io);
    const file = dir.openFile(store.io, place.name, .{}) catch |err|
        switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return err,
        };
    errdefer file.close(store.io);
    const stat = try file.stat(store.io);
    return .{
        .file = file,
        .size = stat.size,
        .content_type = media_type.content_type,
    };
}

pub fn put(
    store: *Store,
    arena: Allocator,
    place: Place,
    data: []const u8,
) !void {
    try validatePlace(place);
    const media_type = mediaTypeOf(place.name) orelse
        return error.UnsupportedMediaType;
    if (data.len > limitFor(store.limits, media_type.category)) {
        return error.TooLarge;
    }
    store.lockExclusive();
    defer store.unlockExclusive();
    var media_dir = try store.openSubdir(dir_name);
    defer media_dir.close(store.io);

    const all = try collect(store.io, arena, media_dir);
    const used = usedBytes(all, try pathOf(arena, place));
    if (used + data.len > store.limits.media_total_bytes) {
        return error.QuotaExceeded;
    }
    var dir = try openFolder(store, place.folder, true);
    defer dir.close(store.io);
    try files.writeAtomic(store.io, dir, place.name, data);
}

pub fn remove(store: *Store, place: Place) !void {
    try validatePlace(place);
    store.lockExclusive();
    defer store.unlockExclusive();
    var dir = try openFolder(store, place.folder, false);
    defer dir.close(store.io);
    dir.deleteFile(store.io, place.name) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return err,
    };
    const folder = place.folder orelse return;
    var buf: [128]u8 = undefined;
    const path = try folderPath(&buf, folder);
    // Fails while other files remain, which is the point.
    store.root.deleteDir(store.io, path) catch {};
}

/// Deletes an entry's folder with every file in it.
pub fn removeFolder(store: *Store, folder: Folder) !void {
    try names.validateSlug(folder.slug);
    store.lockExclusive();
    defer store.unlockExclusive();
    var buf: [128]u8 = undefined;
    const path = try folderPath(&buf, folder);
    store.root.access(store.io, path, .{}) catch return error.NotFound;
    try store.root.deleteTree(store.io, path);
}

/// Whether `slug` has a media folder, as a post or a page. The
/// caller holds the store's lock.
pub fn hasFolderLocked(store: *Store, slug: []const u8) !bool {
    try names.validateSlug(slug);
    for (kinds) |kind| {
        var buf: [128]u8 = undefined;
        const path = try folderPath(&buf, .{ .kind = kind, .slug = slug });
        if (store.root.access(store.io, path, .{})) |_| return true else |_| {}
    }
    return false;
}

/// Moves `from`'s folders, as a post and as a page, to `to`. The
/// caller holds the exclusive lock and has checked that `to` has
/// none.
pub fn renameFoldersLocked(
    store: *Store,
    from: []const u8,
    to: []const u8,
) !void {
    for (kinds) |kind| {
        var from_buf: [128]u8 = undefined;
        var to_buf: [128]u8 = undefined;
        const old = try folderPath(&from_buf, .{ .kind = kind, .slug = from });
        const new = try folderPath(&to_buf, .{ .kind = kind, .slug = to });
        store.root.rename(old, store.root, new, store.io) catch |err|
            switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
    }
}

/// How content refers to `folder`'s files: "media:posts/hello/".
pub fn refPrefix(arena: Allocator, folder: Folder) ![]const u8 {
    return std.fmt.allocPrint(arena, "media:{s}/{s}/", .{
        dirOfKind(folder.kind), folder.slug,
    });
}

fn validatePlace(place: Place) names.Error!void {
    try names.validateFileName(place.name);
    if (place.folder) |f| try names.validateSlug(f.slug);
}

fn limitFor(limits: Store.Limits, category: Category) usize {
    return switch (category) {
        .image => limits.image_bytes,
        .video => limits.video_bytes,
    };
}

/// Total size of all media except `replacing`, which is about to be
/// overwritten and so does not count against the quota.
fn usedBytes(all: []const Item, replacing: []const u8) u64 {
    var total: u64 = 0;
    for (all) |item| {
        if (std.mem.eql(u8, item.path, replacing)) continue;
        total += item.size;
    }
    return total;
}

const kinds = std.enums.values(Kind);

fn dirOfKind(kind: Kind) []const u8 {
    return switch (kind) {
        .post => "posts",
        .page => "pages",
    };
}

fn kindOfDir(dir: []const u8) ?Kind {
    for (kinds) |kind| {
        if (std.mem.eql(u8, dirOfKind(kind), dir)) return kind;
    }
    return null;
}

/// `media/`, or the folder under it; created first when `create`.
fn openFolder(store: *Store, folder: ?Folder, create: bool) !Io.Dir {
    var buf: [128]u8 = undefined;
    const path = if (folder) |f| try folderPath(&buf, f) else dir_name;
    if (create) try store.root.createDirPath(store.io, path);
    return store.root.openDir(store.io, path, .{}) catch |err|
        switch (err) {
            error.FileNotFound => error.NotFound,
            else => err,
        };
}

fn folderPath(buf: []u8, folder: Folder) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}/{s}", .{
        dir_name, dirOfKind(folder.kind), folder.slug,
    });
}

fn collect(io: Io, arena: Allocator, media_dir: Io.Dir) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    try appendFiles(io, arena, &out, media_dir, null);
    for (kinds) |kind| {
        var kind_dir = media_dir.openDir(io, dirOfKind(kind), .{
            .iterate = true,
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer kind_dir.close(io);
        const slugs = try files.listNames(arena, io, kind_dir, .directory);
        for (slugs) |slug| {
            names.validateSlug(slug) catch continue;
            var dir = try kind_dir.openDir(io, slug, .{ .iterate = true });
            defer dir.close(io);
            const folder: Folder = .{ .kind = kind, .slug = slug };
            try appendFiles(io, arena, &out, dir, folder);
        }
    }
    return out.items;
}

fn appendFiles(
    io: Io,
    arena: Allocator,
    out: *std.ArrayList(Item),
    dir: Io.Dir,
    folder: ?Folder,
) !void {
    const entries = try files.listNames(arena, io, dir, .file);
    for (entries) |name| {
        const media_type = mediaTypeOf(name) orelse continue;
        const stat = dir.statFile(io, name, .{}) catch continue;
        const place: Place = .{ .folder = folder, .name = name };
        try out.append(arena, .{
            .path = try pathOf(arena, place),
            .name = name,
            .size = stat.size,
            .content_type = media_type.content_type,
        });
    }
}

test "places from URLs" {
    const site = try placeOf(null, null, "logo.svg");
    try std.testing.expect(site.folder == null);
    const own = try placeOf("pages", "about", "me.png");
    try std.testing.expectEqual(Kind.page, own.folder.?.kind);
    try std.testing.expectEqualStrings("about", own.folder.?.slug);
    try std.testing.expectError(
        error.InvalidName,
        placeOf("drafts", "about", "me.png"),
    );
}

test "entry folders come and go with their files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try Store.openTesting(&tmp);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const own: Place = .{
        .folder = .{ .kind = .post, .slug = "hello" },
        .name = "cat.png",
    };
    try put(&store, arena, .{ .name = "logo.svg" }, "<svg/>");
    try put(&store, arena, own, "png");
    const items = try list(&store, arena);
    try std.testing.expectEqual(2, items.len);
    try std.testing.expectEqualStrings("logo.svg", items[0].path);
    try std.testing.expectEqualStrings("posts/hello/cat.png", items[1].path);

    const opened = try open(&store, own);
    opened.file.close(store.io);
    try std.testing.expectEqual(3, opened.size);

    try remove(&store, own);
    try std.testing.expectError(error.NotFound, open(&store, own));
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.access(store.io, "media/posts/hello", .{}),
    );
}

test "a folder can go at once" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try Store.openTesting(&tmp);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const folder = try folderOf("posts", "hello");
    try put(&store, arena, .{ .folder = folder, .name = "a.png" }, "a");
    try put(&store, arena, .{ .folder = folder, .name = "b.png" }, "b");
    try put(&store, arena, .{ .name = "logo.svg" }, "<svg/>");
    try removeFolder(&store, folder);
    const left = try list(&store, arena);
    try std.testing.expectEqual(1, left.len);
    try std.testing.expectEqualStrings("logo.svg", left[0].path);
    try std.testing.expectError(error.NotFound, removeFolder(&store, folder));
}

test "the quota counts every folder" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try Store.openTesting(&tmp);
    store.limits.media_total_bytes = 8;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const own: Place = .{
        .folder = .{ .kind = .page, .slug = "about" },
        .name = "me.png",
    };
    try put(&store, arena, own, "12345");
    try put(&store, arena, own, "123456");
    try std.testing.expectError(
        error.QuotaExceeded,
        put(&store, arena, .{ .name = "big.png" }, "123"),
    );
}
