//! Filesystem-backed content store; the single source of truth.
//!
//! Layout under the data directory:
//!   layouts/<name>/<version>.xml + HEAD
//!   styles/<name>/<version>.css  + HEAD
//!   snippets/<name>/<version>.js + HEAD
//!   posts/<slug>.html
//!   media/<file>
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
    "layouts", "styles", "snippets", "posts", "media",
};

io: Io,
root: Io.Dir,
limits: Limits,
lock: Io.RwLock = .init,

pub fn open(io: Io, data_dir: []const u8, limits: Limits) !Store {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, data_dir);
    const root = try cwd.openDir(io, data_dir, .{ .iterate = true });
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
