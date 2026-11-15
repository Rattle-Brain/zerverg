//! Expands `<zv-entries>` placeholders in page content into entry
//! lists. Attributes: `kind` (post|page, default post), `tag`,
//! `limit`, and `view="cards"` for image cards instead of a list.
//! Example: `<zv-entries tag="zig" limit="5"></zv-entries>`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const posts = @import("../store/posts.zig");
const meta = @import("../content/meta.zig");
const html_scan = @import("../content/html_scan.zig");
const fragments = @import("fragments.zig");

const open_tag = "<zv-entries";
const close_tag = "</zv-entries>";

pub fn expand(
    arena: Allocator,
    html: []const u8,
    entries: []const posts.Summary,
) ![]const u8 {
    if (std.ascii.indexOfIgnoreCase(html, open_tag) == null) return html;
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    var rest = html;
    while (html_scan.findTag(rest, open_tag)) |tag| {
        try w.writeAll(rest[0..tag.start]);
        const filter = filterOf(tag.text);
        const view = html_scan.attrValue(tag.text, "view") orelse "";
        if (std.mem.eql(u8, view, "cards")) {
            try fragments.writeEntryCards(w, entries, filter);
        } else {
            try fragments.writeEntryList(w, entries, filter, "zv-entries");
        }
        rest = rest[tag.end..];
        if (std.ascii.startsWithIgnoreCase(rest, close_tag)) {
            rest = rest[close_tag.len..];
        }
    }
    try w.writeAll(rest);
    return out.written();
}

fn filterOf(tag: []const u8) fragments.EntryFilter {
    var filter: fragments.EntryFilter = .{};
    if (html_scan.attrValue(tag, "kind")) |kind| {
        filter.kind = std.meta.stringToEnum(meta.Kind, kind) orelse .post;
    }
    filter.tag = html_scan.attrValue(tag, "tag");
    if (html_scan.attrValue(tag, "limit")) |limit| {
        filter.limit = std.fmt.parseInt(usize, limit, 10) catch
            filter.limit;
    }
    return filter;
}

test "expands placeholder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const entries = [_]posts.Summary{
        .{ .slug = "a", .meta = .{ .title = "A", .date = "2026-01-01" } },
        .{ .slug = "b", .meta = .{ .title = "B", .kind = .page } },
    };
    const out = try expand(
        arena_state.allocator(),
        "<p>x</p><zv-entries limit=\"3\"></zv-entries><p>y</p>",
        &entries,
    );
    try std.testing.expect(std.mem.indexOf(u8, out, "href=\"/a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "href=\"/b\"") == null);
    try std.testing.expect(std.mem.endsWith(u8, out, "</ul>\n<p>y</p>"));
}
