//! Markdown to HTML. CommonMark-flavoured, deliberately small:
//! headings, paragraphs, emphasis, links, images, lists, quotes,
//! code, rules, GFM tables, raw HTML, and fenced divs:
//!
//!     ::: note
//!     Styled by the theme as `.note`.
//!     :::
//!
//! It only produces plain semantic HTML. How it looks is up to the
//! active stylesheet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const blocks = @import("markdown/blocks.zig");

pub fn toHtml(arena: Allocator, source: []const u8) ![]const u8 {
    const text = try normalize(arena, source);
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| try lines.append(arena, line);
    var out: Writer.Allocating = .init(arena);
    try blocks.render(arena, &out.writer, lines.items, false);
    return out.written();
}

/// Drops `\r` and expands tabs to four spaces, so indentation is
/// counted in one unit.
fn normalize(arena: Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, source.len);
    for (source) |c| switch (c) {
        '\r' => {},
        '\t' => try out.appendSlice(arena, "    "),
        else => try out.append(arena, c),
    };
    return out.items;
}

fn expectHtml(source: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const html = try toHtml(arena_state.allocator(), source);
    try std.testing.expectEqualStrings(expected, html);
}

test "headings, paragraphs and rules" {
    try expectHtml(
        "# Hello, *World*!\n\nOne\ntwo\n\n---\n## Sub ##\n",
        "<h1 id=\"hello-world\">Hello, <em>World</em>!</h1>\n" ++
            "<p>One\ntwo</p>\n<hr>\n<h2 id=\"sub\">Sub</h2>\n",
    );
}

test "tight, loose and nested lists" {
    try expectHtml(
        "- a\n- b\n  - c\n\n1. x\n\n2. y\n",
        "<ul>\n<li>a</li>\n<li>b<ul>\n<li>c</li>\n</ul>\n</li>\n" ++
            "</ul>\n<ol>\n<li><p>x</p>\n</li>\n<li><p>y</p>\n</li>\n</ol>\n",
    );
    try expectHtml(
        "3) three\n4) four\n",
        "<ol start=\"3\">\n<li>three</li>\n<li>four</li>\n</ol>\n",
    );
}

test "code, quotes and fenced divs" {
    try expectHtml(
        "```zig\nconst a = 1 < 2;\n```\n> quoted\nlazy\n",
        "<pre><code class=\"language-zig\">const a = 1 &lt; 2;\n" ++
            "</code></pre>\n<blockquote>\n<p>quoted\nlazy</p>\n" ++
            "</blockquote>\n",
    );
    try expectHtml(
        "::: {.card .wide}\n::: inner\nhi\n:::\n:::\n",
        "<div class=\"card wide\">\n<div class=\"inner\">\n<p>hi</p>\n" ++
            "</div>\n</div>\n",
    );
}

test "tables and raw html" {
    try expectHtml(
        "| A | B |\n|:--|--:|\n| `x|y` | 2 |\n\n<div class=\"x\">\n" ++
            "<b>raw</b>\n</div>\n",
        "<table>\n<thead>\n<tr>\n<th style=\"text-align:left\">A</th>\n" ++
            "<th style=\"text-align:right\">B</th>\n</tr>\n</thead>\n" ++
            "<tbody>\n<tr>\n<td style=\"text-align:left\"><code>x|y" ++
            "</code></td>\n<td style=\"text-align:right\">2</td>\n</tr>\n" ++
            "</tbody>\n</table>\n<div class=\"x\">\n<b>raw</b>\n</div>\n",
    );
}
