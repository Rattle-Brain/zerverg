//! Renders a validated layout tree into a complete HTML document.
//!
//! Every component maps to a fixed HTML structure with `zv-*`
//! classes, so styles can target them; see the docs page for the
//! full vocabulary.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Error = Writer.Error;

const xml = @import("xml.zig");
const schema = @import("schema.zig");
const posts = @import("../store/posts.zig");
const SiteState = @import("../store/site_state.zig").SiteState;
const fragments = @import("../site/fragments.zig");
const escape = fragments.writeEscaped;

pub const PageContext = struct {
    site: SiteState,
    /// Page title, empty for the home page.
    title: []const u8,
    /// Trusted, admin-authored HTML for `<main/>`.
    main_html: []const u8,
    /// All entries, newest first (for recent posts and page links).
    entries: []const posts.Summary,
    search_query: []const u8 = "",
    /// The home page: `<home>` children render only here.
    is_home: bool = false,
    /// Stylesheet to embed instead of linking the active one (theme
    /// previews of a style that is not active yet).
    inline_css: ?[]const u8 = null,
};

pub fn renderDocument(
    arena: Allocator,
    layout: xml.Element,
    ctx: PageContext,
) Error![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    try writeHead(w, layout, ctx);
    try w.writeAll("<body class=\"zv-kind-");
    try escape(w, layout.attr("kind") orelse "single");
    try w.writeAll("\">\n<div class=\"zv-page\">\n");
    try renderChildren(w, layout, ctx);
    try w.writeAll("</div>\n");
    for (ctx.site.enabled_snippets) |name| {
        // Snippet names are validated slugs.
        try w.print(
            "<script src=\"/assets/snippets/{s}.js\" defer></script>\n",
            .{name},
        );
    }
    try w.writeAll("</body>\n</html>\n");
    return out.written();
}

fn writeHead(w: *Writer, layout: xml.Element, ctx: PageContext) Error!void {
    try w.writeAll("<!doctype html>\n<html lang=\"");
    try escape(w, layout.attr("lang") orelse "en");
    try w.writeAll("\">\n<head>\n<meta charset=\"utf-8\">\n" ++
        "<meta name=\"viewport\" " ++
        "content=\"width=device-width, initial-scale=1\">\n" ++
        "<meta name=\"generator\" content=\"zerverg\">\n<title>");
    if (ctx.title.len > 0) {
        try escape(w, ctx.title);
        try w.writeAll(" :: ");
    }
    try escape(w, ctx.site.title);
    try w.writeAll("</title>\n");
    if (layout.attr("favicon")) |url| {
        try w.writeAll("<link rel=\"icon\" href=\"");
        try fragments.writeUrl(w, url);
        try w.writeAll("\">\n");
    }
    if (ctx.inline_css) |css| {
        try w.print("<style>\n{s}\n</style>\n", .{css});
    } else if (ctx.site.active_style != null) {
        try w.writeAll(
            "<link rel=\"stylesheet\" href=\"/assets/style.css\">\n",
        );
    }
    try w.writeAll("</head>\n");
}

fn renderChildren(
    w: *Writer,
    element: xml.Element,
    ctx: PageContext,
) Error!void {
    for (element.children) |child| switch (child) {
        .element => |e| try renderElement(w, e, ctx),
        .text => {},
    };
}

fn renderElement(w: *Writer, e: xml.Element, ctx: PageContext) Error!void {
    const component = schema.componentOf(e) orelse return;
    switch (component) {
        .layout => {},
        .header => try wrap(w, e, ctx, "header", "zv-header"),
        .footer => try wrap(w, e, ctx, "footer", "zv-footer"),
        .sidebar => try wrap(w, e, ctx, "aside", "zv-sidebar"),
        .section => try renderSection(w, e, ctx),
        .main => try w.print(
            "<main class=\"zv-main\">\n{s}\n</main>\n",
            .{ctx.main_html},
        ),
        .nav => try renderNav(w, e, ctx),
        .link => try renderLink(w, e),
        .@"page-links" => try renderPageLinks(w, ctx),
        .logo => try renderLogo(w, e),
        .@"site-title" => {
            try w.writeAll("<a class=\"zv-site-title\" href=\"/\">");
            try escape(w, ctx.site.title);
            try w.writeAll("</a>\n");
        },
        .tagline => try wrapText(w, e, "p", "zv-tagline"),
        .text => try wrapText(w, e, "p", "zv-text"),
        .search => try renderSearch(w, e, ctx),
        .@"recent-posts" => try renderRecent(w, e, ctx),
        .@"post-cards" => try renderCards(w, e, ctx),
        .home => if (ctx.is_home) try renderChildren(w, e, ctx),
        .raw => for (e.children) |c| switch (c) {
            .text => |t| try w.writeAll(t),
            .element => {},
        },
    }
}

fn wrap(
    w: *Writer,
    e: xml.Element,
    ctx: PageContext,
    tag: []const u8,
    class: []const u8,
) Error!void {
    try w.print("<{s} class=\"{s}\">\n", .{ tag, class });
    try renderChildren(w, e, ctx);
    try w.print("</{s}>\n", .{tag});
}

fn wrapText(
    w: *Writer,
    e: xml.Element,
    tag: []const u8,
    class: []const u8,
) Error!void {
    try w.print("<{s} class=\"{s}\">", .{ tag, class });
    try writeText(w, e);
    try w.print("</{s}>\n", .{tag});
}

fn writeText(w: *Writer, e: xml.Element) Error!void {
    for (e.children) |child| switch (child) {
        .text => |t| try escape(w, std.mem.trim(u8, t, " \t\r\n")),
        .element => {},
    };
}

fn renderSection(w: *Writer, e: xml.Element, ctx: PageContext) Error!void {
    try w.writeAll("<section class=\"zv-section\">\n");
    if (e.attr("title")) |title| {
        try w.writeAll("<h2 class=\"zv-section-title\">");
        try escape(w, title);
        try w.writeAll("</h2>\n");
    }
    try renderChildren(w, e, ctx);
    try w.writeAll("</section>\n");
}

fn renderNav(w: *Writer, e: xml.Element, ctx: PageContext) Error!void {
    try w.writeAll("<nav class=\"zv-nav\"><ul>\n");
    for (e.children) |child| switch (child) {
        .element => |link| {
            if (schema.componentOf(link) == .@"page-links") {
                try renderPageLinks(w, ctx);
                continue;
            }
            try w.writeAll("<li>");
            try renderLink(w, link);
            try w.writeAll("</li>\n");
        },
        .text => {},
    };
    try w.writeAll("</ul></nav>\n");
}

fn renderLink(w: *Writer, e: xml.Element) Error!void {
    try w.writeAll("<a class=\"zv-link\" href=\"");
    try fragments.writeUrl(w, e.attr("href").?);
    try w.writeAll("\">");
    try writeText(w, e);
    try w.writeAll("</a>");
}

/// `<li>` links to every page except the home page.
fn renderPageLinks(w: *Writer, ctx: PageContext) Error!void {
    for (ctx.entries) |entry| {
        if (entry.meta.kind != .page) continue;
        if (std.mem.eql(u8, entry.slug, "index")) continue;
        try w.print("<li><a class=\"zv-link\" href=\"/{s}\">", .{entry.slug});
        try escape(w, fragments.titleOf(entry));
        try w.writeAll("</a></li>\n");
    }
}

fn renderLogo(w: *Writer, e: xml.Element) Error!void {
    const size = e.attr("size") orelse "48";
    try w.writeAll("<a class=\"zv-logo\" href=\"/\"><img src=\"");
    try fragments.writeUrl(w, e.attr("src").?);
    try w.writeAll("\" alt=\"");
    try escape(w, e.attr("alt") orelse "");
    try w.writeAll("\" width=\"");
    try escape(w, size);
    try w.writeAll("\" height=\"");
    try escape(w, size);
    try w.writeAll("\"></a>\n");
}

fn renderSearch(w: *Writer, e: xml.Element, ctx: PageContext) Error!void {
    try w.writeAll(
        "<form class=\"zv-search\" action=\"/search\" method=\"get\" " ++
            "role=\"search\">\n<input type=\"search\" name=\"q\" " ++
            "maxlength=\"100\" aria-label=\"search\" placeholder=\"",
    );
    try escape(w, e.attr("placeholder") orelse "search...");
    try w.writeAll("\" value=\"");
    try escape(w, ctx.search_query);
    try w.writeAll("\">\n<button type=\"submit\">go</button>\n</form>\n");
}

fn renderRecent(w: *Writer, e: xml.Element, ctx: PageContext) Error!void {
    const count = if (e.attr("count")) |c|
        std.fmt.parseInt(u8, c, 10) catch 5
    else
        5;
    try fragments.writeEntryList(
        w,
        ctx.entries,
        .{ .limit = count },
        "zv-recent",
    );
}

/// `<post-cards count="6" tag="x" kind="post"/>`
fn renderCards(w: *Writer, e: xml.Element, ctx: PageContext) Error!void {
    var filter: fragments.EntryFilter = .{ .limit = 6 };
    if (e.attr("count")) |c| filter.limit = std.fmt.parseInt(u8, c, 10) catch 6;
    if (e.attr("kind")) |k| filter.kind = std.meta.stringToEnum(
        @TypeOf(filter.kind),
        k,
    ) orelse .post;
    filter.tag = e.attr("tag");
    try w.writeAll("<div class=\"zv-post-cards\">\n");
    try fragments.writeEntryCards(w, ctx.entries, filter);
    try w.writeAll("</div>\n");
}

test "renders a layout" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const layout = try schema.parseLayout(arena,
        \\<layout kind="sidebar-right" favicon="media:i.svg">
        \\<header><site-title/><nav><link href="/x">x &amp; y</link>
        \\</nav></header><main/><footer><text>bye</text></footer>
        \\</layout>
    );
    const html = try renderDocument(arena, layout, .{
        .site = .{ .title = "T<" },
        .title = "",
        .main_html = "<p>body</p>",
        .entries = &.{},
    });
    const expect = std.testing.expect;
    const has = struct {
        fn f(h: []const u8, n: []const u8) bool {
            return std.mem.indexOf(u8, h, n) != null;
        }
    }.f;
    try expect(has(html, "<title>T&lt;</title>"));
    try expect(has(html, "href=\"/media/i.svg\""));
    try expect(has(html, ">x &amp; y</a>"));
    try expect(has(html, "<main class=\"zv-main\">\n<p>body</p>"));
    try expect(has(html, "class=\"zv-kind-sidebar-right\""));
}

test "home-only blocks and cards" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const layout = try schema.parseLayout(arena,
        \\<layout><home><post-cards count="2"/></home><main/></layout>
    );
    const entries = [_]posts.Summary{.{ .slug = "a", .meta = .{
        .title = "A",
        .description = "about a",
        .image = "media:a.svg",
    } }};
    var ctx: PageContext = .{
        .site = .{},
        .title = "",
        .main_html = "",
        .entries = &entries,
        .inline_css = "p{}",
    };
    const inner = try renderDocument(arena, layout, ctx);
    try std.testing.expect(std.mem.indexOf(u8, inner, "zv-card") == null);
    try std.testing.expect(std.mem.indexOf(u8, inner, "<style>") != null);
    ctx.is_home = true;
    const home = try renderDocument(arena, layout, ctx);
    const expected = "src=\"/media/a.svg\"";
    try std.testing.expect(std.mem.indexOf(u8, home, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, home, "about a") != null);
}
