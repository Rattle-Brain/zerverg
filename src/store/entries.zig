//! Operations on a whole entry: its published file, its draft and
//! its media folders together.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Store = @import("Store.zig");
const names = @import("names.zig");
const posts = @import("posts.zig");
const media = @import("media.zig");
const Kind = @import("../content/meta.zig").Kind;

/// Moves entry `from` to the address `to`: its files on both
/// shelves, its media folders, and every `media:` reference to them
/// in any entry. One exclusive lock covers all of it, so no reader
/// sees the entry half moved. Each step is a rename or an atomic
/// write on the same disk: fast at any size.
pub fn rename(
    store: *Store,
    arena: Allocator,
    from: []const u8,
    to: []const u8,
) !void {
    try names.validateSlug(from);
    try names.validateSlug(to);
    if (std.mem.eql(u8, from, to)) return;
    store.lockExclusive();
    defer store.unlockExclusive();

    if (!try posts.existsLocked(store, from)) return error.NotFound;
    if (try posts.existsLocked(store, to) or
        try media.hasFolderLocked(store, to))
    {
        return error.NameTaken;
    }
    const edits = try refEdits(arena, from, to);
    try media.renameFoldersLocked(store, from, to);
    try posts.renameLocked(store, arena, from, to, &edits);
}

const kinds = std.enums.values(Kind);

/// Points references at `to`'s folders instead of `from`'s.
fn refEdits(
    arena: Allocator,
    from: []const u8,
    to: []const u8,
) ![kinds.len]posts.Edit {
    var edits: [kinds.len]posts.Edit = undefined;
    for (kinds, &edits) |kind, *edit| {
        edit.* = .{
            .old = try media.refPrefix(arena, .{ .kind = kind, .slug = from }),
            .new = try media.refPrefix(arena, .{ .kind = kind, .slug = to }),
        };
    }
    return edits;
}

test "renaming moves an entry, its draft, media and references" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try Store.openTesting(&tmp);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const own = "![cat](media:posts/old/cat.png)\n";
    const other = "<img src=\"media:posts/old/cat.png\"><a href=\"/x\">";
    _ = try posts.put(&store, .posts, "old", .{
        .text = "<title>live</title>",
        .format = .html,
    });
    _ = try posts.put(&store, .drafts, "old", .{
        .text = own,
        .format = .markdown,
    });
    _ = try posts.put(&store, .posts, "other", .{
        .text = other,
        .format = .html,
    });
    const cat: media.Place = .{
        .folder = .{ .kind = .post, .slug = "old" },
        .name = "cat.png",
    };
    try media.put(&store, arena, cat, "png");

    try rename(&store, arena, "old", "new");
    try std.testing.expectError(
        error.NotFound,
        posts.read(&store, arena, .posts, "old"),
    );
    const draft = try posts.read(&store, arena, .drafts, "new");
    try std.testing.expectEqualStrings(
        "![cat](media:posts/new/cat.png)\n",
        draft.text,
    );
    const linked = try posts.read(&store, arena, .posts, "other");
    try std.testing.expect(
        std.mem.indexOf(u8, linked.text, "media:posts/new/cat.png") != null,
    );
    var moved = cat;
    moved.folder.?.slug = "new";
    (try media.open(&store, moved)).file.close(store.io);
    try std.testing.expectError(error.NotFound, media.open(&store, cat));
}

test "renaming refuses a taken or missing address" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var store = try Store.openTesting(&tmp);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const page: posts.Source = .{ .text = "<title>a</title>", .format = .html };
    _ = try posts.put(&store, .posts, "a", page);
    _ = try posts.put(&store, .drafts, "b", page);
    const taken = error.NameTaken;
    try std.testing.expectError(taken, rename(&store, arena, "a", "b"));
    const missing = rename(&store, arena, "c", "d");
    try std.testing.expectError(error.NotFound, missing);
    try media.put(&store, arena, .{
        .folder = .{ .kind = .page, .slug = "e" },
        .name = "x.png",
    }, "png");
    try std.testing.expectError(taken, rename(&store, arena, "a", "e"));
}
