//! Versioned libraries of layouts, styles and snippets.
//!
//! Each item is a directory holding numbered versions plus a HEAD
//! file naming the current one. Uploading creates a new version and
//! moves HEAD to it; rolling back moves HEAD to an older version.
//! Versions beyond `history_keep` are pruned, oldest first.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Store = @import("Store.zig");
const names = @import("names.zig");
const files = @import("files.zig");

pub const Kind = enum {
    layouts,
    styles,
    snippets,

    pub fn extension(kind: Kind) []const u8 {
        return switch (kind) {
            .layouts => "xml",
            .styles => "css",
            .snippets => "js",
        };
    }

    pub fn contentType(kind: Kind) []const u8 {
        return switch (kind) {
            .layouts => "application/xml; charset=utf-8",
            .styles => "text/css; charset=utf-8",
            .snippets => "text/javascript; charset=utf-8",
        };
    }
};

pub const Item = struct {
    name: []const u8,
    version: u32,
};

pub const Error = error{
    NotFound,
    TooLarge,
    InvalidName,
};

const head_file = "HEAD";

pub fn list(store: *Store, arena: Allocator, kind: Kind) ![]Item {
    store.lockShared();
    defer store.unlockShared();
    var kind_dir = try store.openSubdir(@tagName(kind));
    defer kind_dir.close(store.io);

    const item_names = try files.listNames(
        arena,
        store.io,
        kind_dir,
        .directory,
    );
    var items: std.ArrayList(Item) = .empty;
    for (item_names) |name| {
        var dir = openItem(store, kind, name) catch continue;
        defer dir.close(store.io);
        const head = readHead(store.io, dir) catch continue;
        try items.append(arena, .{ .name = name, .version = head });
    }
    return items.items;
}

/// Reads the current version, or `version` when given.
pub fn read(
    store: *Store,
    arena: Allocator,
    kind: Kind,
    name: []const u8,
    version: ?u32,
) ![]u8 {
    try names.validateSlug(name);
    store.lockShared();
    defer store.unlockShared();
    var dir = try openItem(store, kind, name);
    defer dir.close(store.io);

    const wanted = version orelse try readHead(store.io, dir);
    var buf: [32]u8 = undefined;
    const file = try versionFileName(&buf, kind, wanted);
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

pub fn versions(
    store: *Store,
    arena: Allocator,
    kind: Kind,
    name: []const u8,
) ![]u32 {
    try names.validateSlug(name);
    store.lockShared();
    defer store.unlockShared();
    var dir = try openItem(store, kind, name);
    defer dir.close(store.io);
    return listVersions(arena, store.io, dir);
}

/// Stores `data` as a new version and makes it current.
pub fn upload(
    store: *Store,
    arena: Allocator,
    kind: Kind,
    name: []const u8,
    data: []const u8,
) !u32 {
    try names.validateSlug(name);
    if (data.len > store.limits.text_bytes) return error.TooLarge;
    store.lockExclusive();
    defer store.unlockExclusive();

    var dir = try createItem(store, kind, name);
    defer dir.close(store.io);
    const existing = try listVersions(arena, store.io, dir);
    const next = if (existing.len == 0) 1 else existing[existing.len - 1] + 1;

    var buf: [32]u8 = undefined;
    const file = try versionFileName(&buf, kind, next);
    try files.writeAtomic(store.io, dir, file, data);
    try writeHead(store.io, dir, next);
    try prune(arena, store.io, dir, kind, store.limits.history_keep, next);
    return next;
}

pub fn rollback(
    store: *Store,
    kind: Kind,
    name: []const u8,
    version: u32,
) !void {
    try names.validateSlug(name);
    store.lockExclusive();
    defer store.unlockExclusive();
    var dir = try openItem(store, kind, name);
    defer dir.close(store.io);

    var buf: [32]u8 = undefined;
    const file = try versionFileName(&buf, kind, version);
    dir.access(store.io, file, .{}) catch return error.NotFound;
    try writeHead(store.io, dir, version);
}

pub fn remove(store: *Store, kind: Kind, name: []const u8) !void {
    try names.validateSlug(name);
    store.lockExclusive();
    defer store.unlockExclusive();
    var kind_dir = try store.openSubdir(@tagName(kind));
    defer kind_dir.close(store.io);
    kind_dir.access(store.io, name, .{}) catch return error.NotFound;
    try kind_dir.deleteTree(store.io, name);
}

fn openItem(store: *Store, kind: Kind, name: []const u8) !Io.Dir {
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{
        @tagName(kind), name,
    });
    return store.root.openDir(store.io, path, .{ .iterate = true }) catch |err|
        switch (err) {
            error.FileNotFound => error.NotFound,
            else => err,
        };
}

fn createItem(store: *Store, kind: Kind, name: []const u8) !Io.Dir {
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{
        @tagName(kind), name,
    });
    try store.root.createDirPath(store.io, path);
    return store.root.openDir(store.io, path, .{ .iterate = true });
}

fn readHead(io: Io, dir: Io.Dir) !u32 {
    var buf: [16]u8 = undefined;
    const text = dir.readFile(io, head_file, &buf) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => return err,
    };
    const trimmed = std.mem.trim(u8, text, " \r\n");
    return std.fmt.parseInt(u32, trimmed, 10) catch error.NotFound;
}

fn writeHead(io: Io, dir: Io.Dir, version: u32) !void {
    var buf: [16]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}\n", .{version});
    try files.writeAtomic(io, dir, head_file, text);
}

fn versionFileName(buf: []u8, kind: Kind, version: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}.{s}", .{ version, kind.extension() });
}

/// Returns version numbers in ascending order.
fn listVersions(arena: Allocator, io: Io, dir: Io.Dir) ![]u32 {
    const entries = try files.listNames(arena, io, dir, .file);
    var found: std.ArrayList(u32) = .empty;
    for (entries) |entry| {
        const dot = std.mem.indexOfScalar(u8, entry, '.') orelse continue;
        const v = std.fmt.parseInt(u32, entry[0..dot], 10) catch continue;
        try found.append(arena, v);
    }
    std.mem.sort(u32, found.items, {}, std.sort.asc(u32));
    return found.items;
}

fn prune(
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    kind: Kind,
    keep: u16,
    head: u32,
) !void {
    const all = try listVersions(arena, io, dir);
    if (all.len <= keep) return;
    var excess = all.len - keep;
    for (all) |v| {
        if (excess == 0) break;
        if (v == head) continue;
        var buf: [32]u8 = undefined;
        const file = try versionFileName(&buf, kind, v);
        dir.deleteFile(io, file) catch |err| {
            std.log.warn("prune {s}: {t}", .{ file, err });
        };
        excess -= 1;
    }
}
