//! The layout vocabulary and its validation rules. Layouts are
//! validated on upload, so rendering can trust their structure.

const std = @import("std");
const Allocator = std.mem.Allocator;

const xml = @import("xml.zig");

/// Every element a layout may contain.
pub const Component = enum {
    layout,
    header,
    footer,
    sidebar,
    section,
    main,
    nav,
    link,
    @"page-links",
    logo,
    @"site-title",
    tagline,
    text,
    search,
    @"recent-posts",
    @"post-cards",
    home,
    raw,
};

pub const Kind = enum { single, @"sidebar-left", @"sidebar-right" };

const Content = enum {
    /// Child components (any except `layout` and `page-links`).
    components,
    /// `link` and `page-links` only.
    links,
    /// Text only.
    text,
    /// Nothing.
    empty,
};

const Spec = struct {
    content: Content,
    allowed: []const []const u8 = &.{},
    required: []const []const u8 = &.{},
};

fn specOf(component: Component) Spec {
    return switch (component) {
        .layout => .{
            .content = .components,
            .allowed = &.{ "kind", "favicon", "lang" },
        },
        .header, .footer, .sidebar, .home => .{ .content = .components },
        .section => .{ .content = .components, .allowed = &.{"title"} },
        .nav => .{ .content = .links },
        .link => .{
            .content = .text,
            .allowed = &.{"href"},
            .required = &.{"href"},
        },
        .logo => .{
            .content = .empty,
            .allowed = &.{ "src", "alt", "size" },
            .required = &.{"src"},
        },
        .tagline, .text, .raw => .{ .content = .text },
        .search => .{ .content = .empty, .allowed = &.{"placeholder"} },
        .@"recent-posts" => .{ .content = .empty, .allowed = &.{"count"} },
        .@"post-cards" => .{
            .content = .empty,
            .allowed = &.{ "count", "tag", "kind" },
        },
        .main, .@"page-links", .@"site-title" => .{ .content = .empty },
    };
}

pub const Error = error{
    UnknownLayoutElement,
    UnknownLayoutAttribute,
    MissingLayoutAttribute,
    InvalidLayoutContent,
    InvalidLayoutValue,
    LayoutNeedsOneMain,
};

/// Parses and validates a layout source.
pub fn parseLayout(
    arena: Allocator,
    source: []const u8,
) (Error || xml.ParseError)!xml.Element {
    const root = try xml.parse(arena, source);
    if (!std.mem.eql(u8, root.name, "layout")) {
        return error.UnknownLayoutElement;
    }
    var mains: usize = 0;
    try validateElement(root, &mains);
    if (mains != 1) return error.LayoutNeedsOneMain;
    return root;
}

pub fn componentOf(element: xml.Element) ?Component {
    return std.meta.stringToEnum(Component, element.name);
}

fn validateElement(element: xml.Element, mains: *usize) Error!void {
    const component = componentOf(element) orelse
        return error.UnknownLayoutElement;
    if (component == .main) mains.* += 1;
    const spec = specOf(component);
    try validateAttrs(element, spec);
    try validateValues(element, component);
    for (element.children) |child| switch (child) {
        .text => if (spec.content != .text) {
            return error.InvalidLayoutContent;
        },
        .element => |e| {
            try validateChildKind(spec.content, e);
            try validateElement(e, mains);
        },
    };
}

fn validateChildKind(content: Content, child: xml.Element) Error!void {
    const component = componentOf(child) orelse
        return error.UnknownLayoutElement;
    const ok = switch (content) {
        .components => component != .layout and
            component != .@"page-links",
        .links => component == .link or component == .@"page-links",
        .text, .empty => false,
    };
    if (!ok) return error.InvalidLayoutContent;
}

fn validateAttrs(element: xml.Element, spec: Spec) Error!void {
    for (element.attrs) |a| {
        if (!contains(spec.allowed, a.name)) {
            return error.UnknownLayoutAttribute;
        }
    }
    for (spec.required) |name| {
        if (element.attr(name) == null) return error.MissingLayoutAttribute;
    }
}

fn validateValues(element: xml.Element, component: Component) Error!void {
    switch (component) {
        .layout => if (element.attr("kind")) |kind| {
            if (std.meta.stringToEnum(Kind, kind) == null) {
                return error.InvalidLayoutValue;
            }
        },
        .link => if (!isSafeUrl(element.attr("href").?)) {
            return error.InvalidLayoutValue;
        },
        .logo => {
            if (!isSafeUrl(element.attr("src").?)) {
                return error.InvalidLayoutValue;
            }
            if (element.attr("size")) |size| {
                const n = std.fmt.parseInt(u16, size, 10) catch
                    return error.InvalidLayoutValue;
                if (n == 0 or n > 512) return error.InvalidLayoutValue;
            }
        },
        .@"recent-posts", .@"post-cards" => {
            if (element.attr("count")) |count| try validateCount(count);
            if (element.attr("kind")) |kind| {
                if (!eql(kind, "post") and !eql(kind, "page")) {
                    return error.InvalidLayoutValue;
                }
            }
        },
        else => {},
    }
    if (element.attr("favicon")) |url| {
        if (!isSafeUrl(url)) return error.InvalidLayoutValue;
    }
}

fn validateCount(count: []const u8) Error!void {
    const n = std.fmt.parseInt(u8, count, 10) catch
        return error.InvalidLayoutValue;
    if (n == 0 or n > 50) return error.InvalidLayoutValue;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Allows site-relative paths, media references, anchors, http(s)
/// and mailto. Blocks `javascript:` and every other scheme.
pub fn isSafeUrl(url: []const u8) bool {
    const prefixes = [_][]const u8{
        "/", "#", "media:", "https://", "http://", "mailto:",
    };
    if (std.mem.startsWith(u8, url, "//")) return false;
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, url, prefix)) return true;
    }
    return false;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, item)) return true;
    return false;
}

const testing = std.testing;

test "valid layout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    _ = try parseLayout(arena_state.allocator(),
        \\<layout kind="sidebar-right">
        \\  <header><site-title/><nav><link href="/">home</link>
        \\  <page-links/></nav></header>
        \\  <main/>
        \\  <sidebar><section title="x"><recent-posts count="5"/>
        \\  </section></sidebar>
        \\</layout>
    );
}

test "invalid layouts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectError(
        error.LayoutNeedsOneMain,
        parseLayout(a, "<layout><header/></layout>"),
    );
    try testing.expectError(
        error.InvalidLayoutValue,
        parseLayout(a, "<layout><main/><link href='javascript:x'>a</link>" ++
            "</layout>"),
    );
    try testing.expectError(
        error.UnknownLayoutElement,
        parseLayout(a, "<layout><main/><script/></layout>"),
    );
    try testing.expectError(
        error.UnknownLayoutAttribute,
        parseLayout(a, "<layout><main onclick='x'/></layout>"),
    );
}
