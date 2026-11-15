//! Small filesystem helpers shared by the store modules.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Writes to a temporary file and renames it into place, so readers
/// never observe a half-written file.
pub fn writeAtomic(
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    data: []const u8,
) !void {
    var tmp_buf: [128]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, ".tmp-{s}", .{name});
    try dir.writeFile(io, .{ .sub_path = tmp, .data = data });
    errdefer dir.deleteFile(io, tmp) catch {};
    try dir.rename(tmp, dir, name, io);
}

pub fn readAll(
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    limit: usize,
) ![]u8 {
    return dir.readFileAlloc(io, name, arena, .limited(limit + 1));
}

/// Lists visible entries of `kind` in `dir`, sorted by name.
pub fn listNames(
    arena: Allocator,
    io: Io,
    dir: Io.Dir,
    kind: Io.File.Kind,
) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != kind) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
