//! Filesystem-backed content store; the single source of truth.
//!
//! Layout under the data directory:
//!   layouts/<name>/<version>.xml + HEAD
//!   styles/<name>/<version>.css  + HEAD
//!   snippets/<name>/<version>.js + HEAD
//!   posts/<slug>.html
//!   drafts/<slug>.html             unpublished; never served
//!   media/<file>                   site-wide
//!   media/posts/<slug>/<file>      one post's own
//!   media/pages/<slug>/<file>      one page's own
//!   site.json
//!
//! One RwLock guards everything: public reads share it, admin writes
//! take it exclusively. A single-admin site never contends on writes.

const std = @import("std");
const Io = std.Io;

const Store = @This();

pub const Limits = struct {
    text_bytes: usize,
    image_bytes: usize,
    video_bytes: usize,
    media_total_bytes: u64,
    history_keep: u16,
};

const subdirs = [_][]const u8{
    "layouts", "styles", "snippets", "posts", "drafts", "media",
};

io: Io,
root: Io.Dir,
limits: Limits,
lock: Io.RwLock = .init,

pub fn open(io: Io, data_dir: []const u8, limits: Limits) !Store {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, data_dir);
    const root = try cwd.openDir(io, data_dir, .{ .iterate = true });
    return openDir(io, root, limits);
}

/// A store over an already open `root`, which it then owns.
pub fn openDir(io: Io, root: Io.Dir, limits: Limits) !Store {
    for (subdirs) |name| try root.createDirPath(io, name);
    return .{ .io = io, .root = root, .limits = limits };
}

pub fn close(self: *Store) void {
    self.root.close(self.io);
}

pub fn lockShared(self: *Store) void {
    self.lock.lockSharedUncancelable(self.io);
}

pub fn unlockShared(self: *Store) void {
    self.lock.unlockShared(self.io);
}

pub fn lockExclusive(self: *Store) void {
    self.lock.lockUncancelable(self.io);
}

pub fn unlockExclusive(self: *Store) void {
    self.lock.unlock(self.io);
}

pub fn openSubdir(self: *Store, name: []const u8) !Io.Dir {
    return self.root.openDir(self.io, name, .{ .iterate = true });
}

/// A store in a fresh temporary directory, for tests. Closing `tmp`
/// closes the store.
pub fn openTesting(tmp: *const std.testing.TmpDir) !Store {
    return openDir(std.testing.io, tmp.dir, .{
        .text_bytes = 64 * 1024,
        .image_bytes = 64 * 1024,
        .video_bytes = 64 * 1024,
        .media_total_bytes = 1024 * 1024,
        .history_keep = 4,
    });
}
