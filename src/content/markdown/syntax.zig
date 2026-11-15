//! Line classification for the block parser: which construct, if
//! any, a single line starts.

const std = @import("std");
const Writer = std.Io.Writer;

pub fn isBlank(line: []const u8) bool {
    return std.mem.trim(u8, line, " ").len == 0;
}

pub fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

/// Removes up to `n` leading spaces.
pub fn dedent(line: []const u8, n: usize) []const u8 {
    return line[@min(indentOf(line), n)..];
}

/// Up to three spaces of indent, then the rest.
fn body(line: []const u8) ?[]const u8 {
    const indent = indentOf(line);
    if (indent > 3) return null;
    return line[indent..];
}

pub const Fence = struct {
    char: u8,
    len: usize,
    indent: usize,
    language: []const u8,
};

/// ``` or ~~~ (three or more), with an optional language.
pub fn fenceOf(line: []const u8) ?Fence {
    const rest = body(line) orelse return null;
    if (rest.len < 3 or (rest[0] != '`' and rest[0] != '~')) return null;
    var n: usize = 0;
    while (n < rest.len and rest[n] == rest[0]) n += 1;
    if (n < 3) return null;
    const info = std.mem.trim(u8, rest[n..], " ");
    if (rest[0] == '`' and std.mem.indexOfScalar(u8, info, '`') != null) {
        return null;
    }
    const end = std.mem.indexOfScalar(u8, info, ' ') orelse info.len;
    return .{
        .char = rest[0],
        .len = n,
        .indent = indentOf(line),
        .language = info[0..end],
    };
}

pub fn closesFence(line: []const u8, fence: Fence) bool {
    const rest = std.mem.trimEnd(u8, body(line) orelse return false, " ");
    if (rest.len < fence.len) return false;
    for (rest) |c| if (c != fence.char) return false;
    return true;
}

/// `::: name ...` -> "name ...". A bare `:::` closes instead.
pub fn divOpen(line: []const u8) ?[]const u8 {
    const rest = body(line) orelse return null;
    if (!std.mem.startsWith(u8, rest, ":::")) return null;
    const name = std.mem.trim(u8, std.mem.trimStart(u8, rest, ":"), " ");
    if (name.len == 0) return null;
    return name;
}

pub fn isDivClose(line: []const u8) bool {
    const rest = std.mem.trim(u8, body(line) orelse return false, " ");
    if (rest.len < 3) return false;
    for (rest) |c| if (c != ':') return false;
    return true;
}

/// Accepts `card wide`, `.card .wide` and `{.card .wide}`; keeps only
/// class-safe characters.
pub fn writeClasses(w: *Writer, classes: []const u8) !void {
    var tokens = std.mem.tokenizeAny(u8, classes, " {}");
    var first = true;
    while (tokens.next()) |raw| {
        const token = std.mem.trimStart(u8, raw, ".");
        if (token.len == 0) continue;
        if (!first) try w.writeByte(' ');
        first = false;
        for (token) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') {
                try w.writeByte(c);
            }
        }
    }
}

pub const Heading = struct {
    level: u8,
    text: []const u8,
};

pub fn headingOf(line: []const u8) ?Heading {
    const rest = body(line) orelse return null;
    var level: u8 = 0;
    while (level < rest.len and rest[level] == '#') level += 1;
    if (level == 0 or level > 6) return null;
    if (level < rest.len and rest[level] != ' ') return null;
    var text = std.mem.trim(u8, rest[level..], " ");
    const closing = std.mem.trimEnd(u8, text, "#");
    if (closing.len == 0 or closing[closing.len - 1] == ' ') {
        text = std.mem.trimEnd(u8, closing, " ");
    }
    return .{ .level = level, .text = text };
}

/// `---`, `***`, `___`, spaces allowed between.
pub fn isRule(line: []const u8) bool {
    const rest = body(line) orelse return false;
    if (rest.len == 0) return false;
    const c = rest[0];
    if (c != '-' and c != '*' and c != '_') return false;
    var count: usize = 0;
    for (rest) |x| {
        if (x == c) count += 1 else if (x != ' ') return false;
    }
    return count >= 3;
}

pub fn isQuote(line: []const u8) bool {
    const rest = body(line) orelse return false;
    return rest.len > 0 and rest[0] == '>';
}

/// `<div`, `</div`, `<!--`: the line is raw HTML.
pub fn isHtmlStart(line: []const u8) bool {
    const rest = body(line) orelse return false;
    if (rest.len < 2 or rest[0] != '<') return false;
    return std.ascii.isAlphabetic(rest[1]) or rest[1] == '/' or
        rest[1] == '!';
}

pub const ListMarker = struct {
    ordered: bool,
    /// `-`, `*`, `+`, or `.` / `)` after a number.
    char: u8,
    number: u32 = 1,
    /// Column where the item's content starts.
    content: usize,
    empty: bool,

    pub fn sameListAs(a: ListMarker, b: ListMarker) bool {
        return a.ordered == b.ordered and a.char == b.char;
    }
};

pub fn listItemOf(line: []const u8) ?ListMarker {
    const indent = indentOf(line);
    const rest = body(line) orelse return null;
    if (rest.len == 0) return null;
    var marker: ListMarker = .{
        .ordered = false,
        .char = rest[0],
        .content = 0,
        .empty = false,
    };
    var width: usize = 1;
    if (rest[0] != '-' and rest[0] != '*' and rest[0] != '+') {
        width = 0;
        while (width < rest.len and width < 9 and
            std.ascii.isDigit(rest[width])) width += 1;
        if (width == 0 or width >= rest.len) return null;
        if (rest[width] != '.' and rest[width] != ')') return null;
        marker.ordered = true;
        marker.char = rest[width];
        marker.number = std.fmt.parseInt(u32, rest[0..width], 10) catch 1;
        width += 1;
    }
    const after = rest[width..];
    if (after.len > 0 and after[0] != ' ') return null;
    const spaces = @min(@max(indentOf(after), 1), 4);
    marker.empty = isBlank(after);
    marker.content = indent + width + if (marker.empty) 1 else spaces;
    return marker;
}

/// Constructs that end a paragraph without a blank line.
pub fn interruptsParagraph(line: []const u8) bool {
    if (fenceOf(line) != null or divOpen(line) != null) return true;
    if (isDivClose(line) or headingOf(line) != null) return true;
    if (isRule(line) or isQuote(line) or isHtmlStart(line)) return true;
    const item = listItemOf(line) orelse return false;
    return !item.empty and (!item.ordered or item.number == 1);
}

/// A non-indented line that continues the item's last paragraph.
pub fn isLazyContinuation(
    line: []const u8,
    item_lines: []const []const u8,
) bool {
    if (item_lines.len == 0 or isBlank(item_lines[item_lines.len - 1])) {
        return false;
    }
    return !interruptsParagraph(line) and listItemOf(line) == null;
}
