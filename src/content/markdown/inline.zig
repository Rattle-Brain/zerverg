//! Inline Markdown: emphasis, code spans, links, images, autolinks,
//! line breaks and raw inline HTML. Everything else is escaped text.
//!
//! Raw HTML passes through untouched: entries are written by the site
//! admin, and the public CSP already blocks inline scripts.

const std = @import("std");
const Writer = std.Io.Writer;

pub const Error = Writer.Error;

/// Renders `text` (a paragraph, heading or table cell) as HTML.
pub fn render(w: *Writer, text: []const u8) Error!void {
    var i: usize = 0;
    while (i < text.len) i = try step(w, text, i);
}

/// Renders the construct starting at `i`; returns the next index.
fn step(w: *Writer, text: []const u8, i: usize) Error!usize {
    return switch (text[i]) {
        '\\' => backslash(w, text, i),
        '`' => codeSpan(w, text, i),
        '*', '_' => emphasis(w, text, i),
        '~' => strike(w, text, i),
        '!' => image(w, text, i),
        '[' => link(w, text, i),
        '<' => angle(w, text, i),
        '&' => entity(w, text, i),
        '\n' => lineBreak(w, text, i),
        else => |c| literal(w, c, i),
    };
}

fn literal(w: *Writer, c: u8, i: usize) Error!usize {
    try writeEscaped(w, &.{c});
    return i + 1;
}

/// `\*` is a literal star; a backslash at line end is a hard break.
fn backslash(w: *Writer, text: []const u8, i: usize) Error!usize {
    if (i + 1 >= text.len) return literal(w, '\\', i);
    const next = text[i + 1];
    if (next == '\n') {
        try w.writeAll("<br>\n");
        return i + 2;
    }
    if (!std.ascii.isPrint(next) or std.ascii.isAlphanumeric(next)) {
        return literal(w, '\\', i);
    }
    try writeEscaped(w, &.{next});
    return i + 2;
}

/// Two trailing spaces before a newline make a hard break.
fn lineBreak(w: *Writer, text: []const u8, i: usize) Error!usize {
    const hard = i >= 2 and text[i - 1] == ' ' and text[i - 2] == ' ';
    try w.writeAll(if (hard) "<br>\n" else "\n");
    return i + 1;
}

fn codeSpan(w: *Writer, text: []const u8, i: usize) Error!usize {
    const ticks = runLength(text, i);
    var j = i + ticks;
    while (j < text.len) {
        if (text[j] != '`') {
            j += 1;
            continue;
        }
        const close = runLength(text, j);
        if (close == ticks) {
            try writeCode(w, text[i + ticks .. j]);
            return j + close;
        }
        j += close;
    }
    try w.writeAll(text[i .. i + ticks]);
    return i + ticks;
}

fn writeCode(w: *Writer, raw: []const u8) Error!void {
    var code = raw;
    const padded = code.len >= 2 and code[0] == ' ' and
        code[code.len - 1] == ' ';
    if (padded and std.mem.trim(u8, code, " ").len > 0) {
        code = code[1 .. code.len - 1];
    }
    try w.writeAll("<code>");
    for (code) |c| {
        if (c == '\n') try w.writeByte(' ') else try writeEscaped(w, &.{c});
    }
    try w.writeAll("</code>");
}

/// `*em*`, `**strong**`, `***both***`; `_` only at word boundaries,
/// so snake_case stays intact.
fn emphasis(w: *Writer, text: []const u8, i: usize) Error!usize {
    const c = text[i];
    const run = runLength(text, i);
    const after = i + run;
    const intraword = c == '_' and i > 0 and isWordByte(text[i - 1]);
    if (intraword or after >= text.len or text[after] == ' ') {
        try w.writeAll(text[i..after]);
        return after;
    }
    const levels = [_]struct { n: usize, open: []const u8, close: []const u8 }{
        .{ .n = 3, .open = "<em><strong>", .close = "</strong></em>" },
        .{ .n = 2, .open = "<strong>", .close = "</strong>" },
        .{ .n = 1, .open = "<em>", .close = "</em>" },
    };
    for (levels) |level| {
        if (run < level.n) continue;
        const start = i + level.n;
        const end = findCloser(text, start, c, level.n) orelse continue;
        try w.writeAll(level.open);
        try render(w, text[start..end]);
        try w.writeAll(level.close);
        return end + level.n;
    }
    try w.writeAll(text[i..after]);
    return after;
}

/// Index of a closing run of exactly `n` × `c`, not preceded by a
/// space, nor (for `_`) followed by a word character.
fn findCloser(text: []const u8, from: usize, c: u8, n: usize) ?usize {
    var j = from;
    while (j < text.len) {
        if (text[j] == '`') {
            j += runLength(text, j);
            continue;
        }
        if (text[j] != c) {
            j += 1;
            continue;
        }
        const run = runLength(text, j);
        const end = j + run;
        const flanked = j > from and text[j - 1] != ' ';
        const boundary = c != '_' or end >= text.len or
            !isWordByte(text[end]);
        if (run == n and flanked and boundary) return j;
        j = end;
    }
    return null;
}

fn strike(w: *Writer, text: []const u8, i: usize) Error!usize {
    if (!std.mem.startsWith(u8, text[i..], "~~")) return literal(w, '~', i);
    const close = std.mem.indexOfPos(u8, text, i + 2, "~~") orelse
        return literal(w, '~', i);
    try w.writeAll("<del>");
    try render(w, text[i + 2 .. close]);
    try w.writeAll("</del>");
    return close + 2;
}

const Link = struct {
    label: []const u8,
    url: []const u8,
    title: ?[]const u8 = null,
    end: usize,
};

fn link(w: *Writer, text: []const u8, i: usize) Error!usize {
    const parsed = parseLink(text, i) orelse return literal(w, '[', i);
    try w.writeAll("<a href=\"");
    try writeEscaped(w, parsed.url);
    try w.writeByte('"');
    try writeTitle(w, parsed.title);
    try w.writeByte('>');
    try render(w, parsed.label);
    try w.writeAll("</a>");
    return parsed.end;
}

fn image(w: *Writer, text: []const u8, i: usize) Error!usize {
    const parsed = (if (i + 1 < text.len and text[i + 1] == '[')
        parseLink(text, i + 1)
    else
        null) orelse return literal(w, '!', i);
    try w.writeAll("<img src=\"");
    try writeEscaped(w, parsed.url);
    try w.writeAll("\" alt=\"");
    try writeEscaped(w, parsed.label);
    try w.writeByte('"');
    try writeTitle(w, parsed.title);
    try w.writeByte('>');
    return parsed.end;
}

fn writeTitle(w: *Writer, title: ?[]const u8) Error!void {
    const t = title orelse return;
    try w.writeAll(" title=\"");
    try writeEscaped(w, t);
    try w.writeByte('"');
}

/// `[label](url "title")` starting at `[`.
fn parseLink(text: []const u8, open: usize) ?Link {
    const close = matchingBracket(text, open) orelse return null;
    if (close + 1 >= text.len or text[close + 1] != '(') return null;
    var j = skipSpaces(text, close + 2);
    const url_start = j;
    var depth: usize = 0;
    while (j < text.len) : (j += 1) {
        const c = text[j];
        if (c == ' ' or c == '\n') break;
        if (c == '(') depth += 1;
        if (c == ')') {
            if (depth == 0) break;
            depth -= 1;
        }
    }
    var result: Link = .{
        .label = text[open + 1 .. close],
        .url = std.mem.trim(u8, text[url_start..j], "<>"),
        .end = 0,
    };
    j = skipSpaces(text, j);
    if (j < text.len and (text[j] == '"' or text[j] == '\'')) {
        const quote = text[j];
        const end = std.mem.indexOfScalarPos(u8, text, j + 1, quote) orelse
            return null;
        result.title = text[j + 1 .. end];
        j = skipSpaces(text, end + 1);
    }
    if (j >= text.len or text[j] != ')') return null;
    result.end = j + 1;
    return result;
}

fn matchingBracket(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var j = open;
    while (j < text.len) : (j += 1) {
        switch (text[j]) {
            '\\' => j += 1,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) return j;
            },
            else => {},
        }
    }
    return null;
}

/// Autolinks (`<https://...>`), raw HTML tags and comments, or `&lt;`.
fn angle(w: *Writer, text: []const u8, i: usize) Error!usize {
    const rest = text[i + 1 ..];
    if (std.mem.startsWith(u8, rest, "!--")) {
        const end = std.mem.indexOfPos(u8, text, i, "-->") orelse
            return literal(w, '<', i);
        try w.writeAll(text[i .. end + 3]);
        return end + 3;
    }
    const close = std.mem.indexOfScalarPos(u8, text, i, '>') orelse
        return literal(w, '<', i);
    const inner = text[i + 1 .. close];
    if (isAutolink(inner)) {
        try w.writeAll("<a href=\"");
        try writeEscaped(w, inner);
        try w.writeAll("\">");
        try writeEscaped(w, inner);
        try w.writeAll("</a>");
        return close + 1;
    }
    if (!looksLikeTag(inner)) return literal(w, '<', i);
    try w.writeAll(text[i .. close + 1]);
    return close + 1;
}

fn isAutolink(inner: []const u8) bool {
    if (std.mem.indexOfAny(u8, inner, " \n<") != null) return false;
    const schemes = [_][]const u8{ "https://", "http://", "mailto:" };
    for (schemes) |s| {
        if (std.ascii.startsWithIgnoreCase(inner, s)) return true;
    }
    return false;
}

/// `name ...`, `/name` or `name/` with a letter first.
fn looksLikeTag(inner: []const u8) bool {
    const name = if (inner.len > 0 and inner[0] == '/') inner[1..] else inner;
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) return false;
    var j: usize = 1;
    while (j < name.len and (std.ascii.isAlphanumeric(name[j]) or
        name[j] == '-')) j += 1;
    return j == name.len or name[j] == ' ' or name[j] == '\n' or
        name[j] == '/';
}

/// Named and numeric character references pass through.
fn entity(w: *Writer, text: []const u8, i: usize) Error!usize {
    var j = i + 1;
    if (j < text.len and text[j] == '#') j += 1;
    const start = j;
    while (j < text.len and j - start < 32 and
        std.ascii.isAlphanumeric(text[j])) j += 1;
    if (j > start and j < text.len and text[j] == ';') {
        try w.writeAll(text[i .. j + 1]);
        return j + 1;
    }
    return literal(w, '&', i);
}

pub fn writeEscaped(w: *Writer, text: []const u8) Error!void {
    for (text) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

fn runLength(text: []const u8, i: usize) usize {
    var j = i;
    while (j < text.len and text[j] == text[i]) j += 1;
    return j - i;
}

fn skipSpaces(text: []const u8, from: usize) usize {
    var j = from;
    while (j < text.len and (text[j] == ' ' or text[j] == '\n')) j += 1;
    return j;
}

fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

fn expectInline(input: []const u8, expected: []const u8) !void {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try render(&out.writer, input);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "emphasis and code" {
    try expectInline("*a* **b** ***c***", "<em>a</em> <strong>b</strong> " ++
        "<em><strong>c</strong></em>");
    try expectInline("*a **b** c*", "<em>a <strong>b</strong> c</em>");
    try expectInline("snake_case_name", "snake_case_name");
    try expectInline("2 * 3 * 4", "2 * 3 * 4");
    try expectInline("`a < b` and ``x`y``", "<code>a &lt; b</code> and " ++
        "<code>x`y</code>");
    try expectInline("~~old~~ \\*lit\\*", "<del>old</del> *lit*");
}

test "links, images, html and escapes" {
    try expectInline(
        "[a *b*](/x \"T\") ![pic](media:p.png)",
        "<a href=\"/x\" title=\"T\">a <em>b</em></a> " ++
            "<img src=\"media:p.png\" alt=\"pic\">",
    );
    try expectInline(
        "<https://z.dev> <span class=\"k\">x</span> a < b & c &amp;",
        "<a href=\"https://z.dev\">https://z.dev</a> " ++
            "<span class=\"k\">x</span> a &lt; b &amp; c &amp;",
    );
    try expectInline("a  \nb\\\nc", "a  <br>\nb<br>\nc");
    try expectInline("[not a link] (x)", "[not a link] (x)");
}
