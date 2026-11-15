//! Block-level Markdown: paragraphs, headings, lists, quotes, code,
//! rules, tables, raw HTML, and fenced divs (`::: name`), the one
//! extension: they become `<div class="name">` for themes to style.
//!
//! Works on a slice of lines; nested blocks (quotes, list items, divs)
//! recurse on sub-slices, so text is never copied, only re-sliced.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const inline_md = @import("inline.zig");
const table = @import("table.zig");
const syntax = @import("syntax.zig");

const Renderer = struct {
    arena: Allocator,
    w: *Writer,
};

/// `tight`: paragraphs render without `<p>` (tight list items).
pub fn render(
    arena: Allocator,
    w: *Writer,
    lines: []const []const u8,
    tight: bool,
) anyerror!void {
    const r: Renderer = .{ .arena = arena, .w = w };
    var i: usize = 0;
    while (i < lines.len) {
        if (syntax.isBlank(lines[i])) {
            i += 1;
            continue;
        }
        i = try block(r, lines, i, tight);
    }
}

/// Renders the block starting at `i`; returns the index after it.
fn block(
    r: Renderer,
    lines: []const []const u8,
    i: usize,
    tight: bool,
) anyerror!usize {
    const line = lines[i];
    if (syntax.fenceOf(line)) |fence| return codeBlock(r, lines, i, fence);
    if (syntax.divOpen(line)) |classes| return fencedDiv(r, lines, i, classes);
    if (syntax.headingOf(line)) |h| {
        try heading(r, h);
        return i + 1;
    }
    if (syntax.isRule(line)) {
        try r.w.writeAll("<hr>\n");
        return i + 1;
    }
    if (syntax.isQuote(line)) return blockquote(r, lines, i);
    if (syntax.listItemOf(line)) |item| return list(r, lines, i, item);
    if (table.startsAt(lines, i)) return table.render(r.arena, r.w, lines, i);
    if (syntax.isHtmlStart(line)) return htmlBlock(r, lines, i);
    return paragraph(r, lines, i, tight);
}

fn paragraph(
    r: Renderer,
    lines: []const []const u8,
    i: usize,
    tight: bool,
) !usize {
    var j = i + 1;
    while (j < lines.len and !syntax.isBlank(lines[j]) and
        !syntax.interruptsParagraph(lines[j])) j += 1;
    const parts = try r.arena.alloc([]const u8, j - i);
    for (lines[i..j], parts) |line, *part| {
        part.* = std.mem.trimStart(u8, line, " ");
    }
    const joined = try std.mem.join(r.arena, "\n", parts);
    const text = std.mem.trimEnd(u8, joined, " ");
    if (!tight) try r.w.writeAll("<p>");
    try inline_md.render(r.w, text);
    if (!tight) try r.w.writeAll("</p>\n");
    return j;
}

fn heading(r: Renderer, h: syntax.Heading) !void {
    try r.w.print("<h{d} id=\"", .{h.level});
    try writeAnchor(r.w, h.text);
    try r.w.writeAll("\">");
    try inline_md.render(r.w, h.text);
    try r.w.print("</h{d}>\n", .{h.level});
}

/// "Hello, World!" -> "hello-world", for `#fragment` links.
fn writeAnchor(w: *Writer, text: []const u8) !void {
    var pending_dash = false;
    var written = false;
    for (text) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (pending_dash and written) try w.writeByte('-');
            try w.writeByte(std.ascii.toLower(c));
            pending_dash = false;
            written = true;
        } else pending_dash = true;
    }
}

fn codeBlock(
    r: Renderer,
    lines: []const []const u8,
    i: usize,
    fence: syntax.Fence,
) !usize {
    try r.w.writeAll("<pre><code");
    if (fence.language.len > 0) {
        try r.w.writeAll(" class=\"language-");
        try inline_md.writeEscaped(r.w, fence.language);
        try r.w.writeByte('"');
    }
    try r.w.writeByte('>');
    var j = i + 1;
    while (j < lines.len and !syntax.closesFence(lines[j], fence)) : (j += 1) {
        try inline_md.writeEscaped(r.w, syntax.dedent(lines[j], fence.indent));
        try r.w.writeByte('\n');
    }
    try r.w.writeAll("</code></pre>\n");
    return @min(j + 1, lines.len);
}

/// `::: card wide` ... `:::`, nestable.
fn fencedDiv(
    r: Renderer,
    lines: []const []const u8,
    i: usize,
    classes: []const u8,
) !usize {
    var depth: usize = 1;
    var j = i + 1;
    while (j < lines.len) : (j += 1) {
        if (syntax.divOpen(lines[j]) != null) depth += 1;
        if (syntax.isDivClose(lines[j])) depth -= 1;
        if (depth == 0) break;
    }
    try r.w.writeAll("<div class=\"");
    try syntax.writeClasses(r.w, classes);
    try r.w.writeAll("\">\n");
    try render(r.arena, r.w, lines[i + 1 .. j], false);
    try r.w.writeAll("</div>\n");
    return @min(j + 1, lines.len);
}

/// `>` lines plus lazy continuation lines, rendered recursively.
fn blockquote(r: Renderer, lines: []const []const u8, i: usize) !usize {
    var inner: std.ArrayList([]const u8) = .empty;
    var j = i;
    while (j < lines.len and !syntax.isBlank(lines[j])) : (j += 1) {
        const line = lines[j];
        if (!syntax.isQuote(line)) {
            if (syntax.interruptsParagraph(line)) break;
            try inner.append(r.arena, line);
            continue;
        }
        var rest = std.mem.trimStart(u8, line, " ")[1..];
        if (std.mem.startsWith(u8, rest, " ")) rest = rest[1..];
        try inner.append(r.arena, rest);
    }
    try r.w.writeAll("<blockquote>\n");
    try render(r.arena, r.w, inner.items, false);
    try r.w.writeAll("</blockquote>\n");
    return j;
}

/// Raw HTML up to the next blank line, untouched.
fn htmlBlock(r: Renderer, lines: []const []const u8, i: usize) !usize {
    var j = i;
    while (j < lines.len and !syntax.isBlank(lines[j])) : (j += 1) {
        try r.w.writeAll(lines[j]);
        try r.w.writeByte('\n');
    }
    return j;
}

fn list(
    r: Renderer,
    lines: []const []const u8,
    start: usize,
    first: syntax.ListMarker,
) !usize {
    var items: std.ArrayList([]const []const u8) = .empty;
    var loose = false;
    var i = start;
    while (i < lines.len) {
        const marker = syntax.listItemOf(lines[i]) orelse break;
        if (!marker.sameListAs(first)) break;
        const item = try collectItem(r.arena, lines, i, marker);
        try items.append(r.arena, item.lines);
        loose = loose or item.has_blank;
        i = item.end;
        const next = skipBlank(lines, i);
        if (next == i or next >= lines.len) continue;
        const follows = syntax.listItemOf(lines[next]) orelse break;
        if (!follows.sameListAs(first)) break;
        loose = true;
        i = next;
    }
    try writeList(r, first, items.items, !loose);
    return i;
}

fn writeList(
    r: Renderer,
    first: syntax.ListMarker,
    items: []const []const []const u8,
    tight: bool,
) !void {
    const tag = if (first.ordered) "ol" else "ul";
    try r.w.print("<{s}", .{tag});
    if (first.ordered and first.number != 1) {
        try r.w.print(" start=\"{d}\"", .{first.number});
    }
    try r.w.writeAll(">\n");
    for (items) |item| {
        try r.w.writeAll("<li>");
        try render(r.arena, r.w, item, tight);
        try r.w.writeAll("</li>\n");
    }
    try r.w.print("</{s}>\n", .{tag});
}

const Collected = struct {
    lines: []const []const u8,
    end: usize,
    has_blank: bool,
};

/// The item's first line plus indented (or lazy) continuation lines,
/// dedented to the item's content column.
fn collectItem(
    arena: Allocator,
    lines: []const []const u8,
    i: usize,
    marker: syntax.ListMarker,
) !Collected {
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(arena, lines[i][@min(marker.content, lines[i].len)..]);
    var has_blank = false;
    var j = i + 1;
    while (j < lines.len) {
        const line = lines[j];
        if (syntax.isBlank(line)) {
            const next = skipBlank(lines, j);
            if (next >= lines.len or
                syntax.indentOf(lines[next]) < marker.content) break;
            for (j..next) |_| try out.append(arena, "");
            has_blank = true;
            j = next;
            continue;
        }
        if (syntax.indentOf(line) >= marker.content) {
            try out.append(arena, line[marker.content..]);
        } else if (syntax.isLazyContinuation(line, out.items)) {
            try out.append(arena, line);
        } else break;
        j += 1;
    }
    return .{ .lines = out.items, .end = j, .has_blank = has_blank };
}

fn skipBlank(lines: []const []const u8, from: usize) usize {
    var j = from;
    while (j < lines.len and syntax.isBlank(lines[j])) j += 1;
    return j;
}
