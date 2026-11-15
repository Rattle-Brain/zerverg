//! Site-wide settings that the admin changes at runtime: title and
//! which layout, style and snippets are active. Stored as site.json.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Store = @import("Store.zig");
const names = @import("names.zig");
const files = @import("files.zig");

pub const SiteState = struct {
    title: []const u8 = "zerverg",
    active_layout: ?[]const u8 = null,
    active_style: ?[]const u8 = null,
    enabled_snippets: []const []const u8 = &.{},
};

const file_name = "site.json";
const max_bytes = 64 * 1024;

pub fn read(store: *Store, arena: Allocator) !SiteState {
    store.lockShared();
    defer store.unlockShared();
    const data = files.readAll(
        arena,
        store.io,
        store.root,
        file_name,
        max_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return parse(arena, data);
}

/// Whether settings were ever written (the data dir is initialised).
pub fn exists(store: *Store) !bool {
    store.lockShared();
    defer store.unlockShared();
    store.root.access(store.io, file_name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

pub fn parse(arena: Allocator, json: []const u8) !SiteState {
    return std.json.parseFromSliceLeaky(SiteState, arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub fn write(store: *Store, arena: Allocator, state: SiteState) !void {
    try validate(state);
    const json = try std.json.Stringify.valueAlloc(arena, state, .{
        .whitespace = .indent_2,
    });
    store.lockExclusive();
    defer store.unlockExclusive();
    try files.writeAtomic(store.io, store.root, file_name, json);
}

fn validate(state: SiteState) !void {
    if (state.title.len > 200) return error.InvalidTitle;
    if (state.active_layout) |n| try names.validateSlug(n);
    if (state.active_style) |n| try names.validateSlug(n);
    if (state.enabled_snippets.len > 64) return error.TooManySnippets;
    for (state.enabled_snippets) |n| try names.validateSlug(n);
}

test "parse partial state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const state = try parse(
        arena_state.allocator(),
        "{\"active_style\":\"dark\",\"enabled_snippets\":[\"a\"]}",
    );
    try std.testing.expectEqualStrings("dark", state.active_style.?);
    try std.testing.expectEqualStrings("zerverg", state.title);
    try std.testing.expectEqual(@as(usize, 1), state.enabled_snippets.len);
}
