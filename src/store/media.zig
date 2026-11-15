//! Media files (images, videos) under `media/`, with per-type size
//! limits and a total quota so uploads cannot fill the disk.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Store = @import("Store.zig");
const names = @import("names.zig");
const files = @import("files.zig");

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

pub const Item = struct {
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

pub fn list(store: *Store, arena: Allocator) ![]Item {
    store.lockShared();
    defer store.unlockShared();
    var dir = try store.openSubdir(dir_name);
    defer dir.close(store.io);

    const entries = try files.listNames(arena, store.io, dir, .file);
    var out: std.ArrayList(Item) = .empty;
    for (entries) |entry| {
        const media_type = mediaTypeOf(entry) orelse continue;
        const stat = dir.statFile(store.io, entry, .{}) catch continue;
        try out.append(arena, .{
            .name = entry,
            .size = stat.size,
            .content_type = media_type.content_type,
        });
    }
    return out.items;
}

pub const Opened = struct {
    file: std.Io.File,
    size: u64,
    content_type: []const u8,
};

/// Opens a media file for streaming. The caller closes `file`.
/// POSIX keeps the handle valid even if the file is replaced or
/// deleted meanwhile, so the lock is only held while opening.
pub fn open(store: *Store, name: []const u8) !Opened {
    try names.validateFileName(name);
    const media_type = mediaTypeOf(name) orelse return error.NotFound;
    store.lockShared();
    defer store.unlockShared();
    var dir = try store.openSubdir(dir_name);
    defer dir.close(store.io);
    const file = dir.openFile(store.io, name, .{}) catch |err| switch (err) {
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
    name: []const u8,
    data: []const u8,
) !void {
    try names.validateFileName(name);
    const media_type = mediaTypeOf(name) orelse
        return error.UnsupportedMediaType;
    if (data.len > limitFor(store.limits, media_type.category)) {
        return error.TooLarge;
    }
    store.lockExclusive();
    defer store.unlockExclusive();
    var dir = try store.openSubdir(dir_name);
    defer dir.close(store.io);

    const used = try usedBytes(store, arena, dir, name);
    if (used + data.len > store.limits.media_total_bytes) {
        return error.QuotaExceeded;
    }
    try files.writeAtomic(store.io, dir, name, data);
}

pub fn remove(store: *Store, name: []const u8) !void {
    try names.validateFileName(name);
    store.lockExclusive();
    defer store.unlockExclusive();
    var dir = try store.openSubdir(dir_name);
    defer dir.close(store.io);
    dir.deleteFile(store.io, name) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return err,
    };
}

fn limitFor(limits: Store.Limits, category: Category) usize {
    return switch (category) {
        .image => limits.image_bytes,
        .video => limits.video_bytes,
    };
}

/// Total size of all media except `replacing`, which is about to be
/// overwritten and so does not count against the quota.
fn usedBytes(
    store: *Store,
    arena: Allocator,
    dir: std.Io.Dir,
    replacing: []const u8,
) !u64 {
    const entries = try files.listNames(arena, store.io, dir, .file);
    var total: u64 = 0;
    for (entries) |entry| {
        if (std.mem.eql(u8, entry, replacing)) continue;
        const stat = dir.statFile(store.io, entry, .{}) catch continue;
        total += stat.size;
    }
    return total;
}
