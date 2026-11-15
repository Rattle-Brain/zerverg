//! Assembles public pages: picks the layout, builds the main
//! content and renders the document.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Context = @import("../Context.zig");
const Response = @import("../http/Response.zig");
const posts = @import("../store/posts.zig");
const library = @import("../store/library.zig");
const site_state = @import("../store/site_state.zig");
const meta = @import("../content/meta.zig");
const xml = @import("../layout/xml.zig");
const schema = @import("../layout/schema.zig");
const layout_render = @import("../layout/render.zig");
const seed = @import("../defaults/seed.zig");
const fragments = @import("fragments.zig");
const entries_tag = @import("entries_tag.zig");

const home_slug = "index";

const Page = struct {
    layout_name: ?[]const u8 = null,
    title: []const u8,
    main_html: []const u8,
    search_query: []const u8 = "",
};

/// The `index` page if there is one, otherwise the list of posts.
pub fn home(ctx: *Context) !Response {
    const store = ctx.app.store;
    const entries = try posts.list(store, ctx.arena);
    const html = posts.read(store, ctx.arena, home_slug) catch |err|
        switch (err) {
            error.NotFound => return postList(ctx, entries),
            else => return err,
        };
    const entry_meta = try meta.extract(html);
    const main_html = try entryMain(ctx.arena, html, entry_meta, entries);
    return render(ctx, entries, .{
        .layout_name = entry_meta.layout,
        .title = "",
        .main_html = main_html,
    });
}

pub fn entry(ctx: *Context, slug: []const u8) !Response {
    const store = ctx.app.store;
    const html = try posts.read(store, ctx.arena, slug);
    const entries = try posts.list(store, ctx.arena);
    const entry_meta = try meta.extract(html);
    const main_html = try entryMain(ctx.arena, html, entry_meta, entries);
    return render(ctx, entries, .{
        .layout_name = entry_meta.layout,
        .title = if (entry_meta.title.len > 0) entry_meta.title else slug,
        .main_html = main_html,
    });
}

pub fn search(ctx: *Context, query: []const u8) !Response {
    const store = ctx.app.store;
    const entries = try posts.list(store, ctx.arena);
    var out: Writer.Allocating = .init(ctx.arena);
    const w = &out.writer;
    try w.writeAll("<h1>search</h1>\n");
    if (query.len < 2) {
        try w.writeAll("<p class=\"zv-empty\">type at least two " ++
            "characters.</p>\n");
    } else {
        const hits = try posts.search(store, ctx.arena, query);
        try w.writeAll("<p>results for <code>");
        try fragments.writeEscaped(w, query);
        try w.print("</code>: {d}</p>\n", .{hits.len});
        try writeHits(w, hits);
    }
    return render(ctx, entries, .{
        .title = "search",
        .main_html = out.written(),
        .search_query = query,
    });
}

fn writeHits(w: *Writer, hits: []const posts.Summary) !void {
    if (hits.len == 0) return;
    try w.writeAll("<ul class=\"zv-entries\">\n");
    for (hits) |hit| {
        try w.print("<li><a href=\"/{s}\">", .{hit.slug});
        try fragments.writeEscaped(w, fragments.titleOf(hit));
        try w.writeAll("</a></li>\n");
    }
    try w.writeAll("</ul>\n");
}

fn postList(ctx: *Context, entries: []const posts.Summary) !Response {
    var out: Writer.Allocating = .init(ctx.arena);
    try out.writer.writeAll("<h1>posts</h1>\n");
    try fragments.writeEntryList(&out.writer, entries, .{}, "zv-entries");
    return render(ctx, entries, .{ .title = "", .main_html = out.written() });
}

/// Posts get a title header; pages render their body as-is.
fn entryMain(
    arena: Allocator,
    html: []const u8,
    entry_meta: meta.Meta,
    entries: []const posts.Summary,
) ![]const u8 {
    const body = try entries_tag.expand(arena, meta.bodyOf(html), entries);
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("<article class=\"zv-entry\">\n");
    if (entry_meta.kind == .post) try writeEntryHeader(w, entry_meta);
    try w.writeAll(body);
    try w.writeAll("\n</article>");
    return fragments.resolveMediaRefs(arena, out.written());
}

fn writeEntryHeader(w: *Writer, entry_meta: meta.Meta) !void {
    try w.writeAll("<header class=\"zv-entry-header\">\n<h1>");
    try fragments.writeEscaped(w, entry_meta.title);
    try w.writeAll("</h1>\n<p class=\"zv-entry-meta\">");
    if (entry_meta.date.len > 0) {
        try w.writeAll("<time>");
        try fragments.writeEscaped(w, entry_meta.date);
        try w.writeAll("</time>");
    }
    var tags = std.mem.splitScalar(u8, entry_meta.tags, ',');
    while (tags.next()) |raw| {
        const tag = std.mem.trim(u8, raw, " ");
        if (tag.len == 0) continue;
        try w.writeAll("<span class=\"zv-tag\">");
        try fragments.writeEscaped(w, tag);
        try w.writeAll("</span>");
    }
    try w.writeAll("</p>\n</header>\n");
}

fn render(
    ctx: *Context,
    entries: []const posts.Summary,
    page: Page,
) !Response {
    const state = try site_state.read(ctx.app.store, ctx.arena);
    const layout_name = page.layout_name orelse state.active_layout;
    const layout = loadLayout(ctx, layout_name);
    const body = try layout_render.renderDocument(ctx.arena, layout, .{
        .site = state,
        .title = page.title,
        .main_html = page.main_html,
        .entries = entries,
        .search_query = page.search_query,
    });
    return Response.html(body);
}

/// The named layout, falling back to the built-in default if it is
/// missing or broken, so a bad layout never takes the site down.
fn loadLayout(ctx: *Context, name: ?[]const u8) xml.Element {
    if (name) |n| {
        if (loadStored(ctx, n)) |layout| return layout else |err| {
            std.log.warn("layout '{s}' unusable: {t}", .{ n, err });
        }
    }
    return schema.parseLayout(ctx.arena, seed.default_layout) catch
        minimal_layout;
}

fn loadStored(ctx: *Context, name: []const u8) !xml.Element {
    const source = try library.read(
        ctx.app.store,
        ctx.arena,
        .layouts,
        name,
        null,
    );
    return schema.parseLayout(ctx.arena, source);
}

const minimal_layout: xml.Element = .{
    .name = "layout",
    .children = &.{.{ .element = .{ .name = "main" } }},
};
